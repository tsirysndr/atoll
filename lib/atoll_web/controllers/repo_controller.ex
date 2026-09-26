defmodule AtollWeb.RepoController do
  use AtollWeb, :controller
  alias Atoll.{CID, Repositories, Syntax, TID}
  action_fallback AtollWeb.XRPCFallback

  def describe(conn, params) do
    opts = Application.get_env(:atoll, :identity_resolution_options, [])

    with {:ok, description} <- Atoll.Repositories.Description.get(params["repo"], opts) do
      json(conn, description)
    end
  end

  def get_record(conn, params) do
    with :ok <- location(params),
         true <- Syntax.record_key?(params["rkey"]),
         {:ok, requested_cid} <- optional_cid(params["cid"]),
         {:ok, did} <- repository_did(params["repo"]),
         {:ok, record} <- fetch_record(did, params, requested_cid) do
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
         {:ok, did} <- repository_did(params["repo"]),
         {:ok, page} <-
           Repositories.list_records(did, params["collection"],
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
         true <- is_nil(params["since"]) or TID.valid?(params["since"]),
         {:ok, archive} <- Repositories.export(params["did"], params["since"]) do
      conn |> put_resp_content_type("application/vnd.ipld.car", nil) |> send_resp(200, archive)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp location(%{"repo" => did, "collection" => collection}) when is_binary(collection) do
    if (Syntax.did?(did) or Syntax.handle?(did)) and Syntax.repo_path?(collection <> "/self"),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp location(_), do: {:error, :invalid_request}

  defp repository_did(identifier) do
    if Syntax.did?(identifier) do
      {:ok, identifier}
    else
      opts = Application.get_env(:atoll, :identity_resolution_options, [])

      case Atoll.Identity.Handle.verify(identifier, opts) do
        {:ok, identity} -> {:ok, identity.did}
        {:error, :invalid_handle} -> {:error, :invalid_request}
        {:error, _} -> {:error, :unverified_handle}
      end
    end
  end

  defp fetch_record(did, params, cid) do
    case Repositories.get_record(did, params["collection"] <> "/" <> params["rkey"], cid) do
      {:error, :not_found} -> {:error, :record_not_found}
      result -> result
    end
  end

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
