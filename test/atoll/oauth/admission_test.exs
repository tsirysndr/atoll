defmodule Atoll.OAuth.AdmissionTest do
  use Atoll.DataCase, async: false
  require Atoll.Database
  alias Atoll.OAuth.{Admission, PKCEUse, PushedRequest}
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

  test "batched marker cleanup reports the post-cleanup replay state and count" do
    now = System.system_time(:second)
    Repo.insert_all(PKCEUse, for(i <- 1..1005, do: %{digest: <<i::256>>, expires_at: now - i}))
    Repo.insert!(%PKCEUse{digest: <<1006::256>>, expires_at: now + 3600})
    watch_queries()

    assert {:ok, %{replayed: false, count: 6}} =
             Repo.transaction(fn -> Admission.prune_and_status!(PKCEUse, now, <<1005::256>>) end)

    if Atoll.Database.postgres?(),
      do: assert(Enum.count(queries(), &String.contains?(&1, "oauth_pkce_uses")) == 1)

    assert Repo.aggregate(PKCEUse, :count) == 6
    assert Repo.get!(PKCEUse, <<1::256>>)
    refute Repo.get(PKCEUse, <<1005::256>>)

    assert {:ok, %{replayed: true, count: 1}} =
             Repo.transaction(fn -> Admission.prune_and_status!(PKCEUse, now, <<1006::256>>) end)
  end

  test "batched request cleanup reclaims both tables and preserves live challenges" do
    now = System.system_time(:second)
    request = request(now - 1)
    Repo.insert!(request)
    Repo.insert!(%PKCEUse{digest: <<1::256>>, expires_at: now - 1})
    Repo.insert!(%PKCEUse{digest: <<2::256>>, expires_at: now + 3600})
    watch_queries()

    assert {:ok, %{replayed: false, requests: 0, challenges: 1}} =
             Repo.transaction(fn -> Admission.request_status!(now, <<1::256>>) end)

    if Atoll.Database.postgres?(),
      do: assert(Enum.count(queries(), &String.contains?(&1, "oauth_pkce_uses")) == 1)

    refute Repo.get(PushedRequest, request.digest)
    refute Repo.get(PKCEUse, <<1::256>>)
    assert Repo.get!(PKCEUse, <<2::256>>)
  end

  test "request and challenge insert together in one statement with exact JSON values" do
    now = System.system_time(:second)
    challenge = %PKCEUse{digest: <<1::256>>, expires_at: now + 86400}
    request = request(now + 600)
    watch_queries()

    assert {:ok, :ok} =
             Repo.transaction(fn -> Admission.insert_request!(challenge, request) end)

    if Atoll.Database.postgres?(),
      do: assert(Enum.count(queries(), &String.contains?(&1, "oauth_pkce_uses")) == 1)

    assert Repo.get!(PKCEUse, challenge.digest).expires_at == challenge.expires_at
    stored = Repo.get!(PushedRequest, request.digest)
    assert stored.parameters == request.parameters
    assert stored.permission_sets == request.permission_sets
    assert stored.client_binding == request.client_binding
    assert stored.expires_at == request.expires_at
  end

  defp request(expires_at) do
    %PushedRequest{
      digest: <<3::256>>,
      issuer: "https://pds.example.com",
      client_id: "https://app.example.com/metadata.json",
      parameters: %{"scope" => "atproto", "prompt" => "create", "state" => "opaque"},
      permission_sets: %{},
      client_binding: %{"kid" => "signing", "alg" => "ES256", "jkt" => String.duplicate("k", 43)},
      dpop_jkt: String.duplicate("p", 43),
      expires_at: expires_at
    }
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
