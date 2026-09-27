defmodule Atoll.RepoRoutingTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.Profile

  setup do
    prior = Application.fetch_env(:atoll, :read_repo_enabled)
    # A separate real read-only connection cannot see the primary sandbox's
    # uncommitted rows, simulating a replica that has not replayed a write yet.
    config = Repo.config() |> Keyword.drop([:pool, :name, :url]) |> Keyword.put(:pool_size, 2)
    start_supervised!({Atoll.ReadRepo, config})
    Application.put_env(:atoll, :read_repo_enabled, true)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :read_repo_enabled, value)
        :error -> Application.delete_env(:atoll, :read_repo_enabled)
      end
    end)

    :ok
  end

  test "reads use the optional pool and absence of configuration preserves primary access" do
    assert Repo.reader() == Atoll.ReadRepo
    assert Repo.read_query!("SHOW default_transaction_read_only").rows == [["on"]]
    assert Repo.query!("SHOW default_transaction_read_only").rows == [["off"]]
    assert Atoll.ReadRepo.children() == [Atoll.ReadRepo]

    Application.put_env(:atoll, :read_repo_enabled, false)
    assert Repo.reader() == Repo
    assert Repo.read_query!("SHOW default_transaction_read_only").rows == [["off"]]
    assert Atoll.ReadRepo.children() == []
  end

  test "Ecto reads route to the reader while writes and subsequent reads stay on primary" do
    did = "did:web:routing.example.test"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    Repo.insert!(%Profile{did: did, handle: "routing.example.test"})
    assert Repo.get!(Profile, did).handle == "routing.example.test"
    assert Repo.reader() == Repo

    task =
      Task.async(fn ->
        query = from(p in Profile, where: p.did == ^did)
        assert Repo.reader() == Atoll.ReadRepo
        assert Repo.get(Profile, did) == nil
        assert Repo.get_by(Profile, did: did) == nil
        assert Repo.all(query) == []
        assert Repo.all_by(Profile, did: did) == []
        assert Repo.one(query) == nil
        refute Repo.exists?(query)
        assert Repo.aggregate(query, :count) == 0
        assert Repo.aggregate(query, :count, :did) == 0
        assert Repo.aggregate(query, :count, :did, []) == 0
        assert_raise Ecto.NoResultsError, fn -> Repo.get!(Profile, did) end
        assert_raise Ecto.NoResultsError, fn -> Repo.get_by!(Profile, did: did) end
        assert_raise Ecto.NoResultsError, fn -> Repo.one!(query) end

        assert Repo.get(Profile, did, primary: true).did == did
        assert Repo.reader() == Atoll.ReadRepo
        assert Repo.with_primary(fn -> Repo.get!(Profile, did).did end) == did
        assert Repo.reader() == Atoll.ReadRepo

        assert {:ok, ^did} =
                 Repo.transaction(fn ->
                   assert Repo.reader() == Repo
                   Repo.get!(Profile, did).did
                 end)

        assert Repo.reader() == Repo
      end)

    Task.await(task)
  end

  test "read transactions retain connection affinity, stream, nest and roll back" do
    assert {:ok, :done} =
             Repo.read_transaction(fn ->
               assert Repo.in_transaction?()
               assert Repo.reader() == Atoll.ReadRepo
               assert Repo.read_query!("SHOW transaction_read_only").rows == [["on"]]
               assert Enum.to_list(Repo.stream(from(p in Profile, where: false))) == []
               assert {:ok, 1} = Repo.read_transaction(fn -> 1 end)
               assert_raise ArgumentError, fn -> Repo.insert!(%Profile{}) end
               assert_raise ArgumentError, fn -> Repo.transaction(fn -> :write end) end

               assert_raise ArgumentError, fn ->
                 Repo.query!("DELETE FROM account_profiles WHERE false")
               end

               :done
             end)

    refute Repo.in_transaction?()
    assert {:error, :cancelled} = Repo.read_transaction(fn -> Repo.rollback(:cancelled) end)
    assert Repo.reader() == Atoll.ReadRepo

    assert_raise RuntimeError, "failed", fn -> Repo.read_transaction(fn -> raise "failed" end) end
    assert Repo.reader() == Atoll.ReadRepo
    refute Repo.in_transaction?()
  end

  test "nested read transactions also work without a replica" do
    Application.put_env(:atoll, :read_repo_enabled, false)

    assert {:ok, {:ok, [[1]]}} =
             Repo.read_transaction(fn ->
               Repo.read_transaction(fn -> Repo.read_query!("SELECT 1").rows end)
             end)

    assert {:error, :cancelled} =
             Repo.read_transaction(fn ->
               Repo.read_transaction(fn -> Repo.rollback(:cancelled) end)
             end)
  end

  test "security checks use current primary credentials and availability despite replica lag" do
    did = "did:web:routing-auth.example.test"
    password = "a synthetic routing password"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Atoll.Accounts.Credentials.create(did, password)

    task =
      Task.async(fn ->
        assert Repo.get(Atoll.Accounts.Credential, did) == nil
        assert Atoll.Accounts.Credentials.verify(did, password) == {:ok, %{did: did}}
        assert {:ok, %{did: ^did}} = Atoll.Repositories.get_active_head(did)
      end)

    Task.await(task)
  end

  test "raw primary SQL and writes inside a primary scope preserve subsequent read affinity" do
    assert Repo.reader() == Atoll.ReadRepo

    Repo.with_primary(fn ->
      assert {0, nil} = Repo.delete_all(from(p in Profile, where: false))
    end)

    assert Repo.reader() == Repo

    task =
      Task.async(fn ->
        assert Repo.reader() == Atoll.ReadRepo
        assert Repo.query!("SELECT 1").rows == [[1]]
        assert Repo.reader() == Repo
      end)

    Task.await(task)
  end

  test "locking queries, migrations, explicit primary scopes and checkouts stay primary" do
    query = from(p in Profile, lock: "FOR UPDATE")
    assert Repo.reader(query) == Repo
    assert Repo.reader(from(p in subquery(query), select: p.did)) == Repo
    assert Repo.reader(nil, schema_migration: true) == Repo
    assert Repo.reader(nil, primary: true) == Repo
    assert Repo.checkout(fn -> Repo.reader() end) == Repo
    assert Repo.reader() == Atoll.ReadRepo

    assert_raise RuntimeError, fn -> Repo.with_primary(fn -> raise "failure" end) end
    assert Repo.reader() == Atoll.ReadRepo

    assert {:ok, :done} =
             Repo.read_transaction(fn ->
               assert_raise ArgumentError, fn -> Repo.all(query) end
               assert_raise ArgumentError, fn -> Repo.with_primary(fn -> :primary end) end
               :done
             end)
  end

  test "read-only pool rejects raw writes and readiness checks the reader even in a primary scope" do
    assert {:error, %Postgrex.Error{postgres: %{code: :read_only_sql_transaction}}} =
             Repo.read_query("DELETE FROM account_profiles WHERE false", [], log: false)

    assert Atoll.Readiness.check() == :ready

    previous = Atoll.ReadRepo.put_dynamic_repo(Atoll.UnavailableReadReplica)

    try do
      assert Repo.with_primary(fn -> Atoll.Readiness.check() end) == :unavailable
      assert_raise RuntimeError, fn -> Repo.all(Profile) end
    after
      Atoll.ReadRepo.put_dynamic_repo(previous)
    end
  end
end
