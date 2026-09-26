defmodule Atoll.Repositories.EventEncoder do
  @moduledoc """
  Encodes internal outbox events as subscribeRepos messages and CBOR frames.

  Reads immutable historical blocks, never the current repository head. Commit
  CARs include the complete MST plus created/updated records, allowing operation
  inversion even for deletions and empty commits. Compact inductive proofs remain
  future work. Oversized commits become commit-only sync messages. This is an
  internal encoder; public delivery must enforce repository availability.
  """
  alias Atoll.{CAR, CBOR, CID, Storage}
  alias Atoll.CBOR.{Bytes, Link}

  @max_car 2_000_000

  @doc "Two concatenated CBOR objects: stream header followed by message body."
  def encode(event) do
    with {:ok, type, body} <- message(event) do
      {:ok, CBOR.encode!(%{"op" => 1, "t" => type}) <> CBOR.encode!(body)}
    end
  end

  def error(name, message) when is_binary(name) and is_binary(message) do
    CBOR.encode!(%{"op" => -1}) <>
      CBOR.encode!(%{"error" => name, "message" => message})
  end

  @doc "Builds a protocol message from a decoded durable event."
  def message(%{kind: :account, payload: payload} = event) do
    body = Map.merge(base(event), %{"did" => event.did, "active" => payload["active"]})
    body = if payload["active"], do: body, else: Map.put(body, "status", payload["status"])
    {:ok, "#account", body}
  end

  def message(%{kind: kind, payload: payload} = event) when kind in [:commit, :sync] do
    with %Link{cid: cid} <- payload["commit"],
         {:ok, bytes} <- block(cid),
         {:ok, %{"did" => did, "rev" => rev, "data" => %Link{}} = commit} <- CBOR.decode(bytes),
         true <- did == event.did and rev == payload["rev"] do
      if kind == :sync do
        sync(event, cid, bytes)
      else
        commit_message(event, cid, bytes, commit)
      end
    else
      _ -> {:error, :invalid_event_blocks}
    end
  end

  defp commit_message(event, cid, bytes, commit) do
    with {:ok, previous} <- previous_root(event.payload["previousCommit"]),
         {:ok, blocks, size} <- tree_blocks(commit["data"].cid, %{cid => bytes}, byte_size(bytes)),
         {:ok, blocks, _} <- record_blocks(event.payload["ops"], blocks, size),
         {:ok, car} <- CAR.encode([cid], blocks),
         true <- byte_size(car) <= @max_car do
      ops =
        Enum.map(event.payload["ops"], fn op ->
          if is_nil(op["prev"]), do: Map.delete(op, "prev"), else: op
        end)

      body =
        Map.merge(base(event), %{
          "repo" => event.did,
          "commit" => %Link{cid: cid},
          "rev" => event.payload["rev"],
          "since" => event.payload["since"],
          "rebase" => false,
          "tooBig" => false,
          "blocks" => %Bytes{data: car},
          "ops" => ops,
          "blobs" => []
        })

      body = if previous, do: Map.put(body, "prevData", previous), else: body
      {:ok, "#commit", body}
    else
      false -> sync(event, cid, bytes)
      {:error, :car_too_large} -> sync(event, cid, bytes)
      {:error, _} = error -> error
    end
  end

  defp sync(event, cid, bytes) do
    with {:ok, car} <- CAR.encode([cid], %{cid => bytes}),
         true <- byte_size(car) <= 10_000 do
      {:ok, "#sync",
       Map.merge(base(event), %{
         "did" => event.did,
         "rev" => event.payload["rev"],
         "blocks" => %Bytes{data: car}
       })}
    else
      _ -> {:error, :invalid_event_blocks}
    end
  end

  defp base(event), do: %{"seq" => event.seq, "time" => DateTime.to_iso8601(event.time)}

  defp previous_root(nil), do: {:ok, nil}

  defp previous_root(%Link{cid: cid}) do
    with {:ok, %{"data" => %Link{} = root}} <- Storage.get_node(cid) do
      {:ok, root}
    else
      _ -> {:error, :invalid_event_blocks}
    end
  end

  defp tree_blocks(cid, blocks, size) do
    if Map.has_key?(blocks, cid) do
      {:ok, blocks, size}
    else
      with {:ok, bytes} <- block(cid),
           {:ok, blocks, size} <- add_block(cid, bytes, blocks, size),
           {:ok, %{"l" => left, "e" => entries}} <- CBOR.decode(bytes) do
        children = [left | Enum.map(entries, & &1["t"])]

        Enum.reduce_while(children, {:ok, blocks, size}, fn
          nil, acc ->
            {:cont, acc}

          %Link{cid: child}, {:ok, acc, total} ->
            case tree_blocks(child, acc, total) do
              {:ok, _, _} = result -> {:cont, result}
              error -> {:halt, error}
            end
        end)
      else
        {:error, :car_too_large} = error -> error
        _ -> {:error, :invalid_event_blocks}
      end
    end
  end

  defp record_blocks(ops, blocks, size) do
    Enum.reduce_while(ops, {:ok, blocks, size}, fn op, {:ok, acc, total} ->
      case op["cid"] do
        nil ->
          {:cont, {:ok, acc, total}}

        %Link{cid: cid} ->
          with {:ok, bytes} <- block(cid),
               {:ok, _, _} = result <- add_block(cid, bytes, acc, total) do
            {:cont, result}
          else
            error -> {:halt, error}
          end
      end
    end)
  end

  defp add_block(cid, bytes, blocks, size) do
    total = if Map.has_key?(blocks, cid), do: size, else: size + byte_size(bytes) + 40

    if total > @max_car,
      do: {:error, :car_too_large},
      else: {:ok, Map.put(blocks, cid, bytes), total}
  end

  defp block(cid) do
    with {:ok, bytes} <- Storage.get_block(cid), :ok <- CID.verify(cid, bytes) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_event_blocks}
    end
  end
end
