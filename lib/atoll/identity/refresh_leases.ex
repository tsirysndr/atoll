defmodule Atoll.Identity.RefreshLeases do
  @moduledoc "PostgreSQL leases and publication fencing for automatic identity refreshes."
  alias Atoll.Repo

  def refresh(did, opts \\ []) do
    case claim(did) do
      {:ok, token} ->
        result = Atoll.Identity.Updates.refresh(did, Keyword.put(opts, :refresh_lease, token))

        case complete(did, token) do
          :ok -> result
          error -> error
        end

      :skipped ->
        {:ok, :skipped}

      error ->
        error
    end
  end

  def claim(did) do
    token = :crypto.strong_rand_bytes(32)

    case bounded(fn ->
           Repo.query!(
             """
             INSERT INTO identity_refresh_leases (did, token, leased_until, next_attempt_at)
             SELECT did, $2, clock_timestamp() + interval '60 seconds', clock_timestamp()
             FROM repositories WHERE did = $1
             ON CONFLICT (did) DO UPDATE SET token = EXCLUDED.token,
               leased_until = clock_timestamp() + interval '60 seconds', next_attempt_at = clock_timestamp()
             WHERE identity_refresh_leases.leased_until <= clock_timestamp()
               AND identity_refresh_leases.next_attempt_at <= clock_timestamp()
             RETURNING token
             """,
             [did, token],
             log: false
           )
         end) do
      {:ok, %{num_rows: 1}} -> {:ok, token}
      {:ok, %{num_rows: 0}} -> :skipped
      error -> error
    end
  end

  def complete(did, token) do
    case bounded(fn ->
           Repo.query!(
             """
             UPDATE identity_refresh_leases
             SET leased_until = clock_timestamp(), next_attempt_at = clock_timestamp() + interval '300 seconds'
             WHERE did = $1 AND token = $2 AND leased_until > clock_timestamp()
             """,
             [did, token],
             log: false
           )
         end) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :stale_refresh_lease}
      error -> error
    end
  end

  @doc "Checks ownership inside the publication transaction, after event and repository locks."
  def assert_current!(did, token) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "refresh fencing requires a transaction")

    Repo.query!("SELECT did FROM identity_refresh_leases WHERE did = $1 FOR UPDATE", [did],
      log: false
    )

    # Check database time after acquiring the row lock, not before any lock wait.
    case Repo.query!(
           "SELECT 1 FROM identity_refresh_leases WHERE did = $1 AND token = $2 AND leased_until > clock_timestamp()",
           [did, token],
           log: false
         ) do
      %{num_rows: 1} -> :ok
      _ -> Repo.rollback(:stale_refresh_lease)
    end
  end

  defp bounded(fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      fun.()
    end)
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :refresh_lease_unavailable}
  end
end
