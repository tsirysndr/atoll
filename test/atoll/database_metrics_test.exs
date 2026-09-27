defmodule Atoll.DatabaseMetricsTest do
  use Atoll.DataCase, async: false
  alias Atoll.Metrics.Database
  @collector __MODULE__.Collector

  setup do
    start_supervised!({Atoll.Metrics, name: @collector})
    :ok
  end

  test "database inventory reports both backends, oldest jobs and queue removal" do
    assert Atoll.Metrics.render(@collector) =~ "atoll_database_inventory_available 0\n"
    now = DateTime.utc_now()
    old = DateTime.add(now, -3600, :second)

    for {backend, time, bytes} <- [
          {:postgres, old, "old"},
          {:postgres, now, "new"},
          {:s3, now, "s3"}
        ] do
      Repo.insert!(%Atoll.Blobs.CleanupJob{
        cid: Atoll.CID.create(bytes, :raw),
        backend: backend,
        queued_at: time
      })
    end

    Database.sample()
    text = Atoll.Metrics.render(@collector)
    assert text =~ "atoll_database_inventory_available 1\n"
    assert text =~ ~s(atoll_blob_cleanup_pending{backend="postgres"} 2\n)
    assert text =~ ~s(atoll_blob_cleanup_pending{backend="s3"} 1\n)

    assert text =~
             ~s(atoll_blob_cleanup_oldest_time_seconds{backend="postgres"} #{DateTime.to_unix(old)}\n)

    assert text =~
             ~s(atoll_blob_cleanup_oldest_time_seconds{backend="s3"} #{DateTime.to_unix(now)}\n)

    refute text =~ Atoll.CID.to_base32(Atoll.CID.create("old", :raw))

    Repo.delete_all(Atoll.Blobs.CleanupJob)
    Database.sample()
    text = Atoll.Metrics.render(@collector)

    for backend <- ["postgres", "s3"] do
      assert text =~ ~s(atoll_blob_cleanup_pending{backend="#{backend}"} 0\n)
      assert text =~ ~s(atoll_blob_cleanup_oldest_time_seconds{backend="#{backend}"} 0\n)
    end
  end

  test "failed polling preserves observations and freshness, while recovery replaces them" do
    Database.sample(fn -> {:ok, %{"s3" => {7, 100}, "secret-account" => {1, 100}}} end)
    before = Atoll.Metrics.render(@collector)
    assert before =~ "atoll_database_inventory_available 1\n"
    [_, time] = Regex.run(~r/^atoll_database_inventory_success_time_seconds (\d+)$/m, before)

    for query <- [
          fn -> {:error, :busy} end,
          fn -> raise DBConnection.ConnectionError, "private database details" end,
          fn -> exit(:noproc) end
        ] do
      Database.sample(query)
      text = Atoll.Metrics.render(@collector)
      assert text =~ "atoll_database_inventory_available 0\n"
      assert text =~ "atoll_database_inventory_success_time_seconds #{time}\n"
      assert text =~ ~s(atoll_blob_cleanup_pending{backend="s3"} 7\n)
      refute text =~ "secret"
      refute text =~ "private"
    end

    Database.sample(fn -> {:ok, %{}} end)
    assert Atoll.Metrics.render(@collector) =~ "atoll_database_inventory_available 1\n"
    assert Atoll.Metrics.render(@collector) =~ ~s(atoll_blob_cleanup_pending{backend="s3"} 0\n)
    stop_supervised!(Atoll.Metrics)
    start_supervised!({Atoll.Metrics, name: @collector})
    assert Atoll.Metrics.render(@collector) =~ "atoll_database_inventory_success_time_seconds 0\n"
  end

  test "disabled scheduled polling never calls the database and malformed telemetry stays unavailable" do
    refute Database.enabled?()
    caller = self()

    assert :ok =
             Database.poll(fn ->
               send(caller, :queried_when_disabled)
               {:ok, %{}}
             end)

    refute_received :queried_when_disabled
    Database.sample(fn -> {:ok, %{"postgres" => {-1, nil}}} end)
    assert Atoll.Metrics.render(@collector) =~ "atoll_database_inventory_available 0\n"
  end
end
