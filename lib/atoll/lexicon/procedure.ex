defmodule Atoll.Lexicon.Procedure do
  @moduledoc "Validates JSON procedure envelopes using the shared Lexicon schema engine."
  defdelegate methods(), to: Atoll.Lexicon.Schema
  defdelegate validate(nsid, body), to: Atoll.Lexicon.Schema
end
