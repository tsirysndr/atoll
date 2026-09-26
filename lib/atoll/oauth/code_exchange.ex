defmodule Atoll.OAuth.CodeExchange do
  @moduledoc """
  Internal authorization-code exchange into opaque, database-backed OAuth tokens.
  Requires fresh client authentication and a new token-endpoint DPoP proof.
  Verified code reuse commits revocation of the originally issued session.
  HTTP token routing, refresh and resource authorization are separate components.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Repositories.Head
  alias Atoll.Accounts.Signup
  alias Atoll.Accounts.Session, as: AccountSession

  alias Atoll.OAuth.{
    AuthorizationCode,
    ClientMetadata,
    ClientAssertions,
    PKCE,
    Proofs,
    PAR,
    Session,
    AccessToken
  }

  @fields ~w(grant_type client_id code redirect_uri code_verifier client_assertion_type client_assertion)

  def exchange(params, headers, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    cond do
      Repo.in_transaction?() ->
        {:error, :oauth_exchange_inside_transaction}

      not valid_input?(params) ->
        {:error, :invalid_request}

      true ->
        with %AuthorizationCode{} = candidate <-
               Repo.get(AuthorizationCode, :crypto.hash(:sha256, params["code"]), log: false),
             true <- bindings?(candidate, params, issuer),
             {:ok, metadata} <- client(candidate, params, opts),
             true <- current_policy?(candidate, metadata),
             {:ok, proof} <-
               Proofs.verify(
                 headers,
                 "POST",
                 issuer <> "/oauth/token",
                 :authorization,
                 Keyword.take(opts, [:secret]) ++ [issuer: issuer]
               ),
             true <- proof.jkt == candidate.dpop_jkt do
          commit(candidate, params, issuer)
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_grant}
        end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_exchange_store_unavailable}
  end

  defp valid_input?(params) when is_map(params) and map_size(params) in 5..7 do
    Enum.all?(params, fn {k, v} -> k in @fields and is_binary(v) and byte_size(v) in 1..8192 end) and
      Enum.reduce(params, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end) <= 16_384 and
      params["grant_type"] == "authorization_code" and PKCE.challenge?(params["code"]) and
      is_binary(params["client_id"]) and byte_size(params["client_id"]) <= 2048 and
      is_binary(params["redirect_uri"]) and byte_size(params["redirect_uri"]) <= 2048 and
      is_binary(params["code_verifier"]) and byte_size(params["code_verifier"]) in 43..128
  end

  defp valid_input?(_), do: false

  defp bindings?(code, params, issuer),
    do:
      code.issuer == issuer and code.client_id == params["client_id"] and
        code.redirect_uri == params["redirect_uri"] and
        PKCE.verify(params["code_verifier"], code.code_challenge)

  defp client(%{client_binding: nil} = code, params, opts) do
    if Map.has_key?(params, "client_assertion") or Map.has_key?(params, "client_assertion_type") do
      {:error, :invalid_client}
    else
      with {:ok, %{"token_endpoint_auth_method" => "none"} = metadata} <-
             ClientMetadata.fetch(code.client_id, opts),
           do: {:ok, metadata},
           else: (_ -> {:error, :invalid_client})
    end
  end

  defp client(code, params, opts) do
    binding = %{
      kid: code.client_binding["kid"],
      alg: code.client_binding["alg"],
      jkt: code.client_binding["jkt"]
    }

    with {:ok, client} <-
           ClientAssertions.authenticate(
             code.client_id,
             params["client_assertion_type"],
             params["client_assertion"],
             code.issuer,
             Keyword.put(opts, :binding, binding)
           ),
         do: {:ok, client.metadata}
  end

  defp current_policy?(code, metadata),
    do:
      ClientMetadata.redirect_allowed?(metadata, code.redirect_uri) and
        ClientMetadata.scopes_allowed?(metadata, code.scope) and
        (not code.refresh_allowed or "refresh_token" in metadata["grant_types"])

  defp commit(candidate, params, issuer) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      head = Repo.one(from h in Head, where: h.did == ^candidate.did, lock: "FOR SHARE")

      if is_nil(head) or head.status != :active or Signup.pending?(head.did),
        do: Repo.rollback(:invalid_grant)

      source =
        Repo.one(
          from(s in AccountSession,
            where: s.id == ^candidate.source_session_id and s.did == ^candidate.did,
            lock: "FOR SHARE"
          ),
          log: false
        )

      if is_nil(source) or source.access_scope != "com.atproto.access",
        do: Repo.rollback(:invalid_grant)

      PAR.lock!()
      now = clock!()
      if source.expires_at <= now, do: Repo.rollback(:invalid_grant)

      code =
        Repo.one(
          from(c in AuthorizationCode, where: c.digest == ^candidate.digest, lock: "FOR UPDATE"),
          log: false
        )

      if is_nil(code) or not bindings?(code, params, issuer) or
           immutable(code) != immutable(candidate),
         do: Repo.rollback(:invalid_grant)

      if code.redeemed_at do
        # Return an error as transaction data so revocation commits rather than
        # being rolled back with an invalid_grant response.
        if code.redeemed_session_id,
          do:
            Repo.delete_all(from(s in Session, where: s.id == ^code.redeemed_session_id),
              log: false
            )

        {:error, :invalid_grant}
      else
        if code.expires_at <= now, do: Repo.rollback(:invalid_grant)
        prune_sessions!(now)

        if Repo.aggregate(Session, :count) >= 10_000 or
             Repo.aggregate(
               from(s in Session, where: s.did == ^code.did and s.expires_at > ^now),
               :count
             ) >= 100,
           do: Repo.rollback(:oauth_session_limit)

        {:ok, issue!(code, source, now)}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp immutable(code),
    do:
      Map.drop(Map.from_struct(code), [
        :__meta__,
        :redeemed_at,
        :redeemed_session_id,
        :replay_until
      ])

  defp issue!(code, source, now) do
    ttl =
      cond do
        not code.refresh_allowed -> 300
        is_nil(code.client_binding) -> 14 * 86_400
        true -> 180 * 86_400
      end

    expires = min(now + ttl, source.expires_at)
    access = "atoll_access_" <> random()
    refresh = if code.refresh_allowed, do: "atoll_refresh_" <> random()

    session =
      Repo.insert!(
        %Session{
          id: random(),
          did: code.did,
          source_session_id: source.id,
          issuer: code.issuer,
          client_id: code.client_id,
          scope: code.scope,
          dpop_jkt: code.dpop_jkt,
          client_binding: code.client_binding,
          refresh_digest: if(refresh, do: :crypto.hash(:sha256, refresh)),
          expires_at: expires
        },
        log: false
      )

    access_expires = min(now + 300, expires)

    Repo.insert!(
      %AccessToken{
        digest: :crypto.hash(:sha256, access),
        session_id: session.id,
        scope: session.scope,
        expires_at: access_expires
      },
      log: false
    )

    code
    |> Ecto.Changeset.change(
      redeemed_at: now,
      redeemed_session_id: session.id,
      replay_until: expires
    )
    |> Repo.update!(log: false)

    response = %{
      access_token: access,
      token_type: "DPoP",
      expires_in: access_expires - now,
      scope: code.scope,
      sub: code.did
    }

    if refresh, do: Map.put(response, :refresh_token, refresh), else: response
  end

  defp prune_sessions!(now) do
    ids =
      Repo.all(
        from(s in Session,
          where: s.expires_at <= ^now,
          order_by: [asc: s.expires_at, asc: s.id],
          limit: 1000,
          select: s.id
        ),
        log: false
      )

    Repo.delete_all(from(s in Session, where: s.id in ^ids), log: false)
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end
end
