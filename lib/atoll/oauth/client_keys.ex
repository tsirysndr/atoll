defmodule Atoll.OAuth.ClientKeys do
  @moduledoc """
  Fresh confidential-client metadata and ES256 verification keys. The result
  identifies advertised keys, not an authenticated client. Callers must verify
  assertions, reject replays, and enforce the session's kid/alg/jkt binding.
  """
  alias Atoll.OAuth.ClientMetadata
  alias Atoll.Identity.Resolver

  def fetch(client_id, opts \\ []) do
    with {:ok, %{"token_endpoint_auth_method" => "private_key_jwt"} = metadata} <-
           ClientMetadata.fetch(client_id, opts),
         {:ok, document} <- document(metadata, opts),
         {:ok, keys} <- keys(document) do
      {:ok, %{metadata: metadata, keys: keys}}
    else
      _ -> {:error, :invalid_client_keys}
    end
  end

  defp document(%{"jwks" => document}, _), do: {:ok, document}

  defp document(%{"jwks_uri" => url}, opts) do
    with {:ok, body} <- Resolver.fetch_oauth_document(url, opts),
         do: ClientMetadata.decode_document(body)
  end

  defp keys(%{"keys" => keys}) when is_list(keys) and length(keys) in 1..32 do
    Enum.reduce_while(keys, {:ok, %{}}, fn jwk, {:ok, acc} ->
      case key(jwk) do
        {:ok, %{kid: kid} = key} when not is_map_key(acc, kid) ->
          {:cont, {:ok, Map.put(acc, kid, key)}}

        _ ->
          {:halt, {:error, :invalid_client_keys}}
      end
    end)
  end

  defp keys(_), do: {:error, :invalid_client_keys}

  defp key(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y, "kid" => kid} = jwk) do
    with true <- is_binary(kid) and byte_size(kid) in 1..256,
         true <- Regex.match?(~r/\A[\x21-\x7e]+\z/, kid),
         true <- Enum.all?(~w(d k p q dp dq qi oth jku x5u), &(not Map.has_key?(jwk, &1))),
         true <- Map.get(jwk, "alg", "ES256") == "ES256",
         true <- Map.get(jwk, "use", "sig") == "sig",
         true <- Map.get(jwk, "key_ops", ["verify"]) == ["verify"],
         {:ok, x_bytes} <- coordinate(x),
         {:ok, y_bytes} <- coordinate(y),
         true <- point?(x_bytes, y_bytes) do
      # Discard all extensions; only these four public parameters reach JOSE.
      key = JOSE.JWK.from_map(Map.take(jwk, ~w(kty crv x y)))
      {:ok, %{kid: kid, alg: "ES256", jkt: JOSE.JWK.thumbprint(key), jwk: key}}
    else
      _ -> {:error, :invalid_client_keys}
    end
  end

  defp key(_), do: {:error, :invalid_client_keys}

  defp coordinate(value) when is_binary(value) and byte_size(value) == 43 do
    with {:ok, <<_::256>> = bytes} <- Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == value,
         do: {:ok, bytes},
         else: (_ -> {:error, :invalid_client_keys})
  end

  defp coordinate(_), do: {:error, :invalid_client_keys}

  defp point?(x, y) do
    # OpenSSL validates the complete point. Scalar one is public, not a signing secret.
    is_binary(:crypto.compute_key(:ecdh, <<4, x::binary, y::binary>>, <<1::256>>, :secp256r1))
  catch
    :error, _ -> false
  end
end
