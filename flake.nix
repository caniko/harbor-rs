{
  description = "Reusable Rust cross-compilation and toolchain infrastructure for Nix flakes";

  inputs = {
    crane.url = "github:ipetkov/crane";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    osxcross = {
      url = "github:caniko/osxcross/flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    meta-harbor = {
      url = "git+https://codeberg.org/caniko/meta-harbor.git?ref=trunk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-opencode-lsp = {
      url = "git+https://codeberg.org/caniko/nix-opencode-lsp.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    inputs@{
      flake-parts,
      self,
      nixpkgs,
      crane,
      rust-overlay,
      osxcross,
      meta-harbor,
      nix-opencode-lsp,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      flake = let
        lib = import ./lib {
          inherit crane osxcross;
          meta-harbor = meta-harbor.lib;
        };
      in {
        inherit lib;

        nixosModules = {
          macosSdk = import ./nix/nixos-module.nix;
          sccache = import ./nix/sccache-module.nix;
          buildCache = import ./nix/build-cache-module.nix;
        };

        homeManagerModules.sccache = import ./nix/sccache-home.nix;

        templates.bevy = {
          path = ./templates/bevy;
          description = "Bevy game engine project with rs-harbor cross-compilation";
        };
      };

      perSystem =
        { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };

          validateMacosSdk = import ./nix/validate-macos-sdk.nix {
            inherit pkgs;
          };

          toolchain = self.lib.mkToolchain { inherit pkgs; };
          cross = self.lib.mkCross { inherit pkgs system; };
          cargoConfig = self.lib.mkCargoConfig { inherit pkgs; };

          bootstrapCmdsMig = import ./nix/bootstrap-cmds-mig.nix {
            inherit pkgs;
          };

          rsHarborCli = import ./nix/rs-harbor-cli.nix {
            inherit pkgs;
            inherit (toolchain) craneLib;
            src = ./.;
          };

          macosStaging = self.lib.mkMacosUniversalStager {
            inherit pkgs rsHarborCli;
          };

          macosSdkTools = import ./nix/macos-sdk-tools.nix {
            inherit pkgs rsHarborCli validateMacosSdk;
            realizeMacosSdkBin = osxcross.packages.${system}.realize-macos-sdk;
          };

          steamRuntimeTools = self.lib.mkSteamRuntimeTools {
            inherit pkgs rsHarborCli;
          };
        in
        {
          packages =
            {
              # Consumers use this build-platform package to keep the
              # compiler-cache executable and version identical across the
              # Atlas fleet and every rs-harbor builder.
              sccache = pkgs.sccache;
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
            generate-jetbrains-signing-material = {
              type = "app";
              program = "${self.lib.mkJetBrainsSigningMaterial {inherit pkgs;}}/bin/generate-jetbrains-signing-material";
            };
          };

          devShells = import ./nix/dev-shells.nix {
            harbor = self.lib;
            opencodeLsp = nix-opencode-lsp.lib;
            inherit pkgs toolchain cross cargoConfig rsHarborCli;
          };

          checks = import ./checks.nix {
            inherit self pkgs system toolchain cross;
            rootInputNames = builtins.attrNames inputs;
          };
        };
    };
}
