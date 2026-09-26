defmodule Atoll.EventRetentionWorkerTest do
  use Atoll.DataCase, async: false
  alias Atoll.Repositories.EventRetentionWorker, as: Worker

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    owner = self()
    handler = make_ref()
    :ok = :telemetry.attach(handler, [:atoll, :events, :retention], &__MODULE__.report/4, owner)
    on_exit(fn -> :telemetry.detach(handler) end)
    %{supervisor: supervisor, owner: owner}
  end

  def report(_, counts, metadata, owner),
    do: send(owner, {:retention, metadata.result, counts})

  test "scheduled batches prune at most 1000 expired events and preserve fresh rows", c do
    previous = Application.fetch_env(:atoll, :event_retention_seconds)
    Application.put_env(:atoll, :event_retention_seconds, 3600)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :event_retention_seconds, value)
        :error -> Application.delete_env(:atoll, :event_retention_seconds)
      end
    end)

    row = %{
      did: "did:plc:scheduledretention",
      kind: :account,
      payload: Atoll.CBOR.encode!(%{"active" => true}),
      time: DateTime.add(DateTime.utc_now(), -7200, :second)
    }

    Repo.insert_all(Atoll.Repositories.Event, List.duplicate(row, 1001))
    Repo.insert_all(Atoll.Repositories.Event, [Map.put(row, :time, DateTime.utc_now())])
    worker = worker(c)
    tick(worker)
    assert_receive {:retention, :completed, %{deleted: 1000, floor: first, runs: 1}}, 2000
    assert Repo.aggregate(Atoll.Repositories.Event, :count) == 2
    tick(worker)
    assert_receive {:retention, :completed, %{deleted: 1, floor: second, runs: 1}}, 2000
    assert second > first
    assert Repo.aggregate(Atoll.Repositories.Event, :count) == 1
    tick(worker)
    assert_receive {:retention, :completed, %{deleted: 0, floor: ^second, runs: 1}}, 2000
    assert Atoll.Repositories.EventRetention.bounds().floor == second
  end

  test "configuration is opt-in, bounded and always disables scheduling during tests" do
    alias Atoll.Repositories.EventRetention
    assert EventRetention.config_from_env!(%{}) == %{enabled: false, seconds: 604_800}
    env = %{"ATOLL_EVENT_RETENTION_ENABLED" => "true", "ATOLL_EVENT_RETENTION_SECONDS" => "3600"}
    assert EventRetention.config_from_env!(env) == %{enabled: true, seconds: 3600}
    refute EventRetention.config_from_env!(env, true).enabled

    assert_raise ArgumentError, fn ->
      EventRetention.config_from_env!(%{"ATOLL_EVENT_RETENTION_ENABLED" => "yes"})
    end

    for value <- ["0", "3599", "31536001", "3600x", ""] do
      assert_raise ArgumentError, fn ->
        EventRetention.config_from_env!(Map.put(env, "ATOLL_EVENT_RETENTION_SECONDS", value))
      end
    end
  end

  test "manual triggers do not overlap and a finished run schedules its successor", c do
    run = fn ->
      send(c.owner, {:running, self()})

      receive do
        :finish -> {:ok, %{deleted: 2, floor: 3}}
      end
    end

    worker = worker(c, run: run)
    Worker.run_now(worker)
    assert_receive {:running, task}
    Worker.run_now(worker)
    assert :sys.get_state(worker).task.pid == task
    assert length(Task.Supervisor.children(c.supervisor)) == 1
    send(task, :finish)
    assert_receive {:retention, :completed, %{deleted: 2, floor: 3, runs: 1}}
    tick(worker)
    assert_receive {:running, _}
  end

  test "failed results and crashed tasks allow later batches", c do
    counter = start_supervised!({Agent, fn -> 0 end})

    run = fn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:error, :unavailable}
        1 -> exit(:normal)
        _ -> {:ok, %{deleted: 0, floor: 0}}
      end
    end

    worker = worker(c, run: run)

    for result <- [:failed, :failed, :completed] do
      Worker.run_now(worker)
      assert_receive {:retention, ^result, _}
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
    assert_receive {:retention, :timeout, %{runs: 1}}
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
      {Worker,
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
