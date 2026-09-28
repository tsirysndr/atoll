{
  lib,
  beamPackages,
  callPackage,
  sqlite,
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

  frontend = callPackage ./frontend.nix { } { inherit version; };

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
    # mix.exs sets build_path per adapter, and Mix nests MIX_ENV under it again.
    # Both spellings would miss the _build/$MIX_ENV/lib that mixRelease symlinks
    # its dependencies into, so pin the build root back to that layout.
    MIX_BUILD_ROOT = "_build";
    # The bundle is built by nix/frontend.nix from assets/bun.lock; the Mix task
    # would otherwise need network access for Bun.
    ATOLL_SKIP_ASSETS = "true";
  };

  preBuild = ''
    mkdir -p priv/static/assets
    cp -r ${frontend}/* priv/static/assets/
    # The bundle arrives read-only from the store; phx.digest rewrites it.
    chmod -R u+w priv/static/assets
  '';

  postBuild = ''
    # Aliases need deps.loadpaths to carry --no-deps-check for them:
    # https://github.com/phoenixframework/phoenix/issues/2690
    mix do deps.loadpaths --no-deps-check + assets.deploy
  '';

  meta = {
    description = "AT Protocol Personal Data Server (${database} build)";
    homepage = "https://atoll-docs.tsirysndr.deno.net";
    license = lib.licenses.mit;
    mainProgram = "atoll";
    platforms = lib.platforms.unix;
  };
}
