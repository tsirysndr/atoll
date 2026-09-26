defmodule Atoll.Accounts.SessionLimiter do
  @moduledoc "Request budgets backed by bounded node-local memory or shared PostgreSQL state."
  use GenServer
  @window 300_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def check(key, limit) do
    case Application.get_env(:atoll, :rate_limit_backend, :memory) do
      :memory -> check(key, limit, __MODULE__)
      :postgres -> Atoll.Accounts.DistributedLimiter.check(key, limit)
    end
  end

  # Explicit servers remain available for isolated clocks and limiter tests.
  def check(key, limit, server), do: GenServer.call(server, {:check, key, limit})

  def backend_from_env!(nil), do: :memory
  def backend_from_env!("memory"), do: :memory
  def backend_from_env!("postgres"), do: :postgres

  def backend_from_env!(_),
    do: raise(ArgumentError, "ATOLL_RATE_LIMIT_BACKEND must be memory or postgres")

  @impl true
  def init(opts) do
    timer = Process.send_after(self(), :sweep, @window)

    {:ok,
     %{
       entries: %{},
       capacity: Keyword.get(opts, :capacity, 10_000),
       timer: timer,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:check, key, limit}, _from, state) do
    now = state.clock.()

    case Map.get(state.entries, key) do
      {count, expires} when expires > now and count >= limit ->
        {:reply, {:error, max(1, div(expires - now + 999, 1000))}, state}

      {count, expires} when expires > now ->
        {:reply, :ok, put_in(state.entries[key], {count + 1, expires})}

      nil when map_size(state.entries) >= state.capacity ->
        {:reply, {:error, 300}, state}

      _ ->
        {:reply, :ok, put_in(state.entries[key], {1, now + @window})}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.cancel_timer(state.timer)
    now = state.clock.()
    entries = Map.reject(state.entries, fn {_key, {_count, expires}} -> expires <= now end)
    timer = Process.send_after(self(), :sweep, @window)
    {:noreply, %{state | entries: entries, timer: timer}}
  end
end
