defmodule Atoll.Accounts.Signup do
  @moduledoc "Fresh PLC signup with durable reservations and exact-operation retries."
  import Ecto.Query
  alias Atoll.{KeyVault, Multikey, Repo, Repositories, SigningKey, Syntax}
  alias Atoll.Accounts.{Credentials, EmailAddress, Profile, Sessions, Tokens}
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations}
  alias Atoll.Repositories.{Events, Head}

  def create(params, opts \\ []) do
    with true <- Application.get_env(:atoll, :signup_enabled, false),
         false <- Repo.in_transaction?(),
         {:ok, input} <- input(params),
         {:ok, proof} <- prepare(input),
         {:ok, _} <- Registrations.submit(proof.did, Keyword.take(opts, [:plug])),
         {:ok, result} <- finish(input, proof) do
      {:ok, result}
    else
      false -> {:error, :signup_disabled}
      true -> {:error, :registration_inside_transaction}
      error -> error
    end
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
    with true <- Map.keys(params) -- ["handle", "password", "email", "recoveryKey"] == [],
         true <- Syntax.handle?(handle),
         handle = String.downcase(handle),
         :ok <- supported_domain(handle),
         {:ok, email} <- email(params["email"]),
         :ok <- recovery(params["recoveryKey"]) do
      {:ok, %{handle: handle, password: password, email: email, recovery: params["recoveryKey"]}}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp input(_), do: {:error, :invalid_request}

  defp supported_domain(handle),
    do: if(hosted_handle?(handle), do: :ok, else: {:error, :unsupported_domain})

  defp email(nil), do: {:ok, nil}
  defp email(value), do: EmailAddress.normalize(value)
  defp recovery(nil), do: :ok

  defp recovery(value) do
    case Multikey.from_did_key(value) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp prepare(input) do
    # Password hashing/verification happens before taking the global mutation lock.
    case Repo.get_by(Profile, [handle: input.handle], log: false) do
      nil ->
        with {:ok, hash} <- Credentials.hash(input.password) do
          create_reservation(input, hash)
        else
          _ -> {:error, :invalid_password}
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
        if Repo.get_by(Profile, handle: input.handle), do: Repo.rollback(:handle_not_available)

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
        %{did: genesis.did, digest: :crypto.hash(:sha256, hash)}
      end)
    end
  end

  defp finish(input, proof) do
    Repo.transaction(fn ->
      Events.lock!()
      head!(proof.did)
      registration = validate_retry!(input, proof.did, proof.digest)
      unless registration.confirmed_at, do: Repo.rollback(:plc_unavailable)
      unwrap!(KeyVault.fetch(proof.did))
      unwrap!(Registrations.rotation_key(proof.did))

      registration
      |> Ecto.Changeset.change(completed_at: DateTime.utc_now())
      |> Repo.update!(log: false)

      unwrap!(Repositories.set_status(proof.did, :active))
      pair = unwrap!(Sessions.create_for_account(proof.did))

      %{
        did: proof.did,
        handle: input.handle,
        accessJwt: pair.access_jwt,
        refreshJwt: pair.refresh_jwt,
        active: true
      }
    end)
  end

  defp validate_retry!(input, did, digest) do
    profile = Repo.get!(Profile, did, log: false)
    row = Repo.get(Registration, did, log: false)
    unless row && is_nil(row.completed_at), do: Repo.rollback(:account_exists)

    unless profile.handle == input.handle && profile.email == input.email &&
             Credentials.current_digest?(did, digest),
           do: Repo.rollback(:handle_not_available)

    {:ok, local_rotation} = Multikey.to_did_key(row.rotation_curve, row.rotation_public_key)
    expected = if input.recovery, do: [input.recovery, local_rotation], else: [local_rotation]

    unless row.operation["rotationKeys"] == expected and
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
