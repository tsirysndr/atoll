defmodule Atoll.AdminInvitesTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{AdminInvites, Invite, Invites}
  alias Atoll.Moderation.Audit

  test "an outer rollback discards both issuance and its audit entry" do
    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} = AdminInvites.create(%{"useCount" => 1})
               assert {:ok, %{entries: [_]}} = Audit.list()
               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(Invite, :count) == 0
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "operator issuance audit failure rolls back the invitation and prints no code" do
    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_invite_audit CHECK (operation <> 'com.atproto.server.createInviteCode')"
    )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert_raise Ecto.ConstraintError, fn -> Mix.Tasks.Atoll.Invites.Create.run([]) end
      end)

    assert output == ""
    assert Repo.aggregate(Invite, :count) == 0
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "operator issuance keeps owner attribution and rejects caller-supplied actor fields" do
    did = "did:plc:operatorinvites"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())

    assert {:ok, result} =
             AdminInvites.create(%{"useCount" => 2, "forAccount" => did}, "operator")

    assert result.forAccount == did
    assert {:ok, %{entries: [entry]}} = Audit.list()
    assert entry.did == did
    assert entry.actor == "operator"
    assert entry.requested == %{"useCount" => 2, "forAccount" => did}

    assert {:error, :invalid_request} =
             AdminInvites.create(%{"useCount" => 1, "actor" => "operator"})

    assert {:error, :invalid_request} = AdminInvites.create(%{"useCount" => 1}, "unknown")
    assert Repo.aggregate(Invite, :count) == 1
  end

  test "revocation and audit roll back together; internal setup is not attributed to admin" do
    {:ok, %{code: code}} = Invites.create()
    assert {:ok, %{entries: []}} = Audit.list()

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, 1} = AdminInvites.disable(%{"codes" => [code]})
               assert Repo.get!(Invite, code).disabled
               Repo.rollback(:cancelled)
             end)

    refute Repo.get!(Invite, code).disabled
    assert {:ok, %{entries: []}} = Audit.list()
  end
end
