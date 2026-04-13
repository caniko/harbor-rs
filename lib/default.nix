{crane, osxcross}: let
  devShellLib = import ./dev-shell.nix;
in {
  mkToolchain = import ./toolchain.nix {inherit crane;};
  mkCargoConfig = import ./cargo-config.nix;
  mkCross = import ./cross.nix {inherit osxcross;};
  inherit (devShellLib) mkDevShell mkDevShells;
}
