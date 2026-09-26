defmodule Atoll.OAuth.DPoP do
  @moduledoc """
  Bounded ES256 DPoP proof verification, not account authorization.

  Callers supply the externally visible request URL and a recently issued server
  nonce. Resource requests must also supply the validated access token and its
  bound JWK thumbprint. A successful result still requires atomic replay rejection
  and normal token/scope authorization before executing a request.
  """
  @max_size 8192
  @max_age 300
  @clock_skew 30

  def verify(headers, method, url, opts \\ [])

  def verify([proof], method, url, opts)
      when is_binary(proof) and byte_size(proof) <= @max_size and is_binary(method) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    nonce = Keyword.get(opts, :nonce)

    with true <- is_integer(now) and bounded_string?(nonce, 16, 256),
         [encoded_header, encoded_claims, encoded_signature] <- String.split(proof, "."),
         {:ok, header} <- object(encoded_header),
         {:ok, claims} <- object(encoded_claims),
         {:ok, <<_::binary-size(64)>>} <- decode64(encoded_signature),
         %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk} <- header,
         true <- Enum.all?(["crit", "b64", "jku", "x5u"], &(not Map.has_key?(header, &1))),
         {:ok, key} <- public_key(jwk),
         {true, _, _} <- JOSE.JWT.verify_strict(key, ["ES256"], proof),
         true <- claims["htm"] == method and Regex.match?(~r/\A[A-Z]+\z/, method),
         {:ok, expected_url} <- target(url, false),
         {:ok, ^expected_url} <- target(claims["htu"], true),
         true <-
           is_integer(claims["iat"]) and claims["iat"] >= now - @max_age and
             claims["iat"] <= now + @clock_skew,
         true <- is_binary(claims["jti"]) and byte_size(claims["jti"]) in 1..256,
         true <- secure_equal?(claims["nonce"], nonce),
         thumbprint = JOSE.JWK.thumbprint(key),
         :ok <- token_binding(claims, thumbprint, opts) do
      {:ok, %{jkt: thumbprint, jti: claims["jti"], issued_at: claims["iat"], nonce: nonce}}
    else
      _ -> {:error, :invalid_dpop_proof}
    end
  rescue
    _ -> {:error, :invalid_dpop_proof}
  catch
    _, _ -> {:error, :invalid_dpop_proof}
  end

  def verify(_, _, _, _), do: {:error, :invalid_dpop_proof}

  defp public_key(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y} = jwk) do
    with false <- Map.has_key?(jwk, "d"),
         true <- Map.get(jwk, "alg", "ES256") == "ES256",
         true <- Map.get(jwk, "use", "sig") == "sig",
         true <- not Map.has_key?(jwk, "key_ops") or jwk["key_ops"] == ["verify"],
         {:ok, <<_::binary-size(32)>>} <- decode64(x),
         {:ok, <<_::binary-size(32)>>} <- decode64(y) do
      {:ok, JOSE.JWK.from_map(Map.take(jwk, ["kty", "crv", "x", "y"]))}
    else
      _ -> {:error, :invalid_dpop_proof}
    end
  end

  defp public_key(_), do: {:error, :invalid_dpop_proof}

  defp token_binding(claims, thumbprint, opts) do
    case {Keyword.fetch(opts, :access_token), Keyword.fetch(opts, :jkt)} do
      {:error, :error} ->
        :ok

      {{:ok, token}, {:ok, jkt}} when is_binary(token) and byte_size(token) in 1..8192 ->
        hash = :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

        if ascii?(token) and secure_equal?(claims["ath"], hash) and secure_equal?(thumbprint, jkt),
          do: :ok,
          else: {:error, :invalid_dpop_proof}

      _ ->
        {:error, :invalid_dpop_proof}
    end
  end

  defp target(value, proof?) when is_binary(value) and byte_size(value) <= 4096 do
    with {:ok, uri} <- URI.new(value),
         scheme = String.downcase(uri.scheme || ""),
         true <- scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         true <- not proof? or is_nil(uri.query),
         true <- uri.path in [nil, ""] or String.starts_with?(uri.path, "/") do
      {:ok,
       URI.to_string(%{
         uri
         | scheme: scheme,
           port: uri.port || URI.default_port(scheme),
           host: String.downcase(uri.host),
           path: if(uri.path in [nil, ""], do: "/", else: uri.path),
           query: nil
       })}
    else
      _ -> {:error, :invalid_dpop_proof}
    end
  end

  defp target(_, _), do: {:error, :invalid_dpop_proof}

  defp object(value) do
    with {:ok, bytes} <- decode64(value),
         {:ok, %Jason.OrderedObject{} = ordered} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, map} <- unique(ordered, 0),
         do: {:ok, map}
  end

  defp unique(_, depth) when depth > 16, do: {:error, :invalid_dpop_proof}

  defp unique(%Jason.OrderedObject{values: entries}, depth) do
    if length(entries) == length(Enum.uniq_by(entries, &elem(&1, 0))) do
      Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case unique(value, depth + 1) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_dpop_proof}
    end
  end

  defp unique(values, depth) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case unique(value, depth + 1) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp unique(value, _), do: {:ok, value}

  defp decode64(value) when is_binary(value) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == value,
         do: {:ok, bytes},
         else: (_ -> {:error, :invalid_dpop_proof})
  end

  defp decode64(_), do: {:error, :invalid_dpop_proof}

  defp bounded_string?(value, min, max),
    do: is_binary(value) and byte_size(value) in min..max and ascii?(value)

  defp ascii?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 in 33..126))

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: Plug.Crypto.secure_compare(a, b)

  defp secure_equal?(_, _), do: false
end
