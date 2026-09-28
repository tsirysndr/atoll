{
  description = "Atoll, an AT Protocol Personal Data Server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # CI pins OTP 28 and Elixir 1.19; mixRelease builds with whatever the
      # package set provides, so the set is overridden rather than the release.
      beamFor =
        pkgs:
        pkgs.beam.packages.erlang_28.overrideScope (
          final: prev: {
            elixir = prev.elixir_1_19;
          }
        );
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          atoll = pkgs.callPackage ./nix/atoll.nix { beamPackages = beamFor pkgs; };
        in
        rec {
          sqlite = atoll { database = "sqlite"; };
          postgres = atoll { database = "postgres"; };
          default = sqlite;
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          beamPackages = beamFor pkgs;

          shellFor =
            database:
            pkgs.mkShell {
              name = "atoll-${database}";

              packages = [
                beamPackages.elixir
                beamPackages.erlang
                beamPackages.hex
                pkgs.rebar3
                pkgs.tailwindcss_4
                pkgs.mix2nix
                pkgs.sqlite
                pkgs.git
                pkgs.deno
                pkgs.bun
                pkgs.nodejs
              ]
              ++ pkgs.lib.optional (database == "postgres") pkgs.postgresql_18;

              # Headers for the exqlite NIF, which EXQLITE_USE_SYSTEM builds here
              # instead of downloading.
              buildInputs = [ pkgs.sqlite.dev ];

              env = {
                ATOLL_DATABASE = database;
                EXQLITE_USE_SYSTEM = "1";
                MIX_REBAR3 = "${pkgs.rebar3}/bin/rebar3";
                TAILWIND_PATH = "${pkgs.tailwindcss_4}/bin/tailwindcss";
              };

              shellHook = ''
                echo "atoll: $(elixir --version | tail -1), ATOLL_DATABASE=$ATOLL_DATABASE"
              '';
            };
        in
        rec {
          sqlite = shellFor "sqlite";
          postgres = shellFor "postgres";
          default = sqlite;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
