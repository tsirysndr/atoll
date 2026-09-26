defmodule Atoll.DistributedLimiterTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{DistributedLimiter, SessionLimiter}

  test "shares counts, preserves expiry on denial, and resets expired windows" do
    key = {:login, {192, 0, 2, 1}}
    assert :ok = DistributedLimiter.check(key, 2)
    assert :ok = DistributedLimiter.check(key, 2)
    assert {:error, seconds} = DistributedLimiter.check(key, 2)
    assert seconds in 1..300
    assert [[2, expiry]] = Repo.query!("SELECT count, expires_at FROM request_rate_buckets").rows
    assert {:error, _} = DistributedLimiter.check(key, 2)
    assert [[2, ^expiry]] = Repo.query!("SELECT count, expires_at FROM request_rate_buckets").rows
    Repo.query!("UPDATE request_rate_buckets SET expires_at = 1")
    assert :ok = DistributedLimiter.check(key, 2)
    assert [[1, later]] = Repo.query!("SELECT count, expires_at FROM request_rate_buckets").rows
    assert later >= expiry
    assert :ok = DistributedLimiter.check({:admin, {192, 0, 2, 1}}, 2)
    assert :ok = DistributedLimiter.check({:login, {192, 0, 2, 2}}, 2)
  end

  test "bounds storage, denies new keys at capacity, and reclaims expired rows in batches" do
    now = System.system_time(:second)
    rows = for n <- 1..10_000, do: %{digest: <<n::256>>, count: 1, expires_at: now + 3600}
    Repo.insert_all("request_rate_buckets", rows)
    assert {:error, 300} = DistributedLimiter.check({:xrpc, {192, 0, 2, 3}}, 2)
    Repo.query!("UPDATE request_rate_buckets SET expires_at = 1")
    assert :ok = DistributedLimiter.check({:xrpc, {192, 0, 2, 3}}, 2)
    assert [[9001]] = Repo.query!("SELECT count(*) FROM request_rate_buckets").rows
  end

  test "database errors fail closed and emit only an availability count" do
    owner = self()
    ref = make_ref()
    :telemetry.attach(ref, [:atoll, :rate_limit, :unavailable], &__MODULE__.report/4, owner)
    on_exit(fn -> :telemetry.detach(ref) end)

    assert {:error, :restore} =
             Repo.transaction(fn ->
               Repo.query!(
                 "ALTER TABLE request_rate_buckets RENAME TO temporarily_unavailable_rate_buckets"
               )

               assert {:error, 1} = DistributedLimiter.check({:login, {192, 0, 2, 4}}, 2)
               assert_receive {:unavailable, %{count: 1}, %{}}
               Repo.rollback(:restore)
             end)
  end

  test "backend configuration accepts only explicitly supported stores" do
    assert SessionLimiter.backend_from_env!(nil) == :memory
    assert SessionLimiter.backend_from_env!("memory") == :memory
    assert SessionLimiter.backend_from_env!("postgres") == :postgres

    for value <- ["", "REDIS", "POSTGRES", "disabled"],
        do: assert_raise(ArgumentError, fn -> SessionLimiter.backend_from_env!(value) end)
  end

  def report(_, measurements, metadata, owner),
    do: send(owner, {:unavailable, measurements, metadata})
end
