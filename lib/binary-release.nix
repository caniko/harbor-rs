# Reproducible release archives and locked-input consumers for static Rust
# binaries.  The producer deliberately accepts already-built derivations so a
# project can choose its own crane/cross helper while rs-harbor owns the
# archive contract shared by all consumers.
{pkgs}:
let
  lib = pkgs.lib;
  inherit (lib) concatStringsSep escapeShellArg optional optionalString;

  requireNonEmpty = name: value:
    assert lib.assertMsg (lib.isString value && value != "")
      "rs-harbor: binary release ${name} must be a non-empty string";
      value;

  requireBinaries = binaries:
    assert lib.assertMsg (lib.isList binaries && binaries != [])
      "rs-harbor: binary release binaries must be a non-empty list";
      map (binary: requireNonEmpty "binary" binary) binaries;

  expectedMachine = system:
    if system == "x86_64-linux"
    then "Advanced Micro Devices X86-64"
    else if system == "aarch64-linux"
    then "AArch64"
    else throw "rs-harbor: unsupported binary release system '${system}'";

  mkArchive = target: spec:
    let
      pname = requireNonEmpty "pname" spec.pname;
      version = requireNonEmpty "version" spec.version;
      system = requireNonEmpty "system" (spec.system or target);
      rustTarget = requireNonEmpty "rustTarget" (spec.rustTarget or system);
      binaries = requireBinaries spec.binaries;
      binutils = spec.binutils or pkgs.binutils;
      strip = spec.strip or "${binutils}/bin/strip";
      readelf = spec.readelf or "${binutils}/bin/readelf";
      package =
        if spec ? package
        then spec.package
        else throw "rs-harbor: binary release '${target}' is missing package";
      archiveName = "${pname}-${version}-${system}-musl.tar.gz";
      manifest = builtins.toJSON {
        schemaVersion = 1;
        name = pname;
        inherit version system rustTarget binaries;
      };
      binaryArgs = concatStringsSep " " (map escapeShellArg binaries);
    in
      pkgs.runCommand "${pname}-${version}-${system}-release" {
        nativeBuildInputs = [
          pkgs.binutils
          pkgs.coreutils
          pkgs.file
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnutar
          pkgs.gzip
          pkgs.jq
        ];
      } ''
        set -euo pipefail
        stage="$TMPDIR/stage"
        mkdir -p "$stage/bin"

        for binary in ${binaryArgs}; do
          source="${package}/bin/$binary"
          test -f "$source" || {
            echo "missing release binary: $source" >&2
            exit 1
          }
          test -x "$source" || {
            echo "release binary is not executable: $source" >&2
            exit 1
          }
          install -m0755 "$source" "$stage/bin/$binary"
          # Crane may leave debug paths in the executable. Strip before
          # validation so the published binary has no Nix-store references.
          ${strip} --strip-all "$stage/bin/$binary"
          ${readelf} -h "$stage/bin/$binary" | \
            ${pkgs.gnugrep}/bin/grep -F '${expectedMachine system}' >/dev/null || {
              echo "release binary has the wrong ELF machine: $stage/bin/$binary" >&2
              exit 1
            }
          if ${readelf} -l "$stage/bin/$binary" | ${pkgs.gnugrep}/bin/grep -q 'INTERP'; then
            echo "release binary is dynamically linked (PT_INTERP): $stage/bin/$binary" >&2
            exit 1
          fi
          if ${readelf} -d "$stage/bin/$binary" | ${pkgs.gnugrep}/bin/grep -q 'NEEDED'; then
            echo "release binary has dynamic dependencies: $stage/bin/$binary" >&2
            exit 1
          fi
        done

        cat > "$stage/manifest.json" <<'MANIFEST'
        ${manifest}
        MANIFEST
        ${pkgs.jq}/bin/jq -e . "$stage/manifest.json" >/dev/null

        mkdir -p "$out"
        ${pkgs.gnutar}/bin/tar \
          --sort=name \
          --owner=0 \
          --group=0 \
          --numeric-owner \
          --mtime='@1' \
          -czf "$out/${archiveName}" \
          -C "$stage" .
      '';

  mkBinaryRelease = {
    pname,
    version,
    artifacts,
  }:
    let
      archives = lib.mapAttrs (target: spec:
        mkArchive target (spec // {inherit pname version;})) artifacts;
    in {
      inherit archives;
      bundle = pkgs.symlinkJoin {
        name = "${pname}-${version}-release-bundle";
        paths = builtins.attrValues archives;
      };
    };

  mkReleaseBinaryPackage = {
    pname,
    version,
    sources,
    binaries,
    runtimeInputs ? [],
    meta ? {},
  }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      src =
        if builtins.hasAttr system sources
        then sources.${system}
        else throw "rs-harbor: no prebuilt binary release source for system '${system}'";
      expectedBinaries = requireBinaries binaries;
      binaryArgs = concatStringsSep " " (map escapeShellArg expectedBinaries);
      expectedJson = builtins.toJSON expectedBinaries;
      expectedElfMachine = expectedMachine system;
    in
      pkgs.stdenvNoCC.mkDerivation {
        pname = "${pname}-prebuilt";
        inherit version meta;
        src = null;
        dontUnpack = true;
        nativeBuildInputs = optional (runtimeInputs != []) pkgs.makeWrapper;
        installPhase = ''
          set -euo pipefail
          manifest="${src}/manifest.json"
          test -f "$manifest" || {
            echo "prebuilt release is missing manifest.json" >&2
            exit 1
          }
          ${pkgs.jq}/bin/jq -e \
            --arg name ${escapeShellArg pname} \
            --arg version ${escapeShellArg version} \
            --arg system ${escapeShellArg system} \
            --argjson binaries '${expectedJson}' \
            '(.schemaVersion == 1) and (.name == $name) and (.version == $version) and (.system == $system) and (.binaries == $binaries)' \
            "$manifest" >/dev/null || {
              echo "prebuilt release manifest does not match ${pname}-${version}-${system}" >&2
              exit 1
            }

          mkdir -p "$out/bin"
          for binary in ${binaryArgs}; do
            source="${src}/bin/$binary"
            test -x "$source" || {
              echo "prebuilt release binary is missing or not executable: $source" >&2
              exit 1
            }
            if ${pkgs.binutils}/bin/readelf -l "$source" | \
              ${pkgs.gnugrep}/bin/grep -q 'INTERP'; then
                echo "prebuilt release binary is dynamically linked: $source" >&2
                exit 1
            fi
            ${pkgs.binutils}/bin/readelf -h "$source" | \
              ${pkgs.gnugrep}/bin/grep -F ${escapeShellArg expectedElfMachine} >/dev/null || {
                echo "prebuilt release binary has the wrong ELF machine: $source" >&2
                exit 1
            }
            if ${pkgs.binutils}/bin/readelf -d "$source" | \
              ${pkgs.gnugrep}/bin/grep -q 'NEEDED'; then
                echo "prebuilt release binary has dynamic dependencies: $source" >&2
                exit 1
            fi
            install -m0755 "$source" "$out/bin/$binary"
          done
        ''
        + optionalString (runtimeInputs != []) ''
          for binary in ${binaryArgs}; do
            wrapProgram "$out/bin/$binary" \
              --prefix PATH : ${escapeShellArg (lib.makeBinPath runtimeInputs)}
          done
        '';
      };
in {
  inherit mkBinaryRelease mkReleaseBinaryPackage;
}
