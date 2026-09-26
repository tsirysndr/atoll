defmodule AtollWeb.ServiceAuthControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{KeyVault, Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:serviceauth"
  @aud "did:web:appview.example.com"
  @route "/xrpc/com.atproto.server.getServiceAuth"

  setup %{conn: conn} do
    keys = [:session_signing_key, :key_encryption_key]
    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})
    for key <- keys, do: Application.put_env(:atoll, key, :binary.copy(<<26>>, 32))

    on_exit(fn ->
      for {key, prior} <- previous do
        case prior do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, :stored} = KeyVault.store(@did, key)
    {:ok, _} = Credentials.create(@did, "service auth password")
    {:ok, pair} = Sessions.create(@did, "service auth password")
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 43, div(id, 256), rem(id, 256)}}, key: key, pair: pair}
  end

  test "issues a verifiable ES256K token with unique IDs and a default minute lifetime", c do
    result = query(c, %{aud: @aud})
    assert get_resp_header(result, "cache-control") == ["no-store"]
    %{"token" => token} = json_response(result, 200)
    {header, claims} = verify(token, c.key)
    assert header == %{"alg" => "ES256K", "typ" => "JWT"}
    assert claims["iss"] == @did
    assert claims["aud"] == @aud
    assert claims["exp"] - claims["iat"] == 60
    assert abs(claims["iat"] - System.system_time(:second)) <= 2
    assert byte_size(claims["jti"]) == 32
    refute Map.has_key?(claims, "lxm")
    %{"token" => another} = query(c, %{aud: @aud}) |> json_response(200)
    {_, second} = verify(another, c.key)
    refute second["jti"] == claims["jti"]
    assert {:error, :invalid_token} = Sessions.authenticate(token)
  end

  test "supports P-256 signing, service references and method-bound expiration", c do
    did = "did:plc:p256service"
    key = SigningKey.generate(:p256)
    {:ok, _} = Repositories.create(did, key)
    {:ok, :stored} = KeyVault.store(did, key)
    {:ok, _} = Credentials.create(did, "service auth password")
    {:ok, pair} = Sessions.create(did, "service auth password")
    expiry = System.system_time(:second) + 3500
    params = %{aud: @aud <> "#bsky_appview", lxm: "app.bsky.feed.getTimeline", exp: expiry}
    %{"token" => token} = query(%{c | pair: pair}, params) |> json_response(200)
    {header, claims} = verify(token, key)
    assert header["alg"] == "ES256"
    assert claims["iss"] == did
    assert claims["aud"] == params.aud
    assert claims["lxm"] == params.lxm
    assert claims["exp"] == expiry
  end

  test "rejects malformed audiences, protected methods and invalid expiration", c do
    for audience <- ["not-a-did", @aud <> "#", @aud <> "#one#two", @aud <> "#bad%", [@aud]] do
      assert query(c, %{aud: audience}) |> json_response(400)
    end

    for method <- [
          "not-a-method",
          "com.atproto.server.getSession",
          "COM.ATPROTO.SERVER.GETSESSION",
          "com.atproto.identity.signPlcOperation"
        ] do
      assert %{"error" => "InvalidRequest"} =
               query(c, %{aud: @aud, lxm: method}) |> json_response(400)
    end

    for expiry <- ["bad", "0", System.system_time(:second) - 1, System.system_time(:second) + 120] do
      assert %{"error" => "BadExpiration"} =
               query(c, %{aud: @aud, exp: expiry}) |> json_response(400)
    end

    assert %{"error" => "BadExpiration"} =
             query(c, %{
               aud: @aud,
               lxm: "app.bsky.feed.getTimeline",
               exp: System.system_time(:second) + 3601
             })
             |> json_response(400)
  end

  test "requires a live active access session and available signing key", c do
    assert get(c.conn, @route, %{aud: @aud}) |> json_response(401)

    assert query(%{c | pair: %{access_jwt: c.pair.refresh_jwt}}, %{aud: @aud})
           |> json_response(401)

    Application.delete_env(:atoll, :key_encryption_key)
    assert %{"error" => "ServiceUnavailable"} = query(c, %{aud: @aud}) |> json_response(503)
    Application.put_env(:atoll, :key_encryption_key, :binary.copy(<<26>>, 32))
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert query(c, %{aud: @aud}) |> json_response(400)
    {:ok, _} = Repositories.set_status(@did, :active)
    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert query(c, %{aud: @aud}) |> json_response(401)
  end

  test "enforces method and rate limits on encoded routes", c do
    assert post(c.conn, @route) |> response(405)
    for _ <- 1..300, do: Atoll.Accounts.SessionLimiter.check({:session, c.conn.remote_ip}, 300)

    assert get(c.conn, "/xrpc/com.atproto.server.%67etServiceAuth", %{aud: @aud})
           |> json_response(429)
  end

  test "deactivated accounts may only delegate account migration", c do
    {:ok, _} = Repositories.set_status(@did, :deactivated)

    assert %{"token" => token} =
             query(c, %{aud: @aud, lxm: "com.atproto.server.createAccount"}) |> json_response(200)

    {_, claims} = verify(token, c.key)
    assert claims["lxm"] == "com.atproto.server.createAccount"

    for params <- [%{aud: @aud}, %{aud: @aud, lxm: "app.bsky.feed.getTimeline"}] do
      assert %{"error" => "RepoDeactivated"} = query(c, params) |> json_response(400)
    end

    {:ok, _} = Repositories.set_status(@did, :takendown)
    assert query(c, %{aud: @aud, lxm: "com.atproto.server.createAccount"}) |> json_response(400)
  end

  defp query(c, params),
    do:
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> get(@route, params)

  defp verify(token, key) do
    [header, claims, signature] = String.split(token, ".")
    <<r::unsigned-big-256, s::unsigned-big-256>> = Base.url_decode64!(signature, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    curve = if key.curve == :k256, do: :secp256k1, else: :secp256r1
    assert :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [key.public, curve])

    {header |> Base.url_decode64!(padding: false) |> Jason.decode!(),
     claims |> Base.url_decode64!(padding: false) |> Jason.decode!()}
  end
end
