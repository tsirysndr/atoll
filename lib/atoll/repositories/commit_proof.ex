defmodule Atoll.Repositories.CommitProof do
  @moduledoc "Constructs an inductive commit proof by reversing checked operations over the new MST."
  alias Atoll.{CBOR, CID, MST, Syntax}
  alias Atoll.CBOR.Link

  def build(root, previous, ops, reader) when is_list(ops) and length(ops) <= 200 do
    with {:ok, expected_root} <- previous_root(previous),
         {:ok, inverse} <- inverse(ops),
         {:ok, result} <- MST.Editor.apply(root, inverse, reader),
         true <- result.root == expected_root,
         true <- Enum.all?(ops, &matches?(root, &1, result.fetched)) do
      {:ok, result.fetched}
    else
      {:error, :mst_edit_too_large} -> {:error, :car_too_large}
      _ -> {:error, :invalid_event_blocks}
    end
  end

  def build(_, _, _, _), do: {:error, :invalid_event_blocks}

  defp inverse(ops) do
    Enum.reduce_while(ops, {:ok, [], MapSet.new()}, fn op, {:ok, acc, paths} ->
      with %{"path" => path} <- op,
           true <- Syntax.repo_path?(path) and not MapSet.member?(paths, path),
           {:ok, edit} <- invert(op) do
        {:cont, {:ok, [edit | acc], MapSet.put(paths, path)}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, edits, _} -> {:ok, edits}
      _ -> {:error, :invalid_event_blocks}
    end
  end

  defp invert(%{"action" => "create", "path" => path, "cid" => %Link{cid: cid}} = op) do
    if is_nil(op["prev"]) and MST.Node.dag?(cid), do: {:ok, {:delete, path}}, else: :error
  end

  defp invert(%{
         "action" => "update",
         "path" => path,
         "cid" => %Link{cid: cid},
         "prev" => %Link{cid: prev}
       }) do
    if MST.Node.dag?(cid) and MST.Node.dag?(prev), do: {:ok, {:put, path, prev}}, else: :error
  end

  defp invert(%{"action" => "delete", "path" => path, "cid" => nil, "prev" => %Link{cid: prev}}) do
    if MST.Node.dag?(prev), do: {:ok, {:put, path, prev}}, else: :error
  end

  defp invert(_), do: :error

  defp matches?(root, op, blocks) do
    expected =
      case op["cid"] do
        nil -> nil
        %Link{cid: cid} -> cid
      end

    case MST.Proof.fetch(root, op["path"], &Map.fetch(blocks, &1), max_bytes: 16 * 1024 * 1024) do
      {:ok, proof} -> proof.cid == expected
      _ -> false
    end
  end

  defp previous_root(nil),
    do: {:ok, CID.create(CBOR.encode!(%{"l" => nil, "e" => []}), :dag_cbor)}

  defp previous_root(%Link{cid: cid}) do
    if MST.Node.dag?(cid), do: {:ok, cid}, else: :error
  end

  defp previous_root(_), do: :error
end
