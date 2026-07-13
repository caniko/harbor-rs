# mkCrossPackages :: {
#   pkgs,            # native build-system pkgs with rust-overlay applied
#   craneLib,        # native craneLib from rs-harbor.lib.mkToolchain
#   cross,           # result of rs-harbor.lib.mkCross
#   pname,           # base package name, e.g. "modde"
#   commonArgs,      # base crane args shared across targets; MUST include 'src'
#   targets ? [ "native" ],   # subset of the supported target names
#   targetArgs ? {},          # per-target extra crane args, merged LAST
#   toolchainArgs ? {},       # mkToolchain args for non-native targets
# } -> attrset of derivations keyed by OUTPUT ATTR NAME:
#        "native"         -> attr "${pname}"
#        "aarch64-linux"  -> attr "${pname}-aarch64-linux"
#        "windows"        -> attr "${pname}-windows"
#        "darwin-x86_64"  -> attr "${pname}-darwin-x86_64"
#        "darwin-aarch64" -> attr "${pname}-darwin-aarch64"
#
# Each target builds its own cargoArtifacts via buildDepsOnly, then buildPackage,
# applying the right CARGO_BUILD_TARGET + cross env. The aarch64-linux target
# builds a dedicated craneLib from pkgs.pkgsCross.aarch64-multiplatform via
# mkToolchain. Darwin targets fall back to a runCommand that exits 1 when
# cross.osxcrossRustHelpers == null (no realized macOS SDK). Only the requested
# targets' attrs are returned.
#
# This lifts the per-project cross-build boilerplate (previously hand-rolled in
# each consumer flake; see rs-modde flake.nix) into a single reusable helper.
{mkToolchain}: {
  pkgs,
  craneLib,
  cross,
  pname,
  commonArgs,
  targets ? ["native"],
  targetArgs ? {},
  toolchainArgs ? {},
}: let
  lib = pkgs.lib;

  supportedTargets = [
    "native"
    "aarch64-linux"
    "windows"
    "darwin-x86_64"
    "darwin-aarch64"
  ];

  unknownTargets = lib.filter (t: !(builtins.elem t supportedTargets)) targets;
in
  assert lib.assertMsg (commonArgs ? src)
    "rs-harbor: mkCrossPackages 'commonArgs' must include 'src'";
  assert lib.assertMsg (builtins.isList targets)
    "rs-harbor: mkCrossPackages 'targets' must be a list of target names";
  assert lib.assertMsg (unknownTargets == [])
    "rs-harbor: mkCrossPackages received unsupported target(s): ${lib.concatStringsSep ", " unknownTargets}. Supported: ${lib.concatStringsSep ", " supportedTargets}";
  let
    # Per-target extra args injected by the consumer (buildInputs, postInstall,
    # cargoBuildExtraArgs, doCheck, ...). Merged LAST so they win over our env.
    extraFor = target: targetArgs.${target} or {};

    # --- native -------------------------------------------------------------
    nativeArgs =
      commonArgs
      // {inherit pname;}
      // extraFor "native";
    nativeCargoArtifacts = craneLib.buildDepsOnly nativeArgs;
    nativePkg = craneLib.buildPackage (nativeArgs
      // {cargoArtifacts = nativeCargoArtifacts;});

    # --- aarch64-linux ------------------------------------------------------
    aarch64LinuxTarget = "aarch64-unknown-linux-gnu";
    toolchainAarch64 = mkToolchain (
      {
        pkgs = cross.linuxAarch64.pkgsCross;
      }
      // toolchainArgs
    );
    craneLibAarch64 = toolchainAarch64.craneLib;
    aarch64LinuxArgs =
      commonArgs
      // {pname = "${pname}-aarch64-linux";}
      // cross.linuxAarch64.env
      // {
        CARGO_BUILD_TARGET = aarch64LinuxTarget;
        PKG_CONFIG_ALLOW_CROSS = "1";
        depsBuildBuild = [cross.linuxAarch64.cc];
      }
      // extraFor "aarch64-linux";
    aarch64LinuxCargoArtifacts = craneLibAarch64.buildDepsOnly aarch64LinuxArgs;
    aarch64LinuxPkg = craneLibAarch64.buildPackage (aarch64LinuxArgs
      // {cargoArtifacts = aarch64LinuxCargoArtifacts;});

    # --- windows (x86_64-pc-windows-gnu via MinGW) --------------------------
    windowsTarget = "x86_64-pc-windows-gnu";
    buildPlatformSuffix =
      lib.strings.toLower pkgs.pkgsBuildHost.stdenv.hostPlatform.rust.cargoEnvVarTarget;
    windowsArgs =
      commonArgs
      // {pname = "${pname}-windows";}
      // cross.windowsEnv
      // {
        CARGO_BUILD_TARGET = windowsTarget;
        PKG_CONFIG_ALLOW_CROSS = "1";
        "CC_${buildPlatformSuffix}" = "cc";
        "CXX_${buildPlatformSuffix}" = "c++";
      }
      // extraFor "windows";
    windowsCargoArtifacts = craneLib.buildDepsOnly windowsArgs;
    windowsPkg = craneLib.buildPackage (windowsArgs
      // {cargoArtifacts = windowsCargoArtifacts;});

    # --- darwin (osxcross) --------------------------------------------------
    mkDarwinUnavailable = name:
      pkgs.runCommand name {} ''
        echo "ERROR: ${name} requires osxcross on x86_64-linux with a realized macOS SDK." >&2
        exit 1
      '';

    darwinArgs = darwinPname: target:
      commonArgs
      // lib.optionalAttrs (cross.osxcrossRustHelpers != null) cross.osxcrossRustHelpers.commonEnv
      // {
        pname = darwinPname;
        PKG_CONFIG_ALLOW_CROSS = "1";
      }
      // extraFor target;

    mkDarwinPkg = target: darwinTriple: let
      darwinPname = "${pname}-${target}";
      args = darwinArgs darwinPname target;
      builder =
        if cross.osxcrossRustHelpers != null
        then
          cross.osxcrossRustHelpers.mkCrossBuilder {
            inherit craneLib;
            target = darwinTriple;
          }
        else null;
    in
      if builder != null
      then
        builder.buildPackage (args
          // {cargoArtifacts = builder.buildDepsOnly args;})
      else mkDarwinUnavailable darwinPname;

    # Map of every supported output attr name -> derivation thunk.
    allOutputs = {
      "native" = {"${pname}" = nativePkg;};
      "aarch64-linux" = {"${pname}-aarch64-linux" = aarch64LinuxPkg;};
      "windows" = {"${pname}-windows" = windowsPkg;};
      "darwin-x86_64" = {"${pname}-darwin-x86_64" = mkDarwinPkg "darwin-x86_64" "x86_64-apple-darwin";};
      "darwin-aarch64" = {"${pname}-darwin-aarch64" = mkDarwinPkg "darwin-aarch64" "aarch64-apple-darwin";};
    };
  in
    lib.foldl' (acc: target: acc // allOutputs.${target}) {} targets
