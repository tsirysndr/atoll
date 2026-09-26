defmodule Atoll.SignupCleanupWorkerTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{Profile, SignupCleanup, SignupCleanupWorker}
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations}
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}

  setup do
    for name <- [:key_encryption_key, :signup_cleanup] do
      prior = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :signup_cleanup, days: 7, limit: 1)
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:atoll, :accounts, :signup_cleanup],
        &__MODULE__.report/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{supervisor: supervisor, owner: self()}
  end

  def report(_, counts, metadata, owner), do: send(owner, {:cleanup, metadata, counts})

  test "configured batches delete old reservations while protecting attempted publication", c do
    first = reservation("first", false)
    second = reservation("second", false)
    protected = reservation("protected", true)
    worker = worker(c)
    tick(worker)

    assert_receive {:cleanup, %{result: :ok, more: true}, %{runs: 1, selected: 1, deleted: 1}},
                   2000

    assert Repo.aggregate(Registration, :count) == 2
    tick(worker)

    assert_receive {:cleanup, %{result: :ok, more: false}, %{runs: 1, selected: 1, deleted: 1}},
                   2000

    assert Repo.one!(Registration).did == protected
    assert Enum.all?(Repo.all(Atoll.Moderation.AuditEntry), &(&1.actor == "system"))
    refute Repo.get(Registration, first)
    refute Repo.get(Registration, second)
    tick(worker)
    assert_receive {:cleanup, %{result: :ok}, %{selected: 0, deleted: 0, runs: 1}}, 1000
  end

  test "manual triggers do not overlap and telemetry omits private or identifying output", c do
    run = fn ->
      send(c.owner, {:running, self()})

      receive do
        :finish ->
          {:ok, %{selected: 1, deleted: 1, dids: ["private"], cutoff: "private", more: false}}
      end
    end

    worker = worker(c, run: run)
    SignupCleanupWorker.run_now(worker)
    assert_receive {:running, task}
    SignupCleanupWorker.run_now(worker)
    assert :sys.get_state(worker).task.pid == task
    assert length(Task.Supervisor.children(c.supervisor)) == 1
    send(task, :finish)
    assert_receive {:cleanup, %{result: :ok}, counts}
    assert counts == %{selected: 1, deleted: 1, runs: 1}
    tick(worker)
    assert_receive {:running, next}
    monitor = Process.monitor(next)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^monitor, :process, ^next, :killed}
  end

  test "failures, crashes and deadlines allow later batches and ignore stale messages", c do
    counter = start_supervised!({Agent, fn -> 0 end})

    run = fn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          {:error, :busy}

        1 ->
          exit(:normal)

        2 ->
          send(c.owner, {:running, self()})

          receive do
            :never -> :ok
          end

        _ ->
          {:ok, %{selected: 0, deleted: 0}}
      end
    end

    worker = worker(c, run: run)

    for _ <- 1..2 do
      tick(worker)
      assert_receive {:cleanup, %{result: :failed}, %{runs: 1}}
    end

    tick(worker)
    assert_receive {:running, task}
    monitor = Process.monitor(task)
    state = :sys.get_state(worker)
    deadline = {:timeout, state.deadline, {:deadline, state.task.ref}}
    send(worker, deadline)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert_receive {:cleanup, %{result: :timeout}, %{runs: 1}}
    send(worker, deadline)
    assert :sys.get_state(worker).task == nil
    tick(worker)
    assert_receive {:cleanup, %{result: :ok}, %{selected: 0, deleted: 0, runs: 1}}
  end

  test "environment parsing keeps cleanup opt-in and bounds age, interval and batch size" do
    assert SignupCleanup.config_from_env!(%{}) == [
             enabled: false,
             days: 7,
             limit: 100,
             interval_ms: 3_600_000
           ]

    assert SignupCleanupWorker.children([]) == []

    config =
      SignupCleanup.config_from_env!(%{
        "ATOLL_SIGNUP_CLEANUP_ENABLED" => "true",
        "ATOLL_SIGNUP_CLEANUP_AGE_DAYS" => "14",
        "ATOLL_SIGNUP_CLEANUP_BATCH_SIZE" => "20",
        "ATOLL_SIGNUP_CLEANUP_INTERVAL_SECONDS" => "600"
      })

    assert config == [enabled: true, days: 14, limit: 20, interval_ms: 600_000]
    assert length(SignupCleanupWorker.children(config)) == 2

    for env <- [
          %{"ATOLL_SIGNUP_CLEANUP_ENABLED" => "yes"},
          %{"ATOLL_SIGNUP_CLEANUP_AGE_DAYS" => "0"},
          %{"ATOLL_SIGNUP_CLEANUP_BATCH_SIZE" => "101"},
          %{"ATOLL_SIGNUP_CLEANUP_INTERVAL_SECONDS" => "59"},
          %{"ATOLL_SIGNUP_CLEANUP_AGE_DAYS" => "7oops"}
        ] do
      assert_raise ArgumentError, fn -> SignupCleanup.config_from_env!(env) end
    end
  end

  defp worker(c, opts \\ []) do
    start_supervised!(
      {SignupCleanupWorker,
       Keyword.merge(
         [
           name: nil,
           task_supervisor: c.supervisor,
           start_after: 60_000,
           interval: 60_000
         ],
         opts
       )}
    )
  end

  defp tick(worker) do
    state = :sys.get_state(worker)
    send(worker, {:timeout, state.timer, :tick})
    :sys.get_state(worker)
  end

  defp reservation(label, attempted?) do
    key = SigningKey.generate()
    rotation = SigningKey.generate()
    {:ok, signing} = Multikey.to_did_key(key.curve, key.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)
    handle = label <> ".example.com"

    {:ok, genesis} =
      Operation.create_atproto(signing, handle, "https://pds.example.com", [rotating], rotation)

    {:ok, _} = Repositories.create(genesis.did, key)
    {:ok, _} = KeyVault.store(genesis.did, key)
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    Repo.insert!(%Profile{did: genesis.did, handle: handle})
    {:ok, _} = Registrations.stage(genesis.did, genesis.operation, rotation)
    old = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)

    Repo.get!(Registration, genesis.did)
    |> Ecto.Changeset.change(inserted_at: old, submission_started_at: if(attempted?, do: old))
    |> Repo.update!()

    genesis.did
  end
end
