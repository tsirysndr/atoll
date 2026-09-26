defmodule AtollWeb.RepoImportPlug do
  @moduledoc "Authenticated, bounded CAR request ingestion before general parsing."
  import Plug.Conn
  alias Atoll.Accounts.{SessionLimiter, Sessions}
  @max_bytes 1024 * 1024 * 1024

  def init(opts), do: opts

  def call(conn, _opts) do
    if Enum.map(conn.path_info, &URI.decode/1) == ["xrpc", "com.atproto.repo.importRepo"],
      do: import_repo(put_resp_header(conn, "cache-control", "no-store")),
      else: conn
  end

  defp import_repo(%{method: "POST"} = conn) do
    with :ok <- limit(conn),
         {:ok, token} <- AtollWeb.BearerToken.get(conn),
         {:ok, head} <- Sessions.authenticate_management(token),
         :ok <- media_type(conn),
         {:ok, length} <- content_length(conn) do
      conn = %{conn | body_params: %{}}
      put_private(conn, :atoll_repo_import, %{token: token, length: length, head: head.head})
    else
      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> fail({:error, :import_rate_limited})

      error ->
        fail(conn, error)
    end
  end

  defp import_repo(conn) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_resp_content_type("application/json")
    |> send_resp(
      405,
      Jason.encode!(%{error: "MethodNotAllowed", message: "Use POST to import a repository."})
    )
    |> halt()
  end

  defp media_type(conn) do
    if get_req_header(conn, "content-type") == ["application/vnd.ipld.car"] and
         get_req_header(conn, "content-encoding") in [[], ["identity"]],
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp content_length(conn) do
    case get_req_header(conn, "content-length") do
      [value] when byte_size(value) in 1..20 ->
        if Regex.match?(~r/\A[0-9]+\z/, value) do
          length = String.to_integer(value)
          if length <= @max_bytes, do: {:ok, length}, else: {:error, :request_too_large}
        else
          {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp limit(conn) do
    case SessionLimiter.check({:repo_import, conn.remote_ip}, 10) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  defp fail(conn, {:error, :request_too_large}), do: fail(conn, {:error, :car_too_large})
  defp fail(conn, error), do: conn |> AtollWeb.XRPCFallback.call(error) |> halt()
end
