# mkAndroidApk :: {
#   pkgs, androidSdk, rustToolchain, workspaceSrc,
#   cargoPkg, gradleModule, jniLibsDir, apkOutPath,
#   abi?, mode?, pname?, version?, ndkVersion?,
#   cargoFeatures?, cargoNoDefaultFeatures?,
#   mavenCacheTar?, gradleDeps?,
#   cargoNdk?, jdk?, gradle?, lib?,
# } -> derivation
#
# Build an Android APK from a cargo workspace member that exposes a `cdylib`,
# packaging the resulting `.so` via a Gradle module that uses AndroidX
# `GameActivity` (typical for Bevy 0.18 + `android-game-activity`).
#
# Two build modes:
#
#   - **Hermetic**: pass `mavenCacheTar` (a path or store-path tarball whose
#     contents are `caches/modules-2/files-2.1` from a prior `gradle assemble`
#     run). The derivation extracts it into `$GRADLE_USER_HOME` and runs
#     `gradle --offline`. Reproducible across machines once the tarball
#     hash is pinned.
#
#   - **Impure**: pass nothing. Gradle resolves Maven artefacts from the
#     network; the derivation requires `__noChroot = true;` (and therefore
#     `--option sandbox false` or a Nix configured to permit it).
#     Use as a stop-gap until you commit a cache tarball or a
#     `gradle-deps.json` from `gradle2nix`.
#
# Reuses the workspace-pinned `rustToolchain` (see `mkToolchain`) so the
# `cdylib` is built with the exact same compiler as the rest of the
# workspace; the project's `Cargo.lock` therefore stays load-bearing.
#
# Example consumer (regicide):
#
#   packages.android-apk-debug = rs-harbor.lib.mkAndroidApk {
#     inherit pkgs androidSdk rustToolchain;
#     workspaceSrc = self;
#     cargoPkg = "chessbender";
#     gradleModule = ":app";
#     jniLibsDir = "android/app/src/main/jniLibs";
#     apkOutPath = "android/app/build/outputs/apk/debug/app-debug.apk";
#     cargoNoDefaultFeatures = true;
#     cargoFeatures = ["tutorial"];
#     mavenCacheTar = ./gradle-cache.tar;
#   };

{
  pkgs,
  androidSdk,
  rustToolchain,
  workspaceSrc,

  # ─────────────────────────────────────────────────────────────────────────
  # Project-specific knobs
  # ─────────────────────────────────────────────────────────────────────────

  # Cargo workspace member whose cdylib produces `lib<cargoPkg>.so`.
  cargoPkg,
  # Gradle subproject path, e.g. ":app" or ":test-peer".
  gradleModule,
  # Where `cargo ndk -o` should drop the `.so` so gradle picks it up.
  jniLibsDir,
  # Final relative path inside the workspace where gradle emits the APK.
  apkOutPath,

  abi ? "arm64-v8a",
  mode ? "debug",
  pname ? "android-apk",
  version ? "0.1.0",

  cargoFeatures ? [],
  cargoNoDefaultFeatures ? false,

  # ─────────────────────────────────────────────────────────────────────────
  # Toolchain / tool overrides
  # ─────────────────────────────────────────────────────────────────────────

  ndkVersion ? "29.0.14206865",
  cargoNdk ? pkgs.cargo-ndk,
  jdk ? pkgs.jdk21,
  gradle ? pkgs.gradle,
  lib ? pkgs.lib,

  # ─────────────────────────────────────────────────────────────────────────
  # Hermetic-build inputs (mutually exclusive; first non-null wins)
  # ─────────────────────────────────────────────────────────────────────────

  # Path to a tarball whose root is `files-2.1/` — the standard layout of
  # `$GRADLE_USER_HOME/caches/modules-2/files-2.1`. Pack via:
  #   tar --sort=name --mtime='2026-01-01 00:00:00 UTC' \
  #       --owner=0 --group=0 --numeric-owner \
  #       -cf gradle-cache.tar -C $GRADLE_USER_HOME/caches/modules-2 files-2.1
  mavenCacheTar ? null,
  # Reserved for `gradle2nix`-generated dependency manifests once the
  # upstream gradle2nix tooling is unblocked. Currently a no-op placeholder.
  gradleDeps ? null,
}:

