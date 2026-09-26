defmodule AtollWeb.ExportToken do
  @moduledoc false
  import Plug.Conn

  # Carry the credential, never a trusted boolean: storage authorization rechecks it.
  def optional(conn) do
    headers = get_req_header(conn, "authorization")

    if admin_attempt?(headers),
      do: {:ok, {:admin, headers}},
      else: AtollWeb.BearerToken.optional(conn)
  end

  def admin_attempt?(headers) do
    Enum.any?(headers, fn header ->
      is_binary(header) and byte_size(header) >= 6 and
        String.downcase(binary_part(header, 0, 6)) == "basic "
    end)
  end
end
