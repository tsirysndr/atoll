defmodule Atoll.BinaryArray do
  @moduledoc "Binary arrays: native bytea[] on PostgreSQL, JSON hex strings on SQLite."
  use Ecto.Type
  @sqlite Application.compile_env(:atoll, :database, :postgres) == :sqlite

  def type, do: if(@sqlite, do: :string, else: {:array, :binary})

  def cast(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  def cast(_), do: :error

  def dump(values) do
    with {:ok, values} <- cast(values) do
      if @sqlite,
        do: {:ok, Jason.encode!(Enum.map(values, &Base.encode16/1))},
        else: {:ok, values}
    end
  end

  if @sqlite do
    def load(value) do
      with {:ok, values} when is_list(values) <- Jason.decode(value) do
        Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
          case decode(value) do
            {:ok, bytes} -> {:cont, {:ok, [bytes | acc]}}
            _ -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, values} -> {:ok, Enum.reverse(values)}
          _ -> :error
        end
      else
        _ -> :error
      end
    end

    defp decode(value) when is_binary(value), do: Base.decode16(value)
    defp decode(_), do: :error
  else
    def load(values), do: cast(values)
  end
end
