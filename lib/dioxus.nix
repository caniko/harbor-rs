# mkDioxusPackage :: {
#   pkgs, src, cargoLock, pname,
#   rustToolchain, craneLib, cargoVendorDir ?,
#   package ?, platform ?, features ?, wasmSplit ?, ...
# } -> derivation
#
# Build a Dioxus web distribution with the pinned project toolchain. The
# helper keeps generic Cargo/WASM plumbing in rs-harbor while callers own
# source filtering and git-vendor overrides.
{packageTests}: {
  src,
  pkgs,
  cargoLock,
  pname,
  version ? "0.1.0",
  rustToolchain,
  craneLib,
  cargoVendorDir ? null,
  outputHashes ? {},
  overrideVendorGitCheckout ? null,
  package ? null,
  platform ? "web",
  features ? [],
  wasmSplit ? false,
  cargoArgs ? [],
  wasmBindgenCli ? null,
  dioxusCli ? pkgs.dioxus-cli,
  wasmOptPackage ? pkgs.binaryen,
  wasmOptArgs ? ["--strip-debug"],
  installSubdir ? "share/${pname}",
  nativeBuildInputs ? [],
  ...
} @ args: let
  lib = pkgs.lib;
  lockPath =
    if builtins.isPath cargoLock
    then cargoLock
    else cargoLock.lockFile or cargoLock;

  vendorArgs =
    {
      inherit src;
      cargoLock = lockPath;
      inherit outputHashes;
    }
    // lib.optionalAttrs (overrideVendorGitCheckout != null) {
      inherit overrideVendorGitCheckout;
    };

  effectiveCargoVendorDir =
    if cargoVendorDir != null
    then cargoVendorDir
    else craneLib.vendorCargoDeps vendorArgs;

  wasmOptCompat = pkgs.writeShellScriptBin "wasm-opt" ''
    set -euo pipefail
    input="''${1:?missing input wasm path}"
    shift
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then
        shift
        output="''${1:?missing output wasm path}"
      fi
      shift
    done
    test -n "$output"
    exec ${wasmOptPackage}/bin/wasm-opt ${lib.escapeShellArgs wasmOptArgs} "$input" -o "$output"
  '';

  dxArgs =
    [
      "--frozen"
      "bundle"
      "--platform"
      platform
      "--release"
    ]
    ++ lib.optional (package != null) "--package"
    ++ lib.optional (package != null) package
    ++ lib.optional (features != []) "--features"
    ++ lib.optional (features != []) (lib.concatStringsSep "," features)
    ++ lib.optional wasmSplit "--wasm-split";

  cargoTail = lib.optional (cargoArgs != []) "--" ++ cargoArgs;

  extraArgs = builtins.removeAttrs args [
    "src"
    "pkgs"
    "cargoLock"
    "pname"
    "version"
    "rustToolchain"
    "craneLib"
    "cargoVendorDir"
    "outputHashes"
    "overrideVendorGitCheckout"
    "package"
    "platform"
    "features"
    "wasmSplit"
    "cargoArgs"
    "wasmBindgenCli"
    "dioxusCli"
    "wasmOptPackage"
    "wasmOptArgs"
    "installSubdir"
    "nativeBuildInputs"
  ];

  packageDrv = pkgs.stdenvNoCC.mkDerivation ({
      inherit src pname version;

      nativeBuildInputs =
        [
          rustToolchain
          dioxusCli
          pkgs.pkg-config
          pkgs.clang
          pkgs.mold
          wasmOptCompat
          pkgs.esbuild
        ]
        ++ lib.optional (wasmBindgenCli != null) wasmBindgenCli
        ++ nativeBuildInputs;

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild

        export HOME="$TMPDIR/home"
        export CARGO_HOME="$TMPDIR/cargo-home"
        export CARGO_TARGET_DIR="$TMPDIR/cargo-target"
        export CARGO_NET_OFFLINE=true
        mkdir -p "$HOME" "$CARGO_HOME" "$CARGO_TARGET_DIR"

        # dx invokes Cargo itself. Use crane's generated vendor config so git
        # dependencies and the project linker settings resolve offline.
        mkdir -p .cargo
        if [ -f .cargo/config.toml ]; then
          cp .cargo/config.toml "$TMPDIR/project-cargo-config.toml"
        else
          : > "$TMPDIR/project-cargo-config.toml"
        fi
        cp "${effectiveCargoVendorDir}/config.toml" .cargo/config.toml
        cat "$TMPDIR/project-cargo-config.toml" >> .cargo/config.toml

        dx ${lib.escapeShellArgs dxArgs} --out-dir "$TMPDIR/dioxus-out" ${lib.escapeShellArgs cargoTail}
        test -s "$TMPDIR/dioxus-out/public/index.html"
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/${installSubdir}"
        cp -R "$TMPDIR/dioxus-out/public"/. "$out/${installSubdir}/"
        test -s "$out/${installSubdir}/index.html"
        runHook postInstall
      '';
    }
    // extraArgs);
in
  packageDrv
  // {
    artifactBuilder = packageTests.mkArtifactBuilder {
      kind = "trunk-builder";
      packageName = pname;
      inherit version;
      output = toString packageDrv;
      buildCommand = "nix build .#${pname}";
      inputs = [(toString src)];
      metadata = {
        inherit platform features wasmSplit;
        helper = "mkDioxusPackage";
      };
    };
  }
