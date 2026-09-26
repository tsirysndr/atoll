defmodule Atoll.InvitesTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{Invite, Invites, InviteUse}
  alias Atoll.Repositories.Head
  alias Atoll.{Repositories, SigningKey}

  setup do
    previous = Application.fetch_env(:atoll, :invite_code_required)
    Application.put_env(:atoll, :invite_code_required, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :invite_code_required, value)
        :error -> Application.delete_env(:atoll, :invite_code_required)
      end
    end)

    :ok
  end

  test "limited uses are idempotent per DID and deletion never refunds a redemption" do
    first = account("one")
    second = account("two")
    third = account("three")
    assert {:ok, %{code: code}} = Invites.create(2, first)
    assert byte_size(code) == 32
    refute inspect(Repo.get!(Invite, code)) =~ code
    assert :ok = Invites.validate_new(code)
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(first, code) end)
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(first, code) end)
    assert Repo.get!(Invite, code).remaining == 1
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(second, code) end)
    assert Repo.get!(Invite, code).remaining == 0

    assert {:error, :invalid_invite_code} =
             Repo.transaction(fn -> Invites.consume!(third, code) end)

    assert {:error, :invalid_invite_code} = Invites.validate_new(code)
    Repo.delete!(Repo.get!(Head, first))
    assert Repo.get!(Invite, code).remaining == 0
    assert Repo.get!(InviteUse, first).code == code
  end

  test "rollback restores a use and a post-preflight disable is checked at redemption" do
    did = account("rollback")
    {:ok, %{code: code}} = Invites.create()

    assert {:error, :cancel} =
             Repo.transaction(fn ->
               assert :ok = Invites.consume!(did, code)
               Repo.rollback(:cancel)
             end)

    assert Repo.get!(Invite, code).remaining == 1
    refute Repo.get(InviteUse, did)
    assert :ok = Invites.validate_new(code)
    assert {:ok, :disabled} = Invites.disable(code)
    assert {:ok, :disabled} = Invites.disable(code)

    assert {:error, :invalid_invite_code} =
             Repo.transaction(fn -> Invites.consume!(did, code) end)

    assert Repo.get!(Invite, code).remaining == 1
  end

  test "policy, malformed codes, issuance bounds, and transaction boundary fail closed" do
    did = account("bounds")
    assert {:error, :invalid_invite_code} = Invites.validate_new(nil)
    Application.put_env(:atoll, :invite_code_required, false)
    assert :ok = Invites.validate_new(nil)

    for code <- ["", "bad", 12, String.duplicate("!", 32), String.duplicate("a", 32)] do
      assert {:error, :invalid_invite_code} = Invites.validate_new(code)
    end

    for count <- [0, -1, 10_001, 1.5, "1"] do
      assert {:error, :invalid_request} = Invites.create(count)
    end

    assert {:error, :account_not_found} = Invites.create(1, "did:web:missing.example.com")
    assert {:error, :invalid_request} = Invites.create(1, "invalid")
    assert_raise ArgumentError, fn -> Invites.consume!(did, nil) end
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(did, nil) end)
    assert Invites.retry?(did, nil)
  end

  test "a reserved signup retains authorization after code disable or a stricter policy" do
    did = account("retry")
    {:ok, %{code: code}} = Invites.create()
    {:ok, %{code: other}} = Invites.create()
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(did, code) end)
    Invites.disable(code)
    assert Invites.retry?(did, code)
    refute Invites.retry?(did, other)
    refute Invites.retry?(did, nil)

    assert {:error, :invalid_invite_code} =
             Repo.transaction(fn -> Invites.consume!(did, other) end)

    assert Repo.get!(Invite, other).remaining == 1
  end

  test "operator task prints a real invitation and rejects duplicate or invalid options" do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    Mix.Tasks.Atoll.Invites.Create.run(["--uses", "3"])
    assert_receive {:mix_shell, :info, [output]}
    result = Jason.decode!(output)
    assert Repo.get!(Invite, result["code"]).remaining == 3

    for args <- [["--uses", "0"], ["--uses", "1", "--uses", "2"], ["--unknown"], ["extra"]] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Invites.Create.run(args) end
    end

    assert Repo.aggregate(Invite, :count) == 1
  end

  defp account(name) do
    did = "did:web:#{name}.example.com"
    {:ok, _} = Repositories.create(did, SigningKey.generate())
    did
  end
end
