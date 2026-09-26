defmodule Atoll.Repositories.EventDependencies do
  @moduledoc "Commit and predecessor revision pins for retained immutable replay events."
  import Ecto.Query
  alias Atoll.{CBOR, Repo}
  alias Atoll.Repositories.{Event, EventDependency}

  def rows(seq, did, kind, payload) when kind in [:commit, :sync, "commit", "sync"] do
    %CBOR.Link{cid: commit} = payload["commit"]
    previous = if kind in [:commit, "commit"], do: payload["previousCommit"]

    heads =
      case previous do
        nil -> [commit]
        %CBOR.Link{cid: cid} -> [commit, cid]
      end

    Enum.map(Enum.uniq(heads), &%{seq: seq, did: did, head: &1})
  end

  def rows(_, _, _, _), do: []

  def track!(event, payload) do
    Repo.insert_all(EventDependency, rows(event.seq, event.did, event.kind, payload),
      on_conflict: :nothing
    )

    event
  end

  def backfill!(did, limit \\ 1000) do
    events = Repo.all(from e in missing(did), order_by: e.seq, limit: ^limit)

    for event <- events do
      {:ok, payload} = CBOR.decode(event.payload)
      track!(event, payload)
    end

    %{indexed: length(events), incomplete: Repo.exists?(missing(did))}
  end

  defp missing(did) do
    from e in Event,
      where: e.did == ^did and e.kind in [:commit, :sync],
      left_join: d in EventDependency,
      on: d.seq == e.seq,
      where: is_nil(d.seq),
      select: e
  end
end
