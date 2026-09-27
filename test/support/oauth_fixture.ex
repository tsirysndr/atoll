defmodule Atoll.OAuthFixture do
  @moduledoc false
  import Plug.Conn
  alias Atoll.OAuth.{PAR, Nonce, AuthorizationCodes, CodeExchange}
  @client "https://identity-app.example.com/client.json"

  def grant(pair, scope) do
    prior = Application.fetch_env(:atoll, :oauth_nonce_secret)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :oauth_nonce_secret, value)
        :error -> Application.delete_env(:atoll, :oauth_nonce_secret)
      end
    end)

    Application.put_env(:atoll, :oauth_nonce_secret, :crypto.strong_rand_bytes(32))

    metadata = %{
      "client_id" => @client,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "scope" => scope,
      "redirect_uris" => ["https://identity-app.example.com/callback"],
      "dpop_bound_access_tokens" => true
    }

    opts = [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, metadata) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end
    ]

    {:ok, nonce} = Nonce.issue(:authorization)
    client = %{key: JOSE.JWK.generate_key({:ec, :secp256r1}), nonce: nonce}
    verifier = random()

    params = %{
      "client_id" => @client,
      "response_type" => "code",
      "scope" => scope,
      "redirect_uri" => hd(metadata["redirect_uris"]),
      "state" => random(),
      "code_challenge_method" => "S256",
      "code_challenge" => :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    }

    {:ok, %{request_uri: uri}} = PAR.push(params, [proof(client, "/oauth/par")], opts)

    {:ok, approved} =
      AuthorizationCodes.decide(pair.access_jwt, @client, uri, {:approve, scope}, opts)

    {:ok, tokens} =
      CodeExchange.exchange(
        %{
          "grant_type" => "authorization_code",
          "client_id" => @client,
          "code" => approved.code,
          "redirect_uri" => params["redirect_uri"],
          "code_verifier" => verifier
        },
        [proof(client, "/oauth/token")],
        opts
      )

    {:ok, nonce} = Nonce.issue(:resource)
    Map.merge(client, %{nonce: nonce, token: tokens.access_token})
  end

  def conn(client, path) do
    id = rem(System.unique_integer([:positive]), 65_536)

    %{Phoenix.ConnTest.build_conn() | remote_ip: {10, 90, div(id, 256), rem(id, 256)}}
    |> put_req_header("authorization", "DPoP " <> client.token)
    |> put_req_header("dpop", proof(client, path))
    |> put_req_header("content-type", "application/json")
  end

  def proof(client, path) do
    {_, public} = JOSE.JWK.to_public_map(client.key)

    claims = %{
      "jti" => random(),
      "iat" => System.system_time(:second),
      "nonce" => client.nonce,
      "htm" => "POST",
      "htu" => AtollWeb.Endpoint.url() <> path
    }

    claims =
      if client[:token],
        do:
          Map.put(
            claims,
            "ath",
            :crypto.hash(:sha256, client.token) |> Base.url_encode64(padding: false)
          ),
        else: claims

    JOSE.JWT.sign(client.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
