import ci
import dagger/container
import dagger/mod
import dagger/mod/codec
import dagger/types

pub fn nix(
  context: mod.Context,
  args: #(types.Directory, String),
) -> Result(String, codec.Error) {
  let #(source, target) = args
  case target {
    "sqlite" | "postgres" ->
      ci.nix(context.client, source, "atoll-" <> target)
      |> container.with_env_variable("RELEASE_COOKIE", "nix-smoke-test")
      |> ci.commands([
        ["nix", "build", ".#" <> target, "--print-build-logs"],
        ["./result/bin/atoll", "version"],
        ["nix", "develop", ".#" <> target, "--command", "mix", "--version"],
      ])
      |> ci.finish
    _ -> Error(codec.FunctionError("Target must be sqlite or postgres"))
  }
}
