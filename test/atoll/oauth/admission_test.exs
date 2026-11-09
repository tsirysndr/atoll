defmodule Atoll.OAuth.AdmissionTest do
  use Atoll.DataCase, async: false
  require Atoll.Database
  alias Atoll.OAuth.{Admission, PKCEUse}
  @lock 4_182_026_052

  test "setup and lock each read the database clock in a single statement" do
    watch_queries()

    assert {:ok, {start, locked}} =
             Repo.transaction(fn ->
               start = Admission.start!()
               locked = Admission.lock_now!(@lock)
               {start, locked}
             end)

    assert is_integer(start) and locked >= start
    assert abs(locked - System.system_time(:second)) <= 5

    if Atoll.Database.postgres?() do
      queries = queries()
      assert Enum.count(queries, &String.contains?(&1, "clock_timestamp()")) == 2
      refute Enum.any?(queries, &String.starts_with?(&1, "SET LOCAL"))
    end
  end

  test "locked setup installs transaction-local timeouts and reads the clock once" do
    watch_queries()

    assert {:ok, now} =
             Repo.transaction(fn ->
               now = Admission.start!(@lock)

               if Atoll.Database.postgres?() do
                 assert %{rows: [[lock_timeout, statement_timeout]]} =
                          Repo.query!(
                            "SELECT current_setting('lock_timeout'), current_setting('statement_timeout')"
                          )

                 assert lock_timeout in ["1s", "1000ms"]
                 assert statement_timeout in ["5s", "5000ms"]
               end

               now
             end)

    assert abs(now - System.system_time(:second)) <= 5

    if Atoll.Database.postgres?() do
      assert Enum.count(queries(), &String.contains?(&1, "clock_timestamp()")) == 1
    end
  end

  test "one bounded delete reclaims the oldest expired markers and preserves live markers" do
    now = System.system_time(:second)
    rows = for i <- 1..1005, do: %{digest: <<i::256>>, expires_at: now - i}
    Repo.insert_all(PKCEUse, rows, log: false)
    Repo.insert!(%PKCEUse{digest: <<1006::256>>, expires_at: now + 3600})
    watch_queries()

    assert {:ok, {1000, nil}} = Repo.transaction(fn -> Admission.prune!(PKCEUse, now) end)
    cleanup = Enum.filter(queries(), &String.contains?(&1, "oauth_pkce_uses"))
    assert [delete] = cleanup
    assert String.starts_with?(delete, "DELETE")
    assert Repo.aggregate(PKCEUse, :count) == 6
    assert Repo.get!(PKCEUse, <<1006::256>>).expires_at == now + 3600
    assert Repo.get!(PKCEUse, <<1::256>>)
    refute Repo.get(PKCEUse, <<1005::256>>)
  end

  defp watch_queries do
    owner = self()
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:atoll, :repo, :query], &__MODULE__.capture/4, owner)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def capture(_, _, metadata, owner) do
    if self() == owner, do: send(owner, {:admission_query, metadata.query})
  end

  defp queries(acc \\ []) do
    receive do
      {:admission_query, query} -> queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
