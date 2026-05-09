# mkDevShell  :: { ... } -> devShell derivation
# mkDevShells :: { ... } -> { default, windows, macos, cross }
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
    sccache ? {},
  }: let
    inherit (cross) mingwBinutils osxcrossToolchain osxcrossRustHelpers;
    sccacheCfg =
      {
        enable = false;
        cacheDir = null;
        cacheSize = null;
        cargoIncremental = null;
      }
      // sccache;

    basePackages = with pkgs; [
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

    sccachePackages = pkgs.lib.optionals sccacheCfg.enable [
      pkgs.sccache
    ];

    osxShellHook =
      if enableOsxcrossEnv && osxcrossRustHelpers != null
      then osxcrossRustHelpers.mkDevShellHook {}
      else "";

    cargoConfigHook =
      if cargoConfig != null
      then ''
        if [ -f .cargo/config.toml ]; then
          if ! diff -q .cargo/config.toml ${cargoConfig.configPath} >/dev/null 2>&1; then
            cp .cargo/config.toml .cargo/config.toml.bak
            echo "rs-harbor: backed up .cargo/config.toml → .cargo/config.toml.bak"
            cp ${cargoConfig.configPath} .cargo/config.toml
            echo "rs-harbor: updated .cargo/config.toml"
          fi
        else
          mkdir -p .cargo
          cp ${cargoConfig.configPath} .cargo/config.toml
          echo "rs-harbor: wrote .cargo/config.toml"
        fi
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

    sccacheEnv =
      pkgs.lib.optionalAttrs sccacheCfg.enable (
        {
          RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";
        }
        // pkgs.lib.optionalAttrs (sccacheCfg.cacheDir != null) {
          SCCACHE_DIR = sccacheCfg.cacheDir;
        }
        // pkgs.lib.optionalAttrs (sccacheCfg.cacheSize != null) {
          SCCACHE_CACHE_SIZE = sccacheCfg.cacheSize;
        }
        // pkgs.lib.optionalAttrs (sccacheCfg.cargoIncremental != null) {
          CARGO_INCREMENTAL = sccacheCfg.cargoIncremental;
        }
      );

    mergedEnv = baseEnv // crossEnv // pkgConfigEnv // sccacheEnv // extraEnv;
  in
    craneLib.devShell (mergedEnv
      // {
        inherit checks;

        packages = basePackages ++ windowsPackages ++ osxPackages ++ sccachePackages ++ packages;

        shellHook = ''
          ${cargoConfigHook}
          ${osxShellHook}
          ${extraShellHook}
        '';
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
    sccache ? {},
  }: let
    shell = {
      win ? false,
      osx ? false,
    }:
      mkDevShell {
        inherit pkgs craneLib cross pkgConfigDeps packages extraEnv extraShellHook checks cargoConfig sccache;
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
