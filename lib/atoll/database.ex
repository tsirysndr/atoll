defmodule Atoll.Database do
  @moduledoc """
  Database-adapter differences behind one interface.

  The adapter is fixed when the project is compiled, so every predicate here is
  a compile-time constant and the unused branch is eliminated. PostgreSQL is the
  default; build with `ATOLL_DATABASE=sqlite` for a single-node SQLite server.

  PostgreSQL serializes repository writes with a transaction advisory lock and
  bounds each transaction with `lock_timeout`/`statement_timeout`. SQLite admits
  one writer at a time for the whole database, so the advisory lock and the row
  locks are redundant there and the equivalent bound is the connection's busy
  timeout. Statement timeouts have no SQLite equivalent and are not emulated.
  """
  @adapters %{postgres: Ecto.Adapters.Postgres, sqlite: Ecto.Adapters.SQLite3}

  @adapter Application.compile_env(:atoll, :database, :postgres)

  unless @adapter in Map.keys(@adapters) do
    raise "config :atoll, :database must be :postgres or :sqlite, got: #{inspect(@adapter)}"
  end

  @doc "The configured adapter name, fixed at compile time."
  def adapter, do: @adapter

  @doc "The Ecto adapter module for the configured database."
  def ecto_adapter, do: Map.fetch!(@adapters, @adapter)

  defmacro postgres?, do: unquote(@adapter) == :postgres
  defmacro sqlite?, do: unquote(@adapter) == :sqlite

  @doc false
  def adapter_from_env!(nil), do: :postgres
  def adapter_from_env!("postgres"), do: :postgres
  def adapter_from_env!("postgresql"), do: :postgres
  def adapter_from_env!("sqlite"), do: :sqlite
  def adapter_from_env!("sqlite3"), do: :sqlite

  def adapter_from_env!(value),
    do: raise(ArgumentError, "ATOLL_DATABASE must be postgres or sqlite, got: #{inspect(value)}")

  def error_code(%Postgrex.Error{postgres: postgres}), do: postgres[:code]

  def error_code(%Exqlite.Error{message: message})
      when message in [
             "Database busy",
             "Database is busy",
             "database is locked",
             "database is busy"
           ],
      do: :lock_not_available

  def error_code(%Exqlite.Error{}), do: :other

  def blob(value), do: if(@adapter == :sqlite, do: {:blob, value}, else: value)

  @doc "Select SQL for the compiled adapter. Only use with static, audited SQL."
  def sql(postgres, sqlite), do: if(@adapter == :postgres, do: postgres, else: sqlite)

  defmacro sql_fragment(postgres, sqlite, args \\ [], sqlite_args \\ nil) do
    sql = if @adapter == :postgres, do: postgres, else: sqlite
    args = if @adapter == :sqlite and sqlite_args, do: sqlite_args, else: args

    quote do
      fragment(unquote(sql), unquote_splicing(args))
    end
  end

  def read_limits!(lock_ms \\ 1_000, statement_ms \\ 5_000) do
    if @adapter == :postgres do
      Atoll.Repo.read_query!("SET LOCAL lock_timeout = '#{lock_ms}ms'", [], log: false)
      Atoll.Repo.read_query!("SET LOCAL statement_timeout = '#{statement_ms}ms'", [], log: false)
    end

    :ok
  end

  if @adapter == :postgres do
    @doc "Bound the current transaction's lock wait and statement duration."
    def limits!(lock_ms \\ 1_000, statement_ms \\ 5_000) do
      Atoll.Repo.query!("SET LOCAL lock_timeout = '#{lock_ms}ms'")
      Atoll.Repo.query!("SET LOCAL statement_timeout = '#{statement_ms}ms'")
      :ok
    end

    @doc "Serialize repository writes so sequence allocation matches commit order."
    def serialize_writes!(key) when is_integer(key) do
      Ecto.Adapters.SQL.query!(Atoll.Repo, "SELECT pg_advisory_xact_lock($1)", [key])
      :ok
    end

    @doc "Current wall-clock seconds, unaffected by the transaction's start time."
    def now_seconds! do
      %{rows: [[seconds]]} =
        Atoll.Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

      seconds
    end

    @doc "Current wall-clock UTC timestamp, unaffected by the transaction's start time."
    def now_utc! do
      %{rows: [[time]]} = Atoll.Repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'")
      time
    end

    @doc "Row-level lock clause for a raw SQL statement."
    def for_update, do: " FOR UPDATE"
    def for_share, do: " FOR SHARE"

    @doc false
    def strip_lock(query), do: query
  else
    # SQLite admits a single writer per database, so these bounds and locks are
    # already implied. The busy timeout is configured on each connection.
    def limits!(_lock_ms \\ 1_000, _statement_ms \\ 5_000), do: :ok
    def serialize_writes!(key) when is_integer(key), do: :ok

    # The database is local, so the process clock is the database clock.
    def now_seconds!, do: System.system_time(:second)
    def now_utc!, do: DateTime.utc_now() |> DateTime.to_naive()

    def for_update, do: ""
    def for_share, do: ""

    @doc "Drop a redundant row lock so a query compiles on SQLite."
    def strip_lock(%Ecto.Query{lock: lock} = query) when not is_nil(lock),
      do: %{query | lock: nil}

    def strip_lock(query), do: query
  end
end
