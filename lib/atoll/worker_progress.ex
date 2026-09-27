defmodule Atoll.WorkerProgress do
  @moduledoc "Reports when a scheduled worker must next make progress, including its task timeout."

  @workers [
    {"account_cleanup", Atoll.Accounts.CleanupWorker, {:account_cleanup_enabled, false}},
    {"blob_cleanup", Atoll.Blobs.CleanupWorker, {:blob_cleanup_enabled, false}},
    {"event_retention", Atoll.Repositories.EventRetentionWorker,
     {:event_retention_enabled, false}},
    {"identity_refresh", Atoll.Identity.RefreshWorker, {:identity_refresh_enabled, false}},
    {"oauth_key_checks", Atoll.OAuth.KeyCheckWorker, {:oauth_key_checks, :enabled, true}},
    {"relay_announcement", Atoll.Relays.Worker, {:relay_crawl_enabled, false}},
    {"signup_cleanup", Atoll.Accounts.SignupCleanupWorker, {:signup_cleanup, :enabled, false}},
    {"signup_retry", Atoll.Accounts.SignupRetryWorker, {:signup_retry, :enabled, false}}
  ]

  @doc "Reads configured worker expectations and local registered process presence without messaging workers."
  def inventory do
    Enum.map(@workers, fn {worker, module, setting} ->
      %{
        worker: worker,
        expected: if(configured(setting) in [false, nil], do: 0, else: 1),
        present: if(is_pid(Process.whereis(module)), do: 1, else: 0)
      }
    end)
  end

  defp configured({key, default}), do: Application.get_env(:atoll, key, default)

  defp configured({key, option, default}),
    do: Application.get_env(:atoll, key, []) |> Keyword.get(option, default)

  def scheduled(worker, delay_ms, timeout_ms)
      when is_binary(worker) and is_integer(delay_ms) and delay_ms >= 0 and
             is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = div(System.system_time(:millisecond) + delay_ms + timeout_ms + 999, 1000)

    :telemetry.execute([:atoll, :worker, :scheduled], %{deadline_seconds: deadline}, %{
      worker: worker
    })
  end
end
