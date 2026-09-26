defmodule Atoll.Accounts.AdminInfo do
  @moduledoc "Bounded private account inspection; callers must authenticate the operator."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{Invite, InviteListing, InviteUse, Profile}
  alias Atoll.Repositories.{Events, Head}

  def get(%{"did" => did} = params) when map_size(params) == 1 do
    case list(%{"dids" => [did]}) do
      {:ok, %{infos: [info]}} -> {:ok, info}
      {:ok, %{infos: []}} -> {:error, :admin_account_not_found}
      error -> error
    end
  end

  def get(_), do: {:error, :invalid_request}

  def list(%{"dids" => dids} = params)
      when map_size(params) == 1 and is_list(dids) and length(dids) in 1..100 do
    if Enum.all?(dids, &Syntax.did?/1) do
      read(Enum.uniq(dids))
    else
      {:error, :invalid_request}
    end
  end

  def list(_), do: {:error, :invalid_request}

  defp read(dids) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      Events.lock!()
      # Head/profile share locks preserve metadata while invite history is read.
      profiles =
        Repo.all(
          from(p in Profile,
            join: h in Head,
            on: h.did == p.did,
            where: p.did in ^dids,
            order_by: p.did,
            select: p,
            lock: "FOR SHARE"
          ),
          log: false
        )

      present = Enum.map(profiles, & &1.did)

      owned =
        Repo.all(
          from(i in Invite,
            where: i.for_account in ^present,
            order_by: [desc: i.inserted_at, asc: i.code],
            limit: 1001
          ),
          log: false
        )

      if length(owned) > 1000, do: Repo.rollback(:account_info_too_large)
      redeemed = Repo.all(from(u in InviteUse, where: u.did in ^present), log: false)
      redeemed_codes = Enum.map(redeemed, & &1.code)
      origins = Repo.all(from(i in Invite, where: i.code in ^redeemed_codes), log: false)
      rows = Enum.uniq_by(owned ++ origins, & &1.code)
      occurrences = Enum.frequencies(Enum.map(owned, & &1.code) ++ redeemed_codes)

      if length(rows) > 1000 or
           Enum.sum(Enum.map(rows, &((&1.use_count - &1.remaining) * occurrences[&1.code]))) >
             10_000,
         do: Repo.rollback(:account_info_too_large)

      details = InviteListing.details!(rows)

      if Enum.sum(Enum.map(details, &(length(&1.uses) * occurrences[&1.code]))) > 10_000,
        do: Repo.rollback(:account_info_too_large)

      by_code = Map.new(details, &{&1.code, &1})
      by_owner = Enum.group_by(owned, & &1.for_account, &Map.fetch!(by_code, &1.code))
      invited_by = Map.new(redeemed, &{&1.did, Map.fetch!(by_code, &1.code)})
      by_did = Map.new(profiles, &{&1.did, format(&1, by_owner, invited_by)})
      %{infos: Enum.flat_map(dids, fn did -> if info = by_did[did], do: [info], else: [] end)}
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  defp format(profile, by_owner, invited_by) do
    %{
      did: profile.did,
      handle: profile.handle || "handle.invalid",
      indexedAt: DateTime.to_iso8601(profile.inserted_at),
      invites: Map.get(by_owner, profile.did, []),
      invitesDisabled: profile.invites_disabled
    }
    |> optional(:email, profile.email)
    |> optional(
      :emailConfirmedAt,
      profile.email_confirmed_at && DateTime.to_iso8601(profile.email_confirmed_at)
    )
    |> optional(:inviteNote, profile.invite_control_note)
    |> optional(:invitedBy, invited_by[profile.did])
  end

  defp optional(map, _, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
