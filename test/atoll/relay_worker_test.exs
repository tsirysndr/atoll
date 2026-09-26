defmodule Atoll.RelayWorkerTest do
  use ExUnit.Case, async: false
  alias Atoll.Relays.Worker

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    owner = self()
    handler = make_ref()
    :ok = :telemetry.attach(handler, [:atoll, :relay, :announcement], &__MODULE__.report/4, owner)
    on_exit(fn -> :telemetry.detach(handler) end)
    %{supervisor: supervisor, owner: owner}
  end

  def report(_, counts, metadata, owner),
    do: send(owner, {:announcement, metadata.result, counts})

  test "scheduled batches announce every relay and retry unavailable relays on later passes", c do
    keys = [:relay_urls, :relay_request_options]
    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    Application.put_env(:atoll, :relay_urls, [
      "https://one.example.com",
      "https://two.example.com"
    ])

    Application.put_env(:atoll, :relay_request_options,
      hostname: "pds.example.com",
      plug: fn conn ->
        send(c.owner, {:requested, conn.host})
        Plug.Conn.send_resp(conn, if(conn.host == "one.example.com", do: 202, else: 503), "")
      end
    )

    worker = worker(c)

    for _ <- 1..2 do
      tick(worker)
      assert_receive {:requested, "one.example.com"}
      assert_receive {:requested, "two.example.com"}

      assert_receive {:announcement, :completed,
                      %{accepted: 1, unavailable: 1, host_banned: 0, rejected: 0, runs: 1}}

      assert :sys.get_state(worker).task == nil
    end
  end

  test "scheduler configuration is opt-in, bounded and disabled in tests" do
    assert Atoll.Relays.schedule_from_env!(%{}) == %{enabled: false, interval_seconds: 900}

    env = %{
      "ATOLL_RELAY_CRAWL_ENABLED" => "true",
      "ATOLL_RELAY_URLS" => "https://relay.example.com"
    }

    assert Atoll.Relays.schedule_from_env!(env).enabled
    refute Atoll.Relays.schedule_from_env!(env, true).enabled

    assert_raise ArgumentError, fn ->
      Atoll.Relays.schedule_from_env!(Map.delete(env, "ATOLL_RELAY_URLS"))
    end

    assert_raise ArgumentError, fn ->
      Atoll.Relays.schedule_from_env!(%{"ATOLL_RELAY_CRAWL_ENABLED" => "yes"})
    end

    for value <- ["0", "299", "86401", "900x", ""] do
      assert_raise ArgumentError, fn ->
        Atoll.Relays.schedule_from_env!(Map.put(env, "ATOLL_RELAY_CRAWL_INTERVAL_SECONDS", value))
      end
    end

    for value <- ["300", "86400"] do
      assert Atoll.Relays.schedule_from_env!(
               Map.put(env, "ATOLL_RELAY_CRAWL_INTERVAL_SECONDS", value)
             ).interval_seconds == String.to_integer(value)
    end
  end

  test "manual triggers do not overlap and a finished run schedules its successor", c do
    run = fn ->
      send(c.owner, {:running, self()})

      receive do
        :finish -> {:ok, %{accepted: 2, unavailable: 3}}
      end
    end

    worker = worker(c, run: run)
    Worker.run_now(worker)
    assert_receive {:running, task}
    Worker.run_now(worker)
    assert :sys.get_state(worker).task.pid == task
    assert length(Task.Supervisor.children(c.supervisor)) == 1
    send(task, :finish)
    assert_receive {:announcement, :completed, %{accepted: 2, unavailable: 3, runs: 1}}
    tick(worker)
    assert_receive {:running, _}
  end

  test "failed results and crashed tasks allow later batches", c do
    counter = start_supervised!({Agent, fn -> 0 end})

    run = fn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:error, :unavailable}
        1 -> exit(:normal)
        _ -> {:ok, %{accepted: 0, unavailable: 0}}
      end
    end

    worker = worker(c, run: run)

    for result <- [:failed, :failed, :completed] do
      Worker.run_now(worker)
      assert_receive {:announcement, ^result, _}
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
    assert_receive {:announcement, :timeout, %{runs: 1}}
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
