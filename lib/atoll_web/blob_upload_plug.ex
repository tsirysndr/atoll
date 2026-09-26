defmodule AtollWeb.BlobUploadPlug do
  @moduledoc "Authenticated, bounded raw-body reads before Phoenix's general parsers."
  import Plug.Conn
  alias Atoll.Accounts.{SessionLimiter, Sessions}
  @max_bytes 5 * 1024 * 1024

  def init(opts), do: opts

  def call(conn, _opts) do
    if Enum.map(conn.path_info, &URI.decode/1) == ["xrpc", "com.atproto.repo.uploadBlob"] do
      upload(conn |> put_resp_header("cache-control", "no-store"))
    else
      conn
    end
  end

  defp upload(%{method: "POST"} = conn) do
    with :ok <- limit(conn),
         {:ok, token} <- AtollWeb.BearerToken.get(conn),
         {:ok, _} <- Sessions.authenticate(token),
         :ok <- encoding(conn),
         {:ok, mime} <- mime(conn),
         {:ok, length} <- content_length(conn),
         {:ok, bytes, conn} <- read(conn, [], 0, System.monotonic_time(:millisecond) + 30_000) do
      if is_nil(length) or length == byte_size(bytes) do
        conn = %{conn | body_params: %{}}
        put_private(conn, :atoll_blob_upload, %{token: token, bytes: bytes, mime: mime})
      else
        fail(conn, {:error, :content_length_mismatch})
      end
    else
      {:error, reason, conn} ->
        fail(conn, {:error, reason})

      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> fail({:error, :upload_rate_limited})

      error ->
        fail(conn, error)
    end
  end

  defp upload(conn) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_resp_content_type("application/json")
    |> send_resp(
      405,
      Jason.encode!(%{error: "MethodNotAllowed", message: "Use POST to upload a blob."})
    )
    |> halt()
  end

  defp limit(conn) do
    case SessionLimiter.check({:blob_upload, conn.remote_ip}, 60) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  defp encoding(conn) do
    if get_req_header(conn, "content-encoding") in [[], ["identity"]],
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp mime(conn) do
    case get_req_header(conn, "content-type") do
      [] -> {:ok, "application/octet-stream"}
      [mime] -> Atoll.Blobs.normalize_mime(mime)
      _ -> {:error, :invalid_mime_type}
    end
  end

  defp content_length(conn) do
    case get_req_header(conn, "content-length") do
      [] ->
        {:ok, nil}

      [value] when byte_size(value) in 1..20 ->
        if Regex.match?(~r/\A[0-9]+\z/, value) do
          length = String.to_integer(value)
          if length <= @max_bytes, do: {:ok, length}, else: {:error, :blob_too_large}
        else
          {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp read(conn, chunks, size, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :upload_timeout, conn}
    else
      case read_body(conn,
             length: 65_536,
             read_length: 65_536,
             read_timeout: min(remaining, 5_000)
           ) do
        {status, chunk, conn} when status in [:ok, :more] ->
          total = size + byte_size(chunk)

          cond do
            total > @max_bytes -> {:error, :blob_too_large, conn}
            status == :ok -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
            chunk == "" -> {:error, :invalid_request, conn}
            true -> read(conn, [chunk | chunks], total, deadline)
          end

        {:error, :timeout} ->
          {:error, :upload_timeout, conn}

        {:error, _} ->
          {:error, :invalid_request, conn}
      end
    end
  end

  defp fail(conn, error), do: conn |> AtollWeb.XRPCFallback.call(error) |> halt()
end
