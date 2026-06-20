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

  # The NixOS module must pass both the SDK store path and recursive hash to
  # mkCross so sandboxed builds receive the SDK as a real build input.
  nixos-module-macos-sdk-mk-cross-args = let
    evaluated = pkgs.lib.evalModules {
      modules = [
        self.nixosModules.macosSdk
        {
          options.systemd.tmpfiles.rules = pkgs.lib.mkOption {
            type = pkgs.lib.types.listOf pkgs.lib.types.str;
            default = [];
          };
        }
        {
          programs.rsHarbor.macosSdk = {
            enable = true;
            sdkVersion = "26.1";
            storePath = "/nix/store/00000000000000000000000000000000-macosx-sdk-26.1";
            outputHash = "sha256-fake";
          };
        }
      ];
    };
    args = evaluated.config.programs.rsHarbor.macosSdk.mkCrossArgs;
  in
    assert args.osxSdkVersion == "26.1";
    assert args.macosSdkStorePath == "/nix/store/00000000000000000000000000000000-macosx-sdk-26.1";
    assert args.macosSdkOutputHash == "sha256-fake";
    pkgs.runCommand "check-nixos-module-macos-sdk-mk-cross-args" {} "touch $out";

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

  # mkDocsShell evaluates as a dedicated devShell derivation
  mkDocsShell-shape = let
    s = self.lib.mkDocsShell {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
      packages = [pkgs.mdbook];
    };
  in
    assert builtins.isAttrs s;
    assert (s.type or null) == "derivation";
    pkgs.runCommand "check-mkDocsShell-shape" {} "touch $out";

  # mkDevShells accepts the full parameter set simit's cross_template()
  # passes: packages list with all audit/release tools, extraShellHook,
  # and checks.  This is the rs-harbor side of the simit↔rs-harbor
  # bidirectional contract — if this check fails, simit's generated
  # cross-compilation dev-shells are broken.
  mkDevShells-accepts-simit-parameters = let
    s = self.lib.mkDevShells {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
      packages = with pkgs; [
        cargo-about
        cargo-audit
        cargo-cyclonedx
        cargo-deny
        cargo-llvm-cov
        cargo-sbom
        cargo-nextest
        cosign
        file
        gnutar
        gzip
        jq
        minisign
        nodejs
        pre-commit
        rpm
        unzip
        zip
        reprepro
        rust-analyzer
        taplo
      ];
      extraShellHook = ''
        echo "simit-generated dev-shell ready" >&2
      '';
    };
  in
    assert s ? default;
    assert s ? windows;
    assert s ? macos;
    assert s ? cross;
    # Force evaluation of each derivation to confirm the full package
    # closure resolves.  Accessing .name is sufficient — the derivation
    # is instantiated without building it.
    assert builtins.isString s.default.name;
    assert builtins.isString s.windows.name;
    assert builtins.isString s.macos.name;
    assert builtins.isString s.cross.name;
    pkgs.runCommand "check-mkDevShells-accepts-simit-parameters" {} "touch $out";

  # cargo-audit and cargo-deny resolve in nixpkgs and are available on
  # PATH when added as build inputs.  This mirrors what happens inside a
  # dev-shell built by mkDevShells — packages in `packages` end up in
  # the shell's PATH via nativeBuildInputs.
  #
  # This is the companion to the simit↔rs-harbor bidirectional contract:
  # simit's generated cross-compilation flake passes these tools to
  # mkDevShells and expects them to resolve at evaluation time.
  mkDevShells-audit-tools-in-path =
    pkgs.runCommand "check-mkDevShells-audit-tools-in-path" {
      buildInputs = with pkgs; [cargo-audit cargo-deny cargo-sweep];
    } ''
      command -v cargo-audit >/dev/null || {
        echo "cargo-audit: not on PATH — simit requires it in every dev-shell"
        exit 1
      }
      command -v cargo-deny >/dev/null || {
        echo "cargo-deny: not on PATH — simit requires it for deny-enabled projects"
        exit 1
      }
      command -v cargo-sweep >/dev/null || {
        echo "cargo-sweep: not on PATH — rs-harbor base package is missing"
        exit 1
      }
      touch "$out"
    '';

  # mkCrossPackages returns only the requested targets keyed by output attr
  # name, and each derivation evaluates (we force drvPaths, not full builds).
  # native + windows are buildable on x86_64-linux without a macOS SDK.
  mkCrossPackages-shape = let
    fixtureSrc = ./tests/fixtures/cross-package-fixture;
    commonArgs = {
      src = fixtureSrc;
      version = "0.1.0";
      doCheck = false;
    };
    out = self.lib.mkCrossPackages {
      inherit pkgs cross commonArgs;
      inherit (toolchain) craneLib;
      pname = "fixture";
      targets = ["native" "windows"];
    };
  in
    assert out ? "fixture";
    assert out ? "fixture-windows";
    # Only the requested targets are present.
    assert !(out ? "fixture-aarch64-linux");
    assert !(out ? "fixture-darwin-x86_64");
    assert !(out ? "fixture-darwin-aarch64");
    assert pkgs.lib.isDerivation out."fixture";
    assert pkgs.lib.isDerivation out."fixture-windows";
    # Forcing drvPath proves the derivations evaluate without building Rust.
    assert builtins.isString out."fixture".drvPath;
    assert builtins.isString out."fixture-windows".drvPath;
    pkgs.runCommand "check-mkCrossPackages-shape" {} "touch $out";

  # mkCrossPackages rejects unsupported target names and commonArgs without src.
  mkCrossPackages-validation = let
    fixtureSrc = ./tests/fixtures/cross-package-fixture;
    badTarget = builtins.tryEval (self.lib.mkCrossPackages {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
      pname = "fixture";
      commonArgs = {src = fixtureSrc;};
      targets = ["native" "bogus"];
    });
    missingSrc = builtins.tryEval (self.lib.mkCrossPackages {
      inherit pkgs cross;
      inherit (toolchain) craneLib;
      pname = "fixture";
      commonArgs = {version = "0.1.0";};
      targets = ["native"];
    });
  in
    assert badTarget.success == false;
    assert missingSrc.success == false;
    pkgs.runCommand "check-mkCrossPackages-validation" {} "touch $out";

  # mkCrossPackages aarch64-linux + darwin targets. The aarch64 craneLib and the
  # darwin osxcross path are only meaningful on x86_64-linux, mirroring the
  # gating of the osxcross checks above. Darwin falls back to a runCommand that
  # exits 1 when no realized macOS SDK is available, so it still evaluates.
  mkCrossPackages-cross-targets =
    if system == "x86_64-linux"
    then let
      fixtureSrc = ./tests/fixtures/cross-package-fixture;
      commonArgs = {
        src = fixtureSrc;
        version = "0.1.0";
        doCheck = false;
      };
      out = self.lib.mkCrossPackages {
        inherit pkgs cross commonArgs;
        inherit (toolchain) craneLib;
        pname = "fixture";
        targets = ["aarch64-linux" "darwin-x86_64" "darwin-aarch64"];
      };
    in
      assert out ? "fixture-aarch64-linux";
      assert out ? "fixture-darwin-x86_64";
      assert out ? "fixture-darwin-aarch64";
      assert !(out ? "fixture");
      assert !(out ? "fixture-windows");
      assert pkgs.lib.isDerivation out."fixture-aarch64-linux";
      assert builtins.isString out."fixture-aarch64-linux".drvPath;
      # Without a realized SDK in pure eval, darwin outputs are the
      # mkDarwinUnavailable runCommand placeholders, which still evaluate.
      assert pkgs.lib.isDerivation out."fixture-darwin-x86_64";
      assert pkgs.lib.isDerivation out."fixture-darwin-aarch64";
      assert builtins.isString out."fixture-darwin-x86_64".drvPath;
      assert builtins.isString out."fixture-darwin-aarch64".drvPath;
      pkgs.runCommand "check-mkCrossPackages-cross-targets" {} "touch $out"
    else pkgs.runCommand "check-mkCrossPackages-cross-targets-skipped" {} "touch $out";

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

  # mkCargoConfig enables memory-saving dev profile defaults by default
  mkCargoConfig-dev-profile-opts = let
    enabled = self.lib.mkCargoConfig {inherit pkgs;};
    disabled = self.lib.mkCargoConfig {
      inherit pkgs;
      enableDevProfileOpts = false;
      devCodegenUnits = null;
    };
  in
    assert pkgs.lib.hasInfix "[profile.dev]" enabled.configText;
    assert pkgs.lib.hasInfix ''debug = "line-tables-only"'' enabled.configText;
    assert pkgs.lib.hasInfix ''split-debuginfo = "unpacked"'' enabled.configText;
    assert pkgs.lib.hasInfix ''[profile.dev.package."*"]'' enabled.configText;
    assert !(pkgs.lib.hasInfix "codegen-units = " enabled.configText);
    assert !(pkgs.lib.hasInfix ''debug = "line-tables-only"'' disabled.configText);
    assert !(pkgs.lib.hasInfix "split-debuginfo" disabled.configText);
    assert !(pkgs.lib.hasInfix "codegen-units" disabled.configText);
    assert !(pkgs.lib.hasInfix "debug = false" disabled.configText);
    pkgs.runCommand "check-mkCargoConfig-dev-profile-opts" {} "touch $out";

  # mkCargoConfig emits dev codegen-units only when explicitly requested
  mkCargoConfig-dev-codegen-units = let
    c = self.lib.mkCargoConfig {
      inherit pkgs;
      devCodegenUnits = 16;
    };
  in
    assert pkgs.lib.hasInfix "codegen-units = 16" c.configText;
    pkgs.runCommand "check-mkCargoConfig-dev-codegen-units" {} "touch $out";

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

  # mkChocoPackage returns expected attributes and package layout.
  mkChocoPackage-shape = let
    f = self.lib.mkChocoPackage {
      inherit pkgs;
      id = "modde";
      version = "1.2.3";
      description = "Cross-platform game mod manager for Windows";
      homepage = "https://modde.tartanoglu.com";
      license = "MIT";
      licenseUrl = "https://codeberg.org/caniko/modde/raw/branch/main/LICENSE";
      authors = ["Can Tartanoglu"];
      architectures.x64 = {
        url = "https://codeberg.org/caniko/modde/releases/download/1.2.3/modde-1.2.3-x86_64-pc-windows-msvc.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      binaries = ["modde"];
    };
  in
    assert f ? nuspecText;
    assert f ? installScriptText;
    assert f ? packageDir;
    assert builtins.isString f.nuspecText;
    assert builtins.isString f.installScriptText;
    assert pkgs.lib.hasInfix "<id>modde</id>" f.nuspecText;
    assert pkgs.lib.hasInfix "<version>1.2.3</version>" f.nuspecText;
    assert pkgs.lib.hasInfix "url64bit" f.installScriptText;
    assert pkgs.lib.hasInfix "checksum64" f.installScriptText;
    pkgs.runCommand "check-mkChocoPackage-shape" {
      nativeBuildInputs = [pkgs.libxml2];
    } ''
      test -f ${f.packageDir}/modde.nuspec
      test -f ${f.packageDir}/tools/chocolateyInstall.ps1
      grep '<id>modde</id>' ${f.packageDir}/modde.nuspec
      grep "url64bit = 'https://codeberg.org/caniko/modde/releases/download/1.2.3/modde-1.2.3-x86_64-pc-windows-msvc.zip'" \
        ${f.packageDir}/tools/chocolateyInstall.ps1
      xmllint --noout ${f.packageDir}/modde.nuspec
      touch $out
    '';

  # mkChocoPackage emits the expected PowerShell keys for multiple Windows architectures.
  mkChocoPackage-multi-arch = let
    f = self.lib.mkChocoPackage {
      inherit pkgs;
      id = "multi-app";
      version = "2.0.0";
      description = "Windows CLI package";
      homepage = "https://example.com";
      license = "Apache-2.0";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures = {
        x64 = {
          url = "https://example.com/multi-app-2.0.0-x86_64-pc-windows-msvc.zip";
          sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        };
        arm64 = {
          url = "https://example.com/multi-app-2.0.0-aarch64-pc-windows-msvc.zip";
          sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        };
      };
      binaries = ["multi-app"];
    };
  in
    assert pkgs.lib.hasInfix "url64bit" f.installScriptText;
    assert pkgs.lib.hasInfix "urlArm64" f.installScriptText;
    assert pkgs.lib.hasInfix "checksumType64 = 'sha256'" f.installScriptText;
    assert pkgs.lib.hasInfix "checksumTypeArm64 = 'sha256'" f.installScriptText;
    pkgs.runCommand "check-mkChocoPackage-multi-arch" {} "touch $out";

  # mkChocoPackage omits checksum args when the caller uses :no_check placeholders.
  mkChocoPackage-no-check-placeholder = let
    f = self.lib.mkChocoPackage {
      inherit pkgs;
      id = "placeholder-app";
      version = "1.0.0";
      description = "Placeholder checksum package";
      homepage = "https://example.com";
      license = "MIT";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures.x64 = {
        url = "https://example.com/placeholder-app-1.0.0-x86_64-pc-windows-msvc.zip";
        sha256 = ":no_check";
      };
      binaries = ["placeholder-app"];
    };
  in
    assert pkgs.lib.hasInfix "url64bit" f.installScriptText;
    assert !(pkgs.lib.hasInfix "checksum64" f.installScriptText);
    assert !(pkgs.lib.hasInfix "checksumType64" f.installScriptText);
    pkgs.runCommand "check-mkChocoPackage-no-check-placeholder" {
      nativeBuildInputs = [pkgs.libxml2];
    } ''
      test -f ${f.packageDir}/placeholder-app.nuspec
      grep "url64bit = 'https://example.com/placeholder-app-1.0.0-x86_64-pc-windows-msvc.zip'" \
        ${f.packageDir}/tools/chocolateyInstall.ps1
      if grep -q "checksum64" ${f.packageDir}/tools/chocolateyInstall.ps1; then
        echo "checksum64 should be omitted for :no_check" >&2
        exit 1
      fi
      xmllint --noout ${f.packageDir}/placeholder-app.nuspec
      touch $out
    '';

  # mkChocoPackage XML-escapes metadata content before writing the nuspec.
  mkChocoPackage-xml-escaping = let
    f = self.lib.mkChocoPackage {
      inherit pkgs;
      id = "xml-app";
      version = "1.0.0";
      description = ''Needs <escaping> & "quotes" in XML'';
      homepage = "https://example.com";
      license = "MIT";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures.x86 = {
        url = "https://example.com/xml-app-1.0.0-i686-pc-windows-msvc.zip";
        sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
      };
      binaries = ["xml-app"];
    };
  in
    assert pkgs.lib.hasInfix "&lt;escaping&gt;" f.nuspecText;
    assert pkgs.lib.hasInfix "&amp;" f.nuspecText;
    assert pkgs.lib.hasInfix "&quot;quotes&quot;" f.nuspecText;
    pkgs.runCommand "check-mkChocoPackage-xml-escaping" {
      nativeBuildInputs = [pkgs.libxml2];
    } ''
      xmllint --noout ${f.packageDir}/xml-app.nuspec
      touch $out
    '';

  # mkChocoPackage rejects a Chocolatey-illegal package id.
  mkChocoPackage-rejects-bad-id = let
    result = builtins.tryEval (self.lib.mkChocoPackage {
      inherit pkgs;
      id = "Bad_Id";
      version = "1.0.0";
      description = "Bad id package";
      homepage = "https://example.com";
      license = "MIT";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures.x64 = {
        url = "https://example.com/bad-id.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      binaries = ["bad-id"];
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkChocoPackage-rejects-bad-id" {} "touch $out";

  # mkChocoPackage rejects versions with a leading v.
  mkChocoPackage-rejects-bad-version = let
    result = builtins.tryEval (self.lib.mkChocoPackage {
      inherit pkgs;
      id = "bad-version";
      version = "v1.0.0";
      description = "Bad version package";
      homepage = "https://example.com";
      license = "MIT";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures.x64 = {
        url = "https://example.com/bad-version.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      binaries = ["bad-version"];
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkChocoPackage-rejects-bad-version" {} "touch $out";

  # mkChocoPackage rejects descriptions longer than Chocolatey's nuspec limit.
  mkChocoPackage-rejects-long-description = let
    result = builtins.tryEval (self.lib.mkChocoPackage {
      inherit pkgs;
      id = "long-description";
      version = "1.0.0";
      description = builtins.concatStringsSep "" (builtins.genList (_: "a") 4001);
      homepage = "https://example.com";
      license = "MIT";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures.x64 = {
        url = "https://example.com/long-description.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      binaries = ["long-description"];
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkChocoPackage-rejects-long-description" {} "touch $out";

  # mkChocoPackage rejects non-HTTPS homepages.
  mkChocoPackage-rejects-http-homepage = let
    result = builtins.tryEval (self.lib.mkChocoPackage {
      inherit pkgs;
      id = "http-homepage";
      version = "1.0.0";
      description = "HTTP homepage package";
      homepage = "http://example.com";
      license = "MIT";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures.x64 = {
        url = "https://example.com/http-homepage.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      binaries = ["http-homepage"];
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkChocoPackage-rejects-http-homepage" {} "touch $out";

  # mkChocoPackage rejects unsupported Windows architecture keys.
  mkChocoPackage-rejects-bad-arch-key = let
    result = builtins.tryEval (self.lib.mkChocoPackage {
      inherit pkgs;
      id = "bad-arch";
      version = "1.0.0";
      description = "Bad architecture package";
      homepage = "https://example.com";
      license = "MIT";
      licenseUrl = "https://example.com/LICENSE";
      authors = ["Example Author"];
      architectures.ppc64 = {
        url = "https://example.com/bad-arch.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      binaries = ["bad-arch"];
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkChocoPackage-rejects-bad-arch-key" {} "touch $out";

  # mkScoopManifest returns expected attributes and a bin list.
  mkScoopManifest-shape = let
    m = self.lib.mkScoopManifest {
      inherit pkgs;
      name = "modde";
      version = "1.2.3";
      description = "Cross-platform game mod manager";
      homepage = "https://modde.tartanoglu.com";
      license = "MIT";
      architectures."64bit" = {
        url = "https://example.com/modde-1.2.3-x86_64-pc-windows-msvc.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
      binaries = ["modde.exe" "modde-ui.exe"];
    };
    parsed = builtins.fromJSON m.manifestText;
  in
    assert m ? manifestText;
    assert m ? manifestPath;
    assert builtins.isString m.manifestText;
    assert parsed.architecture."64bit".url == "https://example.com/modde-1.2.3-x86_64-pc-windows-msvc.zip";
    assert parsed.bin == ["modde.exe" "modde-ui.exe"];
    pkgs.runCommand "check-mkScoopManifest-shape" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -e '.architecture["64bit"].url == "https://example.com/modde-1.2.3-x86_64-pc-windows-msvc.zip"' ${m.manifestPath}
      jq -e '.bin == ["modde.exe", "modde-ui.exe"]' ${m.manifestPath}
      touch $out
    '';

  # mkScoopManifest emits the requested architecture blocks.
  mkScoopManifest-multi-arch = let
    both = self.lib.mkScoopManifest {
      inherit pkgs;
      name = "multi-app";
      version = "1.0.0";
      description = "Multi arch app";
      homepage = "https://example.com";
      license = "Apache-2.0";
      architectures = {
        "64bit" = {
          url = "https://example.com/multi-app-1.0.0-x86_64-pc-windows-msvc.zip";
          sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        };
        arm64 = {
          url = "https://example.com/multi-app-1.0.0-aarch64-pc-windows-msvc.zip";
          sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        };
      };
    };
    armOnly = self.lib.mkScoopManifest {
      inherit pkgs;
      name = "arm-app";
      version = "1.0.0";
      description = "Arm app";
      homepage = "https://example.com";
      license = "MIT";
      architectures.arm64 = {
        url = "https://example.com/arm-app-1.0.0-aarch64-pc-windows-msvc.zip";
        sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
      };
    };
    bothParsed = builtins.fromJSON both.manifestText;
    armOnlyParsed = builtins.fromJSON armOnly.manifestText;
  in
    assert bothParsed.architecture ? "64bit";
    assert bothParsed.architecture ? arm64;
    assert armOnlyParsed.architecture ? arm64;
    assert !(armOnlyParsed.architecture ? "64bit");
    pkgs.runCommand "check-mkScoopManifest-multi-arch" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -e '.architecture["64bit"].hash == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' ${both.manifestPath}
      jq -e '.architecture.arm64.hash == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' ${both.manifestPath}
      jq -e '.architecture.arm64.url == "https://example.com/arm-app-1.0.0-aarch64-pc-windows-msvc.zip"' ${armOnly.manifestPath}
      touch $out
    '';

  # mkScoopManifest omits hash entries for :no_check placeholders.
  mkScoopManifest-no-check-placeholder = let
    m = self.lib.mkScoopManifest {
      inherit pkgs;
      name = "placeholder-app";
      version = "1.0.0";
      description = "Placeholder checksum app";
      homepage = "https://example.com";
      license = "MIT";
      architectures."64bit" = {
        url = "https://example.com/placeholder-app-1.0.0-x86_64-pc-windows-msvc.zip";
        sha256 = ":no_check";
      };
    };
    parsed = builtins.fromJSON m.manifestText;
  in
    assert parsed ? _comment;
    assert !(parsed.architecture."64bit" ? hash);
    pkgs.runCommand "check-mkScoopManifest-no-check-placeholder" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      jq -e '._comment | contains(":no_check")' ${m.manifestPath}
      jq -e 'has("architecture") and (.architecture["64bit"] | has("hash") | not)' ${m.manifestPath}
      touch $out
    '';

  # mkScoopManifest rejects a Scoop-illegal manifest name.
  mkScoopManifest-rejects-bad-name = let
    result = builtins.tryEval (self.lib.mkScoopManifest {
      inherit pkgs;
      name = "Bad_Name";
      version = "1.0.0";
      description = "Bad name app";
      homepage = "https://example.com";
      license = "MIT";
      architectures."64bit" = {
        url = "https://example.com/bad-name.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkScoopManifest-rejects-bad-name" {} "touch $out";

  # mkScoopManifest rejects versions with a leading v.
  mkScoopManifest-rejects-bad-version = let
    result = builtins.tryEval (self.lib.mkScoopManifest {
      inherit pkgs;
      name = "bad-version";
      version = "v1.0.0";
      description = "Bad version app";
      homepage = "https://example.com";
      license = "MIT";
      architectures."64bit" = {
        url = "https://example.com/bad-version.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkScoopManifest-rejects-bad-version" {} "touch $out";

  # mkScoopManifest rejects descriptions longer than the helper allows.
  mkScoopManifest-rejects-long-desc = let
    result = builtins.tryEval (self.lib.mkScoopManifest {
      inherit pkgs;
      name = "long-desc";
      version = "1.0.0";
      description = "This description is deliberately longer than eighty characters so validation rejects it.";
      homepage = "https://example.com";
      license = "MIT";
      architectures."64bit" = {
        url = "https://example.com/long-desc.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkScoopManifest-rejects-long-desc" {} "touch $out";

  # mkScoopManifest rejects non-HTTPS homepages.
  mkScoopManifest-rejects-http-homepage = let
    result = builtins.tryEval (self.lib.mkScoopManifest {
      inherit pkgs;
      name = "http-homepage";
      version = "1.0.0";
      description = "HTTP homepage app";
      homepage = "http://example.com";
      license = "MIT";
      architectures."64bit" = {
        url = "https://example.com/http-homepage.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkScoopManifest-rejects-http-homepage" {} "touch $out";

  # mkScoopManifest rejects unsupported architecture keys.
  mkScoopManifest-rejects-bad-arch-key = let
    result = builtins.tryEval (self.lib.mkScoopManifest {
      inherit pkgs;
      name = "bad-arch";
      version = "1.0.0";
      description = "Bad architecture app";
      homepage = "https://example.com";
      license = "MIT";
      architectures.x86_64 = {
        url = "https://example.com/bad-arch.zip";
        sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      };
    });
  in
    assert !result.success;
    pkgs.runCommand "check-mkScoopManifest-rejects-bad-arch-key" {} "touch $out";
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

  mkMinisignSign-shape = let
    app = self.lib.mkMinisignSign {
      inherit pkgs;
      files = ["release/SHA256SUMS.txt"];
    };
  in
    assert app.type == "app";
    pkgs.runCommand "check-mkMinisignSign-shape" {} ''
      cp ${app.program} script
      grep 'minisign -S -s "$keyfile"' script
      grep 'MINISIGN_SECRET_KEY' script
      grep 'release/SHA256SUMS.txt' script
      touch $out
    '';

  mkMinisignVerify-shape = let
    app = self.lib.mkMinisignVerify {
      inherit pkgs;
      files = ["release/SHA256SUMS.txt"];
    };
  in
    assert app.type == "app";
    pkgs.runCommand "check-mkMinisignVerify-shape" {} ''
      cp ${app.program} script
      grep 'minisign -V -p' script
      grep 'keys/minisign.pub' script
      touch $out
    '';

  # mkSccacheEnv produces expected env vars
  mkSccacheEnv-shape = let
    env = self.lib.mkSccacheEnv.mkSccacheEnv {
      bucket = "sccache";
      endpoint = "http://127.0.0.1:3900";
    };
  in
    assert env ? SCCACHE_BUCKET;
    assert env ? SCCACHE_ENDPOINT;
    assert env ? SCCACHE_REGION;
    assert env ? SCCACHE_S3_USE_SSL;
    assert env.SCCACHE_BUCKET == "sccache";
    assert env.SCCACHE_ENDPOINT == "http://127.0.0.1:3900";
    assert env.SCCACHE_S3_USE_SSL == "false";
    pkgs.runCommand "check-mkSccacheEnv-shape" {} "touch $out";

  # mkSccacheEnv with SSL sets SCCACHE_S3_USE_SSL=true
  mkSccacheEnv-ssl = let
    env = self.lib.mkSccacheEnv.mkSccacheEnv {
      bucket = "sccache";
      endpoint = "https://s3.example.com";
      useSsl = true;
    };
  in
    assert env.SCCACHE_S3_USE_SSL == "true";
    pkgs.runCommand "check-mkSccacheEnv-ssl" {} "touch $out";

  # mkSccacheEnv with keyPrefix sets SCCACHE_S3_KEY_PREFIX
  mkSccacheEnv-prefix = let
    env = self.lib.mkSccacheEnv.mkSccacheEnv {
      bucket = "sccache";
      endpoint = "http://127.0.0.1:3900";
      keyPrefix = "atlas";
    };
  in
    assert env.SCCACHE_S3_KEY_PREFIX == "atlas";
    pkgs.runCommand "check-mkSccacheEnv-prefix" {} "touch $out";
}
