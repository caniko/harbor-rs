{
  description = "Rust project — powered by rs-harbor";

  inputs = {
    rs-harbor.url = "git+https://github.com/caniko/rs-harbor.git?ref=trunk";
    nixpkgs.follows = "rs-harbor/nixpkgs";
    rust-overlay.follows = "rs-harbor/rust-overlay";
    crane.follows = "rs-harbor/crane";
  };

  outputs = {
    self,
    nixpkgs,
    rs-harbor,
    rust-overlay,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
  in {
    packages = nixpkgs.lib.genAttrs systems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [(import rust-overlay)];
        };
        toolchain = rs-harbor.lib.mkToolchain {inherit pkgs;};
      in {
        default = toolchain.craneLib.buildPackage {
          src = ./.;
          pname = "cross-fixture";
          version = "0.1.0";
          doCheck = false;
        };
      }
    );

    devShells = nixpkgs.lib.genAttrs systems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [(import rust-overlay)];
        };
        toolchain = rs-harbor.lib.mkToolchain {inherit pkgs;};
        cross = rs-harbor.lib.mkCross {inherit pkgs system;};
      in
        rs-harbor.lib.mkDevShells {
          inherit pkgs cross;
          inherit (toolchain) craneLib;
        }
    );
  };
}
