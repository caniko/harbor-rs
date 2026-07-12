# mkToolchain :: { pkgs, channel?, date?, extensions?, withRustAnalyzer?, crossTargets? }
#             -> { rustToolchain, craneLib, crossTargets }
#
# Build a Rust toolchain + craneLib for a given pkgs set.
{crane}: {
  pkgs,
  channel ? "nightly",
  date ? "latest",
  extensions ? ["rust-src" "rustfmt" "rustc-codegen-cranelift-preview" "llvm-tools-preview"],
  withRustAnalyzer ? true,
  crossTargets ? [
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
    "x86_64-pc-windows-gnu"
    "x86_64-apple-darwin"
    "aarch64-apple-darwin"
  ],
}:
assert pkgs.lib.assertMsg (pkgs ? rust-bin)
"rs-harbor: mkToolchain requires pkgs with rust-overlay applied (pkgs.rust-bin must exist)";
assert pkgs.lib.assertMsg (builtins.elem channel ["nightly" "stable"])
"rs-harbor: mkToolchain 'channel' must be \"nightly\" or \"stable\", got \"${channel}\"";
assert pkgs.lib.assertMsg (date == "latest" || builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" date != null)
"rs-harbor: mkToolchain 'date' must be \"latest\" or a YYYY-MM-DD string, got \"${date}\""; let
  extensions' =
    if withRustAnalyzer
    then
      if builtins.elem "rust-analyzer" extensions
      then extensions
      else extensions ++ ["rust-analyzer"]
    else extensions;
  channelSet =
    if channel == "nightly"
    then pkgs.rust-bin.nightly
    else pkgs.rust-bin.stable;
  dateSet =
    if date == "latest"
    then channelSet.latest
    else channelSet.${date};
  rustToolchain = dateSet.default.override {
    extensions = extensions';
    targets = crossTargets;
  };
  upstreamCraneLib = (crane.mkLib pkgs).overrideToolchain (_p: rustToolchain);

  patchCratesIoPathPatches = args: let
    cargoTomlPath =
      if args ? src
      then "${args.src}/Cargo.toml"
      else null;
    cargoTomlText =
      if cargoTomlPath != null
      then builtins.tryEval (builtins.readFile cargoTomlPath)
      else {success = false;};
    cargoToml =
      if cargoTomlText.success
      then builtins.fromTOML cargoTomlText.value
      else {};
    cratesIoPatches = cargoToml.patch."crates-io" or {};
    patchNames = builtins.attrNames cratesIoPatches;
    pathPatchNames = builtins.filter (name: (cratesIoPatches.${name} ? path)) patchNames;
  in
    builtins.map (name: {
      inherit name;
      path = cratesIoPatches.${name}.path;
    })
    pathPatchNames;

  formatPathPatches = pathPatches:
    pkgs.lib.concatStringsSep ", " (
      builtins.map (patch: "${patch.name} -> ${patch.path}") pathPatches
    );

  stripRsHarborCraneArgs = args:
    builtins.removeAttrs args ["rsHarborAllowPathPatchBuildDepsOnly"];

  pathPatchBuildDepsOnlyError = pathPatches: ''
    rs-harbor: refusing craneLib.buildDepsOnly for a Cargo workspace with [patch.crates-io] path patches: ${formatPathPatches pathPatches}

    Crane's dependency-only build replaces path crates with dummy sources. That is unsafe when a patched crate is used by registry dependencies, because those dependencies can compile against a dummy API and fail with misleading missing-symbol errors.

    Use craneLib.buildPackage (args // { cargoArtifacts = null; }) to build with real sources, remove the path patch, or vendor the dependency in a way that does not rely on [patch.crates-io]. If this project is known to tolerate dummy path patches, pass rsHarborAllowPathPatchBuildDepsOnly = true.
  '';

  craneLib =
    upstreamCraneLib
    // {
      buildDepsOnly = args: let
        pathPatches = patchCratesIoPathPatches args;
        allow = args.rsHarborAllowPathPatchBuildDepsOnly or false;
      in
        if pathPatches != [] && !allow
        then throw (pathPatchBuildDepsOnlyError pathPatches)
        else upstreamCraneLib.buildDepsOnly (stripRsHarborCraneArgs args);

      buildPackage = args: let
        pathPatches = patchCratesIoPathPatches args;
        args' = stripRsHarborCraneArgs args;
      in
        upstreamCraneLib.buildPackage (
          if pathPatches != [] && !(args ? cargoArtifacts)
          then args' // {cargoArtifacts = null;}
          else args'
        );
    };
in {
  inherit rustToolchain craneLib crossTargets;
}
