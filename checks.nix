{
  self,
  pkgs,
  system,
  toolchain,
  cross,
}: let
  isLinux = builtins.match ".*-linux" system != null;
in {
  # mkToolchain returns expected attributes
  mkToolchain-shape = let
    t = self.lib.mkToolchain {inherit pkgs;};
  in
    assert t ? rustToolchain;
    assert t ? craneLib;
    assert t ? crossTargets;
    assert builtins.isList t.crossTargets;
    assert builtins.length t.crossTargets > 0;
    pkgs.runCommand "check-mkToolchain-shape" {} "touch $out";

  # stable channel works
  mkToolchain-stable = let
    t = self.lib.mkToolchain {
      inherit pkgs;
      channel = "stable";
    };
  in
    assert t ? rustToolchain;
    assert t ? craneLib;
    pkgs.runCommand "check-mkToolchain-stable" {} "touch $out";

  # mkCross returns expected attributes
  mkCross-shape = let
    c = self.lib.mkCross {
      inherit pkgs system;
      enableOsxcross = false;
    };
  in
    assert c ? mingwCC;
    assert c ? mingwBinutils;
    assert c ? winpthreads;
    assert c ? windowsEnv;
    assert c ? macosSdk;
    assert c ? osxcrossToolchain;
    assert c ? osxcrossRustHelpers;
    assert builtins.isAttrs c.windowsEnv;
    assert c.windowsEnv ? CC_x86_64_pc_windows_gnu;
    assert c.windowsEnv ? CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER;
    pkgs.runCommand "check-mkCross-shape" {} "touch $out";

  # osxcross disabled returns nulls
  mkCross-osxcross-disabled = let
    c = self.lib.mkCross {
      inherit pkgs system;
      enableOsxcross = false;
    };
  in
    assert c.macosSdk == null;
    assert c.osxcrossToolchain == null;
    assert c.osxcrossRustHelpers == null;
    pkgs.runCommand "check-mkCross-osxcross-disabled" {} "touch $out";

  # Pure evaluation should not enable osxcross without an SDK input.
  mkCross-osxcross-default-disabled-without-sdk = let
    c = self.lib.mkCross {inherit pkgs system;};
  in
    assert builtins.getEnv "MACOS_SDK" == "";
    assert c.macosSdk == null;
    assert c.osxcrossToolchain == null;
    assert c.osxcrossRustHelpers == null;
    pkgs.runCommand "check-mkCross-osxcross-default-disabled-without-sdk" {} "touch $out";

  # mkCross enables osxcross from a pure macOS SDK ref without MACOS_SDK.
  mkCross-osxcross-enabled-with-macos-sdk-ref =
    if system == "x86_64-linux"
    then let
      fakeMacosSdk = {
        _type = "osxcross-macos-sdk";
        sdk = pkgs.emptyDirectory;
        sdkVersion = "26.1";
        sdkRoot = "${pkgs.emptyDirectory}/MacOSX26.1.sdk";
      };
      fakeOsxcross = {
        lib.${system} = {
          mkOsxcross = args:
            args
            // {
              _type = "fake-osxcross-toolchain";
              darwinTarget = "darwin25";
              supportedArchs = ["x86_64"];
              effectiveOsxVersionMin = "10.13";
            };
          mkRustHelpers = toolchain: {
            _type = "fake-rust-helpers";
            inherit toolchain;
          };
        };
      };
      mkCross = import ./lib/cross.nix {osxcross = fakeOsxcross;};
      c = mkCross {
        inherit pkgs system;
        macosSdk = fakeMacosSdk;
      };
    in
      assert builtins.getEnv "MACOS_SDK" == "";
      assert c.macosSdk == fakeMacosSdk;
      assert c.osxcrossToolchain._type == "fake-osxcross-toolchain";
      assert c.osxcrossToolchain.macosSdk == fakeMacosSdk;
      assert c.osxcrossToolchain.sdkVersion == "26.1";
      assert c.osxcrossRustHelpers._type == "fake-rust-helpers";
      pkgs.runCommand "check-mkCross-osxcross-enabled-with-macos-sdk-ref" {} "touch $out"
    else pkgs.runCommand "check-mkCross-osxcross-enabled-with-macos-sdk-ref-skipped" {} "touch $out";

  # mkCross can initialize the pure macOS SDK ref from an archive input.
  mkCross-osxcross-enabled-with-sdk-archive =
    if system == "x86_64-linux"
    then let
      fakeSdkArchive = pkgs.emptyDirectory;
      fakeOsxcross = {
        lib.${system} = {
          mkMacosSdk = args:
            args
            // {
              _type = "osxcross-macos-sdk";
              sdk = pkgs.emptyDirectory;
              sdkRoot = "${pkgs.emptyDirectory}/MacOSX${args.sdkVersion}.sdk";
            };
          mkOsxcross = args:
            args
            // {
              _type = "fake-osxcross-toolchain";
              darwinTarget = "darwin25";
              supportedArchs = ["x86_64"];
              effectiveOsxVersionMin = "10.13";
            };
          mkRustHelpers = toolchain: {
            _type = "fake-rust-helpers";
            inherit toolchain;
          };
        };
      };
      mkCross = import ./lib/cross.nix {osxcross = fakeOsxcross;};
      c = mkCross {
        inherit pkgs system;
        sdkArchive = fakeSdkArchive;
        osxSdkVersion = "26.1";
        macosSdkOutputHash = "sha256-fake";
      };
    in
      assert c.macosSdk._type == "osxcross-macos-sdk";
      assert c.macosSdk.sdkArchive == fakeSdkArchive;
      assert c.macosSdk.sdkVersion == "26.1";
      assert c.macosSdk.outputHash == "sha256-fake";
      assert c.osxcrossToolchain.macosSdk == c.macosSdk;
      assert c.osxcrossToolchain.sdkVersion == "26.1";
      assert c.osxcrossRustHelpers.toolchain == c.osxcrossToolchain;
      pkgs.runCommand "check-mkCross-osxcross-enabled-with-sdk-archive" {} "touch $out"
    else pkgs.runCommand "check-mkCross-osxcross-enabled-with-sdk-archive-skipped" {} "touch $out";

  # mkCross resolves MACOS_SDK when it points directly at a complete .sdk directory.
  mkCross-osxcross-enabled-with-env-direct-sdk =
    if system == "x86_64-linux"
    then let
      fakeOsxcross = {
        lib.${system} = {
          mkMacosSdkRef = args:
            args
            // {
              _type = "osxcross-macos-sdk";
            };
          mkOsxcross = args:
            args
            // {
              _type = "fake-osxcross-toolchain";
              darwinTarget = "darwin25";
              supportedArchs = ["x86_64"];
              effectiveOsxVersionMin = "10.13";
            };
          mkRustHelpers = toolchain: {
            _type = "fake-rust-helpers";
            inherit toolchain;
          };
        };
      };
      mkCross = import ./lib/cross.nix {osxcross = fakeOsxcross;};
      c = mkCross {
        inherit pkgs system;
        macosSdkEnvPath = toString ./tests/fixtures/macos-sdk-complete/MacOSX26.1.sdk;
        osxSdkVersion = "26.1";
      };
    in
      assert c.macosSdk._type == "osxcross-macos-sdk";
      assert builtins.baseNameOf (toString c.macosSdk.sdkRoot) == "MacOSX26.1.sdk";
      assert c.osxcrossToolchain.macosSdk == c.macosSdk;
      pkgs.runCommand "check-mkCross-osxcross-enabled-with-env-direct-sdk" {} "touch $out"
    else pkgs.runCommand "check-mkCross-osxcross-enabled-with-env-direct-sdk-skipped" {} "touch $out";

  # mkCross resolves MACOS_SDK when it points at a parent directory containing MacOSX<version>.sdk.
  mkCross-osxcross-enabled-with-env-parent-sdk =
    if system == "x86_64-linux"
    then let
      fakeOsxcross = {
        lib.${system} = {
          mkMacosSdkRef = args:
            args
            // {
              _type = "osxcross-macos-sdk";
            };
          mkOsxcross = args:
            args
            // {
              _type = "fake-osxcross-toolchain";
              darwinTarget = "darwin25";
              supportedArchs = ["x86_64"];
              effectiveOsxVersionMin = "10.13";
            };
          mkRustHelpers = toolchain: {
            _type = "fake-rust-helpers";
            inherit toolchain;
          };
        };
      };
      mkCross = import ./lib/cross.nix {osxcross = fakeOsxcross;};
      c = mkCross {
        inherit pkgs system;
        macosSdkEnvPath = toString ./tests/fixtures/macos-sdk-complete;
        osxSdkVersion = "26.1";
      };
    in
      assert c.macosSdk._type == "osxcross-macos-sdk";
      assert builtins.baseNameOf (toString c.macosSdk.sdkRoot) == "MacOSX26.1.sdk";
      assert c.osxcrossToolchain.macosSdk == c.macosSdk;
      pkgs.runCommand "check-mkCross-osxcross-enabled-with-env-parent-sdk" {} "touch $out"
    else pkgs.runCommand "check-mkCross-osxcross-enabled-with-env-parent-sdk-skipped" {} "touch $out";

  # mkCross resolves MACOS_SDK archives through the archive workflow.
  mkCross-osxcross-enabled-with-env-sdk-archive =
    if system == "x86_64-linux"
    then let
      fakeOsxcross = {
        lib.${system} = {
          mkMacosSdk = args:
            args
            // {
              _type = "osxcross-macos-sdk";
              sdk = pkgs.emptyDirectory;
              sdkRoot = "${pkgs.emptyDirectory}/MacOSX${args.sdkVersion}.sdk";
            };
          mkOsxcross = args:
            args
            // {
              _type = "fake-osxcross-toolchain";
              darwinTarget = "darwin25";
              supportedArchs = ["x86_64"];
              effectiveOsxVersionMin = "10.13";
            };
          mkRustHelpers = toolchain: {
            _type = "fake-rust-helpers";
            inherit toolchain;
          };
        };
      };
      mkCross = import ./lib/cross.nix {osxcross = fakeOsxcross;};
      c = mkCross {
        inherit pkgs system;
        macosSdkEnvPath = toString ./tests/fixtures/MacOSX26.1.sdk.tar.xz;
        osxSdkVersion = "26.1";
      };
    in
      assert c.macosSdk._type == "osxcross-macos-sdk";
      assert builtins.baseNameOf (toString c.macosSdk.sdkArchive) == "MacOSX26.1.sdk.tar.xz";
      assert c.osxcrossToolchain.macosSdk == c.macosSdk;
      pkgs.runCommand "check-mkCross-osxcross-enabled-with-env-sdk-archive" {} "touch $out"
    else pkgs.runCommand "check-mkCross-osxcross-enabled-with-env-sdk-archive-skipped" {} "touch $out";

  # mkCross rejects incomplete SDK directories with validation diagnostics.
  mkCross-osxcross-rejects-incomplete-env-sdk =
    if system == "x86_64-linux"
    then let
      fakeOsxcross = {
        lib.${system} = {
          mkMacosSdkRef = args:
            args
            // {
              _type = "osxcross-macos-sdk";
            };
        };
      };
      mkCross = import ./lib/cross.nix {osxcross = fakeOsxcross;};
      failure = builtins.tryEval ((mkCross {
          inherit pkgs system;
          macosSdkEnvPath = toString ./tests/fixtures/macos-sdk-incomplete/MacOSX26.1.sdk;
          osxSdkVersion = "26.1";
        })
        .macosSdk
        .sdkRoot);
    in
      assert failure.success == false;
      pkgs.runCommand "check-mkCross-osxcross-rejects-incomplete-env-sdk" {} "touch $out"
    else pkgs.runCommand "check-mkCross-osxcross-rejects-incomplete-env-sdk-skipped" {} "touch $out";

  # mkCross can use a VCS-compatible SDK store path produced by host init.
  mkCross-osxcross-enabled-with-sdk-store-path =
    if system == "x86_64-linux"
    then let
      fakeSdkStorePath = "/nix/store/00000000000000000000000000000000-macosx-sdk-26.1";
      fakeOsxcross = {
        lib.${system} = {
          mkMacosSdkRef = args:
            args
            // {
              _type = "osxcross-macos-sdk";
              sdkRoot = "${args.sdk}/MacOSX${args.sdkVersion}.sdk";
            };
          mkOsxcross = args:
            args
            // {
              _type = "fake-osxcross-toolchain";
              darwinTarget = "darwin25";
              supportedArchs = ["x86_64"];
              effectiveOsxVersionMin = "10.13";
            };
          mkRustHelpers = toolchain: {
            _type = "fake-rust-helpers";
            inherit toolchain;
          };
        };
      };
      mkCross = import ./lib/cross.nix {osxcross = fakeOsxcross;};
      c = mkCross {
        inherit pkgs system;
        macosSdkStorePath = fakeSdkStorePath;
        osxSdkVersion = "26.1";
      };
    in
      assert c.macosSdk._type == "osxcross-macos-sdk";
      assert toString c.macosSdk.sdk == fakeSdkStorePath;
      assert c.macosSdk.sdkVersion == "26.1";
      assert c.macosSdk.sdkRoot == "${fakeSdkStorePath}/MacOSX26.1.sdk";
      assert c.osxcrossToolchain.macosSdk == c.macosSdk;
      assert c.osxcrossRustHelpers.toolchain == c.osxcrossToolchain;
      pkgs.runCommand "check-mkCross-osxcross-enabled-with-sdk-store-path" {} "touch $out"
    else pkgs.runCommand "check-mkCross-osxcross-enabled-with-sdk-store-path-skipped" {} "touch $out";

  # mkCross rejects ambiguous SDK inputs.
  mkCross-osxcross-sdk-input-conflict = let
    fakeMacosSdk = {
      _type = "osxcross-macos-sdk";
      sdk = pkgs.emptyDirectory;
      sdkVersion = "26.1";
      sdkRoot = "${pkgs.emptyDirectory}/MacOSX26.1.sdk";
    };
    conflict = builtins.tryEval (self.lib.mkCross {
      inherit pkgs system;
      sdkArchive = pkgs.emptyDirectory;
      macosSdk = fakeMacosSdk;
    });
    storeConflict = builtins.tryEval (self.lib.mkCross {
      inherit pkgs system;
      macosSdkStorePath = "/nix/store/00000000000000000000000000000000-macosx-sdk-26.1";
      sdkArchive = pkgs.emptyDirectory;
    });
  in
    assert conflict.success == false;
    assert storeConflict.success == false;
    pkgs.runCommand "check-mkCross-osxcross-sdk-input-conflict" {} "touch $out";

  validate-macos-sdk-fixtures =
    pkgs.runCommand "check-validate-macos-sdk-fixtures" {} ''
      "${self.packages.${system}.validate-macos-sdk}/bin/validate-macos-sdk" \
        "${./tests/fixtures/macos-sdk-complete/MacOSX26.1.sdk}" 26.1 > complete
      if "${self.packages.${system}.validate-macos-sdk}/bin/validate-macos-sdk" \
        "${./tests/fixtures/macos-sdk-incomplete/MacOSX26.1.sdk}" 26.1 > incomplete.out 2> incomplete.err
      then
        echo "incomplete SDK unexpectedly passed validation" >&2
        exit 1
      fi
      grep 'TargetConditionals.h' incomplete.err
      grep 'SystemConfiguration.framework' incomplete.err
      grep 'CoreFoundation.framework' incomplete.err
      touch "$out"
    '';

  # mkDevShells returns expected shell variants
  mkDevShells-shape = let
    s = self.lib.mkDevShells {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
    };
  in
    assert s ? default;
    assert s ? windows;
    assert s ? macos;
    assert s ? cross;
    pkgs.runCommand "check-mkDevShells-shape" {} "touch $out";

  # mkDevShells accepts pkg-config dependency inputs
  mkDevShells-pkg-config-deps = let
    s = self.lib.mkDevShells {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
      pkgConfigDeps = with pkgs; [
        wayland
        libxkbcommon
      ];
    };
  in
    assert s ? default;
    pkgs.runCommand "check-mkDevShells-pkg-config-deps" {} "touch $out";

  # findLocalMavenCache returns null until both hash and host tarball exist.
  findLocalMavenCache-missing-inputs = let
    missingHash = self.lib.findLocalMavenCache {
      sha256Path = ./tests/fixtures/android-maven-cache/missing.sha256;
      hostPath = ./tests/fixtures/android-maven-cache/cache.tar;
      name = "fixture-cache.tar";
    };
    missingTar = self.lib.findLocalMavenCache {
      sha256Path = ./tests/fixtures/android-maven-cache/cache.sha256;
      hostPath = ./tests/fixtures/android-maven-cache/missing.tar;
      name = "fixture-cache.tar";
    };
  in
    assert missingHash == null;
    assert missingTar == null;
    pkgs.runCommand "check-findLocalMavenCache-missing-inputs" {} "touch $out";

  # findLocalMavenCache imports a flat-hashed tarball as a store path.
  findLocalMavenCache-flat-hash = let
    cache = self.lib.findLocalMavenCache {
      sha256Path = ./tests/fixtures/android-maven-cache/cache.sha256;
      hostPath = ./tests/fixtures/android-maven-cache/cache.tar;
      name = "fixture-cache.tar";
    };
  in
    assert cache != null;
    assert pkgs.lib.hasSuffix "-fixture-cache.tar" (builtins.baseNameOf cache);
    pkgs.runCommand "check-findLocalMavenCache-flat-hash" {} "touch $out";

  # mkAndroidFlavorTable expands asymmetric flavor modes into packages, dev
  # builders, and app wrappers while preserving caller-owned public names.
  mkAndroidFlavorTable-shape = let
    table = self.lib.mkAndroidFlavorTable {
      inherit pkgs;
      androidSdk = pkgs.emptyDirectory;
      rustToolchain = pkgs.emptyDirectory;
      workspaceSrc = pkgs.emptyDirectory;
      commonCargoFeatures = ["tutorial"];
      commonCargoNoDefaultFeatures = true;
      flavors = {
        app = {
          cargoPkg = "game";
          gradleModule = ":app";
          packageModes = ["debug" "release"];
          packageAttr = mode: "android-apk-${mode}";
          devAppAttr = "android-apk";
        };
        test-peer = {
          cargoPkg = "game-test-peer";
          gradleModule = ":test-peer";
          packageModes = ["debug"];
          packageAttr = mode: "android-test-peer-apk";
          devAppAttr = "android-test-peer-apk";
        };
      };
    };
  in
    assert table ? packages;
    assert table ? devBuilders;
    assert table ? apps;
    assert table.packages ? android-apk-debug;
    assert table.packages ? android-apk-release;
    assert table.packages ? android-test-peer-apk;
    assert !(table.packages ? android-test-peer-apk-release);
    assert table.devBuilders ? android-apk;
    assert table.devBuilders ? android-test-peer-apk;
    assert table.apps.android-apk.type == "app";
    assert table.apps.android-test-peer-apk.type == "app";
    pkgs.runCommand "check-mkAndroidFlavorTable-shape" {} "touch $out";

  # mkSteamRuntimeTools returns expected metadata and packages.
  # rsHarborCli is now required, so we pass the flake-built CLI here.
  mkSteamRuntimeTools-shape = let
    s = self.lib.mkSteamRuntimeTools {
      inherit pkgs;
      rsHarborCli = self.packages.${system}.rs-harbor;
    };
  in
    assert s ? runtimes;
    assert s ? selectedRuntime;
    assert s ? image;
    assert s ? containerCommandText;
    assert s ? steamRuntimeExec;
    assert s ? auditElfRuntimeDeps;
    assert s ? auditWindowsRuntimeDeps;
    assert s ? auditDarwinRuntimeDeps;
    assert s.packages ? steamRuntimeExec;
    assert s.packages ? auditElfRuntimeDeps;
    assert s.selectedRuntime.name == "Steam Linux Runtime 3.0 (sniper)";
    assert s.image == "registry.gitlab.steamos.cloud/steamrt/sniper/sdk";
    assert s ? defaultAllowRegexes;
    assert s.defaultAllowRegexes ? linuxNeeded;
    assert s.defaultAllowRegexes ? windowsDll;
    assert s.defaultAllowRegexes ? macosDylib;
    assert builtins.match s.defaultAllowRegexes.linuxNeeded "libsteam_api.so" != null;
    assert builtins.match s.defaultAllowRegexes.linuxNeeded "libc.so.6" != null;
    assert builtins.match s.defaultAllowRegexes.linuxNeeded "libsketchy.so" == null;
    assert builtins.match s.defaultAllowRegexes.windowsDll "steam_api64.dll" != null;
    assert builtins.match s.defaultAllowRegexes.windowsDll "KERNEL32.dll" != null;
    assert builtins.match s.defaultAllowRegexes.windowsDll "OPENGL32.dll" != null;
    assert builtins.match "${s.defaultAllowRegexes.macosDylib}.*" "@rpath/libfoo.dylib" != null;
    assert builtins.match "${s.defaultAllowRegexes.macosDylib}.*" "/usr/local/lib/libfoo.dylib" == null;
    assert s ? steamworksRsCargoLibraryHook;
    assert pkgs.lib.hasInfix "redistributable_bin/linux64" s.steamworksRsCargoLibraryHook;
    assert pkgs.lib.hasInfix "LD_LIBRARY_PATH" s.steamworksRsCargoLibraryHook;
    assert s ? steamRuntimeCargoBootstrap;
    assert s.packages ? steamRuntimeCargoBootstrap;
    pkgs.runCommand "check-mkSteamRuntimeTools-shape" {} ''
      "${s.steamRuntimeCargoBootstrap}/bin/steam-runtime-cargo-bootstrap" --help > help
      grep -- '--features LIST' help
      grep 'STEAM_RUNTIME_BUILD_ROOT' help
      grep 'STEAM_RUNTIME_TARGET' help
      touch "$out"
    '';

  # bootstrap-cmds-mig is exposed as a flake package
  bootstrap-cmds-mig-shape =
    pkgs.runCommand "check-bootstrap-cmds-mig-shape" {} ''
      mig="${self.packages.${system}.bootstrap-cmds-mig}/bin/mig"
      test -x "$mig"
      touch "$out"
    '';

  # mkOsxcrossHooks emits both shell-hook fragments
  mkOsxcrossHooks-shape = let
    h = self.lib.mkOsxcrossHooks {llvmPackages = pkgs.llvmPackages;};
  in
    assert h ? appleClangShimsHook;
    assert h ? macosShellGuard;
    assert pkgs.lib.hasInfix "OSXCROSS_TARGET_DIR" h.appleClangShimsHook;
    assert pkgs.lib.hasInfix "RS_HARBOR_HOST_CLANG" h.appleClangShimsHook;
    assert pkgs.lib.hasInfix "OSXCROSS_SDKROOT" h.macosShellGuard;
    assert pkgs.lib.hasInfix "CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER" h.macosShellGuard;
    pkgs.runCommand "check-mkOsxcrossHooks-shape" {} "touch $out";

  # mkWindowsMsvcDevShell evaluates and produces a derivation with the
  # MSVC env vars wired up
  mkWindowsMsvcDevShell-shape = let
    s = self.lib.mkWindowsMsvcDevShell {
      inherit pkgs;
      lib = pkgs.lib;
      llvmPackages = pkgs.llvmPackages;
      inherit toolchain;
    };
  in
    assert pkgs.lib.isDerivation s;
    assert s ? CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER;
    assert s ? CC_x86_64_pc_windows_msvc;
    assert s ? INCLUDE;
    assert s ? LIB;
    assert pkgs.lib.hasInfix "lld-link" s.CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER;
    pkgs.runCommand "check-mkWindowsMsvcDevShell-shape" {} "touch $out";

  # mkMacosUniversalStager exposes a stager package and the cargo profile snippet.
  # The stager is a thin shim around the rs-harbor Rust CLI's
  # `rs-harbor stage macos` subcommand.
  mkMacosUniversalStager-shape = let
    s = self.lib.mkMacosUniversalStager {
      inherit pkgs;
      rsHarborCli = self.packages.${system}.rs-harbor;
    };
  in
    assert s ? stager;
    assert s ? cargoMacosPackedDebuginfoSnippet;
    assert s.packages ? stageMacosUniversal;
    assert pkgs.lib.hasInfix "split-debuginfo = \"packed\"" s.cargoMacosPackedDebuginfoSnippet;
    pkgs.runCommand "check-mkMacosUniversalStager-shape" {} ''
      "${s.stager}/bin/stage-macos-universal" --help > help
      grep -- '--binary <BINARY>' help
      grep -- '--dylib <DYLIB>' help
      grep -- '--archs <ARCHS>' help
      touch "$out"
    '';

  # The rs-harbor CLI exposes top-level subcommands.
  rs-harbor-cli-shape =
    pkgs.runCommand "check-rs-harbor-cli-shape" {} ''
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" --help > help
      grep 'rs-harbor build helpers' help
      grep 'stage' help
      grep 'audit' help
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" stage --help > stage-help
      grep 'macos' stage-help
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" audit --help > audit-help
      grep 'elf' audit-help
      grep 'pe' audit-help
      grep 'macho' audit-help
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" audit elf --help > elf-help
      grep -- '--allow-needed-regex' elf-help
      grep -- '--require-origin-rpath' elf-help
      grep -- '--skip-ldd' elf-help
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" audit pe --help > pe-help
      grep -- '--allow-dll-regex' pe-help
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" audit macho --help > macho-help
      grep -- '--allow-dylib-regex' macho-help
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" steam-runtime --help > sr-help
      grep 'exec' sr-help
      "${self.packages.${system}.rs-harbor}/bin/rs-harbor" steam-runtime exec --help > sr-exec-help
      grep -- '--image' sr-exec-help
      grep -- '--container-runtime' sr-exec-help
      grep -- '--mount-nix-store' sr-exec-help
      touch "$out"
    '';

  # When mkSteamRuntimeTools is given an rsHarborCli, the audit helpers
  # become thin shims around `rs-harbor audit ...`.
  mkSteamRuntimeTools-rust-audit-shims = let
    s = self.lib.mkSteamRuntimeTools {
      inherit pkgs;
      rsHarborCli = self.packages.${system}.rs-harbor;
    };
  in
    pkgs.runCommand "check-mkSteamRuntimeTools-rust-audit-shims" {} ''
      "${s.auditElfRuntimeDeps}/bin/audit-elf-runtime-deps" --help > elf-help
      grep 'rs-harbor audit elf' elf-help
      grep -- '--allow-needed-regex' elf-help
      "${s.auditWindowsRuntimeDeps}/bin/audit-windows-runtime-deps" --help > pe-help
      grep -- '--allow-dll-regex' pe-help
      "${s.auditDarwinRuntimeDeps}/bin/audit-darwin-runtime-deps" --help > macho-help
      grep -- '--allow-dylib-regex' macho-help
      touch "$out"
    '';

  # mkSteamRuntimeTools threads steamworksRsLibSubdir through the cargo hook
  mkSteamRuntimeTools-steamworks-subdir = let
    s = self.lib.mkSteamRuntimeTools {
      inherit pkgs;
      rsHarborCli = self.packages.${system}.rs-harbor;
      steamworksRsLibSubdir = "osx";
    };
  in
    assert pkgs.lib.hasInfix "redistributable_bin/osx" s.steamworksRsCargoLibraryHook;
    pkgs.runCommand "check-mkSteamRuntimeTools-steamworks-subdir" {} "touch $out";

  # mkSteamRuntimeTools supports custom images without changing downstream policy
  mkSteamRuntimeTools-custom-image = let
    s = self.lib.mkSteamRuntimeTools {
      inherit pkgs;
      rsHarborCli = self.packages.${system}.rs-harbor;
      runtime = "custom";
      customImage = "registry.example.com/custom/steam-sdk:latest";
      containerRuntime = "docker";
    };
  in
    assert s.selectedRuntime.name == "custom";
    assert s.image == "registry.example.com/custom/steam-sdk:latest";
    assert pkgs.lib.hasInfix "docker run" s.containerCommandText;
    pkgs.runCommand "check-mkSteamRuntimeTools-custom-image" {} "touch $out";

  # mkCargoConfig returns expected attributes
  mkCargoConfig-shape = let
    c = self.lib.mkCargoConfig {inherit pkgs;};
  in
    assert c ? configText;
    assert c ? configPath;
    assert builtins.isString c.configText;
    pkgs.runCommand "check-mkCargoConfig-shape" {} "touch $out";

  # mkCargoConfig stable disables nightly features by default
  mkCargoConfig-stable = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      channel = "stable";
    };
  in
    assert !(pkgs.lib.hasInfix "cranelift" c.configText);
    assert !(pkgs.lib.hasInfix "share-generics" c.configText);
    assert !(pkgs.lib.hasInfix "threads" c.configText);
    pkgs.runCommand "check-mkCargoConfig-stable" {} "touch $out";

  # mkCargoConfig nightly includes expected optimizations
  mkCargoConfig-nightly = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      channel = "nightly";
    };
  in
    assert pkgs.lib.hasInfix "cranelift" c.configText;
    assert pkgs.lib.hasInfix "share-generics" c.configText;
    assert pkgs.lib.hasInfix "mold" c.configText;
    assert pkgs.lib.hasInfix "threads" c.configText;
    pkgs.runCommand "check-mkCargoConfig-nightly" {} "touch $out";

  # mkCargoConfig respects enableMold = false
  mkCargoConfig-no-mold = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      enableMold = false;
    };
  in
    assert !(pkgs.lib.hasInfix "mold" c.configText);
    pkgs.runCommand "check-mkCargoConfig-no-mold" {} "touch $out";

  # Windows GNU should not force lld through the MinGW GCC wrapper
  mkCargoConfig-no-windows-gnu-lld = let
    c = self.lib.mkCargoConfig {inherit pkgs;};
  in
    assert !(pkgs.lib.hasInfix "link-arg=-fuse-ld=lld" c.configText);
    pkgs.runCommand "check-mkCargoConfig-no-windows-gnu-lld" {} "touch $out";

  # mkCargoConfig respects enableParallelFrontend = false
  mkCargoConfig-no-parallel-frontend = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      enableParallelFrontend = false;
    };
  in
    assert !(pkgs.lib.hasInfix "threads" c.configText);
    pkgs.runCommand "check-mkCargoConfig-no-parallel-frontend" {} "touch $out";

  # mkAdapter returns expected attributes
  mkAdapter-shape = let
    a = self.lib.mkAdapter {
      attic = {endpoint = "https://cache.example.com"; cache = "main";};
    };
  in
    assert a ? _type;
    assert a._type == "harbor-adapter";
    assert a ? _version;
    assert a._version == 1;
    assert a ? attic;
    assert a.attic ? endpoint;
    assert a.attic ? cache;
    assert a.attic ? tokenEnvVar;
    assert a.attic.tokenEnvVar == "ATTIC_TOKEN";
    assert a.attic ? serverName;
    assert a.attic.serverName == "harbor";
    pkgs.runCommand "check-mkAdapter-shape" {} "touch $out";

  # mkAdapter preserves custom tokenEnvVar
  mkAdapter-custom-token = let
    a = self.lib.mkAdapter {
      attic = {endpoint = "https://cache.example.com"; cache = "main"; tokenEnvVar = "MY_TOKEN";};
    };
  in
    assert a.attic.tokenEnvVar == "MY_TOKEN";
    pkgs.runCommand "check-mkAdapter-custom-token" {} "touch $out";

  # isHarborAdapter accepts valid adapters
  isHarborAdapter-valid = let
    a = self.lib.mkAdapter {
      attic = {endpoint = "https://x.com"; cache = "c";};
    };
  in
    assert self.lib.isHarborAdapter a;
    pkgs.runCommand "check-isHarborAdapter-valid" {} "touch $out";

  # isHarborAdapter rejects invalid values
  isHarborAdapter-invalid =
    assert !(self.lib.isHarborAdapter {});
    assert !(self.lib.isHarborAdapter {_type = "wrong";});
    assert !(self.lib.isHarborAdapter "string");
    assert !(self.lib.isHarborAdapter 42);
    pkgs.runCommand "check-isHarborAdapter-invalid" {} "touch $out";

  # mkAtticPush returns a valid app attrset
  mkAtticPush-shape = let
    adapter = self.lib.mkAdapter {
      attic = {endpoint = "https://x.com"; cache = "c";};
    };
    app = self.lib.mkAtticPush {
      inherit pkgs adapter;
      paths = [pkgs.hello];
    };
  in
    assert app ? type;
    assert app.type == "app";
    assert app ? program;
    assert builtins.isString app.program;
    pkgs.runCommand "check-mkAtticPush-shape" {} "touch $out";

  # mkCoprSpec returns expected attributes with default binary-shipping layout
  mkCoprSpec-shape = let
    s = self.lib.mkCoprSpec {
      inherit pkgs;
      name = "test-app";
      version = "1.0.0";
      summary = "Test summary";
      license = "MIT";
    };
  in
    assert s ? specText;
    assert s ? specPath;
    assert !(s ? coprMakefilePath);
    assert builtins.isString s.specText;
    assert pkgs.lib.hasInfix "Name:    test-app" s.specText;
    assert pkgs.lib.hasInfix "Version: 1.0.0" s.specText;
    assert pkgs.lib.hasInfix "License: MIT" s.specText;
    assert pkgs.lib.hasInfix "Source0: %{name}-%{version}.tar.gz" s.specText;
    assert pkgs.lib.hasInfix "%{_bindir}/%{name}" s.specText;
    assert pkgs.lib.hasInfix "%description\nTest summary" s.specText;
    pkgs.runCommand "check-mkCoprSpec-shape" {} "touch $out";

  # mkCoprSpec includes desktop + icon install rules when provided
  mkCoprSpec-desktop-icon = let
    s = self.lib.mkCoprSpec {
      inherit pkgs;
      name = "myapp";
      version = "2.3";
      summary = "Demo";
      license = "Apache-2.0";
      appId = "com.example.MyApp";
      desktopFile = "[Desktop Entry]\nType=Application";
      icon = "/some/path/myapp.png";
    };
  in
    assert pkgs.lib.hasInfix "com.example.MyApp.desktop" s.specText;
    assert pkgs.lib.hasInfix "hicolor/256x256/apps/com.example.MyApp.png" s.specText;
    assert pkgs.lib.hasInfix "install -Dm644 myapp.png" s.specText;
    pkgs.runCommand "check-mkCoprSpec-desktop-icon" {} "touch $out";

  # mkCoprSpec emits a custom-build Makefile when requested
  mkCoprSpec-copr-makefile = let
    s = self.lib.mkCoprSpec {
      inherit pkgs;
      name = "withmake";
      version = "0.1";
      summary = "x";
      license = "MIT";
      coprMakefile = true;
    };
  in
    assert s ? coprMakefilePath;
    pkgs.runCommand "check-mkCoprSpec-copr-makefile" {} ''
      grep 'SPEC := withmake.spec' ${s.coprMakefilePath}
      grep '^srpm:' ${s.coprMakefilePath}
      grep 'rpmbuild -bs' ${s.coprMakefilePath}
      touch $out
    '';

  # mkCoprSpec renders changelog entries in RPM format
  mkCoprSpec-changelog = let
    s = self.lib.mkCoprSpec {
      inherit pkgs;
      name = "cl";
      version = "1.2";
      summary = "x";
      license = "MIT";
      changelog = [
        {
          date = "Tue May 19 2026";
          author = "Can <can@example.com>";
          version = "1.2-1";
          entries = ["Bump to 1.2" "Fix the bug"];
        }
      ];
    };
  in
    assert pkgs.lib.hasInfix "%changelog" s.specText;
    assert pkgs.lib.hasInfix "* Tue May 19 2026 Can <can@example.com> - 1.2-1" s.specText;
    assert pkgs.lib.hasInfix "- Bump to 1.2" s.specText;
    assert pkgs.lib.hasInfix "- Fix the bug" s.specText;
    pkgs.runCommand "check-mkCoprSpec-changelog" {} "touch $out";

  # mkCoprSpec rejects an RPM-illegal version (contains '-')
  mkCoprSpec-rejects-bad-version = let
    result = builtins.tryEval (self.lib.mkCoprSpec {
      inherit pkgs;
      name = "x";
      version = "1.0-beta";
      summary = "x";
      license = "MIT";
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkCoprSpec-rejects-bad-version" {} "touch $out";

  # mkCoprSpec rejects a non-reverse-DNS appId
  mkCoprSpec-rejects-bad-appid = let
    result = builtins.tryEval (self.lib.mkCoprSpec {
      inherit pkgs;
      name = "x";
      version = "1";
      summary = "x";
      license = "MIT";
      appId = "notReverseDns";
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkCoprSpec-rejects-bad-appid" {} "touch $out";

  # Validation logic works correctly
  validation-helpers = let
    dateRegex = "[0-9]{4}-[0-9]{2}-[0-9]{2}";
  in
    assert builtins.match dateRegex "2025-12-01" != null;
    assert builtins.match dateRegex "yesterday" == null;
    assert builtins.match dateRegex "25-12-01" == null;
    assert builtins.elem "nightly" ["nightly" "stable"];
    assert builtins.elem "stable" ["nightly" "stable"];
    assert !(builtins.elem "beta" ["nightly" "stable"]);
    pkgs.runCommand "check-validation-helpers" {} "touch $out";

  # mkHomebrewFormula returns expected attributes and a binary install block.
  mkHomebrewFormula-shape = let
    f = self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "modde";
      version = "1.2.3";
      description = "Cross-platform game mod manager";
      homepage = "https://modde.tartanoglu.com";
      license = "MIT";
      platforms.darwin_arm = {
        url = "https://codeberg.org/caniko/modde/releases/download/1.2.3/modde-1.2.3-aarch64-darwin.tar.gz";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      dependencies = ["openssl@3"];
      binaries = ["modde" "modde-ui"];
      testBlock = ''system "#{bin}/modde", "--version"'';
    };
  in
    assert f ? formulaText;
    assert f ? formulaPath;
    assert builtins.isString f.formulaText;
    assert pkgs.lib.hasInfix "class Modde < Formula" f.formulaText;
    assert pkgs.lib.hasInfix "def install" f.formulaText;
    assert pkgs.lib.hasInfix ''bin.install "modde"'' f.formulaText;
    assert pkgs.lib.hasInfix ''bin.install "modde-ui"'' f.formulaText;
    assert pkgs.lib.hasInfix ''depends_on "openssl@3"'' f.formulaText;
    pkgs.runCommand "check-mkHomebrewFormula-shape" {} ''
      grep 'class Modde < Formula' ${f.formulaPath}
      grep 'def install' ${f.formulaPath}
      touch $out
    '';

  # mkHomebrewFormula nests architecture stanzas under OS platform blocks.
  mkHomebrewFormula-multi-platform = let
    both = self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "multi-app";
      version = "1.0.0";
      description = "Multi platform app";
      homepage = "https://example.com";
      license = "Apache-2.0";
      platforms = {
        darwin_arm = {
          url = "https://example.com/multi-app-1.0.0-aarch64-darwin.tar.gz";
          sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        };
        linux_intel = {
          url = "https://example.com/multi-app-1.0.0-x86_64-linux.tar.gz";
          sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        };
      };
    };
    macOnly = self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "mac-app";
      version = "1.0.0";
      description = "Mac only app";
      homepage = "https://example.com";
      license = "MIT";
      platforms.darwin_intel = {
        url = "https://example.com/mac-app-1.0.0-x86_64-darwin.tar.gz";
        sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
      };
    };
  in
    assert pkgs.lib.hasInfix "on_macos do" both.formulaText;
    assert pkgs.lib.hasInfix "on_linux do" both.formulaText;
    assert pkgs.lib.hasInfix "on_arm do" both.formulaText;
    assert pkgs.lib.hasInfix "on_intel do" both.formulaText;
    assert pkgs.lib.hasInfix "on_macos do" macOnly.formulaText;
    assert !(pkgs.lib.hasInfix "on_linux do" macOnly.formulaText);
    pkgs.runCommand "check-mkHomebrewFormula-multi-platform" {} "touch $out";

  # mkHomebrewFormula emits Homebrew's checksum skip symbol for placeholders.
  mkHomebrewFormula-no-check-placeholder = let
    f = self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "placeholder-app";
      version = "1.0.0";
      description = "Placeholder checksum app";
      homepage = "https://example.com";
      license = "MIT";
      platforms.linux_intel = {
        url = "https://example.com/placeholder-app-1.0.0-x86_64-linux.tar.gz";
        sha256 = ":no_check";
      };
    };
  in
    assert pkgs.lib.hasInfix "sha256 :no_check" f.formulaText;
    assert !(pkgs.lib.hasInfix ''sha256 ":no_check"'' f.formulaText);
    pkgs.runCommand "check-mkHomebrewFormula-no-check-placeholder" {} "touch $out";

  # mkHomebrewFormula rejects a Homebrew-illegal formula name.
  mkHomebrewFormula-rejects-bad-name = let
    result = builtins.tryEval (self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "Bad_Name";
      version = "1.0.0";
      description = "Bad name app";
      homepage = "https://example.com";
      license = "MIT";
      platforms.linux_intel = {
        url = "https://example.com/bad-name.tar.gz";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkHomebrewFormula-rejects-bad-name" {} "touch $out";

  # mkHomebrewFormula rejects versions with a leading v.
  mkHomebrewFormula-rejects-bad-version = let
    result = builtins.tryEval (self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "bad-version";
      version = "v1.0.0";
      description = "Bad version app";
      homepage = "https://example.com";
      license = "MIT";
      platforms.linux_intel = {
        url = "https://example.com/bad-version.tar.gz";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkHomebrewFormula-rejects-bad-version" {} "touch $out";

  # mkHomebrewFormula rejects descriptions longer than Homebrew audit allows.
  mkHomebrewFormula-rejects-long-desc = let
    result = builtins.tryEval (self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "long-desc";
      version = "1.0.0";
      description = "This description is deliberately longer than eighty characters so validation rejects it.";
      homepage = "https://example.com";
      license = "MIT";
      platforms.linux_intel = {
        url = "https://example.com/long-desc.tar.gz";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkHomebrewFormula-rejects-long-desc" {} "touch $out";

  # mkHomebrewFormula rejects non-HTTPS homepages.
  mkHomebrewFormula-rejects-http-homepage = let
    result = builtins.tryEval (self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "http-homepage";
      version = "1.0.0";
      description = "HTTP homepage app";
      homepage = "http://example.com";
      license = "MIT";
      platforms.linux_intel = {
        url = "https://example.com/http-homepage.tar.gz";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkHomebrewFormula-rejects-http-homepage" {} "touch $out";

  # mkHomebrewFormula rejects unsupported platform keys.
  mkHomebrewFormula-rejects-bad-platform = let
    result = builtins.tryEval (self.lib.mkHomebrewFormula {
      inherit pkgs;
      name = "bad-platform";
      version = "1.0.0";
      description = "Bad platform app";
      homepage = "https://example.com";
      license = "MIT";
      platforms.freebsd_intel = {
        url = "https://example.com/bad-platform.tar.gz";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkHomebrewFormula-rejects-bad-platform" {} "touch $out";
}
// pkgs.lib.optionalAttrs isLinux {
  # mkFlatpakManifest returns expected attributes
  mkFlatpakManifest-shape = let
    m = self.lib.mkFlatpakManifest {
      inherit pkgs;
      appId = "com.example.TestApp";
      pname = "test-app";
      desktopFile = "[Desktop Entry]\nType=Application\nName=Test\nExec=test-app";
    };
  in
    assert m ? manifestText;
    assert m ? manifestPath;
    assert builtins.isString m.manifestText;
    assert pkgs.lib.hasInfix "com.example.TestApp" m.manifestText;
    assert pkgs.lib.hasInfix "test-app" m.manifestText;
    assert pkgs.lib.hasInfix "org.freedesktop.Platform" m.manifestText;
    assert pkgs.lib.hasInfix "24.08" m.manifestText;
    pkgs.runCommand "check-mkFlatpakManifest-shape" {} "touch $out";

  # mkFlatpakManifest respects custom runtime
  mkFlatpakManifest-custom-runtime = let
    m = self.lib.mkFlatpakManifest {
      inherit pkgs;
      appId = "org.test.App";
      pname = "myapp";
      desktopFile = "[Desktop Entry]\nType=Application\nName=Test\nExec=myapp";
      runtime = "org.gnome.Platform";
      runtimeVersion = "46";
      sdk = "org.gnome.Sdk";
    };
  in
    assert pkgs.lib.hasInfix "org.gnome.Platform" m.manifestText;
    assert pkgs.lib.hasInfix "46" m.manifestText;
    assert pkgs.lib.hasInfix "org.gnome.Sdk" m.manifestText;
    pkgs.runCommand "check-mkFlatpakManifest-custom-runtime" {} "touch $out";

  # mkFlatpakManifest respects custom finishArgs
  mkFlatpakManifest-finish-args = let
    m = self.lib.mkFlatpakManifest {
      inherit pkgs;
      appId = "org.test.App2";
      pname = "myapp2";
      desktopFile = "[Desktop Entry]\nType=Application\nName=Test\nExec=myapp2";
      finishArgs = ["--share=network" "--socket=x11"];
    };
  in
    assert pkgs.lib.hasInfix "share=network" m.manifestText;
    assert pkgs.lib.hasInfix "socket=x11" m.manifestText;
    pkgs.runCommand "check-mkFlatpakManifest-finish-args" {} "touch $out";

  # mkAndroidApk produces a derivation with the project-specific bits
  # baked into the build script. We don't try to actually build the APK
  # in CI (it needs the Android SDK + a real `cargo ndk` workflow);
  # instead we evaluate the derivation and assert basic shape.
  mkAndroidApk-shape = let
    fakeSdk = pkgs.runCommand "fake-androidsdk" {} ''
      mkdir -p $out/libexec/android-sdk/ndk/29.0.14206865
      mkdir -p $out/libexec/android-sdk/platform-tools
      mkdir -p $out/libexec/android-sdk/emulator
    '';
    fakeToolchain = pkgs.symlinkJoin {
      name = "fake-rust";
      paths = [pkgs.coreutils];
    };
    drv = self.lib.mkAndroidApk {
      inherit pkgs;
      androidSdk = fakeSdk;
      rustToolchain = fakeToolchain;
      workspaceSrc = ./.;
      cargoPkg = "test-pkg";
      gradleModule = ":app";
      jniLibsDir = "android/app/src/main/jniLibs";
      apkOutPath = "android/app/build/outputs/apk/debug/app-debug.apk";
      cargoNoDefaultFeatures = true;
      cargoFeatures = ["alpha" "beta"];
    };
  in
    assert drv.pname == "android-apk";
    assert drv.drvAttrs ? __noChroot;
    assert drv.drvAttrs.__noChroot == true;
    assert pkgs.lib.hasInfix "cargo ndk -t arm64-v8a" drv.drvAttrs.buildPhase;
    assert pkgs.lib.hasInfix "test-pkg" drv.drvAttrs.buildPhase;
    assert pkgs.lib.hasInfix "--no-default-features" drv.drvAttrs.buildPhase;
    assert pkgs.lib.hasInfix "--features alpha,beta" drv.drvAttrs.buildPhase;
    assert pkgs.lib.hasInfix ":app:assembleDebug" drv.drvAttrs.buildPhase;
    assert !(pkgs.lib.hasInfix "--offline" drv.drvAttrs.buildPhase);
    pkgs.runCommand "check-mkAndroidApk-shape" {} "touch $out";

  # Hermetic mode flips to gradle --offline + drops __noChroot.
  mkAndroidApk-hermetic = let
    fakeSdk = pkgs.runCommand "fake-androidsdk" {} ''
      mkdir -p $out/libexec/android-sdk/ndk/29.0.14206865
    '';
    fakeToolchain = pkgs.symlinkJoin {
      name = "fake-rust";
      paths = [pkgs.coreutils];
    };
    fakeCacheTar = pkgs.runCommand "fake-cache.tar" {} ''
      mkdir -p $out
      touch $out/dummy
    '';
    drv = self.lib.mkAndroidApk {
      inherit pkgs;
      androidSdk = fakeSdk;
      rustToolchain = fakeToolchain;
      workspaceSrc = ./.;
      cargoPkg = "test-peer";
      gradleModule = ":test-peer";
      jniLibsDir = "android/test-peer/src/main/jniLibs";
      apkOutPath = "android/test-peer/build/outputs/apk/release/test-peer-release.apk";
      mode = "release";
      mavenCacheTar = fakeCacheTar;
    };
  in
    assert !(drv.drvAttrs ? __noChroot && drv.drvAttrs.__noChroot == true);
    assert pkgs.lib.hasInfix "--offline" drv.drvAttrs.buildPhase;
    assert pkgs.lib.hasInfix ":test-peer:assembleRelease" drv.drvAttrs.buildPhase;
    assert pkgs.lib.hasInfix "--release" drv.drvAttrs.buildPhase;
    assert pkgs.lib.hasInfix "extracted maven cache" drv.drvAttrs.preBuild;
    pkgs.runCommand "check-mkAndroidApk-hermetic" {} "touch $out";

  # Bad inputs are rejected with clear messages.
  mkAndroidApk-rejects-bad-mode = let
    fakeSdk = pkgs.runCommand "fake-androidsdk" {} "mkdir -p $out";
    fakeToolchain = pkgs.symlinkJoin {
      name = "fake-rust";
      paths = [pkgs.coreutils];
    };
    result = builtins.tryEval (self.lib.mkAndroidApk {
      inherit pkgs;
      androidSdk = fakeSdk;
      rustToolchain = fakeToolchain;
      workspaceSrc = ./.;
      cargoPkg = "x";
      gradleModule = ":x";
      jniLibsDir = "x";
      apkOutPath = "x";
      mode = "bogus";
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkAndroidApk-rejects-bad-mode" {} "touch $out";

  mkAndroidApk-rejects-missing-toolchain = let
    fakeSdk = pkgs.runCommand "fake-androidsdk" {} "mkdir -p $out";
    result = builtins.tryEval (self.lib.mkAndroidApk {
      inherit pkgs;
      androidSdk = fakeSdk;
      rustToolchain = null;
      workspaceSrc = ./.;
      cargoPkg = "x";
      gradleModule = ":x";
      jniLibsDir = "x";
      apkOutPath = "x";
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkAndroidApk-rejects-missing-toolchain" {} "touch $out";

  mkAndroidApkDevBuilder-shape = let
    script = self.lib.mkAndroidApkDevBuilder {
      inherit pkgs;
      defaultFlavor = "test-peer";
      cargoNoDefaultFeatures = true;
      cargoFeatures = ["tutorial"];
      flavors = {
        app = {
          cargoPkg = "game";
          gradleModule = ":app";
          jniLibsDir = "android/app/src/main/jniLibs";
          apkOutPath = "android/app/build/outputs/apk/debug/app-debug.apk";
        };
        test-peer = {
          cargoPkg = "game-android-test-peer";
          gradleModule = ":test-peer";
          jniLibsDir = "android/test-peer/src/main/jniLibs";
          apkOutPath = "android/test-peer/build/outputs/apk/debug/test-peer-debug.apk";
        };
      };
    };
  in
    pkgs.runCommand "check-mkAndroidApkDevBuilder-shape" {} ''
      cp ${script} script
      grep 'cargo ndk -t "$abi" -o "$jni_libs_dir" build' script
      grep 'game-android-test-peer' script
      grep 'gradle_module=:test-peer' script
      grep 'gradle "$gradle_module:assemble$mode_cap"' script
      grep -- '--no-default-features' script
      grep -- '--features tutorial' script
      touch $out
    '';
}
