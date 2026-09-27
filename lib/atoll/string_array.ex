defmodule Atoll.StringArray do
  @moduledoc "A nullable string array that preserves SQL NULL on both adapters."
  use Ecto.Type
  @sqlite Application.compile_env(:atoll, :database, :postgres) == :sqlite

  def type, do: if(@sqlite, do: :string, else: {:array, :string})
  def cast(value), do: Ecto.Type.cast({:array, :string}, value)

  def dump(value) do
    with {:ok, values} <- cast(value) do
      if @sqlite, do: {:ok, Jason.encode!(values)}, else: {:ok, values}
    end
  end

  def load(value) do
    if @sqlite do
      with {:ok, values} <- Jason.decode(value), do: cast(values)
    else
      cast(value)
    end
  end
end
