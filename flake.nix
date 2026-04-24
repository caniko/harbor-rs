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
    lib = import ./lib {inherit crane osxcross;};
  in
    {
      inherit lib;

      templates = {
        bevy = {
          path = ./templates/bevy;
          description = "Bevy game engine project with rs-harbor cross-compilation";
        };
      };
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };
      initMacosSdk = import ./nix/init-macos-sdk.nix {
        inherit pkgs osxcross;
      };

      toolchain = self.lib.mkToolchain {inherit pkgs;};
      cross = self.lib.mkCross {inherit pkgs system;};
      cargoConfig = self.lib.mkCargoConfig {inherit pkgs;};
      sitePackages = import ./nix/site.nix {inherit pkgs;};
    in {
      packages =
        sitePackages
        // {
          init-macos-sdk = initMacosSdk;
        };

      apps = {
        init-macos-sdk = {
          type = "app";
          program = "${initMacosSdk}/bin/init-macos-sdk";
        };
      };

      devShells = import ./nix/dev-shell.nix {
        harbor = self.lib;
        inherit pkgs toolchain cross cargoConfig;
      };

      checks = import ./checks.nix {inherit self pkgs system toolchain cross;};
    });
}
