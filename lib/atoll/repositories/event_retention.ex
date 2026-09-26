defmodule Atoll.Repositories.EventRetention do
  @moduledoc "Explicit bounded pruning of an expired event prefix, with a durable replay floor."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Repositories.{Event, Events}

  def config_from_env!(env, test? \\ false) do
    enabled =
      case Map.get(env, "ATOLL_EVENT_RETENTION_ENABLED", "false") do
        "true" -> true
        "false" -> false
        _ -> raise ArgumentError, "ATOLL_EVENT_RETENTION_ENABLED must be true or false"
      end

    seconds =
      case Integer.parse(Map.get(env, "ATOLL_EVENT_RETENTION_SECONDS", "604800")) do
        {value, ""} when value in 3600..31_536_000 ->
          value

        _ ->
          raise ArgumentError,
                "ATOLL_EVENT_RETENTION_SECONDS must be an integer from 3600 to 31536000"
      end

    %{enabled: enabled and not test?, seconds: seconds}
  end

  def bounds do
    %{rows: [[floor, latest]]} =
      Repo.query!("""
      SELECT cursor_floor, GREATEST(cursor_floor, COALESCE((SELECT max(seq) FROM repository_events), 0))
      FROM event_retention_state WHERE id = 1
      """)

    %{floor: floor, latest: latest}
  end

  @doc "Hold through event selection to prevent pruning between the floor check and read."
  def lock_floor! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "retention reads require a transaction")

    %{rows: [[floor]]} =
      Repo.query!("SELECT cursor_floor FROM event_retention_state WHERE id = 1 FOR SHARE")

    floor
  end

  def prune(limit \\ 1000, retention_seconds \\ 604_800)

  def prune(limit, retention_seconds)
      when is_integer(limit) and limit in 1..1000 and is_integer(retention_seconds) and
             retention_seconds in 3600..31_536_000 do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      Events.lock!()

      %{rows: [[floor]]} =
        Repo.query!("SELECT cursor_floor FROM event_retention_state WHERE id = 1 FOR UPDATE")

      %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'")
      cutoff = now |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-retention_seconds, :second)

      prefix =
        Repo.all(
          from e in Event, order_by: e.seq, limit: ^limit, select: %{seq: e.seq, time: e.time}
        )
        |> Enum.take_while(&(DateTime.compare(&1.time, cutoff) == :lt))

      if prefix == [] do
        %{deleted: 0, floor: floor}
      else
        last = List.last(prefix).seq
        {count, _} = Repo.delete_all(from e in Event, where: e.seq <= ^last)
        new_floor = max(floor, last)

        Repo.query!("UPDATE event_retention_state SET cursor_floor = $1 WHERE id = 1", [new_floor])

        %{deleted: count, floor: new_floor}
      end
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :event_retention_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def prune(_, _), do: {:error, :invalid_retention_options}
end
