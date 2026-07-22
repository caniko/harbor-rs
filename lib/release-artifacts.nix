# Generic release artifact constructors.
#
# The artifact layer deliberately does not know about Codeberg or Simit.  It
# produces deterministic, flat Nix outputs plus a small passthru descriptor;
# Simit consumes the conventional release-bundle output in its Forgejo job.
{pkgs}:
let
  lib = pkgs.lib;
  inherit (lib) concatStringsSep escapeShellArg optionalString;

  require = label: value:
    assert lib.assertMsg (value != null) "rs-harbor: release ${label} is required";
      value;

  requireString = label: value:
    assert lib.assertMsg (builtins.isString value && value != "")
      "rs-harbor: release ${label} must be a non-empty string";
      value;

  descriptor = {
    pname,
    version,
    name,
    kind,
    format,
    system ? null,
    rustTarget ? null,
    validation ? "none",
    consumable ? false,
    files ? [name],
  }:
    assert lib.assertMsg (builtins.isString pname && pname != "") "rs-harbor: release pname must be a non-empty string";
    assert lib.assertMsg (builtins.isString version && version != "") "rs-harbor: release version must be a non-empty string";
    {
      schemaVersion = 2;
      inherit pname version name kind format system rustTarget validation consumable files;
    };

  artifactPassthru = meta: {
    passthru.rsHarborReleaseArtifact = meta;
  };

  mkFile = {
    pname,
    version,
    name,
    source,
    sourcePath ? null,
    kind ? "opaque",
    format ? "raw",
    system ? null,
    rustTarget ? null,
    validation ? "none",
    consumable ? false,
    executable ? false,
  }:
    let
      fileName = requireString "artifact name" name;
      sourceValue = require "artifact source" source;
      meta = descriptor {
        inherit pname version;
        name = fileName;
        inherit kind format system rustTarget validation consumable;
      };
      sourceArg = if sourcePath == null then "${sourceValue}" else "${sourceValue}/${sourcePath}";
    in
      pkgs.runCommand "${pname}-${version}-${fileName}-release-artifact" (artifactPassthru meta) ''
        set -euo pipefail
        mkdir -p "$out"
        test -f ${escapeShellArg sourceArg}
        install -m${if executable then "0755" else "0644"} ${escapeShellArg sourceArg} "$out/${fileName}"
      '';

  expectedMachine = system:
    if system == "x86_64-linux"
    then "Advanced Micro Devices X86-64"
    else if system == "aarch64-linux"
    then "AArch64"
    else throw "rs-harbor: unsupported release ELF system '${system}'";

  mkArchive = {
    pname,
    version,
    name,
    package,
    entries,
    format ? "tar.gz",
    kind ? "binary",
    system ? null,
    rustTarget ? null,
    validation ? "none",
    consumable ? false,
  }:
    let
      archiveName = requireString "archive name" name;
      packageValue = require "archive package" package;
      entryNames = builtins.attrNames entries;
      entryArgs = concatStringsSep " " (map escapeShellArg entryNames);
      entrySources = concatStringsSep "\n" (map (destination:
        "source=\"${packageValue}/${entries.${destination}}\"\ndestination=\"$stage/${destination}\"\nmkdir -p \"$(dirname \"$destination\")\"\ninstall -m0755 \"$source\" \"$destination\"") entryNames);
      meta = descriptor {
        inherit pname version;
        name = archiveName;
        files = [archiveName];
        inherit kind format system rustTarget validation consumable;
      };
      validationScript =
        if validation == "static-elf"
        then
          assert lib.assertMsg (system != null) "rs-harbor: static-elf artifacts require system";
          ''
            for binary in ${entryArgs}; do
              readelf -h "$stage/$binary" | grep -F ${escapeShellArg (expectedMachine system)} >/dev/null
              ! readelf -l "$stage/$binary" | grep -q INTERP
              ! readelf -d "$stage/$binary" | grep -q NEEDED
            done
          ''
        else "";
      archiveCommand =
        if format == "tar.gz"
        then ''tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' -czf "$out/${archiveName}" -C "$stage" .''
        else if format == "zip"
        then ''cd "$stage" && zip -X -q "$out/${archiveName}" $(find . -type f -print | LC_ALL=C sort)''
        else throw "rs-harbor: unsupported release archive format '${format}'";
    in
      pkgs.runCommand "${pname}-${version}-${archiveName}-release-artifact" ((artifactPassthru meta) // {
        nativeBuildInputs = [pkgs.binutils pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnutar pkgs.gzip pkgs.zip];
      }) ''
        set -euo pipefail
        stage="$TMPDIR/stage"
        mkdir -p "$stage"
        ${entrySources}
        ${validationScript}
        mkdir -p "$out"
        ${archiveCommand}
      '';

  mkReleaseBundle = {
    pname,
    version,
    artifacts,
  }:
    let
      artifactValues = builtins.attrValues artifacts;
      descriptors = map (artifact: if builtins.isAttrs artifact && artifact ? rsHarborReleaseArtifact then artifact.rsHarborReleaseArtifact else {
        schemaVersion = 2;
        name = builtins.baseNameOf (toString artifact);
        kind = "opaque";
        format = "directory";
        system = null;
        rustTarget = null;
        validation = "none";
        consumable = false;
        files = [];
      }) artifactValues;
      manifest = builtins.toJSON {
        schemaVersion = 2;
        inherit pname version;
        artifacts = descriptors;
      };
      artifactArgs = concatStringsSep " " (map (artifact: escapeShellArg (toString artifact)) artifactValues);
    in
      pkgs.runCommand "${pname}-${version}-release-bundle" {
        nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.jq];
        passthru.rsHarborReleaseBundle = true;
      } ''
        set -euo pipefail
        mkdir -p "$out"
        for artifact in ${artifactArgs}; do
          while IFS= read -r file; do
            name="$(basename "$file")"
            test ! -e "$out/$name" || {
              echo "rs-harbor: release bundle asset collision: $name" >&2
              exit 1
            }
            cp -L "$file" "$out/$name"
          done < <(find -L "$artifact" -mindepth 1 -maxdepth 1 -type f -print | LC_ALL=C sort)
        done
        cat > "$out/${pname}-${version}-release-manifest.json" <<'MANIFEST'
        ${manifest}
        MANIFEST
        ${pkgs.jq}/bin/jq -e --arg name ${escapeShellArg pname} --arg version ${escapeShellArg version} \
          '(.schemaVersion == 2) and (.pname == $name) and (.version == $version) and (.artifacts | length > 0)' \
          "$out/${pname}-${version}-release-manifest.json" >/dev/null
      '';

  mkPrebuiltFlake = {
    pname,
    version,
    packages,
    description ? "${pname} prebuilt release",
  }:
    let
      systems = builtins.attrNames packages;
      packageFiles = lib.mapAttrsToList (system: spec: {
        inherit system;
        binary = spec.binary;
        source = toString spec.source;
      }) packages;
      fileCopies = concatStringsSep "\n" (map (spec: ''
        mkdir -p "$stage/${spec.system}/bin"
        install -m0755 ${escapeShellArg "${spec.source}/bin/${spec.binary}"} "$stage/${spec.system}/bin/${spec.binary}"
      '') packageFiles);
      packageAttrs = concatStringsSep "\n" (map (spec: ''
        ${builtins.toJSON spec.system} = let pkgs = import nixpkgs {system = ${builtins.toJSON spec.system};}; in {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = ${builtins.toJSON "${pname}-prebuilt"};
            version = ${builtins.toJSON version};
            src = ./${spec.system};
            dontUnpack = true;
            installPhase = "mkdir -p $out/bin; install -m0755 $src/bin/${spec.binary} $out/bin/${spec.binary}";
          };
        };
      '') packageFiles);
      flake = ''
        {
          description = ${builtins.toJSON description};
          inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
          outputs = {self, nixpkgs}: {
            packages = {
              ${packageAttrs}
            };
          };
        }
      '';
    in
      pkgs.runCommand "${pname}-${version}-prebuilt-flake" {nativeBuildInputs = [pkgs.coreutils pkgs.gnutar pkgs.gzip];} ''
        set -euo pipefail
        stage="$TMPDIR/stage"
        mkdir -p "$stage"
        ${fileCopies}
        printf '%s\n' ${escapeShellArg flake} > "$stage/flake.nix"
        tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' -czf "$out" -C "$stage" .
      '';
in {
  inherit mkFile mkArchive mkReleaseBundle mkPrebuiltFlake;
  mkReleaseArtifact = mkFile;
  mkReleaseArchive = mkArchive;
}
