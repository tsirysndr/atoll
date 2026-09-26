defmodule Atoll.Accounts.Sessions do
  @moduledoc """
  Password session lifecycle for active repositories, used by the HTTP session API.

  Refresh rotates the refresh token once, without a retry grace period. Older
  access tokens remain valid until expiry or session revocation. Every access
  verification checks persistent session state and current repository availability.
  Options (signing key, audience, clock) are trusted configuration, never user input.
  """
  import Ecto.Query
  alias Atoll.{Repo, Repositories}
  alias Atoll.Accounts.{Credentials, Session, Tokens}
  alias Atoll.Repositories.Head

  def create(did, password, opts \\ []) do
    with {:ok, _} <- Credentials.verify(did, password),
         {:ok, limit} <- session_limit(opts),
         id = Tokens.random_id(),
         {:ok, pair} <- Tokens.pair(did, id, opts) do
      Repo.transaction(fn ->
        # Serialize account logins before counting so parallel creates cannot exceed the cap.
        active_head!(did, true)
        now = Keyword.get(opts, :now, System.system_time(:second))
        live = from s in Session, where: s.did == ^did and s.expires_at > ^now
        if Repo.aggregate(live, :count) >= limit, do: Repo.rollback(:session_limit_exceeded)

        Repo.insert!(
          %Session{
            id: id,
            did: did,
            refresh_hash: pair.refresh_hash,
            expires_at: pair.expires_at
          },
          log: false
        )

        response(did, pair)
      end)
    end
  end

  def authenticate(token, opts \\ []) do
    with {:ok, claims} <- Tokens.verify(token, :access, opts) do
      Repo.transaction(fn ->
        active_head!(claims["sub"])
        session!(claims, opts, false)
        %{did: claims["sub"]}
      end)
    end
  end

  def refresh(token, opts \\ []) do
    with {:ok, claims} <- Tokens.verify(token, :refresh, opts) do
      Repo.transaction(fn ->
        active_head!(claims["sub"])
        session = session!(claims, opts, true)
        matching_refresh!(session, claims)

        case Tokens.pair(session.did, session.id, opts) do
          {:ok, pair} ->
            session
            |> Ecto.Changeset.change(refresh_hash: pair.refresh_hash, expires_at: pair.expires_at)
            |> Repo.update!(log: false)

            response(session.did, pair)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Read-only account status authorization; accepts inactive repositories without granting write access."
  def authenticate_status(token) do
    with {:ok, claims} <- Tokens.verify(token, :access) do
      Repo.transaction(fn ->
        head =
          Repo.one(from h in Head, where: h.did == ^claims["sub"], lock: "FOR SHARE") ||
            Repo.rollback(:invalid_token)

        session!(claims, [], false)
        head
      end)
    end
  end

  @doc "Revokes a session with its current refresh token, even while the repository is inactive."
  def revoke(token, opts \\ []) do
    with {:ok, claims} <- Tokens.verify(token, :refresh, opts) do
      Repo.transaction(fn ->
        session = session!(claims, opts, true)
        matching_refresh!(session, claims)
        Repo.delete!(session, log: false)
        :ok
      end)
    end
  end

  defp session!(claims, opts, update?) do
    query = from s in Session, where: s.id == ^claims["sid"] and s.did == ^claims["sub"]

    query =
      if update?,
        do: from(s in query, lock: "FOR UPDATE"),
        else: from(s in query, lock: "FOR SHARE")

    session = Repo.one(query) || Repo.rollback(:invalid_token)
    now = Keyword.get(opts, :now, System.system_time(:second))
    if session.expires_at <= now, do: Repo.rollback(:expired_token)
    session
  end

  defp matching_refresh!(session, claims) do
    unless Plug.Crypto.secure_compare(session.refresh_hash, Tokens.digest(claims["jti"])) and
             session.expires_at == claims["exp"],
           do: Repo.rollback(:invalid_token)
  end

  defp session_limit(opts) do
    limit = Keyword.get(opts, :max_sessions, Application.get_env(:atoll, :session_max_count, 100))

    if is_integer(limit) and limit in 0..1000,
      do: {:ok, limit},
      else: {:error, :invalid_session_limit}
  end

  defp active_head!(did, update? \\ false) do
    query = from h in Head, where: h.did == ^did

    query =
      if update?,
        do: from(h in query, lock: "FOR UPDATE"),
        else: from(h in query, lock: "FOR SHARE")

    head =
      Repo.one(query) ||
        Repo.rollback(:invalid_token)

    case Repositories.availability(head) do
      :ok -> head
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp response(did, pair),
    do: %{did: did, access_jwt: pair.access_jwt, refresh_jwt: pair.refresh_jwt}
end
