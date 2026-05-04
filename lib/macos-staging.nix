# mkMacosUniversalStager :: { pkgs, rsHarborCli? } -> { stager, packages, ... }
#
# Produces the `stage-macos-universal` helper that takes cargo's per-target
# Mach-O outputs (and their split-debuginfo=packed `.dSYM` bundles) and
# stages them as both per-arch dist dirs and a universal slice via `lipo`.
#
# Implementation lives in the rs-harbor Rust CLI (`rs-harbor stage macos`).
# The `stager` derivation is a thin shell shim so existing call sites that
# spawn `stage-macos-universal` keep working without rewrites.
#
# Consumers compiling on a host without the rust CLI prebuilt may pass
# `rsHarborCli = null` to fall back to a stub that errors out — but in
# practice the rs-harbor flake always wires its own CLI in.
{
  pkgs,
  rsHarborCli ? null,
}: let
  cargoMacosPackedDebuginfoSnippet = ''
    [profile.release]
    split-debuginfo = "packed"
  '';

  stager =
    if rsHarborCli == null
    then
      pkgs.writeShellApplication {
        name = "stage-macos-universal";
        text = ''
          echo "stage-macos-universal: rs-harbor CLI was not wired into mkMacosUniversalStager" >&2
          echo "Pass rsHarborCli = self.packages.\$\{system}.rs-harbor when calling the helper." >&2
          exit 127
        '';
      }
    else
      pkgs.writeShellApplication {
        name = "stage-macos-universal";
        runtimeInputs = [rsHarborCli pkgs.llvmPackages.llvm];
        text = ''
          exec rs-harbor stage macos "$@"
        '';
      };
in {
  inherit cargoMacosPackedDebuginfoSnippet stager;
  packages = {stageMacosUniversal = stager;};
}
