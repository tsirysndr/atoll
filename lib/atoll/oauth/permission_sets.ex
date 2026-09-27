defmodule Atoll.OAuth.PermissionSets do
  @moduledoc """
  Internal, authenticated permission-set resolution with a bounded PostgreSQL cache.
  Network work runs outside transactions. Callers must snapshot returned documents
  with consent and token grants; this cache is not a resource authorization boundary.
  Transport, fetch and clock options are trusted server/test inputs.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Lexicon.{Authority, Fetcher}
  alias Atoll.OAuth.{Permissions, PermissionSet, PermissionSetCache}
  @stale 86_400
  @expire 90 * 86_400
  @backoff 300
  @capacity 1000
  @lock 4_182_026_054

  def resolve(scope, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :permission_set_inside_transaction}
    else
      with {:ok, include} <- Permissions.include(scope),
           {:ok, target} <- Authority.name(include.nsid),
           now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end),
           {:ok, row} <- cached(target.nsid, now, opts),
           {:ok, scopes} <- PermissionSet.expand(row.document, %{include | nsid: target.nsid}) do
        {:ok,
         %{
           scope: scope,
           nsid: target.nsid,
           document: row.document,
           provenance: row.provenance,
           fetched_at: row.fetched_at,
           scopes: scopes
         }}
      end
    end
  rescue
    _ in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :permission_set_store_unavailable}
  end

  defp cached(nsid, now, opts) do
    prior = Repo.get(PermissionSetCache, nsid)

    cond do
      prior && prior.fetched_at <= now && prior.fetched_at + @stale > now ->
        {:ok, prior}

      prior && prior.retry_at > now ->
        fallback(prior, now, opts)

      true ->
        fetch = Keyword.get(opts, :fetch, &Fetcher.fetch/2)

        case fetch.(nsid, opts) do
          {:ok, %{nsid: ^nsid, document: document} = result} ->
            case PermissionSet.validate(document, nsid) do
              {:ok, _} -> persist(prior, nsid, document, result, now)
              {:error, _} -> failed(prior, now, opts)
            end

          _ ->
            failed(prior, now, opts)
        end
    end
  end

  defp fallback(nil, _, _), do: {:error, :permission_set_unavailable}

  defp fallback(row, now, opts) do
    if row.fetched_at <= now and
         (row.fetched_at + @expire > now or opts[:existing_session] == true),
       do: {:ok, row},
       else: {:error, :permission_set_unavailable}
  end

  defp failed(nil, _, _), do: {:error, :permission_set_unavailable}

  defp failed(prior, now, opts) do
    # Failure backoff must not extend the original schema's freshness or expiration.
    Repo.update_all(
      from(r in PermissionSetCache,
        where:
          r.nsid == ^prior.nsid and r.fetched_at == ^prior.fetched_at and
            r.retry_at == ^prior.retry_at
      ),
      set: [retry_at: max(now + @backoff, prior.fetched_at)]
    )

    fallback(Repo.get(PermissionSetCache, prior.nsid), now, opts)
  end

  defp persist(prior, nsid, document, result, now) do
    Repo.transaction(fn ->
      Atoll.Database.limits!(1_000, 5_000)
      Atoll.Database.serialize_writes!(@lock)
      current = Repo.get(PermissionSetCache, nsid)

      if current != prior and current do
        current
      else
        if is_nil(current) do
          Repo.delete_all(from r in PermissionSetCache, where: r.fetched_at <= ^(now - @expire))

          if Repo.aggregate(PermissionSetCache, :count) >= @capacity,
            do: Repo.rollback(:permission_set_cache_full)
        end

        provenance =
          Map.new(Map.take(result, [:did, :uri, :cid, :commit, :rev]), fn {key, value} ->
            {Atom.to_string(key), value}
          end)

        Repo.insert!(
          %PermissionSetCache{
            nsid: nsid,
            document: document,
            provenance: provenance,
            fetched_at: now,
            retry_at: now
          },
          on_conflict: {:replace, [:document, :provenance, :fetched_at, :retry_at]},
          conflict_target: [:nsid]
        )
      end
    end)
  end
end
