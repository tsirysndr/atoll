defmodule Atoll.CBOR.Link do
  @moduledoc """
  A CBOR link containing a binary CID.
  """

  @enforce_keys [:cid]
  defstruct [:cid]

  @type t :: %__MODULE__{cid: binary()}
end
