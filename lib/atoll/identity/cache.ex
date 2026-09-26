defmodule Atoll.Identity.Cache do
  @moduledoc """
  Bounded node-local positive DID cache. Network work stays in callers.
  Fetch tokens prevent older in-flight responses from replacing newer lookups.
  Payloads are serialized internally to enforce an exact stored-payload byte cap.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def fetch(server, did, fresh?, loader) do
    case call(server, {:checkout, did, fresh?}, :uncached) do
      {:hit, encoded} ->
        {:ok, :erlang.binary_to_term(encoded, [:safe])}

      checkout ->
        result = loader.()

        case checkout do
          {:miss, token} -> call(server, {:complete, did, token, result}, :ok)
          :uncached -> :ok
        end

        result
    end
  end

  @impl true
  def init(opts) do
    ttl = Keyword.get(opts, :ttl_ms, 60_000)
    count = Keyword.get(opts, :max_entries, 256)
    bytes = Keyword.get(opts, :max_bytes, 8 * 1024 * 1024)

    unless is_integer(ttl) and ttl in 0..300_000 and is_integer(count) and count in 1..10_000 and
             is_integer(bytes) and bytes in 1..(64 * 1024 * 1024),
           do: raise(ArgumentError, "invalid DID cache limits")

    {:ok,
     %{
       entries: %{},
       ttl: ttl,
       max_entries: count,
       max_bytes: bytes,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:checkout, did, fresh?}, _, state) do
    now = state.clock.()
    state = prune(state, now)

    case Map.get(state.entries, did) do
      %{payload: payload} when not fresh? and is_binary(payload) ->
        {:reply, {:hit, payload}, state}

      _ when state.ttl == 0 ->
        {:reply, :uncached, state}

      _ ->
        token = make_ref()

        entry = %{
          token: token,
          payload: nil,
          expires: now + 30_000,
          order: System.unique_integer([:monotonic, :positive])
        }

        state = %{state | entries: Map.put(state.entries, did, entry)} |> bound()
        {:reply, {:miss, token}, state}
    end
  end

  def handle_call({:complete, did, token, result}, _, state) do
    now = state.clock.()
    state = prune(state, now)

    state =
      case Map.get(state.entries, did) do
        %{token: ^token} = entry ->
          case result do
            {:ok, %{"id" => ^did} = document} ->
              payload = :erlang.term_to_binary(document)

              if byte_size(payload) <= state.max_bytes do
                entry = %{entry | payload: payload, expires: now + state.ttl}
                %{state | entries: Map.put(state.entries, did, entry)} |> bound()
              else
                %{state | entries: Map.delete(state.entries, did)}
              end

            _ ->
              %{state | entries: Map.delete(state.entries, did)}
          end

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  defp prune(state, now),
    do: %{state | entries: Map.reject(state.entries, fn {_, entry} -> entry.expires <= now end)}

  defp bound(state) do
    size =
      Enum.reduce(state.entries, 0, fn {_, e}, acc ->
        acc + if(e.payload, do: byte_size(e.payload), else: 0)
      end)

    if map_size(state.entries) > state.max_entries or size > state.max_bytes do
      {oldest, _} = Enum.min_by(state.entries, fn {_, e} -> e.order end)
      bound(%{state | entries: Map.delete(state.entries, oldest)})
    else
      state
    end
  end

  # A cache restart or failure never prevents authoritative resolution.
  defp call(server, message, fallback) do
    GenServer.call(server, message)
  catch
    :exit, _ -> fallback
  end
end
