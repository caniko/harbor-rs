# Generic derivation-level compiler-cache policy.
#
# Host modules own cache transport, credentials, and the writable sandbox
# mount.  This library owns the mechanics that must be identical in every
# Rust consumer: the versioned namespace, sandbox admission, environment
# scrubbing, Cargo/Dioxus wrapper selection, and Cargo artifact propagation.
{ }:
let
  buildContract = import ./build-contract.nix;
  remoteCacheEnvNames = [
    "SCCACHE_SERVER_UDS"
    "SCCACHE_BUCKET"
    "SCCACHE_ENDPOINT"
    "SCCACHE_REGION"
    "SCCACHE_S3_USE_SSL"
    "SCCACHE_S3_KEY_PREFIX"
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_SESSION_TOKEN"
  ];

  mkBuildCachePolicy = {
    pkgs,
    # Cross consumers may pass the build package set explicitly.  The cache
    # executable and its wrapper always run on the build platform, never on
    # the target platform.
    buildPackageSet ? null,
    sccachePackage ? null,
    cacheRoot ? null,
    namespaceScope ? "rs-harbor-rust",
    namespaceGeneration ? 1,
    connectTimeout ? "2",
    executionModel ? "sandbox-local",
  }:
    let
      lib = pkgs.lib;
      buildPackages =
        if buildPackageSet != null
        then buildPackageSet
        else pkgs.buildPackages or pkgs;
      canonicalSccachePackage =
        if sccachePackage != null
        then sccachePackage
        else buildPackages.sccache;
      sccacheVersion = canonicalSccachePackage.version or "unknown";
      namespace = "${namespaceScope}-v${toString namespaceGeneration}-sccache-${sccacheVersion}";
      sharedCacheDir =
        if cacheRoot == null
        then null
        else "${cacheRoot}/${namespace}";

      mkSandboxWrapper = packageSet: let
        realSccache =
          if packageSet ? sccache
          then packageSet.sccache
          else canonicalSccachePackage;
        wrapperCacheDir =
          if sharedCacheDir == null
          then ""
          else sharedCacheDir;
      in
        packageSet.writeShellScriptBin "rs-harbor-sandbox-sccache" ''
          set -eu

          state_root="''${NIX_BUILD_TOP:-''${TMPDIR:-/tmp}}"
          fallback_cache_dir="$state_root/rs-harbor-sccache"
          configured_cache_dir=${lib.escapeShellArg wrapperCacheDir}

          shared_cache_is_admissible() {
            current_uid="$(${packageSet.coreutils}/bin/id -u)"
            current_gid="$(${packageSet.coreutils}/bin/id -g)"
            current_user="$(${packageSet.coreutils}/bin/id -un)"
            current_group="$(${packageSet.coreutils}/bin/id -gn)"

            case "$current_user:$current_group" in
              nixbld*:nixbld) ;;
              *) return 1 ;;
            esac

            ${packageSet.coreutils}/bin/mkdir -p "$configured_cache_dir" 2>/dev/null || return 1
            [ -d "$configured_cache_dir" ] \
              && [ ! -L "$configured_cache_dir" ] \
              && [ -w "$configured_cache_dir" ] \
              || return 1

            owner_uid="$(${packageSet.coreutils}/bin/stat -c %u "$configured_cache_dir")"
            owner_gid="$(${packageSet.coreutils}/bin/stat -c %g "$configured_cache_dir")"
            owner_name="$(${packageSet.coreutils}/bin/stat -c %U "$configured_cache_dir")"
            group_name="$(${packageSet.coreutils}/bin/stat -c %G "$configured_cache_dir")"
            mode="$(${packageSet.coreutils}/bin/stat -c %a "$configured_cache_dir")"

            case "$owner_name:$owner_uid" in
              root:0 | nixbld*:* | nobody:65534) ;;
              *) return 1 ;;
            esac
            [ "$owner_gid" = "$current_gid" ] \
              && [ "$group_name" = "$current_group" ] \
              || return 1
            case "$mode" in
              "" | *[!0-7]*) return 1 ;;
            esac
            [ "$((8#$mode & 0777))" -eq "$((0770))" ]
          }

          # Sandbox builds must never send Garage credentials or a host daemon
          # socket through the compiler wrapper.  The host-mounted disk cache
          # is the only shared state this execution model admits.
          unset ${lib.escapeShellArgs remoteCacheEnvNames}
          unset XDG_CACHE_HOME

          umask 0007
          if [ -n "$configured_cache_dir" ] && shared_cache_is_admissible; then
            cache_dir="$configured_cache_dir"
          elif [ -n "''${SCCACHE_DIR:-}" ] && [ -d "''${SCCACHE_DIR}" ] && [ -w "''${SCCACHE_DIR}" ]; then
            cache_dir="$SCCACHE_DIR"
          else
            umask 0077
            cache_dir="$fallback_cache_dir"
            ${packageSet.coreutils}/bin/mkdir -p "$cache_dir"
          fi

          export SCCACHE_DIR="$cache_dir"
          export XDG_CACHE_HOME="$cache_dir"
          export SCCACHE_CONNECT_TIMEOUT=${lib.escapeShellArg connectTimeout}
          exec ${realSccache}/bin/sccache "$@"
        '';

      markSandboxWrapper = wrapperDrv: wrapperDrv.overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            rsHarborSandboxLocalSccache = true;
            rsHarborSharedCacheDir = sharedCacheDir;
            sharedCacheAdmission = "nixbld-owner-group-0770";
          };
      });
      wrapper = markSandboxWrapper (mkSandboxWrapper buildPackages);
      wrapperPath = "${wrapper}/bin/rs-harbor-sandbox-sccache";
      commonNativeInputs = [wrapper canonicalSccachePackage];

      rustEnv = {
        RUSTC_WRAPPER = wrapperPath;
        CARGO_INCREMENTAL = "0";
      };
      dioxusEnv = {
        # Dioxus installs a compiler shim in RUSTC_WRAPPER.  Workspace
        # wrapping sees the real rustc invocation beneath that shim.
        RUSTC_WORKSPACE_WRAPPER = wrapperPath;
        CARGO_INCREMENTAL = "0";
      };

      markWrapped = old: {
        passthru =
          (old.passthru or {})
          // {
            rsHarborBuildCacheWrapped = true;
            rsHarborBuildCacheContract = {
              inherit namespace sccacheVersion executionModel;
            };
          };
      };

      withEnv = {
        package,
        env,
        nativeInputs ? commonNativeInputs,
      }:
        package.overrideAttrs (old:
          if (old.passthru or {}).rsHarborBuildCacheWrapped or false
          then { }
          else
            {
              nativeBuildInputs = (old.nativeBuildInputs or []) ++ nativeInputs;
              env = (old.env or {}) // env;
            }
            // markWrapped old);

      withRustCache = {
        package,
        enable ? true,
        extraEnv ? {},
        linkerPackageSet ? null,
      }:
        if !enable
        then package
        else let
          linkerEnv =
            if linkerPackageSet == null
            then {}
            else hostLinkerEnvFor linkerPackageSet;
          wrapped = withEnv {
            inherit package;
            env = rustEnv // extraEnv // linkerEnv;
          };
        in
          wrapped.overrideAttrs (old:
            if (old.passthru or {}).rsHarborBuildCacheArtifactsWrapped or false
            then { }
            else {
              cargoArtifacts =
                if (old.cargoArtifacts or null) != null
                then withEnv {
                  package = old.cargoArtifacts;
                  env = rustEnv // extraEnv // linkerEnv;
                }
                else old.cargoArtifacts or null;
              passthru =
                (old.passthru or {})
                // {rsHarborBuildCacheArtifactsWrapped = true;};
            });

      withDioxusCache = {
        package,
        enable ? true,
      }:
        if !enable
        then package
        else withEnv {inherit package; env = dioxusEnv;};

      hostLinkerEnvFor = buildPackageSet': let
        target =
          buildPackageSet'.stdenv.buildPlatform.rust.cargoEnvVarTarget;
        targetUpper = lib.toUpper (lib.replaceStrings ["-"] ["_"] target);
        linkerEnv = "CARGO_TARGET_${targetUpper}_LINKER";
        hostCc = "${buildPackageSet'.stdenv.cc}/bin/cc";
      in {
        ${linkerEnv} = hostCc;
        "CC_${targetUpper}" = hostCc;
        HOST_CC = hostCc;
        CC_FOR_BUILD = hostCc;
      };

      withCrossRust = {
        package,
        buildPackageSet' ? buildPackages,
        enable ? true,
      }:
        if !enable
        then package
        else
          withRustCache {
            package = package.overrideAttrs (old: {
              env = (old.env or {}) // hostLinkerEnvFor buildPackageSet';
            });
            linkerPackageSet = buildPackageSet';
          };

      withCrossLinker = {
        package,
        buildPackageSet' ? buildPackages,
        enable ? true,
      }:
        if !enable
        then package
        else package.overrideAttrs (old: {
          env = (old.env or {}) // hostLinkerEnvFor buildPackageSet';
        });

      withCmakeCache = {
        package,
        enable ? true,
        packageSet ? buildPackages,
      }:
        if !enable
        then package
        else let
          cmakeWrapper = markSandboxWrapper (mkSandboxWrapper packageSet);
          launcher = "${cmakeWrapper}/bin/rs-harbor-sandbox-sccache";
          launcherEnv = {
            CMAKE_C_COMPILER_LAUNCHER = launcher;
            CMAKE_CXX_COMPILER_LAUNCHER = launcher;
          };
        in
          package.overrideAttrs (old: let
            oldEnv = old.env or {};
            conflicting = builtins.filter (name:
              builtins.hasAttr name old
              || builtins.hasAttr name oldEnv
              || builtins.any (flag:
                builtins.isString flag
                && (lib.hasPrefix "-D${name}=" flag || lib.hasPrefix "-D${name}:" flag))
                ((old.cmakeFlags or []) ++ (old.configureFlags or []))) [
                  "CMAKE_C_COMPILER_LAUNCHER"
                  "CMAKE_CXX_COMPILER_LAUNCHER"
                ];
          in
            if (old.passthru or {}).rsHarborCmakeCacheWrapped or false
            then { }
            else if conflicting != []
            then throw "rs-harbor: package already defines a CMake compiler launcher: ${lib.concatStringsSep ", " conflicting}"
            else {
              nativeBuildInputs = (old.nativeBuildInputs or []) ++ [packageSet.sccache cmakeWrapper];
              env = (builtins.removeAttrs oldEnv (remoteCacheEnvNames ++ ["RUSTC_WRAPPER" "XDG_CACHE_HOME"])) // launcherEnv;
              passthru =
                (old.passthru or {})
                // {
                  rsHarborCmakeCacheWrapped = true;
                  rsHarborCmakeCacheWrapper = wrapper;
                  rsHarborBuildCacheContract = {
                    inherit namespace sccacheVersion executionModel;
                  };
                };
            });

      mkOverlay = {
        rustPackages ? [],
        cmakePackages ? [],
        crossOnly ? false,
      }:
        final: prev:
          let
            cross = prev.stdenv.buildPlatform.system != prev.stdenv.hostPlatform.system;
            applyRust = name: acc:
              if !(prev ? ${name}) || (crossOnly && !cross)
              then acc
              else acc // {${name} = withRustCache {package = prev.${name};};};
            applyCmake = name: acc:
              if !(prev ? ${name}) || (crossOnly && !cross)
              then acc
              else acc // {${name} = withCmakeCache {package = prev.${name}; packageSet = final.buildPackages;};};
          in
            (builtins.foldl' (name: acc: applyRust name acc) {} rustPackages)
            // (builtins.foldl' (name: acc: applyCmake name acc) {} cmakePackages);
    in {
      inherit namespace sharedCacheDir wrapper wrapperPath rustEnv dioxusEnv;
      inherit withRustCache withDioxusCache withCrossRust withCrossLinker withCmakeCache mkOverlay;
      contract = {
        schemaVersion = 1;
        inherit namespaceScope namespaceGeneration namespace sccacheVersion executionModel;
        rustToolchain = buildContract.toolchain.toolchain;
      };
    };
in {
  inherit mkBuildCachePolicy;
}
