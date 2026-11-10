# `mkBinstallRelease`: one call turns a workspace into cargo-binstall archives.
#
# It builds the host's declared cross targets once, packs every binary they
# ship into a deterministic archive with the harbor `bin/` layout, and derives
# the union `[package.metadata.binstall]` for every system declared in
# `targets`. The union is plain data, so any host renders identical metadata
# without instantiating another system's toolchain; `archives` exposes those
# synthetic descriptors so a check can prove they equal the host's real ones.
{
  mkToolchain,
  mkCross,
  mkCrossPackages,
  mkReleaseArchive,
  mkReleaseBundle,
}: {
  pkgs,
  system,
  pname,
  version,
  commonArgs,
  crates,
  targets ? {
    x86_64-linux = ["x86_64-linux-musl" "aarch64-linux-musl" "windows"];
    aarch64-darwin = ["native"];
  },
  tagPrefix ? "",
  toolchainArgs ? {},
  cross ? null,
  targetArgs ? {},
}: let
  lib = pkgs.lib;
  binstallLib = import ./binstall.nix {inherit lib;};
  inherit (binstallLib) crateBins mkBinstallCheck mkBinstallMetadata;

  crateList = lib.mapAttrsToList (name: crate: crate // {inherit name;}) crates;
  bins = lib.concatMap (crate: crateBins crate.cargoToml) crateList;
  duplicateBins = lib.filter (bin: lib.count (other: other == bin) bins > 1) (lib.unique bins);
  invalidCrates = map (crate: crate.name) (lib.filter (crate: !(crate ? cargoToml)) crateList);

  # Nix system -> Rust triple, for the `native` target of any declared system.
  hostRustTarget = sys: let
    parts = lib.splitString "-" sys;
    arch = lib.head parts;
    os = lib.last parts;
  in
    if os == "linux"
    then "${arch}-unknown-linux-gnu"
    else if os == "darwin"
    then "${arch}-apple-darwin"
    else if os == "windows"
    then "${arch}-pc-windows-gnu"
    else throw "harbor-rs: mkBinstallRelease has no native Rust target for system '${sys}'";

  # Archive metadata implied by a mkCrossPackages target name, independent of
  # the host that builds it.
  targetSpecs = {
    x86_64-linux-musl = {
      system = "x86_64-linux";
      rustTarget = "x86_64-unknown-linux-musl";
    };
    aarch64-linux-musl = {
      system = "aarch64-linux";
      rustTarget = "aarch64-unknown-linux-musl";
    };
    aarch64-linux = {
      system = "aarch64-linux";
      rustTarget = "aarch64-unknown-linux-gnu";
    };
    windows = {
      system = "x86_64-windows";
      rustTarget = "x86_64-pc-windows-gnu";
    };
    windows-aarch64 = {
      system = "aarch64-windows";
      rustTarget = "aarch64-pc-windows-gnullvm";
    };
    darwin-x86_64 = {
      system = "x86_64-darwin";
      rustTarget = "x86_64-apple-darwin";
    };
    darwin-aarch64 = {
      system = "aarch64-darwin";
      rustTarget = "aarch64-apple-darwin";
    };
  };
  supportedTargets = ["native"] ++ lib.attrNames targetSpecs;

  specFor = host: target:
    if target == "native"
    then {
      system = host;
      rustTarget = hostRustTarget host;
    }
    else targetSpecs.${target};

  archiveFormat = sys:
    if lib.hasSuffix "-windows" sys
    then "zip"
    else "tar.gz";

  # Static musl builds are the portable archive contract; everything else
  # keeps the plain executable.
  archiveValidation = spec:
    if lib.hasSuffix "-musl" spec.rustTarget
    then "static-elf"
    else "none";

  archiveBinaries = sys: map (bin: "bin/${bin}${lib.optionalString (lib.hasSuffix "-windows" sys) ".exe"}") bins;

  archiveName = spec: "${pname}-${version}-${spec.rustTarget}.${archiveFormat spec.system}";

  declaredTargets = lib.concatMap (host: targets.${host}) (lib.attrNames targets);
  unknownTargets = lib.filter (target: !(builtins.elem target supportedTargets)) declaredTargets;

  # Every declared system's archive descriptors, from data only. This is what
  # `binstall` is rendered from, so the TOML is the same on every host.
  archives = lib.concatMap (host:
    map (target: let
      spec = specFor host target;
    in {
      name = archiveName spec;
      inherit (spec) system rustTarget;
      format = archiveFormat spec.system;
      validation = archiveValidation spec;
      binaries = archiveBinaries spec.system;
    })
    targets.${host})
  (lib.attrNames targets);

  hostTargets = targets.${system} or [];

  toolchain = mkToolchain ({inherit pkgs;} // toolchainArgs);
  crossTools =
    if cross != null
    then cross
    else mkCross {inherit pkgs system;};
  # Release archives are built once per target and never run: cross test
  # binaries cannot execute on the build host, and Rust's windows-gnu target
  # shells out to the MinGW dlltool, which must be on PATH.
  releaseTargetArgs = lib.genAttrs hostTargets (target: let
    extra = targetArgs.${target} or {};
  in
    lib.optionalAttrs (target != "native") {doCheck = false;}
    // extra
    // lib.optionalAttrs (target == "windows") {
      nativeBuildInputs = [crossTools.mingwCC crossTools.mingwBinutils] ++ (extra.nativeBuildInputs or []);
    });
  crossPackages = mkCrossPackages {
    inherit pkgs pname commonArgs;
    targetArgs = releaseTargetArgs;
    inherit (toolchain) craneLib;
    cross = crossTools;
    targets = hostTargets;
    # `null` keeps mkCrossPackages' native-profile inheritance; `{}` would
    # silently reset it to the harbor default channel.
    toolchainArgs =
      if toolchainArgs == {}
      then null
      else toolchainArgs;
  };

  mkArchive = target: let
    spec = specFor system target;
    attrName =
      if target == "native"
      then pname
      else "${pname}-${target}";
  in
    mkReleaseArchive {
      inherit pkgs pname version;
      name = archiveName spec;
      package = crossPackages.${attrName};
      entries = lib.genAttrs (archiveBinaries spec.system) (path: path);
      format = archiveFormat spec.system;
      inherit (spec) system rustTarget;
      validation = archiveValidation spec;
    };

  releaseBundle =
    if hostTargets == []
    then null
    else
      mkReleaseBundle {
        inherit pkgs pname version;
        artifacts = lib.genAttrs hostTargets mkArchive;
        binstallTagPrefix = tagPrefix;
      };

  binstall = mkBinstallMetadata {
    inherit version archives;
    inherit tagPrefix;
  };

  checkBundle = {
    inherit binstall;
    binstallArchives = archives;
  };
  checkName = crate:
    if lib.length crateList == 1
    then "binstall-metadata"
    else "binstall-metadata-${crate.name}";
  checks = lib.listToAttrs (map (crate:
    lib.nameValuePair (checkName crate) (mkBinstallCheck {
      inherit pkgs;
      bundle = checkBundle;
      cargoToml = crate.cargoToml;
    }))
  crateList);
in
  assert lib.assertMsg (builtins.isString pname && pname != "")
  "harbor-rs: mkBinstallRelease 'pname' must be a non-empty string";
  assert lib.assertMsg (builtins.isString version && version != "")
  "harbor-rs: mkBinstallRelease 'version' must be a non-empty string";
  assert lib.assertMsg (crates != {})
  "harbor-rs: mkBinstallRelease needs at least one crate with binaries";
  assert lib.assertMsg (invalidCrates == [])
  "harbor-rs: mkBinstallRelease crate entries need a `cargoToml`: ${lib.concatStringsSep ", " invalidCrates}";
  assert lib.assertMsg (duplicateBins == [])
  "harbor-rs: mkBinstallRelease crates ship the same binary name: ${lib.concatStringsSep ", " duplicateBins}";
  assert lib.assertMsg (unknownTargets == [])
  "harbor-rs: mkBinstallRelease received unsupported target(s): ${lib.concatStringsSep ", " unknownTargets}. Supported: ${lib.concatStringsSep ", " supportedTargets}"; {
    inherit releaseBundle binstall checks archives;
    packages =
      if hostTargets == []
      then {}
      else crossPackages;
  }
