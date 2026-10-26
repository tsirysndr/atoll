import dagger/directory
import dagger/mod
import dagger/mod/argument
import dagger/mod/codec
import elixir_checks
import frontend_checks
import nix_checks

pub fn definition() -> mod.Object {
  let source = argument.required("source", directory.codec())
  let root =
    mod.object("ProjectCi")
    |> mod.with_function(mod.function(
      "postgres",
      source,
      codec.string(),
      elixir_checks.postgres,
    ))
    |> mod.with_function(mod.function(
      "sqlite",
      source,
      codec.string(),
      elixir_checks.sqlite,
    ))
    |> mod.with_function(mod.function(
      "frontend",
      source,
      codec.string(),
      frontend_checks.frontend,
    ))
    |> mod.with_function(mod.function(
      "nix",
      argument.pair(source, argument.required("target", codec.string())),
      codec.string(),
      nix_checks.nix,
    ))
  root
}
