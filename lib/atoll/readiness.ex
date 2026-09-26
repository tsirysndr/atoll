defmodule Atoll.Readiness do
  @moduledoc "A bounded PostgreSQL connectivity probe, independent of liveness."

  def check do
    started = System.monotonic_time()
    outcome = database()

    :telemetry.execute(
      [:atoll, :readiness, :check],
      %{duration: System.monotonic_time() - started, count: 1},
      %{outcome: outcome}
    )

    outcome
  end

  defp database do
    case Atoll.Repo.query("SELECT 1", [], timeout: 1_000, queue: false, log: false) do
      {:ok, %{rows: [[1]]}} -> :ready
      _ -> :unavailable
    end
  rescue
    # Missing repo processes and connection failures must still produce a health response.
    _ in [RuntimeError, DBConnection.ConnectionError, Postgrex.Error] -> :unavailable
  catch
    :exit, _ -> :unavailable
  end
end
