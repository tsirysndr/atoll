defmodule AtollWeb.BoundedBody do
  @moduledoc "Raw body reads with bounded bytes, per-read timeout, and an overall read budget."
  import Plug.Conn

  def read(conn, max_bytes) do
    read(conn, max_bytes, [], 0, System.monotonic_time(:millisecond) + 30_000)
  end

  defp read(conn, max_bytes, chunks, size, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :request_timeout, conn}
    else
      case read_body(conn,
             length: 65_536,
             read_length: 65_536,
             read_timeout: min(remaining, 5_000)
           ) do
        {status, chunk, conn} when status in [:ok, :more] ->
          total = size + byte_size(chunk)

          cond do
            total > max_bytes -> {:error, :request_too_large, conn}
            status == :ok -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
            chunk == "" -> {:error, :invalid_request, conn}
            true -> read(conn, max_bytes, [chunk | chunks], total, deadline)
          end

        {:error, :timeout} ->
          {:error, :request_timeout, conn}

        {:error, _} ->
          {:error, :invalid_request, conn}
      end
    end
  end
end
