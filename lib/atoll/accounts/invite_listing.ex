defmodule Atoll.Accounts.InviteListing do
  @moduledoc "Bounded invite listings with owner authorization and keyset admin pagination."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{Invite, InviteUse, Sessions}
  alias Atoll.Repositories.Events
  @max_uses 10_000

  @doc "Internal admin listing; caller must authenticate the operator."
  def admin(params) when is_map(params) do
    sort = Map.get(params, "sort", "recent")

    with true <- Map.keys(params) -- ["sort", "limit", "cursor"] == [],
         true <- sort in ["recent", "usage"],
         {:ok, limit} <- limit(params["limit"]),
         {:ok, cursor} <- cursor(params["cursor"], sort) do
      read(fn ->
        query = ordered(sort) |> after_cursor(cursor, sort) |> limit(^(limit + 1))
        rows = Repo.all(query, log: false)

        {page, _uses} =
          Enum.reduce_while(rows, {[], 0}, fn row, {page, uses} ->
            next = uses + row.use_count - row.remaining

            if length(page) < limit and next <= @max_uses,
              do: {:cont, {[row | page], next}},
              else: {:halt, {page, uses}}
          end)

        page = Enum.reverse(page)
        result = %{codes: details!(page)}

        if length(rows) > length(page) and page != [],
          do: Map.put(result, :cursor, encode_cursor(List.last(page), sort)),
          else: result
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def admin(_), do: {:error, :invalid_request}

  def account(token, params) when is_map(params) do
    with true <- Map.keys(params) -- ["includeUsed", "createAvailable"] == [],
         {:ok, include_used} <- boolean(Map.get(params, "includeUsed", "true")),
         {:ok, create_available} <- boolean(Map.get(params, "createAvailable", "true")),
         {:ok, _} <- Sessions.authenticate_management(token) do
      read(fn ->
        head =
          case Sessions.authenticate_management(token) do
            {:ok, head} -> head
            {:error, reason} -> Repo.rollback(reason)
          end

        if create_available, do: Atoll.Accounts.InviteAllocation.allocate!(head.did)

        query = ordered("recent") |> where([i], i.for_account == ^head.did) |> limit(1001)
        query = if include_used, do: query, else: where(query, [i], i.remaining > 0)
        rows = Repo.all(query, log: false)

        if length(rows) > 1000 or
             Enum.sum(Enum.map(rows, &(&1.use_count - &1.remaining))) > @max_uses,
           do: Repo.rollback(:invite_listing_too_large)

        %{codes: details!(rows)}
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def account(_, _), do: {:error, :invalid_request}

  defp ordered("recent"), do: from(i in Invite, order_by: [desc: i.inserted_at, asc: i.code])

  defp ordered("usage"),
    do:
      from(i in Invite,
        order_by: [
          desc: fragment("? - ?", i.use_count, i.remaining),
          desc: i.inserted_at,
          asc: i.code
        ]
      )

  defp after_cursor(query, nil, _), do: query

  defp after_cursor(query, {time, code, _used}, "recent"),
    do: where(query, [i], i.inserted_at < ^time or (i.inserted_at == ^time and i.code > ^code))

  defp after_cursor(query, {time, code, used}, "usage"),
    do:
      where(
        query,
        [i],
        fragment("? - ?", i.use_count, i.remaining) < ^used or
          (fragment("? - ?", i.use_count, i.remaining) == ^used and
             (i.inserted_at < ^time or (i.inserted_at == ^time and i.code > ^code)))
      )

  @doc "Internal bounded formatter; call inside a consistent invite read transaction."
  def details!(rows) do
    codes = Enum.map(rows, & &1.code)

    uses =
      Repo.all(
        from(u in InviteUse,
          where: u.code in ^codes,
          order_by: [desc: u.inserted_at, asc: u.did],
          limit: @max_uses + 1
        ),
        log: false
      )

    if length(uses) > @max_uses, do: Repo.rollback(:invite_listing_too_large)

    grouped =
      Enum.group_by(
        uses,
        & &1.code,
        &%{usedBy: &1.did, usedAt: DateTime.to_iso8601(&1.inserted_at)}
      )

    Enum.map(rows, fn row ->
      %{
        code: row.code,
        available: row.use_count,
        disabled: row.disabled,
        forAccount: row.for_account || "admin",
        createdBy: row.created_by,
        createdAt: DateTime.to_iso8601(row.inserted_at),
        uses: Map.get(grouped, row.code, [])
      }
    end)
  end

  defp encode_cursor(row, sort),
    do:
      [1, sort, DateTime.to_iso8601(row.inserted_at), row.code, row.use_count - row.remaining]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

  defp cursor(nil, _), do: {:ok, nil}

  defp cursor(encoded, sort) when is_binary(encoded) and byte_size(encoded) <= 512 do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, [1, ^sort, time, code, used]} <- Jason.decode(json),
         true <- is_binary(time) and byte_size(time) <= 40,
         {:ok, time, 0} <- DateTime.from_iso8601(time),
         true <-
           is_binary(code) and byte_size(code) == 32 and
             Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, code),
         true <- is_integer(used) and used in 0..10_000 do
      {:ok, {time, code, used}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp cursor(_, _), do: {:error, :invalid_request}
  defp limit(nil), do: {:ok, 100}

  defp limit(value) when is_binary(value) and byte_size(value) <= 3 do
    case Integer.parse(value) do
      {number, ""} when number in 1..500 -> {:ok, number}
      _ -> {:error, :invalid_request}
    end
  end

  defp limit(_), do: {:error, :invalid_request}
  defp boolean("true"), do: {:ok, true}
  defp boolean("false"), do: {:ok, false}
  defp boolean(_), do: {:error, :invalid_request}

  defp read(fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      # Shared mutation order gives a consistent count/history view without lock upgrades.
      Events.lock!()
      fun.()
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end
end
