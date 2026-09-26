defmodule Atoll.Repositories.Events do
  @moduledoc """
  Internal durable event outbox, not subscribeRepos wire messages.

  Every repository mutation takes the same transaction advisory lock before
  touching heads or blocks. This serializes writes so sequence allocation and
  transaction visibility have the same order. Sequence gaps after rollback are
  expected. Callers composing transactions must acquire this lock first too.
  Events and their referenced blocks are retained indefinitely for now.
  """
  import Ecto.Query
  alias Atoll.{CBOR, Repo}
  alias Atoll.Repositories.Event

  @doc "Acquire before any repository mutation, inside its transaction."
  def lock! do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "event lock requires a transaction")
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [4_182_026_001])
    :ok
  end

  @doc false
  def append!(kind, head, payload) do
    lock!()

    Repo.insert!(%Event{
      did: head.did,
      kind: kind,
      payload: CBOR.encode!(payload),
      time: DateTime.utc_now()
    })
  end

  def latest_seq, do: Repo.one(from e in Event, select: max(e.seq)) || 0

  @doc "Replay up to 1000 events after an exclusive numeric cursor. Payloads are decoded CBOR."
  def list_after(cursor, limit \\ 100)

  def list_after(cursor, limit)
      when is_integer(cursor) and cursor >= 0 and cursor <= 9_223_372_036_854_775_807 and
             is_integer(limit) and limit in 1..1000 do
    events = Repo.all(from e in Event, where: e.seq > ^cursor, order_by: e.seq, limit: ^limit)

    {:ok,
     Enum.map(events, fn event ->
       {:ok, payload} = CBOR.decode(event.payload)
       %{seq: event.seq, did: event.did, kind: event.kind, time: event.time, payload: payload}
     end)}
  end

  def list_after(_, _), do: {:error, :invalid_cursor_or_limit}
end
