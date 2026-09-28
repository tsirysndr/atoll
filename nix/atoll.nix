{
  lib,
  beamPackages,
  sqlite,
  tailwindcss_4,
}:

# The Ecto adapter is compiled in, so each database is its own package.
{ database }:

assert lib.assertMsg (lib.elem database [
  "postgres"
  "sqlite"
]) "database must be \"postgres\" or \"sqlite\"";

let
  mixNixDeps = import ./deps.nix {
    inherit lib beamPackages;
    overrides = final: prev: {
      # Without this exqlite asks elixir_make for a precompiled NIF, which needs
      # network the sandbox does not have. Compile against nixpkgs' SQLite.
      exqlite = prev.exqlite.override (old: {
        env = (old.env or { }) // {
          EXQLITE_USE_SYSTEM = "1";
        };
        buildInputs = (old.buildInputs or [ ]) ++ [
          sqlite.dev
          sqlite.out
        ];
      });
    };
  };

  version =
    let
      line = lib.findFirst (lib.hasInfix "version: \"") null (
        lib.splitString "\n" (builtins.readFile ../mix.exs)
      );
    in
    lib.elemAt (lib.splitString "\"" line) 1;
in
beamPackages.mixRelease {
  pname = "atoll-${database}";
  inherit version mixNixDeps;

  src = ../.;

  env = {
    ATOLL_DATABASE = database;
    # config/config.exs passes this to the tailwind dep, which would otherwise
    # download its own binary.
    TAILWIND_PATH = "${tailwindcss_4}/bin/tailwindcss";
  }
  // lib.optionalAttrs (database == "sqlite") {
    # mix.exs redirects build_path for SQLite; keep the _build/$MIX_ENV layout
    # that mixRelease symlinks its dependencies into.
    MIX_BUILD_ROOT = "_build";
  };

  postBuild = ''
    # Aliases need deps.loadpaths to carry --no-deps-check for them:
    # https://github.com/phoenixframework/phoenix/issues/2690
    mix do deps.loadpaths --no-deps-check, assets.deploy
  '';

  meta = {
    description = "AT Protocol Personal Data Server (${database} build)";
    homepage = "https://atoll-docs.tsirysndr.deno.net";
    license = lib.licenses.mit;
    mainProgram = "atoll";
    platforms = lib.platforms.unix;
  };
}
