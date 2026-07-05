# mkAndroidFlavorTable :: {
#   pkgs, androidSdk, rustToolchain, workspaceSrc,
#   mavenCacheTar?, gradleDeps?, ndkVersion?,
#   commonCargoFeatures?, commonCargoNoDefaultFeatures?,
#   defaultFlavor?, defaultAbi?, defaultMode?, androidDir?,
#   modes?, flavors,
# } -> { packages, devBuilders, apps }
#
# Expand one consumer-owned Android flavor table into `mkAndroidApk`
# derivations, `mkAndroidApkDevBuilder` scripts, and `nix run` app wrappers.
# The helper owns repeated wiring only; callers still own flavor names, cargo
# package names, Gradle module names, output attribute names, and mode coverage.
# Each flavor may set `packageModes` to model asymmetric builds such as a main
# app with debug+release packages and a test peer with debug only.
#
# Example:
#
#   android = rs-harbor.lib.mkAndroidFlavorTable {
#     inherit pkgs androidSdk rustToolchain workspaceSrc;
#     flavors.app = {
#       cargoPkg = "my-game";
#       gradleModule = ":app";
#       packageModes = ["debug" "release"];
#     };
#   };
{packageTests}: {
  pkgs,
  androidSdk,
  rustToolchain,
  workspaceSrc,
  mavenCacheTar ? null,
  gradleDeps ? null,
  ndkVersion ? "29.0.14206865",
  commonCargoFeatures ? [],
  commonCargoNoDefaultFeatures ? false,
  defaultFlavor ? builtins.head (builtins.attrNames flavors),
  defaultAbi ? "arm64-v8a",
  defaultMode ? "debug",
  androidDir ? "android",
  modes ? ["debug" "release"],
  flavors,
  lib ? pkgs.lib,
}:
assert lib.assertMsg (builtins.isAttrs flavors && flavors != {})
"rs-harbor: mkAndroidFlavorTable requires a non-empty `flavors` attrset";
assert lib.assertMsg (builtins.hasAttr defaultFlavor flavors)
"rs-harbor: mkAndroidFlavorTable defaultFlavor `${defaultFlavor}` is not in flavors";
assert lib.assertMsg (builtins.isList modes && modes != [])
"rs-harbor: mkAndroidFlavorTable `modes` must be a non-empty list";
assert lib.assertMsg (builtins.elem defaultMode ["debug" "release"])
"rs-harbor: mkAndroidFlavorTable `defaultMode` must be \"debug\" or \"release\""; let
  mkAndroidApk = import ./android-apk.nix {inherit packageTests;};
  mkAndroidApkDevBuilder = import ./android-apk-dev-builder.nix {inherit packageTests;};

  validMode = mode: builtins.elem mode ["debug" "release"];

  moduleName = gradleModule: lib.removePrefix ":" gradleModule;

  callOrValue = value: arg:
    if builtins.isFunction value
    then value arg
    else value;

  normalizeFlavor = name: cfg:
    assert lib.assertMsg (cfg ? cargoPkg)
    "rs-harbor: mkAndroidFlavorTable flavor `${name}` requires cargoPkg"; let
      gradleModule = cfg.gradleModule or ":${name}";
      module = moduleName gradleModule;
      packageModes = cfg.packageModes or modes;
      packageAttr = cfg.packageAttr or (mode: "android-${name}-apk-${mode}");
      devAppAttr = cfg.devAppAttr or "android-${name}-apk";
      apkOutPath = cfg.apkOutPath or (mode: "android/${module}/build/outputs/apk/${mode}/${module}-${mode}.apk");
    in
      assert lib.assertMsg (builtins.isString cfg.cargoPkg && cfg.cargoPkg != "")
      "rs-harbor: mkAndroidFlavorTable flavor `${name}` cargoPkg must be a non-empty string";
      assert lib.assertMsg (builtins.isString gradleModule && lib.hasPrefix ":" gradleModule)
      "rs-harbor: mkAndroidFlavorTable flavor `${name}` gradleModule must look like \":app\"";
      assert lib.assertMsg (builtins.isList packageModes && packageModes != [])
      "rs-harbor: mkAndroidFlavorTable flavor `${name}` packageModes must be a non-empty list";
      assert lib.assertMsg (builtins.all validMode packageModes)
      "rs-harbor: mkAndroidFlavorTable flavor `${name}` packageModes may only contain \"debug\" or \"release\"";
      assert lib.assertMsg (builtins.isString devAppAttr && devAppAttr != "")
      "rs-harbor: mkAndroidFlavorTable flavor `${name}` devAppAttr must be a non-empty string"; {
        inherit name gradleModule packageModes packageAttr devAppAttr apkOutPath;
        cargoPkg = cfg.cargoPkg;
        jniLibsDir = cfg.jniLibsDir or "android/${module}/src/main/jniLibs";
        pname = cfg.pname or packageAttr;
        cargoFeatures = cfg.cargoFeatures or commonCargoFeatures;
        cargoNoDefaultFeatures = cfg.cargoNoDefaultFeatures or commonCargoNoDefaultFeatures;
      };

  normalized = lib.mapAttrs normalizeFlavor flavors;

  packageEntries = lib.flatten (
    lib.mapAttrsToList (
      name: cfg:
        map (
          mode: let
            attr = callOrValue cfg.packageAttr mode;
          in
            assert lib.assertMsg (builtins.isString attr && attr != "")
            "rs-harbor: mkAndroidFlavorTable flavor `${name}` packageAttr must return a non-empty string"; {
              inherit attr;
              value = mkAndroidApk {
                inherit pkgs androidSdk rustToolchain workspaceSrc mavenCacheTar gradleDeps ndkVersion;
                inherit (cfg) cargoPkg gradleModule jniLibsDir cargoFeatures cargoNoDefaultFeatures;
                inherit mode;
                pname = callOrValue cfg.pname mode;
                apkOutPath = callOrValue cfg.apkOutPath mode;
                abi = defaultAbi;
              };
            }
        )
        cfg.packageModes
    )
    normalized
  );

  devBuilderFlavors =
    lib.mapAttrs (_: cfg: {
      inherit (cfg) cargoPkg gradleModule jniLibsDir;
      apkOutPath = callOrValue cfg.apkOutPath defaultMode;
    })
    normalized;

  devBuilderEntries =
    lib.mapAttrsToList (
      name: cfg: {
        attr = cfg.devAppAttr;
        value = mkAndroidApkDevBuilder {
          inherit pkgs defaultAbi defaultMode androidDir;
          defaultFlavor = name;
          flavors = devBuilderFlavors;
          cargoFeatures = cfg.cargoFeatures;
          cargoNoDefaultFeatures = cfg.cargoNoDefaultFeatures;
        };
      }
    )
    normalized;

  assertUnique = kind: entries: let
    names = map (entry: entry.attr) entries;
    uniqueNames = lib.unique names;
  in
    assert lib.assertMsg (builtins.length names == builtins.length uniqueNames)
    "rs-harbor: mkAndroidFlavorTable produced duplicate ${kind} attribute names: ${lib.concatStringsSep ", " names}"; true;

  packages = assert assertUnique "package" packageEntries;
    builtins.listToAttrs (map (entry: {
        name = entry.attr;
        inherit (entry) value;
      })
      packageEntries);

  devBuilders = assert assertUnique "dev builder/app" devBuilderEntries;
    builtins.listToAttrs (map (entry: {
        name = entry.attr;
        inherit (entry) value;
      })
      devBuilderEntries);
in {
  inherit packages devBuilders;
  apps =
    lib.mapAttrs (_: builder: {
      type = "app";
      program = toString builder;
    })
    devBuilders;
}
