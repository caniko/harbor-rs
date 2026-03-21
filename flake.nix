{
  description = "Reusable Rust cross-compilation and toolchain infrastructure for Nix flakes";

  inputs = {
    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    osxcross = {
      url = "github:caniko/osxcross/flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    flake-utils,
    rust-overlay,
    osxcross,
    ...
  }: let
    # Library functions available without system context
    lib = rec {
      # Build a Rust toolchain + craneLib for a given pkgs set.
      #
      # Args:
      #   pkgs          - nixpkgs with rust-overlay applied
      #   channel       - "nightly" (default) or "stable"
      #   date          - pin to a specific date, e.g. "2025-12-01" (default: "latest")
      #   extensions    - extra rustup components (default: common dev set)
      #   crossTargets  - list of Rust target triples (default: linux + windows + macOS)
      #
      # Returns: { rustToolchain, craneLib, crossTargets }
      mkToolchain = {
        pkgs,
        channel ? "nightly",
        date ? "latest",
        extensions ? ["rust-src" "rustfmt" "rustc-codegen-cranelift-preview"],
        crossTargets ? [
          "x86_64-unknown-linux-gnu"
          "x86_64-pc-windows-gnu"
          "x86_64-apple-darwin"
          "aarch64-apple-darwin"
        ],
      }:
        assert pkgs.lib.assertMsg (pkgs ? rust-bin)
          "rs-harbor: mkToolchain requires pkgs with rust-overlay applied (pkgs.rust-bin must exist)";
        assert pkgs.lib.assertMsg (builtins.elem channel ["nightly" "stable"])
          "rs-harbor: mkToolchain 'channel' must be \"nightly\" or \"stable\", got \"${channel}\"";
        assert pkgs.lib.assertMsg (date == "latest" || builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" date != null)
          "rs-harbor: mkToolchain 'date' must be \"latest\" or a YYYY-MM-DD string, got \"${date}\"";
        let
        channelSet =
          if channel == "nightly"
          then pkgs.rust-bin.nightly
          else pkgs.rust-bin.stable;
        dateSet =
          if date == "latest"
          then channelSet.latest
          else channelSet.${date};
        rustToolchain = dateSet.default.override {
          inherit extensions;
          targets = crossTargets;
        };
        craneLib = (crane.mkLib pkgs).overrideToolchain (_p: rustToolchain);
      in {
        inherit rustToolchain craneLib crossTargets;
      };

      # Build cross-compilation toolchains (MinGW for Windows, osxcross for macOS).
      #
      # Args:
      #   pkgs          - nixpkgs
      #   system        - the host system string
      #   osxSdkVersion - macOS SDK version (default: "26.1")
      #
      # Returns: { mingwCC, mingwBinutils, winpthreads, windowsEnv, osxcrossToolchain, osxcrossRustHelpers }
      mkCross = {
        pkgs,
        system,
        enableOsxcross ? true,
        osxSdkVersion ? "26.1",
      }: let
        mingwCC = pkgs.pkgsCross.mingwW64.stdenv.cc;
        mingwBinutils = pkgs.pkgsCross.mingwW64.stdenv.cc.bintools.bintools;
        winpthreads = pkgs.pkgsCross.mingwW64.windows.pthreads;

        osxcrossToolchain =
          if enableOsxcross && system == "x86_64-linux"
          then
            osxcross.lib.${system}.mkOsxcross {
              sdkVersion = osxSdkVersion;
            }
          else null;

        osxcrossRustHelpers =
          if osxcrossToolchain != null
          then osxcross.lib.${system}.mkRustHelpers osxcrossToolchain
          else null;

        # Pre-built attrset of Windows cross-compilation env vars.
        # Consumers can merge this into mkShell when needed, without
        # polluting every dev shell unconditionally.
        windowsEnv = {
          CC_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-gcc";
          CXX_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-g++";
          AR_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-ar";
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${mingwCC}/bin/x86_64-w64-mingw32-gcc";
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "-L ${winpthreads}/lib";
        };
      in {
        inherit mingwCC mingwBinutils winpthreads;
        inherit osxcrossToolchain osxcrossRustHelpers;
        inherit windowsEnv;
      };

      # Build a devShell with Rust cross-compilation environment variables pre-configured.
      #
      # Args:
      #   pkgs               - nixpkgs
      #   craneLib            - from mkToolchain
      #   cross              - from mkCross
      #   enableWindowsEnv   - set Windows cross-compilation env vars (default: true)
      #   enableOsxcrossEnv  - include osxcross toolchain + shell hook (default: true)
      #   packages           - extra packages to include (default: [])
      #   extraEnv           - attrset of extra environment variables (default: {})
      #   extraShellHook     - additional shell hook commands (default: "")
      #   checks             - flake checks to wire into the shell (default: {})
      #
      # Returns: a devShell derivation
      mkDevShell = {
        pkgs,
        craneLib,
        cross,
        enableWindowsEnv ? true,
        enableOsxcrossEnv ? true,
        packages ? [],
        extraEnv ? {},
        extraShellHook ? "",
        checks ? {},
      }: let
        inherit (cross) mingwBinutils osxcrossToolchain osxcrossRustHelpers;

        basePackages = with pkgs; [
          cmake
          gcc
          clang
          mold
          lld
          pkg-config
        ];

        windowsPackages = pkgs.lib.optionals enableWindowsEnv [
          mingwBinutils
        ];

        osxPackages = pkgs.lib.optionals (enableOsxcrossEnv && osxcrossToolchain != null) [
          osxcrossToolchain
        ];

        osxShellHook =
          if enableOsxcrossEnv && osxcrossRustHelpers != null
          then osxcrossRustHelpers.mkDevShellHook {}
          else "";

        baseEnv = {
          LIBCLANG_PATH = pkgs.lib.makeLibraryPath [pkgs.clang.cc];
        };

        crossEnv =
          if enableWindowsEnv
          then cross.windowsEnv
          else {};

        mergedEnv = baseEnv // crossEnv // extraEnv;
      in
        craneLib.devShell (mergedEnv
          // {
            inherit checks;

            packages = basePackages ++ windowsPackages ++ osxPackages ++ packages;

            shellHook = ''
              ${osxShellHook}
              ${extraShellHook}
            '';
          });

      # Build multiple devShells for workspace ergonomics.
      #
      # Returns four shells from one config: default (native-only),
      # windows, macos, and cross (all targets). Downstream workspaces
      # use `nix develop` for native and `nix develop .#cross` etc.
      #
      # Args: same as mkDevShell, minus enableWindowsEnv/enableOsxcrossEnv.
      #   enableOsxcrossEnv controls whether the macos/cross shells get osxcross.
      #
      # Returns: { default, windows, macos, cross }
      mkDevShells = {
        pkgs,
        craneLib,
        cross,
        enableOsxcrossEnv ? true,
        packages ? [],
        extraEnv ? {},
        extraShellHook ? "",
        checks ? {},
      }: let
        shell = {
          win ? false,
          osx ? false,
        }:
          mkDevShell {
            inherit pkgs craneLib cross packages extraEnv extraShellHook checks;
            enableWindowsEnv = win;
            enableOsxcrossEnv = osx && enableOsxcrossEnv;
          };
      in {
        default = shell {};
        windows = shell {win = true;};
        macos = shell {osx = true;};
        cross = shell {win = true; osx = true;};
      };
    };
  in
    {
      inherit lib;
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };

      toolchain = self.lib.mkToolchain {inherit pkgs;};
      cross = self.lib.mkCross {
        inherit pkgs system;
        enableOsxcross = false; # requires --impure; enable manually
      };
    in {
      # DevShells for testing rs-harbor itself
      devShells = self.lib.mkDevShells {
        inherit pkgs cross;
        inherit (toolchain) craneLib;
        enableOsxcrossEnv = false; # requires --impure; enable manually
      };

      checks = {
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
          t = self.lib.mkToolchain {inherit pkgs; channel = "stable";};
        in
          assert t ? rustToolchain;
          assert t ? craneLib;
          pkgs.runCommand "check-mkToolchain-stable" {} "touch $out";

        # mkCross returns expected attributes
        mkCross-shape = let
          c = self.lib.mkCross {inherit pkgs system; enableOsxcross = false;};
        in
          assert c ? mingwCC;
          assert c ? mingwBinutils;
          assert c ? winpthreads;
          assert c ? windowsEnv;
          assert c ? osxcrossToolchain;
          assert c ? osxcrossRustHelpers;
          assert builtins.isAttrs c.windowsEnv;
          assert c.windowsEnv ? CC_x86_64_pc_windows_gnu;
          assert c.windowsEnv ? CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER;
          pkgs.runCommand "check-mkCross-shape" {} "touch $out";

        # osxcross disabled returns nulls
        mkCross-osxcross-disabled = let
          c = self.lib.mkCross {inherit pkgs system; enableOsxcross = false;};
        in
          assert c.osxcrossToolchain == null;
          assert c.osxcrossRustHelpers == null;
          pkgs.runCommand "check-mkCross-osxcross-disabled" {} "touch $out";

        # mkDevShells returns expected shell variants
        mkDevShells-shape = let
          s = self.lib.mkDevShells {
            inherit pkgs cross;
            inherit (toolchain) craneLib;
            enableOsxcrossEnv = false;
          };
        in
          assert s ? default;
          assert s ? windows;
          assert s ? macos;
          assert s ? cross;
          pkgs.runCommand "check-mkDevShells-shape" {} "touch $out";

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
      };
    });
}
