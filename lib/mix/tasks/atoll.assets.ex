defmodule Mix.Tasks.Atoll.Assets do
  @shortdoc "Builds the account frontend with Bun into priv/static/assets"
  @moduledoc """
  Runs the Bun build for `assets/`.

      mix atoll.assets            # build
      mix atoll.assets --install  # install dependencies, then build

  Set ATOLL_SKIP_ASSETS=true to skip the build, for example when the bundle was
  built elsewhere and copied into priv/static.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    if System.get_env("ATOLL_SKIP_ASSETS") == "true" do
      Mix.shell().info("atoll.assets: skipped (ATOLL_SKIP_ASSETS=true)")
    else
      directory = Path.join(File.cwd!(), "assets")
      bun = System.find_executable("bun") || Mix.raise("bun is required to build assets/")

      if "--install" in args or not File.dir?(Path.join(directory, "node_modules")) do
        run!(bun, ["install", "--frozen-lockfile"], directory)
      end

      run!(bun, ["run", "build"], directory)
    end
  end

  defp run!(bun, args, directory) do
    case System.cmd(bun, args,
           cd: directory,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("bun #{Enum.join(args, " ")} failed with status #{status}")
    end
  end
end
