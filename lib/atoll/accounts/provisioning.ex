defmodule Atoll.Accounts.Provisioning do
  @moduledoc "Creates deactivated accounts for pre-existing DIDs using single-use service authorization."
  alias Atoll.{Repo, Repositories, Syntax}
  alias Atoll.Accounts.{Credentials, Invites, Profile, ServiceTokens, Sessions}
  alias Atoll.Identity.{Document, Handle}
  alias Atoll.Repositories.{Events, Head}
  @method "com.atproto.server.createAccount"

  def import_account(token, params) do
    with false <- Repo.in_transaction?(),
         {:ok, input} <- input(params),
         :ok <- Invites.validate_new(input.invite),
         {:ok, hash} <- Credentials.hash(input.password) do
      opts =
        Application.get_env(:atoll, :identity_resolution_options, [])
        |> Keyword.put(:force_refresh, true)

      audience = Application.fetch_env!(:atoll, :pds) |> Keyword.fetch!(:did)

      result =
        Repo.transaction(fn ->
          # Consume the token within this transaction so any provisioning failure permits retry.
          verified = unwrap!(authorize(token, audience, opts))
          if verified.claims["iss"] != input.did, do: Repo.rollback(:forbidden)
          identity = unwrap!(Document.parse(verified.document, input.did))

          unless identity.claimed_handle == input.handle and
                   Handle.resolve(input.handle, opts) == {:ok, input.did},
                 do: Repo.rollback(:unverified_handle)

          migration =
            unwrap!(
              Atoll.Accounts.MigrationOperation.prepare(input, verified, submission_opts(opts))
            )

          Events.lock!()
          if Repo.get(Head, input.did), do: Repo.rollback(:account_exists)

          if Atoll.Identity.HandleChanges.claimed?(input.handle),
            do: Repo.rollback(:handle_not_available)

          if input.email && Repo.get_by(Profile, email: input.email),
            do: Repo.rollback(:email_not_available)

          reserved =
            if migration,
              do: Atoll.Accounts.SigningKeyReservations.claim!(input.did, migration.public_key),
              else: Atoll.Accounts.SigningKeyReservations.claim_for_did!(input.did)

          case reserved do
            nil ->
              unwrap!(Repositories.create_managed(input.did))

            key ->
              unwrap!(Repositories.create(input.did, key))
              unwrap!(Atoll.KeyVault.store(input.did, key))
          end

          unwrap!(Repositories.set_status(input.did, :deactivated))

          changeset =
            Ecto.Changeset.change(%Profile{
              did: input.did,
              handle: input.handle,
              email: input.email,
              import_curve: verified.signing_key.curve,
              import_public_key: verified.signing_key.public
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

          unwrap!(Credentials.store_hash(input.did, hash))
          Invites.consume!(input.did, input.invite)

          if migration,
            do:
              unwrap!(
                Atoll.Identity.PLC.Updates.stage(input.did, migration.audit, input.operation)
              )

          pair = unwrap!(Sessions.create_for_account(input.did))

          %{
            did: input.did,
            handle: input.handle,
            accessJwt: pair.access_jwt,
            refreshJwt: pair.refresh_jwt,
            active: false,
            status: "deactivated"
          }
        end)

      case result do
        {:ok, account} when not is_nil(input.operation) ->
          case Atoll.Identity.PLC.Submission.submit(
                 account.accessJwt,
                 %{"operation" => input.operation},
                 submission_opts(opts)
               ) do
            {:ok, _} -> {:ok, account}
            {:error, _} -> {:error, :migration_publication_pending}
          end

        result ->
          result
      end
    else
      true -> {:error, :plc_update_inside_transaction}
      {:error, :invalid_credentials} -> {:error, :invalid_password}
      error -> error
    end
  end

  defp submission_opts(opts),
    do: Keyword.merge(opts, Application.get_env(:atoll, :plc_submission_options, []))

  # Accept only this specific PDS service reference or the explicit legacy bare audience.
  defp authorize(token, audience, opts) do
    case ServiceTokens.authenticate_identity(token, audience <> "#atproto_pds", @method, opts) do
      {:error, :invalid_service_token} ->
        ServiceTokens.authenticate_identity(token, audience, @method, opts)

      result ->
        result
    end
  end

  defp input(%{"did" => did, "handle" => handle, "password" => password} = params) do
    with true <-
           Map.keys(params) -- ["did", "handle", "password", "email", "inviteCode", "plcOp"] == [],
         true <- Syntax.did?(did),
         true <- Syntax.handle?(handle),
         true <- not Map.has_key?(params, "plcOp") or is_map(params["plcOp"]),
         {:ok, email} <- email(params["email"]) do
      {:ok,
       %{
         did: did,
         handle: String.downcase(handle),
         password: password,
         email: email,
         invite: params["inviteCode"],
         operation: params["plcOp"]
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp input(_), do: {:error, :invalid_request}

  defp email(nil), do: {:ok, nil}

  defp email(value), do: Atoll.Accounts.EmailAddress.normalize(value)

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
