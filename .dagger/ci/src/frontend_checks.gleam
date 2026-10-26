import ci
import dagger/container
import dagger/directory
import dagger/mod
import dagger/mod/codec
import dagger/types

pub fn frontend(
  context: mod.Context,
  source: types.Directory,
) -> Result(String, codec.Error) {
  let built =
    ci.frontend(context.client, source, "assets")
    |> container.with_exec(["bun", "run", "storybook:build"])
    |> container.with_workdir("/src")
    |> ci.commands([
      ["apt-get", "update"],
      ["apt-get", "install", "-y", "--no-install-recommends", "python3"],
      ["python3", "scripts/bun2nix.py"],
    ])
  ci.unchanged(
    directory.directory(source, "nix"),
    container.directory(built, "/src/nix"),
  )
}
