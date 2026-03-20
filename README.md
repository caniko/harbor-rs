# rs-harbor

Reusable Rust cross-compilation and toolchain infrastructure for Nix flakes.

Provides three composable functions:

- **`mkToolchain`** — Rust nightly/stable toolchain with crane and cross-compilation targets
- **`mkCross`** — MinGW (Windows) and osxcross (macOS) cross-compilation toolchains
- **`mkDevShell`** — Pre-configured devShell with all cross-compilation env vars

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- The `pkgs` passed to `mkToolchain` must have [rust-overlay](https://github.com/oxalica/rust-overlay) applied
- macOS cross-compilation via osxcross requires the `--impure` flag

## Usage

```nix
{
  inputs = {
    rs-harbor.url = "git+ssh://git@codeberg.org/caniko/rs-harbor.git";
    # Pin shared inputs
    nixpkgs.follows = "rs-harbor/nixpkgs";
    rust-overlay.follows = "rs-harbor/rust-overlay";
    crane.follows = "rs-harbor/crane";
    flake-utils.follows = "rs-harbor/flake-utils";
  };

  outputs = { self, nixpkgs, rs-harbor, flake-utils, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };

      toolchain = rs-harbor.lib.mkToolchain { inherit pkgs; };
      cross = rs-harbor.lib.mkCross { inherit pkgs system; };
    in {
      devShells.default = rs-harbor.lib.mkDevShell {
        inherit pkgs cross;
        inherit (toolchain) craneLib;

        # Your project-specific packages
        packages = with pkgs; [ just wayland.dev vulkan-loader ];

        # Extra environment variables
        extraEnv = {
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader ];
        };

        # Extra shell hook
        extraShellHook = ''
          echo "Welcome to my project!"
        '';
      };
    });
}
```

## API

### `mkToolchain`

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs with rust-overlay applied |
| `channel` | `"nightly"` | `"nightly"` or `"stable"` |
| `date` | `"latest"` | Pin to a date, e.g. `"2025-12-01"` |
| `extensions` | `["rust-src" "rustfmt" "rustc-codegen-cranelift-preview"]` | Rustup components |
| `crossTargets` | linux + windows + macOS | Rust target triples |

Returns: `{ rustToolchain, craneLib, crossTargets }`

### `mkCross`

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs |
| `system` | required | Host system string |
| `enableOsxcross` | `true` | Enable macOS cross-compilation (requires `--impure`) |
| `osxSdkVersion` | `"26.1"` | macOS SDK version |

Returns: `{ mingwCC, mingwBinutils, winpthreads, windowsEnv, osxcrossToolchain, osxcrossRustHelpers }`

### `mkDevShell`

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs |
| `craneLib` | required | From `mkToolchain` |
| `cross` | required | From `mkCross` |
| `enableWindowsEnv` | `true` | Include Windows cross-compilation env vars |
| `enableOsxcrossEnv` | `true` | Include osxcross toolchain and shell hook |
| `packages` | `[]` | Extra packages |
| `extraEnv` | `{}` | Extra environment variables |
| `extraShellHook` | `""` | Additional shell hook |
| `checks` | `{}` | Flake checks |

Returns: a devShell derivation

## What's included in the devShell

**Packages:** cmake, gcc, clang, mold, lld, pkg-config, mingw binutils, osxcross (if enabled)

**Environment:** `LIBCLANG_PATH`, Windows cross-compilation (`CC_x86_64_pc_windows_gnu`, linker, rustflags)

## Testing

```bash
nix flake check   # Run all checks (attribute shapes, validation logic)
```
