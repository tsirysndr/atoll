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
