defmodule Atoll.Metrics.Database do
  @moduledoc "Bounded periodic database inventory; never queried from the metrics endpoint."
  alias Atoll.Repo

  def enabled? do
    Application.get_env(:atoll, :metrics_enabled, false) == true and
      Application.get_env(:atoll, :metrics_database_polling_enabled, true) == true
  end

  def poll(query \\ &snapshot/0) do
    if enabled?(), do: sample(query)
    :ok
  end

  @doc false
  def sample(query \\ &snapshot/0) do
    result = read(query)
    :telemetry.execute([:atoll, :metrics, :database], %{}, %{result: result})
  end

  def snapshot do
    Repo.read_transaction(
      fn ->
        Atoll.Database.read_limits!(100, 2_000)

        %{rows: rows} =
          Repo.read_query!(
            Atoll.Database.sql(
              """
              SELECT backend, count(*), floor(extract(epoch FROM min(queued_at)))::bigint
              FROM blob_cleanup_jobs GROUP BY backend
              """,
              "SELECT backend, count(*), unixepoch(min(queued_at)) FROM blob_cleanup_jobs GROUP BY backend"
            ),
            [],
            log: false
          )

        Map.new(rows, fn [backend, count, oldest] -> {backend, {count, oldest}} end)
      end,
      timeout: 3_000,
      log: false
    )
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
