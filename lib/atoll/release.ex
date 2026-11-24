defmodule Atoll.Release do
  @moduledoc "Release tasks executed with `bin/atoll eval`; Mix is not available in releases."
  @app :atoll

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          # A cold remote PostgreSQL pool can take longer to establish TLS
          # connections than its normal checkout queue permits. Probe without
          # queuing until a connection is usable before submitting migration DDL.
          await_database(repo, System.monotonic_time(:millisecond) + 60_000)
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  defp await_database(repo, deadline) do
    case Ecto.Adapters.SQL.query(repo, "SELECT 1", [], queue: false, timeout: 5_000, log: false) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise error
        else
          Process.sleep(250)
          await_database(repo, deadline)
        end
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
