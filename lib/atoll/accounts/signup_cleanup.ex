defmodule Atoll.Accounts.SignupCleanup do
  @moduledoc "Bounded operator cleanup of old signup reservations never submitted by Atoll."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Identity.PLC.Registration
  alias Atoll.Repositories.{Events, Head}

  def config_from_env!(env) do
    enabled =
      case Map.get(env, "ATOLL_SIGNUP_CLEANUP_ENABLED", "false") do
        "true" -> true
        "false" -> false
        _ -> raise ArgumentError, "ATOLL_SIGNUP_CLEANUP_ENABLED must be true or false"
      end

    [
      enabled: enabled,
      days: integer!(env, "ATOLL_SIGNUP_CLEANUP_AGE_DAYS", "7", 1..3650),
      limit: integer!(env, "ATOLL_SIGNUP_CLEANUP_BATCH_SIZE", "100", 1..100),
      interval_ms:
        integer!(env, "ATOLL_SIGNUP_CLEANUP_INTERVAL_SECONDS", "3600", 60..86400) * 1000
    ]
  end

  defp integer!(env, name, default, range) do
    case Integer.parse(Map.get(env, name, default)) do
      {value, ""} ->
        if value in range,
          do: value,
          else: raise(ArgumentError, "#{name} is outside its permitted range")

      _ ->
        raise ArgumentError, "#{name} must be an integer"
    end
  end

  def batch(
        days \\ 7,
        limit \\ 100,
        dry_run \\ true,
        now \\ DateTime.utc_now(),
        actor \\ "operator"
      )

  def batch(days, limit, dry_run, %DateTime{} = now, actor)
      when is_integer(days) and days in 1..3650 and is_integer(limit) and limit in 1..100 and
             is_boolean(dry_run) and actor in ["operator", "system"] do
    cutoff = DateTime.add(now, -days * 86_400, :second)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      Events.lock!()

      rows =
        Repo.all(
          from r in Registration,
            join: h in Head,
            on: h.did == r.did,
            where:
              is_nil(r.submission_started_at) and is_nil(r.confirmed_at) and
                is_nil(r.completed_at) and r.inserted_at <= ^cutoff and h.status == :deactivated,
            order_by: [r.inserted_at, r.did],
            limit: ^(limit + 1),
            select: r
        )

      page = Enum.take(rows, limit)

      unless dry_run do
        for row <- page do
          # Every signup/publication writer holds Events before the account lock.
          Atoll.Moderation.Audit.signup_cleanup!(row, cutoff, actor)

          case Atoll.Accounts.Deletion.admin_delete(%{"did" => row.did}, actor) do
            {:ok, :deleted} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end

      %{
        dry_run: dry_run,
        cutoff: DateTime.to_iso8601(cutoff),
        dids: Enum.map(page, & &1.did),
        selected: length(page),
        deleted: if(dry_run, do: 0, else: length(page)),
        more: length(rows) > limit
      }
    end)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :signup_cleanup_busy},
        else: reraise(error, __STACKTRACE__)
  end

  def batch(_, _, _, _, _), do: {:error, :invalid_cleanup_options}
end
