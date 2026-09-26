defmodule Atoll.Accounts.AdminPassword do
  @moduledoc "Operator password replacement with atomic credential and challenge revocation."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{AppPassword, Credential, Credentials, Profile, Session}
  alias Atoll.Repositories.{Events, Head}

  def update(%{"did" => did, "password" => password} = params) when map_size(params) == 2 do
    with true <- Syntax.did?(did), {:ok, hash} <- Credentials.hash(password) do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        Events.lock!()

        unless Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE"),
          do: Repo.rollback(:admin_account_not_found)

        profile =
          Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false) ||
            Repo.rollback(:admin_account_not_found)

        {count, _} =
          Repo.update_all(
            from(c in Credential, where: c.did == ^did),
            [set: [password_hash: hash]],
            log: false
          )

        if count != 1, do: Repo.rollback(:admin_account_not_found)
        {sessions, _} = Repo.delete_all(from(s in Session, where: s.did == ^did), log: false)
        {apps, _} = Repo.delete_all(from(a in AppPassword, where: a.did == ^did), log: false)

        profile
        |> Ecto.Changeset.change(
          email_confirmation_digest: nil,
          email_confirmation_expires_at: nil,
          email_confirmation_requested_at: nil,
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
        |> Repo.update!(log: false)

        Atoll.Moderation.Audit.password_change!(did, sessions, apps)
        :updated
      end)
    else
      false -> {:error, :invalid_request}
      {:error, :invalid_credentials} -> {:error, :invalid_password}
    end
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def update(_), do: {:error, :invalid_request}
end
