defmodule Atoll.Accounts.AdminEmail do
  @moduledoc "Operator email correction with atomic invalidation of old address-bound challenges."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{EmailAddress, Profile}
  alias Atoll.Repositories.{Events, Head}

  def update(%{"account" => account, "email" => email} = params) when map_size(params) == 2 do
    with {:ok, target} <- target(account), {:ok, email} <- EmailAddress.normalize(email) do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        Events.lock!()
        did = resolve!(target)

        unless Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE"),
          do: Repo.rollback(:admin_account_not_found)

        profile =
          Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false) ||
            Repo.rollback(:admin_account_not_found)

        unless matches?(profile, target), do: Repo.rollback(:admin_account_not_found)

        updated = if profile.email == email, do: profile, else: replace!(profile, email)
        Atoll.Moderation.Audit.email_change!(profile, updated, account)
        if profile.email == email, do: :unchanged, else: :updated
      end)
    end
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def update(_), do: {:error, :invalid_request}

  defp replace!(profile, email) do
    changeset =
      profile
      |> Ecto.Changeset.change(
        email: email,
        email_confirmed_at: nil,
        email_auth_factor: false,
        email_confirmation_digest: nil,
        email_confirmation_expires_at: nil,
        email_confirmation_requested_at: nil,
        plc_signature_digest: nil,
        plc_signature_expires_at: nil,
        email_update_digest: nil,
        email_update_expires_at: nil,
        email_update_requested_at: nil,
        password_reset_digest: nil,
        password_reset_expires_at: nil,
        password_reset_requested_at: nil,
        auth_factor_digest: nil,
        auth_factor_expires_at: nil,
        auth_factor_requested_at: nil,
        deletion_digest: nil,
        deletion_expires_at: nil,
        deletion_requested_at: nil
      )
      |> Ecto.Changeset.unique_constraint(:email)

    case Repo.update(changeset, log: false) do
      {:ok, profile} -> profile
      {:error, _} -> Repo.rollback(:email_not_available)
    end
  end

  defp target(value) do
    cond do
      Syntax.did?(value) -> {:ok, {:did, value}}
      Syntax.handle?(value) -> {:ok, {:handle, String.downcase(value)}}
      true -> {:error, :invalid_request}
    end
  end

  defp resolve!({:did, did}), do: did

  defp resolve!({:handle, handle}) do
    Repo.one(from p in Profile, where: p.handle == ^handle, select: p.did) ||
      Repo.rollback(:admin_account_not_found)
  end

  defp matches?(profile, {:did, did}), do: profile.did == did
  defp matches?(profile, {:handle, handle}), do: profile.handle == handle
end
