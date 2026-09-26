defmodule Atoll.SignupRetryWorkerTest do
  use ExUnit.Case, async: true
  alias Atoll.Accounts.{SignupRetries, SignupRetryWorker}

  def report(_, counts, metadata, owner), do: send(owner, {:retry, metadata.result, counts})

  test "disabled defaults and bounded startup settings" do
    assert SignupRetries.config_from_env!(%{}) == [
             enabled: false,
             interval_ms: 30_000,
             delay_seconds: 300
           ]

    assert SignupRetryWorker.children([]) == []

    config =
      SignupRetries.config_from_env!(%{
        "ATOLL_SIGNUP_RETRY_ENABLED" => "true",
        "ATOLL_SIGNUP_RETRY_INTERVAL_SECONDS" => "60",
        "ATOLL_SIGNUP_RETRY_DELAY_SECONDS" => "600"
      })

    assert config == [enabled: true, interval_ms: 60_000, delay_seconds: 600]
    assert length(SignupRetryWorker.children(config)) == 2

    for env <- [
          %{"ATOLL_SIGNUP_RETRY_ENABLED" => "yes"},
          %{"ATOLL_SIGNUP_RETRY_INTERVAL_SECONDS" => "0"},
          %{"ATOLL_SIGNUP_RETRY_DELAY_SECONDS" => "59"},
          %{"ATOLL_SIGNUP_RETRY_DELAY_SECONDS" => "86401"}
        ] do
      assert_raise ArgumentError, fn -> SignupRetries.config_from_env!(env) end
    end
  end

  test "one task at a time, deadline cancellation, shutdown and failure retry" do
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    handler = make_ref()

    :ok =
      :telemetry.attach(handler, [:atoll, :accounts, :signup_retry], &__MODULE__.report/4, owner)

    on_exit(fn -> :telemetry.detach(handler) end)
    counter = start_supervised!({Agent, fn -> 0 end})

    run = fn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          {:error, :database_unavailable}

        1 ->
          exit(:normal)

        _ ->
          send(owner, {:running, self()})

          receive do
            :finish -> {:ok, %{attempted: 1, completed: 1, failed: 0, did: "redact"}}
          end
      end
    end

    worker =
      start_supervised!(
        {SignupRetryWorker,
         [name: nil, task_supervisor: supervisor, run: run, interval: 60_000, start_after: 60_000]}
      )

    for _ <- 1..2 do
      tick(worker)
      assert_receive {:retry, :failed, %{runs: 1}}
    end

    tick(worker)
    assert_receive {:running, task}
    SignupRetryWorker.run_now(worker)
    state = :sys.get_state(worker)
    assert state.task.pid == task
    assert length(Task.Supervisor.children(supervisor)) == 1
    ref = Process.monitor(task)
    deadline = {:timeout, state.deadline, {:deadline, state.task.ref}}
    send(worker, deadline)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}
    assert_receive {:retry, :timeout, %{runs: 1}}
    send(worker, deadline)
    assert :sys.get_state(worker).task == nil
    tick(worker)
    assert_receive {:running, next}
    send(next, :finish)
    assert_receive {:retry, :ok, counts}
    assert counts == %{runs: 1, attempted: 1, completed: 1, failed: 0}
    tick(worker)
    assert_receive {:running, final}
    ref = Process.monitor(final)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^ref, :process, ^final, :killed}
  end

  defp tick(worker) do
    state = :sys.get_state(worker)
    send(worker, {:timeout, state.timer, :tick})
    :sys.get_state(worker)
  end
end
