defmodule Atoll.OAuth.Form do
  @moduledoc "Bounded flat OAuth form decoding with duplicate field rejection."
  def decode(body) when is_binary(body) and byte_size(body) in 1..49_152 do
    pairs = String.split(body, "&")

    if length(pairs) <= 11 and not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, body) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
        case String.split(pair, "=", parts: 2) do
          [key, value] ->
            key = URI.decode_www_form(key)
            value = URI.decode_www_form(value)

            if key != "" and String.valid?(key) and String.valid?(value) and
                 not Map.has_key?(acc, key),
               do: {:cont, {:ok, Map.put(acc, key, value)}},
               else: {:halt, {:error, :invalid_request}}

          _ ->
            {:halt, {:error, :invalid_request}}
        end
      end)
    else
      {:error, :invalid_request}
    end
  end

  def decode(_), do: {:error, :invalid_request}
end
