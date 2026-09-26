defmodule Atoll.OAuth.Refresh do
  @moduledoc "Single-use opaque refresh rotation with bound proofs and durable reuse revocation."
  import Ecto.Query
  alias Atoll.Repo

  alias Atoll.OAuth.{
    Session,
    AccessToken,
    RefreshUse,
    PKCE,
    Proofs,
    PAR,
    ClientMetadata,
    ClientKeys,
    ClientAssertions
  }

  alias Atoll.Accounts.Session, as: AccountSession
  alias Atoll.Accounts.Signup
  alias Atoll.Repositories.Head
  @fields ~w(grant_type client_id refresh_token scope client_assertion_type client_assertion)

  def exchange(params, headers, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    cond do
      Repo.in_transaction?() ->
        {:error, :oauth_refresh_inside_transaction}

      not valid_input?(params) ->
        {:error, :invalid_request}

      true ->
        digest = :crypto.hash(:sha256, params["refresh_token"])

        with %Session{} = candidate <- find_session(digest),
             true <- candidate.client_id == params["client_id"] and candidate.issuer == issuer,
             {:ok, proof} <-
               Proofs.verify(
                 headers,
                 "POST",
                 issuer <> "/oauth/token",
                 :authorization,
                 Keyword.take(opts, [:secret]) ++ [issuer: issuer]
               ),
             true <- proof.jkt == candidate.dpop_jkt,
             {:ok, policy} <- client(candidate, params, opts),
             {:ok, scope} <- requested_scope(candidate, params) do
          commit(candidate, digest, policy, scope)
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_grant}
        end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_refresh_store_unavailable}
  end

  defp valid_input?(params) when is_map(params) and map_size(params) in 3..6 do
    Enum.all?(params, fn {k, v} -> k in @fields and is_binary(v) and byte_size(v) in 1..8192 end) and
      Enum.reduce(params, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end) <= 16_384 and
      params["grant_type"] == "refresh_token" and token?(params["refresh_token"]) and
      is_binary(params["client_id"]) and byte_size(params["client_id"]) <= 2048
  end

  defp valid_input?(_), do: false
  defp token?("atoll_refresh_" <> value), do: PKCE.challenge?(value)
  defp token?(_), do: false

  defp find_session(digest) do
    Repo.one(from(s in Session, where: s.refresh_digest == ^digest), log: false) ||
      Repo.one(
        from(u in RefreshUse,
          join: s in Session,
          on: s.id == u.session_id,
          where: u.digest == ^digest,
          select: s
        ),
        log: false
      )
  end

  defp client(%{client_binding: nil} = session, params, opts) do
    if Map.has_key?(params, "client_assertion") or Map.has_key?(params, "client_assertion_type") do
      {:error, :invalid_client}
    else
      with {:ok, %{"token_endpoint_auth_method" => "none"} = meta} <-
             ClientMetadata.fetch(session.client_id, opts),
           true <- current_policy?(session, meta),
           do: {:ok, :valid},
           else: (_ -> {:error, :invalid_client})
    end
  end

  defp client(session, params, opts) do
    binding = %{
      kid: session.client_binding["kid"],
      alg: session.client_binding["alg"],
      jkt: session.client_binding["jkt"]
    }

    with {:ok, client} <- ClientKeys.fetch(session.client_id, opts) do
      key = client.keys[binding.kid]

      if is_nil(key) or Map.take(key, [:kid, :alg, :jkt]) != binding do
        {:ok, :revoke}
      else
        with {:ok, _} <-
               ClientAssertions.authenticate_loaded(
                 params["client_assertion_type"],
                 params["client_assertion"],
                 client,
                 session.issuer,
                 Keyword.put(opts, :binding, binding)
               ),
             true <- current_policy?(session, client.metadata),
             do: {:ok, :valid},
             else: (
               false -> {:error, :invalid_client}
               error -> error
             )
      end
    end
  end

  defp current_policy?(session, meta),
    do:
      "refresh_token" in meta["grant_types"] and
        ClientMetadata.scopes_allowed?(meta, session.scope)

  defp requested_scope(session, params) do
    scope = Map.get(params, "scope", session.scope)
    values = String.split(scope, " ")

    if ClientMetadata.scopes_allowed?(%{"scope" => session.scope}, scope) and
         ("transition:chat.bsky" not in values or "transition:generic" in values),
       do: {:ok, scope},
       else: {:error, :invalid_scope}
  end

  defp commit(candidate, digest, policy, scope) do
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

      session =
        Repo.one(from(s in Session, where: s.id == ^candidate.id, lock: "FOR UPDATE"), log: false)

      if is_nil(session) or immutable(session) != immutable(candidate) or
           session.expires_at <= now or source.expires_at <= now,
         do: Repo.rollback(:invalid_grant)

      used = Repo.get(RefreshUse, digest, log: false)

      cond do
        policy == :revoke or (used && used.session_id == session.id) ->
          Repo.delete!(session, log: false)
          {:error, :invalid_grant}

        session.refresh_digest != digest ->
          Repo.rollback(:invalid_grant)

        true ->
          {:ok, rotate!(session, scope, min(session.expires_at, source.expires_at), now)}
      end
    end)
    |> case do
      {:ok, result} -> result
      error -> error
    end
  end

  defp immutable(session), do: Map.drop(Map.from_struct(session), [:__meta__, :refresh_digest])

  defp rotate!(session, scope, expires, now) do
    ids =
      Repo.all(
        from(u in RefreshUse,
          where: u.expires_at <= ^now,
          order_by: [asc: u.expires_at, asc: u.digest],
          limit: 1000,
          select: u.digest
        ),
        log: false
      )

    Repo.delete_all(from(u in RefreshUse, where: u.digest in ^ids), log: false)

    Repo.delete_all(
      from(t in AccessToken, where: t.session_id == ^session.id and t.expires_at <= ^now),
      log: false
    )

    if Repo.aggregate(RefreshUse, :count) >= 100_000 or
         Repo.aggregate(from(t in AccessToken, where: t.session_id == ^session.id), :count) >= 100,
       do: Repo.rollback(:oauth_refresh_store_full)

    refresh = "atoll_refresh_" <> random()
    access = "atoll_access_" <> random()
    access_expires = min(now + 300, expires)

    Repo.insert!(
      %RefreshUse{
        digest: session.refresh_digest,
        session_id: session.id,
        expires_at: session.expires_at
      },
      log: false
    )

    session
    |> Ecto.Changeset.change(refresh_digest: :crypto.hash(:sha256, refresh))
    |> Repo.update!(log: false)

    Repo.insert!(
      %AccessToken{
        digest: :crypto.hash(:sha256, access),
        session_id: session.id,
        scope: scope,
        expires_at: access_expires
      },
      log: false
    )

    %{
      access_token: access,
      refresh_token: refresh,
      token_type: "DPoP",
      expires_in: access_expires - now,
      scope: scope,
      sub: session.did
    }
  end

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
