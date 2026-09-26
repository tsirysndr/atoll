defmodule Atoll.Accounts.EmailUpdate do
  @moduledoc "Changes account email using proof of the current address when confirmed."
  import Ecto.Query
  alias Atoll.Accounts.{EmailAddress, Profile, Sessions}
  alias Atoll.Repo

  def request(access_token) do
    with {:ok, delivery} <- prepare(access_token) do
      case delivery do
        :not_required ->
          {:ok, %{tokenRequired: false}}

        {email, code} ->
          id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

          message = %{
            to: email,
            subject: "Change your Atoll email",
            text:
              "Your Atoll email change code is: #{code}\n\nThis code expires in 15 minutes. If you did not request this change, do not share this code."
          }

          case Atoll.Email.deliver(
                 message,
                 id,
                 Application.get_env(:atoll, :email_delivery_options, [])
               ) do
            :ok -> {:ok, %{tokenRequired: true}}
            error -> error
          end
      end
    end
  end

  defp prepare(access_token) do
    Repo.transaction(fn ->
      profile = profile!(access_token)
      now = System.system_time(:second)

      cond do
        is_nil(profile.email_confirmed_at) ->
          :not_required

        profile.email_update_requested_at && now - profile.email_update_requested_at < 60 ->
          Repo.rollback(:email_rate_limited)

        true ->
          code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

          profile
          |> Ecto.Changeset.change(
            email_update_digest: digest(profile.email, code),
            email_update_expires_at: now + 900,
            email_update_requested_at: now
          )
          |> Repo.update!(log: false)

          {profile.email, code}
      end
    end)
  end

  def update(access_token, %{"email" => email} = params) do
    with {:ok, email} <- EmailAddress.normalize(email),
         true <- Map.keys(params) -- ["email", "token", "emailAuthFactor"] == [],
         true <- is_boolean(Map.get(params, "emailAuthFactor", false)) do
      Repo.transaction(fn ->
        profile = profile!(access_token)
        if profile.email_confirmed_at, do: verify!(profile, params["token"])

        factor =
          Map.get(params, "emailAuthFactor", profile.email_auth_factor and profile.email == email)

        if factor and (is_nil(profile.email_confirmed_at) or profile.email != email),
          do: Repo.rollback(:email_factor_unconfirmed)

        if profile.email != email do
          changeset =
            profile
            |> Ecto.Changeset.change(
              email: email,
              email_auth_factor: false,
              auth_factor_digest: nil,
              auth_factor_expires_at: nil,
              password_reset_digest: nil,
              password_reset_expires_at: nil,
              email_confirmed_at: nil,
              email_confirmation_digest: nil,
              email_confirmation_expires_at: nil,
              email_update_digest: nil,
              email_update_expires_at: nil
            )
            |> Ecto.Changeset.unique_constraint(:email)

          case Repo.update(changeset, log: false) do
            {:ok, _} -> :updated
            {:error, _} -> Repo.rollback(:email_not_available)
          end
        else
          # Consume valid authorization even if the normalized address did not change.
          profile
          |> Ecto.Changeset.change(
            email_update_digest: nil,
            email_update_expires_at: nil,
            email_auth_factor: factor,
            auth_factor_digest: nil,
            auth_factor_expires_at: nil
          )
          |> Repo.update!(log: false)

          :unchanged
        end
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def update(_, _), do: {:error, :invalid_request}

  defp verify!(_profile, nil), do: Repo.rollback(:email_token_required)

  defp verify!(profile, code) when is_binary(code) and byte_size(code) == 32 do
    cond do
      is_nil(profile.email_update_digest) ->
        Repo.rollback(:invalid_email_token)

      not Plug.Crypto.secure_compare(profile.email_update_digest, digest(profile.email, code)) ->
        Repo.rollback(:invalid_email_token)

      profile.email_update_expires_at <= System.system_time(:second) ->
        Repo.rollback(:expired_email_token)

      true ->
        :ok
    end
  end

  defp verify!(_, _), do: Repo.rollback(:invalid_email_token)

  defp profile!(token) do
    case Sessions.authenticate_management(token) do
      {:ok, head} ->
        Repo.one(from(p in Profile, where: p.did == ^head.did, lock: "FOR UPDATE"), log: false) ||
          Repo.rollback(:account_not_found)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp digest(email, code),
    do: :crypto.hash(:sha256, ["atoll.email-update.v1", <<0>>, email, <<0>>, code])
end
