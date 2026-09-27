defmodule AtollWeb.StreamConnections do
  @moduledoc "Node-local live firehose quotas, including pending upgrades and monitored socket owners."
  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def reserve(peer, server \\ __MODULE__) do
    result = call(server, {:reserve, peer})

    outcome =
      case result do
        {:ok, _} -> :accepted
        {:error, :full} -> :full
        _ -> :unavailable
      end

    :telemetry.execute([:atoll, :firehose, :admission], %{count: 1}, %{outcome: outcome})
    result
  end

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot, 100)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def claim({server, token}), do: call(server, {:claim, token})
  def release({server, token}), do: GenServer.cast(server, {:release, token, self()})

  def limit_from_env!(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..100_000 -> limit
      _ -> raise ArgumentError, "firehose connection limits must be integers from 1 to 100000"
    end
  end

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    limits =
      Keyword.get(opts, :limits, fn ->
        {Application.get_env(:atoll, :firehose_max_connections, 1024),
         Application.get_env(:atoll, :firehose_max_connections_per_ip, 16)}
      end)

    {:ok, %{entries: %{}, monitors: %{}, peers: %{}, active: 0, limits: limits}}
  end

  @impl true
  def handle_call(:snapshot, _, state) do
    {total, per_ip} = state.limits.()

    if is_integer(total) and total in 1..100_000 and is_integer(per_ip) and per_ip in 1..100_000 do
      {:reply,
       {:ok,
        %{
          active: state.active,
          pending: map_size(state.entries) - state.active,
          max_connections: total,
          max_connections_per_ip: per_ip
        }}, state}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:reserve, peer}, {owner, _}, state) do
    {total, per_ip} = state.limits.()

    cond do
      not (is_integer(total) and total in 1..100_000 and is_integer(per_ip) and
               per_ip in 1..100_000) ->
        {:reply, {:error, :unavailable}, state}

      map_size(state.entries) >= total or Map.get(state.peers, peer, 0) >= per_ip ->
        {:reply, {:error, :full}, state}

      true ->
        token = make_ref()
        monitor = Process.monitor(owner)
        timer = Process.send_after(self(), {:expire, token}, 30_000)
        entry = %{owner: owner, peer: peer, monitor: monitor, timer: timer, claimed: false}

        state = %{
          state
          | entries: Map.put(state.entries, token, entry),
            monitors: Map.put(state.monitors, monitor, token),
            peers: Map.update(state.peers, peer, 1, &(&1 + 1))
        }

        {:reply, {:ok, {self(), token}}, state}
    end
  end

  def handle_call({:claim, token}, {owner, _}, state) do
    case state.entries[token] do
      %{claimed: false} = entry ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(entry.monitor, [:flush])
        monitor = Process.monitor(owner)
        updated = %{entry | owner: owner, monitor: monitor, timer: nil, claimed: true}

        state = %{
          state
          | entries: Map.put(state.entries, token, updated),
            active: state.active + 1,
            monitors: state.monitors |> Map.delete(entry.monitor) |> Map.put(monitor, token)
        }

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
  def handle_cast({:release, token, owner}, state) do
    case state.entries[token] do
      %{owner: ^owner} -> {:noreply, remove(state, token)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    {:noreply, remove(state, state.monitors[monitor])}
  end

  def handle_info({:expire, token}, state) do
    case state.entries[token] do
      %{claimed: false} -> {:noreply, remove(state, token)}
      _ -> {:noreply, state}
    end
  end

  defp remove(state, token) do
    case Map.pop(state.entries, token) do
      {nil, _} ->
        state

      {entry, entries} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        Process.demonitor(entry.monitor, [:flush])

        peers =
          case state.peers[entry.peer] do
            1 -> Map.delete(state.peers, entry.peer)
            count -> Map.put(state.peers, entry.peer, count - 1)
          end

        %{
          state
          | entries: entries,
            active: state.active - if(entry.claimed, do: 1, else: 0),
            peers: peers,
            monitors: Map.delete(state.monitors, entry.monitor)
        }
    end
  end
end
