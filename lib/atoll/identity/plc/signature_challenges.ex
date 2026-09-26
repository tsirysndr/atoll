defmodule Atoll.Identity.PLC.SignatureChallenges do
  @moduledoc "Purpose-bound, single-use email authorization for PLC operation signing."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{Profile, Sessions}

  def request(token) do
    if Repo.in_transaction?() do
      {:error, :plc_update_inside_transaction}
    else
      with {:ok, {email, code}} <- prepare(token) do
        Atoll.Email.deliver(
          %{
            to: email,
            subject: "Authorize an Atoll identity change",
            text:
              "Your Atoll PLC operation signing code is: #{code}\n\nThis code expires in 15 minutes and permits signing an identity change, including moving your account or changing its keys. Only use it for a change you requested."
          },
          Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
          Application.get_env(:atoll, :email_delivery_options, [])
        )
      end
    end
  end

  defp prepare(token) do
    Repo.transaction(fn ->
      profile = authorize!(token)
      now = System.system_time(:second)

      if profile.plc_signature_requested_at && now - profile.plc_signature_requested_at < 60,
        do: Repo.rollback(:email_rate_limited)

      code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      profile
      |> Ecto.Changeset.change(
        plc_signature_digest: digest(profile, code),
        plc_signature_expires_at: now + 900,
        plc_signature_requested_at: now
      )
      |> Repo.update!(log: false)

      {profile.email, code}
    end)
  end

  @doc "Consume inside the authorized signing transaction; signing failure must roll back this change."
  def consume!(token, code) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "PLC challenge consumption requires a transaction")

    profile = authorize!(token)
    verify!(profile, code)

    profile
    |> Ecto.Changeset.change(plc_signature_digest: nil, plc_signature_expires_at: nil)
    |> Repo.update!(log: false)

    profile.did
  end

  @doc "Check before external lookups without consuming; signing must recheck and consume atomically."
  def verify(token, code) do
    Repo.transaction(fn ->
      profile = authorize!(token)
      verify!(profile, code)
      profile.did
    end)
  end

  defp verify!(profile, code) do
    cond do
      is_nil(code) ->
        Repo.rollback(:email_token_required)

      not is_binary(code) or byte_size(code) != 32 ->
        Repo.rollback(:invalid_email_token)

      is_nil(profile.plc_signature_digest) ->
        Repo.rollback(:invalid_email_token)

      not Plug.Crypto.secure_compare(profile.plc_signature_digest, digest(profile, code)) ->
        Repo.rollback(:invalid_email_token)

      profile.plc_signature_expires_at <= System.system_time(:second) ->
        Repo.rollback(:expired_email_token)

      true ->
        :ok
    end
  end

  defp authorize!(token) do
    head =
      case Sessions.authenticate_management(token) do
        {:ok, head} -> head
        {:error, reason} -> Repo.rollback(reason)
      end

    unless Regex.match?(~r/\Adid:plc:[a-z2-7]{24}\z/, head.did),
      do: Repo.rollback(:unsupported_did_method)

    profile =
      Repo.one(from(p in Profile, where: p.did == ^head.did, lock: "FOR UPDATE"), log: false) ||
        Repo.rollback(:account_not_found)

    unless profile.email && profile.email_confirmed_at,
      do: Repo.rollback(:email_unconfirmed)

    profile
  end

  defp digest(profile, code),
    do:
      :crypto.hash(:sha256, [
        "atoll.plc-signature.v1",
        <<0>>,
        profile.did,
        <<0>>,
        profile.email,
        <<0>>,
        code
      ])
end
