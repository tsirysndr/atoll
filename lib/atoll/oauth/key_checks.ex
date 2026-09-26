defmodule Atoll.OAuth.KeyChecks do
  @moduledoc "Bounded cursor sweep of confidential sessions using fresh public client key sets."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.OAuth.{Session, ClientKeys, PAR}
  alias Atoll.Repositories.Head
  alias Atoll.Accounts.Session, as: AccountSession

  def config_from_env!(env) do
    enabled =
      case Map.get(env, "ATOLL_OAUTH_KEY_CHECKS_ENABLED", "true") do
        "true" -> true
        "false" -> false
        _ -> raise ArgumentError, "ATOLL_OAUTH_KEY_CHECKS_ENABLED must be true or false"
      end

    interval =
      case Integer.parse(Map.get(env, "ATOLL_OAUTH_KEY_CHECKS_INTERVAL_SECONDS", "300")) do
        {n, ""} when n in 30..3600 ->
          n * 1000

        _ ->
          raise ArgumentError, "ATOLL_OAUTH_KEY_CHECKS_INTERVAL_SECONDS must be from 30 to 3600"
      end

    [enabled: enabled, interval_ms: interval]
  end

  def run(cursor \\ nil, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :oauth_key_checks_inside_transaction}
    else
      case batch(cursor) do
        [] ->
          {:ok, :done}

        rows ->
          last = List.last(rows)
          cursor = {last.client_id, last.id}
          if checkpoint = opts[:checkpoint], do: checkpoint.(cursor)
          # Capture the exact session bindings before network IO; a later grant
          # must not be revoked using a key set fetched for an earlier snapshot.
          case ClientKeys.fetch(last.client_id, opts) do
            {:ok, client} ->
              with {:ok, revoked} <- revoke(rows, client.keys) do
                {:ok, %{cursor: cursor, checked: length(rows), revoked: revoked, failed: 0}}
              end

            {:error, _} ->
              {:ok, %{cursor: cursor, checked: 0, revoked: 0, failed: length(rows)}}
          end
      end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_key_checks_store_unavailable}
  end

  defp batch(cursor) do
    query =
      from s in Session,
        where:
          not is_nil(s.client_binding) and
            s.expires_at > fragment("extract(epoch FROM clock_timestamp())"),
        order_by: [asc: s.client_id, asc: s.id]

    query =
      case cursor do
        nil ->
          query

        {client, id} ->
          from s in query, where: s.client_id > ^client or (s.client_id == ^client and s.id > ^id)
      end

    # At most 100 candidates in memory and one client fetch per invocation.
    case Repo.all(from(s in query, limit: 100), log: false, timeout: 5000) do
      [] -> []
      [first | _] = rows -> Enum.take_while(rows, &(&1.client_id == first.client_id))
    end
  end

  defp revoke(rows, keys) do
    missing =
      Enum.filter(rows, fn session ->
        binding = session.client_binding

        case keys[binding["kid"]] do
          nil -> true
          key -> key.alg != binding["alg"] or key.jkt != binding["jkt"]
        end
      end)

    if missing == [] do
      {:ok, 0}
    else
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        dids = Enum.map(missing, & &1.did) |> Enum.uniq() |> Enum.sort()
        sources = Enum.map(missing, & &1.source_session_id) |> Enum.uniq() |> Enum.sort()
        Repo.all(from(h in Head, where: h.did in ^dids, order_by: h.did, lock: "FOR SHARE"))

        Repo.all(
          from(s in AccountSession, where: s.id in ^sources, order_by: s.id, lock: "FOR SHARE"),
          log: false
        )

        PAR.lock!()
        ids = Enum.map(missing, & &1.id)
        originals = Map.new(missing, &{&1.id, &1})

        current =
          Repo.all(from(s in Session, where: s.id in ^ids, order_by: s.id, lock: "FOR UPDATE"),
            log: false
          )

        %{rows: [[now]]} =
          Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

        revoked =
          Enum.filter(current, fn session ->
            session.expires_at > now and
              session_binding(session) == session_binding(originals[session.id])
          end)
          |> Enum.map(& &1.id)

        {count, _} = Repo.delete_all(from(s in Session, where: s.id in ^revoked), log: false)
        count
      end)
    end
  end

  defp session_binding(session),
    do:
      Map.take(session, [
        :id,
        :did,
        :source_session_id,
        :issuer,
        :client_id,
        :client_binding,
        :dpop_jkt
      ])
end
