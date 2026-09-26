defmodule Atoll.Accounts.SignupRetries do
  @moduledoc "Durable fair retry scheduling and activation fencing for previously attempted signups."
  alias Atoll.Repo

  def config_from_env!(env) do
    enabled =
      case Map.get(env, "ATOLL_SIGNUP_RETRY_ENABLED", "false") do
        "true" -> true
        "false" -> false
        _ -> raise ArgumentError, "ATOLL_SIGNUP_RETRY_ENABLED must be true or false"
      end

    integer = fn name, default, range ->
      case Integer.parse(Map.get(env, name, default)) do
        {value, ""} ->
          if value in range,
            do: value,
            else: raise(ArgumentError, "#{name} is outside its permitted range")

        _ ->
          raise ArgumentError, "#{name} must be an integer"
      end
    end

    [
      enabled: enabled,
      interval_ms: integer.("ATOLL_SIGNUP_RETRY_INTERVAL_SECONDS", "30", 1..3600) * 1000,
      delay_seconds: integer.("ATOLL_SIGNUP_RETRY_DELAY_SECONDS", "300", 60..86400)
    ]
  end

  def run_next(opts \\ []) do
    delay = Application.get_env(:atoll, :signup_retry, []) |> Keyword.get(:delay_seconds, 300)

    with {:ok, claim} <- claim(delay) do
      case claim do
        nil ->
          {:ok, %{attempted: 0, completed: 0, failed: 0}}

        %{did: did, cid: cid, token: token} ->
          result =
            Atoll.Accounts.Signup.resume_registration(
              did,
              cid,
              Keyword.put(opts, :signup_retry_token, token)
            )

          with :ok <- release(did, token) do
            success = match?({:ok, _}, result)

            {:ok,
             %{
               attempted: 1,
               completed: if(success, do: 1, else: 0),
               failed: if(success, do: 0, else: 1)
             }}
          end
      end
    end
  end

  def claim(delay \\ 300) when is_integer(delay) and delay in 60..86400 do
    token = :crypto.strong_rand_bytes(32)

    case bounded(fn ->
           Repo.query!(
             """
             WITH candidate AS (
               SELECT r.did FROM plc_registrations r
               JOIN repositories h ON h.did = r.did
               WHERE r.retry_eligible AND r.submission_started_at IS NOT NULL AND r.completed_at IS NULL
                 AND h.status = 'deactivated'
                 AND (r.retry_next_at <= clock_timestamp() OR (r.retry_next_at IS NULL AND r.submission_started_at + ($2::integer * interval '1 second') <= clock_timestamp()))
                 AND (r.retry_leased_until IS NULL OR r.retry_leased_until <= clock_timestamp())
               ORDER BY COALESCE(r.retry_next_at, r.submission_started_at), r.did
               LIMIT 1 FOR UPDATE OF r SKIP LOCKED
             )
             UPDATE plc_registrations r SET retry_token = $1,
               retry_leased_until = clock_timestamp() + interval '60 seconds',
               retry_next_at = clock_timestamp() + ($2::integer * interval '1 second')
             FROM candidate c WHERE r.did = c.did RETURNING r.did, r.cid
             """,
             [token, delay],
             log: false
           )
         end) do
      {:ok, %{rows: [[did, cid]]}} -> {:ok, %{did: did, cid: cid, token: token}}
      {:ok, %{rows: []}} -> {:ok, nil}
      error -> error
    end
  end

  defp release(did, token) do
    case bounded(fn ->
           Repo.query!(
             "UPDATE plc_registrations SET retry_leased_until = clock_timestamp() WHERE did = $1 AND retry_token = $2",
             [did, token],
             log: false
           )
         end) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :stale_signup_retry}
      error -> error
    end
  end

  @doc "Validate a retry lease inside activation, after event/account locks."
  def assert_current!(did, token) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "signup retry fencing requires a transaction")

    Repo.query!("SELECT did FROM plc_registrations WHERE did = $1 FOR UPDATE", [did], log: false)

    case Repo.query!(
           "SELECT 1 FROM plc_registrations WHERE did = $1 AND retry_token = $2 AND retry_leased_until > clock_timestamp()",
           [did, token],
           log: false
         ) do
      %{num_rows: 1} -> :ok
      _ -> Repo.rollback(:stale_signup_retry)
    end
  end

  defp bounded(fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      fun.()
    end)
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :signup_retry_unavailable}
  end
end
