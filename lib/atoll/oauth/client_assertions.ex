defmodule Atoll.OAuth.ClientAssertions do
  @moduledoc """
  Confidential-client ES256 JWT assertions with fresh metadata and shared replay
  admission. This authenticates client software, not an account or an OAuth grant.
  Call authenticate before the request mutation transaction. Options are trusted;
  pass binding: %{kid: ..., alg: ..., jkt: ...} for an existing session.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.OAuth.{ClientKeys, ClientMetadata, ClientAssertionUse}
  @type_uri "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @lock 4_182_026_051
  @capacity 100_000

  def authenticate(client_id, type, assertion, issuer, opts \\ []) do
    cond do
      Repo.in_transaction?() ->
        {:error, :oauth_assertion_inside_transaction}

      type != @type_uri or not is_binary(assertion) or byte_size(assertion) > 8192 ->
        {:error, :invalid_client_assertion}

      true ->
        with {:ok, client} <- ClientKeys.fetch(client_id, opts) do
          admit(assertion, client, issuer, opts)
        end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_assertion_store_unavailable}
  end

  @doc "Admits an assertion against a freshly validated ClientKeys snapshot supplied by trusted code."
  def authenticate_loaded(type, assertion, client, issuer, opts \\ []) do
    cond do
      Repo.in_transaction?() ->
        {:error, :oauth_assertion_inside_transaction}

      type != @type_uri or not is_binary(assertion) or byte_size(assertion) > 8192 ->
        {:error, :invalid_client_assertion}

      true ->
        admit(assertion, client, issuer, opts)
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_assertion_store_unavailable}
  end

  @doc "Stateless assertion verification; successful results still require atomic replay admission."
  def verify(assertion, client, issuer, opts \\ [])

  def verify(
        assertion,
        %{
          metadata: %{"client_id" => client_id, "token_endpoint_auth_method" => "private_key_jwt"},
          keys: keys
        },
        issuer,
        opts
      )
      when is_binary(assertion) and byte_size(assertion) <= 8192 and is_binary(issuer) and
             byte_size(issuer) in 1..2048 do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with true <- is_integer(now),
         [encoded_header, encoded_claims, encoded_signature] <- String.split(assertion, "."),
         {:ok, header} <- object(encoded_header),
         %{"alg" => "ES256", "kid" => kid} <- header,
         true <- bounded_id?(kid),
         true <- Map.get(header, "typ", "JWT") in ["JWT", "jwt"],
         true <- Enum.all?(~w(crit b64 jwk jku x5u x5c), &(not Map.has_key?(header, &1))),
         %{alg: "ES256"} = key <- Map.get(keys, kid),
         true <- binding_matches?(key, Keyword.fetch(opts, :binding)),
         {:ok, <<_::512>>} <- decode64(encoded_signature),
         {:ok, claims} <- object(encoded_claims),
         true <- claims["iss"] == client_id and claims["sub"] == client_id,
         true <- claims["aud"] == issuer or claims["aud"] == [issuer],
         true <- bounded_id?(claims["jti"]),
         true <- valid_time?(claims, now),
         {true, _, _} <- JOSE.JWT.verify_strict(key.jwk, ["ES256"], assertion) do
      {:ok,
       %{
         client_id: client_id,
         binding: Map.take(key, [:kid, :alg, :jkt]),
         jti: claims["jti"],
         issued_at: claims["iat"],
         expires_at: claims["exp"]
       }}
    else
      _ -> {:error, :invalid_client_assertion}
    end
  rescue
    _ -> {:error, :invalid_client_assertion}
  catch
    _, _ -> {:error, :invalid_client_assertion}
  end

  def verify(_, _, _, _), do: {:error, :invalid_client_assertion}

  defp admit(assertion, client, issuer, opts) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      now = clock!()
      options = Keyword.take(opts, [:binding]) |> Keyword.put(:now, now)
      verified = unwrap!(verify(assertion, client, issuer, options))
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock])
      now = clock!()

      if now >= verified.expires_at or now > verified.issued_at + 300,
        do: Repo.rollback(:invalid_client_assertion)

      prune!(now)
      # JTI uniqueness spans client key rotation and all endpoints for this issuer.
      digest =
        :crypto.hash(
          :sha256,
          Atoll.CBOR.encode!([
            "atoll.oauth.client-assertion-use.v1",
            issuer,
            verified.client_id,
            verified.jti
          ])
        )

      if Repo.get(ClientAssertionUse, digest, log: false),
        do: Repo.rollback(:client_assertion_replayed)

      if Repo.aggregate(ClientAssertionUse, :count) >= @capacity,
        do: Repo.rollback(:oauth_assertion_store_full)

      Repo.insert!(%ClientAssertionUse{digest: digest, expires_at: verified.expires_at},
        log: false
      )

      Map.put(verified, :metadata, client.metadata)
    end)
  end

  defp valid_time?(claims, now) do
    iat = claims["iat"]
    exp = claims["exp"]

    is_integer(iat) and is_integer(exp) and iat >= now - 300 and iat <= now + 30 and
      exp > now and exp > iat and exp <= iat + 300 and
      (not Map.has_key?(claims, "nbf") or (is_integer(claims["nbf"]) and claims["nbf"] <= now))
  end

  defp binding_matches?(_, :error), do: true

  defp binding_matches?(key, {:ok, %{kid: kid, alg: alg, jkt: jkt}}),
    do: key.kid == kid and key.alg == alg and key.jkt == jkt

  defp binding_matches?(_, _), do: false

  defp bounded_id?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: Regex.match?(~r/\A[\x21-\x7e]+\z/, value)

  defp bounded_id?(_), do: false

  defp object(value) do
    with {:ok, bytes} <- decode64(value), do: ClientMetadata.decode_document(bytes)
  end

  defp decode64(value) do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == value,
         do: {:ok, bytes},
         else: (_ -> {:error, :invalid_client_assertion})
  end

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end

  defp prune!(now) do
    ids =
      Repo.all(
        from(u in ClientAssertionUse,
          where: u.expires_at <= ^now,
          order_by: [asc: u.expires_at, asc: u.digest],
          limit: 1000,
          select: u.digest
        ),
        log: false
      )

    Repo.delete_all(from(u in ClientAssertionUse, where: u.digest in ^ids), log: false)
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
