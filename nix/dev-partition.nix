# The `dev` flake-parts partition: devShells, formatter and checks. `inputs`
# here also carries ./nix's inputs (treefmt-nix, git-hooks, nix-opencode-lsp,
# nix-cache-pin), which are locked in nix/flake.lock and never reach consumers.
{
  inputs,
  self,
  ...
}: let
  inherit (inputs) nixpkgs crane rust-overlay harbor-meta;
  harborRoot =
    inputs.harborRoot or (harbor-meta.lib.standaloneRoot {
      core = harbor-meta;
      rust = self;
    });
in {
  perSystem = {system, ...}: let
    pkgs = import nixpkgs {
      inherit system;
      overlays = [(import rust-overlay)];
    };
    toolchain = self.lib.mkToolchain {
      inherit pkgs;
      toolchainProfile = "nightly";
    };
    cross = self.lib.mkCross {inherit pkgs system;};
    inherit (toolchain) cargoConfig;
    treefmt = inputs.treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix {
      harbor-rs = self;
      rustfmtPackage = toolchain.rustToolchain;
    });
    rsHarborVersion = (builtins.fromTOML (builtins.readFile ../cli/Cargo.toml)).package.version;
    rsHarborCli = import ./harbor-rs-cli.nix {
      inherit pkgs;
      inherit (toolchain) craneLib;
      src = ../.;
      version = rsHarborVersion;
    };
    harborCi = import ./harbor-ci.nix {
      inherit pkgs;
      inherit (toolchain) craneLib;
      src = ../.;
      version = rsHarborVersion;
    };
  in {
    devShells = import ./dev-shells.nix {
      harbor = self.lib;
      opencodeLsp = inputs.nix-opencode-lsp.lib;
      inherit pkgs toolchain cross cargoConfig rsHarborCli harborCi;
      treefmtWrapper = treefmt.config.build.wrapper;
    };

    formatter = treefmt.config.build.wrapper;

    checks =
      (import ../checks.nix {
        inherit self pkgs system toolchain cross nixpkgs rust-overlay crane harborRoot;
        inherit (inputs) treefmt-nix git-hooks nix-cache-pin;
        rootInputNames = builtins.attrNames inputs;
        # The lock that resolves this flake's inputs: harbor's inside the
        # superproject, this repository's own standalone.
        rootLock = builtins.fromJSON (builtins.readFile ((inputs.harborRoot or self).outPath + "/flake.lock"));
      })
      // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ../checks/release-archives.nix {
        inherit pkgs self system;
      })
      // (import ./checks-dev-sandbox.nix {
        inherit pkgs;
        harborRsCli = rsHarborCli;
        inherit (self.lib) mkDevSandbox;
      })
      // {
        treefmt-modules = import ./treefmt/check.nix {
          inherit pkgs;
          inherit (inputs) treefmt-nix;
          inherit (toolchain) rustToolchain;
          rustModule = self.treefmtModules.rust;
          baseModules = [inputs.harbor-meta.treefmtModules.nix inputs.harbor-meta.treefmtModules.toml];
        };
      };
  };
}
