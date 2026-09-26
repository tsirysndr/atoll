defmodule Atoll.OAuth.PAR do
  @moduledoc """
  Internal pushed authorization admission. Persists validated parameters and
  client/DPoP bindings, not consent or a grant. Input is a decoded parameter map;
  the HTTP adapter rejects duplicate form fields before constructing it.
  Issuer, transport and nonce-secret options are trusted server configuration.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.OAuth.{ClientMetadata, ClientAssertions, Proofs, PKCE, PKCEUse, PushedRequest}
  @prefix "urn:ietf:params:oauth:request_uri:"
  @fields ~w(client_id response_type redirect_uri scope state code_challenge code_challenge_method login_hint dpop_jkt client_assertion_type client_assertion)
  @stored ~w(client_id response_type redirect_uri scope state code_challenge code_challenge_method login_hint)
  @scopes ~w(atproto transition:generic transition:chat.bsky transition:email)
  @lock 4_182_026_052

  @doc false
  def lock! do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "PAR lock requires a transaction")
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock])
  end

  def push(params, headers, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    cond do
      Repo.in_transaction?() ->
        {:error, :oauth_par_inside_transaction}

      not valid_input?(params) ->
        {:error, :invalid_request}

      not is_binary(issuer) or byte_size(issuer) not in 1..2048 ->
        {:error, :invalid_request}

      true ->
        with {:ok, client} <- client(params, issuer, opts),
             :ok <- validate(params, client.metadata),
             {:ok, proof} <-
               Proofs.verify(
                 headers,
                 "POST",
                 issuer <> "/oauth/par",
                 :authorization,
                 Keyword.take(opts, [:secret]) ++ [issuer: issuer]
               ),
             true <- not Map.has_key?(params, "dpop_jkt") or params["dpop_jkt"] == proof.jkt do
          persist(params, client.binding, proof.jkt, issuer)
        else
          false -> {:error, :invalid_dpop_proof}
          {:error, _} = error -> error
        end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :oauth_par_store_unavailable}
  end

  @doc "Reads a live client/issuer-bound request. Does not consume it or authorize an account."
  def get(client_id, request_uri, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    with true <- is_binary(client_id) and byte_size(client_id) in 1..2048,
         true <- is_binary(issuer) and byte_size(issuer) in 1..2048,
         {:ok, digest} <- request_digest(request_uri),
         %PushedRequest{} = request <-
           Repo.one(
             from(r in PushedRequest,
               where:
                 r.digest == ^digest and r.client_id == ^client_id and r.issuer == ^issuer and
                   r.expires_at > fragment("floor(extract(epoch FROM clock_timestamp()))::bigint")
             ),
             log: false
           ) do
      {:ok, request}
    else
      _ -> {:error, :invalid_request_uri}
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :oauth_par_store_unavailable}
  end

  defp valid_input?(params) when is_map(params) and map_size(params) <= 11 do
    Enum.all?(params, fn {k, v} ->
      k in @fields and is_binary(v) and byte_size(v) in 1..8192 and String.valid?(v)
    end) and
      Enum.reduce(params, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end) <= 16_384 and
      params["response_type"] == "code" and params["code_challenge_method"] == "S256" and
      PKCE.challenge?(params["code_challenge"]) and text?(params["state"], 2048) and
      text?(params["client_id"], 2048) and text?(params["redirect_uri"], 2048) and
      text?(params["scope"], 4096) and
      (not Map.has_key?(params, "login_hint") or text?(params["login_hint"], 2048))
  end

  defp valid_input?(_), do: false

  defp text?(value, max) when is_binary(value),
    do: byte_size(value) in 1..max and not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp text?(_, _), do: false

  defp client(params, issuer, opts) do
    if Map.has_key?(params, "client_assertion") or Map.has_key?(params, "client_assertion_type") do
      with {:ok, verified} <-
             ClientAssertions.authenticate(
               params["client_id"],
               params["client_assertion_type"],
               params["client_assertion"],
               issuer,
               opts
             ),
           do: {:ok, %{metadata: verified.metadata, binding: verified.binding}}
    else
      with {:ok, %{"token_endpoint_auth_method" => "none"} = metadata} <-
             ClientMetadata.fetch(params["client_id"], opts),
           do: {:ok, %{metadata: metadata, binding: nil}},
           else: (_ -> {:error, :invalid_client})
    end
  end

  defp validate(params, metadata) do
    scopes = String.split(params["scope"], " ")

    cond do
      not ClientMetadata.redirect_allowed?(metadata, params["redirect_uri"]) ->
        {:error, :invalid_redirect_uri}

      not ClientMetadata.scopes_allowed?(metadata, params["scope"]) ->
        {:error, :invalid_scope}

      not Enum.all?(scopes, &(&1 in @scopes)) ->
        {:error, :invalid_scope}

      "transition:chat.bsky" in scopes and "transition:generic" not in scopes ->
        {:error, :invalid_scope}

      true ->
        :ok
    end
  end

  defp persist(params, binding, jkt, issuer) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      lock!()

      %{rows: [[now]]} =
        Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

      prune!(PushedRequest, now)
      prune!(PKCEUse, now)

      challenge_digest =
        :crypto.hash(
          :sha256,
          Atoll.CBOR.encode!([
            "atoll.oauth.pkce-use.v1",
            issuer,
            params["code_challenge"]
          ])
        )

      if Repo.get(PKCEUse, challenge_digest, log: false),
        do: Repo.rollback(:pkce_challenge_reused)

      if Repo.aggregate(PushedRequest, :count) >= 10_000 or
           Repo.aggregate(PKCEUse, :count) >= 100_000,
         do: Repo.rollback(:oauth_par_store_full)

      uri = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      {:ok, digest} = request_digest(uri)
      Repo.insert!(%PKCEUse{digest: challenge_digest, expires_at: now + 86_400}, log: false)

      Repo.insert!(
        %PushedRequest{
          digest: digest,
          issuer: issuer,
          client_id: params["client_id"],
          parameters: Map.take(params, @stored),
          client_binding: binding,
          dpop_jkt: jkt,
          expires_at: now + 90
        },
        log: false
      )

      %{request_uri: uri, expires_in: 90}
    end)
  end

  defp request_digest(@prefix <> token = uri) when byte_size(token) == 43 do
    if PKCE.challenge?(token),
      do: {:ok, :crypto.hash(:sha256, uri)},
      else: {:error, :invalid_request_uri}
  end

  defp request_digest(_), do: {:error, :invalid_request_uri}

  defp prune!(schema, now) do
    ids =
      Repo.all(
        from(r in schema,
          where: r.expires_at <= ^now,
          order_by: [asc: r.expires_at, asc: r.digest],
          limit: 1000,
          select: r.digest
        ),
        log: false
      )

    Repo.delete_all(from(r in schema, where: r.digest in ^ids), log: false)
  end
end
