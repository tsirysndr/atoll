defmodule Atoll.Accounts.SignupRetryWorker do
  @moduledoc "Opt-in scheduled retries of previously attempted signup registrations."
  use GenServer

  def children(config \\ Application.get_env(:atoll, :signup_retry, [])) do
    if Keyword.get(config, :enabled, false) do
      [
        Supervisor.child_spec({Task.Supervisor, name: Atoll.Accounts.SignupRetryTaskSupervisor},
          id: Atoll.Accounts.SignupRetryTaskSupervisor
        ),
        {__MODULE__, [interval: Keyword.get(config, :interval_ms, 30_000)]}
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
      task: nil,
      timer: nil,
      deadline: nil,
      supervisor: Keyword.get(opts, :task_supervisor, Atoll.Accounts.SignupRetryTaskSupervisor),
      run: Keyword.get(opts, :run, &run_batch/0),
      interval: Keyword.get(opts, :interval, 30_000),
      timeout: Keyword.get(opts, :timeout, 45_000)
    }

    {:ok, schedule(state, Keyword.get(opts, :start_after, 60_000))}
  end

  @impl true
  def handle_cast(:run, %{task: nil} = state), do: {:noreply, schedule(state, 0)}
  def handle_cast(:run, state), do: {:noreply, state}

  @impl true
  def handle_info({:timeout, ref, :tick}, %{timer: ref, task: nil} = state) do
    task = Task.Supervisor.async_nolink(state.supervisor, state.run)
    deadline = :erlang.start_timer(state.timeout, self(), {:deadline, task.ref})
    {:noreply, %{state | task: task, timer: nil, deadline: deadline}}
  end

  def handle_info({ref, {:ok, counts}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(state, :ok, counts)
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

  defp run_batch do
    opts =
      Keyword.merge(
        Application.get_env(:atoll, :identity_resolution_options, []),
        Application.get_env(:atoll, :plc_submission_options, [])
      )

    Atoll.Accounts.SignupRetries.run_next(opts)
  end

  defp finish(state, result, counts) do
    if state.deadline, do: Process.cancel_timer(state.deadline)

    :telemetry.execute(
      [:atoll, :accounts, :signup_retry],
      counts |> Map.take([:attempted, :completed, :failed]) |> Map.put(:runs, 1),
      %{result: result}
    )

    {:noreply, schedule(%{state | task: nil, deadline: nil}, state.interval)}
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: :erlang.start_timer(delay, self(), :tick)}
  end
end
