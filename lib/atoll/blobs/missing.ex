defmodule Atoll.Blobs.Missing do
  @moduledoc "Account-scoped inventory of referenced blobs without matching local ownership."
  import Ecto.Query
  alias Atoll.{CID, Repo}
  alias Atoll.Accounts.Sessions
  alias Atoll.Blobs.{Blob, Reference, Takedown}

  def list(token, limit, cursor) when limit in 1..1000 do
    Repo.transaction(fn ->
      # The nested authentication retains head/session share locks through the query.
      did =
        case Sessions.authenticate_management(token) do
          {:ok, %{did: did}} -> did
          {:error, reason} -> Repo.rollback(reason)
        end

      query =
        from r in Reference,
          left_join: b in Blob,
          on:
            b.did == r.did and b.cid == r.cid and b.mime_type == r.mime_type and
              b.size == r.size,
          left_join: t in Takedown,
          on: t.did == r.did and t.cid == r.cid,
          where: r.did == ^did and is_nil(b.cid) and is_nil(t.cid),
          group_by: r.cid,
          order_by: r.cid,
          select: {r.cid, min(r.path)},
          limit: ^(limit + 1)

      query = if cursor, do: from(r in query, where: r.cid > ^cursor), else: query
      rows = Repo.all(query)
      page = Enum.take(rows, limit)

      result = %{
        blobs:
          Enum.map(page, fn {cid, path} ->
            %{cid: CID.to_base32(cid), recordUri: "at://" <> did <> "/" <> path}
          end)
      }

      if length(rows) > limit,
        do: Map.put(result, :cursor, page |> List.last() |> elem(0) |> CID.to_base32()),
        else: result
    end)
  end
end
