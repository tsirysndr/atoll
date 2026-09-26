defmodule Atoll.IdentityRefreshSweepTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Identity.RefreshWorker

  test "database cursor sweeps hosted repositories including inactive identities" do
    for did <- ["did:plc:z", "did:plc:a"] do
      assert {:ok, _} = Repositories.create(did, SigningKey.generate())
    end

    assert {:ok, _} = Repositories.set_status("did:plc:a", :deactivated)
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    owner = self()
    handler = make_ref()
    :ok = :telemetry.attach(handler, [:atoll, :identity, :refresh], &__MODULE__.report/4, owner)
    on_exit(fn -> :telemetry.detach(handler) end)

    worker =
      start_supervised!(
        {RefreshWorker,
         name: nil,
         task_supervisor: supervisor,
         refresh: fn _ -> {:ok, :unchanged} end,
         start_after: 60_000,
         spacing: 60_000,
         interval: 60_000}
      )

    for did <- ["did:plc:a", "did:plc:z"] do
      RefreshWorker.run_now(worker)
      assert_receive {:refreshed, ^did}
    end

    state = :sys.get_state(worker)
    send(worker, {:timeout, state.timer, :tick})
    assert :sys.get_state(worker).cursor == nil
    RefreshWorker.run_now(worker)
    assert_receive {:refreshed, "did:plc:a"}
  end

  def report(_, _, metadata, owner), do: send(owner, {:refreshed, metadata.did})
end
