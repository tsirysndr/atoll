defmodule Atoll.AccountCleanupWorkerTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{CleanupWorker, ServiceTokenUse, Session, Tokens}
  alias Atoll.{Repositories, SigningKey}

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    owner = self()
    handler = make_ref()
    :ok = :telemetry.attach(handler, [:atoll, :accounts, :cleanup], &__MODULE__.report/4, owner)
    on_exit(fn -> :telemetry.detach(handler) end)
    %{supervisor: supervisor, owner: owner}
  end

  def report(_, counts, metadata, owner), do: send(owner, {:cleanup, metadata.result, counts})

  test "scheduled batches prune expired rows within limits while keeping live authentication state",
       c do
    did = "did:plc:scheduledaccountcleanup"
    {:ok, _} = Repositories.create(did, SigningKey.generate())

    for expiry <- List.duplicate(1, 501) ++ [System.system_time(:second) + 3600] do
      Repo.insert!(%Session{
        id: Tokens.random_id(),
        did: did,
        refresh_hash: :crypto.strong_rand_bytes(32),
        expires_at: expiry
      })

      Repo.insert!(%ServiceTokenUse{digest: :crypto.strong_rand_bytes(32), expires_at: expiry})
    end

    worker = worker(c)
    tick(worker)
    assert_receive {:cleanup, :ok, %{sessions: 500, replay_markers: 500, runs: 1}}, 2000
    assert Repo.aggregate(Session, :count) == 2
    assert Repo.aggregate(ServiceTokenUse, :count) == 2
    tick(worker)
    assert_receive {:cleanup, :ok, %{sessions: 1, replay_markers: 1, runs: 1}}, 1000
    assert Repo.one!(Session).expires_at > System.system_time(:second)
    assert Repo.one!(ServiceTokenUse).expires_at > System.system_time(:second)
    tick(worker)
    assert_receive {:cleanup, :ok, %{sessions: 0, replay_markers: 0, runs: 1}}, 1000
    assert :sys.get_state(worker).task == nil
  end

  test "manual triggers do not overlap and a finished run schedules its successor", c do
    run = fn ->
      send(c.owner, {:running, self()})

      receive do
        :finish -> {:ok, %{sessions: 2, replay_markers: 3}}
      end
    end

    worker = worker(c, run: run)
    CleanupWorker.run_now(worker)
    assert_receive {:running, task}
    CleanupWorker.run_now(worker)
    assert :sys.get_state(worker).task.pid == task
    assert length(Task.Supervisor.children(c.supervisor)) == 1
    send(task, :finish)
    assert_receive {:cleanup, :ok, %{sessions: 2, replay_markers: 3, runs: 1}}
    tick(worker)
    assert_receive {:running, _}
  end

  test "failed results and crashed tasks allow later batches", c do
    counter = start_supervised!({Agent, fn -> 0 end})

    run = fn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:error, :unavailable}
        1 -> exit(:normal)
        _ -> {:ok, %{sessions: 0, replay_markers: 0}}
      end
    end

    worker = worker(c, run: run)

    for result <- [:failed, :failed, :ok] do
      CleanupWorker.run_now(worker)
      assert_receive {:cleanup, ^result, _}
    end
  end

  test "timeouts kill the task and ignore stale deadline messages", c do
    worker =
      worker(c,
        run: fn ->
          send(c.owner, {:running, self()})

          receive do
            :never -> :ok
          end
        end
      )

    tick(worker)
    assert_receive {:running, task}
    monitor = Process.monitor(task)
    state = :sys.get_state(worker)
    message = {:timeout, state.deadline, {:deadline, state.task.ref}}
    send(worker, message)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert_receive {:cleanup, :timeout, %{runs: 1}}
    send(worker, message)
    assert :sys.get_state(worker).task == nil
    tick(worker)
    assert_receive {:running, next_task}
    monitor = Process.monitor(next_task)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^monitor, :process, ^next_task, :killed}
  end

  defp worker(c, opts \\ []) do
    start_supervised!(
      {CleanupWorker,
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
end
