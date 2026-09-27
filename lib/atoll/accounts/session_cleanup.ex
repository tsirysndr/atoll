defmodule Atoll.Accounts.SessionCleanup do
  @moduledoc "Bounded expired-session deletion for trusted operators and scheduled maintenance."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.Session

  def prune_expired(limit \\ 500, actor \\ "operator")

  def prune_expired(_, actor) when actor not in ["operator", "worker"],
    do: {:error, :invalid_cleanup_actor}

  def prune_expired(limit, actor) when is_integer(limit) and limit in 1..1000 do
    cutoff = System.system_time(:second)

    Repo.transaction(fn ->
      Atoll.Database.limits!(1_000, 5_000)
      # Audit insertion uses the event lock. Acquire it before session locks to
      # preserve the order used by account deletion and other operator mutations.
      Atoll.Repositories.Events.lock!()
      # Never acquire repository locks after session locks.
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

      if actor == "operator" or count > 0,
        do: Atoll.Moderation.Audit.session_cleanup!(limit, cutoff, count, actor)

      count
    end)
  end

  def prune_expired(_, _), do: {:error, :invalid_limit}
end
