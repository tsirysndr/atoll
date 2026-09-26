defmodule AtollWeb.AdminAccountControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{AdminInfo, Invite, InviteControl, Invites, InviteUse, Profile, Sessions}
  @get "/xrpc/com.atproto.admin.getAccountInfo"
  @batch "/xrpc/com.atproto.admin.getAccountInfos"
  @did "did:web:admin-info.example.com"
  @secret "separate-operator-secret-for-account-info"

  setup %{conn: conn} do
    previous =
      Map.new([:admin_password, :session_signing_key], &{&1, Application.fetch_env(:atoll, &1)})

    Application.put_env(:atoll, :admin_password, @secret)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    profile = account(@did, "admin-info.example.com", "private@example.com")
    {:ok, pair} = Sessions.create_for_account(@did)
    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 64, div(id, 256), rem(id, 256)}},
      profile: profile,
      pair: pair
    }
  end

  test "returns complete private metadata and invite histories without allocating new invites",
       c do
    {:ok, owned} = Invites.create(2, @did)
    {:ok, origin} = Invites.create(1)
    now = DateTime.utc_now()
    Repo.insert!(%InviteUse{did: @did, code: origin.code, inserted_at: now})
    Repo.get!(Invite, origin.code) |> Ecto.Changeset.change(remaining: 0) |> Repo.update!()
    {:ok, _} = InviteControl.set(%{"account" => @did, "note" => "private control reason"}, true)

    c.profile
    |> Ecto.Changeset.change(
      email_confirmed_at: now,
      password_reset_digest: :binary.copy(<<1>>, 32),
      password_reset_requested_at: System.system_time(:second),
      password_reset_expires_at: System.system_time(:second) + 900
    )
    |> Repo.update!()

    seq = Atoll.Repositories.Events.latest_seq()
    result = auth(c.conn) |> get(@get, %{did: @did})
    assert get_resp_header(result, "cache-control") == ["no-store"]
    info = json_response(result, 200)
    assert info["did"] == @did
    assert info["handle"] == "admin-info.example.com"
    assert info["indexedAt"] == DateTime.to_iso8601(c.profile.inserted_at)
    assert info["email"] == "private@example.com"
    assert info["emailConfirmedAt"] == DateTime.to_iso8601(now)
    assert info["invitesDisabled"] == true
    assert info["inviteNote"] == "private control reason"
    assert [%{"code" => code, "available" => 2, "uses" => []}] = info["invites"]
    assert code == owned.code
    assert info["invitedBy"]["code"] == origin.code
    assert [%{"usedBy" => @did}] = info["invitedBy"]["uses"]

    assert Enum.sort(Map.keys(info)) ==
             Enum.sort(
               ~w(did handle indexedAt email emailConfirmedAt invites invitesDisabled inviteNote invitedBy)
             )

    assert Repo.aggregate(Invite, :count) == 2
    assert Atoll.Repositories.Events.latest_seq() == seq
  end

  test "batch lookup deduplicates in request order, includes inactive accounts, and omits unknown DIDs",
       c do
    other = "did:web:other-info.example.com"
    account(other, "other-info.example.com", nil)
    {:ok, _} = Repositories.set_status(@did, :takendown)
    {:ok, _} = Repositories.set_status(other, :deactivated)

    result =
      auth(c.conn)
      |> get(@batch, %{dids: [other, "did:web:missing.example.com", @did, other]})
      |> json_response(200)

    assert Enum.map(result["infos"], & &1["did"]) == [other, @did]
    refute Map.has_key?(hd(result["infos"]), "email")

    assert auth(c.conn)
           |> get(@batch, %{dids: ["did:web:missing.example.com"]})
           |> json_response(200) == %{"infos" => []}

    assert %{"error" => "NotFound"} =
             auth(c.conn)
             |> get(@get, %{did: "did:web:missing.example.com"})
             |> json_response(400)

    {:ok, _} = Repositories.create("did:plc:noaccountprofile", SigningKey.generate())
    assert auth(c.conn) |> get(@get, %{did: "did:plc:noaccountprofile"}) |> json_response(400)
    # Plain repeated query keys are supported as well as bracketed array encoding.
    query = URI.encode_query(%{"dids" => @did}) <> "&" <> URI.encode_query(%{"dids" => other})

    assert length((auth(c.conn) |> get(@batch <> "?" <> query) |> json_response(200))["infos"]) ==
             2
  end

  test "both routes authenticate before parsing, reject session tokens, and validate bounded input",
       c do
    for path <- [@get, @batch] do
      assert get(c.conn, path <> "?bad=%ZZ") |> json_response(401)

      assert c.conn
             |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
             |> get(path)
             |> json_response(401)

      assert auth(c.conn) |> post(path, %{}) |> json_response(405)
    end

    assert get(c.conn, "/xrpc/com.atproto.admin.%67etAccountInfo", %{did: @did})
           |> json_response(401)

    for params <- [%{}, %{did: "bad"}, %{did: @did, extra: "unexpected"}] do
      assert auth(c.conn) |> get(@get, params) |> json_response(400)
    end

    for params <- [
          %{},
          %{dids: ["bad"]},
          %{dids: List.duplicate(@did, 101)},
          %{dids: [@did], extra: "unexpected"}
        ] do
      assert auth(c.conn) |> get(@batch, params) |> json_response(400)
    end

    assert auth(c.conn) |> get(@get <> "?did=#{@did}&did=#{@did}") |> json_response(400)
    Application.delete_env(:atoll, :admin_password)
    assert auth(c.conn) |> get(@get, %{did: @did}) |> json_response(503)
  end

  test "oversized owned invitation history returns an error without truncation", c do
    now = DateTime.utc_now()

    rows =
      for n <- 1..1001 do
        %{
          code: Base.url_encode64(<<n::192>>, padding: false),
          use_count: 1,
          remaining: 1,
          disabled: false,
          for_account: @did,
          created_by: "admin",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Invite, rows)
    result = auth(c.conn) |> get(@get, %{did: @did}) |> json_response(400)
    assert result["error"] == "InvalidRequest"
    assert result["message"] =~ "history is too large"
    assert Repo.aggregate(Invite, :count) == 1001
  end

  test "shared invitation usage is counted each time it would appear in the batch response" do
    other = "did:web:shared-origin.example.com"
    account(other, "shared-origin.example.com", nil)
    {:ok, origin} = Invites.create(5001)
    now = DateTime.utc_now()

    uses =
      for did <- [@did, other | Enum.map(1..4999, &"did:plc:historic#{&1}")],
          do: %{did: did, code: origin.code, inserted_at: now}

    Repo.insert_all(InviteUse, uses)
    Repo.get!(Invite, origin.code) |> Ecto.Changeset.change(remaining: 0) |> Repo.update!()
    assert {:ok, info} = AdminInfo.get(%{"did" => @did})
    assert length(info.invitedBy.uses) == 5001
    assert {:error, :account_info_too_large} = AdminInfo.list(%{"dids" => [@did, other]})
  end

  test "private account reads share the operator request rate limit", c do
    for _ <- 1..60, do: assert(get(c.conn, @get, %{did: @did}) |> json_response(401))
    result = auth(c.conn) |> get(@batch, %{dids: [@did]})
    assert json_response(result, 429)["error"] == "RateLimitExceeded"
    assert get_resp_header(result, "retry-after") != []
  end

  defp account(did, handle, email) do
    {:ok, _} = Repositories.create(did, SigningKey.generate())
    Repo.insert!(%Profile{did: did, handle: handle, email: email})
  end

  defp auth(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> @secret))
end
