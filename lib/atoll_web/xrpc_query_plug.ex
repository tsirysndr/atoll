defmodule AtollWeb.XRPCQueryPlug do
  @moduledoc "Validates query parameters after specialized request guards and before routing."
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "GET"} = conn, _) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["xrpc", nsid] ->
        case Atoll.Lexicon.Query.decode(nsid, conn.query_string) do
          {:ok, params} ->
            %{conn | query_params: params, params: params}

          {:error, _} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> put_resp_content_type("application/json")
            |> send_resp(
              400,
              Jason.encode!(%{error: "InvalidRequest", message: "Invalid query parameters."})
            )
            |> halt()
        end

      _ ->
        conn
    end
  end

  def call(conn, _), do: conn
end
