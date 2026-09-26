defmodule Atoll.Identity.Server do
  @moduledoc "Publishes the configured hostname-based server DID using a stable service signing key."
  alias Atoll.{Multikey, SigningKey, Syntax}

  def key_from_env!(nil), do: nil

  def key_from_env!(encoded) do
    with {:ok, private} <- Base.decode64(encoded),
         {:ok, key} <- SigningKey.from_private(:k256, private) do
      key
    else
      _ ->
        raise "ATOLL_PDS_SIGNING_KEY must be a base64-encoded secp256k1 private key of 32 bytes"
    end
  end

  def document(request_host) do
    did = Application.get_env(:atoll, :pds, [])[:did]
    endpoint = AtollWeb.Endpoint.url()
    uri = URI.parse(endpoint)

    with true <- origin?(did, request_host, uri),
         true <-
           is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             uri.path in [nil, "", "/"] do
      case Application.get_env(:atoll, :server_identity_key) do
        %SigningKey{} = key ->
          with {:ok, public} <- Multikey.encode(key.curve, key.public) do
            {:ok,
             %{
               "@context" => [
                 "https://www.w3.org/ns/did/v1",
                 "https://w3id.org/security/multikey/v1"
               ],
               "id" => did,
               "verificationMethod" => [
                 %{
                   "id" => did <> "#atproto",
                   "type" => "Multikey",
                   "controller" => did,
                   "publicKeyMultibase" => public
                 }
               ],
               "assertionMethod" => [did <> "#atproto"],
               "service" => [
                 %{
                   "id" => did <> "#atproto_pds",
                   "type" => "AtprotoPersonalDataServer",
                   "serviceEndpoint" => endpoint
                 }
               ]
             }}
          end

        _ ->
          {:error, :server_identity_unconfigured}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp origin?("did:web:" <> host = did, request_host, uri) do
    public? =
      Syntax.handle?(host) and host == String.downcase(host) and
        uri.scheme == "https" and uri.host == host and request_host == host

    local? =
      case Atoll.Identity.Localhost.url(did) do
        {:ok, url} ->
          local = URI.parse(url)

          uri.scheme == "http" and uri.host == "localhost" and request_host == "localhost" and
            uri.port == local.port

        _ ->
          false
      end

    public? or local?
  end

  defp origin?(_, _, _), do: false
end
