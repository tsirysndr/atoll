defmodule AtollWeb.RecordWritePlug do
  @moduledoc "Authenticates and bounds record-write requests before general parsing."
  import Plug.Conn

  @methods [
    "com.atproto.repo.createRecord",
    "com.atproto.repo.putRecord",
    "com.atproto.repo.deleteRecord",
    "com.atproto.repo.applyWrites"
  ]
  @parser Plug.Parsers.init(
            parsers: [:json],
            json_decoder: Jason,
            length: 2 * 1024 * 1024,
            read_length: 65_536,
            read_timeout: 5_000
          )

  def init(opts), do: opts

  def call(conn, _opts) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["xrpc", method] when method in @methods ->
        write(put_resp_header(conn, "cache-control", "no-store"))

      _ ->
        conn
    end
  end

  defp write(%{method: "POST"} = conn) do
    with :ok <- limit(conn),
         {:ok, token} <- AtollWeb.BearerToken.get(conn),
         {:ok, _} <- Atoll.Accounts.Sessions.authenticate(token),
         [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.media_type(content_type) do
      conn |> Plug.Parsers.call(@parser) |> put_private(:atoll_record_token, token)
    else
      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> fail({:error, :record_rate_limited})

      {:error, _} = error ->
        fail(conn, error)

      _ ->
        fail(conn, {:error, :invalid_request})
    end
  rescue
    Plug.Parsers.RequestTooLargeError -> fail(conn, {:error, :record_request_too_large})
    Plug.Parsers.ParseError -> fail(conn, {:error, :invalid_request})
  end

  defp write(conn) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_resp_content_type("application/json")
    |> send_resp(
      405,
      Jason.encode!(%{error: "MethodNotAllowed", message: "Use POST to write records."})
    )
    |> halt()
  end

  defp limit(conn) do
    case Atoll.Accounts.SessionLimiter.check({:record_write, conn.remote_ip}, 300) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  defp fail(conn, error), do: conn |> AtollWeb.XRPCFallback.call(error) |> halt()
end
