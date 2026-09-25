defmodule Atoll.CBOR.Bytes do
  @moduledoc """
  Distinguishes CBOR byte strings from UTF-8 text strings.
  """

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: binary()}
end
