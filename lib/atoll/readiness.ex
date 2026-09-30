defmodule Atoll.Readiness do
  @moduledoc "Bounded connectivity probes for the primary and optional reader, independent of liveness."

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
    repos = [Atoll.Repo] ++ Atoll.ReadRepo.children()

    if Enum.all?(repos, fn repo ->
         match?(
           {:ok, %{rows: [[1]]}},
           Ecto.Adapters.SQL.query(repo.get_dynamic_repo(), "SELECT 1", [],
             timeout: 1_000,
             # Wait briefly for a connection rather than refuse to queue for one.
             # SQLite runs a single connection, so a query in flight would
             # otherwise report a merely busy server as an unreachable one.
             queue_target: 500,
             queue_interval: 1_000,
             log: false
           )
         )
       end),
       do: :ready,
       else: :unavailable
  rescue
    # Missing repo processes and connection failures must still produce a health response.
    _ in [RuntimeError, DBConnection.ConnectionError, Postgrex.Error, Exqlite.Error] ->
      :unavailable
  catch
    :exit, _ -> :unavailable
  end
end
