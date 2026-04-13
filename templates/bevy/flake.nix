{
  description = "Bevy game project — powered by rs-harbor";

  inputs = {
    rs-harbor.url = "github:caniko/rs-harbor";

    nixpkgs.follows = "rs-harbor/nixpkgs";
    rust-overlay.follows = "rs-harbor/rust-overlay";
    crane.follows = "rs-harbor/crane";
    flake-utils.follows = "rs-harbor/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    rs-harbor,
    flake-utils,
    rust-overlay,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };

      toolchain = rs-harbor.lib.mkToolchain {inherit pkgs;};
      cross = rs-harbor.lib.mkCross {
        inherit pkgs system;
        enableOsxcross = false;
      };
      cargoConfig = rs-harbor.lib.mkCargoConfig {inherit pkgs;};

      bevyDeps = import ./nix/bevy-deps.nix {inherit pkgs;};
    in {
      devShells = import ./nix/dev-shell.nix {
        inherit pkgs rs-harbor toolchain cross cargoConfig bevyDeps;
      };
    });
}
