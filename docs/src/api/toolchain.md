# mkToolchain

`mkToolchain` creates the Rust toolchain and `craneLib` used by the rest of the flake.

## Parameters

- `pkgs` (required): nixpkgs with `rust-overlay` applied
- `channel`: `"nightly"` or `"stable"`; defaults to `"nightly"`
- `date`: `"latest"` or a pinned date such as `"2025-12-01"`
- `extensions`: extra Rust components to install. Defaults to `["rust-src" "rustfmt" "rustc-codegen-cranelift-preview" "llvm-tools-preview"]`. `llvm-tools-preview` provides `llvm-cov`/`llvm-profdata`, which `cargo-llvm-cov`-based coverage CI requires.
- `withRustAnalyzer`: whether to include `rust-analyzer` in the toolchain extensions; defaults to `true`
- `crossTargets`: list of target triples to include in the toolchain

## Returns

`mkToolchain` returns an attribute set with:

- `rustToolchain`
- `craneLib`
- `crossTargets`

## Example

```nix
toolchain = rs-harbor.lib.mkToolchain {
  inherit pkgs;
  channel = "stable";
  date = "2026-04-01";
};
```

Most downstream projects only need `craneLib` from the result. Pair it with [mkCargoConfig](./cargo-config.md) and [mkDevShell and mkDevShells](./dev-shells.md) for a complete local environment.
