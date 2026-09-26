defmodule Atoll.Accounts.CredentialRevocation do
  @moduledoc "Internal atomic invalidation of sessions, app passwords and pending account challenges."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{AppPassword, Profile, Session}
  alias Atoll.Repositories.{Events, Head}

  @challenge_fields ~w(email_confirmation_digest email_confirmation_expires_at email_confirmation_requested_at
    plc_signature_digest plc_signature_expires_at plc_signature_requested_at
    email_update_digest email_update_expires_at email_update_requested_at
    password_reset_digest password_reset_expires_at password_reset_requested_at
    auth_factor_digest auth_factor_expires_at auth_factor_requested_at
    deletion_digest deletion_expires_at deletion_requested_at)a

  def revoke!(did) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "credential revocation requires a transaction")

    Events.lock!()

    Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
      Repo.rollback(:account_not_found)

    profile =
      Repo.one(from p in Profile, where: p.did == ^did, lock: "FOR UPDATE") ||
        Repo.rollback(:account_not_found)

    {sessions, _} = Repo.delete_all(from(s in Session, where: s.did == ^did), log: false)
    {apps, _} = Repo.delete_all(from(a in AppPassword, where: a.did == ^did), log: false)

    profile
    |> Ecto.Changeset.change(Map.new(@challenge_fields, &{&1, nil}))
    |> Repo.update!(log: false)

    %{sessions: sessions, app_passwords: apps}
  end
end
