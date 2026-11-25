defmodule Atoll.Repositories.Events do
  @moduledoc """
  Internal durable event outbox, not subscribeRepos wire messages.

  Every repository mutation takes the same transaction advisory lock before
  touching heads or blocks. This serializes writes so sequence allocation and
  transaction visibility have the same order. Sequence gaps after rollback are
  expected. Callers composing transactions must acquire this lock first too.
  Event retention is operator-controlled; referenced repository blocks remain retained.
  """
  require Atoll.Database
  import Ecto.Query
  alias Atoll.{CBOR, Repo}
  alias Atoll.Repositories.{Event, EventEncoder, EventRetention, Head}

  @lock_key 4_182_026_001

  @doc "Acquire before any repository mutation, inside its transaction."
  def lock! do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "event lock requires a transaction")
    Atoll.Database.serialize_writes!(@lock_key)
    :ok
  end

  @doc "Attempt background maintenance without queuing behind repository writes."
  def try_lock! do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "event lock requires a transaction")

    if Atoll.Database.postgres?() do
      %{rows: [[acquired]]} = Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [@lock_key])
      acquired
    else
      true
    end
  end

  @doc false
  def append!(kind, head, payload) do
    lock!()

    event =
      Repo.insert!(%Event{
        did: head.did,
        kind: kind,
        payload: CBOR.encode!(payload),
        time: DateTime.utc_now()
      })

    Atoll.Repositories.EventDependencies.track!(event, payload)
  end

  def latest_seq, do: EventRetention.bounds().latest

  @doc "Counts only enough pending rows to detect a slow consumer; sequence gaps do not count."
  def backlog_exceeded?(cursor, limit \\ 10_000) do
    query = from e in Event, where: e.seq > ^cursor, select: e.seq, limit: ^(limit + 1)
    Repo.aggregate(subquery(query), :count) > limit
  end

  @doc "Build immutable bytes before taking the short primary availability lock."
  def next_frame(cursor) do
    with {:ok, events} <- list_after(cursor, 1) do
      case events do
        [] -> {:ok, :idle}
        [event] -> prepare_frame(event, cursor)
      end
    end
  end

  defp prepare_frame(event, cursor) do
    # Encoding can read many historical blocks over a remote connection. Never
    # hold the head's shared lock while doing that: a writer waiting for it also
    # owns the global event lock and would stall every repository's writes.
    encoded = EventEncoder.encode(event)

    Repo.transaction(fn ->
      if cursor < EventRetention.lock_floor!(), do: Repo.rollback(:outdated_cursor)
      head = Repo.one(from h in Head, where: h.did == ^event.did, lock: "FOR SHARE")

      if event.kind in [:account, :identity] or match?(%Head{status: :active}, head) do
        case encoded do
          {:ok, frame} -> {:frame, event.seq, frame}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:skip, event.seq}
      end
    end)
  end

  @doc "Replay up to 1000 events after an exclusive numeric cursor. Payloads are decoded CBOR."
  def list_after(cursor, limit \\ 100)

  def list_after(cursor, limit)
      when is_integer(cursor) and cursor >= 0 and cursor <= 9_223_372_036_854_775_807 and
             is_integer(limit) and limit in 1..1000 do
    Repo.transaction(fn ->
      if cursor < EventRetention.lock_floor!(), do: Repo.rollback(:outdated_cursor)
      events = Repo.all(from e in Event, where: e.seq > ^cursor, order_by: e.seq, limit: ^limit)

      Enum.map(events, fn event ->
        {:ok, payload} = CBOR.decode(event.payload)
        %{seq: event.seq, did: event.did, kind: event.kind, time: event.time, payload: payload}
      end)
    end)
  end

  def list_after(_, _), do: {:error, :invalid_cursor_or_limit}
end
