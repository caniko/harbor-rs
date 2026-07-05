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
    plinth = {
      url = "git+https://codeberg.org/caniko/plinth.git?ref=refs/heads/trunk";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    meta-harbor = {
      url = "git+https://codeberg.org/caniko/meta-harbor.git?ref=trunk";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    nix-opencode-lsp = {
      url = "git+ssh://git@codeberg.org/caniko/nix-opencode-lsp.git";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    flake-utils,
    rust-overlay,
    osxcross,
    plinth,
    meta-harbor,
    nix-opencode-lsp,
    ...
  }: let
    lib = import ./lib {
      inherit crane osxcross;
      meta-harbor = meta-harbor.lib;
    };
  in
    {
      inherit lib;

      nixosModules.macosSdk = import ./nix/nixos-module.nix;
      nixosModules.sccache = import ./nix/sccache-module.nix;

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
      sitePackages = import ./nix/site.nix {
        inherit pkgs;
        lib = nixpkgs.lib;
        projectSiteLib = import "${plinth}/nix/project-site.nix" {
          inherit pkgs;
          lib = nixpkgs.lib;
          plinthProject = plinth.packages.${system}.plinth-project;
        };
      };
      bootstrapCmdsMig = import ./nix/bootstrap-cmds-mig.nix {inherit pkgs;};

      # rs-harbor's own type-safe CLI, built from the workspace at the
      # repo root. Backs the helper packages (e.g. stage-macos-universal).
      rsHarborCli = import ./nix/rs-harbor-cli.nix {
        inherit pkgs;
        inherit (toolchain) craneLib;
        src = ./.;
      };

      macosStaging = self.lib.mkMacosUniversalStager {
        inherit pkgs rsHarborCli;
      };
      # `realizeMacosSdkBin` is the osxcross binary literally named
      # `realize-macos-sdk`. The Rust CLI's `harbor-sdk::realize_macos_sdk`
      # does `which::which("realize-macos-sdk")` at runtime, so we must NOT
      # export a shell wrapper of the same name — it would shadow the
      # osxcross binary and cause infinite self-recursion.
      macosSdkTools = import ./nix/macos-sdk-tools.nix {
        inherit pkgs rsHarborCli validateMacosSdk;
        realizeMacosSdkBin = osxcross.packages.${system}.realize-macos-sdk;
      };
      steamRuntimeTools = self.lib.mkSteamRuntimeTools {
        inherit pkgs rsHarborCli;
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
          program = "${macosSdkTools.publishMacosSdk}/bin/publish-macos-sdk";
        };
        # Bare osxcross realize step. Operators who want the Rust CLI's
        # structured trailer should use `rs-harbor sdk realize` (no app
        # alias — it would collide with this binary's name and break
        # `which::which("realize-macos-sdk")` inside harbor-sdk).
        realize-macos-sdk = {
          type = "app";
          program = "${macosSdkTools.realizeMacosSdkBin}/bin/realize-macos-sdk";
        };
        validate-macos-sdk = {
          type = "app";
          program = "${validateMacosSdk}/bin/validate-macos-sdk";
        };
        stage-macos-universal = {
          type = "app";
          program = "${macosStaging.stager}/bin/stage-macos-universal";
        };
        deploy-pages = plinth.lib.${system}.mkDeployPagesApp {
          domain = "rs-harbor.tartanoglu.com";
        };
      };

      devShells = import ./nix/dev-shells.nix {
        harbor = self.lib;
        opencodeLsp = nix-opencode-lsp.lib;
        inherit pkgs toolchain cross cargoConfig;
        plinthProject = plinth.packages.${system}.plinth-project;
      };

      checks = import ./checks.nix {inherit self pkgs system toolchain cross;};
    });
}
