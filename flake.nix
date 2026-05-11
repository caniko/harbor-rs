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

      nixosModules.macosSdk = import ./nix/nixos-module.nix;

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
      validateMacosSdk = import ./nix/validate-macos-sdk.nix {
        inherit pkgs;
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
      realizeMacosSdk = pkgs.writeShellApplication {
        name = "realize-macos-sdk";
        runtimeInputs = [rsHarborCli];
        text = ''
          exec rs-harbor sdk realize "$@"
        '';
      };
      publishMacosSdk = pkgs.writeShellApplication {
        name = "publish-macos-sdk";
        runtimeInputs = [rsHarborCli];
        text = ''
          exec rs-harbor sdk publish-macos "$@"
        '';
      };
      steamRuntimeTools = self.lib.mkSteamRuntimeTools {
        inherit pkgs;
        rsHarborCli = rsHarborCli;
      };
    in {
      packages =
        sitePackages
        // {
          validate-macos-sdk = validateMacosSdk;
          stage-macos-universal = macosStaging.stager;
          bootstrap-cmds-mig = bootstrapCmdsMig;
          steam-runtime-cargo-bootstrap = steamRuntimeTools.steamRuntimeCargoBootstrap;
          rs-harbor = rsHarborCli;
        };

      apps = {
        publish-macos-sdk = {
          type = "app";
          program = "${publishMacosSdk}/bin/publish-macos-sdk";
        };
        realize-macos-sdk = {
          type = "app";
          program = "${realizeMacosSdk}/bin/realize-macos-sdk";
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

      devShells = import ./nix/dev-shells.nix {
        harbor = self.lib;
        inherit pkgs toolchain cross cargoConfig;
      };

      checks = import ./checks.nix {inherit self pkgs system toolchain cross;};
    });
}
