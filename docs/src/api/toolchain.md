# mkToolchain

`mkToolchain` creates the Rust toolchain and `craneLib` used by the rest of the flake.

## Parameters

- `pkgs` (required): nixpkgs with `rust-overlay` applied
- `toolchainFile`: optional path to a standard `rust-toolchain.toml`; when set, its channel, components, and targets are authoritative
- `channel`: `"nightly"` or `"stable"`; defaults to `"nightly"`
- `date`: `"latest"` or a pinned date such as `"2025-12-01"`; only used without `toolchainFile`
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

Path-patch detection reads `Cargo.toml` during evaluation. Direct Nix paths and
`lib.cleanSourceWith` sources are handled automatically. If `src` is a generated
derivation output or an undeclared plain-string path, provide the manifest
explicitly to avoid import-from-derivation and store-state-dependent evaluation:

```nix
craneLib.buildPackage {
  src = generatedSource;
  rsHarborCargoTomlContents = builtins.readFile ./Cargo.toml;
  # ...
}
```

The rs-harbor-only argument is removed before the remaining arguments are
passed to Crane.

## Example

```nix
toolchain = rs-harbor.lib.mkToolchain {
  inherit pkgs;
  channel = "stable";
  date = "2026-04-01";
};
```

Most downstream projects only need `craneLib` from the result. Pair it with [mkCargoConfig](./cargo-config.md) and [mkDevShell and mkDevShells](./dev-shells.md) for a complete local environment.

Projects with a checked-in Rust toolchain file can consume it directly:

```nix
toolchain = rs-harbor.lib.mkToolchain {
  inherit pkgs;
  toolchainFile = ./rust-toolchain.toml;
  cache.enable = false;
};
```

In file mode, `channel` and `date` must be omitted. Explicit `extensions` and
`crossTargets` are added to the components and targets declared by the file.
