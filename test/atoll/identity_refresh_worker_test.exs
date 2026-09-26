defmodule Atoll.IdentityRefreshWorkerTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.RefreshWorker

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    handler = make_ref()
    owner = self()
    :ok = :telemetry.attach(handler, [:atoll, :identity, :refresh], &__MODULE__.report/4, owner)
    on_exit(fn -> :telemetry.detach(handler) end)
    %{supervisor: supervisor, owner: owner}
  end

  def report(_, _, metadata, owner), do: send(owner, {:result, metadata.did, metadata.result})

  test "visits each identity without overlap and resets after a sweep", context do
    next = fn
      nil -> "a"
      "a" -> "b"
      "b" -> nil
    end

    refresh = fn did ->
      send(context.owner, {:started, did, self()})

      receive do
        :release -> {:ok, :unchanged}
      end
    end

    worker = worker(context, next, refresh)
    RefreshWorker.run_now(worker)
    assert_receive {:started, "a", task}
    RefreshWorker.run_now(worker)
    assert :sys.get_state(worker).cursor == "a"
    assert length(Task.Supervisor.children(context.supervisor)) == 1
    send(task, :release)
    assert_receive {:result, "a", :unchanged}
    RefreshWorker.run_now(worker)
    assert_receive {:started, "b", task}
    send(task, :release)
    assert_receive {:result, "b", :unchanged}
    tick(worker)
    assert :sys.get_state(worker).cursor == nil
    RefreshWorker.run_now(worker)
    assert_receive {:started, "a", _}
  end

  test "failed and crashed refreshes advance to the next identity", context do
    next = fn
      nil -> "a"
      "a" -> "b"
      "b" -> "c"
      "c" -> nil
    end

    refresh = fn
      "a" -> {:error, :identity_unavailable}
      "b" -> exit(:normal)
      "c" -> {:ok, :published}
    end

    worker = worker(context, next, refresh)

    for {did, outcome} <- [{"a", :failed}, {"b", :failed}, {"c", :published}] do
      RefreshWorker.run_now(worker)
      assert_receive {:result, ^did, ^outcome}
    end
  end

  test "deadline kills a stuck task and stale timers do not start duplicate work", context do
    refresh = fn did ->
      send(context.owner, {:started, did, self()})

      receive do
        :never -> :ok
      end
    end

    worker =
      worker(
        context,
        fn
          nil -> "a"
          "a" -> "b"
        end,
        refresh
      )

    tick(worker)
    assert_receive {:started, "a", task}
    monitor = Process.monitor(task)
    state = :sys.get_state(worker)
    deadline = {:timeout, state.deadline, {:deadline, state.task.ref}}
    send(worker, deadline)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
    assert_receive {:result, "a", :timeout}
    send(worker, deadline)
    assert :sys.get_state(worker).task == nil
    RefreshWorker.run_now(worker)
    assert_receive {:started, "b", _}
  end

  test "stopping the worker terminates its in-flight task", context do
    refresh = fn _ ->
      send(context.owner, {:started, self()})

      receive do
        :never -> :ok
      end
    end

    worker = worker(context, fn _ -> "a" end, refresh)
    RefreshWorker.run_now(worker)
    assert_receive {:started, task}
    monitor = Process.monitor(task)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
  end

  defp worker(context, next, refresh) do
    start_supervised!(
      {RefreshWorker,
       name: nil,
       task_supervisor: context.supervisor,
       next: next,
       refresh: refresh,
       start_after: 60_000,
       spacing: 60_000,
       interval: 60_000}
    )
  end

  defp tick(worker) do
    state = :sys.get_state(worker)
    send(worker, {:timeout, state.timer, :tick})
    :sys.get_state(worker)
  end
end
