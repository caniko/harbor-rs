# cargo-binstall metadata derived from release bundle descriptors, so
# `cargo binstall <crate>` fetches the archives harbor-rs publishes instead of
# compiling. The archive name contract stays here, next to the producers.
{lib}: let
  pkgFmt = {
    "tar.gz" = "tgz";
    zip = "zip";
  };
  binaryKinds = ["binary" "binary-archive" "portable-binary-archive"];
  # Static and nix-bundle Linux executables run on glibc and musl hosts alike.
  libcIndependent = ["static-archive" "static-elf" "portable-executable"];

  rustTargets = archive: let
    parts = lib.splitString "-" archive.system;
    arch = lib.head parts;
    os = lib.last parts;
    own = lib.optional (archive.rustTarget != null) archive.rustTarget;
  in
    if os == "linux"
    then
      if builtins.elem archive.validation libcIndependent || lib.hasSuffix "-musl" (toString archive.rustTarget)
      then ["${arch}-unknown-linux-gnu" "${arch}-unknown-linux-musl"]
      else if own != []
      then own
      else ["${arch}-unknown-linux-gnu"]
    else if os == "windows"
    then lib.unique (["${arch}-pc-windows-msvc" "${arch}-pc-windows-gnu"] ++ own)
    else if os == "darwin"
    then ["${arch}-apple-darwin"]
    else throw "harbor-rs: binstall has no Rust target mapping for system '${archive.system}'";

  # Archives without recorded binaries (hand-made mkReleaseArtifact) are
  # assumed to use the harbor `bin/` layout.
  binDir = archive: let
    dirs = lib.unique (map dirOf (
      if archive.binaries == null || archive.binaries == []
      then ["bin/_"]
      else archive.binaries
    ));
    dir = lib.head dirs;
  in
    assert lib.assertMsg (lib.length dirs == 1) "harbor-rs: binstall needs all binaries of ${archive.name} in one directory";
      lib.optionalString (dir != ".") "${dir}/" + "{ bin }{ binary-ext }";

  binaryArchives = builtins.filter (artifact:
    builtins.elem artifact.kind binaryKinds
    && pkgFmt ? ${artifact.format}
    && artifact.system != null);

  # `tagPrefix` matches simit's release tag (bare `<version>` by default).
  mkBinstallMetadata = {
    version,
    archives,
    tagPrefix ? "",
  }: let
    entries = lib.concatMap (archive:
      map (target:
        lib.nameValuePair target {
          pkg-url = "{ repo }/releases/download/${tagPrefix}{ version }/${lib.replaceStrings [version] ["{ version }"] archive.name}";
          pkg-fmt = pkgFmt.${archive.format};
          bin-dir = binDir archive;
        })
      (rustTargets archive))
    archives;
    targets = map (entry: entry.name) entries;
  in
    assert lib.assertMsg (archives != []) "harbor-rs: binstall metadata needs at least one binary archive";
    assert lib.assertMsg (lib.length targets == lib.length (lib.unique targets))
    "harbor-rs: two binstall archives serve the same Rust target"; {
      overrides = lib.listToAttrs entries;
    };

  toToml = metadata:
    lib.concatStrings (lib.mapAttrsToList (target: o: ''
        [package.metadata.binstall.overrides.${target}]
        pkg-url = ${builtins.toJSON o.pkg-url}
        pkg-fmt = ${builtins.toJSON o.pkg-fmt}
        bin-dir = ${builtins.toJSON o.bin-dir}
      '')
      metadata.overrides);

  # `[[bin]]` targets without required features must ship in every archive; a
  # crate without explicit bins installs its package name.
  crateBins = cargoToml: let
    manifest = builtins.fromTOML (builtins.readFile cargoToml);
    package = manifest.package or {};
  in
    map (bin: bin.name) (builtins.filter (bin: (bin.required-features or []) == []) (manifest.bin or [{name = package.name or "";}]));

  # Fails (without breaking evaluation) until the crate manifest carries the
  # bundle's metadata verbatim and every archive ships each required binary,
  # which binstall otherwise rejects at install time. `toml` is the block to paste.
  mkBinstallCheck = {
    pkgs,
    bundle,
    cargoToml,
  }: let
    manifest = builtins.fromTOML (builtins.readFile cargoToml);
    package = manifest.package or {};
    toml = toToml bundle.binstall;
    bins = crateBins cargoToml;
    missing = lib.concatMap (archive: let
      shipped = map baseNameOf archive.binaries;
      ext = lib.optionalString (lib.hasSuffix "-windows" archive.system) ".exe";
    in
      if archive.binaries == null
      then ["${archive.name} records no binaries; pass binaries to mkReleaseArtifact"]
      else map (bin: "${archive.name} lacks ${bin}${ext}") (builtins.filter (bin: !(builtins.elem "${bin}${ext}" shipped)) bins))
    bundle.binstallArchives;
    matches = package ? repository && (package.metadata.binstall or null) == bundle.binstall && missing == [];
  in
    pkgs.runCommand "binstall-metadata-check" {
      passthru = {inherit toml matches missing;};
      expected = toml;
      passAsFile = ["expected"];
    } (
      if matches
      then "touch $out"
      else ''
        echo ${lib.escapeShellArg (lib.concatStringsSep "\n" missing)} >&2
        echo "${toString cargoToml}: needs package.repository and exactly this [package.metadata.binstall]:" >&2
        cat "$expectedPath" >&2
        exit 1
      ''
    );
in {
  inherit binaryArchives crateBins mkBinstallMetadata mkBinstallCheck;
}
