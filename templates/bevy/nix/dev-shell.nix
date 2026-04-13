{
  pkgs,
  rs-harbor,
  toolchain,
  cross,
  cargoConfig,
  bevyDeps,
}:
  rs-harbor.lib.mkDevShells {
    inherit pkgs cross cargoConfig;
    inherit (toolchain) craneLib;
    enableOsxcrossEnv = false;

    packages = bevyDeps.buildInputs ++ bevyDeps.nativeBuildInputs;

    extraEnv = {
      LD_LIBRARY_PATH = bevyDeps.ldLibraryPath;
    };
  }
