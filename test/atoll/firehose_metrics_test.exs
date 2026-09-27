defmodule Atoll.FirehoseMetricsTest do
  use ExUnit.Case, async: false
  alias Atoll.Metrics.Firehose
  alias AtollWeb.StreamConnections, as: Quota
  @collector __MODULE__.Collector

  setup do
    start_supervised!({Atoll.Metrics, name: @collector})
    server = start_supervised!({Quota, name: nil, limits: fn -> {2, 1} end})
    %{server: server}
  end

  test "live snapshots follow admission, claims and releases without exposing peers", %{
    server: server
  } do
    assert Atoll.Metrics.render(@collector) =~ "atoll_firehose_inventory_available 0\n"
    {:ok, first} = Quota.reserve("secret-peer", server)
    {:ok, second} = Quota.reserve(:other, server)
    assert {:error, :full} = Quota.reserve("secret-peer", server)
    assert :ok = Quota.claim(first)
    Firehose.sample(fn -> Quota.snapshot(server) end)
    text = Atoll.Metrics.render(@collector)
    assert text =~ "atoll_firehose_inventory_available 1\n"
    assert text =~ "atoll_firehose_active 1\n"
    assert text =~ "atoll_firehose_pending 1\n"
    assert text =~ "atoll_firehose_max_connections 2\n"
    assert text =~ "atoll_firehose_max_connections_per_ip 1\n"
    assert text =~ ~s(atoll_firehose_admissions_total{outcome="accepted"} 2\n)
    assert text =~ ~s(atoll_firehose_admissions_total{outcome="full"} 1\n)
    refute text =~ "secret-peer"
    Quota.release(first)
    Quota.release(second)
    Firehose.sample(fn -> Quota.snapshot(server) end)
    text = Atoll.Metrics.render(@collector)
    assert text =~ "atoll_firehose_active 0\n"
    assert text =~ "atoll_firehose_pending 0\n"
    stop_supervised!(Quota)
    assert {:error, :unavailable} = Quota.reserve(:peer, server)

    assert Atoll.Metrics.render(@collector) =~
             ~s(atoll_firehose_admissions_total{outcome="unavailable"} 1\n)
  end

  test "failed snapshots preserve last observations and freshness, and recovery replaces them", %{
    server: server
  } do
    {:ok, lease} = Quota.reserve(:one, server)
    :ok = Quota.claim(lease)
    Firehose.sample(fn -> Quota.snapshot(server) end)
    before = Atoll.Metrics.render(@collector)
    [_, time] = Regex.run(~r/^atoll_firehose_inventory_success_time_seconds (\d+)$/m, before)

    for query <- [
          fn -> {:error, :busy} end,
          fn -> exit(:noproc) end,
          fn -> raise "private server state" end,
          fn ->
            {:ok, %{active: -1, pending: 0, max_connections: 2, max_connections_per_ip: 1}}
          end
        ] do
      Firehose.sample(query)
      text = Atoll.Metrics.render(@collector)
      assert text =~ "atoll_firehose_inventory_available 0\n"
      assert text =~ "atoll_firehose_inventory_success_time_seconds #{time}\n"
      assert text =~ "atoll_firehose_active 1\n"
      refute text =~ "private"
    end

    Quota.release(lease)
    Firehose.sample(fn -> Quota.snapshot(server) end)
    assert Atoll.Metrics.render(@collector) =~ "atoll_firehose_inventory_available 1\n"
    assert Atoll.Metrics.render(@collector) =~ "atoll_firehose_active 0\n"
    stop_supervised!(Atoll.Metrics)
    start_supervised!({Atoll.Metrics, name: @collector})
    assert Atoll.Metrics.render(@collector) =~ "atoll_firehose_inventory_success_time_seconds 0\n"
  end

  test "disabled polling performs no work and forged labels cannot add series" do
    before = Atoll.Metrics.render(@collector)
    :ok = Firehose.poll(fn -> flunk("disabled poll queried connection manager") end)
    :telemetry.execute([:atoll, :firehose, :admission], %{count: 1}, %{outcome: "secret-label"})
    text = Atoll.Metrics.render(@collector)
    refute text =~ "secret-label"

    for text <- [before, text] do
      assert text =~ ~s(atoll_firehose_admissions_total{outcome="accepted"} 0\n)
    end
  end

  test "unresponsive quota managers cannot block scrapes", %{server: server} do
    :sys.suspend(server)

    try do
      assert {:error, :unavailable} = Quota.snapshot(server)
      Firehose.sample(fn -> Quota.snapshot(server) end)
      assert Atoll.Metrics.render(@collector) =~ "atoll_firehose_inventory_available 0\n"
    after
      :sys.resume(server)
    end
  end
end
