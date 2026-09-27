defmodule AtollWeb.OAuthPolicyTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{CID, OAuthFixture, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  alias AtollWeb.OAuthPolicyPlug
  @did "did:plc:oauthpolicy"
  @record %{"$type" => "com.example.record", "text" => "public"}

  setup do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, _} = Credentials.create(@did, "OAuth policy password")
    {:ok, pair} = Sessions.create(@did, "OAuth policy password")

    client =
      OAuthFixture.grant(
        pair,
        "atproto transition:generic account:email?action=manage identity:*"
      )

    %{pair: pair, client: client, key: key}
  end

  defp routes do
    AtollWeb.Router.__routes__()
    |> Enum.flat_map(fn route ->
      case route.path do
        "/xrpc/" <> nsid -> [{route.verb, nsid}]
        _ -> []
      end
    end)
    |> Kernel.++([{:get, "com.atproto.sync.subscribeRepos"}])
  end

  test "every local XRPC route has an explicit OAuth policy" do
    for {method, nsid} <- routes() do
      refute OAuthPolicyPlug.policy(nsid) == :unclassified, "missing policy for #{nsid}"
      if OAuthPolicyPlug.policy(nsid) == :public, do: assert(method == :get)
    end

    assert OAuthPolicyPlug.policy("com.example.future") == :unclassified
  end

  test "supplied invalid DPoP credentials are rejected on every public read before query parsing",
       c do
    for {_method, nsid} <- routes(), OAuthPolicyPlug.policy(nsid) == :public do
      path = "/xrpc/" <> nsid
      conn = OAuthFixture.conn(c.client, path, "GET") |> put_req_header("dpop", "invalid")
      response = get(conn, path <> "?unknown=malformed")
      assert response.status == 401, nsid
      assert [_] = get_resp_header(response, "dpop-nonce")
      assert [_] = get_resp_header(response, "www-authenticate")
    end
  end

  test "public reads consume proofs and retain anonymous access", c do
    path = "/xrpc/com.atproto.server.describeServer"
    anonymous = get(build_conn(), path) |> json_response(200)
    request = OAuthFixture.conn(c.client, path, "GET")
    first = get(request, path)
    assert json_response(first, 200) == anonymous
    assert get_resp_header(first, "cache-control") == ["no-store"]
    assert get(request, path) |> json_response(401) == %{"error" => "invalid_dpop_proof"}

    assert request
           |> put_req_header("authorization", "Bearer " <> c.client.token)
           |> get(path)
           |> json_response(401) == %{"error" => "invalid_token"}
  end

  test "every public route admits its proof once even when the query or upgrade is rejected", c do
    for {_method, nsid} <- routes(), OAuthPolicyPlug.policy(nsid) == :public do
      path = "/xrpc/" <> nsid
      request = OAuthFixture.conn(c.client, path, "GET")
      first = get(request, path <> "?unknown=invalid")
      assert first.status in [200, 400, 426], nsid

      assert get(request, path <> "?unknown=invalid") |> json_response(401) ==
               %{"error" => "invalid_dpop_proof"},
             nsid
    end
  end

  test "public identity resolution runs after admission and outside authorization locks", c do
    prior = Application.fetch_env(:atoll, :identity_resolution_options)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :identity_resolution_options, value)
        :error -> Application.delete_env(:atoll, :identity_resolution_options)
      end
    end)

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn name ->
        assert name == "_atproto.alice.example.com"
        refute Repo.in_transaction?()
        [["did=" <> @did]]
      end
    )

    path = "/xrpc/com.atproto.identity.resolveHandle"

    assert OAuthFixture.conn(c.client, path, "GET")
           |> get(path, %{handle: "alice.example.com"})
           |> json_response(200) == %{"did" => @did}
  end

  test "public repository reads do not gain inactive-owner access", c do
    path = "/xrpc/com.atproto.repo.getRecord"
    params = %{repo: @did, collection: "com.example.record", rkey: "self"}

    {:ok, _} =
      Repositories.apply_writes(@did, [{:put, "com.example.record/self", @record}], c.key)

    {:ok, record} = Repositories.get_record(@did, "com.example.record/self")
    result = OAuthFixture.conn(c.client, path, "GET") |> get(path, params) |> json_response(200)
    assert result["value"] == @record
    assert result["cid"] == CID.to_base32(record.cid)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert OAuthFixture.conn(c.client, path, "GET") |> get(path, params) |> json_response(401)
    assert get(build_conn(), path, params).status != 200
  end

  test "revoked OAuth credentials cannot silently downgrade to anonymous reads", c do
    assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    path = "/xrpc/com.atproto.sync.listRepos"
    assert OAuthFixture.conn(c.client, path, "GET") |> get(path) |> json_response(401)
    assert get(build_conn(), path) |> json_response(200)
  end

  test "non-OAuth endpoints deny valid grants before reading bodies and consume their proofs",
       c do
    sessions = Repo.aggregate(Atoll.Accounts.Session, :count)

    for {method, nsid} <- routes(), OAuthPolicyPlug.policy(nsid) == :non_oauth do
      path = "/xrpc/" <> nsid
      request = OAuthFixture.conn(c.client, path, method |> Atom.to_string() |> String.upcase())

      result =
        dispatch(
          request,
          @endpoint,
          method,
          path,
          if(method == :post, do: "invalid JSON", else: nil)
        )

      assert json_response(result, 403) == %{"error" => "insufficient_scope"}, nsid

      replay =
        dispatch(request, @endpoint, method, path, if(method == :post, do: "{}", else: nil))

      assert json_response(replay, 401) == %{"error" => "invalid_dpop_proof"}, nsid
    end

    assert Repo.aggregate(Atoll.Accounts.Session, :count) == sessions
    assert {:ok, %{status: :active}} = Repositories.get_head(@did)
  end

  test "resource endpoints keep their own admission without consuming proofs twice", c do
    path = "/xrpc/com.atproto.server.getSession"
    assert OAuthFixture.conn(c.client, path, "GET") |> get(path) |> json_response(200)
  end
end
