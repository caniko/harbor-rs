# mkToolchain :: { pkgs, toolchainProfile?, toolchainFile?, channel?, date?, extensions?, withRustAnalyzer?, crossTargets?, targets?, cache?, rustBin?, cargoConfigArgs? }
#             -> { rustToolchain, craneLib, rawCraneLib, buildCache, cargoConfig, crossTargets }
#
# Build a Rust toolchain + craneLib for a given pkgs set.
{
  crane,
  mkCargoConfig,
  mkCargoHomeHook,
  mkBuildCachePolicy,
  # harbor-rs's own rust-overlay flake. Null only when a consumer imports
  # `lib/` directly without it; mkToolchain then needs rust-overlay on `pkgs`.
  rustOverlay ? null,
}: {
  pkgs,
  # Optional harbor-rs-owned pinned profile. Null preserves the historical
  # channel/date behavior for consumers that are not opting into fleet pins.
  toolchainProfile ? null,
  # When set, the standard rust-toolchain.toml is authoritative for the
  # compiler channel, components, and targets. The legacy channel/date mode
  # remains the default when this is null.
  toolchainFile ? null,
  channel ? null,
  # Preserve the historical channel default for downstream stable consumers.
  # Projects that need the fleet-pinned nightly read `rust-toolchain.toml` and
  # pass its date explicitly; a stable channel has no nightly date attribute.
  date ? null,
  extensions ? null,
  withRustAnalyzer ? true,
  crossTargets ? null,
  # Replaces the profile/file/legacy target list instead of extending it;
  # `[]` installs only the host standard library.
  targets ? null,
  # Compiler caching requires host transport and is therefore explicit.
  cache ? {},
  # Escape hatch: a `rust-bin` set for the build platform (for example
  # `pkgs.buildPackages.rust-bin` from the consumer's own rust-overlay) used
  # instead of harbor-rs's rust-overlay. Whoever passes it owns the
  # availability of the selected channel.
  rustBin ? null,
  # Extra mkCargoConfig arguments for the toolchain's generated Cargo config
  # (for example `parallelFrontendThreads` or `enableCranelift`). Its asserts
  # still fire, so a nightly-only knob on a stable toolchain fails evaluation.
  cargoConfigArgs ? {},
}:
assert pkgs.lib.assertMsg (targets == null || (builtins.isList targets && crossTargets == null))
"harbor-rs: mkToolchain 'targets' must be a list and cannot be combined with 'crossTargets'";
assert pkgs.lib.assertMsg (toolchainProfile == null || builtins.elem toolchainProfile ["nightly" "stable"])
"harbor-rs: mkToolchain 'toolchainProfile' must be \"nightly\" or \"stable\", got \"${toString toolchainProfile}\"";
assert pkgs.lib.assertMsg (toolchainProfile == null || (toolchainFile == null && channel == null && date == null))
"harbor-rs: mkToolchain 'toolchainProfile' cannot be combined with 'toolchainFile', 'channel', or 'date'";
assert pkgs.lib.assertMsg (toolchainFile == null || (channel == null && date == null))
"harbor-rs: mkToolchain 'toolchainFile' cannot be combined with 'channel' or 'date'";
assert pkgs.lib.assertMsg (channel == null || builtins.elem channel ["nightly" "stable"])
"harbor-rs: mkToolchain 'channel' must be \"nightly\" or \"stable\", got \"${toString channel}\"";
assert pkgs.lib.assertMsg (date == null || date == "latest" || builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" date != null)
"harbor-rs: mkToolchain 'date' must be \"latest\" or a YYYY-MM-DD string, got \"${toString date}\""; let
  profileToolchainFiles = {
    nightly = ../rust-toolchain.toml;
    stable = ../rust-toolchain-stable.toml;
  };
  resolvedToolchainFile =
    if toolchainProfile != null
    then profileToolchainFiles.${toolchainProfile}
    else toolchainFile;
  legacyExtensions =
    if extensions == null
    then ["rust-src" "rustfmt" "rustc-codegen-cranelift-preview" "llvm-tools-preview"]
    else extensions;
  legacyCrossTargets =
    if targets != null
    then targets
    else if crossTargets == null
    then [
      "x86_64-unknown-linux-gnu"
      "aarch64-unknown-linux-gnu"
      "x86_64-pc-windows-gnu"
      "x86_64-apple-darwin"
      "aarch64-apple-darwin"
    ]
    else crossTargets;
  toolchainManifest =
    if resolvedToolchainFile == null
    then {}
    else builtins.fromTOML (builtins.readFile resolvedToolchainFile);
  manifestToolchain = toolchainManifest.toolchain or {};
  manifestComponents = manifestToolchain.components or [];
  manifestTargets = manifestToolchain.targets or [];
  fileExtensions =
    manifestComponents
    ++ (
      if extensions == null
      then []
      else extensions
    )
    ++ (
      if
        withRustAnalyzer
        && !(builtins.elem "rust-analyzer" (manifestComponents
          ++ (
            if extensions == null
            then []
            else extensions
          )))
      then ["rust-analyzer"]
      else []
    );
  fileTargets =
    if targets != null
    then targets
    else
      pkgs.lib.unique (
        manifestTargets
        ++ (
          if crossTargets == null
          then []
          else crossTargets
        )
      );
  resolvedCrossTargets =
    if resolvedToolchainFile != null
    then fileTargets
    else legacyCrossTargets;
  legacyExtensions' =
    if withRustAnalyzer
    then
      if builtins.elem "rust-analyzer" legacyExtensions
      then legacyExtensions
      else legacyExtensions ++ ["rust-analyzer"]
    else legacyExtensions;
  legacyChannel =
    if channel == null
    then "nightly"
    else channel;
  legacyDate =
    if date == null
    then "latest"
    else date;
  manifestChannel = manifestToolchain.channel or "";
  cargoChannel =
    if resolvedToolchainFile == null
    then legacyChannel
    else if builtins.match "nightly.*" manifestChannel != null
    then "nightly"
    else "stable";
  resolvedToolchainManifest =
    if resolvedToolchainFile != null
    then manifestToolchain
    else {
      channel =
        if legacyChannel == "nightly" && legacyDate != "latest"
        then "nightly-${legacyDate}"
        else legacyChannel;
      components = legacyExtensions';
      targets = legacyCrossTargets;
    };
  # Cargo/rustc run on the build platform; only their standard libraries target
  # the host. Selecting the host package set here runs ARM tools under emulation.
  #
  # Channels resolve through harbor-rs's own rust-overlay, never one the
  # consumer applied to `pkgs`: an older consumer overlay cannot make the
  # pinned profile channels unavailable.
  rustBin' =
    if rustBin != null
    then rustBin
    else if rustOverlay != null
    then rustOverlay.lib.mkRustBin {} pkgs.buildPackages
    else
      assert pkgs.lib.assertMsg (pkgs.buildPackages ? rust-bin)
      "harbor-rs: mkToolchain needs rust-overlay: import lib/ with 'rustOverlay', pass 'rustBin', or apply rust-overlay to the build package set (pkgs.buildPackages.rust-bin)";
        pkgs.buildPackages.rust-bin;
  channelSet =
    if legacyChannel == "nightly"
    then rustBin'.nightly
    else rustBin'.stable;
  dateSet =
    if legacyDate == "latest"
    then channelSet.latest
    else channelSet.${legacyDate};
  rustToolchain =
    if resolvedToolchainFile != null
    then
      assert pkgs.lib.assertMsg (manifestToolchain ? channel)
      "harbor-rs: mkToolchain 'toolchainFile' must contain [toolchain].channel";
        (rustBin'.fromRustupToolchainFile resolvedToolchainFile).override ({
            extensions = fileExtensions;
            targets = fileTargets;
          }
          # rust-overlay turns cargo's libsecret integration off for the
          # minimal profile. Keep the previous default-profile behavior for
          # harbor-rs's own profile files, so they only drop rust-docs; a
          # consumer's toolchain file keeps its own profile's default. Key on
          # the file, not toolchainProfile: cross builds re-call mkToolchain
          # with only toolchainFile and must get the same toolchain.
          // pkgs.lib.optionalAttrs (builtins.elem resolvedToolchainFile (builtins.attrValues profileToolchainFiles)) {
            enableLibsecret = pkgs.buildPackages.stdenv.hostPlatform.isLinux;
          })
    else
      dateSet.default.override {
        extensions = legacyExtensions';
        targets = legacyCrossTargets;
      };
  toolchainArgs =
    (
      if resolvedToolchainFile != null
      then {toolchainFile = resolvedToolchainFile;}
      else {
        channel = legacyChannel;
        date = legacyDate;
      }
    )
    // pkgs.lib.optionalAttrs (extensions != null) {inherit extensions;}
    // pkgs.lib.optionalAttrs (rustBin != null) {inherit rustBin;}
    // pkgs.lib.optionalAttrs (!withRustAnalyzer) {withRustAnalyzer = false;};
  cargoConfig = mkCargoConfig ({
      inherit pkgs;
      channel = cargoChannel;
      crossTargets = resolvedCrossTargets;
    }
    // cargoConfigArgs);
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
        else throw "harbor-rs: rsHarborCargoTomlContents must be a string"
      else if cargoTomlSource != null && !cargoTomlSourceIsSafe
      then
        throw ''
          harbor-rs: cannot safely inspect Cargo.toml from this `src` during evaluation.

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
      "rsHarborCargoConfig"
      "rsHarborCargoTomlContents"
      "rsHarborCacheReuseKey"
      "stdenv"
    ];

  # Crane deprecated per-derivation `stdenv=`; apply it on craneLib instead.
  cranePrevFor = prev: args:
    if !(args ? stdenv)
    then prev
    else
      upstreamCraneLib.overrideScope (_: _: {
        stdenvSelector =
          if pkgs.lib.isFunction args.stdenv
          then args.stdenv
          else _: args.stdenv;
      });

  pathPatchBuildDepsOnlyError = pathPatches: ''
    harbor-rs: refusing craneLib.buildDepsOnly for a Cargo workspace with [patch.crates-io] path patches: ${formatPathPatches pathPatches}

    Crane's dependency-only build replaces path crates with dummy sources. That is unsafe when a patched crate is used by registry dependencies, because those dependencies can compile against a dummy API and fail with misleading missing-symbol errors.

    harbor-rs keeps the patched crates real automatically when `src` is a direct Nix path or lib.cleanSourceWith source, every patch path lies inside it, and neither `dummySrc` nor `rsHarborCargoTomlContents` is passed. Otherwise use craneLib.buildPackage (args // { cargoArtifacts = null; }) to build with real sources, or, if this project is known to tolerate dummy path patches, pass rsHarborAllowPathPatchBuildDepsOnly = true.
  '';

  # Arguments for Crane's buildDepsOnly. Crane dummifies every workspace
  # crate; registry crates may compile against a [patch.crates-io] path crate,
  # so those directories stay real. They are copied from a source filtered to
  # the patch directories alone, and vendoring reads the real `src`, so the
  # dependency derivation changes only with Cargo manifests, Cargo.lock and the
  # patched crates, and evaluation never reads the built dummy source (IFD).
  buildDepsOnlyArgs = prev: args: let
    pathPatches =
      if args.rsHarborAllowPathPatchBuildDepsOnly or false
      then []
      else patchCratesIoPathPatches args;
    dirs = builtins.map (patch: pkgs.lib.removeSuffix "/" (pkgs.lib.removePrefix "./" patch.path)) pathPatches;
    supported =
      args ? src
      && !(args ? dummySrc)
      && !(args ? rsHarborCargoTomlContents)
      && builtins.all (dir: dir != "" && dir != "." && !(pkgs.lib.hasPrefix "/" dir) && !(builtins.elem ".." (pkgs.lib.splitString "/" dir))) dirs;
    root =
      toString (
        if args.src._isLibCleanSourceWith or false
        then args.src.origSrc
        else args.src
      )
      + "/";
    patchSrc = pkgs.lib.cleanSourceWith {
      inherit (args) src;
      name = "path-patches";
      filter = path: _type: let
        rel = pkgs.lib.removePrefix root path;
      in
        builtins.any (dir: rel == dir || pkgs.lib.hasPrefix "${dir}/" rel || pkgs.lib.hasPrefix "${rel}/" dir) dirs;
    };
    copyPatches =
      pkgs.lib.concatMapStrings (dir: let
        target = "\"$out\"/${pkgs.lib.escapeShellArg dir}";
      in ''
        rm -rf ${target}
        mkdir -p "$(dirname ${target})"
        cp -r --no-preserve=mode ${patchSrc}/${pkgs.lib.escapeShellArg dir} ${target}
      '')
      dirs;
  in
    stripRsHarborCraneArgs (
      if pathPatches == []
      then args
      else if !supported
      then throw (pathPatchBuildDepsOnlyError pathPatches)
      else
        builtins.removeAttrs args ["src"]
        // {
          dummySrc = prev.mkDummySrc (args // {extraDummyScript = (args.extraDummyScript or "") + "\n" + copyPatches;});
          cargoVendorDir = args.cargoVendorDir or (prev.vendorCargoDeps args);
          pname = args.pname or (prev.crateNameFromCargoToml args).pname;
          version = args.version or (prev.crateNameFromCargoToml args).version;
        }
    );

  cacheEnabled = cache.enable or false;
  buildCache =
    if cacheEnabled
    then
      mkBuildCachePolicy {
        inherit pkgs;
        compiler = rustToolchain.version;
        toolchainManifest = resolvedToolchainManifest;
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

  # Keep harbor-rs's path-patch safety checks at the crane scope boundary.
  # The cache wrapper is applied in the same scope so every crane helper that
  # constructs a Cargo derivation inherits it automatically.
  craneLib =
    (upstreamCraneLib.overrideScope (_final: prev: {
      # Every dev shell built from this craneLib installs the generated Cargo
      # config, so consumers that call `craneLib.devShell` directly get it
      # without wiring mkDevShell. `rsHarborCargoConfig = false` opts out; a
      # mkCargoConfig result replaces the toolchain's config.
      devShell = args: let
        config =
          if args ? rsHarborCargoConfig
          then args.rsHarborCargoConfig
          else cargoConfig;
        devShellConfig =
          if config == false
          then null
          else config;
        args' = stripRsHarborCraneArgs args;
      in
        (cranePrevFor prev args).devShell (args'
          // {
            shellHook =
              mkCargoHomeHook {
                # The hook runs on the build machine, also for cross package sets.
                pkgs = pkgs.buildPackages;
                cargoConfig = devShellConfig;
              }
              + (args'.shellHook or "");
            packages =
              (
                if devShellConfig == null
                then []
                else devShellConfig.packages or []
              )
              ++ (args'.packages or []);
          });

      mkCargoDerivation = args: let
        raw = (cranePrevFor prev args).mkCargoDerivation (stripRsHarborCraneArgs args);
      in
        if buildCache == null
        then raw
        else buildCache.withRustCache {package = raw;};

      buildDepsOnly = args: let
        raw = (cranePrevFor prev args).buildDepsOnly (buildDepsOnlyArgs prev args);
      in
        if buildCache == null
        then raw
        else
          buildCache.withRustCache {
            package = raw;
            telemetry = {
              workloadKind = "dependency-artifacts";
              reuseKey = args.rsHarborCacheReuseKey or "";
            };
          };

      buildPackage = args: let
        pathPatches =
          if args ? cargoArtifacts
          then []
          else patchCratesIoPathPatches args;
        args' = stripRsHarborCraneArgs args;
        raw = (cranePrevFor prev args).buildPackage (
          if pathPatches != [] && !(args ? cargoArtifacts)
          then args' // {cargoArtifacts = null;}
          else args'
        );
      in
        if buildCache == null
        then raw
        else
          buildCache.withRustCache {
            package = raw;
            telemetry = {
              workloadKind = "package";
              reuseKey = args.rsHarborCacheReuseKey or "";
            };
          };
    }))
    // {
      # Dioxus and cross helpers use these markers to inherit the same policy
      # without requiring every consumer to thread it through manually.
      rsHarborBuildCachePolicy = buildCache;
      rsHarborCargoConfig = cargoConfig;
      rsHarborToolchainArgs = toolchainArgs;
      rsHarborToolchainFile = resolvedToolchainFile;
      rsHarborToolchainProfile = toolchainProfile;
    };

  rawCraneLib = upstreamCraneLib.overrideScope (_final: prev: {
    buildDepsOnly = args: (cranePrevFor prev args).buildDepsOnly (buildDepsOnlyArgs prev args);

    buildPackage = args: let
      pathPatches =
        if args ? cargoArtifacts
        then []
        else patchCratesIoPathPatches args;
      args' = stripRsHarborCraneArgs args;
    in
      (cranePrevFor prev args).buildPackage (
        if pathPatches != [] && !(args ? cargoArtifacts)
        then args' // {cargoArtifacts = null;}
        else args'
      );
  });
in {
  inherit rustToolchain craneLib rawCraneLib buildCache cargoConfig toolchainArgs;
  inherit toolchainProfile resolvedToolchainFile resolvedToolchainManifest;
  crossTargets = resolvedCrossTargets;
}
