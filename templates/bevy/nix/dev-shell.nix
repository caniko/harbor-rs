{
  pkgs,
  rs-harbor,
  toolchain,
  cross,
  cargoConfig,
  bevyDeps,
  checks ? {},
}:
  rs-harbor.lib.mkDevShells {
    inherit pkgs cross cargoConfig checks;
    inherit (toolchain) craneLib;
    enableOsxcrossEnv = false;

    packages = bevyDeps.buildInputs ++ bevyDeps.nativeBuildInputs;

    extraEnv = {
      LD_LIBRARY_PATH = bevyDeps.ldLibraryPath;
    };
  }
