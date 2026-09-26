defmodule Atoll.OAuth.Resource do
  @moduledoc """
  DPoP-bound OAuth reads and process-bound credentials for repository writes.
  Proof admission commits before request parsing and mutation transactions;
  account, source session, OAuth session and access-token locks protect the callback.
  The reader is trusted server code and must not perform mutations or network IO.
  Required scopes and issuer options are trusted endpoint policy, never request input.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.OAuth.{AccessToken, Session, Proofs, PKCE, ClientMetadata, WriteCredential}
  alias Atoll.Accounts.Session, as: AccountSession
  alias Atoll.Accounts.Signup
  alias Atoll.Repositories.Head

  def read(token, headers, url, reader, opts \\ []) when is_function(reader, 1),
    do: admit(token, headers, "GET", url, fn _, _, principal -> reader.(principal) end, opts)

  @write_methods %{
    create: "createRecord",
    put: "putRecord",
    delete: "deleteRecord",
    batch: "applyWrites",
    upload_blob: "uploadBlob"
  }

  @doc "Admit a POST proof and issue a process/method-bound internal credential, valid for 30 seconds."
  def prepare_write(token, headers, url, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    action =
      Enum.find_value(@write_methods, fn {action, method} ->
        if url == issuer <> "/xrpc/com.atproto.repo." <> method, do: action
      end)

    if action do
      admit(
        token,
        headers,
        "POST",
        url,
        fn access, session, _ ->
          claims = %{
            "digest" => Base.url_encode64(access.digest, padding: false),
            "binding" => fingerprint(session),
            "owner" => owner(),
            "action" => Atom.to_string(action),
            "expires" => clock!() + 30
          }

          %WriteCredential{
            receipt: Plug.Crypto.MessageVerifier.sign(Jason.encode!(claims), receipt_key(opts))
          }
        end,
        Keyword.put(opts, :required_scopes, ["transition:generic"])
      )
    else
      {:error, :invalid_request}
    end
  end

  @doc "Recheck an admitted credential inside the caller's write transaction without admitting its proof twice."
  def recheck(%WriteCredential{receipt: receipt}, action)
      when is_binary(receipt) and byte_size(receipt) <= 4096 do
    with true <- action in Map.keys(@write_methods),
         <<_::256>> = secret <- Application.get_env(:atoll, :oauth_nonce_secret),
         {:ok, body} <- Plug.Crypto.MessageVerifier.verify(receipt, receipt_key(secret: secret)),
         {:ok, %{} = claims} <- Jason.decode(body),
         true <- claims["owner"] == owner() and claims["action"] == Atom.to_string(action),
         true <- is_integer(claims["expires"]) and claims["expires"] > clock!(),
         true <- is_binary(claims["digest"]),
         {:ok, <<_::256>> = digest} <- Base.url_decode64(claims["digest"], padding: false),
         %AccessToken{} = access <- Repo.get(AccessToken, digest, log: false),
         %Session{} = session <- Repo.get(Session, access.session_id, log: false),
         true <- claims["binding"] == fingerprint(session) do
      locked_read(
        access,
        session,
        fn principal ->
          if claims["expires"] <= clock!(), do: Repo.rollback(:invalid_token)
          principal
        end,
        required_scopes: ["transition:generic"]
      )
    else
      _ -> {:error, :invalid_token}
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_resource_store_unavailable}
  end

  def recheck(_, _), do: {:error, :invalid_token}

  defp owner, do: :erlang.term_to_binary(self()) |> Base.url_encode64(padding: false)

  defp fingerprint(session),
    do:
      session_binding(session)
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

  defp receipt_key(opts),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        Keyword.get(opts, :secret, Application.get_env(:atoll, :oauth_nonce_secret)),
        "atoll.oauth.write-credential.v1"
      )

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end

  defp admit(token, headers, method, url, reader, opts) do
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    cond do
      Repo.in_transaction?() ->
        {:error, :oauth_resource_inside_transaction}

      not token?(token) ->
        {:error, :invalid_token}

      true ->
        digest = :crypto.hash(:sha256, token)

        with %AccessToken{} = access <- Repo.get(AccessToken, digest, log: false),
             %Session{} = candidate <- Repo.get(Session, access.session_id, log: false),
             true <- candidate.issuer == issuer,
             {:ok, _} <-
               Proofs.verify(
                 headers,
                 method,
                 url,
                 :resource,
                 Keyword.take(opts, [:secret]) ++
                   [issuer: issuer, access_token: token, jkt: candidate.dpop_jkt]
               ) do
          locked_read(
            access,
            candidate,
            fn principal -> reader.(access, candidate, principal) end,
            opts
          )
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_token}
        end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_resource_store_unavailable}
  end

  defp token?("atoll_access_" <> value), do: PKCE.challenge?(value)
  defp token?(_), do: false

  defp locked_read(access, candidate, reader, opts) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      head = Repo.one(from h in Head, where: h.did == ^candidate.did, lock: "FOR SHARE")

      if is_nil(head) or head.status != :active or Signup.pending?(head.did),
        do: Repo.rollback(:invalid_token)

      source =
        Repo.one(
          from(s in AccountSession,
            where: s.id == ^candidate.source_session_id and s.did == ^candidate.did,
            lock: "FOR SHARE"
          ),
          log: false
        )

      session =
        Repo.one(from(s in Session, where: s.id == ^candidate.id, lock: "FOR SHARE"), log: false)

      current =
        Repo.one(from(t in AccessToken, where: t.digest == ^access.digest, lock: "FOR SHARE"),
          log: false
        )

      %{rows: [[now]]} =
        Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

      if is_nil(source) or source.access_scope != "com.atproto.access" or source.expires_at <= now or
           is_nil(session) or session.expires_at <= now or
           session_binding(session) != session_binding(candidate) or
           is_nil(current) or current.session_id != session.id or current.expires_at <= now,
         do: Repo.rollback(:invalid_token)

      if not allowed?(current.scope, session.scope, Keyword.get(opts, :required_scopes, [])),
        do: Repo.rollback(:insufficient_scope)

      reader.(%{
        did: head.did,
        status: head.status,
        scope: current.scope,
        client_id: session.client_id
      })
    end)
  end

  defp session_binding(session),
    do:
      Map.take(session, [
        :did,
        :source_session_id,
        :issuer,
        :client_id,
        :client_binding,
        :dpop_jkt
      ])

  defp allowed?(scope, grant, required) do
    ClientMetadata.scopes_allowed?(%{"scope" => grant}, scope) and is_list(required) and
      Enum.all?(required, &(&1 in String.split(scope, " ")))
  end
end
