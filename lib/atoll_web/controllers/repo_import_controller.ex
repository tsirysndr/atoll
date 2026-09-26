defmodule AtollWeb.RepoImportController do
  use AtollWeb, :controller
  action_fallback AtollWeb.XRPCFallback

  def create(%{private: %{atoll_repo_import: upload}} = conn, _params) do
    with {:ok, _} <- Atoll.Accounts.Sessions.authenticate_management(upload.token) do
      source = %{
        conn: conn,
        size: 0,
        expected: upload.length,
        deadline: System.monotonic_time(:millisecond) + 30_000
      }

      result =
        Atoll.CAR.Stage.with_reader(
          source,
          &read_chunk/1,
          fn stage, source ->
            case Atoll.Repositories.import_staged(upload.token, stage, upload.head) do
              {:ok, _} -> {:ok, source.conn}
              {:error, reason} -> {:error, reason, source}
            end
          end,
          max_bytes: 1_073_741_824
        )

      case result do
        {:ok, conn} -> send_resp(conn, 200, "")
        {:error, reason, source} -> fail(source.conn, reason)
        {:error, reason} -> fail(conn, reason)
      end
    end
  end

  def create(_, _), do: {:error, :auth_required}

  defp read_chunk(source) do
    remaining = source.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :request_timeout, source}
    else
      case read_body(source.conn,
             length: 65_536,
             read_length: 65_536,
             read_timeout: min(remaining, 5_000)
           ) do
        {status, bytes, conn} when status in [:ok, :more] ->
          source = %{source | conn: conn, size: source.size + byte_size(bytes)}

          cond do
            source.size > source.expected ->
              {:error, :invalid_request, source}

            status == :ok and source.size != source.expected ->
              {:error, :invalid_request, source}

            status == :more and bytes == "" ->
              {:error, :invalid_request, source}

            System.monotonic_time(:millisecond) > source.deadline ->
              {:error, :request_timeout, source}

            true ->
              {status, bytes, source}
          end

        {:error, :timeout} ->
          {:error, :request_timeout, source}

        {:error, _} ->
          {:error, :invalid_request, source}
      end
    end
  end

  defp fail(conn, reason) when reason in [:invalid_car, :invalid_snapshot],
    do: AtollWeb.XRPCFallback.call(conn, {:error, :invalid_snapshot})

  defp fail(conn, :car_staging_unavailable),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        503,
        Jason.encode!(%{error: "ServiceUnavailable", message: "Import staging is unavailable."})
      )

  defp fail(conn, reason), do: AtollWeb.XRPCFallback.call(conn, {:error, reason})
end
