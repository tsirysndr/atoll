defmodule Atoll.TID do
  @moduledoc "Sortable timestamp identifiers. Serialize next/2 with the repository's head update."
  import Bitwise
  @alphabet "234567abcdefghijklmnopqrstuvwxyz"
  @digits @alphabet |> :binary.bin_to_list() |> Enum.with_index() |> Map.new()

  def encode(value)
      when is_integer(value) and value >= 0 and value < 18_446_744_073_709_551_616 do
    for shift <- 60..0//-5, into: "", do: <<:binary.at(@alphabet, band(value >>> shift, 31))>>
  end

  def decode(value) when is_binary(value) and byte_size(value) == 13 do
    if Regex.match?(~r/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/, value) do
      {:ok, for(<<c <- value>>, reduce: 0, do: (acc -> acc * 32 + Map.fetch!(@digits, c)))}
    else
      {:error, :invalid_tid}
    end
  end

  def decode(_), do: {:error, :invalid_tid}
  def valid?(value), do: match?({:ok, _}, decode(value))

  @doc "Generates a revision greater than the supplied previous revision, even if the clock regresses."
  def next(previous \\ nil, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:microsecond) end)
    clock = Keyword.get_lazy(opts, :clock, fn -> :rand.uniform(1024) - 1 end)

    with true <- is_integer(now) and now >= 0 and now < 9_007_199_254_740_992,
         true <- is_integer(clock) and clock in 0..1023,
         {:ok, prior} <- previous_value(previous),
         value = max(now * 1024 + clock, prior + 1),
         true <- value < 9_223_372_036_854_775_808 do
      {:ok, encode(value)}
    else
      _ -> {:error, :invalid_tid}
    end
  end

  defp previous_value(nil), do: {:ok, -1}
  defp previous_value(previous), do: decode(previous)
end
