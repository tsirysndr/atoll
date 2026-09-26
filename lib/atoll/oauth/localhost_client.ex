defmodule Atoll.OAuth.LocalhostClient do
  @moduledoc "Virtual public OAuth clients for localhost development; never performs DNS or HTTP."
  alias Atoll.OAuth.ClientMetadata
  @defaults ["http://127.0.0.1/", "http://[::1]/"]

  def metadata(client_id) do
    with true <- url_text?(client_id),
         {:ok, %URI{scheme: "http", host: "localhost", userinfo: nil, fragment: nil} = uri} <-
           URI.new(client_id),
         true <- authority(client_id) == "localhost" and uri.path in [nil, "", "/"],
         {:ok, pairs} <- query(uri.query),
         scopes = for({"scope", value} <- pairs, do: value),
         true <- length(scopes) <= 1,
         scope = List.first(scopes) || "atproto",
         true <- ClientMetadata.scopes_allowed?(%{"scope" => scope}, scope),
         redirects = for({"redirect_uri", value} <- pairs, do: value),
         redirects = if(redirects == [], do: @defaults, else: redirects),
         true <- length(redirects) <= 32 and length(Enum.uniq(redirects)) == length(redirects),
         true <- Enum.all?(redirects, &match?({:ok, _}, callback(&1))) do
      {:ok,
       %{
         "client_id" => client_id,
         "client_name" => "Local development client",
         "application_type" => "native",
         "token_endpoint_auth_method" => "none",
         "grant_types" => ["authorization_code", "refresh_token"],
         "response_types" => ["code"],
         "scope" => scope,
         "redirect_uris" => redirects,
         "dpop_bound_access_tokens" => true
       }}
    else
      _ -> {:error, :invalid_client_metadata}
    end
  end

  def redirect_allowed?(client_id, redirect) do
    with {:ok, metadata} <- metadata(client_id),
         {:ok, target} <- callback(redirect) do
      Enum.any?(metadata["redirect_uris"], fn declared -> callback(declared) == {:ok, target} end)
    else
      _ -> false
    end
  end

  defp query(nil), do: {:ok, []}
  defp query(""), do: {:ok, []}

  defp query(value) do
    pairs = String.split(value, "&")

    if length(pairs) <= 33 do
      Enum.reduce_while(pairs, {:ok, []}, fn pair, {:ok, acc} ->
        case String.split(pair, "=", parts: 2) do
          [key, value] ->
            key = URI.decode_www_form(key)
            value = URI.decode_www_form(value)

            if key in ["scope", "redirect_uri"] and String.valid?(value) and value != "",
              do: {:cont, {:ok, acc ++ [{key, value}]}},
              else: {:halt, :error}

          _ ->
            {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp callback(value) do
    with true <- url_text?(value),
         {:ok, %URI{scheme: "http", host: host, userinfo: nil, fragment: nil, port: port} = uri} <-
           URI.new(value),
         true <- host in ["127.0.0.1", "::1"] and port in 1..65535,
         true <- Regex.match?(~r/\A(?:127\.0\.0\.1|\[::1\])(?::[0-9]{1,5})?\z/, authority(value)),
         path = if(uri.path in [nil, ""], do: "/", else: uri.path),
         true <- String.starts_with?(path, "/"),
         false <- Enum.any?(String.split(path, "/"), &(URI.decode(&1) in [".", ".."])) do
      # Ignore only the callback's port. Preserve host, path, and query binding.
      {:ok, {host, path, uri.query}}
    else
      _ -> :error
    end
  end

  defp url_text?(value) when is_binary(value) and byte_size(value) in 1..2048,
    do:
      Regex.match?(~r/\A[\x21-\x7e]+\z/, value) and not String.contains?(value, "\\") and
        not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value)

  defp url_text?(_), do: false

  defp authority(value),
    do:
      value
      |> String.split("://", parts: 2)
      |> List.last()
      |> String.split(~r/[\/?#]/, parts: 2)
      |> hd()
end
