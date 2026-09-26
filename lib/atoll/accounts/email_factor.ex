defmodule Atoll.Accounts.EmailFactor do
  @moduledoc "Email login challenges bound to the account, email, and current password credential."
  import Ecto.Query
  alias Atoll.Accounts.{Credentials, Profile}
  alias Atoll.Repositories.Head
  alias Atoll.Repo

  # Called only after a successful account-password check, never for app passwords.
  def challenge(did, credential_digest, opts) do
    if opts[:auth_factor_token] do
      :ok
    else
      case prepare(did, credential_digest, opts) do
        {:ok, :disabled} ->
          :ok

        {:ok, :pending} ->
          {:error, :auth_factor_required}

        {:ok, {email, code}} ->
          message = %{
            to: email,
            subject: "Your Atoll login code",
            text:
              "Your Atoll login code is: #{code}\n\nThis code expires in 15 minutes. If you did not attempt to log in, change your account password."
          }

          case Atoll.Email.deliver(
                 message,
                 Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
                 Application.get_env(:atoll, :email_delivery_options, [])
               ) do
            :ok -> {:error, :auth_factor_required}
            error -> error
          end

        error ->
          error
      end
    end
  end

  defp prepare(did, credential_digest, opts) do
    Repo.transaction(fn ->
      head =
        Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE") ||
          Repo.rollback(:invalid_credentials)

      unless head.status in [:active, :deactivated] or
               (head.status == :takendown and head.pre_takedown_status != :suspended and
                  opts[:allow_takendown] == true),
             do: Repo.rollback({:repo_inactive, head.status})

      unless Credentials.current_digest?(did, credential_digest),
        do: Repo.rollback(:invalid_credentials)

      profile = Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false)

      if opts[:login_email] && (is_nil(profile) or profile.email != opts[:login_email]),
        do: Repo.rollback(:invalid_credentials)

      now = System.system_time(:second)

      cond do
        is_nil(profile) or not profile.email_auth_factor ->
          :disabled

        profile.auth_factor_requested_at && now - profile.auth_factor_requested_at < 60 ->
          :pending

        true ->
          code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

          profile
          |> Ecto.Changeset.change(
            auth_factor_digest: digest(profile, credential_digest, code),
            auth_factor_expires_at: now + 900,
            auth_factor_requested_at: now
          )
          |> Repo.update!(log: false)

          {profile.email, code}
      end
    end)
  end

  @doc "Consumes the factor inside session creation, after the caller holds the head write lock."
  def consume!(did, credential_digest, code) do
    profile = Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false)

    if profile && profile.email_auth_factor do
      cond do
        is_nil(code) ->
          Repo.rollback(:auth_factor_required)

        not is_binary(code) or byte_size(code) != 32 ->
          Repo.rollback(:invalid_auth_factor)

        is_nil(profile.auth_factor_digest) ->
          Repo.rollback(:invalid_auth_factor)

        not Plug.Crypto.secure_compare(
          profile.auth_factor_digest,
          digest(profile, credential_digest, code)
        ) ->
          Repo.rollback(:invalid_auth_factor)

        profile.auth_factor_expires_at <= System.system_time(:second) ->
          Repo.rollback(:invalid_auth_factor)

        true ->
          profile
          |> Ecto.Changeset.change(auth_factor_digest: nil, auth_factor_expires_at: nil)
          |> Repo.update!(log: false)
      end
    else
      if code, do: Repo.rollback(:invalid_request)
    end
  end

  defp digest(profile, credential_digest, code),
    do:
      :crypto.hash(:sha256, [
        "atoll.email-factor.v1",
        <<0>>,
        profile.did,
        <<0>>,
        profile.email,
        <<0>>,
        credential_digest,
        code
      ])
end
