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

## Path-patched crates and `buildDepsOnly`

The returned `craneLib` wraps Crane's `buildPackage` and `buildDepsOnly` for workspaces that use `[patch.crates-io]` with local `path` entries.

Crane's dependency-only phase builds a dummy source tree for path crates. That is unsafe when a registry dependency compiles against a patched local crate, because the dependency may see the dummy crate API instead of the real patched API.

For these workspaces, `craneLib.buildPackage` automatically disables implicit dependency artifact reuse by passing `cargoArtifacts = null` unless the caller already provided `cargoArtifacts`.

Direct `craneLib.buildDepsOnly` calls fail with an rs-harbor error naming the path patches. Prefer:

```nix
craneLib.buildPackage (commonArgs // {
  cargoArtifacts = null;
})
```

If a workspace is known to tolerate dummy path patches, pass `rsHarborAllowPathPatchBuildDepsOnly = true` to `buildDepsOnly`.

## Example

```nix
toolchain = rs-harbor.lib.mkToolchain {
  inherit pkgs;
  channel = "stable";
  date = "2026-04-01";
};
```

Most downstream projects only need `craneLib` from the result. Pair it with [mkCargoConfig](./cargo-config.md) and [mkDevShell and mkDevShells](./dev-shells.md) for a complete local environment.
