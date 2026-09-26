defmodule AtollWeb.XRPCProcedurePlug do
  @moduledoc "Checks parsed JSON procedure bodies without reading uploads or changing authentication."
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "POST"} = conn, _) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["xrpc", nsid] ->
        case Atoll.Lexicon.Procedure.validate(nsid, conn.body_params) do
          :ok ->
            conn

          {:error, _} ->
            conn
            |> put_resp_header("cache-control", "no-store")
            |> put_resp_content_type("application/json")
            |> send_resp(
              400,
              Jason.encode!(%{error: "InvalidRequest", message: "Invalid procedure input."})
            )
            |> halt()
        end

      _ ->
        conn
    end
  end

  def call(conn, _), do: conn
end
