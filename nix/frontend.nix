{
  lib,
  stdenv,
  fetchurl,
  writeText,
  autoPatchelfHook,
  bun,
  nodejs,
}:

{ version }:

let
  deps = import ./bun-deps.nix;

  manifest = writeText "bun-deps-manifest" (
    lib.concatMapStrings (dep: "${fetchurl { inherit (dep) url hash; }} ${dep.path}\n") deps
  );

  bins = writeText "bun-deps-bins" (
    lib.concatMapStrings (
      dep: lib.concatMapStrings (bin: "${dep.path} ${bin.name} ${bin.path}\n") dep.bins
    ) deps
  );

  # Ordinary phases rather than runCommand: a buildCommand skips fixupPhase, and
  # with it the interpreter patching the prebuilt binaries need.
  nodeModules = stdenv.mkDerivation {
    name = "atoll-node-modules-${version}";

    dontUnpack = true;

    nativeBuildInputs = [ nodejs ] ++ lib.optional stdenv.hostPlatform.isLinux autoPatchelfHook;
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

    # The tree carries prebuilt binaries for every platform; only this one's can
    # be patched, and the rest are left as they are.
    autoPatchelfIgnoreMissingDeps = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/.bin

      while read -r tarball path; do
        mkdir -p "$out/$path"
        tar -xzf "$tarball" -C "$out/$path" --strip-components=1
      done < ${manifest}

      while read -r path name target; do
        ln -sf "../$path/$target" "$out/.bin/$name"
      done < ${bins}

      chmod -R u+w $out

      # npm ships `#!/usr/bin/env node`, and the sandbox has no /usr/bin.
      patchShebangs $out

      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  pname = "atoll-account";
  inherit version;

  src = ../assets;

  nativeBuildInputs = [
    bun
    nodejs
  ];

  configurePhase = ''
    runHook preConfigure
    cp -r ${nodeModules} node_modules
    chmod -R u+w node_modules
    export PATH="$PWD/node_modules/.bin:$PATH"
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ATOLL_ASSETS_OUT="$out" bun run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    test -f "$out/account.js"
    test -f "$out/account.css"
    runHook postInstall
  '';

  meta = {
    description = "Atoll account frontend bundle";
    license = lib.licenses.mit;
  };
}
