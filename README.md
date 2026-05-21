# rs-harbor

Reusable Rust toolchain and cross-compilation infrastructure for Nix flakes.

`rs-harbor` packages the Nix plumbing most Rust workspaces need when targeting Linux, Windows, and macOS:

- `mkToolchain` for Rust toolchains with `crane`
- `mkCargoConfig` for generated `.cargo/config.toml`
- `mkCross` for MinGW and optional osxcross environments
- `mkDevShell` and `mkDevShells` for consistent development shells
- `mkGpuRenderPin` for visual snapshot test renderer pinning
- `mkAppImage`, `mkFlatpakManifest`, `mkCoprSpec`, and `mkHomebrewFormula` for packaging outputs

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- [rust-overlay](https://github.com/oxalica/rust-overlay) applied to the `pkgs` you pass into `mkToolchain`
- A configured macOS SDK only if you want osxcross-based macOS targets

## Quick Start

```nix
{
  outputs = { self, nixpkgs, rs-harbor, flake-utils, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [(import rust-overlay)];
      };

      toolchain = rs-harbor.lib.mkToolchain { inherit pkgs; };
      cross = rs-harbor.lib.mkCross { inherit pkgs system; };
      cargoConfig = rs-harbor.lib.mkCargoConfig { inherit pkgs; };
    in {
      devShells = rs-harbor.lib.mkDevShells {
        inherit pkgs cross cargoConfig;
        inherit (toolchain) craneLib;
      };
    });
}
```

This produces:

- `nix develop` for native work
- `nix develop .#windows` for MinGW cross builds
- `nix develop .#macos` for osxcross when a macOS SDK is configured
- `nix develop .#cross` for both Windows and macOS helpers

## macOS SDK Init

Initialize the SDK once per host, using a host-local archive path:

```bash
nix run rs-harbor#init-macos-sdk -- /host/local/MacOSX26.1.sdk.tar.xz 26.1
```

Then pass the realized store path to `mkCross` from host configuration rather than committing host-local archive paths. Full setup details are in [docs/src/reference/macos-sdk.md](docs/src/reference/macos-sdk.md).

## Homebrew Formula Bump

After release archives exist on disk, `rs-harbor brew bump` renders a Homebrew formula with real sha256 sums:

```bash
rs-harbor brew bump \
  --tap ../homebrew-tap \
  --name my-app \
  --version 1.0.0 \
  --description "My example application" \
  --homepage https://example.com/my-app \
  --license MIT \
  --archive linux_intel=https://example.com/releases/my-app-1.0.0-x86_64-linux.tar.gz,dist/my-app-linux.tar.gz
```

Use `--stdout` to print the formula for piping, or `--push` to commit and push the tap update after rs-harbor verifies the tap has no unrelated dirty files.

## Docs

- [Getting started](docs/src/getting-started/installation.md)
- [Quick start](docs/src/getting-started/quick-start.md)
- [API summary](docs/src/SUMMARY.md)
- [mkCross](docs/src/api/cross.md)
- [mkDevShell and mkDevShells](docs/src/api/dev-shells.md)
- [Packaging](docs/src/packaging/appimage.md)
- [Homebrew formula](docs/src/packaging/homebrew-formula.md)
- [COPR spec](docs/src/packaging/copr.md)

Source repository: <https://codeberg.org/caniko/rs-harbor>
