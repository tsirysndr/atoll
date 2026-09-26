defmodule Atoll.InviteAllocationTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.{Invite, InviteAllocation, InviteListing, Invites, Profile, Sessions}
  @did "did:web:earned.example.com"

  setup do
    previous =
      Map.new(
        [:invite_code_required, :invite_allocation, :session_signing_key],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :invite_code_required, true)
    Application.put_env(:atoll, :invite_allocation, interval_seconds: 3600, max_open: 2)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    now = DateTime.utc_now()
    {:ok, _} = Repositories.create(@did, SigningKey.generate())

    Repo.insert!(%Profile{
      did: @did,
      handle: "earned.example.com",
      email: "earned@example.com",
      email_confirmed_at: now,
      inserted_at: DateTime.add(now, -10 * 3600)
    })

    {:ok, pair} = Sessions.create_for_account(@did)
    %{now: now, pair: pair}
  end

  test "earned codes respect the open cap, exclude gifts, and retain their creator", c do
    {:ok, %{code: gift}} = Invites.create(100, @did)
    assert {:ok, 2} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    assert Repo.get!(Invite, gift).created_by == "admin"
    [first, second] = Repo.all(from i in Invite, where: i.created_by == ^@did)
    assert first.use_count == 1 and second.use_count == 1
    assert first.for_account == @did
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(@did, first.code) end)
    assert {:ok, 1} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    assert Repo.aggregate(from(i in Invite, where: i.created_by == ^@did), :count) == 3

    assert Repo.aggregate(
             from(i in Invite, where: i.created_by == ^@did and i.remaining > 0),
             :count
           ) == 2

    assert Repo.get!(Invite, gift).remaining == 100
  end

  test "interval boundaries, future creation times and disabled codes cannot grant unearned credits",
       c do
    set_created(DateTime.add(c.now, -3599))
    assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    set_created(DateTime.add(c.now, -3600))
    assert {:ok, 1} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    code = Repo.one!(Invite).code
    Invites.disable(code)
    assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)

    assert {:ok, 1} =
             Repo.transaction(fn ->
               InviteAllocation.allocate!(@did, DateTime.add(c.now, 3600))
             end)

    set_created(DateTime.add(c.now, 3600))
    assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
  end

  test "allocation requires active status, confirmed email, invite policy and an interval", c do
    profile = Repo.get!(Profile, @did)
    Repo.update_all(Profile, set: [email_confirmed_at: nil])
    assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    Repo.update_all(Profile, set: [email_confirmed_at: profile.email_confirmed_at])

    for status <- [:deactivated, :takendown, :suspended] do
      Repositories.set_status(@did, status)
      assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    end

    Repositories.set_status(@did, :active)
    Application.put_env(:atoll, :invite_code_required, false)
    assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    Application.put_env(:atoll, :invite_code_required, true)
    Application.put_env(:atoll, :invite_allocation, interval_seconds: 0, max_open: 2)
    assert {:ok, 0} = Repo.transaction(fn -> InviteAllocation.allocate!(@did, c.now) end)
    assert Repo.aggregate(Invite, :count) == 0
  end

  test "createAvailable controls transactional allocation in the authenticated listing", c do
    assert {:ok, %{codes: []}} =
             InviteListing.account(c.pair.access_jwt, %{"createAvailable" => "false"})

    assert {:ok, %{codes: codes}} = InviteListing.account(c.pair.access_jwt, %{})
    assert length(codes) == 2
    assert Enum.all?(codes, &(&1.createdBy == @did))
    assert {:ok, %{codes: ^codes}} = InviteListing.account(c.pair.access_jwt, %{})

    assert {:error, :cancel} =
             Repo.transaction(fn ->
               Repo.update_all(Invite, set: [disabled: true])
               assert 2 == InviteAllocation.allocate!(@did, c.now)
               Repo.rollback(:cancel)
             end)

    assert Repo.aggregate(Invite, :count) == 2
    refute Repo.exists?(from i in Invite, where: i.disabled)
  end

  test "owner moderation or deletion rejects new redemptions without refunding prior use" do
    {:ok, %{code: code}} = Invites.create(2, @did)
    recipient = "did:web:recipient.example.com"
    {:ok, _} = Repositories.create(recipient, SigningKey.generate())

    for status <- [:takendown, :suspended] do
      Repositories.set_status(@did, status)
      assert {:error, :invalid_invite_code} = Invites.validate_new(code)

      assert {:error, :invalid_invite_code} =
               Repo.transaction(fn -> Invites.consume!(recipient, code) end)
    end

    Repositories.set_status(@did, :deactivated)
    assert :ok = Invites.validate_new(code)
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(recipient, code) end)
    Repo.delete!(Repo.get!(Atoll.Repositories.Head, @did))
    assert {:error, :invalid_invite_code} = Invites.validate_new(code)
    assert Invites.retry?(recipient, code)
    assert Repo.get!(Invite, code).remaining == 1
  end

  test "configuration and internal transaction requirements are validated" do
    assert InviteAllocation.config_from_env!(%{}) == [interval_seconds: 0, max_open: 5]

    for env <- [
          %{"ATOLL_INVITE_INTERVAL_SECONDS" => "59"},
          %{"ATOLL_INVITE_INTERVAL_SECONDS" => "bad"},
          %{"ATOLL_INVITE_MAX_OPEN" => "0"},
          %{"ATOLL_INVITE_MAX_OPEN" => "1001"}
        ] do
      assert_raise RuntimeError, fn -> InviteAllocation.config_from_env!(env) end
    end

    assert_raise ArgumentError, fn -> InviteAllocation.allocate!(@did) end
    Application.put_env(:atoll, :invite_allocation, interval_seconds: -1, max_open: 2)

    assert {:error, :invalid_invite_allocation} =
             Repo.transaction(fn -> InviteAllocation.allocate!(@did) end)
  end

  defp set_created(time), do: Repo.update_all(Profile, set: [inserted_at: time])
end
