defmodule Atoll.IdentityRefreshLeaseConcurrencyTest do
  use ExUnit.Case, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Identity.RefreshLeases
  alias Ecto.Adapters.SQL.Sandbox

  test "independent database connections elect exactly one refresh owner" do
    supervisor = start_supervised!({Task.Supervisor, []})
    did = "did:web:lease-#{System.unique_integer([:positive])}.example.com"

    created_blocks =
      Sandbox.unboxed_run(Repo, fn ->
        before = Repo.query!("SELECT cid FROM blocks").rows |> MapSet.new()
        {:ok, _} = Repositories.create(did, SigningKey.generate())
        Repo.query!("SELECT cid FROM blocks").rows |> Enum.reject(&MapSet.member?(before, &1))
      end)

    try do
      results =
        Task.Supervisor.async_stream_nolink(
          supervisor,
          1..16,
          fn _ ->
            Sandbox.unboxed_run(Repo, fn -> RefreshLeases.claim(did) end)
          end,
          max_concurrency: 8,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == :skipped)) == 15
      {:ok, token} = Enum.find(results, &match?({:ok, _}, &1))

      Sandbox.unboxed_run(Repo, fn ->
        assert :ok = RefreshLeases.complete(did, token)
        assert :skipped = RefreshLeases.claim(did)
      end)
    after
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM repository_events WHERE did = $1", [did])
        Repo.query!("DELETE FROM repositories WHERE did = $1", [did])
        for [cid] <- created_blocks, do: Repo.query!("DELETE FROM blocks WHERE cid = $1", [cid])
      end)
    end
  end
end
