defmodule Atoll.Lexicon.Fetcher do
  @moduledoc """
  Retrieves a schema from the HTTPS PDS identified by fresh namespace/DID resolution.
  Verifies record URI and content CID, but does not verify a signed repository proof.
  Does not install schemas or resolve their dependencies.
  """
  alias Atoll.{CBOR, CID, DataModel}
  alias Atoll.Identity.Resolver
  alias Atoll.Lexicon.Authority

  def fetch(nsid, opts \\ []) do
    with {:ok, target} <- Authority.resolve(nsid, opts),
         {:ok, body} <- Resolver.fetch_lexicon(target.identity.pds, target.did, target.nsid, opts),
         {:ok, record} <- decode(body),
         :ok <- verify(record, target) do
      {:ok,
       %{
         nsid: target.nsid,
         did: target.did,
         uri: target.uri,
         cid: record["cid"],
         document: record["value"]
       }}
    end
  end

  defp decode(body) do
    with {:ok, object} <- Jason.decode(body, objects: :ordered_objects) do
      {:ok, unique!(object, 0)}
    else
      _ -> {:error, :invalid_lexicon_record}
    end
  rescue
    ArgumentError -> {:error, :invalid_lexicon_record}
  end

  defp unique!(_, depth) when depth > 64, do: raise(ArgumentError)

  defp unique!(%Jason.OrderedObject{values: pairs}, depth) do
    Enum.reduce(pairs, %{}, fn {key, value}, acc ->
      if Map.has_key?(acc, key), do: raise(ArgumentError)
      Map.put(acc, key, unique!(value, depth + 1))
    end)
  end

  defp unique!(values, depth) when is_list(values), do: Enum.map(values, &unique!(&1, depth + 1))
  defp unique!(value, _), do: value

  defp verify(%{"uri" => uri, "cid" => cid, "value" => document}, target) do
    with true <- uri == target.uri,
         %{"$type" => "com.atproto.lexicon.schema", "lexicon" => 1, "id" => id, "defs" => defs} <-
           document,
         true <- id == target.nsid and is_map(defs) and map_size(defs) > 0,
         true <-
           Enum.all?(defs, fn {name, definition} ->
             is_binary(name) and name != "" and not String.contains?(name, "#") and
               is_map(definition) and is_binary(definition["type"])
           end),
         {:ok, binary_cid} <- CID.from_base32(cid),
         {:ok, %{codec: :dag_cbor}} <- CID.decode(binary_cid),
         {:ok, value} <- DataModel.from_json(document),
         :ok <- CID.verify(binary_cid, CBOR.encode!(value)) do
      :ok
    else
      _ -> {:error, :invalid_lexicon_record}
    end
  end

  defp verify(_, _), do: {:error, :invalid_lexicon_record}
end
