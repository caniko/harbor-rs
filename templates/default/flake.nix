{
  description = "Rust project — powered by rs-harbor";

  inputs = {
    rs-harbor.url = "git+https://github.com/caniko/rs-harbor.git?ref=trunk";
    nixpkgs.follows = "rs-harbor/nixpkgs";
    rust-overlay.follows = "rs-harbor/rust-overlay";
    crane.follows = "rs-harbor/crane";
    treefmt-nix.follows = "rs-harbor/treefmt-nix";
    git-hooks.follows = "rs-harbor/git-hooks";
  };

  outputs = {
    self,
    nixpkgs,
    rs-harbor,
    rust-overlay,
    treefmt-nix,
    git-hooks,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forSystem = system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };
      toolchain = rs-harbor.lib.mkToolchain {inherit pkgs;};
      inherit (toolchain) craneLib rustToolchain;
      cross = rs-harbor.lib.mkCross {inherit pkgs system;};
      treefmtEval = treefmt-nix.lib.evalModule pkgs (import ./nix/treefmt.nix);
      pre-commit-check = git-hooks.lib.${system}.run {
        src = ./.;
        hooks = import ./nix/pre-commit.nix {
          inherit pkgs;
          treefmtWrapper = treefmtEval.config.build.wrapper;
          inherit rustToolchain;
        };
      };
      package = craneLib.buildPackage {
        src = ./.;
        pname = "cross-fixture";
        version = "0.1.0";
        doCheck = false;
      };
    in {
      inherit pkgs toolchain craneLib cross treefmtEval pre-commit-check package;
    };
  in {
    packages = nixpkgs.lib.genAttrs systems (system: {
      default = (forSystem system).package;
    });

    formatter = nixpkgs.lib.genAttrs systems (
      system: (forSystem system).treefmtEval.config.build.wrapper
    );

    checks = nixpkgs.lib.genAttrs systems (
      system: let
        cfg = forSystem system;
      in {
        default = cfg.package;
        formatting = cfg.treefmtEval.config.build.check self;
      }
    );

    devShells = nixpkgs.lib.genAttrs systems (
      system: let
        cfg = forSystem system;
      in
        rs-harbor.lib.mkDevShells {
          inherit (cfg) pkgs cross;
          inherit (cfg.toolchain) craneLib;
          packages = cfg.pre-commit-check.enabledPackages;
          extraShellHook = cfg.pre-commit-check.shellHook;
        }
    );
  };
}
