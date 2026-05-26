# mkCargoConfig

`mkCargoConfig` generates a `.cargo/config.toml` tuned for fast local builds and cross-target linker configuration.

## What it configures

- `mold` for Linux linker acceleration when enabled
- `lld`-compatible Rust target configuration where appropriate
- nightly-only optimizations such as Cranelift, shared generics, and parallel frontend work
- dev-profile defaults that reduce debug info and peak link memory
- extra target sections for the Rust triples you care about

## Parameters

- `pkgs` (required)
- `channel`: `"nightly"` or `"stable"`
- `crossTargets`: target triples to emit configuration for
- `enableMold`
- `enableCranelift`
- `enableShareGenerics`
- `enableParallelFrontend`
- `enableDevProfileOpts`
- `extraConfig`: raw TOML appended to the generated file

### `enableDevProfileOpts` (default: `true`)

When enabled, `mkCargoConfig` writes a `[profile.dev]` section that reduces peak codegen and link memory:

- `debug = "line-tables-only"` keeps line tables for backtraces while dropping full DWARF.
- `split-debuginfo = "unpacked"` puts remaining debug info in side files on platforms that support it; Windows treats this as a no-op.
- `codegen-units = 32` trades some dev-build wall-clock time for lower peak codegen memory.
- `[profile.dev.package."*"] debug = false` drops dependency debuginfo; workspace crates keep line-table backtraces.

Cargo profile precedence means keys in a project's `Cargo.toml [profile.dev]` override the same keys from this generated `.cargo/config.toml`. Set `enableDevProfileOpts = false` if a project needs Cargo's full default dev profile.

This flag does not add binaries to the build environment. It only changes generated Cargo configuration.

## Returns

- `configText`: rendered TOML
- `configPath`: store path to the generated config file

## Example

```nix
cargoConfig = rs-harbor.lib.mkCargoConfig {
  inherit pkgs;
  extraConfig = ''
    [alias]
    xtask = "run -p xtask --"
  '';
};
```

Pass the result into `mkDevShell` or `mkDevShells` and `rs-harbor` will write or update `.cargo/config.toml` when the shell starts.
