defmodule Atoll.Accounts.WebAuthn.CBOR do
  @moduledoc false
  # WebAuthn/COSE needs integer map keys, unlike DAG-CBOR. Keep this decoder
  # separate from repository encoding rules. Only definite-length values needed
  # by authenticator data are supported, with bounded bytes, depth and nodes.
  alias Atoll.CBOR.Bytes

  def decode(bytes) do
    with {:ok, value, <<>>} <- prefix(bytes), do: {:ok, value}, else: (_ -> invalid())
  end

  def prefix(bytes) when is_binary(bytes) and byte_size(bytes) <= 16_384 do
    with {:ok, value, rest, _budget} <- value(bytes, 0, 256),
         do: {:ok, value, rest}
  end

  def prefix(_), do: invalid()

  defp value(_, depth, budget) when depth > 8 or budget <= 0, do: invalid()
  defp value(<<0xF4, rest::binary>>, _, budget), do: {:ok, false, rest, budget - 1}
  defp value(<<0xF5, rest::binary>>, _, budget), do: {:ok, true, rest, budget - 1}
  defp value(<<0xF6, rest::binary>>, _, budget), do: {:ok, nil, rest, budget - 1}

  defp value(<<major::3, info::5, rest::binary>>, depth, budget) when major <= 5 do
    with {:ok, count, rest} <- argument(info, rest) do
      item(major, count, rest, depth, budget - 1)
    end
  end

  defp value(_, _, _), do: invalid()

  defp item(0, number, rest, _, budget), do: {:ok, number, rest, budget}
  defp item(1, number, rest, _, budget), do: {:ok, -1 - number, rest, budget}

  defp item(major, size, rest, _, budget) when major in [2, 3] and size <= byte_size(rest) do
    <<data::binary-size(size), rest::binary>> = rest

    cond do
      major == 2 -> {:ok, %Bytes{data: data}, rest, budget}
      String.valid?(data) -> {:ok, data, rest, budget}
      true -> invalid()
    end
  end

  defp item(4, count, rest, depth, budget) when count <= budget,
    do: array(rest, count, depth + 1, budget, [])

  defp item(5, count, rest, depth, budget) when count * 2 <= budget,
    do: map(rest, count, depth + 1, budget, %{})

  defp item(_, _, _, _, _), do: invalid()

  defp array(rest, 0, _, budget, values), do: {:ok, Enum.reverse(values), rest, budget}

  defp array(bytes, count, depth, budget, values) do
    with {:ok, next, rest, budget} <- value(bytes, depth, budget),
         do: array(rest, count - 1, depth, budget, [next | values])
  end

  defp map(rest, 0, _, budget, result), do: {:ok, result, rest, budget}

  defp map(bytes, count, depth, budget, result) do
    with {:ok, key, rest, budget} when is_integer(key) or is_binary(key) <-
           value(bytes, depth, budget),
         false <- Map.has_key?(result, key),
         {:ok, item, rest, budget} <- value(rest, depth, budget) do
      map(rest, count - 1, depth, budget, Map.put(result, key, item))
    else
      _ -> invalid()
    end
  end

  defp argument(info, rest) when info < 24, do: {:ok, info, rest}
  defp argument(24, <<v::8, rest::binary>>), do: {:ok, v, rest}
  defp argument(25, <<v::16, rest::binary>>), do: {:ok, v, rest}
  defp argument(26, <<v::32, rest::binary>>), do: {:ok, v, rest}
  defp argument(27, <<v::64, rest::binary>>), do: {:ok, v, rest}
  defp argument(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_webauthn}
end
