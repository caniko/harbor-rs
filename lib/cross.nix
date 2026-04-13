# mkCross :: { pkgs, system, enableOsxcross?, osxSdkVersion? }
#         -> { mingwCC, mingwBinutils, winpthreads, windowsEnv,
#              osxcrossToolchain, osxcrossRustHelpers }
#
# Build cross-compilation toolchains (MinGW for Windows, osxcross for macOS).
{osxcross}: {
  pkgs,
  system,
  enableOsxcross ? true,
  osxSdkVersion ? "26.1",
}: let
  mingwCC = pkgs.pkgsCross.mingwW64.stdenv.cc;
  mingwBinutils = pkgs.pkgsCross.mingwW64.stdenv.cc.bintools.bintools;
  winpthreads = pkgs.pkgsCross.mingwW64.windows.pthreads;

  osxcrossToolchain =
    if enableOsxcross && system == "x86_64-linux"
    then
      osxcross.lib.${system}.mkOsxcross {
        sdkVersion = osxSdkVersion;
      }
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
  inherit osxcrossToolchain osxcrossRustHelpers;
  inherit windowsEnv;
}
