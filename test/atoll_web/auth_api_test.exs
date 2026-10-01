defmodule AtollWeb.AuthApiTest do
  @moduledoc """
  `social.rocksky.auth.*` is the contract a client uses against any PDS, so what
  matters here is the state machine it sees over XRPC and what it is refused.
  """
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.{Credentials, Sessions, TOTP}

  @password "authenticator password"

  setup %{conn: conn} do
    for name <- [:session_signing_key, :key_encryption_key, :previous_key_encryption_keys] do
      previous = Application.fetch_env(:atoll, name)
      Application.put_env(:atoll, name, :crypto.strong_rand_bytes(32))

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :previous_key_encryption_keys, [])

    did = "did:plc:authapi"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Credentials.create(did, @password)
    Atoll.Repo.insert!(%Atoll.Accounts.Profile{did: did, handle: "alice.example.test"})
    {:ok, pair} = Sessions.create(did, @password)

    %{conn: conn, did: did, access: pair.access_jwt}
  end

  defp authed(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  defp call(conn, token, method, nsid, body \\ nil) do
    conn = authed(conn, token)

    case method do
      :get -> get(conn, "/xrpc/" <> nsid)
      :post -> post(conn, "/xrpc/" <> nsid, body || %{})
    end
  end

  defp code_for(secret) do
    # The code the authenticator would be showing for the secret just issued.
    {:ok, raw} = Base.decode32(secret, padding: false)
    {:ok, code} = TOTP.code(raw, System.system_time(:second))
    code
  end

  test "two-factor goes disabled -> pending -> enabled", c do
    disabled = call(c.conn, c.access, :get, "social.rocksky.auth.getTwoFactor")
    assert json_response(disabled, 200)["state"] == "disabled"

    begun =
      call(build_conn(), c.access, :post, "social.rocksky.auth.beginTwoFactor", %{
        "password" => @password
      })

    body = json_response(begun, 200)
    assert body["state"] == "pending"
    assert body["uri"] =~ "otpauth://totp/"
    assert is_binary(body["secret"])

    pending = call(build_conn(), c.access, :get, "social.rocksky.auth.getTwoFactor")
    assert json_response(pending, 200)["state"] == "pending"

    confirmed =
      call(build_conn(), c.access, :post, "social.rocksky.auth.confirmTwoFactor", %{
        "code" => code_for(body["secret"])
      })

    result = json_response(confirmed, 200)
    assert result["state"] == "enabled"
    assert length(result["recoveryCodes"]) > 0

    enabled = call(build_conn(), c.access, :get, "social.rocksky.auth.getTwoFactor")
    assert json_response(enabled, 200)["recoveryRemaining"] == length(result["recoveryCodes"])
  end

  test "a wrong code is refused as a bad code, not a server error", c do
    begun =
      call(c.conn, c.access, :post, "social.rocksky.auth.beginTwoFactor", %{
        "password" => @password
      })

    assert json_response(begun, 200)["state"] == "pending"

    refused =
      call(build_conn(), c.access, :post, "social.rocksky.auth.confirmTwoFactor", %{
        "code" => "000000"
      })

    # The common case when finishing setup: a mistyped or drifted code. It must
    # say so, not 500.
    assert json_response(refused, 400)["error"] == "InvalidCode"

    # And the enrollment survives, so the owner can simply try again.
    state = call(build_conn(), c.access, :get, "social.rocksky.auth.getTwoFactor")
    assert json_response(state, 200)["state"] == "pending"
  end

  test "every error the factor layer can return is answered, never crashed", _c do
    # The factor layer's own atoms. An unmapped one used to raise inside the
    # shared XRPC mapping and surface as a 500.
    for reason <- [
          :invalid_totp,
          :totp_required,
          :totp_rate_limited,
          :totp_already_enabled,
          :totp_not_enrolled,
          :totp_enrollment_expired,
          :totp_store_unavailable,
          :invalid_credentials,
          :invalid_token,
          :totp_inside_transaction,
          :some_future_reason
        ] do
      conn = AtollWeb.AuthApiFallback.call(build_conn(), {:error, reason})
      assert conn.status in 400..503, "#{reason} gave #{conn.status}"
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["error"]), "#{reason} returned no error name"
    end
  end

  test "a passkey ceremony can be started without signing in first", c do
    # This is how a session begins, so it takes no bearer token.
    started = post(c.conn, "/xrpc/social.rocksky.auth.beginPasskeyLogin", %{})
    body = json_response(started, 200)

    assert is_binary(body["requestId"])
    assert body["publicKey"]["challenge"]
    assert body["publicKey"]["userVerification"] == "required"
  end

  test "a passkey login refuses a request id it did not issue", c do
    for request_id <- [".no-reference", "no-separator", "aaa."] do
      refused =
        post(c.conn, "/xrpc/social.rocksky.auth.finishPasskeyLogin", %{
          "requestId" => request_id,
          "credential" => %{}
        })

      assert json_response(refused, 400)["error"] == "InvalidPasskey",
             "accepted #{request_id}"
    end
  end

  test "a passkey login refuses a well-formed but unknown ceremony", c do
    started = post(c.conn, "/xrpc/social.rocksky.auth.beginPasskeyLogin", %{})
    issued = json_response(started, 200)["requestId"]
    [reference, _browser] = String.split(issued, ".", parts: 2)

    # The right reference with the wrong secret must not be claimable: the pair
    # is what authorises it.
    refused =
      post(build_conn(), "/xrpc/social.rocksky.auth.finishPasskeyLogin", %{
        "requestId" => reference <> ".not-the-binding",
        "credential" => %{}
      })

    assert json_response(refused, 400)["error"] in ["InvalidPasskey", "InvalidRequest"]
  end

  test "the password is required to begin enrollment", c do
    refused =
      call(c.conn, c.access, :post, "social.rocksky.auth.beginTwoFactor", %{
        "password" => "not the password"
      })

    # An access token proves the session, not the owner.
    assert json_response(refused, 401)["error"] == "InvalidCredentials"

    state = call(build_conn(), c.access, :get, "social.rocksky.auth.getTwoFactor")
    assert json_response(state, 200)["state"] == "disabled"
  end

  test "a missing password is a bad request, not a crash", c do
    refused = call(c.conn, c.access, :post, "social.rocksky.auth.beginTwoFactor", %{})
    assert json_response(refused, 400)["error"]
  end

  test "an unauthenticated caller gets nothing", c do
    assert json_response(get(c.conn, "/xrpc/social.rocksky.auth.getTwoFactor"), 401)
    assert json_response(get(build_conn(), "/xrpc/social.rocksky.auth.listPasskeys"), 401)
  end

  test "passkeys start empty and a malformed request id is refused", c do
    listed = call(c.conn, c.access, :get, "social.rocksky.auth.listPasskeys")
    assert json_response(listed, 200)["passkeys"] == []

    refused =
      call(build_conn(), c.access, :post, "social.rocksky.auth.finishPasskeyRegistration", %{
        "requestId" => ".no-reference",
        "credential" => %{}
      })

    # An empty half is not a usable half.
    assert json_response(refused, 400)["error"] == "InvalidPasskey"
  end
end
