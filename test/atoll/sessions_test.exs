defmodule Atoll.Accounts.SessionsTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Session, Sessions, Tokens}
  @did "did:plc:sessions"
  @password "session test password"
  @opts [
    secret: :binary.copy(<<9>>, 32),
    audience: "did:web:pds.example.test",
    now: 1_800_000_000
  ]

  setup do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, @password)
    :ok
  end

  test "caps live sessions while allowing refresh, expiry and revocation to release capacity" do
    opts = Keyword.put(@opts, :max_sessions, 1)
    {:ok, first} = Sessions.create(@did, @password, opts)
    assert {:error, :session_limit_exceeded} = Sessions.create(@did, @password, opts)
    assert Repo.aggregate(Session, :count) == 1
    assert {:ok, refreshed} = Sessions.refresh(first.refresh_jwt, opts)
    assert {:ok, :ok} = Sessions.revoke(refreshed.refresh_jwt, opts)
    assert {:ok, next} = Sessions.create(@did, @password, opts)
    {:ok, claims} = Tokens.verify(next.refresh_jwt, :refresh, opts)
    later = Keyword.put(opts, :now, claims["exp"])
    assert {:ok, _} = Sessions.create(@did, @password, later)
    assert Repo.aggregate(Session, :count) == 2
  end

  test "zero disables new sessions without invalidating existing sessions" do
    {:ok, pair} = Sessions.create(@did, @password, @opts)
    opts = Keyword.put(@opts, :max_sessions, 0)
    assert {:error, :session_limit_exceeded} = Sessions.create(@did, @password, opts)
    assert {:ok, %{did: @did}} = Sessions.authenticate(pair.access_jwt, opts)
    assert {:ok, _} = Sessions.refresh(pair.refresh_jwt, opts)
  end

  test "session caps are account scoped and invalid settings fail closed" do
    other = "did:plc:othersessions"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, _} = Credentials.create(other, @password)
    opts = Keyword.put(@opts, :max_sessions, 1)
    assert {:ok, _} = Sessions.create(@did, @password, opts)
    assert {:ok, _} = Sessions.create(other, @password, opts)

    for limit <- [-1, 1001, "100", nil] do
      assert {:error, :invalid_session_limit} =
               Sessions.create(@did, @password, Keyword.put(@opts, :max_sessions, limit))
    end
  end

  test "creates sessions only after password verification and stores no bearer tokens" do
    assert Sessions.create(@did, "wrong password", @opts) == {:error, :invalid_credentials}
    refute Repo.exists?(Session)
    {:ok, pair} = Sessions.create(@did, @password, @opts)
    assert Sessions.authenticate(pair.access_jwt, @opts) == {:ok, %{did: @did}}
    session = Repo.one!(Session)
    assert byte_size(session.refresh_hash) == 32
    refute inspect(session) =~ pair.refresh_jwt
    refute inspect(session) =~ inspect(session.refresh_hash)
    assert Sessions.authenticate(pair.refresh_jwt, @opts) == {:error, :invalid_token}
    assert Sessions.refresh(pair.access_jwt, @opts) == {:error, :invalid_token}
  end

  test "refresh rotates once and revocation immediately invalidates all access tokens in the session" do
    {:ok, first} = Sessions.create(@did, @password, @opts)
    later = Keyword.put(@opts, :now, @opts[:now] + 1)
    {:ok, second} = Sessions.refresh(first.refresh_jwt, later)
    refute first.refresh_jwt == second.refresh_jwt
    assert Sessions.refresh(first.refresh_jwt, later) == {:error, :invalid_token}
    assert Sessions.revoke(first.refresh_jwt, later) == {:error, :invalid_token}
    assert Sessions.authenticate(first.access_jwt, later) == {:ok, %{did: @did}}
    assert Sessions.authenticate(second.access_jwt, later) == {:ok, %{did: @did}}
    assert Sessions.revoke(second.refresh_jwt, later) == {:ok, :ok}
    assert Sessions.authenticate(first.access_jwt, later) == {:error, :invalid_token}
    assert Sessions.authenticate(second.access_jwt, later) == {:error, :invalid_token}
    assert Sessions.refresh(second.refresh_jwt, later) == {:error, :invalid_token}
  end

  test "independent logins remain independent and reject unpersisted signed tokens" do
    {:ok, first} = Sessions.create(@did, @password, @opts)
    {:ok, second} = Sessions.create(@did, @password, @opts)
    {:ok, :ok} = Sessions.revoke(first.refresh_jwt, @opts)
    assert Sessions.authenticate(second.access_jwt, @opts) == {:ok, %{did: @did}}
    {:ok, unpersisted} = Tokens.pair(@did, Tokens.random_id(), @opts)
    assert Sessions.authenticate(unpersisted.access_jwt, @opts) == {:error, :invalid_token}
    assert Sessions.refresh(unpersisted.refresh_jwt, @opts) == {:error, :invalid_token}
  end

  test "inactive repositories cannot create, authenticate or refresh sessions but can revoke" do
    for status <- [:deactivated, :takendown, :suspended] do
      {:ok, _} = Repositories.set_status(@did, :active)
      {:ok, pair} = Sessions.create(@did, @password, @opts)
      {:ok, _} = Repositories.set_status(@did, status)
      assert Sessions.create(@did, @password, @opts) == {:error, {:repo_inactive, status}}
      assert Sessions.authenticate(pair.access_jwt, @opts) == {:error, {:repo_inactive, status}}
      assert Sessions.refresh(pair.refresh_jwt, @opts) == {:error, {:repo_inactive, status}}
      assert Sessions.revoke(pair.refresh_jwt, @opts) == {:ok, :ok}
    end
  end

  test "binds a session to its account and current refresh identifier" do
    {:ok, original} = Sessions.create(@did, @password, @opts)
    {:ok, claims} = Tokens.verify(original.access_jwt, :access, @opts)
    other = "did:plc:sessionother"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, forged_account} = Tokens.pair(other, claims["sid"], @opts)
    assert Sessions.authenticate(forged_account.access_jwt, @opts) == {:error, :invalid_token}
    assert Sessions.refresh(forged_account.refresh_jwt, @opts) == {:error, :invalid_token}
    {:ok, wrong_refresh} = Tokens.pair(@did, claims["sid"], @opts)
    assert Sessions.refresh(wrong_refresh.refresh_jwt, @opts) == {:error, :invalid_token}
    assert Sessions.revoke(wrong_refresh.refresh_jwt, @opts) == {:error, :invalid_token}
    assert Sessions.authenticate(original.access_jwt, @opts) == {:ok, %{did: @did}}
  end

  test "missing configuration and rolled-back creation leave no live sessions" do
    assert Sessions.create(@did, @password, Keyword.put(@opts, :secret, nil)) ==
             {:error, :session_configuration_missing}

    assert {:error, pair} =
             Repo.transaction(fn ->
               {:ok, pair} = Sessions.create(@did, @password, @opts)
               Repo.rollback(pair)
             end)

    refute Repo.exists?(Session)
    assert Sessions.authenticate(pair.access_jwt, @opts) == {:error, :invalid_token}
    assert Sessions.refresh(pair.refresh_jwt, @opts) == {:error, :invalid_token}
  end

  test "expiration and transaction rollback prevent session reuse" do
    {:ok, pair} = Sessions.create(@did, @password, @opts)

    assert Sessions.authenticate(pair.access_jwt, Keyword.put(@opts, :now, @opts[:now] + 7200)) ==
             {:error, :expired_token}

    assert {:error, :abort} =
             Repo.transaction(fn ->
               {:ok, _} = Sessions.refresh(pair.refresh_jwt, @opts)
               Repo.rollback(:abort)
             end)

    assert {:ok, _} = Sessions.refresh(pair.refresh_jwt, @opts)
    Repo.update_all(Session, set: [expires_at: @opts[:now]])
    assert Sessions.authenticate(pair.access_jwt, @opts) == {:error, :expired_token}
  end
end
