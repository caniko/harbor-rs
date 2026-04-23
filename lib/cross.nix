# mkCross :: { pkgs, system, macosSdkStorePath?, sdkArchive?, macosSdk?, macosSdkOutputHash?, enableOsxcross?, osxSdkVersion? }
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
  enableOsxcross ? (macosSdkStorePath != null || sdkArchive != null || macosSdk != null || builtins.getEnv "MACOS_SDK" != ""),
  osxSdkVersion ? "26.1",
}:
if
  (if macosSdk != null then 1 else 0)
  + (if macosSdkStorePath != null then 1 else 0)
  + (if sdkArchive != null then 1 else 0)
  > 1
then throw "rs-harbor.mkCross: pass only one of macosSdk, macosSdkStorePath, or sdkArchive"
else let
  mingwCC = pkgs.pkgsCross.mingwW64.stdenv.cc;
  mingwBinutils = pkgs.pkgsCross.mingwW64.stdenv.cc.bintools.bintools;
  winpthreads = pkgs.pkgsCross.mingwW64.windows.pthreads;

  supportsOsxcross = system == "x86_64-linux";

  effectiveMacosSdk =
    if !enableOsxcross || !supportsOsxcross
    then null
    else if macosSdk != null
    then macosSdk
    else if macosSdkStorePath != null
    then
      osxcross.lib.${system}.mkMacosSdkRef {
        sdk = macosSdkStorePath;
        sdkVersion = osxSdkVersion;
      }
    else if sdkArchive != null
    then
      osxcross.lib.${system}.mkMacosSdk {
        inherit sdkArchive;
        sdkVersion = osxSdkVersion;
        outputHash = macosSdkOutputHash;
      }
    else null;

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
