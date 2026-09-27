defmodule Atoll.Repo do
  @moduledoc """
  Primary repository with optional routing of ordinary reads to `Atoll.ReadRepo`.

  Transactions, checked-out connections, locking queries and migrations stay on
  the primary. Writes pin subsequent reads in the calling process to the primary
  to preserve read-after-write consistency. Use `with_primary/1` for operations
  that must observe current authorization or moderation state.

  Raw `query/3` and `query!/3` always use the primary. Audited read-only SQL uses
  `read_query/3` or `read_query!/3`; SQL is never classified by string matching.
  """
  use Ecto.Repo,
    otp_app: :atoll,
    adapter:
      (case Application.compile_env(:atoll, :database, :postgres) do
         :sqlite -> Ecto.Adapters.SQLite3
         _ -> Ecto.Adapters.Postgres
       end)

  @before_compile Atoll.RepoSQLRouting

  @primary_key {__MODULE__, :primary_reads}
  @primary_scope_key {__MODULE__, :primary_scope}
  @read_transaction_key {__MODULE__, :read_transaction}

  # Override the full arities; Ecto's default-argument wrappers call these too.
  for {name, arity} <- [
        all: 2,
        all_by: 3,
        get: 3,
        get!: 3,
        get_by: 3,
        get_by!: 3,
        one: 2,
        one!: 2,
        exists?: 2,
        reload: 2,
        reload!: 2,
        preload: 3,
        stream: 2,
        aggregate: 4
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)
    query = hd(args)
    opts = List.last(args)

    defoverridable [{name, arity}]

    def unquote(name)(unquote_splicing(args)) do
      # Routing classifies the original query; SQLite then drops the row lock it
      # cannot express, which its single-writer model already guarantees.
      target = reader(unquote(query), unquote(opts))
      unquote(query) = Atoll.Database.strip_lock(unquote(query))

      case target do
        __MODULE__ -> super(unquote_splicing(args))
        repo -> apply(repo, unquote(name), [unquote_splicing(args)])
      end
    end
  end

  # aggregate/3 accepts either a field or options.
  defoverridable aggregate: 3

  def aggregate(query, operation, field_or_opts) do
    opts = if is_list(field_or_opts), do: field_or_opts, else: []

    case reader(query, opts) do
      __MODULE__ -> super(query, operation, field_or_opts)
      repo -> repo.aggregate(query, operation, field_or_opts)
    end
  end

  for {name, arity} <- [
        insert: 2,
        insert!: 2,
        insert_all: 3,
        update: 2,
        update!: 2,
        update_all: 3,
        delete: 2,
        delete!: 2,
        delete_all: 2,
        insert_or_update: 2,
        insert_or_update!: 2,
        transact: 2
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)
    defoverridable [{name, arity}]

    def unquote(name)(unquote_splicing(args)) do
      pin_primary!()
      super(unquote_splicing(args))
    end
  end

  @doc "Run a callback with primary reads, restoring the previous routing scope afterwards."
  def with_primary(fun) when is_function(fun, 0) do
    if Process.get(@read_transaction_key),
      do: raise(ArgumentError, "cannot switch to primary inside a read transaction")

    previous = Process.put(@primary_scope_key, true)

    try do
      fun.()
    after
      restore(@primary_scope_key, previous)
    end
  end

  @doc "The repository for ordinary reads in the current process."
  def reader(query \\ nil, opts \\ []) do
    case Process.get(@read_transaction_key) do
      nil ->
        if not Application.get_env(:atoll, :read_repo_enabled, false) or
             Process.get(@primary_key, false) or Process.get(@primary_scope_key, false) or
             get_dynamic_repo() != __MODULE__ or checked_out?() or primary_query?(query, opts),
           do: __MODULE__,
           else: Atoll.ReadRepo

      repo ->
        if repo != __MODULE__ and primary_query?(query, opts),
          do:
            raise(ArgumentError, "primary/locking reads cannot run inside a replica transaction")

        repo
    end
  end

  defp primary_query?(query, opts),
    do: opts[:primary] == true or opts[:schema_migration] == true or locking?(query)

  @doc "Run audited read-only SQL on the selected read connection."
  def read_query(sql, params \\ [], opts \\ []) do
    repo = reader(nil, opts)
    Ecto.Adapters.SQL.query(repo.get_dynamic_repo(), sql, params, opts)
  end

  def read_query!(sql, params \\ [], opts \\ []) do
    repo = reader(nil, opts)
    Ecto.Adapters.SQL.query!(repo.get_dynamic_repo(), sql, params, opts)
  end

  @doc "Run a read-only callback on one connection, including streamed reads."
  def read_transaction(fun, opts \\ []) when is_function(fun, 0) do
    repo = reader(nil, opts)

    if Process.get(@read_transaction_key) do
      # Nested read callbacks join the outer transaction; rollback aborts it.
      {:ok, fun.()}
    else
      start_read_transaction(repo, fun, opts)
    end
  end

  defp start_read_transaction(repo, fun, opts) do
    repo.transaction(
      fn ->
        previous = Process.put(@read_transaction_key, repo)

        try do
          fun.()
        after
          restore(@read_transaction_key, previous)
        end
      end,
      opts
    )
  end

  defoverridable rollback: 1, in_transaction?: 0

  def rollback(reason) do
    case Process.get(@read_transaction_key) do
      Atoll.ReadRepo -> Atoll.ReadRepo.rollback(reason)
      _ -> super(reason)
    end
  end

  def in_transaction? do
    case Process.get(@read_transaction_key) do
      Atoll.ReadRepo -> Atoll.ReadRepo.in_transaction?()
      _ -> super()
    end
  end

  defp pin_primary! do
    if Process.get(@read_transaction_key),
      do:
        raise(
          ArgumentError,
          "writes and primary transactions cannot run inside a read transaction"
        )

    if Application.get_env(:atoll, :read_repo_enabled, false),
      do: Process.put(@primary_key, true)

    :ok
  end

  # Traverse subqueries and CTEs too: a SELECT can contain locks or a writing CTE.
  defp locking?(%Ecto.Query{lock: lock}) when not is_nil(lock), do: true

  defp locking?(%Ecto.Query.WithExpr{queries: queries}) do
    Enum.any?(queries, fn {_name, opts, query} ->
      Map.get(opts, :operation, :all) != :all or locking?(query)
    end)
  end

  defp locking?(value) when is_map(value),
    do: value |> Map.to_list() |> Enum.any?(fn {_key, v} -> locking?(v) end)

  defp locking?(value) when is_list(value), do: Enum.any?(value, &locking?/1)

  defp locking?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&locking?/1)

  defp locking?(_), do: false

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)
end
