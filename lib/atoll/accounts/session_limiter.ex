defmodule Atoll.Accounts.SessionLimiter do
  @moduledoc "Bounded per-node, fixed-window session request limits using the direct peer IP."
  use GenServer
  @window 300_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def check(key, limit, server \\ __MODULE__), do: GenServer.call(server, {:check, key, limit})

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
