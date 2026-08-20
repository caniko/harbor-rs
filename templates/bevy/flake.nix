{
  description = "Bevy game project — powered by rs-harbor";

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
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forSystem = system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };
      toolchain = rs-harbor.lib.mkToolchain {inherit pkgs;};
      inherit (toolchain) craneLib;
      cross = rs-harbor.lib.mkCross {inherit pkgs system;};
      cargoConfig = rs-harbor.lib.mkCargoConfig {
        inherit pkgs;
        extraConfig = ''
          [alias]
          rd = "run --features bevy/dynamic_linking"
        '';
      };
      bevyDeps = import ./nix/bevy-deps.nix {inherit pkgs;};
      src = pkgs.lib.cleanSourceWith {
        src = ./.;
        filter = path: type:
          (!pkgs.lib.hasPrefix (toString ./.cargo) (toString path))
          && craneLib.filterCargoSources path type;
      };
      build = import ./nix/package.nix {inherit craneLib bevyDeps src;};
    in {
      inherit pkgs toolchain cross cargoConfig bevyDeps build;
    };
  in {
    packages = nixpkgs.lib.genAttrs systems (system: {
      default = (forSystem system).build.default;
    });

    checks = nixpkgs.lib.genAttrs systems (
      system: let
        inherit ((forSystem system).build) default clippy fmt;
      in {
        inherit default clippy fmt;
      }
    );

    devShells = nixpkgs.lib.genAttrs systems (
      system: let
        cfg = forSystem system;
      in
        import ./nix/dev-shells.nix {
          inherit (cfg) pkgs toolchain cross cargoConfig bevyDeps;
          inherit rs-harbor;
        }
    );
  };
}
