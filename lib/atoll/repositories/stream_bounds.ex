defmodule Atoll.Repositories.StreamBounds do
  @moduledoc "Shares one bounded retention-bounds read across idle stream subscribers."
  use GenServer
  alias Atoll.Repositories.EventRetention

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def get do
    if Application.get_env(:atoll, :stream_bounds_cache_enabled, true),
      do: GenServer.call(__MODULE__, :get),
      else: fetch()
  end

  def fetch do
    {:ok, EventRetention.bounds(timeout: 2_000, queue: false, log: false)}
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error, Exqlite.Error] -> {:error, :database_busy}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       value: nil,
       expires: nil,
       fetch: Keyword.get(opts, :fetch, &fetch/0),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call(:get, _from, state) do
    now = state.clock.()

    if state.expires && now < state.expires do
      {:reply, state.value, state}
    else
      value = state.fetch.()
      # Cache transient failure too, preventing hundreds of subscribers from
      # retrying the same exhausted pool at once. Never serve stale bounds.
      {:reply, value, %{state | value: value, expires: state.clock.() + 500}}
    end
  end
end
