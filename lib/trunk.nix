# mkTrunkPackage :: {
#   pkgs, src, cargoLock, pname,
#   craneLib ?, cargoExtraArgs ? "",
#   nativeBuildInputs ? [], ...
# } -> derivation
#
# Build a WASM front-end distribution with trunk.
#
# Two modes:
#   1. Pragmatic (omitted craneLib): auto-creates a wasm-capable
#      craneLib via mkWasmToolchain.
#   2. Modular (supplied craneLib): uses the caller's craneLib
#      directly — caller must ensure wasm32-unknown-unknown is
#      in the toolchain targets.
#
# Cargo.lock is parsed to auto-select the matching
# wasm-bindgen-cli from nixpkgs.
{crane}: {
  src,
  pkgs,
  cargoLock,
  pname,
  version ? "0.1.0",
  craneLib ? null,
  cargoExtraArgs ? "",
  nativeBuildInputs ? [],
  ...
} @ args:
let
  lib = pkgs.lib;
  inherit (lib) hasSuffix concatStringsSep;

  lockPath =
    if builtins.isPath cargoLock
    then cargoLock
    else cargoLock.lockFile or cargoLock;

  # Extract wasm-bindgen version from Cargo.lock.
  # Scans for the [[package]] block with name = "wasm-bindgen".
  lockContent = builtins.readFile lockPath;
  lockLines = lib.splitString "\n" lockContent;

  wasmBindgenNameLine = builtins.head (
    builtins.filter (
      line: builtins.match "name = \"wasm-bindgen\"" line != null
    ) lockLines
  );

  wasmBindgenVersion =
    if wasmBindgenNameLine != null
    then let
      # Find the first [[package]] above the wasm-bindgen line, then find
      # version = "X.Y.Z" in the lines between that header and the next header.
      wasmBindgenIdx = let
        findIdx = lines: idx:
          if lines == [] then -1
          else if builtins.match "name = \"wasm-bindgen\"" (builtins.head lines) != null
          then idx
          else findIdx (builtins.tail lines) (idx + 1);
      in findIdx lockLines 0;

      # Walk backward to find the [[package]] header, then forward
      # from there to find version = "X.Y.Z".
      blockStart = let
        back = lines: idx:
          if idx < 0 then 0
          else if builtins.match "\[\[package\]\]" (builtins.elemAt lines idx) != null
          then idx
          else back lines (idx - 1);
      in back lockLines (wasmBindgenIdx - 1);

      # Scan from blockStart to next [[package]] for version line
      blockEnd = let
        fwd = lines: idx:
          if idx >= builtins.length lines then builtins.length lines
          else if idx != blockStart && builtins.match "\[\[package\]\]" (builtins.elemAt lines idx) != null
          then idx
          else fwd lines (idx + 1);
      in fwd lockLines (blockStart + 1);

      blockLines = lib.sublist blockStart (blockEnd - blockStart) lockLines;
      versionLine = builtins.head (
        builtins.filter (
          line: builtins.match "version = \".*\"" line != null
        ) blockLines
      );
    in
      if versionLine != null
      then let
        matched = builtins.match "version = \"(.*)\"" versionLine;
      in
        if matched != null then builtins.head matched else ""
      else ""
    else "";

  # Map wasm-bindgen version string to nixpkgs attribute name
  # "0.2.120" -> "wasm-bindgen-cli_0_2_120"
  versionToAttr = ver: let
    parts = lib.splitString "." ver;
    major = builtins.head parts;
    minor = if builtins.length parts > 1 then builtins.elemAt parts 1 else "0";
    patch = if builtins.length parts > 2 then builtins.elemAt parts 2 else "0";
    attr = "wasm-bindgen-cli_${major}_${minor}_${patch}";
  in attr;

  resolvedCli = let
    exactAttr = versionToAttr wasmBindgenVersion;
    hasExact = wasmBindgenVersion != "" && pkgs ? ${exactAttr};
  in
    if wasmBindgenVersion == ""
    then pkgs.wasm-bindgen-cli
    else if hasExact
    then pkgs.${exactAttr}
    else let
      available = builtins.filter (
        n: builtins.match "wasm-bindgen-cli_.*" n != null
      ) (builtins.attrNames pkgs);
      fallback = lib.optional (pkgs ? wasm-bindgen-cli) pkgs.wasm-bindgen-cli;
    in
      if fallback != []
      then builtins.head fallback
      else throw "rs-harbor.mkTrunkPackage: Cargo.lock requires wasm-bindgen ${wasmBindgenVersion} (attr ${exactAttr}), but nixpkgs has none of: ${concatStringsSep ", " available}";

  effectiveCraneLib =
    if craneLib != null
    then craneLib
    else (import ./wasm-toolchain.nix {inherit crane pkgs;}).craneLib;

  cleanWasmSrc = lib.cleanSourceWith {
    inherit src;
    filter = path: type:
      (effectiveCraneLib.filterCargoSources path type)
      || (builtins.any (suffix: hasSuffix suffix (toString path)) [
        ".html" ".css" ".js" "Trunk.toml"
      ]);
    name = "${pname}-wasm-src";
  };

  extraArgs = builtins.removeAttrs args [
    "src" "pkgs" "cargoLock" "pname" "version" "craneLib"
    "cargoExtraArgs" "nativeBuildInputs"
  ];
in
  effectiveCraneLib.buildTrunkPackage ({
    src = cleanWasmSrc;
    inherit pname version;
    cargoLock = lockPath;
    cargoExtraArgs = cargoExtraArgs;
    wasm-bindgen-cli = resolvedCli;
    nativeBuildInputs = nativeBuildInputs ++ [pkgs.nodejs pkgs.tailwindcss_4];
  } // extraArgs)
