defmodule Atoll.OAuth.WriteCredential do
  @moduledoc false
  @derive {Inspect, except: [:receipt]}
  defstruct [:receipt]
end
