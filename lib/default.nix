{
  crane,
  osxcross,
  meta-harbor ? null,
}: let
  devShellLib = import ./dev-shell.nix;
  adapterLib = import ./adapter.nix;
  minisignLib = import ./minisign.nix;
  mkToolchain = import ./toolchain.nix {inherit crane;};
  hardeningProfiles = import ./hardening-profiles.nix;
  mkSccacheLib = import ./sccache.nix {};
  packageTests =
    if meta-harbor != null
    then meta-harbor.packageTests
    else throw "rs-harbor: package-test helpers require the meta-harbor flake input";
in {
  inherit mkToolchain hardeningProfiles packageTests;
  opencode =
    if meta-harbor != null
    then meta-harbor.opencode
    else throw "rs-harbor: opencode helpers require the meta-harbor flake input";

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

  mkWasmToolchain = import ./wasm-toolchain.nix {inherit crane;};
  mkTrunkPackage = import ./trunk.nix {inherit crane packageTests;};
  mkRustServiceModule = import ./nixos-rust-service.nix {
    inherit hardeningProfiles;
  };

  findLocalMavenCache = import ./android-maven-cache.nix;
  mkAtticPush = import ./attic-push.nix;
  mkAndroidApk = import ./android-apk.nix {inherit packageTests;};
  mkAndroidApkDevBuilder = import ./android-apk-dev-builder.nix {inherit packageTests;};
  mkAndroidFlavorTable = import ./android-flavor-table.nix {inherit packageTests;};
  mkAppImage = import ./appimage.nix {inherit packageTests;};
  mkPackageArtifactBuilder = import ./package-artifact-builder.nix {inherit packageTests;};
  mkChocoPackage = import ./choco-package.nix {inherit packageTests;};
  mkChocoTestEnvironment = import ./choco-test-environment.nix {inherit packageTests;};
  mkPackageTestPlan = import ./package-test-plan.nix {inherit packageTests;};
  mkCoprSpec = import ./copr-spec.nix {inherit packageTests;};
  mkDebPackage = import ./deb-package.nix {inherit packageTests;};
  mkFlatpakManifest = import ./flatpak-manifest.nix {inherit packageTests;};
  mkHomebrewFormula = import ./homebrew-formula.nix {inherit packageTests;};
  mkScoopManifest = import ./scoop-manifest.nix {inherit packageTests;};
  mkSccacheEnv = mkSccacheLib; # backward compat: rs-harbor.lib.mkSccacheEnv.mkSccacheEnv { ... }
  mkSccacheCraneEnv = mkSccacheLib.mkSccacheCraneEnv;
  wrapRustPackageWithSccache = mkSccacheLib.wrapRustPackageWithSccache;
}
