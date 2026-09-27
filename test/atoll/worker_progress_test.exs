defmodule Atoll.WorkerProgressTest do
  use ExUnit.Case, async: false

  test "every scheduler reports its actual initial delay plus task timeout" do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:atoll, :worker, :scheduled],
        fn _, values, metadata, _ ->
          send(owner, {:progress, metadata.worker, values.deadline_seconds})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {module, worker} <- [
          {Atoll.Blobs.CleanupWorker, "blob_cleanup"},
          {Atoll.Accounts.CleanupWorker, "account_cleanup"},
          {Atoll.Accounts.SignupCleanupWorker, "signup_cleanup"},
          {Atoll.Accounts.SignupRetryWorker, "signup_retry"},
          {Atoll.Identity.RefreshWorker, "identity_refresh"},
          {Atoll.OAuth.KeyCheckWorker, "oauth_key_checks"},
          {Atoll.Repositories.EventRetentionWorker, "event_retention"},
          {Atoll.Relays.Worker, "relay_announcement"}
        ] do
      before = System.system_time(:millisecond)
      start_supervised!({module, name: __MODULE__.Worker, start_after: 60_000, timeout: 1000})
      assert_receive {:progress, ^worker, deadline}
      after_start = System.system_time(:millisecond)
      assert deadline >= div(before + 61_000 + 999, 1000)
      assert deadline <= div(after_start + 61_000 + 999, 1000)
      stop_supervised!(module)
    end
  end
end
