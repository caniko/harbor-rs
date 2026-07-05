# mkAndroidApkDevBuilder :: {
#   pkgs,
#   flavors,
#   defaultFlavor?, defaultAbi?, defaultMode?,
#   androidDir?, cargoFeatures?, cargoNoDefaultFeatures?,
# } -> path
#
# Produce an impure developer helper script for staging Android APKs from the
# current checkout. This is intentionally not a derivation builder: it expects
# to run inside a dev shell with cargo-ndk, Gradle, Android SDK/NDK, and network
# access available, then leaves the APK in the project's normal Gradle output
# directory for device-oriented smoke loops.
{packageTests}: {
  pkgs,
  flavors,
  packageName ? "android-apk",
  version ? "0.1.0",
  defaultFlavor ? "app",
  defaultAbi ? "arm64-v8a",
  defaultMode ? "debug",
  androidDir ? "android",
  cargoFeatures ? [],
  cargoNoDefaultFeatures ? false,
  lib ? pkgs.lib,
}:
assert lib.assertMsg (builtins.isAttrs flavors && flavors != {})
"rs-harbor: mkAndroidApkDevBuilder requires a non-empty `flavors` attrset";
assert lib.assertMsg (builtins.hasAttr defaultFlavor flavors)
"rs-harbor: mkAndroidApkDevBuilder defaultFlavor `${defaultFlavor}` is not in flavors"; let
  shellCase = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: cfg:
        assert lib.assertMsg (cfg ? cargoPkg)
        "rs-harbor: mkAndroidApkDevBuilder flavor `${name}` requires cargoPkg";
        assert lib.assertMsg (cfg ? gradleModule)
        "rs-harbor: mkAndroidApkDevBuilder flavor `${name}` requires gradleModule";
        assert lib.assertMsg (cfg ? jniLibsDir)
        "rs-harbor: mkAndroidApkDevBuilder flavor `${name}` requires jniLibsDir";
        assert lib.assertMsg (cfg ? apkOutPath)
        "rs-harbor: mkAndroidApkDevBuilder flavor `${name}` requires apkOutPath"; ''
          ${lib.escapeShellArg name})
            cargo_pkg=${lib.escapeShellArg cfg.cargoPkg}
            gradle_module=${lib.escapeShellArg cfg.gradleModule}
            jni_libs_dir=${lib.escapeShellArg cfg.jniLibsDir}
            apk_out_path=${lib.escapeShellArg cfg.apkOutPath}
            ;;
        ''
    )
    flavors
  );

  cargoNoDefault = lib.optionalString cargoNoDefaultFeatures "--no-default-features";
  cargoFeatureFlag =
    lib.optionalString (cargoFeatures != [])
    "--features ${lib.concatStringsSep "," cargoFeatures}";
  script = pkgs.writeShellScript "android-apk-dev-builder" ''
    set -euo pipefail

    if [ -z "''${ANDROID_NDK_HOME:-}" ]; then
      echo "error: ANDROID_NDK_HOME is unset. Run inside the Android dev shell." >&2
      exit 1
    fi
    for tool in cargo-ndk gradle; do
      if ! command -v "$tool" >/dev/null; then
        echo "error: $tool not on PATH. Run inside the Android dev shell." >&2
        exit 1
      fi
    done

    flavor="''${FLAVOR:-${defaultFlavor}}"
    abi="''${ABI:-${defaultAbi}}"
    mode="''${MODE:-${defaultMode}}"

    case "$flavor" in
    ${shellCase}
      *)
        echo "error: unknown FLAVOR=$flavor (expected one of: ${lib.concatStringsSep ", " (builtins.attrNames flavors)})" >&2
        exit 1
        ;;
    esac

    cargo_mode_flag=""
    mode_cap="Debug"
    if [ "$mode" = "release" ]; then
      cargo_mode_flag="--release"
      mode_cap="Release"
    elif [ "$mode" != "debug" ]; then
      echo "error: unknown MODE=$mode (expected debug or release)" >&2
      exit 1
    fi

    echo "[android-apk] flavor=$flavor abi=$abi mode=$mode"
    echo "[android-apk] cargo ndk -t $abi -o $jni_libs_dir build $cargo_mode_flag ${cargoNoDefault} ${cargoFeatureFlag} -p $cargo_pkg"
    cargo ndk -t "$abi" -o "$jni_libs_dir" build $cargo_mode_flag \
      ${cargoNoDefault} ${cargoFeatureFlag} -p "$cargo_pkg"

    echo "[android-apk] gradle $gradle_module:assemble$mode_cap"
    (cd ${lib.escapeShellArg androidDir} && gradle "$gradle_module:assemble$mode_cap")

    echo "[android-apk] APK at $apk_out_path"
  '';
in
  script
  // {
    artifactBuilder = packageTests.mkArtifactBuilder {
      kind = "android-apk-dev-builder";
      inherit packageName version;
      output = toString script;
      buildCommand = "nix build .#android-apk-dev-builder";
      metadata = {
        inherit defaultFlavor defaultAbi defaultMode androidDir cargoFeatures cargoNoDefaultFeatures;
        flavors = builtins.attrNames flavors;
        helper = "mkAndroidApkDevBuilder";
      };
    };
  }
