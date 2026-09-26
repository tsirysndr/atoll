defmodule Atoll.Accounts.InviteAllocation do
  @moduledoc "Opt-in interval invitations for active accounts with confirmed email."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{Invite, Invites, Profile}
  alias Atoll.Repositories.{Events, Head}

  def config_from_env!(env) do
    interval = integer!(env, "ATOLL_INVITE_INTERVAL_SECONDS", 0)
    maximum = integer!(env, "ATOLL_INVITE_MAX_OPEN", 5)

    unless interval == 0 or interval in 3600..31_536_000,
      do: raise("ATOLL_INVITE_INTERVAL_SECONDS must be 0 or an integer from 3600 to 31536000")

    unless maximum in 1..1000,
      do: raise("ATOLL_INVITE_MAX_OPEN must be an integer from 1 to 1000")

    [interval_seconds: interval, max_open: maximum]
  end

  @doc "Internal allocation inside an already authorized listing transaction."
  def allocate!(did, now \\ DateTime.utc_now()) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "invite allocation requires a transaction")

    now = DateTime.from_unix!(DateTime.to_unix(now, :microsecond), :microsecond)
    config = Application.get_env(:atoll, :invite_allocation, interval_seconds: 0, max_open: 5)
    interval = config[:interval_seconds]
    maximum = config[:max_open]

    unless is_integer(interval) and (interval == 0 or interval in 3600..31_536_000) and
             is_integer(maximum) and maximum in 1..1000,
           do: Repo.rollback(:invalid_invite_allocation)

    if interval == 0 or not Invites.required?() do
      0
    else
      Events.lock!()
      head = Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE")
      profile = Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR SHARE"), log: false)

      if head && head.status == :active && profile && not profile.invites_disabled &&
           profile.email && profile.email_confirmed_at do
        earned = max(div(DateTime.diff(now, profile.inserted_at, :second), interval), 0)
        query = from i in Invite, where: i.created_by == ^did
        total = Repo.aggregate(query, :count)
        open = Repo.aggregate(from(i in query, where: i.remaining > 0 and not i.disabled), :count)
        count = max(min(earned - total, maximum - open), 0)

        if count > 0 do
          rows =
            Enum.map(1..count, fn _ ->
              %{
                code: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
                for_account: did,
                created_by: did,
                use_count: 1,
                remaining: 1,
                inserted_at: now,
                updated_at: now
              }
            end)

          Repo.insert_all(Invite, rows, log: false)
        end

        count
      else
        0
      end
    end
  end

  defp integer!(env, name, default) do
    case Integer.parse(Map.get(env, name, Integer.to_string(default))) do
      {number, ""} -> number
      _ -> raise "#{name} must be an integer"
    end
  end
end
