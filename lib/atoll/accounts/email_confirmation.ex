defmodule Atoll.Accounts.EmailConfirmation do
  @moduledoc "Account-bound, expiring, one-use email confirmation through the external Worker."
  import Ecto.Query
  alias Atoll.Accounts.{Profile, Sessions}
  alias Atoll.Repo

  def request(access_token) do
    with {:ok, delivery} <- prepare(access_token) do
      case delivery do
        :confirmed ->
          {:ok, :confirmed}

        {email, code, id} ->
          case Atoll.Email.deliver(
                 %{
                   to: email,
                   subject: "Confirm your Atoll email",
                   text:
                     "Your Atoll email confirmation code is: #{code}\n\nThis code expires in 15 minutes."
                 },
                 id,
                 Application.get_env(:atoll, :email_delivery_options, [])
               ) do
            :ok -> {:ok, :sent}
            error -> error
          end
      end
    end
  end

  defp prepare(access_token) do
    Repo.transaction(fn ->
      head = authorize!(access_token)
      profile = profile!(head.did)
      now = System.system_time(:second)

      cond do
        is_nil(profile.email) ->
          Repo.rollback(:invalid_email)

        not is_nil(profile.email_confirmed_at) ->
          :confirmed

        profile.email_confirmation_requested_at &&
            now - profile.email_confirmation_requested_at < 60 ->
          Repo.rollback(:email_rate_limited)

        true ->
          code = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

          profile
          |> Ecto.Changeset.change(
            email_confirmation_digest: digest(profile.email, code),
            email_confirmation_expires_at: now + 900,
            email_confirmation_requested_at: now
          )
          |> Repo.update!(log: false)

          {profile.email, code, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}
      end
    end)
  end

  def confirm(access_token, %{"email" => email, "token" => code})
      when is_binary(email) and byte_size(email) <= 254 and is_binary(code) and
             byte_size(code) == 32 do
    Repo.transaction(fn ->
      head = authorize!(access_token)
      profile = profile!(head.did)
      email = String.downcase(email)

      cond do
        email != profile.email ->
          Repo.rollback(:invalid_email)

        is_nil(profile.email_confirmation_digest) ->
          Repo.rollback(:invalid_email_token)

        not Plug.Crypto.secure_compare(profile.email_confirmation_digest, digest(email, code)) ->
          Repo.rollback(:invalid_email_token)

        profile.email_confirmation_expires_at <= System.system_time(:second) ->
          Repo.rollback(:expired_email_token)

        true ->
          profile
          |> Ecto.Changeset.change(
            email_confirmed_at: DateTime.utc_now(),
            email_confirmation_digest: nil,
            email_confirmation_expires_at: nil
          )
          |> Repo.update!(log: false)

          :confirmed
      end
    end)
  end

  def confirm(_, _), do: {:error, :invalid_request}

  defp authorize!(token) do
    case Sessions.authenticate_management(token) do
      {:ok, head} -> head
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp profile!(did) do
    Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false) ||
      Repo.rollback(:account_not_found)
  end

  defp digest(email, code), do: :crypto.hash(:sha256, [email, <<0>>, code])
end
