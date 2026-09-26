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

  def rate_limit_from_env!(nil), do: 300

  def rate_limit_from_env!(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 0..100_000 ->
        limit

      _ ->
        raise ArgumentError,
              "ATOLL_RECORD_WRITE_RATE_LIMIT must be an integer from 0 to 100000 (0 disables record-write rate limits)"
    end
  end

  @doc false
  def unlimited?("POST", nsid) when nsid in @methods,
    do: Application.get_env(:atoll, :record_write_rate_limit, 300) == 0

  def unlimited?(_, _), do: false

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
         {:ok, token} <- authorize(conn),
         [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.media_type(content_type) do
      conn |> Plug.Parsers.call(@parser) |> put_private(:atoll_record_token, token)
    else
      {:error, {:oauth, reason}} ->
        AtollWeb.OAuthResource.error(conn, reason)

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

  defp authorize(conn) do
    if AtollWeb.OAuthResource.attempt?(conn) do
      case AtollWeb.OAuthResource.prepare_write(conn) do
        {:ok, credential} -> {:ok, credential}
        {:error, reason} -> {:error, {:oauth, reason}}
      end
    else
      with {:ok, token} <- AtollWeb.BearerToken.get(conn),
           {:ok, _} <- Atoll.Accounts.Sessions.authenticate(token),
           do: {:ok, token}
    end
  end

  defp limit(conn) do
    case Application.get_env(:atoll, :record_write_rate_limit, 300) do
      0 ->
        :ok

      limit when is_integer(limit) and limit in 1..100_000 ->
        case Atoll.Accounts.SessionLimiter.check({:record_write, conn.remote_ip}, limit) do
          :ok -> :ok
          {:error, seconds} -> {:error, {:rate_limited, seconds}}
        end

      _ ->
        {:error, :record_rate_limit_configuration}
    end
  end

  defp fail(conn, error), do: conn |> AtollWeb.XRPCFallback.call(error) |> halt()
end
