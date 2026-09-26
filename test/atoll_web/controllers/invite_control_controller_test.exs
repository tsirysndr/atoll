defmodule AtollWeb.InviteControlControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Invite, InviteControl, InviteListing, Invites, Profile, Sessions}
  @did "did:web:controlled.example.com"
  @disable "/xrpc/com.atproto.admin.disableAccountInvites"
  @enable "/xrpc/com.atproto.admin.enableAccountInvites"
  @secret "independent-invite-control-admin-secret"

  setup %{conn: conn} do
    previous =
      Map.new(
        [:admin_password, :session_signing_key, :invite_code_required, :invite_allocation],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :admin_password, @secret)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :invite_code_required, true)
    Application.put_env(:atoll, :invite_allocation, interval_seconds: 3600, max_open: 2)

    on_exit(fn ->
      for {name, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end
    end)

    now = DateTime.utc_now()
    {:ok, _} = Repositories.create(@did, SigningKey.generate())

    Repo.insert!(%Profile{
      did: @did,
      handle: "controlled.example.com",
      email: "owner@example.com",
      email_confirmed_at: now,
      inserted_at: DateTime.add(now, -36_000)
    })

    {:ok, pair} = Sessions.create_for_account(@did)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 59, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "disabling pauses allocation without revoking codes or sessions, and enabling restores it",
       c do
    {:ok, %{codes: [first, _]}} = InviteListing.account(c.pair.access_jwt, %{})

    assert request(admin(c.conn), @disable, %{account: @did, note: "private operator reason"})
           |> response(200) == ""

    profile = Repo.get!(Profile, @did)
    assert profile.invites_disabled
    assert profile.invite_control_note == "private operator reason"
    refute inspect(profile) =~ "private operator reason"
    assert :ok = Invites.validate_new(first.code)
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(@did, first.code) end)
    assert {:ok, %{codes: codes}} = InviteListing.account(c.pair.access_jwt, %{})
    assert length(codes) == 2
    assert Repo.aggregate(Invite, :count) == 2
    refute Jason.encode!(codes) =~ "private operator reason"
    assert {:ok, %{did: @did}} = Sessions.authenticate(c.pair.access_jwt)
    assert request(admin(c.conn), @enable, %{account: @did}) |> response(200) == ""
    refute Repo.get!(Profile, @did).invites_disabled
    assert Repo.get!(Profile, @did).invite_control_note == nil
    assert {:ok, %{codes: codes}} = InviteListing.account(c.pair.access_jwt, %{})
    assert length(codes) == 3
    assert Repo.get!(Invite, first.code).remaining == 0
  end

  test "repeated controls are idempotent and do not change account status", c do
    params = %{account: @did, note: "review"}
    assert response(request(admin(c.conn), @disable, params), 200) == ""
    first = Repo.get!(Profile, @did)
    assert response(request(admin(c.conn), @disable, params), 200) == ""
    assert Repo.get!(Profile, @did).invites_updated_at == first.invites_updated_at
    assert Repo.get!(Atoll.Repositories.Head, @did).status == :active
    {:ok, %{code: gift}} = Invites.create(1, @did)
    assert :ok = Invites.validate_new(gift)

    assert {:error, :cancel} =
             Repo.transaction(fn ->
               assert {:ok, :updated} = InviteControl.set(%{"account" => @did}, false)
               Repo.rollback(:cancel)
             end)

    assert Repo.get!(Profile, @did).invites_disabled
  end

  test "both methods require operator auth and validate account and private notes", c do
    for path <- [@disable, @enable] do
      assert request(c.conn, path, %{account: @did}) |> json_response(401)
      user = put_req_header(c.conn, "authorization", "Bearer " <> c.pair.access_jwt)
      assert request(user, path, %{account: @did}) |> json_response(401)
      assert admin(c.conn) |> get(path) |> json_response(405)

      for params <- [
            %{},
            %{account: "invalid"},
            %{account: @did, note: 1},
            %{account: @did, note: String.duplicate("x", 2001)},
            %{account: @did, note: <<0>>},
            %{account: @did, extra: true}
          ] do
        assert request(admin(c.conn), path, params) |> json_response(400)
      end

      assert request(admin(c.conn), path, %{account: "did:web:missing.example.com"})
             |> json_response(400)
    end

    refute Repo.get!(Profile, @did).invites_disabled
    result = request(admin(c.conn), @disable, %{account: @did})
    assert get_resp_header(result, "cache-control") == ["no-store"]
  end

  defp admin(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> @secret))

  defp request(conn, path, params),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(params))
end
