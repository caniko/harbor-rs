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
    lib = {
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
      }: let
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
      # Returns: { mingwCC, mingwBinutils, winpthreads, osxcrossToolchain, osxcrossRustHelpers }
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
      in {
        inherit mingwCC mingwBinutils winpthreads;
        inherit osxcrossToolchain osxcrossRustHelpers;
      };

      # Build a devShell with Rust cross-compilation environment variables pre-configured.
      #
      # Args:
      #   pkgs          - nixpkgs
      #   craneLib       - from mkToolchain
      #   cross          - from mkCross
      #   packages       - extra packages to include (default: [])
      #   extraEnv       - attrset of extra environment variables (default: {})
      #   extraShellHook - additional shell hook commands (default: "")
      #   checks         - flake checks to wire into the shell (default: {})
      #
      # Returns: a devShell derivation
      mkDevShell = {
        pkgs,
        craneLib,
        cross,
        packages ? [],
        extraEnv ? {},
        extraShellHook ? "",
        checks ? {},
      }: let
        inherit (cross) mingwCC mingwBinutils winpthreads osxcrossToolchain osxcrossRustHelpers;

        basePackages = with pkgs; [
          cmake
          gcc
          clang
          mold
          lld
          pkg-config
          mingwBinutils
        ];

        osxPackages = pkgs.lib.optionals (osxcrossToolchain != null) [
          osxcrossToolchain
        ];

        osxShellHook =
          if osxcrossRustHelpers != null
          then osxcrossRustHelpers.mkDevShellHook {}
          else "";

        baseEnv = {
          LIBCLANG_PATH = pkgs.lib.makeLibraryPath [pkgs.clang.cc];

          # Windows cross-compilation
          CC_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-gcc";
          CXX_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-g++";
          AR_x86_64_pc_windows_gnu = "${mingwCC}/bin/x86_64-w64-mingw32-ar";
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${mingwCC}/bin/x86_64-w64-mingw32-gcc";
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS = "-L ${winpthreads}/lib";
        };

        mergedEnv = baseEnv // extraEnv;
      in
        craneLib.devShell (mergedEnv
          // {
            inherit checks;

            packages = basePackages ++ osxPackages ++ packages;

            shellHook = ''
              ${osxShellHook}
              ${extraShellHook}
            '';
          });
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
      # Default devShell for testing rs-harbor itself
      devShells.default = self.lib.mkDevShell {
        inherit pkgs cross;
        inherit (toolchain) craneLib;
      };
    });
}
