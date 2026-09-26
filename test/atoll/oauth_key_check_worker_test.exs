defmodule Atoll.OAuthKeyCheckWorkerTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.{KeyChecks, KeyCheckWorker}

  def report(_, counts, metadata, owner), do: send(owner, {:key_check, metadata.result, counts})

  test "enabled defaults, test opt-out, and bounded startup settings" do
    assert KeyChecks.config_from_env!(%{}) == [enabled: true, interval_ms: 300_000]
    assert KeyCheckWorker.children(enabled: false) == []
    assert length(KeyCheckWorker.children(KeyChecks.config_from_env!(%{}))) == 2

    assert KeyChecks.config_from_env!(%{
             "ATOLL_OAUTH_KEY_CHECKS_ENABLED" => "false",
             "ATOLL_OAUTH_KEY_CHECKS_INTERVAL_SECONDS" => "60"
           }) == [enabled: false, interval_ms: 60_000]

    for env <- [
          %{"ATOLL_OAUTH_KEY_CHECKS_ENABLED" => "yes"},
          %{"ATOLL_OAUTH_KEY_CHECKS_INTERVAL_SECONDS" => "29"},
          %{"ATOLL_OAUTH_KEY_CHECKS_INTERVAL_SECONDS" => "3601"}
        ] do
      assert_raise ArgumentError, fn -> KeyChecks.config_from_env!(env) end
    end
  end

  test "one task at a time, deadline cancellation, shutdown and failure retry" do
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    handler = make_ref()

    :ok =
      :telemetry.attach(handler, [:atoll, :oauth, :key_checks], &__MODULE__.report/4, owner)

    on_exit(fn -> :telemetry.detach(handler) end)
    counter = start_supervised!({Agent, fn -> 0 end})

    run = fn cursor, checkpoint ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          {:error, :database_unavailable}

        1 ->
          exit(:normal)

        _ ->
          checkpoint.({"client", "session"})
          send(owner, {:running, self(), cursor})

          receive do
            :finish ->
              {:ok,
               %{cursor: {"client", "session"}, checked: 1, revoked: 1, failed: 0, did: "redact"}}
          end
      end
    end

    worker =
      start_supervised!(
        {KeyCheckWorker,
         [name: nil, task_supervisor: supervisor, run: run, interval: 60_000, start_after: 60_000]}
      )

    for _ <- 1..2 do
      tick(worker)
      assert_receive {:key_check, :failed, %{runs: 1}}
    end

    tick(worker)
    assert_receive {:running, task, nil}
    KeyCheckWorker.run_now(worker)
    state = :sys.get_state(worker)
    assert state.task.pid == task
    assert length(Task.Supervisor.children(supervisor)) == 1
    ref = Process.monitor(task)
    deadline = {:timeout, state.deadline, {:deadline, state.task.ref}}
    send(worker, deadline)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}
    assert_receive {:key_check, :timeout, %{runs: 1}}
    send(worker, deadline)
    assert :sys.get_state(worker).task == nil
    tick(worker)
    assert_receive {:running, next, {"client", "session"}}
    send(next, :finish)
    assert_receive {:key_check, :ok, counts}
    assert counts == %{runs: 1, checked: 1, revoked: 1, failed: 0}
    tick(worker)
    assert_receive {:running, final, {"client", "session"}}
    ref = Process.monitor(final)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^ref, :process, ^final, :killed}
  end

  test "completed sweeps reset the cursor and wait for the configured interval" do
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    handler = make_ref()
    :ok = :telemetry.attach(handler, [:atoll, :oauth, :key_checks], &__MODULE__.report/4, owner)
    on_exit(fn -> :telemetry.detach(handler) end)

    run = fn
      nil, checkpoint ->
        checkpoint.({"client", "last"})
        {:ok, %{cursor: {"client", "last"}, checked: 1, revoked: 0, failed: 0}}

      {"client", "last"}, _ ->
        {:ok, :done}
    end

    worker =
      start_supervised!(
        {KeyCheckWorker,
         [name: nil, task_supervisor: supervisor, run: run, interval: 60_000, start_after: 60_000]}
      )

    tick(worker)
    assert_receive {:key_check, :ok, _}
    assert :sys.get_state(worker).cursor == {"client", "last"}
    tick(worker)
    assert_receive {:key_check, :complete, %{runs: 1}}
    state = :sys.get_state(worker)
    assert state.cursor == nil
    assert :erlang.read_timer(state.timer) in 1001..60_000
    tick(worker)
    assert_receive {:key_check, :ok, _}
  end

  defp tick(worker) do
    state = :sys.get_state(worker)
    send(worker, {:timeout, state.timer, :tick})
    :sys.get_state(worker)
  end
end
