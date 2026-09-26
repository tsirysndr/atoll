defmodule AtollWeb.BearerToken do
  @moduledoc false
  import Plug.Conn

  def optional(conn) do
    if get_req_header(conn, "authorization") == [], do: {:ok, nil}, else: get(conn)
  end

  def get(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:error, :auth_required}

      [value] when byte_size(value) <= 8200 ->
        case Regex.run(~r/\ABearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\z/i, value) do
          [_, token] -> {:ok, token}
          _ -> {:error, :invalid_token}
        end

      _ ->
        {:error, :invalid_token}
    end
  end
end
