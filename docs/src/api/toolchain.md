# mkToolchain

`mkToolchain` creates the Rust toolchain and `craneLib` used by the rest of the flake.

## Parameters

- `pkgs` (required): native or cross nixpkgs. It needs no `rust-overlay`: toolchains resolve through harbor-rs's own `rust-overlay` input on `pkgs.buildPackages`, whatever overlay `pkgs` carries
- `toolchainProfile`: optional harbor-rs-owned pin, either `"stable"` or `"nightly"`. Stable is currently pinned to Rust `1.98.1`; nightly uses the repository's checked-in `rust-toolchain.toml` (currently `nightly-2026-10-11`). Omitting it preserves the legacy channel/date behavior.
- `toolchainFile`: optional path to a standard `rust-toolchain.toml`; when set, its channel, components, and targets are authoritative
- `channel`: `"nightly"` or `"stable"`; defaults to `"nightly"`
- `date`: `"latest"` or a pinned date such as `"2025-12-01"`; only used without `toolchainFile`
- `extensions`: extra Rust components to install. Defaults to `["rust-src" "rustfmt" "rustc-codegen-cranelift-preview" "llvm-tools-preview"]`. `llvm-tools-preview` provides `llvm-cov`/`llvm-profdata`, which `cargo-llvm-cov`-based coverage CI requires.
- `withRustAnalyzer`: whether to include `rust-analyzer` in the toolchain extensions; defaults to `true`
- `crossTargets`: list of target triples to include in the toolchain
- `targets`: list of target triples that replaces the profile, file, or legacy target list instead of extending it; `[]` installs only the host standard library. Cannot be combined with `crossTargets`
- `cache.enable`: explicitly enable the host-backed compiler cache; defaults to `false`
- `rustBin`: escape hatch, a `rust-bin` set for the build platform (for example `pkgs.buildPackages.rust-bin` from your own rust-overlay) used instead of harbor-rs's. You then own the availability of the selected channel
- `cargoConfigArgs`: attribute set merged into the `mkCargoConfig` call for the toolchain's generated config, for example `{ parallelFrontendThreads = 6; }`. `mkCargoConfig`'s asserts still fire, so a nightly-only knob on a stable toolchain fails evaluation. The generated file keeps today's bytes when the defaults are unchanged

A `toolchainFile` channel or `date` newer than harbor-rs's `rust-overlay` pin
is not available by default. Bump harbor-rs, override its input
(`inputs.harbor-rs.inputs.rust-overlay.follows = "rust-overlay"`), or pass
`rustBin`.

## Returns

`mkToolchain` returns an attribute set with:

- `rustToolchain`
- `craneLib`
- `buildCache`: the compiler-cache policy when enabled, otherwise `null`
- `cargoConfig`: matching `mkCargoConfig` output, installed automatically by every `craneLib.devShell` and every harbor-rs dev shell using this `craneLib`
- `crossTargets`

## Dev shells

The returned `craneLib` overrides Crane's `devShell`, so a bare
`craneLib.devShell` carries the generated Cargo config hook and the packages
that config needs (`clang`, and `mold` while an emitted target links with
mold), with no consumer edit. `mkDevShell` and `mkDevShells` install the same
hook themselves and disable the `craneLib` copy, so it runs exactly once.

Opt out, or replace the config, per shell:

```nix
devShells.default = toolchain.craneLib.devShell {
  # Keep whatever rustflags the project and environment already set.
  rsHarborCargoConfig = false;
};

devShells.bench = toolchain.craneLib.devShell {
  # Any mkCargoConfig result replaces the toolchain's config.
  rsHarborCargoConfig = harbor-rs.lib.mkCargoConfig {
    inherit pkgs;
    channel = "nightly";
    enableCranelift = true;
  };
};
```

Cargo reads exactly one rustflags source, in this order, first non-empty wins:
`CARGO_ENCODED_RUSTFLAGS`, `RUSTFLAGS`, all matching `target.*.rustflags`,
then `build.rustflags`. The generated config sets `target.*.rustflags`, so a
project that keeps flags in `[build] rustflags` inside its own
`.cargo/config.toml` does not get them once the generated config is active.
Put project flags in `[target.<triple>]` (Cargo joins every matching target
entry), export `RUSTFLAGS`, or opt out of the generated config.

