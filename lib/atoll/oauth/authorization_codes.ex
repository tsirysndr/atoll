defmodule Atoll.OAuth.AuthorizationCodes do
  @moduledoc """
  Internal approval/denial of a pushed request by a full account session.
  The browser adapter must establish CSRF-protected explicit consent and pass
  :deny or {:approve, granted_scope}. This module does not render consent or
  redeem codes. Transport/session options are trusted server configuration.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{Sessions, Tokens, Signup}
  alias Atoll.OAuth.{PAR, PushedRequest, ClientMetadata, ClientKeys, AuthorizationCode}

  def decide(token, client_id, uri, decision, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :oauth_authorization_inside_transaction}
    else
      with {:ok, _} <- authorize(token, session_opts(opts)),
           {:ok, request} <- PAR.get(client_id, uri, opts),
           :ok <- decision_valid(decision, request),
           {:ok, metadata} <- current_client(request, decision, opts) do
        commit(token, request, decision, metadata, opts)
      end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_authorization_store_unavailable}
  end

  defp decision_valid(:deny, _), do: :ok

  defp decision_valid({:approve, scope}, request) do
    if ClientMetadata.scopes_allowed?(%{"scope" => request.parameters["scope"]}, scope) and
         ("transition:chat.bsky" not in String.split(scope, " ") or
            "transition:generic" in String.split(scope, " ")),
       do: :ok,
       else: {:error, :invalid_scope}
  end

  defp decision_valid(_, _), do: {:error, :invalid_consent}

  defp current_client(_, :deny, _), do: {:ok, nil}

  defp current_client(request, {:approve, scope}, opts) do
    result =
      if is_nil(request.client_binding) do
        with {:ok, %{"token_endpoint_auth_method" => "none"} = metadata} <-
               ClientMetadata.fetch(request.client_id, opts),
             do: {:ok, metadata},
             else: (_ -> {:error, :invalid_client})
      else
        binding = request.client_binding

        with {:ok, client} <- ClientKeys.fetch(request.client_id, opts),
             %{alg: alg, jkt: jkt} <- client.keys[binding["kid"]],
             true <- alg == binding["alg"] and jkt == binding["jkt"],
             do: {:ok, client.metadata},
             else: (_ -> {:error, :invalid_client})
      end

    with {:ok, metadata} <- result,
         true <- ClientMetadata.redirect_allowed?(metadata, request.parameters["redirect_uri"]),
         true <- ClientMetadata.scopes_allowed?(metadata, scope),
         do: {:ok, metadata},
         else: (_ -> {:error, :invalid_client})
  end

  defp commit(token, snapshot, decision, metadata, opts) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      # Keep account/session-before-PAR lock order. Account deletion and session
      # revocation cannot pass their locks until the decision commits.
      unwrap!(authorize(token, Keyword.put(session_opts(opts), :now, clock!())))
      PAR.lock!()
      now = clock!()
      {head, claims} = unwrap!(authorize(token, Keyword.put(session_opts(opts), :now, now)))

      request =
        Repo.one(
          from(r in PushedRequest, where: r.digest == ^snapshot.digest, lock: "FOR UPDATE"),
          log: false
        )

      if is_nil(request) or request != snapshot or request.expires_at <= now,
        do: Repo.rollback(:invalid_request_uri)

      response = %{
        redirect_uri: request.parameters["redirect_uri"],
        state: request.parameters["state"],
        iss: request.issuer
      }

      response =
        case decision do
          :deny ->
            Map.put(response, :error, "access_denied")

          {:approve, scope} ->
            prune!(now)

            if Repo.aggregate(AuthorizationCode, :count) >= 10_000,
              do: Repo.rollback(:oauth_code_store_full)

            code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

            Repo.insert!(
              %AuthorizationCode{
                digest: :crypto.hash(:sha256, code),
                did: head.did,
                source_session_id: claims["sid"],
                issuer: request.issuer,
                client_id: request.client_id,
                redirect_uri: request.parameters["redirect_uri"],
                scope: scope,
                code_challenge: request.parameters["code_challenge"],
                dpop_jkt: request.dpop_jkt,
                client_binding: request.client_binding,
                refresh_allowed: "refresh_token" in metadata["grant_types"],
                expires_at: now + 120
              },
              log: false
            )

            Map.put(response, :code, code)
        end

      Repo.delete!(request, log: false)
      response
    end)
  end

  defp authorize(token, opts) do
    with {:ok, head} <- Sessions.authenticate_management(token, opts),
         true <- head.status == :active and not Signup.pending?(head.did),
         {:ok, claims} <- Tokens.verify(token, :access, opts),
         do: {:ok, {head, claims}},
         else: (
           false -> {:error, :account_unavailable}
           error -> error
         )
  end

  defp session_opts(opts),
    do: opts |> Keyword.get(:session_options, []) |> Keyword.take([:secret, :audience])

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end

  defp prune!(now) do
    ids =
      Repo.all(
        from(c in AuthorizationCode,
          where: c.expires_at <= ^now,
          order_by: [asc: c.expires_at, asc: c.digest],
          limit: 1000,
          select: c.digest
        ),
        log: false
      )

    Repo.delete_all(from(c in AuthorizationCode, where: c.digest in ^ids), log: false)
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
