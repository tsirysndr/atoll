defmodule AtollWeb.SyncController do
  use AtollWeb, :controller
  alias Atoll.{CID, Repositories, Syntax}
  action_fallback AtollWeb.XRPCFallback

  def latest_commit(conn, params) do
    with {:ok, head} <- head(params) do
      json(conn, %{cid: CID.to_base32(head.head), rev: head.rev})
    end
  end

  def repo_status(conn, params) do
    with {:ok, head} <- head(params) do
      # All repositories are active until account lifecycle support is added.
      json(conn, %{did: head.did, active: true, rev: head.rev})
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
