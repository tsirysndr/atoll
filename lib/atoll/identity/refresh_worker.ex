defmodule Atoll.Identity.RefreshWorker do
  @moduledoc """
  Opt-in identity sweeper with database-coordinated automatic refreshes. Visits hosted DIDs in order, with one
  supervised refresh task at a time. Failures advance the cursor and retry on
  the next sweep. The cursor is in memory; restart safely repeats observations.
  """
  use GenServer
  alias Atoll.{Repositories, Identity.RefreshLeases}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def run_now(server \\ __MODULE__), do: GenServer.cast(server, :run)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      cursor: nil,
      task: nil,
      timer: nil,
      deadline: nil,
      supervisor: Keyword.get(opts, :task_supervisor, Atoll.Identity.TaskSupervisor),
      next: Keyword.get(opts, :next, &next_did/1),
      refresh: Keyword.get(opts, :refresh, &RefreshLeases.refresh/1),
      interval: Keyword.get(opts, :interval, 300_000),
      spacing: Keyword.get(opts, :spacing, 1000),
      timeout: Keyword.get(opts, :timeout, 20_000)
    }

    {:ok, schedule(state, Keyword.get(opts, :start_after, 1000))}
  end

  @impl true
  def handle_cast(:run, %{task: nil} = state), do: {:noreply, schedule(state, 0)}
  def handle_cast(:run, state), do: {:noreply, state}

  @impl true
  def handle_info({:timeout, ref, :tick}, %{timer: ref, task: nil} = state) do
    case state.next.(state.cursor) do
      nil ->
        {:noreply, schedule(%{state | cursor: nil}, state.interval)}

      did ->
        refresh = state.refresh
        task = Task.Supervisor.async_nolink(state.supervisor, fn -> refresh.(did) end)
        deadline = :erlang.start_timer(state.timeout, self(), {:deadline, task.ref})
        {:noreply, %{state | cursor: did, task: task, timer: nil, deadline: deadline}}
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    outcome =
      case result do
        {:ok, :published} -> :published
        {:ok, :unchanged} -> :unchanged
        {:ok, :skipped} -> :skipped
        _ -> :failed
      end

    finish(state, outcome)
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state),
    do: finish(state, :failed)

  def handle_info(
        {:timeout, timer, {:deadline, ref}},
        %{deadline: timer, task: %Task{ref: ref}} = state
      ) do
    Task.shutdown(state.task, :brutal_kill)
    finish(state, :timeout)
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.deadline, do: Process.cancel_timer(state.deadline)
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    :ok
  end

  defp finish(state, result) do
    if state.deadline, do: Process.cancel_timer(state.deadline)

    :telemetry.execute([:atoll, :identity, :refresh], %{count: 1}, %{
      did: state.cursor,
      result: result
    })

    {:noreply, schedule(%{state | task: nil, deadline: nil}, state.spacing)}
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: :erlang.start_timer(delay, self(), :tick)}
  end

  defp next_did(cursor) do
    case Repositories.list_heads(1, cursor).repos do
      [%{did: did}] -> did
      [] -> nil
    end
  end
end
