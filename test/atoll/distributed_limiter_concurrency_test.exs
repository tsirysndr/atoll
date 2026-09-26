defmodule Atoll.DistributedLimiterConcurrencyTest do
  use ExUnit.Case, async: false
  alias Atoll.{Repo, Accounts.DistributedLimiter}
  alias Ecto.Adapters.SQL.Sandbox

  test "independent database connections cannot exceed a shared budget" do
    supervisor = start_supervised!({Task.Supervisor, []})
    key = {:concurrency_test, :crypto.strong_rand_bytes(24)}
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(key, minor_version: 2))

    try do
      results =
        Task.Supervisor.async_stream_nolink(
          supervisor,
          1..24,
          fn _ ->
            Sandbox.unboxed_run(Repo, fn -> DistributedLimiter.check(key, 7) end)
          end,
          max_concurrency: 8,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 7
      assert Enum.count(results, &match?({:error, seconds} when seconds in 1..300, &1)) == 17

      Sandbox.unboxed_run(Repo, fn ->
        assert [[7]] =
                 Repo.query!("SELECT count FROM request_rate_buckets WHERE digest = $1", [digest]).rows

        assert {:error, _} = DistributedLimiter.check(key, 7)
      end)
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM request_rate_buckets WHERE digest = $1", [digest])
      end)
    end
  end
end
