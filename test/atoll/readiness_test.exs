defmodule Atoll.ReadinessTest do
  use ExUnit.Case, async: false
  require Atoll.Database

  @moduletag :readiness

  setup do
    config =
      Atoll.Repo.config()
      |> Keyword.merge(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)
      |> database()

    {:ok, pool} = Atoll.Repo.start_link(config)
    prior = Atoll.Repo.put_dynamic_repo(pool)

    on_exit(fn ->
      Atoll.Repo.put_dynamic_repo(prior)
      if path = config[:database], do: Enum.each(["", "-shm", "-wal"], &File.rm(path <> &1))
    end)

    %{pool: pool}
  end

  # A pool of its own, so holding the only connection cannot disturb the sandbox.
  defp database(config) do
    if Atoll.Database.sqlite?(),
      do: Keyword.put(config, :database, Path.expand("readiness_probe_test.sqlite3")),
      else: config
  end

  test "a busy connection pool is not reported as an unreachable database", %{pool: pool} do
    parent = self()

    holder =
      spawn_link(fn ->
        Atoll.Repo.put_dynamic_repo(pool)

        Atoll.Repo.transaction(fn ->
          send(parent, :holding)
          Process.sleep(150)
        end)

        send(parent, :released)
      end)

    assert_receive :holding, 2_000
    assert Process.alive?(holder)

    # The single connection is checked out for the whole probe's first attempt.
    assert Atoll.Readiness.check() == :ready
    assert_receive :released, 5_000
  end

  test "an unreachable database is still reported as unavailable" do
    prior = Atoll.Repo.put_dynamic_repo(Atoll.UnavailableReadinessTestRepo)

    try do
      assert Atoll.Readiness.check() == :unavailable
    after
      Atoll.Repo.put_dynamic_repo(prior)
    end
  end
end
