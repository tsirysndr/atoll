defmodule AtollWeb.RepoController do
  use AtollWeb, :controller
  alias Atoll.{CID, Repositories, Syntax}
  action_fallback AtollWeb.XRPCFallback

  def get_record(conn, params) do
    with :ok <- location(params),
         true <- Syntax.record_key?(params["rkey"]),
         {:ok, requested_cid} <- optional_cid(params["cid"]),
         {:ok, record} <- fetch_record(params),
         :ok <- matches_cid(record.cid, requested_cid) do
      json(conn, public_record(record))
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def list_records(conn, params) do
    with :ok <- location(params),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, reverse} <- reverse(params["reverse"]),
         true <- is_nil(params["cursor"]) or Syntax.record_key?(params["cursor"]),
         {:ok, page} <-
           Repositories.list_records(params["repo"], params["collection"],
             limit: limit,
             reverse: reverse,
             cursor: params["cursor"]
           ) do
      json(
        conn,
        Map.update!(page, :records, &Enum.map(&1, fn record -> public_record(record) end))
      )
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def get_repo(conn, params) do
    with true <- Syntax.did?(params["did"]),
         # Diff exports are not available yet; never silently ignore `since`.
         true <- is_nil(params["since"]),
         {:ok, archive} <- Repositories.export(params["did"]) do
      conn |> put_resp_content_type("application/vnd.ipld.car", nil) |> send_resp(200, archive)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp location(%{"repo" => did, "collection" => collection}) when is_binary(collection) do
    if Syntax.did?(did) and Syntax.repo_path?(collection <> "/self"),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp location(_), do: {:error, :invalid_request}

  defp fetch_record(params) do
    case Repositories.get_record(params["repo"], params["collection"] <> "/" <> params["rkey"]) do
      {:error, :not_found} -> {:error, :record_not_found}
      result -> result
    end
  end

  defp matches_cid(_, nil), do: :ok
  defp matches_cid(cid, cid), do: :ok
  defp matches_cid(_, _), do: {:error, :record_not_found}
  defp optional_cid(nil), do: {:ok, nil}

  defp optional_cid(value) do
    case CID.from_base32(value) do
      {:ok, cid} -> {:ok, cid}
      _ -> {:error, :invalid_request}
    end
  end

  defp limit(nil), do: {:ok, 50}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..100 -> {:ok, n}
      _ -> {:error, :invalid_request}
    end
  end

  defp limit(_), do: {:error, :invalid_request}
  defp reverse(nil), do: {:ok, false}
  defp reverse("true"), do: {:ok, true}
  defp reverse("false"), do: {:ok, false}
  defp reverse(_), do: {:error, :invalid_request}
  defp public_record(record), do: Map.update!(record, :cid, &CID.to_base32/1)
end
