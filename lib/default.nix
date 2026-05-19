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
  mkAtticPush = import ./attic-push.nix;
  mkAppImage = import ./appimage.nix;
  mkAndroidApk = import ./android-apk.nix;
  mkAndroidApkDevBuilder = import ./android-apk-dev-builder.nix;
  mkFlatpakManifest = import ./flatpak-manifest.nix;
  mkCoprSpec = import ./copr-spec.nix;
}
