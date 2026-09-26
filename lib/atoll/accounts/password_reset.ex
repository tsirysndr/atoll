defmodule Atoll.Accounts.PasswordReset do
  @moduledoc "One-use password recovery with atomic credential replacement and session revocation."
  import Ecto.Query
  alias Atoll.Accounts.{Credential, Credentials, EmailAddress, Profile, Session}
  alias Atoll.Repositories.Head
  alias Atoll.Repo

  def request(%{"email" => email} = params) when map_size(params) == 1 do
    with {:ok, email} <- EmailAddress.normalize(email),
         :ok <- configured(),
         {:ok, delivery} <- prepare(email) do
      if delivery do
        {recipient, code} = delivery

        result =
          Atoll.Email.deliver(
            %{
              to: recipient,
              subject: "Reset your Atoll password",
              text:
                "Your Atoll password reset code is: #{code}\n\nThis code expires in 15 minutes. If you did not request this reset, ignore this email."
            },
            Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
            Application.get_env(:atoll, :email_delivery_options, [])
          )

        # Do not reveal account existence through provider error status or content.
        :telemetry.execute([:atoll, :email, :password_reset], %{count: 1}, %{
          outcome: if(result == :ok, do: :accepted, else: :unavailable)
        })
      end

      {:ok, :requested}
    end
  end

  def request(_), do: {:error, :invalid_request}

  defp configured do
    config = Application.get_env(:atoll, :email_worker, [])

    if Atoll.Email.Config.validate(config[:url], config[:token]) == :ok,
      do: :ok,
      else: {:error, :email_not_configured}
  end

  defp prepare(email) do
    # Look up ownership first, then use the same head-before-profile lock order as account management.
    did = Repo.one(from(p in Profile, where: p.email == ^email, select: p.did), log: false)

    Repo.transaction(fn ->
      with did when not is_nil(did) <- did,
           %Head{status: status} when status in [:active, :deactivated] <-
             Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE"),
           %Profile{email: ^email} = profile <-
             Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false),
           true <- Repo.exists?(from c in Credential, where: c.did == ^did) do
        now = System.system_time(:second)

        if is_nil(profile.password_reset_requested_at) or
             now - profile.password_reset_requested_at >= 60 do
          code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

          profile
          |> Ecto.Changeset.change(
            password_reset_digest: digest(code),
            password_reset_expires_at: now + 900,
            password_reset_requested_at: now
          )
          |> Repo.update!(log: false)

          {email, code}
        end
      else
        _ -> nil
      end
    end)
  end

  def reset(%{"token" => code, "password" => password} = params)
      when is_binary(code) and byte_size(code) == 32 and map_size(params) == 2 do
    hashed_code = digest(code)
    # Avoid expensive Argon2 work for unknown or already consumed recovery tokens.
    with %Profile{} = candidate <-
           Repo.get_by(Profile, [password_reset_digest: hashed_code], log: false),
         :ok <- unexpired(candidate),
         {:ok, hash} <- Credentials.hash(password) do
      Repo.transaction(fn ->
        head = Repo.one(from h in Head, where: h.did == ^candidate.did, lock: "FOR UPDATE")

        unless head && head.status in [:active, :deactivated],
          do: Repo.rollback(:invalid_email_token)

        profile =
          Repo.one(from(p in Profile, where: p.did == ^candidate.did, lock: "FOR UPDATE"),
            log: false
          )

        unless profile && profile.password_reset_digest == hashed_code,
          do: Repo.rollback(:invalid_email_token)

        case unexpired(profile) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        {count, _} =
          Repo.update_all(
            from(c in Credential, where: c.did == ^head.did),
            [set: [password_hash: hash]],
            log: false
          )

        if count != 1, do: Repo.rollback(:invalid_email_token)
        Repo.delete_all(from(s in Session, where: s.did == ^head.did), log: false)

        Repo.delete_all(from(a in Atoll.Accounts.AppPassword, where: a.did == ^head.did),
          log: false
        )

        profile
        |> Ecto.Changeset.change(
          password_reset_digest: nil,
          password_reset_expires_at: nil,
          email_update_digest: nil,
          email_update_expires_at: nil,
          email_confirmation_digest: nil,
          email_confirmation_expires_at: nil
        )
        |> Repo.update!(log: false)

        :reset
      end)
    else
      nil -> {:error, :invalid_email_token}
      {:error, :invalid_credentials} -> {:error, :invalid_password}
      error -> error
    end
  end

  def reset(_), do: {:error, :invalid_request}

  defp unexpired(profile) do
    if profile.password_reset_expires_at > System.system_time(:second),
      do: :ok,
      else: {:error, :expired_email_token}
  end

  defp digest(code), do: :crypto.hash(:sha256, ["atoll.password-reset.v1", <<0>>, code])
end
