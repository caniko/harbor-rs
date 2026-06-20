{
  crane,
  osxcross,
}: let
  devShellLib = import ./dev-shell.nix;
  adapterLib = import ./adapter.nix;
  minisignLib = import ./minisign.nix;
  mkToolchain = import ./toolchain.nix {inherit crane;};
in {
  inherit mkToolchain;
  mkCargoConfig = import ./cargo-config.nix;
  mkCross = import ./cross.nix {inherit osxcross;};
  mkCrossPackages = import ./cross-packages.nix {inherit mkToolchain;};
  mkSteamRuntimeTools = import ./steam-runtime.nix;
  mkGpuRenderPin = import ./gpu-render-pin.nix;
  mkMacosUniversalStager = import ./macos-staging.nix;
  mkOsxcrossHooks = import ./osxcross-hooks.nix;
  mkWindowsMsvcDevShell = import ./windows-msvc-shell.nix;
  inherit (devShellLib) mkDevShell mkDocsShell mkDevShells;
  inherit (adapterLib) mkAdapter isHarborAdapter;
  inherit (minisignLib) mkMinisignSign mkMinisignVerify;
  findLocalMavenCache = import ./android-maven-cache.nix;
  mkAtticPush = import ./attic-push.nix;
  mkAndroidApk = import ./android-apk.nix;
  mkAndroidApkDevBuilder = import ./android-apk-dev-builder.nix;
  mkAndroidFlavorTable = import ./android-flavor-table.nix;
  mkAppImage = import ./appimage.nix;
  mkChocoPackage = import ./choco-package.nix;
  mkCoprSpec = import ./copr-spec.nix;
  mkDebPackage = import ./deb-package.nix;
  mkFlatpakManifest = import ./flatpak-manifest.nix;
  mkHomebrewFormula = import ./homebrew-formula.nix;
  mkScoopManifest = import ./scoop-manifest.nix;
  mkSccacheEnv = import ./sccache.nix {};
}
