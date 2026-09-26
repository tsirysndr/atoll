defmodule Mix.Tasks.Atoll.Assets do
  @shortdoc "Copies the dependency-free account browser script into static assets"
  use Mix.Task

  @impl Mix.Task
  def run(_) do
    File.mkdir_p!("priv/static/assets")
    File.cp!("assets/js/passkeys.js", "priv/static/assets/passkeys.js")
  end
end
