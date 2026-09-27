defmodule Atoll.Accounts.Status do
  @moduledoc "Authenticated repository inventory and resolved DID service/key checks."
  import Ecto.Query
  alias Atoll.{CID, Repo}
  alias Atoll.Accounts.Sessions
  alias Atoll.Blobs.{Blob, Reference}
  alias Atoll.Repositories.{BlockReference, Record}
  alias Atoll.Storage.Block

  def get(token) do
    with {:ok, prior} <- Sessions.authenticate_status(token) do
      identity = resolve(prior)

      # Resolve remotely before taking inventory locks, then recheck the live session.
      Repo.transaction(fn ->
        head =
          case Sessions.authenticate_status(token) do
            {:ok, head} -> head
            {:error, reason} -> Repo.rollback(reason)
          end

        inventory(head, identity)
      end)
    end
  end

  @doc "Resolve the authenticated account's current DID without holding inventory locks."
  def resolve(%{did: did}) do
    opts = Application.get_env(:atoll, :identity_resolution_options, [])
    Atoll.Identity.Resolver.resolve(did, Keyword.put(opts, :force_refresh, true))
  end

  @doc "Trusted OAuth read callback; the resource guard holds account and authorization locks."
  def oauth_inventory(%{did: did}, identity) do
    Repo.get!(Atoll.Repositories.Head, did) |> inventory(identity)
  end

  defp inventory(head, identity) do
    block_count =
      Repo.one(
        from b in Block,
          join: r in BlockReference,
          on: r.cid == b.cid and r.did == ^head.did,
          select: count(b.cid)
      )

    %{
      activated: head.status == :active,
      validDid: valid_identity?(identity, head),
      repoCommit: CID.to_base32(head.head),
      repoRev: head.rev,
      repoBlocks: block_count,
      indexedRecords: Repo.aggregate(from(r in Record, where: r.did == ^head.did), :count),
      privateStateValues: 0,
      expectedBlobs:
        Repo.one(from r in Reference, where: r.did == ^head.did, select: count(r.cid, :distinct)),
      importedBlobs: Repo.aggregate(from(b in Blob, where: b.did == ^head.did), :count)
    }
  end

  defp valid_identity?({:ok, identity}, head) do
    identity.signing_key == %{curve: head.curve, public: head.public_key} and
      identity.pds == AtollWeb.Endpoint.url()
  end

  defp valid_identity?(_, _), do: false
end
