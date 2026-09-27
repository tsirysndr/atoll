defmodule Atoll.WorkerInventoryTest do
  use ExUnit.Case, async: false

  @settings [
    :account_cleanup_enabled,
    :blob_cleanup_enabled,
    :event_retention_enabled,
    :identity_refresh_enabled,
    :oauth_key_checks,
    :relay_crawl_enabled,
    :signup_cleanup,
    :signup_retry
  ]

  setup do
    previous = Map.new(@settings, &{&1, Application.fetch_env(:atoll, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    :ok
  end

  test "expectations follow the same defaults and option maps as supervision" do
    for key <- @settings, do: Application.delete_env(:atoll, key)
    initial = Map.new(Atoll.WorkerProgress.inventory(), &{&1.worker, &1.expected})
    assert map_size(initial) == 8
    assert initial["oauth_key_checks"] == 1

    assert Enum.all?(Map.delete(initial, "oauth_key_checks"), fn {_, expected} ->
             expected == 0
           end)

    for key <- @settings do
      value =
        if key in [:oauth_key_checks, :signup_cleanup, :signup_retry],
          do: [enabled: true],
          else: true

      Application.put_env(:atoll, key, value)
    end

    assert Enum.all?(Atoll.WorkerProgress.inventory(), &(&1.expected == 1))

    for key <- @settings do
      value =
        if key in [:oauth_key_checks, :signup_cleanup, :signup_retry],
          do: [enabled: false],
          else: false

      Application.put_env(:atoll, key, value)
    end

    assert Enum.all?(Atoll.WorkerProgress.inventory(), &(&1.expected == 0))
  end

  test "scrapes distinguish a never-started configured worker from an actual registered process" do
    Application.put_env(:atoll, :blob_cleanup_enabled, true)
    start_supervised!({Atoll.Metrics, name: __MODULE__.Metrics})
    assert blob() == %{worker: "blob_cleanup", expected: 1, present: 0}
    text = Atoll.Metrics.render(__MODULE__.Metrics)
    assert text =~ ~s(atoll_worker_expected{worker="blob_cleanup"} 1\n)
    assert text =~ ~s(atoll_worker_present{worker="blob_cleanup"} 0\n)

    worker = start_supervised!({Atoll.Blobs.CleanupWorker, start_after: 60_000})
    assert blob().present == 1

    assert Atoll.Metrics.render(__MODULE__.Metrics) =~
             ~s(atoll_worker_present{worker="blob_cleanup"} 1\n)

    :sys.suspend(worker)

    try do
      # Presence is deliberately not a synchronous health request to the worker.
      assert Atoll.Metrics.render(__MODULE__.Metrics) =~
               ~s(atoll_worker_present{worker="blob_cleanup"} 1\n)
    after
      :sys.resume(worker)
    end

    stop_supervised!(Atoll.Blobs.CleanupWorker)
    assert blob().present == 0

    stop_supervised!(Atoll.Metrics)
    start_supervised!({Atoll.Metrics, name: __MODULE__.Metrics})
    text = Atoll.Metrics.render(__MODULE__.Metrics)
    assert text =~ ~s(atoll_worker_expected{worker="blob_cleanup"} 1\n)
    assert text =~ ~s(atoll_worker_present{worker="blob_cleanup"} 0\n)
    assert text =~ ~s(atoll_worker_progress_deadline_seconds{worker="blob_cleanup"} 0\n)
    assert length(Regex.scan(~r/^atoll_worker_expected\{/m, text)) == 8
    assert length(Regex.scan(~r/^atoll_worker_present\{/m, text)) == 8
  end

  defp blob, do: Enum.find(Atoll.WorkerProgress.inventory(), &(&1.worker == "blob_cleanup"))
end
