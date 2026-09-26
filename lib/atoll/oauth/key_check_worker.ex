defmodule Atoll.OAuth.KeyCheckWorker do
  @moduledoc "Periodic bounded checks of confidential OAuth keys, one supervised task at a time."
  use GenServer

  def children(config \\ Application.get_env(:atoll, :oauth_key_checks, [])) do
    if Keyword.get(config, :enabled, true) do
      [
        Supervisor.child_spec({Task.Supervisor, name: Atoll.OAuth.KeyCheckTaskSupervisor},
          id: Atoll.OAuth.KeyCheckTaskSupervisor
        ),
        {__MODULE__, [interval: Keyword.get(config, :interval_ms, 300_000)]}
      ]
    else
      []
    end
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def run_now(server \\ __MODULE__), do: GenServer.cast(server, :run)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      cursor: nil,
      pending_cursor: nil,
      task: nil,
      timer: nil,
      deadline: nil,
      supervisor: Keyword.get(opts, :task_supervisor, Atoll.OAuth.KeyCheckTaskSupervisor),
      run: Keyword.get(opts, :run, &run_batch/2),
      interval: Keyword.get(opts, :interval, 300_000),
      timeout: Keyword.get(opts, :timeout, 20_000)
    }

    {:ok, schedule(state, Keyword.get(opts, :start_after, 60_000))}
  end

  @impl true
  def handle_cast(:run, %{task: nil} = state), do: {:noreply, schedule(state, 0)}
  def handle_cast(:run, state), do: {:noreply, state}

  @impl true
  def handle_info({:timeout, ref, :tick}, %{timer: ref, task: nil} = state) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        checkpoint = fn cursor -> send(owner, {:key_check_cursor, self(), cursor}) end
        state.run.(state.cursor, checkpoint)
      end)

    deadline = :erlang.start_timer(state.timeout, self(), {:deadline, task.ref})
    {:noreply, %{state | task: task, timer: nil, deadline: deadline}}
  end

  def handle_info({:key_check_cursor, pid, cursor}, %{task: %Task{pid: pid}} = state),
    do: {:noreply, %{state | pending_cursor: cursor}}

  def handle_info({ref, {:ok, :done}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(%{state | cursor: nil}, :complete, %{})
  end

  def handle_info({ref, {:ok, %{cursor: cursor} = counts}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(%{state | cursor: cursor}, :ok, counts)
  end

  def handle_info({ref, _}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(state, :failed, %{})
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state),
    do: finish(state, :failed, %{})

  def handle_info(
        {:timeout, timer, {:deadline, ref}},
        %{deadline: timer, task: %Task{ref: ref}} = state
      ) do
    Task.shutdown(state.task, :brutal_kill)
    finish(state, :timeout, %{})
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.deadline, do: Process.cancel_timer(state.deadline)
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    :ok
  end

  defp run_batch(cursor, checkpoint) do
    opts =
      Application.get_env(:atoll, :oauth_transport_options, [])
      |> Keyword.take([:request, :lookup])

    Atoll.OAuth.KeyChecks.run(cursor, Keyword.put(opts, :checkpoint, checkpoint))
  end

  defp finish(state, result, counts) do
    if state.deadline, do: Process.cancel_timer(state.deadline)

    :telemetry.execute(
      [:atoll, :oauth, :key_checks],
      counts |> Map.take([:checked, :revoked, :failed]) |> Map.put(:runs, 1),
      %{result: result}
    )

    # A timed-out client must not prevent checks of every later client.
    advanced = result in [:failed, :timeout] and state.pending_cursor != nil
    state = if advanced, do: %{state | cursor: state.pending_cursor}, else: state
    delay = if result == :ok or advanced, do: 1000, else: state.interval
    {:noreply, schedule(%{state | task: nil, deadline: nil, pending_cursor: nil}, delay)}
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: :erlang.start_timer(delay, self(), :tick)}
  end
end
