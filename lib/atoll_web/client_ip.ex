defmodule AtollWeb.ClientIP do
  @moduledoc "Client addresses from bounded X-Forwarded-For chains sent by explicitly trusted proxies."
  @behaviour Plug
  import Plug.Conn
  import Bitwise

  def init(opts), do: opts

  def parse_trusted_proxies!(nil), do: []
  def parse_trusted_proxies!(""), do: []

  def parse_trusted_proxies!(value) when is_binary(value) and byte_size(value) <= 8192 do
    entries = String.split(value, ",")
    if length(entries) > 128, do: invalid!()
    Enum.map(entries, &(String.trim(&1) |> cidr!())) |> Enum.uniq()
  end

  def parse_trusted_proxies!(_), do: invalid!()

  def call(conn, opts) do
    ranges =
      Keyword.get(opts, :trusted_proxies, Application.get_env(:atoll, :trusted_proxies, []))

    peer = normalize(conn.remote_ip)
    conn = put_private(conn, :atoll_peer_ip, conn.remote_ip)

    client =
      if trusted?(peer, ranges) do
        case addresses(get_req_header(conn, "x-forwarded-for")) do
          {:ok, chain} -> walk(Enum.reverse(chain), peer, ranges)
          :error -> peer
        end
      else
        peer
      end

    %{conn | remote_ip: client}
  end

  defp walk([], current, _), do: current

  defp walk([next | rest], current, ranges) do
    if trusted?(current, ranges), do: walk(rest, next, ranges), else: current
  end

  defp addresses([value]) when byte_size(value) <= 2048 do
    if String.valid?(value) do
      parts = String.split(value, ",")

      if length(parts) in 1..32 do
        Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
          case address(String.trim(part)) do
            {:ok, ip} -> {:cont, {:ok, acc ++ [normalize(ip)]}}
            _ -> {:halt, :error}
          end
        end)
      else
        :error
      end
    else
      :error
    end
  end

  defp addresses(_), do: :error

  defp address(value) do
    if value != "" and Regex.match?(~r/\A[0-9a-fA-F:.]+\z/, value),
      do: :inet.parse_strict_address(String.to_charlist(value)),
      else: :error
  end

  defp cidr!(value) do
    {host, prefix} =
      case String.split(value, "/") do
        [host] -> {host, nil}
        [host, prefix] -> {host, prefix}
        _ -> invalid!()
      end

    case address(host) do
      {:ok, ip} ->
        width = if tuple_size(ip) == 4, do: 32, else: 128

        bits =
          case prefix do
            nil ->
              width

            text ->
              if Regex.match?(~r/\A[0-9]+\z/, text) do
                {bits, ""} = Integer.parse(text)
                if bits <= width, do: bits, else: invalid!()
              else
                invalid!()
              end
          end

        normalized = normalize(ip)

        {width, bits} =
          if normalized != ip do
            if bits < 96, do: invalid!()
            {32, bits - 96}
          else
            {width, bits}
          end

        mask = if bits == 0, do: 0, else: ((1 <<< bits) - 1) <<< (width - bits)
        {width, integer(normalized) &&& mask, mask}

      _ ->
        invalid!()
    end
  end

  defp trusted?(ip, ranges) do
    width = if tuple_size(ip) == 4, do: 32, else: 128
    number = integer(ip)

    Enum.any?(ranges, fn {size, network, mask} ->
      size == width and (number &&& mask) == network
    end)
  end

  defp integer(ip) do
    shift = if tuple_size(ip) == 4, do: 8, else: 16
    ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< shift) + part end)
  end

  defp normalize({0, 0, 0, 0, 0, 65535, high, low}),
    do: {high >>> 8, high &&& 255, low >>> 8, low &&& 255}

  defp normalize(ip), do: ip

  defp invalid!,
    do:
      raise(
        ArgumentError,
        "ATOLL_TRUSTED_PROXY_CIDRS must be up to 128 comma-separated IP addresses or CIDRs"
      )
end
