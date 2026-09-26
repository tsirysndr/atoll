defmodule Atoll.Accounts.Sessions do
  @moduledoc """
  Password sessions, including restricted export sessions for taken-down repositories, used by the HTTP session API.

  Refresh rotates the refresh token once, without a retry grace period. Older
  access tokens remain valid until expiry or session revocation. Every access
  verification checks persistent session state and current repository availability.
  Options (signing key, audience, clock) are trusted configuration, never user input.
  """
  import Ecto.Query
  alias Atoll.{Repo, Repositories}
  alias Atoll.Accounts.{AppPasswords, Credentials, EmailAddress, Profile, Session, Tokens}
  alias Atoll.Repositories.Head

  def create(did, password, opts \\ []) do
    case Credentials.verified_digest(did, password) do
      {:ok, digest} ->
        with :ok <- Atoll.Accounts.EmailFactor.challenge(did, digest, opts),
             do: create_for_account(did, Keyword.put(opts, :credential_digest, digest))

      {:error, :invalid_credentials} ->
        with {:ok, app} <- AppPasswords.verify(did, password),
             do:
               create_for_account(
                 did,
                 Keyword.merge(opts, app_password_id: app.id, access_scope: app.scope)
               )
    end
  end

  @doc "Creates a password session using a local account email, rechecking ownership under the account lock."
  def create_email(email, password, opts \\ []) do
    with {:ok, email} <- EmailAddress.normalize(email) do
      case Repo.get_by(Profile, [email: email], log: false) do
        %Profile{did: did} ->
          create(did, password, Keyword.put(opts, :login_email, email))

        nil ->
          Argon2.no_user_verify(argon2_type: 2)
          {:error, :invalid_credentials}
      end
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @doc "Internal session creation after credentials or provisioning have been authorized by the caller."
  def create_for_account(did, opts \\ []) do
    with {:ok, limit} <- session_limit(opts) do
      id = Tokens.random_id()

      Repo.transaction(fn ->
        # Serialize account logins before counting so parallel creates cannot exceed the cap.
        head = active_head!(did, true, true, opts[:allow_takendown] == true)
        if Atoll.Accounts.Signup.pending?(did), do: Repo.rollback(:signup_pending)
        # Password verification happens outside locks; reject a proof made stale by recovery.
        if digest = opts[:credential_digest] do
          unless Credentials.current_digest?(did, digest), do: Repo.rollback(:invalid_credentials)
        end

        if email = opts[:login_email] do
          unless Repo.exists?(from(p in Profile, where: p.did == ^did and p.email == ^email),
                   log: false
                 ),
                 do: Repo.rollback(:invalid_credentials)
        end

        if app_id = opts[:app_password_id] do
          unless AppPasswords.current?(did, app_id, opts[:access_scope]),
            do: Repo.rollback(:invalid_credentials)
        end

        if digest = opts[:credential_digest] do
          Atoll.Accounts.EmailFactor.consume!(did, digest, opts[:auth_factor_token])
        end

        now = Keyword.get(opts, :now, System.system_time(:second))
        live = from s in Session, where: s.did == ^did and s.expires_at > ^now
        if Repo.aggregate(live, :count) >= limit, do: Repo.rollback(:session_limit_exceeded)

        original_scope = Keyword.get(opts, :access_scope, "com.atproto.access")

        unless original_scope in [
                 "com.atproto.access",
                 "com.atproto.appPass",
                 "com.atproto.appPassPrivileged"
               ],
               do: Repo.rollback(:invalid_token)

        scope = if head.status == :takendown, do: "com.atproto.takendown", else: original_scope

        pair =
          case Tokens.pair(did, id, Keyword.put(opts, :access_scope, scope)) do
            {:ok, pair} -> pair
            {:error, reason} -> Repo.rollback(reason)
          end

        Repo.insert!(
          %Session{
            id: id,
            did: did,
            app_password_id: opts[:app_password_id],
            access_scope: Keyword.get(opts, :access_scope, "com.atproto.access"),
            refresh_hash: pair.refresh_hash,
            expires_at: pair.expires_at
          },
          log: false
        )

        response(head, pair, scope)
      end)
    end
  end

  def authenticate(token, opts \\ []) do
    with {:ok, claims} <- Tokens.verify(token, :access, opts),
         :ok <- ordinary_scope(claims) do
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
        head = active_head!(claims["sub"], false, true)
        session = session!(claims, opts, true)
        matching_refresh!(session, claims)

        case Tokens.pair(
               session.did,
               session.id,
               Keyword.put(opts, :access_scope, session.access_scope)
             ) do
          {:ok, pair} ->
            session
            |> Ecto.Changeset.change(refresh_hash: pair.refresh_hash, expires_at: pair.expires_at)
            |> Repo.update!(log: false)

            response(head, pair, session.access_scope)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Read-only account status authorization; accepts inactive repositories without granting write access."
  def authenticate_status(token) do
    with {:ok, claims} <- Tokens.verify(token, :access),
         :ok <- full_scope(claims) do
      Repo.transaction(fn ->
        head =
          Repo.one(from h in Head, where: h.did == ^claims["sub"], lock: "FOR SHARE") ||
            Repo.rollback(:invalid_token)

        session!(claims, [], false)
        head
      end)
    end
  end

  @doc "Authorizes session management for active or deactivated accounts; not ordinary write permission."
  def authenticate_management(token, opts \\ []) do
    with {:ok, claims} <- Tokens.verify(token, :access, opts),
         :ok <- full_scope(claims) do
      Repo.transaction(fn ->
        head = active_head!(claims["sub"], false, true)
        session!(claims, opts, false)
        head
      end)
    end
  end

  @doc "Inspects a live session, including restricted app sessions; does not authorize account management."
  def authenticate_session(token, opts \\ []) do
    with {:ok, claims} <- Tokens.verify(token, :access, opts),
         :ok <- ordinary_scope(claims) do
      Repo.transaction(fn ->
        head = active_head!(claims["sub"], false, true)
        session!(claims, opts, false)
        %{did: head.did, status: head.status, scope: claims["scope"]}
      end)
    end
  end

  @doc "Authorize live owner exports or revalidated operator credentials; non-owner user targets must be active."
  def authenticate_export(token, did, opts \\ [])

  def authenticate_export({:admin, headers}, did, _opts) do
    with :ok <- Atoll.Accounts.AdminAuth.authenticate(headers) do
      Repo.transaction(fn ->
        Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE") ||
          Repo.rollback(:not_found)
      end)
    else
      _ -> {:error, :invalid_token}
    end
  end

  def authenticate_export(token, did, opts) do
    with {:ok, claims} <- Tokens.verify(token, :access, opts) do
      Repo.transaction(fn ->
        owner = active_head!(claims["sub"], false, true, true)
        session!(claims, opts, false)
        if owner.did == did, do: owner, else: active_head!(did)
      end)
    end
  end

  defp ordinary_scope(%{"scope" => "com.atproto.takendown"}), do: {:error, :forbidden}
  defp ordinary_scope(_), do: :ok

  defp full_scope(%{"scope" => "com.atproto.access"}), do: :ok
  defp full_scope(_), do: {:error, :forbidden}

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

    if claims["scope"] not in ["com.atproto.refresh", "com.atproto.takendown"] and
         claims["scope"] != session.access_scope,
       do: Repo.rollback(:invalid_token)

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

  defp active_head!(did, update? \\ false, allow_deactivated? \\ false, allow_takendown? \\ false) do
    query = from h in Head, where: h.did == ^did

    query =
      if update?,
        do: from(h in query, lock: "FOR UPDATE"),
        else: from(h in query, lock: "FOR SHARE")

    head =
      Repo.one(query) ||
        Repo.rollback(:invalid_token)

    if allow_takendown? and head.status == :takendown and head.pre_takedown_status == :suspended,
      do: Repo.rollback({:repo_inactive, :suspended})

    case Repositories.availability(head) do
      :ok -> head
      {:error, {:repo_inactive, :deactivated}} when allow_deactivated? -> head
      {:error, {:repo_inactive, :takendown}} when allow_takendown? -> head
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp response(head, pair, scope),
    do: %{
      did: head.did,
      status: head.status,
      scope: scope,
      access_jwt: pair.access_jwt,
      refresh_jwt: pair.refresh_jwt
    }
end
