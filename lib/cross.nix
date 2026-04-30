# mkCross :: { pkgs, system, macosSdkStorePath?, sdkArchive?, macosSdk?, macosSdkOutputHash?, macosSdkEnvPath?, enableOsxcross?, osxSdkVersion? }
#         -> { mingwCC, mingwBinutils, winpthreads, windowsEnv,
#              macosSdk, osxcrossToolchain, osxcrossRustHelpers }
#
# Build cross-compilation toolchains (MinGW for Windows, osxcross for macOS).
{osxcross}: {
  pkgs,
  system,
  macosSdkStorePath ? null,
  sdkArchive ? null,
  macosSdk ? null,
  macosSdkOutputHash ? null,
  macosSdkEnvPath ? builtins.getEnv "MACOS_SDK",
  enableOsxcross ? (macosSdkStorePath != null || sdkArchive != null || macosSdk != null || macosSdkEnvPath != ""),
  osxSdkVersion ? "26.1",
}:
if
  (if macosSdk != null then 1 else 0)
  + (if macosSdkStorePath != null then 1 else 0)
  + (if sdkArchive != null then 1 else 0)
  > 1
then throw "rs-harbor.mkCross: pass only one of macosSdk, macosSdkStorePath, or sdkArchive"
else let
  lib = pkgs.lib;
  mingwCC = pkgs.pkgsCross.mingwW64.stdenv.cc;
  mingwBinutils = pkgs.pkgsCross.mingwW64.stdenv.cc.bintools.bintools;
  winpthreads = pkgs.pkgsCross.mingwW64.windows.pthreads;

  supportsOsxcross = system == "x86_64-linux";

  archiveSuffixes = [
    ".tar"
    ".tar.gz"
    ".tgz"
    ".tar.xz"
    ".txz"
    ".tar.bz2"
    ".tbz2"
  ];

  hasArchiveSuffix = value:
    lib.any (suffix: lib.hasSuffix suffix (toString value)) archiveSuffixes;

  requireAbsolutePath = context: value: let
    str = toString value;
  in
    if lib.hasPrefix "/" str
    then str
    else throw "rs-harbor.mkCross: ${context} must be an absolute path, got '${str}'";

  pathExistsAbs = value: let
    str = toString value;
  in
    lib.hasPrefix "/" str && builtins.pathExists (/. + str);

  sdkRootFor = value:
    if lib.hasSuffix ".sdk" (toString value)
    then toString value
    else "${toString value}/MacOSX${osxSdkVersion}.sdk";

  requiredSdkEntries = [
    "SDKSettings.json"
    "usr/include/TargetConditionals.h"
    "System/Library/Frameworks"
    "System/Library/Frameworks/SystemConfiguration.framework"
    "System/Library/Frameworks/CoreFoundation.framework"
  ];

  missingSdkEntries = sdkRoot:
    lib.filter (entry: !(pathExistsAbs "${toString sdkRoot}/${entry}")) requiredSdkEntries;

  validateVisibleSdkRoot = context: sdkRoot: let
    root = toString sdkRoot;
    missing = missingSdkEntries root;
  in
    if !(pathExistsAbs root)
    then root
    else if missing == []
    then root
    else
      throw ''
        rs-harbor.mkCross: ${context} is not a complete macOS SDK.
        SDK root: ${root}
        Missing required entries: ${lib.concatStringsSep ", " missing}
        Expected a real Apple SDK root such as MacOSX${osxSdkVersion}.sdk, not a fake/minimal fixture.
      '';

  mkStorePathSdkRef = storePath: let
    path = toString storePath;
    root = validateVisibleSdkRoot "macosSdkStorePath" (sdkRootFor path);
  in
    osxcross.lib.${system}.mkMacosSdkRef {
      sdk = storePath;
      sdkRoot = root;
      sdkVersion = osxSdkVersion;
    };

  mkEnvSdkRef = envPath: let
    path = requireAbsolutePath "MACOS_SDK" envPath;
    directRoot = path;
    parentRoot = "${path}/MacOSX${osxSdkVersion}.sdk";
  in
    if pathExistsAbs directRoot && lib.hasSuffix ".sdk" directRoot
    then let
      checkedSdkRoot = validateVisibleSdkRoot "MACOS_SDK direct SDK directory" directRoot;
      sdkPath = /. + path;
    in
      assert checkedSdkRoot != "";
      osxcross.lib.${system}.mkMacosSdkRef {
        sdk = sdkPath;
        sdkRoot = sdkPath;
        sdkVersion = osxSdkVersion;
      }
    else if pathExistsAbs parentRoot
    then let
      checkedSdkRoot = validateVisibleSdkRoot "MACOS_SDK parent directory" parentRoot;
      sdkParent = /. + path;
      sdkRoot = "${sdkParent}/MacOSX${osxSdkVersion}.sdk";
    in
      assert checkedSdkRoot != "";
      osxcross.lib.${system}.mkMacosSdkRef {
        sdk = sdkParent;
        inherit sdkRoot;
        sdkVersion = osxSdkVersion;
      }
    else if pathExistsAbs path && hasArchiveSuffix path
    then
      osxcross.lib.${system}.mkMacosSdk {
        sdkArchive = /. + path;
        sdkVersion = osxSdkVersion;
        outputHash = macosSdkOutputHash;
      }
    else
      throw ''
        rs-harbor.mkCross: MACOS_SDK must point to one of:
        - a MacOSX${osxSdkVersion}.sdk directory
        - a parent directory containing MacOSX${osxSdkVersion}.sdk
        - a supported SDK archive (${lib.concatStringsSep ", " archiveSuffixes})
        Got: ${path}
      '';

  effectiveMacosSdk =
    if !enableOsxcross || !supportsOsxcross
    then null
    else if macosSdk != null
    then macosSdk
    else if macosSdkStorePath != null
    then mkStorePathSdkRef macosSdkStorePath
    else if sdkArchive != null
    then
      osxcross.lib.${system}.mkMacosSdk {
        inherit sdkArchive;
        sdkVersion = osxSdkVersion;
        outputHash = macosSdkOutputHash;
      }
    else if macosSdkEnvPath != ""
    then mkEnvSdkRef macosSdkEnvPath
    else throw "rs-harbor.mkCross: enableOsxcross is true, but no macOS SDK input was provided";

  osxcrossArgs =
    {
      sdkVersion = osxSdkVersion;
    }
    // pkgs.lib.optionalAttrs (effectiveMacosSdk != null) {
      macosSdk = effectiveMacosSdk;
    };

  osxcrossToolchain =
    if enableOsxcross && supportsOsxcross
    then
      osxcross.lib.${system}.mkOsxcross osxcrossArgs
    else null;

  osxcrossRustHelpers =
    if osxcrossToolchain != null
    then osxcross.lib.${system}.mkRustHelpers osxcrossToolchain
    else null;

  # Pre-built attrset of Windows cross-compilation env vars.
  # Consumers can merge this into mkShell when needed, without
  # polluting every dev shell unconditionally.
  windowsEnv = {
    CC_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-gcc";
    CXX_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-g++";
    AR_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-ar";
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${mingwCC}/bin/x86_64-w64-mingw32-gcc";
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "-L ${winpthreads}/lib";
  };
in {
  inherit mingwCC mingwBinutils winpthreads;
  macosSdk = effectiveMacosSdk;
  inherit osxcrossToolchain osxcrossRustHelpers;
  inherit windowsEnv;
}
