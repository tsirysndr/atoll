defmodule Atoll.Accounts.Signup do
  @moduledoc "Fresh PLC signup with durable reservations and exact-operation retries."
  import Ecto.Query
  alias Atoll.{KeyVault, Multikey, Repo, Repositories, SigningKey, Syntax}
  alias Atoll.Accounts.{Credentials, EmailAddress, Invites, Profile, Sessions, Tokens}
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations}
  alias Atoll.Repositories.{Events, Head}

  def create(params, opts \\ []) do
    with true <- Application.get_env(:atoll, :signup_enabled, false),
         false <- Repo.in_transaction?(),
         {:ok, input} <- input(params),
         {:ok, proof} <- prepare(input),
         :ok <- verify_custom_handle(input.handle, proof.did, opts),
         {:ok, _} <- Registrations.submit(proof.did, Keyword.take(opts, [:plug])),
         :ok <- verify_custom_handle(input.handle, proof.did, opts),
         {:ok, result} <- finish(input, proof) do
      {:ok, result}
    else
      false -> {:error, :signup_disabled}
      true -> {:error, :registration_inside_transaction}
      error -> error
    end
  end

  @doc "Operator resume of an exact stored signup, without password input or session issuance."
  def resume_registration(did, expected_cid, opts \\ []) do
    with false <- Repo.in_transaction?(),
         {:ok, snapshot} <-
           resume_snapshot(did, expected_cid, Keyword.get(opts, :signup_retry_token)) do
      case snapshot do
        {:completed, result} ->
          {:ok, result}

        {:pending, input, proof} ->
          with :ok <- verify_custom_handle(input.handle, did, opts),
               {:ok, _} <- Registrations.submit(did, Keyword.take(opts, [:plug])),
               :ok <- verify_custom_handle(input.handle, did, opts),
               do: finish(input, proof, false)
      end
    else
      true -> {:error, :registration_inside_transaction}
      error -> error
    end
  end

  defp resume_snapshot(did, expected_cid, retry_token) do
    Repo.transaction(fn ->
      Events.lock!()

      head =
        Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
          Repo.rollback(:account_not_found)

      row = Repo.get(Registration, did, log: false) || Repo.rollback(:registration_not_found)
      profile = Repo.get(Profile, did, log: false) || Repo.rollback(:account_not_found)
      unless row.cid == expected_cid, do: Repo.rollback(:stale_signup)

      if row.completed_at do
        {:completed,
         %{
           did: did,
           handle: profile.handle,
           active: head.status == :active,
           result: :already_completed
         }}
      else
        head!(did)
        if retry_token, do: Atoll.Accounts.SignupRetries.assert_current!(did, retry_token)

        credential =
          Repo.get(Atoll.Accounts.Credential, did, log: false) ||
            Repo.rollback(:invalid_credentials)

        {:ok, local} = Multikey.to_did_key(row.rotation_curve, row.rotation_public_key)

        recovery =
          case row.operation["rotationKeys"] do
            [^local] -> nil
            [external, ^local] -> external
            _ -> Repo.rollback(:invalid_request)
          end

        invite =
          case Repo.get(Atoll.Accounts.InviteUse, did, log: false) do
            nil -> nil
            use -> use.code
          end

        input = %{
          handle: profile.handle,
          email: profile.email,
          recovery: recovery,
          invite: invite
        }

        proof = %{
          did: did,
          cid: row.cid,
          digest: :crypto.hash(:sha256, credential.password_hash),
          retry_token: retry_token
        }

        validate_retry!(input, did, proof.digest)
        {:pending, input, proof}
      end
    end)
  end

  @doc "Operator-only custom-domain reservation. Returns public setup details, never sessions or private keys."
  def reserve_custom(params) do
    with true <- Application.get_env(:atoll, :signup_enabled, false),
         false <- Repo.in_transaction?(),
         {:ok, input} <- input(params),
         :ok <- custom_domain(input.handle),
         {:ok, proof} <- prepare(input, true) do
      {:ok,
       %{
         did: proof.did,
         handle: input.handle,
         dns_name: "_atproto." <> input.handle,
         dns_value: "did=" <> proof.did,
         https_url: "https://" <> input.handle <> "/.well-known/atproto-did"
       }}
    else
      false -> {:error, :signup_disabled}
      true -> {:error, :registration_inside_transaction}
      error -> error
    end
  end

  defp custom_domain(handle) do
    if not hosted_handle?(handle) and
         Application.get_env(:atoll, :custom_domain_signup_enabled, false),
       do: :ok,
       else: {:error, :unsupported_domain}
  end

  defp verify_custom_handle(handle, did, opts) do
    if hosted_handle?(handle) or
         Atoll.Identity.Handle.resolve(handle, Keyword.put(opts, :force_refresh, true)) ==
           {:ok, did}, do: :ok, else: {:error, :unverified_handle}
  end

  @doc "Whether the handle is one label beneath an advertised server domain."
  def hosted_handle?(handle) do
    domains = Application.get_env(:atoll, :pds, []) |> Keyword.get(:available_user_domains, [])

    Syntax.handle?(handle) and
      Enum.any?(domains, fn suffix ->
        if is_binary(suffix) and String.starts_with?(suffix, ".") and
             String.ends_with?(handle, suffix) do
          label = String.replace_suffix(handle, suffix, "")
          label != "" and not String.contains?(label, ".")
        else
          false
        end
      end)
  end

  def pending?(did),
    do: Repo.exists?(from r in Registration, where: r.did == ^did and is_nil(r.completed_at))

  defp input(%{"handle" => handle, "password" => password} = params) do
    with true <-
           Map.keys(params) -- ["handle", "password", "email", "recoveryKey", "inviteCode"] == [],
         true <- Syntax.handle?(handle),
         handle = String.downcase(handle),
         :ok <- supported_domain(handle),
         {:ok, email} <- email(params["email"]),
         :ok <- recovery(params["recoveryKey"]) do
      {:ok,
       %{
         handle: handle,
         password: password,
         email: email,
         recovery: params["recoveryKey"],
         invite: params["inviteCode"]
       }}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp input(_), do: {:error, :invalid_request}

  defp supported_domain(handle),
    do: if(hosted_handle?(handle), do: :ok, else: custom_domain(handle))

  defp email(nil), do: {:ok, nil}
  defp email(value), do: EmailAddress.normalize(value)
  defp recovery(nil), do: :ok

  defp recovery(value) do
    case Multikey.from_did_key(value) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp prepare(input, allow_custom_reservation \\ false) do
    # Password hashing/verification happens before taking the global mutation lock.
    case Repo.get_by(Profile, [handle: input.handle], log: false) do
      nil ->
        with true <- hosted_handle?(input.handle) or allow_custom_reservation,
             :ok <- Invites.validate_new(input.invite),
             {:ok, hash} <- Credentials.hash(input.password) do
          create_reservation(input, hash)
        else
          false -> {:error, :unsupported_domain}
          {:error, :invalid_credentials} -> {:error, :invalid_password}
          error -> error
        end

      profile ->
        with {:ok, digest} <- Credentials.verified_digest(profile.did, input.password),
             :ok <- session_ready(profile.did) do
          Repo.transaction(fn ->
            Events.lock!()
            head!(profile.did)
            validate_retry!(input, profile.did, digest)
            %{did: profile.did, digest: digest}
          end)
        else
          {:error, :invalid_credentials} -> {:error, :handle_not_available}
          error -> error
        end
    end
  end

  defp create_reservation(input, hash) do
    repository_key = SigningKey.generate()
    rotation_key = SigningKey.generate()
    {:ok, signing} = Multikey.to_did_key(repository_key.curve, repository_key.public)
    {:ok, rotation} = Multikey.to_did_key(rotation_key.curve, rotation_key.public)
    rotations = if input.recovery, do: [input.recovery, rotation], else: [rotation]

    with {:ok, genesis} <-
           Operation.create_atproto(
             signing,
             input.handle,
             AtollWeb.Endpoint.url(),
             rotations,
             rotation_key
           ),
         :ok <- session_ready(genesis.did) do
      Repo.transaction(fn ->
        Events.lock!()

        if Atoll.Identity.HandleChanges.claimed?(input.handle),
          do: Repo.rollback(:handle_not_available)

        if input.email && Repo.get_by(Profile, [email: input.email], log: false),
          do: Repo.rollback(:email_not_available)

        unwrap!(Repositories.create(genesis.did, repository_key))
        unwrap!(KeyVault.store(genesis.did, repository_key))
        unwrap!(Repositories.set_status(genesis.did, :deactivated))

        changeset =
          Ecto.Changeset.change(%Profile{
            did: genesis.did,
            handle: input.handle,
            email: input.email
          })
          |> Ecto.Changeset.unique_constraint(:handle)
          |> Ecto.Changeset.unique_constraint(:email)

        case Repo.insert(changeset, log: false) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            if Keyword.has_key?(changeset.errors, :handle),
              do: Repo.rollback(:handle_not_available),
              else: Repo.rollback(:email_not_available)
        end

        unwrap!(Credentials.store_hash(genesis.did, hash))
        unwrap!(Registrations.stage(genesis.did, genesis.operation, rotation_key))
        Invites.consume!(genesis.did, input.invite)

        unless hosted_handle?(input.handle),
          do: Atoll.Moderation.Audit.signup_reservation!(genesis.did, input.handle, genesis.cid)

        %{did: genesis.did, digest: :crypto.hash(:sha256, hash)}
      end)
    end
  end

  defp finish(input, proof, issue_session \\ true) do
    Repo.transaction(fn ->
      Events.lock!()
      head!(proof.did)

      if Map.get(proof, :retry_token),
        do: Atoll.Accounts.SignupRetries.assert_current!(proof.did, proof.retry_token)

      registration = validate_retry!(input, proof.did, proof.digest)

      unless registration.cid == Map.get(proof, :cid, registration.cid),
        do: Repo.rollback(:stale_signup)

      unless registration.confirmed_at, do: Repo.rollback(:plc_unavailable)
      unwrap!(KeyVault.fetch(proof.did))
      unwrap!(Registrations.rotation_key(proof.did))

      registration
      |> Ecto.Changeset.change(completed_at: DateTime.utc_now())
      |> Repo.update!(log: false)

      unwrap!(Repositories.set_status(proof.did, :active))
      result = %{did: proof.did, handle: input.handle, active: true}

      if issue_session do
        pair = unwrap!(Sessions.create_for_account(proof.did))
        Map.merge(result, %{accessJwt: pair.access_jwt, refreshJwt: pair.refresh_jwt})
      else
        Atoll.Moderation.Audit.signup_resume!(
          proof.did,
          registration.cid,
          if(Map.get(proof, :retry_token), do: "system", else: "operator")
        )

        Map.put(result, :result, :completed)
      end
    end)
  end

  defp validate_retry!(input, did, digest) do
    profile = Repo.get!(Profile, did, log: false)
    row = Repo.get(Registration, did, log: false)
    unless row && is_nil(row.completed_at), do: Repo.rollback(:account_exists)
    unless Invites.retry?(did, input.invite), do: Repo.rollback(:invalid_invite_code)

    unless profile.handle == input.handle && profile.email == input.email &&
             Credentials.current_digest?(did, digest),
           do: Repo.rollback(:handle_not_available)

    {:ok, local_rotation} = Multikey.to_did_key(row.rotation_curve, row.rotation_public_key)
    expected = if input.recovery, do: [input.recovery, local_rotation], else: [local_rotation]

    head = Repo.get!(Head, did)
    {:ok, signing} = Multikey.to_did_key(head.curve, head.public_key)

    unless row.operation["alsoKnownAs"] == ["at://" <> input.handle] and
             get_in(row.operation, ["verificationMethods", "atproto"]) == signing and
             row.operation["rotationKeys"] == expected and
             row.operation["services"]["atproto_pds"]["endpoint"] == AtollWeb.Endpoint.url(),
           do: Repo.rollback(:invalid_request)

    row
  end

  defp head!(did) do
    case Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") do
      %{status: :deactivated} = head -> head
      nil -> Repo.rollback(:account_not_found)
      _ -> Repo.rollback(:account_exists)
    end
  end

  defp session_ready(did) do
    case Tokens.pair(did, Tokens.random_id()) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
