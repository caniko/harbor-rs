# mkCargoConfig

`mkCargoConfig` generates a `.cargo/config.toml` tuned for fast local builds and cross-target linker configuration.

## What it configures

- `mold` for Linux linker acceleration when enabled
- `lld`-compatible Rust target configuration where appropriate
- nightly-only optimizations such as Cranelift, shared generics, and parallel frontend work
- extra target sections for the Rust triples you care about

## Parameters

- `pkgs` (required)
- `channel`: `"nightly"` or `"stable"`
- `crossTargets`: target triples to emit configuration for
- `enableMold`
- `enableCranelift`
- `enableShareGenerics`
- `enableParallelFrontend`
- `extraConfig`: raw TOML appended to the generated file

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