assert lib.assertMsg (builtins.isString cargoPkg)
  "rs-harbor: mkAndroidApk requires `cargoPkg` (a workspace cdylib package name)";
assert lib.assertMsg (builtins.isString gradleModule && lib.hasPrefix ":" gradleModule)
  "rs-harbor: mkAndroidApk `gradleModule` must look like \":app\" or \":test-peer\", got ${toString gradleModule}";
assert lib.assertMsg (builtins.elem mode ["debug" "release"])
  "rs-harbor: mkAndroidApk `mode` must be \"debug\" or \"release\", got ${mode}";
assert lib.assertMsg (rustToolchain != null)
  "rs-harbor: mkAndroidApk requires `rustToolchain` — pass `(mkToolchain { ... }).rustToolchain`";

let
  modeCap =
    if mode == "debug"
    then "Debug"
    else "Release";

  ndkRoot = "${androidSdk}/libexec/android-sdk/ndk/${ndkVersion}";

  hermetic = mavenCacheTar != null || gradleDeps != null;

  cargoNoDefault = lib.optionalString cargoNoDefaultFeatures "--no-default-features";
  cargoFeatureFlag = lib.optionalString (cargoFeatures != [])
    "--features ${lib.concatStringsSep "," cargoFeatures}";
  cargoReleaseFlag = lib.optionalString (mode == "release") "--release";

  # The Gradle module name without the leading colon — used for Gradle's
  # `<module>/build/...` output path convention.
  moduleSubdir = lib.removePrefix ":" gradleModule;

  commonAttrs = {
    inherit pname version;
    src = workspaceSrc;

    nativeBuildInputs = [
      cargoNdk
      gradle
      jdk
      androidSdk
      rustToolchain
    ];

    ANDROID_NDK_HOME = ndkRoot;
    ANDROID_NDK_ROOT = ndkRoot;
    ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";

    buildPhase = ''
      runHook preBuild

      echo "[mkAndroidApk] cargo ndk -t ${abi} -o ${jniLibsDir} build ${cargoReleaseFlag} ${cargoNoDefault} ${cargoFeatureFlag} -p ${cargoPkg}"
      cargo ndk -t ${abi} -o ${jniLibsDir} build ${cargoReleaseFlag} \
        ${cargoNoDefault} ${cargoFeatureFlag} -p ${cargoPkg}

      echo "[mkAndroidApk] gradle ${gradleModule}:assemble${modeCap}"
      (cd android && gradle "${gradleModule}:assemble${modeCap}" \
          --no-daemon ${lib.optionalString hermetic "--offline"})

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp ${apkOutPath} "$out/"

      runHook postInstall
    '';

    meta = {
      description =
        "Android ${moduleSubdir} APK (${mode}, ${if hermetic then "hermetic" else "impure"})";
      platforms = ["x86_64-linux" "aarch64-linux"];
    };
  };

  impureExtras = {
    # Gradle needs network for first-run dep fetch. The user must have
    # `sandbox = false` (or `relaxed`) in nix.conf for this to succeed.
    __noChroot = true;
  };

  hermeticExtras = {
    preBuild =
      if mavenCacheTar != null
      then ''
        export GRADLE_USER_HOME="$NIX_BUILD_TOP/.gradle-home"
        mkdir -p "$GRADLE_USER_HOME/caches/modules-2"
        tar -xf ${mavenCacheTar} -C "$GRADLE_USER_HOME/caches/modules-2"
        echo "[mkAndroidApk-hermetic] extracted maven cache → $GRADLE_USER_HOME/caches/modules-2"
      ''
      else ''
        # gradle2nix path — schema-dependent; populate $offlineRepo from the
        # vendored manifest then re-export GRADLE_USER_HOME / set
        # `-Dmaven.repo.local=$offlineRepo`. Filled in once gradle2nix is
        # unblocked; until then mavenCacheTar is the supported hermetic
        # input.
        echo "[mkAndroidApk-hermetic] gradleDeps schema iteration — TODO"
        false
      '';
  };
in
  pkgs.stdenv.mkDerivation (
    commonAttrs
    // (if hermetic then hermeticExtras else impureExtras)
  )
