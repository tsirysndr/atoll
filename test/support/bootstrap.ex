defmodule Atoll.Bootstrap do
  @moduledoc "Reads the account shell's JSON payload out of a rendered page."

  @pattern ~r|<script type="application/json" id="atoll-bootstrap">(.*?)</script>|s

  def read(%Plug.Conn{} = conn), do: read(conn.resp_body)

  def read(html) when is_binary(html) do
    case Regex.run(@pattern, html) do
      [_, json] -> Jason.decode!(json)
      _ -> nil
    end
  end

  def screen(page), do: read(page)["screen"]
  def error(page), do: read(page)["error"]
end
