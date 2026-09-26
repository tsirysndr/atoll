defmodule Atoll.OAuth.SessionManagement do
  @moduledoc """
  Owner-authenticated OAuth session inventory and revocation for the account UI.
  Requires a live full-account access JWT; OAuth and app-password tokens cannot
  manage grants. Client IDs are returned as data without metadata retrieval.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.Sessions
  alias Atoll.Accounts.Session, as: AccountSession
  alias Atoll.OAuth.{Session, PKCE, PAR}

  def list(token, limit \\ 50, cursor \\ nil, opts \\ [])

  def list(token, limit, cursor, opts) when is_integer(limit) and limit in 1..100 do
    if is_nil(cursor) or PKCE.challenge?(cursor) do
      authorized(token, opts, fn head ->
        now = clock!()

        query =
          from s in Session,
            join: source in AccountSession,
            on: source.id == s.source_session_id and source.did == s.did,
            where:
              s.did == ^head.did and s.expires_at > ^now and source.expires_at > ^now and
                source.access_scope == "com.atproto.access",
            order_by: s.id,
            limit: ^(limit + 1),
            select: %{
              id: s.id,
              clientId: s.client_id,
              scope: s.scope,
              expiresAt: s.expires_at,
              refreshable: not is_nil(s.refresh_digest)
            }

        query = if cursor, do: from(s in query, where: s.id > ^cursor), else: query
        rows = Repo.all(query, log: false)
        page = Enum.take(rows, limit)
        result = %{sessions: page}

        if length(rows) > limit,
          do: Map.put(result, :cursor, List.last(page).id),
          else: result
      end)
    else
      {:error, :invalid_request}
    end
  end

  def list(_, _, _, _), do: {:error, :invalid_request}

  @doc "Revoke one owned grant and its tokens; absent and foreign IDs are idempotent no-ops."
  def revoke(token, id, opts \\ []) do
    if PKCE.challenge?(id) do
      authorized(token, opts, fn head ->
        # Match token exchange/refresh/key-check ordering before deleting a grant.
        PAR.lock!()

        case Repo.one(
               from(s in Session,
                 where: s.id == ^id and s.did == ^head.did,
                 lock: "FOR UPDATE"
               ),
               log: false
             ) do
          nil ->
            :ok

          session ->
            Repo.delete!(session, log: false)
            :ok
        end
      end)
    else
      {:error, :invalid_request}
    end
  end

  defp authorized(token, opts, action) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")

      case Sessions.authenticate_management(token, opts) do
        {:ok, head} -> action.(head)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_session_store_unavailable}
  end

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end
end
