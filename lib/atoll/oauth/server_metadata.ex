defmodule Atoll.OAuth.ServerMetadata do
  @moduledoc "OAuth discovery for Atoll's colocated authorization and resource server."
  @scopes ~w(atproto transition:generic transition:chat.bsky transition:email repo:* blob:*/* account:email account:email?action=manage account:repo account:repo?action=manage identity:handle identity:*)

  def authorization do
    with {:ok, origin} <- origin() do
      {:ok,
       %{
         issuer: origin,
         authorization_endpoint: origin <> "/oauth/authorize",
         token_endpoint: origin <> "/oauth/token",
         pushed_authorization_request_endpoint: origin <> "/oauth/par",
         response_types_supported: ["code"],
         response_modes_supported: ["query"],
         grant_types_supported: ["authorization_code", "refresh_token"],
         code_challenge_methods_supported: ["S256"],
         token_endpoint_auth_methods_supported: ["none", "private_key_jwt"],
         token_endpoint_auth_signing_alg_values_supported: ["ES256"],
         dpop_signing_alg_values_supported: ["ES256"],
         scopes_supported: @scopes,
         authorization_response_iss_parameter_supported: true,
         require_pushed_authorization_requests: true,
         require_request_uri_registration: true,
         client_id_metadata_document_supported: true,
         prompt_values_supported: ["create"],
         protected_resources: [origin]
       }}
    end
  end

  def resource do
    with {:ok, origin} <- origin() do
      {:ok,
       %{
         resource: origin,
         authorization_servers: [origin],
         scopes_supported: @scopes,
         dpop_signing_alg_values_supported: ["ES256"]
       }}
    end
  end

  # Legacy password sessions still use Bearer; do not claim all resource access
  # requires DPoP. OAuth-issued access tokens do require DPoP, as the profile mandates.
  defp host?(host),
    do:
      host == "localhost" or Atoll.Syntax.handle?(host) or
        match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))

  def origin do
    origin = AtollWeb.Endpoint.url()

    with true <- is_binary(origin) and byte_size(origin) in 1..2048,
         {:ok, uri} <- URI.new(origin),
         true <- is_binary(uri.host) and uri.host == String.downcase(uri.host),
         true <- host?(uri.host),
         true <- uri.userinfo == nil and uri.query == nil and uri.fragment == nil,
         true <- uri.path in [nil, ""],
         true <- is_integer(uri.port) and uri.port in 1..65535,
         true <- uri.scheme == "https" or Atoll.Identity.Localhost.endpoint?(origin),
         true <- URI.to_string(uri) == origin,
         true <- AtollWeb.Endpoint.path("/") == "/" do
      {:ok, origin}
    else
      _ -> {:error, :invalid_oauth_origin}
    end
  end
end
