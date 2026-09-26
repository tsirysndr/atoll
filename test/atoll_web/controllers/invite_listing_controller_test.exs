defmodule AtollWeb.InviteListingControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{AppPasswords, Invite, Invites, InviteUse, Sessions}
  @admin "/xrpc/com.atproto.admin.getInviteCodes"
  @account "/xrpc/com.atproto.server.getAccountInviteCodes"
  @did "did:web:owner.example.com"
  @secret "separate-admin-password-long-enough-for-tests"

  setup %{conn: conn} do
    previous =
      Map.new(
        [:admin_password, :session_signing_key, :invite_code_required, :invite_allocation],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :invite_code_required, false)
    Application.put_env(:atoll, :invite_allocation, interval_seconds: 0, max_open: 5)
    Application.put_env(:atoll, :admin_password, @secret)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {name, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    {:ok, pair} = Sessions.create_for_account(@did)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 58, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "admin recent pagination has deterministic ties and complete protocol metadata", c do
    {:ok, result} = Invites.create_many(%{"codeCount" => 3, "useCount" => 2})
    [%{codes: codes}] = result
    now = DateTime.utc_now()
    Repo.update_all(Invite, set: [inserted_at: now])
    # PostgreSQL collation need not match Elixir byte ordering. Compare the cursor
    # traversal with one unpaginated database result, including equal timestamps.
    expected =
      Repo.query!("SELECT code FROM invite_codes ORDER BY code ASC", [], log: false).rows
      |> List.flatten()

    assert Enum.sort(expected) == Enum.sort(codes)
    one = admin(c) |> get(@admin, %{limit: 1}) |> json_response(200)
    two = admin(c) |> get(@admin, %{limit: 1, cursor: one["cursor"]}) |> json_response(200)
    three = admin(c) |> get(@admin, %{limit: 1, cursor: two["cursor"]}) |> json_response(200)
    assert Enum.map([one, two, three], &hd(&1["codes"])["code"]) == expected
    refute three["cursor"]

    assert %{
             "available" => 2,
             "disabled" => false,
             "forAccount" => "admin",
             "createdBy" => "admin",
             "createdAt" => _,
             "uses" => []
           } = hd(one["codes"])

    assert admin(c) |> get(@admin, %{sort: "usage", cursor: one["cursor"]}) |> json_response(400)
  end

  test "usage sorting returns real redemption history and original allowance", c do
    {:ok, %{code: unused}} = Invites.create(3, @did)
    {:ok, %{code: used}} = Invites.create(2, @did)
    assert {:ok, :ok} = Repo.transaction(fn -> Invites.consume!(@did, used) end)
    result = admin(c) |> get(@admin, %{sort: "usage", limit: 1}) |> json_response(200)

    assert [%{"code" => ^used, "available" => 2, "uses" => [%{"usedBy" => @did, "usedAt" => _}]}] =
             result["codes"]

    next =
      admin(c) |> get(@admin, %{sort: "usage", cursor: result["cursor"]}) |> json_response(200)

    assert [%{"code" => ^unused}] = next["codes"]
    assert Repo.get!(Invite, used).remaining == 1
  end

  test "account listing is owner-scoped, filters exhausted codes, and rejects app sessions", c do
    {:ok, %{code: owned}} = Invites.create(1, @did)
    {:ok, %{code: exhausted}} = Invites.create(1, @did)
    {:ok, %{code: unowned}} = Invites.create()
    Repo.transaction(fn -> Invites.consume!(@did, exhausted) end)
    Invites.disable(owned)
    full = bearer(c.conn, c.pair.access_jwt)
    result = get(full, @account) |> json_response(200)
    assert Enum.sort(Enum.map(result["codes"], & &1["code"])) == Enum.sort([owned, exhausted])
    refute Enum.any?(result["codes"], &(&1["code"] == unowned))

    filtered =
      get(full, @account, %{includeUsed: false, createAvailable: true}) |> json_response(200)

    assert [%{"code" => ^owned, "disabled" => true}] = filtered["codes"]
    assert Repo.aggregate(Invite, :count) == 3
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "restricted"})
    {:ok, restricted} = Sessions.create(@did, app.password)
    assert bearer(c.conn, restricted.access_jwt) |> get(@account) |> json_response(403)
    assert get(c.conn, @account) |> json_response(401)
    assert admin(c) |> get(@account) |> json_response(401)
    assert full |> get(@admin) |> json_response(401)
    assert get(full, @account, %{includeUsed: "yes"}) |> json_response(400)
    assert get(full, @account, %{did: "did:web:other.example.com"}) |> json_response(400)
    assert get_resp_header(get(full, @account), "cache-control") == ["no-store"]
  end

  test "admin pages adapt to large histories without truncating individual uses", c do
    {:ok, %{code: first}} = Invites.create(6000, @did)
    {:ok, %{code: second}} = Invites.create(6000, @did)
    now = DateTime.utc_now()
    Repo.update_all(Invite, set: [remaining: 0])

    for {code, prefix} <- [{first, "a"}, {second, "b"}] do
      rows =
        Enum.map(
          1..6000,
          &%{code: code, did: "did:web:#{prefix}#{&1}.example.com", inserted_at: now}
        )

      Repo.insert_all(InviteUse, rows, log: false)
    end

    one = admin(c) |> get(@admin, %{limit: 500}) |> json_response(200)
    assert [entry] = one["codes"]
    assert length(entry["uses"]) == 6000
    two = admin(c) |> get(@admin, %{limit: 500, cursor: one["cursor"]}) |> json_response(200)
    assert [next] = two["codes"]
    assert next["code"] != entry["code"]
    assert length(next["uses"]) == 6000
    refute two["cursor"]
    assert bearer(c.conn, c.pair.access_jwt) |> get(@account) |> json_response(400)
  end

  test "oversized account code sets are rejected instead of silently truncated", c do
    now = DateTime.utc_now()

    rows =
      Enum.map(1..1001, fn _ ->
        %{
          code: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
          use_count: 1,
          remaining: 1,
          for_account: @did,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Invite, rows, log: false)
    assert bearer(c.conn, c.pair.access_jwt) |> get(@account) |> json_response(400)
    assert length((admin(c) |> get(@admin, %{limit: 500}) |> json_response(200))["codes"]) == 500
  end

  test "HTTP createAvailable creates earned codes only for an eligible full-session owner", c do
    now = DateTime.utc_now()

    Repo.insert!(%Atoll.Accounts.Profile{
      did: @did,
      handle: "owner.example.com",
      email: "owner@example.com",
      email_confirmed_at: now,
      inserted_at: DateTime.add(now, -7200)
    })

    Application.put_env(:atoll, :invite_code_required, true)
    Application.put_env(:atoll, :invite_allocation, interval_seconds: 3600, max_open: 2)
    full = bearer(c.conn, c.pair.access_jwt)

    assert get(full, @account, %{createAvailable: false}) |> json_response(200) == %{
             "codes" => []
           }

    result = get(full, @account) |> json_response(200)
    assert length(result["codes"]) == 2
    assert Enum.all?(result["codes"], &(&1["createdBy"] == @did and &1["available"] == 1))
    assert get(full, @account) |> json_response(200) == result
  end

  test "query methods enforce authentication, cursors, limits and empty bodies", c do
    assert get(c.conn, @admin) |> json_response(401)

    for params <- [
          %{limit: 0},
          %{limit: 501},
          %{sort: "invalid"},
          %{cursor: "bad"},
          %{cursor: String.duplicate("a", 513)},
          %{unknown: true}
        ] do
      assert admin(c) |> get(@admin, params) |> json_response(400)
    end

    assert admin(c) |> post(@admin) |> json_response(405)

    assert admin(c)
           |> put_req_header("content-type", "application/json")
           |> get(@admin, "{}")
           |> json_response(400)

    assert admin(c)
           |> put_req_header("content-type", "application/json")
           |> get(@admin, String.duplicate("x", 16_385))
           |> json_response(413)

    empty = admin(c) |> get(@admin)
    assert json_response(empty, 200) == %{"codes" => []}
    assert get_resp_header(empty, "cache-control") == ["no-store"]
  end

  defp admin(c),
    do: put_req_header(c.conn, "authorization", "Basic " <> Base.encode64("admin:" <> @secret))

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
