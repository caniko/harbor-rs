{crane, osxcross}: let
  devShellLib = import ./dev-shell.nix;
  adapterLib = import ./adapter.nix;
in {
  mkToolchain = import ./toolchain.nix {inherit crane;};
  mkCargoConfig = import ./cargo-config.nix;
  mkCross = import ./cross.nix {inherit osxcross;};
  mkSteamRuntimeTools = import ./steam-runtime.nix;
  mkGpuRenderPin = import ./gpu-render-pin.nix;
  mkMacosUniversalStager = import ./macos-staging.nix;
  mkOsxcrossHooks = import ./osxcross-hooks.nix;
  mkWindowsMsvcDevShell = import ./windows-msvc-shell.nix;
  inherit (devShellLib) mkDevShell mkDevShells;
  inherit (adapterLib) mkAdapter isHarborAdapter;
  findLocalMavenCache = import ./android-maven-cache.nix;
  mkAtticPush = import ./attic-push.nix;
  mkAndroidApk = import ./android-apk.nix;
  mkAndroidApkDevBuilder = import ./android-apk-dev-builder.nix;
  mkAndroidFlavorTable = import ./android-flavor-table.nix;
  mkAppImage = import ./appimage.nix;
  mkFlatpakManifest = import ./flatpak-manifest.nix;
  mkCoprSpec = import ./copr-spec.nix;
  mkHomebrewFormula = import ./homebrew-formula.nix;
}
