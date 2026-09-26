defmodule Atoll.CAR.StageLease do
  @moduledoc "Supervised ownership of private staging files, with cleanup when the request process exits."
  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def open(parent) do
    case DynamicSupervisor.start_child(
           Atoll.CAR.StageSupervisor,
           {__MODULE__, owner: self(), parent: parent}
         ) do
      {:ok, pid} ->
        case GenServer.call(pid, :file) do
          {:ok, io} -> {:ok, pid, io}
        end

      _ ->
        {:error, :car_staging_unavailable}
    end
  catch
    :exit, _ -> {:error, :car_staging_unavailable}
  end

  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  def limit_from_env!(nil), do: 16

  def limit_from_env!(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..64 -> limit
      _ -> raise "ATOLL_IMPORT_CONCURRENCY must be an integer between 1 and 64"
    end
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    monitor = Process.monitor(owner)

    directory =
      Path.join(
        Keyword.fetch!(opts, :parent),
        "atoll-car-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    case File.mkdir(directory) do
      :ok ->
        with :ok <- File.chmod(directory, 0o700),
             {:ok, io} <-
               File.open(Path.join(directory, "blocks"), [:read, :write, :binary, :exclusive]) do
          {:ok, %{owner: owner, monitor: monitor, directory: directory, io: io}}
        else
          _ ->
            File.rm_rf(directory)
            {:stop, :car_staging_unavailable}
        end

      _ ->
        {:stop, :car_staging_unavailable}
    end
  end

  @impl true
  def handle_call(:file, {owner, _}, %{owner: owner} = state),
    do: {:reply, {:ok, state.io}, state}

  def handle_call(:file, _, state), do: {:reply, {:error, :not_owner}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{monitor: ref, owner: owner} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_, state) do
    File.close(state.io)
    File.rm_rf(state.directory)
    :ok
  end
end
