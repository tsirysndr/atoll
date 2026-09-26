defmodule Atoll.Accounts.Passkeys do
  @moduledoc """
  Internal passkey lifecycle. Browser bindings are trusted random server cookie
  values, not request parameters. HTTP callers must enforce CSRF and rate limits.
  Standalone transactions consume matched challenges even on verification failure.
  User-verified passkeys are an alternative to password and its optional factors.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Repositories.Head

  alias Atoll.Accounts.{
    Authenticator,
    Credential,
    Credentials,
    Passkey,
    PasskeyUser,
    PasskeyChallenge,
    Sessions,
    Tokens,
    TOTPFactor,
    WebAuthn
  }

  @lock 4_182_026_053

  def enabled?, do: Application.get_env(:atoll, :passkeys_enabled, true) == true

  def begin_registration(token, password, browser, name, opts \\ []) do
    with :ok <- enabled(),
         true <- binding?(browser) and name?(name),
         {:ok, context} <- WebAuthn.challenge(AtollWeb.Endpoint.url()),
         {:ok, head, digest, admission} <- fresh_owner(token, password, opts[:totp_code]) do
      transact(fn ->
        owner!(token, head.did, digest)
        Authenticator.recheck!(head.did, admission)

        if Repo.aggregate(from(k in Passkey, where: k.did == ^head.did), :count) >= 10,
          do: Repo.rollback(:passkey_limit)

        user =
          Repo.get(PasskeyUser, head.did, log: false) ||
            Repo.insert!(%PasskeyUser{did: head.did, user_handle: :crypto.strong_rand_bytes(32)},
              log: false
            )

        session_id = session_id!(token)

        {reference, row} =
          issue!(context, browser, %{
            kind: "register",
            did: head.did,
            source_session_id: session_id,
            credential_digest: digest,
            totp_version: factor_version(head.did),
            name: name
          })

        excluded =
          Repo.all(from(k in Passkey, where: k.did == ^head.did and k.rp_id == ^context.rp_id),
            log: false
          )

        {:ok,
         %{
           reference: reference,
           public_key: %{
             challenge: base(row.challenge),
             rp: %{id: row.rp_id, name: "Atoll"},
             user: %{id: base(user.user_handle), name: head.did, displayName: head.did},
             pubKeyCredParams: [%{type: "public-key", alg: -7}],
             timeout: 300_000,
             attestation: "none",
             authenticatorSelection: %{
               residentKey: "required",
               requireResidentKey: true,
               userVerification: "required"
             },
             excludeCredentials:
               Enum.map(excluded, &%{type: "public-key", id: base(&1.credential_id)})
           }
         }}
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def complete_registration(token, browser, reference, response) do
    with :ok <- enabled(),
         {:ok, head} <- Sessions.authenticate_management(token) do
      transact(fn ->
        owner!(token, head.did, nil)
        session_id = session_id!(token)

        with {:ok, row} <- consume(reference, browser, "register"),
             true <- row.did == head.did and row.source_session_id == session_id,
             true <- Credentials.current_digest?(head.did, row.credential_digest),
             true <- row.totp_version == factor_version(head.did),
             {:ok, credential} <- WebAuthn.register(response, context(row)),
             true <- Repo.aggregate(from(k in Passkey, where: k.did == ^head.did), :count) < 10 do
          attrs =
            credential
            |> Map.take([
              :credential_id,
              :public_key,
              :sign_count,
              :backup_eligible,
              :backup_state
            ])
            |> Map.merge(%{
              id: Ecto.UUID.generate(),
              did: head.did,
              rp_id: row.rp_id,
              name: row.name,
              created_at: clock!()
            })

          case Repo.insert_all(Passkey, [attrs],
                 on_conflict: :nothing,
                 returning: [:id],
                 log: false
               ) do
            {1, [%{id: id}]} -> {:ok, %{id: id}}
            _ -> {:error, :passkey_already_registered}
          end
        else
          _ -> {:error, :invalid_passkey}
        end
      end)
    end
  end

  def begin_login(browser) do
    with :ok <- enabled(),
         true <- binding?(browser),
         {:ok, context} <- WebAuthn.challenge(AtollWeb.Endpoint.url()) do
      transact(fn ->
        {reference, row} = issue!(context, browser, %{kind: "login"})

        {:ok,
         %{
           reference: reference,
           public_key: %{
             challenge: base(row.challenge),
             rpId: row.rp_id,
             timeout: 300_000,
             userVerification: "required"
           }
         }}
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def complete_login(browser, reference, response) do
    with :ok <- enabled(),
         {:ok, admission} <- admit_login(browser, reference, response) do
      Sessions.create_for_account(admission.did,
        passkey_id: admission.id,
        passkey_admission: admission
      )
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :passkey_store_unavailable}
  end

  defp admit_login(browser, reference, response) do
    transact(fn ->
      # Snapshot the owner only; verify current key material after taking its head lock.
      snapshot = credential(response)
      if snapshot, do: lock_head!(snapshot.did)

      with {:ok, row} <- consume(reference, browser, "login"),
           %Passkey{} = key <- if(snapshot, do: Repo.get(Passkey, snapshot.id, log: false)),
           true <- key.rp_id == row.rp_id,
           %PasskeyUser{} = user <- Repo.get(PasskeyUser, key.did, log: false),
           %Credential{} = password <- Repo.get(Credential, key.did, log: false),
           {:ok, update} <-
             WebAuthn.authenticate(
               response,
               context(row),
               Map.put(Map.from_struct(key), :user_handle, user.user_handle)
             ) do
        now = clock!()

        key
        |> Ecto.Changeset.change(Map.put(update, :last_used_at, now))
        |> Repo.update!(log: false)

        # Commit proof consumption even if subsequent session issuance hits its cap.
        {:ok,
         %{
           did: key.did,
           id: key.id,
           sign_count: update.sign_count,
           origin: row.origin,
           expires_at: now + 30,
           credential_digest: hash(password.password_hash)
         }}
      else
        _ -> {:error, :invalid_passkey}
      end
    end)
  end

  def list(token) do
    with {:ok, head} <- Sessions.authenticate_management(token) do
      transact(fn ->
        owner!(token, head.did, nil)

        rows =
          Repo.all(
            from(k in Passkey,
              where: k.did == ^head.did,
              order_by: [asc: k.created_at, asc: k.id],
              select:
                map(k, [:id, :name, :created_at, :last_used_at, :backup_eligible, :backup_state])
            ),
            log: false
          )

        {:ok, rows}
      end)
    end
  end

  def revoke(token, password, id, opts \\ []) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, head, digest, admission} <- fresh_owner(token, password, opts[:totp_code]) do
      transact(fn ->
        owner!(token, head.did, digest)
        Authenticator.recheck!(head.did, admission)
        Repo.delete_all(from(k in Passkey, where: k.did == ^head.did and k.id == ^id), log: false)
        {:ok, :revoked}
      end)
    else
      :error -> {:error, :invalid_request}
      error -> error
    end
  end

  @doc false
  def session_key!(did, id, admission) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Passkey recheck requires a transaction")

    lock_head!(did)

    valid =
      case {Repo.get(Passkey, id, log: false), admission} do
        {%{did: ^did, sign_count: count},
         %{
           did: ^did,
           id: ^id,
           sign_count: observed,
           origin: origin,
           expires_at: expires,
           credential_digest: digest
         }} ->
          enabled?() and count >= observed and expires > clock!() and
            origin == AtollWeb.Endpoint.url() and Credentials.current_digest?(did, digest)

        _ ->
          false
      end

    unless valid, do: Repo.rollback(:invalid_passkey)
  end

  defp session_id!(token) do
    case Tokens.verify(token, :access) do
      {:ok, claims} -> claims["sid"]
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fresh_owner(token, password, code) do
    with {:ok, head} <- Sessions.authenticate_management(token),
         {:ok, digest} <- Credentials.verified_digest(head.did, password),
         {:ok, admission} <- Authenticator.check_login(head.did, digest, code),
         do: {:ok, head, digest, admission}
  end

  defp owner!(token, did, digest) do
    lock_head!(did)

    case Sessions.authenticate_management(token) do
      {:ok, %{did: ^did}} -> :ok
      _ -> Repo.rollback(:invalid_token)
    end

    if digest && not Credentials.current_digest?(did, digest),
      do: Repo.rollback(:invalid_credentials)
  end

  defp lock_head!(did) do
    case Repo.one(from(h in Head, where: h.did == ^did, lock: "FOR UPDATE")) do
      %{status: :active} -> :ok
      _ -> Repo.rollback(:invalid_passkey)
    end

    if Atoll.Accounts.Signup.pending?(did), do: Repo.rollback(:invalid_passkey)
  end

  defp factor_version(did) do
    case Repo.get(TOTPFactor, did, log: false) do
      %{confirmed_at: at, version: version} when not is_nil(at) -> version
      _ -> nil
    end
  end

  defp issue!(context, browser, attrs) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock])
    now = clock!()

    expired =
      Repo.all(
        from(c in PasskeyChallenge,
          where: c.expires_at <= ^now,
          order_by: [asc: c.expires_at, asc: c.digest],
          limit: 1000,
          select: c.digest
        ),
        log: false
      )

    Repo.delete_all(from(c in PasskeyChallenge, where: c.digest in ^expired), log: false)

    if Repo.aggregate(PasskeyChallenge, :count) >= 10_000,
      do: Repo.rollback(:passkey_challenge_capacity)

    reference = base(:crypto.strong_rand_bytes(32))

    attrs =
      Map.merge(attrs, %{
        digest: hash(reference),
        browser_hash: hash(browser),
        challenge: context.challenge,
        origin: context.origin,
        rp_id: context.rp_id,
        expires_at: now + 300
      })

    row = Repo.insert!(struct!(PasskeyChallenge, attrs), log: false)
    {reference, row}
  end

  defp consume(reference, browser, kind) do
    if binding?(reference) and binding?(browser) do
      row =
        Repo.one(
          from(c in PasskeyChallenge, where: c.digest == ^hash(reference), lock: "FOR UPDATE"),
          log: false
        )

      if row && row.kind == kind && Plug.Crypto.secure_compare(row.browser_hash, hash(browser)) do
        Repo.delete!(row, log: false)

        if row.expires_at > clock!() and row.origin == AtollWeb.Endpoint.url(),
          do: {:ok, row},
          else: {:error, :invalid_passkey}
      else
        {:error, :invalid_passkey}
      end
    else
      {:error, :invalid_passkey}
    end
  end

  defp credential(%{"id" => id}) when is_binary(id) and byte_size(id) <= 1364 do
    case Base.url_decode64(id, padding: false) do
      {:ok, bytes} when byte_size(bytes) in 1..1023 ->
        Repo.get_by(Passkey, [credential_id: bytes], log: false)

      _ ->
        nil
    end
  end

  defp credential(_), do: nil
  defp context(row), do: Map.take(row, [:challenge, :origin, :rp_id])

  defp binding?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<_::256>> = bytes} -> base(bytes) == value
      _ -> false
    end
  end

  defp binding?(_), do: false

  defp name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..64 and String.valid?(name) and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, name)

  defp enabled, do: if(enabled?(), do: :ok, else: {:error, :passkeys_disabled})
  defp base(bytes), do: Base.url_encode64(bytes, padding: false)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes)

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end

  defp transact(fun) do
    if Repo.in_transaction?() do
      {:error, :passkey_inside_transaction}
    else
      case Repo.transaction(fn ->
             Repo.query!("SET LOCAL lock_timeout = '1s'")
             Repo.query!("SET LOCAL statement_timeout = '5s'")
             fun.()
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :passkey_store_unavailable}
  end
end
