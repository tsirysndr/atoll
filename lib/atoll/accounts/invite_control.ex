defmodule Atoll.Accounts.InviteControl do
  @moduledoc "Internal operator control of future earned invitations; existing codes remain valid."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.Profile
  alias Atoll.Repositories.{Events, Head}

  def set(%{"account" => did} = params, disabled) when is_boolean(disabled) do
    note = params["note"]

    if Map.keys(params) -- ["account", "note"] == [] and Syntax.did?(did) and valid_note?(note) do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        Events.lock!()

        unless Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE"),
          do: Repo.rollback(:account_not_found)

        profile =
          Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false)

        unless profile, do: Repo.rollback(:account_not_found)

        if profile.invites_disabled == disabled and profile.invite_control_note == note do
          :unchanged
        else
          profile
          |> Ecto.Changeset.change(
            invites_disabled: disabled,
            invite_control_note: note,
            invites_updated_at: DateTime.utc_now()
          )
          |> Repo.update!(log: false)

          :updated
        end
      end)
    else
      {:error, :invalid_request}
    end
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def set(_, _), do: {:error, :invalid_request}

  defp valid_note?(nil), do: true

  defp valid_note?(value) when is_binary(value),
    do: byte_size(value) <= 2000 and String.valid?(value) and not String.contains?(value, <<0>>)

  defp valid_note?(_), do: false
end
