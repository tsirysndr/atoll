defmodule AtollWeb.RepoStreamSocket do
  @moduledoc """
  Database-backed subscribeRepos delivery. Polls when idle, emits one event per
  callback, and disconnects consumers more than 10,000 durable events behind.
  No per-client event queue or uncommitted PubSub notifications are used.
  """
  @behaviour WebSock
  alias Atoll.Repositories.{EventEncoder, Events}

  @impl true
  def init({:error, :invalid_cursor}), do: stop("InvalidRequest", "Invalid cursor", %{})

  def init({:ok, cursor}) do
    latest = Events.latest_seq()

    if cursor && cursor > latest do
      stop("FutureCursor", "Cursor is ahead of the stream", %{})
    else
      {:ok, schedule(%{cursor: cursor || latest, idle: 0}, 0)}
    end
  end

  @impl true
  def handle_in(_, state), do: {:ok, state}

  @impl true
  def handle_info(:drain, state) do
    if Events.backlog_exceeded?(state.cursor) do
      stop("ConsumerTooSlow", "Replay backlog exceeds 10000 events", state)
    else
      case Events.next_frame(state.cursor) do
        {:ok, {:frame, seq, frame}} ->
          {:push, {:binary, frame}, schedule(%{state | cursor: seq, idle: 0}, 0)}

        {:ok, {:skip, seq}} ->
          {:ok, schedule(%{state | cursor: seq, idle: 0}, 0)}

        {:ok, :idle} ->
          next = schedule(%{state | idle: rem(state.idle + 1, 30)}, 500)
          if next.idle == 0, do: {:push, {:ping, ""}, next}, else: {:ok, next}

        {:error, _} ->
          stop("InternalServerError", "Unable to read repository event", state)
      end
    end
  end

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_, state) do
    if timer = state[:timer], do: Process.cancel_timer(timer)
    :ok
  end

  defp schedule(state, delay),
    do: Map.put(state, :timer, Process.send_after(self(), :drain, delay))

  defp stop(error, message, state),
    do: {:stop, :normal, 1000, {:binary, EventEncoder.error(error, message)}, state}
end
