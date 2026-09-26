defmodule AtollWeb.SyncController do
  use AtollWeb, :controller
  alias Atoll.{CID, Repositories, Syntax}
  action_fallback AtollWeb.XRPCFallback

  def get_record(conn, params) do
    with true <- Syntax.did?(params["did"]),
         collection when is_binary(collection) <- params["collection"],
         rkey when is_binary(rkey) <- params["rkey"],
         path = collection <> "/" <> rkey,
         true <- Syntax.repo_path?(path),
         {:ok, archive} <- Repositories.export_record(params["did"], path) do
      car(conn, archive)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def get_blocks(conn, params) do
    cids = params["cids"] || []

    with true <- Syntax.did?(params["did"]) and length(cids) in 1..100,
         {:ok, decoded} <- decode_cids(cids),
         {:ok, archive} <- Repositories.export_blocks(params["did"], decoded) do
      car(conn, archive)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp decode_cids(cids) do
    Enum.reduce_while(cids, {:ok, []}, fn value, {:ok, acc} ->
      case CID.from_base32(value) do
        {:ok, cid} -> {:cont, {:ok, [cid | acc]}}
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
  end

  defp car(conn, bytes),
    do: conn |> put_resp_content_type("application/vnd.ipld.car", nil) |> send_resp(200, bytes)

  def latest_commit(conn, params) do
    with {:ok, head} <- head(params), :ok <- Repositories.availability(head) do
      json(conn, %{cid: CID.to_base32(head.head), rev: head.rev})
    end
  end

  def repo_status(conn, params) do
    with {:ok, head} <- head(params) do
      json(conn, Repositories.status_fields(head))
    end
  end

  def list_repos(conn, params) do
    with {:ok, limit} <- limit(params["limit"]),
         true <- is_nil(params["cursor"]) or Syntax.did?(params["cursor"]) do
      json(conn, Repositories.list_heads(limit, params["cursor"]))
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp head(%{"did" => did}) do
    if Syntax.did?(did), do: Repositories.get_head(did), else: {:error, :invalid_request}
  end

  defp head(_), do: {:error, :invalid_request}
  defp limit(nil), do: {:ok, 500}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..1000 -> {:ok, n}
      _ -> {:error, :invalid_request}
    end
  end

  defp limit(_), do: {:error, :invalid_request}
end
