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
      realizeMacosSdk = osxcross.packages.${system}.realize-macos-sdk;
      validateMacosSdk = import ./nix/validate-macos-sdk.nix {
        inherit pkgs;
      };
      initMacosSdk = import ./nix/init-macos-sdk.nix {
        inherit pkgs realizeMacosSdk validateMacosSdk;
      };

      toolchain = self.lib.mkToolchain {inherit pkgs;};
      cross = self.lib.mkCross {inherit pkgs system;};
      cargoConfig = self.lib.mkCargoConfig {inherit pkgs;};
      sitePackages = import ./nix/site.nix {inherit pkgs;};
      bootstrapCmdsMig = import ./nix/bootstrap-cmds-mig.nix {inherit pkgs;};

      # rs-harbor's own type-safe CLI, used to back the helper packages
      # (e.g. stage-macos-universal). Built with crane against the
      # workspace at the repo root.
      craneLib = toolchain.craneLib;
      # Custom source filter: keep cleanCargoSource defaults plus the
      # binary fixtures used by the integration test suite (PE/Mach-O
      # samples for `rs-harbor audit`).
      rsHarborSrc = pkgs.lib.cleanSourceWith {
        src = ./.;
        filter = path: type:
          (craneLib.filterCargoSources path type)
          || (builtins.match ".*/tests/fixtures/.*" path != null);
        name = "rs-harbor-source";
      };
      rsHarborCli = craneLib.buildPackage {
        pname = "rs-harbor";
        version = "0.1.0";
        src = rsHarborSrc;
        strictDeps = true;
        doCheck = true;
      };

      macosStaging = self.lib.mkMacosUniversalStager {
        inherit pkgs;
        rsHarborCli = rsHarborCli;
      };
      steamRuntimeTools = self.lib.mkSteamRuntimeTools {
        inherit pkgs;
        rsHarborCli = rsHarborCli;
      };
    in {
      packages =
        sitePackages
        // {
          init-macos-sdk = initMacosSdk;
          validate-macos-sdk = validateMacosSdk;
          stage-macos-universal = macosStaging.stager;
          bootstrap-cmds-mig = bootstrapCmdsMig;
          steam-runtime-cargo-bootstrap = steamRuntimeTools.steamRuntimeCargoBootstrap;
          rs-harbor = rsHarborCli;
        };

      apps = {
        init-macos-sdk = {
          type = "app";
          program = "${initMacosSdk}/bin/init-macos-sdk";
        };
        validate-macos-sdk = {
          type = "app";
          program = "${validateMacosSdk}/bin/validate-macos-sdk";
        };
        stage-macos-universal = {
          type = "app";
          program = "${macosStaging.stager}/bin/stage-macos-universal";
        };
      };

      devShells = import ./nix/dev-shell.nix {
        harbor = self.lib;
        inherit pkgs toolchain cross cargoConfig;
      };

      checks = import ./checks.nix {inherit self pkgs system toolchain cross;};
    });
}
