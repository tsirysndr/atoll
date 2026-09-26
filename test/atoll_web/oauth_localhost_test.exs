defmodule AtollWeb.OAuthLocalhostTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.OAuth.{Nonce, AuthorizationCodes}

  test "localhost PAR, approval, token exchange, refresh and session read require no metadata fetch",
       %{conn: conn} do
    for name <- [:oauth_nonce_secret, :oauth_transport_options] do
      prior = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :oauth_nonce_secret, :crypto.strong_rand_bytes(32))

    opts = [
      lookup: fn _ -> flunk("unexpected DNS") end,
      request: Req.new(plug: fn _ -> flunk("unexpected metadata HTTP") end)
    ]

    Application.put_env(:atoll, :oauth_transport_options, opts)
    did = "did:plc:localhostoauth"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    session_opts = [secret: :crypto.strong_rand_bytes(32), audience: "did:web:pds.example.com"]
    {:ok, account} = Atoll.Accounts.Sessions.create_for_account(did, session_opts)
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    {:ok, nonce} = Nonce.issue(:authorization)

    id =
      "http://localhost?" <>
        URI.encode_query([
          {"redirect_uri", "http://127.0.0.1/callback"},
          {"scope", "atproto transition:email"}
        ])

    verifier = random()

    params = %{
      "client_id" => id,
      "redirect_uri" => "http://127.0.0.1:48765/callback",
      "response_type" => "code",
      "scope" => "atproto",
      "state" => random(),
      "code_challenge_method" => "S256",
      "code_challenge" => hash(verifier)
    }

    peer = rem(System.unique_integer([:positive]), 65_536)
    conn = %{conn | remote_ip: {10, 83, div(peer, 256), rem(peer, 256)}}
    pushed = post_form(conn, "/oauth/par", params, key, nonce) |> json_response(201)

    assert {:ok, approved} =
             AuthorizationCodes.decide(
               account.access_jwt,
               id,
               pushed["request_uri"],
               {:approve, "atproto"},
               Keyword.put(opts, :session_options, session_opts)
             )

    assert approved.redirect_uri == params["redirect_uri"]

    token_params = %{
      "grant_type" => "authorization_code",
      "client_id" => id,
      "redirect_uri" => params["redirect_uri"],
      "code" => approved.code,
      "code_verifier" => verifier
    }

    alternate_id = String.replace(id, "http://localhost?", "http://localhost/?")

    assert post_form(
             conn,
             "/oauth/token",
             Map.put(token_params, "client_id", alternate_id),
             key,
             nonce
           )
           |> json_response(400) == %{"error" => "invalid_grant"}

    # Port flexibility applies to registration only; the issued code retains the actual callback.
    assert post_form(
             conn,
             "/oauth/token",
             Map.put(token_params, "redirect_uri", "http://127.0.0.1:9000/callback"),
             key,
             nonce
           )
           |> json_response(400) == %{"error" => "invalid_grant"}

    tokens = post_form(conn, "/oauth/token", token_params, key, nonce) |> json_response(200)
    assert tokens["sub"] == did
    assert tokens["scope"] == "atproto"

    refreshed =
      post_form(
        conn,
        "/oauth/token",
        %{
          "grant_type" => "refresh_token",
          "client_id" => id,
          "refresh_token" => tokens["refresh_token"]
        },
        key,
        nonce
      )
      |> json_response(200)

    {:ok, resource_nonce} = Nonce.issue(:resource)
    path = "/xrpc/com.atproto.server.getSession"
    proof = proof(key, resource_nonce, "GET", path, %{"ath" => hash(refreshed["access_token"])})

    result =
      conn
      |> put_req_header("authorization", "DPoP " <> refreshed["access_token"])
      |> put_req_header("dpop", proof)
      |> get(path)
      |> json_response(200)

    assert result["did"] == did
    refute Map.has_key?(result, "email")
  end

  defp post_form(conn, path, params, key, nonce),
    do:
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(key, nonce, "POST", path, %{}))
      |> post(path, URI.encode_query(params))

  defp proof(key, nonce, method, path, extra) do
    {_, public} = JOSE.JWK.to_public_map(key)

    JOSE.JWT.sign(
      key,
      %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public},
      Map.merge(
        %{
          "jti" => random(),
          "iat" => System.system_time(:second),
          "nonce" => nonce,
          "htm" => method,
          "htu" => AtollWeb.Endpoint.url() <> path
        },
        extra
      )
    )
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
end
