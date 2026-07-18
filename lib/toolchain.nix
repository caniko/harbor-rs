# mkToolchain :: { pkgs, channel?, date?, extensions?, withRustAnalyzer?, crossTargets?, cache? }
#             -> { rustToolchain, craneLib, rawCraneLib, buildCache, crossTargets }
#
# Build a Rust toolchain + craneLib for a given pkgs set.
{crane, mkBuildCachePolicy}: {
  pkgs,
  channel ? "nightly",
  # Preserve the historical channel default for downstream stable consumers.
  # Projects that need the fleet-pinned nightly read `rust-toolchain.toml` and
  # pass its date explicitly; a stable channel has no nightly date attribute.
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
  # Compiler caching is enabled by default for every crane derivation. The
  # policy is deliberately configurable so projects with an exceptional
  # build can opt out explicitly without reintroducing hand-wrapped packages.
  cache ? {},
}:
assert pkgs.lib.assertMsg (pkgs ? rust-bin)
"rs-harbor: mkToolchain requires pkgs with rust-overlay applied (pkgs.rust-bin must exist)";
assert pkgs.lib.assertMsg (builtins.elem channel ["nightly" "stable"])
"rs-harbor: mkToolchain 'channel' must be \"nightly\" or \"stable\", got \"${channel}\"";
assert pkgs.lib.assertMsg (date == null || date == "latest" || builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" date != null)
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
    if date == null || date == "latest"
    then channelSet.latest
    else channelSet.${date};
  rustToolchain = dateSet.default.override {
    extensions = extensions';
    targets = crossTargets;
  };
  upstreamCraneLib = (crane.mkLib pkgs).overrideToolchain (_p: rustToolchain);

  patchCratesIoPathPatches = args: let
    # `cleanSourceWith` returns a source accessor whose filtered `outPath` may
    # not be realised while package arguments are still being evaluated. Read
    # Cargo.toml from its durable original source instead. Clean-source
    # accessors can also carry a stale wrapper path in their string context,
    # so classify that context and reconstruct only a proven static store path.
    # This keeps evaluation independent of prior build and store state.
    cargoTomlSource =
      if args ? src && (args.src._isLibCleanSourceWith or false)
      then args.src.origSrc
      else args.src or null;
    cargoTomlSourceStringResult =
      if cargoTomlSource != null
      then builtins.tryEval (toString cargoTomlSource)
      else {
        success = false;
        value = null;
      };
    cargoTomlSourceString =
      if cargoTomlSourceStringResult.success
      then cargoTomlSourceStringResult.value
      else null;
    cargoTomlSourceContext =
      if cargoTomlSourceString != null
      then builtins.getContext cargoTomlSourceString
      else {};
    cargoTomlSourceContextValues = builtins.attrValues cargoTomlSourceContext;
    cargoTomlSourceHasOnlyPathContext =
      cargoTomlSourceContextValues
      != []
      && builtins.all
      (context: builtins.attrNames context == ["path"] && context.path)
      cargoTomlSourceContextValues;
    cargoTomlSourcePlain =
      if cargoTomlSourceString != null
      then builtins.unsafeDiscardStringContext cargoTomlSourceString
      else null;
    cargoTomlSourceIsStorePath =
      cargoTomlSourcePlain
      != null
      && pkgs.lib.hasPrefix (builtins.storeDir + "/") cargoTomlSourcePlain;
    cargoTomlSourceIsSafe =
      cargoTomlSourceString
      != null
      && (
        builtins.isPath cargoTomlSource
        || (cargoTomlSourceHasOnlyPathContext && cargoTomlSourceIsStorePath)
      );
    cargoTomlPath =
      if builtins.isPath cargoTomlSource
      then cargoTomlSource + "/Cargo.toml"
      else if cargoTomlSourceHasOnlyPathContext && cargoTomlSourceIsStorePath
      then (/. + cargoTomlSourcePlain) + "/Cargo.toml"
      else null;
    cargoTomlRead =
      if args ? rsHarborCargoTomlContents
      then
        if builtins.isString args.rsHarborCargoTomlContents
        then {
          success = true;
          value = args.rsHarborCargoTomlContents;
        }
        else throw "rs-harbor: rsHarborCargoTomlContents must be a string"
      else if cargoTomlSource != null && !cargoTomlSourceIsSafe
      then
        throw ''
          rs-harbor: cannot safely inspect Cargo.toml from this `src` during evaluation.

          Generated derivation outputs and untracked plain-string paths would make path-patch validation depend on prior store or host state. Pass `rsHarborCargoTomlContents = builtins.readFile ./Cargo.toml` so validation has explicit source data, or pass a direct Nix path / lib.cleanSourceWith source as `src`.
        ''
      else if cargoTomlPath != null
      then builtins.tryEval (builtins.readFile cargoTomlPath)
      else {
        success = false;
        value = null;
      };
    cargoToml =
      if cargoTomlRead.success
      then builtins.fromTOML (builtins.unsafeDiscardStringContext cargoTomlRead.value)
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
    builtins.removeAttrs args [
      "rsHarborAllowPathPatchBuildDepsOnly"
      "rsHarborCargoTomlContents"
    ];

  pathPatchBuildDepsOnlyError = pathPatches: ''
    rs-harbor: refusing craneLib.buildDepsOnly for a Cargo workspace with [patch.crates-io] path patches: ${formatPathPatches pathPatches}

    Crane's dependency-only build replaces path crates with dummy sources. That is unsafe when a patched crate is used by registry dependencies, because those dependencies can compile against a dummy API and fail with misleading missing-symbol errors.

    Use craneLib.buildPackage (args // { cargoArtifacts = null; }) to build with real sources, remove the path patch, or vendor the dependency in a way that does not rely on [patch.crates-io]. If this project is known to tolerate dummy path patches, pass rsHarborAllowPathPatchBuildDepsOnly = true.
  '';

  cacheEnabled = cache.enable or true;
  buildCache =
    if cacheEnabled
    then
      mkBuildCachePolicy {
        inherit pkgs;
        buildPackageSet = pkgs.buildPackages;
        sccachePackage = cache.sccachePackage or null;
        cacheRoot = cache.cacheRoot or null;
        namespaceScope = cache.namespaceScope or "canix-rust";
        namespaceGeneration = cache.namespaceGeneration or 5;
        connectTimeout = cache.connectTimeout or "2";
        executionModel = cache.executionModel or "sandbox-local";
        redisSocketPath = cache.redisSocketPath or "/run/redis-sccache/redis.sock";
      }
    else null;

  # Keep rs-harbor's path-patch safety checks at the crane scope boundary.
  # The cache wrapper is applied in the same scope so every crane helper that
  # constructs a Cargo derivation inherits it automatically.
  craneLib =
    (upstreamCraneLib.overrideScope (_final: prev: {
    mkCargoDerivation =
      if buildCache == null
      then prev.mkCargoDerivation
      else args: buildCache.withRustCache {package = prev.mkCargoDerivation args;};

    buildDepsOnly = args: let
      allow = args.rsHarborAllowPathPatchBuildDepsOnly or false;
      pathPatches =
        if allow
        then []
        else patchCratesIoPathPatches args;
      raw =
        if pathPatches != []
        then throw (pathPatchBuildDepsOnlyError pathPatches)
        else prev.buildDepsOnly (stripRsHarborCraneArgs args);
    in
      if buildCache == null
      then raw
      else buildCache.withRustCache {package = raw;};

    buildPackage = args: let
      pathPatches =
        if args ? cargoArtifacts
        then []
        else patchCratesIoPathPatches args;
      args' = stripRsHarborCraneArgs args;
      raw = prev.buildPackage (
        if pathPatches != [] && !(args ? cargoArtifacts)
        then args' // {cargoArtifacts = null;}
        else args'
      );
    in
      if buildCache == null
      then raw
      else buildCache.withRustCache {package = raw;};
    }))
    // {
      # Dioxus and cross helpers use this marker to inherit the same policy
      # without requiring every consumer to thread it through manually.
      rsHarborBuildCachePolicy = buildCache;
    };

  rawCraneLib = upstreamCraneLib.overrideScope (_final: prev: {
    buildDepsOnly = args: let
      allow = args.rsHarborAllowPathPatchBuildDepsOnly or false;
      pathPatches =
        if allow
        then []
        else patchCratesIoPathPatches args;
    in
      if pathPatches != []
      then throw (pathPatchBuildDepsOnlyError pathPatches)
      else prev.buildDepsOnly (stripRsHarborCraneArgs args);

    buildPackage = args: let
      pathPatches =
        if args ? cargoArtifacts
        then []
        else patchCratesIoPathPatches args;
      args' = stripRsHarborCraneArgs args;
    in
      prev.buildPackage (
        if pathPatches != [] && !(args ? cargoArtifacts)
        then args' // {cargoArtifacts = null;}
        else args'
      );
  });
in {
  inherit rustToolchain craneLib rawCraneLib buildCache crossTargets;
}
