defmodule AtollWeb.BlobController do
  use AtollWeb, :controller
  alias Atoll.{Blobs, CID, Syntax, TID}
  action_fallback AtollWeb.XRPCFallback

  def upload(%{private: %{atoll_blob_upload: upload}} = conn, _params) do
    with {:ok, blob} <- Blobs.stage_authenticated(upload.token, upload.bytes, upload.mime) do
      json(conn, %{blob: blob})
    end
  end

  def upload(_conn, _params), do: {:error, :auth_required}

  def get_blob(conn, params) do
    with true <- Syntax.did?(params["did"]),
         {:ok, cid} <- raw_cid(params["cid"]),
         {:ok, %{blob: blob, bytes: bytes}} <- Blobs.get_public(params["did"], cid) do
      conn
      |> put_resp_content_type(blob["mimeType"], nil)
      |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, bytes)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def list_blobs(conn, params) do
    with true <- Syntax.did?(params["did"]),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, cursor} <- cursor(params["cursor"]),
         true <- is_nil(params["since"]) or TID.valid?(params["since"]),
         {:ok, result} <- Blobs.list_public(params["did"], limit, cursor, params["since"]) do
      json(conn, result)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp raw_cid(value) do
    with {:ok, cid} <- CID.from_base32(value), {:ok, %{codec: :raw}} <- CID.decode(cid) do
      {:ok, cid}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp cursor(nil), do: {:ok, nil}
  defp cursor(value), do: raw_cid(value)
  defp limit(nil), do: {:ok, 500}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..1000 -> {:ok, n}
      _ -> {:error, :invalid_request}
    end
  end

  defp limit(_), do: {:error, :invalid_request}
end
