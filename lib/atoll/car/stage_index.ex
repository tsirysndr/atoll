defmodule Atoll.CAR.StageIndex do
  @moduledoc "Fixed-memory, disk-backed CID offsets for one private CAR stage."
  defstruct [:io, :slots, :key]
  @entry_bytes 48
  @max_probes 128

  def new(io, max_blocks) when max_blocks in 1..1_000_000 do
    slots = max_blocks * 2

    # Reserve logical space; filesystems supporting sparse files need not allocate
    # untouched slots. Zero CID slots are empty (valid CIDv1 starts with 1).
    with :ok <- :file.pwrite(io, slots * @entry_bytes - 1, <<0>>) do
      {:ok, %__MODULE__{io: io, slots: slots, key: :crypto.strong_rand_bytes(32)}}
    end
  end

  @doc "Finds a CID or an empty insertion slot. Collisions and I/O work are bounded."
  def locate(%__MODULE__{} = index, cid) when is_binary(cid) and byte_size(cid) == 36 do
    <<hash::unsigned-64, _::binary>> = :crypto.mac(:hmac, :sha256, index.key, cid)
    probe(index, cid, rem(hash, index.slots), min(index.slots, @max_probes))
  end

  def locate(_, _), do: {:error, :invalid_index_key}

  def put(index, slot, cid, offset, size) do
    :file.pwrite(
      index.io,
      slot * @entry_bytes,
      <<cid::binary-size(36), offset::unsigned-64, size::unsigned-32>>
    )
  end

  defp probe(_, _, _, 0), do: {:error, :index_probe_limit}

  defp probe(index, cid, slot, left) do
    case :file.pread(index.io, slot * @entry_bytes, @entry_bytes) do
      {:ok, <<0::384>>} ->
        {:empty, slot}

      {:ok, <<^cid::binary-size(36), offset::unsigned-64, size::unsigned-32>>} ->
        {:found, offset, size}

      {:ok, <<1, _::binary-size(47)>>} ->
        probe(index, cid, rem(slot + 1, index.slots), left - 1)

      _ ->
        {:error, :invalid_index_slot}
    end
  end
end
