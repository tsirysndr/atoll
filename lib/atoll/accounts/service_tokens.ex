defmodule Atoll.Accounts.ServiceTokens do
  @moduledoc "Account service-JWT verification with exact audience/method binding and persistent replay rejection."
  import Ecto.Query
  alias Atoll.{CBOR, Repo, SigningKey, Syntax}
  alias Atoll.Accounts.ServiceTokenUse
  alias Atoll.Identity.{Document, Resolver}

  @doc "Verifies and consumes a service token once. Options are trusted resolver/clock configuration."
  def authenticate(token, audience, method, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with true <- is_binary(audience) and Syntax.nsid?(method),
         {:ok, header, claims, input, signature} <- decode(token),
         :ok <- claims_valid(claims, audience, method, now),
         {:ok, doc} <- Resolver.resolve_document(claims["iss"], opts),
         {:ok, key} <- Document.account_key(doc, claims["iss"]),
         true <- header["alg"] == algorithm(key.curve),
         true <- SigningKey.verify(key.curve, key.public, input, signature),
         :ok <-
           claims_valid(
             claims,
             audience,
             method,
             Keyword.get(opts, :now, System.system_time(:second))
           ) do
      digest =
        :crypto.hash(
          :sha256,
          CBOR.encode!(["atoll.service-token.v1", claims["iss"], claims["jti"]])
        )

      case Repo.insert_all(ServiceTokenUse, [%{digest: digest, expires_at: claims["exp"]}],
             on_conflict: :nothing,
             conflict_target: [:digest],
             log: false
           ) do
        {1, _} -> {:ok, claims}
        {0, _} -> {:error, :service_token_replayed}
      end
    else
      {:error, :expired_token} = error -> error
      _ -> {:error, :invalid_service_token}
    end
  end

  @doc "Deletes at most 1000 expired replay markers; run periodically from trusted maintenance."
  def prune_expired(limit \\ 500)

  def prune_expired(limit) when is_integer(limit) and limit in 1..1000 do
    now = System.system_time(:second)

    Repo.transaction(fn ->
      ids =
        Repo.all(
          from u in ServiceTokenUse,
            where: u.expires_at <= ^now,
            order_by: [asc: u.expires_at, asc: u.digest],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED",
            select: u.digest
        )

      {count, _} =
        Repo.delete_all(
          from u in ServiceTokenUse, where: u.digest in ^ids and u.expires_at <= ^now
        )

      count
    end)
  end

  def prune_expired(_), do: {:error, :invalid_limit}

  defp decode(token) when is_binary(token) and byte_size(token) <= 8192 do
    with [h, c, s] <- String.split(token, "."),
         {:ok, header} <- object(h),
         true <- header["alg"] in ["ES256", "ES256K"] and header["typ"] == "JWT",
         true <- Map.get(header, "kid", "#atproto") == "#atproto",
         true <- Map.keys(header) -- ["alg", "typ", "kid"] == [],
         {:ok, claims} <- object(c),
         {:ok, <<_::binary-size(64)>> = signature} <- base64(s) do
      {:ok, header, claims, h <> "." <> c, signature}
    else
      _ -> {:error, :invalid_service_token}
    end
  end

  defp decode(_), do: {:error, :invalid_service_token}

  defp object(segment) do
    with {:ok, json} <- base64(segment),
         {:ok, %Jason.OrderedObject{values: entries}} <-
           Jason.decode(json, objects: :ordered_objects),
         true <- length(entries) == length(Enum.uniq_by(entries, &elem(&1, 0))) do
      {:ok, Map.new(entries)}
    else
      _ -> {:error, :invalid_service_token}
    end
  end

  defp base64(segment) do
    with {:ok, bytes} <- Base.url_decode64(segment, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == segment do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_service_token}
    end
  end

  defp claims_valid(
         %{
           "iss" => did,
           "aud" => audience,
           "lxm" => method,
           "iat" => iat,
           "exp" => exp,
           "jti" => nonce
         },
         audience,
         method,
         now
       )
       when is_integer(iat) and is_integer(exp) and is_binary(nonce) do
    cond do
      not Syntax.did?(did) ->
        {:error, :invalid_service_token}

      byte_size(nonce) not in 1..256 ->
        {:error, :invalid_service_token}

      iat < 0 or iat > now + 30 or exp <= iat or exp - iat > 3600 ->
        {:error, :invalid_service_token}

      exp <= now ->
        {:error, :expired_token}

      true ->
        :ok
    end
  end

  defp claims_valid(_, _, _, _), do: {:error, :invalid_service_token}
  defp algorithm(:k256), do: "ES256K"
  defp algorithm(:p256), do: "ES256"
end
