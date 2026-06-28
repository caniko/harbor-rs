# mkDevShell   :: { ... } -> devShell derivation
# mkDocsShell  :: { ... } -> devShell derivation
# mkDevShells  :: { ... } -> { default, windows, macos, cross }
#
# Build devShells with Rust cross-compilation environment variables pre-configured.
# mkDevShells calls mkDevShell internally, so both live in the same file.
rec {
  # Build a devShell with Rust cross-compilation environment variables pre-configured.
  mkDevShell = {
    pkgs,
    craneLib,
    cross,
    enableWindowsEnv ? true,
    enableOsxcrossEnv ? true,
    pkgConfigDeps ? [],
    packages ? [],
    extraEnv ? {},
    extraShellHook ? "",
    checks ? {},
    cargoConfig ? null,
  }: let
    inherit (cross) mingwBinutils osxcrossToolchain osxcrossRustHelpers;

    basePackages = with pkgs; [
      cargo-audit
      cargo-deny
      cargo-sweep
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

    cargoConfigHook =
      if cargoConfig != null
      then ''
        RS_HARBOR_CARGO_HOME="$(mktemp -d -t rs-harbor-cargo-XXXXXX)"
        export CARGO_HOME="$RS_HARBOR_CARGO_HOME"
        mkdir -p "$RS_HARBOR_CARGO_HOME"
        install -m 0644 ${cargoConfig.configPath} "$RS_HARBOR_CARGO_HOME/config.toml"
        # Chain cargo cleanup with any existing EXIT trap (e.g. direnv's __dump_at_exit)
        # to avoid overwriting it. direnv's __main__ sets an EXIT trap to capture the
        # environment; overwriting it would prevent PATH changes from being exported.
        __rs_harbor_prev_exit=$(trap -p EXIT | sed "s/^trap -- '\\(.*\\)' EXIT$/\\1/")
        if [[ -n $__rs_harbor_prev_exit ]]; then
          trap "rm -rf \"\$RS_HARBOR_CARGO_HOME\"; $__rs_harbor_prev_exit" EXIT
        else
          trap 'rm -rf "$RS_HARBOR_CARGO_HOME"' EXIT
        fi
        echo "rs-harbor: cargo config at $RS_HARBOR_CARGO_HOME/config.toml"
      ''
      else "";

    baseEnv = {
      LIBCLANG_PATH = pkgs.lib.makeLibraryPath [pkgs.clang.cc];
    };

    crossEnv =
      if enableWindowsEnv
      then cross.windowsEnv
      else {};

    pkgConfigEnv = pkgs.lib.optionalAttrs (pkgConfigDeps != []) {
      PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" pkgConfigDeps;
    };

    mergedEnv = baseEnv // crossEnv // pkgConfigEnv // extraEnv;
  in
    craneLib.devShell (mergedEnv
      // {
        inherit checks;

        packages = basePackages ++ windowsPackages ++ osxPackages ++ packages;

        shellHook = ''
          ${cargoConfigHook}
          ${osxShellHook}
          ${extraShellHook}
        '';
      });

  # Build a docs/tooling shell that starts from the same foundation as
  # mkDevShell, but keeps cross-compilation environment variables disabled
  # unless a downstream project explicitly opts back in.
  mkDocsShell = args@{
    enableWindowsEnv ? false,
    enableOsxcrossEnv ? false,
    ...
  }:
    mkDevShell (args
      // {
        inherit enableWindowsEnv enableOsxcrossEnv;
      });

  # Build multiple devShells for workspace ergonomics.
  #
  # Returns four shells from one config: default (native-only),
  # windows, macos, and cross (all targets). Downstream workspaces
  # use `nix develop` for native and `nix develop .#cross` etc.
  mkDevShells = {
    pkgs,
    craneLib,
    cross,
    enableOsxcrossEnv ? true,
    pkgConfigDeps ? [],
    packages ? [],
    extraEnv ? {},
    extraShellHook ? "",
    checks ? {},
    cargoConfig ? null,
  }: let
    shell = {
      win ? false,
      osx ? false,
    }:
      mkDevShell {
        inherit pkgs craneLib cross pkgConfigDeps packages extraEnv extraShellHook checks cargoConfig;
        enableWindowsEnv = win;
        enableOsxcrossEnv = osx && enableOsxcrossEnv;
      };
  in {
    default = shell {};
    windows = shell {win = true;};
    macos = shell {osx = true;};
    cross = shell {win = true; osx = true;};
  };
}
