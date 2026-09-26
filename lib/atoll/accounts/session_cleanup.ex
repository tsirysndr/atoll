defmodule Atoll.Accounts.SessionCleanup do
  @moduledoc "Bounded expired-session deletion for trusted operators and scheduled maintenance."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.Session

  def prune_expired(limit \\ 500)

  def prune_expired(limit) when is_integer(limit) and limit in 1..1000 do
    cutoff = System.system_time(:second)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      # Only lock sessions; never acquire repository locks after these locks.
      # Refresh/authentication may hold a session lock, so leave those rows for a later batch.
      ids =
        Repo.all(
          from(s in Session,
            where: s.expires_at <= ^cutoff,
            order_by: [asc: s.expires_at, asc: s.id],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED",
            select: s.id
          ),
          log: false
        )

      {count, _} =
        Repo.delete_all(
          from(s in Session, where: s.id in ^ids and s.expires_at <= ^cutoff),
          log: false
        )

      count
    end)
  end

  def prune_expired(_), do: {:error, :invalid_limit}
end