Cargo, rustc, and the other toolchain executables always run on
`pkgs.stdenv.buildPlatform`, including when `pkgs` is a cross package set.
The requested standard-library targets remain available through `crossTargets`;
Crane still uses the supplied target stdenv and linker for the output package.

## Path-patched crates and `buildDepsOnly`

The returned `craneLib` wraps Crane's `buildPackage` and `buildDepsOnly` for workspaces that use `[patch.crates-io]` with local `path` entries.

Crane's dependency-only phase builds a dummy source tree for path crates. That is unsafe when a registry dependency compiles against a patched local crate, because the dependency may see the dummy crate API instead of the real patched API.

For these workspaces, `craneLib.buildPackage` automatically disables implicit dependency artifact reuse by passing `cargoArtifacts = null` unless the caller already provided `cargoArtifacts`.

Direct `craneLib.buildDepsOnly` calls keep the patched crates real. harbor-rs
builds the dummy source with Crane's `mkDummySrc`, then copies each patch
directory back from a source filtered to those directories, and vendors from
the real `src`. The dependency derivation therefore changes only with Cargo
manifests, `Cargo.lock` and the patched crates, and evaluation needs no
import-from-derivation. Pass the real `src` and no `dummySrc`:

```nix
cargoArtifacts = craneLib.buildDepsOnly commonArgs;
```

This needs `src` as a direct Nix path or `lib.cleanSourceWith` source with
every patch path inside it. Otherwise, and when `dummySrc` or
`rsHarborCargoTomlContents` is passed, `buildDepsOnly` fails with an harbor-rs
error naming the path patches; build with `cargoArtifacts = null` instead. If a
workspace is known to tolerate dummy path patches, or supplies its own
`dummySrc`, pass `rsHarborAllowPathPatchBuildDepsOnly = true`.

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

The harbor-rs-only argument is removed before the remaining arguments are
passed to Crane.

## Example

```nix
toolchain = harbor-rs.lib.mkToolchain {
  inherit pkgs;
  channel = "stable";
  date = "2026-04-01";
};
```

Most downstream projects only need `craneLib` from the result. [mkDevShell and mkDevShells](./dev-shells.md) inherit its matching Cargo configuration automatically.

Compiler caching is host infrastructure rather than a portable toolchain
default. Hosts with a managed cache transport can opt in explicitly:

```nix
toolchain = harbor-rs.lib.mkToolchain {
  inherit pkgs;
  cache.enable = true;
};
```

## Optional fleet profiles

The profiles are opt-in. A project that wants harbor-rs to control its Rust
version can select a profile and reuse the returned Cargo configuration:

```nix
toolchain = harbor-rs.lib.mkToolchain {
  inherit pkgs;
  toolchainProfile = "stable";
};
cargoConfig = toolchain.cargoConfig;
```

The selected profile is also inherited by `mkCrossPackages` for non-native
outputs unless `toolchainArgs` is supplied explicitly. Updating the profile
manifest in harbor-rs then updates every consumer when it refreshes its
harbor-rs input, without requiring per-project version edits.

Both profile manifests select the rustup `minimal` profile and list `clippy`
and `rustfmt` as components. Compared with rustup's default profile, the only
component left out is `rust-docs`, a large download that every crane package
build would otherwise pull in. `cargo`, `rustc`, `clippy`, `rustfmt`,
`rust-src`, and `rust-analyzer` stay available.

Projects with a checked-in Rust toolchain file can consume it directly:

```nix
toolchain = harbor-rs.lib.mkToolchain {
  inherit pkgs;
  toolchainFile = ./rust-toolchain.toml;
};
```

In file mode, `channel` and `date` must be omitted. Explicit `extensions` and
`crossTargets` are added to the components and targets declared by the file;
`targets` replaces the file's targets.
