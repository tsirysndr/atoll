defmodule Atoll.OAuth.ClientMetadata do
  @moduledoc """
  Fresh, bounded OAuth client metadata retrieval, localhost synthesis, and declaration validation.
  Metadata is untrusted branding, not client authentication or consent. Embedded
  and remote JWKS declarations require ClientKeys validation and JWT verification.
  Transport options are trusted configuration, never request parameters.
  """
  alias Atoll.Identity.Resolver

  def fetch(client_id, opts \\ [])

  def fetch("http://" <> _ = client_id, _opts),
    do: Atoll.OAuth.LocalhostClient.metadata(client_id)

  def fetch(client_id, opts) do
    with {:ok, uri} <- https_url(client_id),
         true <- authority(client_id) == authority_host(uri),
         {:ok, body} <- Resolver.fetch_oauth_document(client_id, opts),
         {:ok, document} <- decode_document(body),
         {:ok, metadata} <- validate(document, client_id, uri) do
      {:ok, metadata}
    else
      _ -> {:error, :invalid_client_metadata}
    end
  end

  @doc "Matches validated callback declarations; virtual localhost clients ignore only loopback ports."
  def redirect_allowed?(%{"client_id" => "http://" <> _ = client_id}, uri),
    do: Atoll.OAuth.LocalhostClient.redirect_allowed?(client_id, uri)

  def redirect_allowed?(%{"redirect_uris" => uris}, uri) when is_list(uris) and is_binary(uri),
    do: uri in uris

  def redirect_allowed?(_, _), do: false

  @doc "Checks requested scope syntax, required atproto, and membership in declared scopes."
  def scopes_allowed?(%{"scope" => declared}, requested) do
    with {:ok, allowed} <- scopes(declared),
         {:ok, values} <- scopes(requested),
         do: Enum.all?(values, &(&1 in allowed)),
         else: (_ -> false)
  end

  def scopes_allowed?(_, _), do: false

  defp validate(doc, client_id, uri) when is_map(doc) do
    app = Map.get(doc, "application_type", "web")
    auth = Map.get(doc, "token_endpoint_auth_method", "none")

    with true <- doc["client_id"] == client_id,
         true <- app in ["web", "native"] and auth in ["none", "private_key_jwt"],
         true <- doc["dpop_bound_access_tokens"] == true,
         true <- strings?(doc["grant_types"], 2),
         true <- "authorization_code" in doc["grant_types"],
         true <- Enum.all?(doc["grant_types"], &(&1 in ["authorization_code", "refresh_token"])),
         true <- doc["response_types"] == ["code"],
         {:ok, _} <- scopes(doc["scope"]),
         true <- strings?(doc["redirect_uris"], 32),
         true <- Enum.all?(doc["redirect_uris"], &redirect?(&1, app, uri)),
         true <- authentication?(doc, auth),
         true <- presentation?(doc, uri) do
      {:ok,
       doc |> Map.put("application_type", app) |> Map.put("token_endpoint_auth_method", auth)}
    else
      _ -> {:error, :invalid_client_metadata}
    end
  end

  defp validate(_, _, _), do: {:error, :invalid_client_metadata}

  defp authentication?(doc, method) do
    alg = Map.get(doc, "token_endpoint_auth_signing_alg", "ES256")
    inline = Map.has_key?(doc, "jwks")
    remote = Map.has_key?(doc, "jwks_uri")

    alg == "ES256" and not (inline and remote) and
      (method == "none" or inline or remote) and
      (not inline or jwks_declaration?(doc["jwks"])) and
      (not remote or match?({:ok, _}, https_url(doc["jwks_uri"])))
  end

  # This only validates the declaration's shape. It must never authenticate a client.
  defp jwks_declaration?(%{"keys" => keys}) when is_list(keys) do
    length(keys) in 0..32 and Enum.all?(keys, &is_map/1)
  end

  defp jwks_declaration?(_), do: false

  defp presentation?(doc, client_uri) do
    Enum.all?(["logo_uri", "tos_uri", "policy_uri", "client_uri"], fn key ->
      case Map.fetch(doc, key) do
        :error ->
          true

        {:ok, value} ->
          case https_url(value) do
            {:ok, uri} ->
              key != "client_uri" or String.downcase(uri.host) == String.downcase(client_uri.host)

            _ ->
              false
          end
      end
    end) and
      (not Map.has_key?(doc, "client_name") or
         (is_binary(doc["client_name"]) and byte_size(doc["client_name"]) in 1..256))
  end

  defp redirect?(value, app, client) do
    case https_url(value) do
      {:ok, uri} ->
        # An explicitly written default HTTPS port is not permitted for callbacks.
        (uri.port != 443 or authority(value) == authority_host(uri)) and
          (app == "web" or
             (String.downcase(uri.host) == String.downcase(client.host) and
                uri.port == client.port))

      _ when app == "native" ->
        scheme =
          client.host
          |> String.downcase()
          |> String.split(".")
          |> Enum.reverse()
          |> Enum.join(".")

        with true <- url_text?(value),
             {:ok, uri} <- URI.new(value),
             true <- uri.scheme == scheme and is_nil(uri.host) and is_nil(uri.fragment),
             true <- is_binary(uri.path) and String.starts_with?(uri.path, "/"),
             do: true,
             else: (_ -> false)

      _ ->
        false
    end
  end

  defp https_url(value) do
    with true <- url_text?(value),
         {:ok, %URI{scheme: "https", host: host, port: port, userinfo: nil, fragment: nil} = uri} <-
           URI.new(value),
         true <- is_binary(host) and host != "" and port in 1..65535,
         true <- valid_host?(host) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_url}
    end
  end

  defp valid_host?(host) do
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host))) or
      (byte_size(host) <= 253 and
         Enum.all?(
           String.split(host, "."),
           &Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, &1)
         ))
  end

  defp authority_host(uri),
    do: if(String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host)

  # URI.new normalizes away an explicitly written default port. Inspect the
  # original authority only after HTTPS parsing has validated the URL structure.
  defp authority(value),
    do:
      value
      |> String.split("://", parts: 2)
      |> List.last()
      |> String.split(~r/[\/?#]/, parts: 2)
      |> hd()

  defp url_text?(value) when is_binary(value) and byte_size(value) in 1..2048,
    do:
      Regex.match?(~r/\A[\x21-\x7e]+\z/, value) and
        not String.contains?(value, "\\") and not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value)

  defp url_text?(_), do: false

  defp strings?(values, limit) when is_list(values),
    do:
      length(values) in 1..limit and Enum.all?(values, &is_binary/1) and
        length(Enum.uniq(values)) == length(values)

  defp strings?(_, _), do: false

  defp scopes(value) when is_binary(value) and byte_size(value) in 1..4096 do
    values = String.split(value, " ")

    if "atproto" in values and length(values) <= 128 and
         Enum.all?(values, &Regex.match?(~r/\A[\x21\x23-\x5b\x5d-\x7e]+\z/, &1)) and
         length(Enum.uniq(values)) == length(values),
       do: {:ok, values},
       else: {:error, :invalid_scope}
  end

  defp scopes(_), do: {:error, :invalid_scope}

  @doc false
  def decode_document(body) when is_binary(body) and byte_size(body) <= 65_536 do
    with {:ok, %Jason.OrderedObject{} = object} <- Jason.decode(body, objects: :ordered_objects),
         do: {:ok, unique!(object, 0)},
         else: (_ -> {:error, :invalid_client_metadata})
  rescue
    ArgumentError -> {:error, :invalid_client_metadata}
  end

  def decode_document(_), do: {:error, :invalid_client_metadata}
  defp unique!(_, depth) when depth > 16, do: raise(ArgumentError)

  defp unique!(%Jason.OrderedObject{values: pairs}, depth) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      if Map.has_key?(acc, key), do: raise(ArgumentError)
      Map.put(acc, key, unique!(value, depth + 1))
    end)
  end

  defp unique!(values, depth) when is_list(values), do: Enum.map(values, &unique!(&1, depth + 1))
  defp unique!(value, _), do: value
end
