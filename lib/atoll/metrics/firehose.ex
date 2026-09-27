defmodule Atoll.Metrics.Firehose do
  @moduledoc "Bounded live-connection inventory, sampled outside the metrics HTTP request."

  def poll(query \\ &AtollWeb.StreamConnections.snapshot/0) do
    if Application.get_env(:atoll, :metrics_enabled, false) == true, do: sample(query)
    :ok
  end

  @doc false
  def sample(query \\ &AtollWeb.StreamConnections.snapshot/0) do
    :telemetry.execute([:atoll, :metrics, :firehose], %{}, %{result: read(query)})
  end

  defp read(query) do
    case query.() do
      {:ok, rows} -> {:ok, rows, System.system_time(:second)}
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end
end
