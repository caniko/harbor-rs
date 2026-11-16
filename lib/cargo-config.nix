# mkCargoConfig :: { pkgs, channel?, ... } -> { configText, configPath, packages }
#
# Generate optimized .cargo/config.toml content for fast Rust builds.
# Configures mold linker (Linux), lld (Windows), optional cranelift dev backend,
# share-generics, memory-saving dev profile defaults, and optional dev codegen-
# units tuning. All nightly-only features auto-disable on stable.
#
# enableDevProfileOpts controls debug-info reductions that lower peak memory
# without changing Cargo's codegen-unit default. devCodegenUnits is separate
# because lowering codegen-units is a measured wall-clock/RSS tradeoff, not a
# pure memory win for every workspace.
{
  pkgs,
  channel ? "nightly",
  crossTargets ? [
    "x86_64-unknown-linux-gnu"
    "aarch64-unknown-linux-gnu"
    "x86_64-pc-windows-gnu"
    "x86_64-apple-darwin"
    "aarch64-apple-darwin"
  ],
  # true: mold on every Linux triple. false: never. null: rust-lld, the
  # default for x86_64-unknown-linux-gnu, everywhere else.
  enableMold ? true,
  # Cranelift cannot yet honor LLVM's \x01 no-mangle marker used by some FFI bindings.
  enableCranelift ? false,
  enableShareGenerics ? (channel == "nightly"),
  enableParallelFrontend ? (channel == "nightly"),
  # Defaults from the 2026-11-15 compile-bench (harbor-rs docs, cargo-config):
  # the hint cut clean builds 23-33% and 8 threads beat one per core.
  enableHintMostlyUnused ? (channel == "nightly"),
  parallelFrontendThreads ? 8,
  enableDevProfileOpts ? true,
  devCodegenUnits ? null,
  devBuildOverrideOptLevel ? null,
  extraConfig ? "",
}:
assert pkgs.lib.assertMsg (builtins.elem channel ["nightly" "stable"])
"harbor-rs: mkCargoConfig 'channel' must be \"nightly\" or \"stable\", got \"${channel}\"";
assert pkgs.lib.assertMsg (!enableCranelift || channel == "nightly")
"harbor-rs: mkCargoConfig 'enableCranelift' requires channel=\"nightly\"";
assert pkgs.lib.assertMsg (!enableShareGenerics || channel == "nightly")
"harbor-rs: mkCargoConfig 'enableShareGenerics' requires channel=\"nightly\"";
assert pkgs.lib.assertMsg (!enableParallelFrontend || channel == "nightly")
"harbor-rs: mkCargoConfig 'enableParallelFrontend' requires channel=\"nightly\"";
assert pkgs.lib.assertMsg (!enableHintMostlyUnused || channel == "nightly")
"harbor-rs: mkCargoConfig 'enableHintMostlyUnused' requires channel=\"nightly\"";
assert pkgs.lib.assertMsg (builtins.isBool enableMold || enableMold == null)
"harbor-rs: mkCargoConfig 'enableMold' must be true, false or null";
assert pkgs.lib.assertMsg (builtins.isInt parallelFrontendThreads && parallelFrontendThreads >= 0)
"harbor-rs: mkCargoConfig 'parallelFrontendThreads' must be a non-negative integer";
assert pkgs.lib.assertMsg (builtins.isList crossTargets)
"harbor-rs: mkCargoConfig 'crossTargets' must be a list of target triples";
assert pkgs.lib.assertMsg (devCodegenUnits == null || (builtins.isInt devCodegenUnits && devCodegenUnits > 0))
"harbor-rs: mkCargoConfig 'devCodegenUnits' must be null or a positive integer";
assert pkgs.lib.assertMsg (
  devBuildOverrideOptLevel
  == null
  || (builtins.isInt devBuildOverrideOptLevel && devBuildOverrideOptLevel >= 0 && devBuildOverrideOptLevel <= 3)
)
"harbor-rs: mkCargoConfig 'devBuildOverrideOptLevel' must be null or 0-3"; let
  inherit (pkgs.lib) concatStringsSep hasInfix optionalString;
  inherit (builtins) filter length;

  # Android targets use the NDK linker even though their triples contain linux.
  isLinux = t: hasInfix "-linux-" t && !(hasInfix "-android" t);
  isDarwin = t: hasInfix "-apple-darwin" t;

  # rustc already defaults x86_64-unknown-linux-gnu to rust-lld (F11).
  moldFor = triple:
    isLinux triple
    && (enableMold == true || (enableMold == null && triple != "x86_64-unknown-linux-gnu"));

  # Build rustflags array string from a list of flag pairs/singles
  mkRustflags = flags:
    if length flags == 0
    then ""
    else "rustflags = [${concatStringsSep ", " (map (f: "\"${f}\"") flags)}]\n";

  # Generate a [target.<triple>] section
  mkTargetSection = triple: let
    moldFlags =
      if moldFor triple
      then ["-C" "link-arg=-fuse-ld=mold"]
      else [];
    shareGenFlags =
      if enableShareGenerics && (isLinux triple || isDarwin triple)
      then ["-Zshare-generics=y"]
      else [];
    parallelFlags =
      if enableParallelFrontend
      then ["-Zthreads=${toString parallelFrontendThreads}"]
      else [];
    # Do not force `-fuse-ld=lld` for MinGW/GNU Windows targets. When Rust
    # links through the GCC wrapper provided by pkgsCross.mingwW64, that path
    # can inject unsupported PIE arguments into lld and fail the final link.
    allFlags = moldFlags ++ shareGenFlags ++ parallelFlags;
    linkerLine =
      optionalString (moldFor triple) "linker = \"clang\"\n";
    flagsLine = mkRustflags allFlags;
  in
    if linkerLine == "" && flagsLine == ""
    then ""
    else "[target.${triple}]\n${linkerLine}${flagsLine}";

  targetSections = concatStringsSep "\n" (filter (s: s != "") (map mkTargetSection (pkgs.lib.unique crossTargets)));

  # Exactly one [unstable] table: cranelift and the upstream
  # `[hints] mostly-unused` opt-in both write it.
  unstableLines =
    optionalStringList enableCranelift ["codegen-backend = true"]
    ++ optionalStringList enableHintMostlyUnused ["profile-hint-mostly-unused = true"];

  unstableSection =
    if unstableLines == []
    then ""
    else concatStringsSep "\n" (["[unstable]"] ++ unstableLines ++ [""]);

  optionalStringList = cond: list:
    if cond
    then list
    else [];

  codegenUnitsLines =
    if devCodegenUnits == null
    then []
    else ["codegen-units = ${toString devCodegenUnits}"];

  # Keys of [profile.dev.package."*"]; an empty table is not emitted.
  devPackageLines =
    optionalStringList enableCranelift [''codegen-backend = "llvm"'']
    ++ optionalStringList enableDevProfileOpts ["debug = false"];

  devLines =
    optionalStringList enableCranelift [''codegen-backend = "cranelift"'']
    ++ optionalStringList enableDevProfileOpts [
      ''debug = "line-tables-only"''
      ''split-debuginfo = "unpacked"''
    ]
    ++ codegenUnitsLines;

  # Exactly one [profile.dev] table: cranelift, the dev-profile opts and
  # codegen-units all contribute keys to the same table.
  devProfileSection = concatStringsSep "\n" (
    optionalStringList (devLines != []) (["[profile.dev]"] ++ devLines ++ [""])
    ++ optionalStringList (devBuildOverrideOptLevel != null) [
      "[profile.dev.build-override]"
      "opt-level = ${toString devBuildOverrideOptLevel}"
      ""
    ]
    ++ optionalStringList (devPackageLines != []) (
      [''[profile.dev.package."*"]''] ++ devPackageLines ++ [""]
    )
  );

  header = "# Generated by harbor-rs — https://github.com/caniko/harbor-rs\n# Optimized Cargo configuration for fast Rust builds\n";

  configText =
    header
    + optionalString (targetSections != "") "\n${targetSections}"
    + optionalString (unstableSection != "") "\n${unstableSection}"
    + optionalString (devProfileSection != "") "\n${devProfileSection}"
    + optionalString (extraConfig != "") "\n${extraConfig}\n";
in {
  inherit configText;
  configPath = pkgs.writeText "cargo-config.toml" configText;
  # Shell packages the config needs: the clang driver and mold, but only when
  # an emitted target section actually selects mold.
  packages =
    if builtins.any moldFor (pkgs.lib.unique crossTargets)
    then [pkgs.clang pkgs.mold]
    else [];
}
