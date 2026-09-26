defmodule Atoll.Commit do
  @moduledoc """
  Signs and verifies version-3 repository commits.

  Verification uses the caller's expected DID and trusted public key. Identity
  resolution, freshness, revision ordering, and MST validation belong to the
  repository layer and are not implied by a valid signature.
  """
  alias Atoll.{CBOR, CID, SigningKey, Syntax, TID}
  alias Atoll.CBOR.{Bytes, Link}

  def create(did, root, rev, key) do
    unsigned = %{
      "did" => did,
      "version" => 3,
      "data" => %Link{cid: root},
      "rev" => rev,
      "prev" => nil
    }

    with true <- valid_unsigned?(unsigned),
         {:ok, signature} <- SigningKey.sign(key, CBOR.encode!(unsigned)) do
      bytes = unsigned |> Map.put("sig", %Bytes{data: signature}) |> CBOR.encode!()
      {:ok, %{cid: CID.create(bytes, :dag_cbor), bytes: bytes}}
    else
      _ -> {:error, :invalid_commit}
    end
  end

  def verify(bytes, expected_did, curve, public)
      when is_binary(bytes) and byte_size(bytes) <= 4096 do
    with {:ok, %{"did" => ^expected_did, "sig" => %Bytes{data: signature}} = signed} <-
           CBOR.decode(bytes),
         true <- map_size(signed) == 6,
         unsigned = Map.delete(signed, "sig"),
         true <- valid_unsigned?(unsigned),
         true <- SigningKey.verify(curve, public, CBOR.encode!(unsigned), signature) do
      {:ok, signed}
    else
      _ -> {:error, :invalid_commit}
    end
  end

  def verify(_, _, _, _), do: {:error, :invalid_commit}

  defp valid_unsigned?(%{
         "did" => did,
         "version" => 3,
         "data" => root,
         "rev" => rev,
         "prev" => prev
       }) do
    Syntax.did?(did) and TID.valid?(rev) and dag_link?(root) and (is_nil(prev) or dag_link?(prev))
  end

  defp valid_unsigned?(_), do: false

  defp dag_link?(%Link{cid: cid}) when is_binary(cid),
    do: match?({:ok, %{codec: :dag_cbor}}, CID.decode(cid))

  defp dag_link?(_), do: false
end
