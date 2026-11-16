# compile-bench

`harbor-compile-bench` measures how a consumer's build responds to the
`.cargo/config.toml` `mkCargoConfig` generates. It exists so a proposed default
change ships with a before/after number from the project that would receive it,
instead of a flag count.

```sh
nix develop -c nix run github:caniko/harbor-rs#compile-bench -- \
  --edit-file crates/api/src/lib.rs
```

Run it inside the consumer's dev shell: the shell supplies `cargo`, `rustc`
and the project's inputs. The bench adds `hyperfine`, `jq`, `git`, `systemd` and
`wild`, and appends `clang` and `mold` to `PATH` for shells that lack them.

## Variants

Each variant is one generated `config.toml`; the table prints with
`--list-variants`.

| Variant | Config |
| --- | --- |
| `none` | empty config, as a `craneLib.devShell` consumer has today |
| `current` | `mkCargoConfig` defaults |
| `threads0` / `nothreads` | `parallelFrontendThreads = 0` (one per core) / `enableParallelFrontend = false` |
| `lld` | `enableMold = null`, so rust-lld serves `x86_64-unknown-linux-gnu` |
| `wild` | `enableMold = false` plus `linker = "clang"` and `-Clink-arg=--ld-path=wild` |
| `nohint` | `enableHintMostlyUnused = false` |
| `buildopt` | `devBuildOverrideOptLevel = 3` |
| `cranelift` | `enableCranelift = true`, informational |
| `incremental` | `current`, with `CARGO_INCREMENTAL` unset |
| `aslived` | `current`, with the host's `RUSTC_WRAPPER` (warm sccache) |

The channel comes from `rustc -V`. Nightly-only variants (`threads0`,
`nothreads`, `nohint`, `cranelift`) are offered on nightly only, and asking for
one on stable fails with a message instead of silently running `current`.

Fixed for every variant except `aslived` and `incremental`: `RUSTC_WRAPPER`
unset, `CARGO_INCREMENTAL=0`, `CARGO_BUILD_JOBS=16`, `CARGO_BUILD_BUILD_DIR`
unset, and a private `CARGO_HOME` and `CARGO_TARGET_DIR` per variant. `registry`
and `git` are symlinked from your own Cargo home, so variants reuse downloads
instead of fetching them again. The dev-shell environment is captured once
(`export -p`) and re-sourced in each unit.

## Scenarios

| Scenario | Command | Runs |
| --- | --- | --- |
| `S1` | clean `cargo build --workspace` | 3 |
| `S2` | no-op `cargo build --workspace` | 5 |
| `S3` | `cargo build --workspace` after the one-line edit | 5 |
| `S4` | clean `cargo check --workspace` | 3 |
| `S5` | `cargo check --workspace` after the one-line edit | 5 |

`--scenarios a,b` selects a subset; the order is always S1 to S5. `S3` and `S5`
append a single comment line to `--edit-file` before each run and restore the
file on exit, including after a failure.

`W1` (a wasm `cargo check` of one web crate) is not built in yet: it needs a
package name per subject, which this interface does not take.

## Memory

Each run happens in its own `systemd-run --user` unit with `MemoryMax` set to
`--memory-max`, or to `min(24G, MemAvailable - 4G)`; the bench refuses to start
below 12G rather than measured under pressure. `MemorySwapMax=0` keeps a run
from spilling to swap and reporting a number nobody can reproduce. The unit's
own cgroup `memory.peak` is captured before the unit exits, because systemd
drops `MemoryPeak` once a transient unit stops.

## Results

`--out DIR` (default `./compile-bench-results`) receives:

- `<variant>/<scenario>.json`: hyperfine's report, mean and stddev included
- `<variant>/<scenario>.sh`: the command that ran; it sources a private dump of
  the dev-shell environment that is deleted afterwards (it may hold secrets)
- `toolchain`: `rustc -vV` and `cargo -V`
- `<variant>/<scenario>.peak-bytes`: the unit's peak memory
- `rev`: the consumer's `git` HEAD

Pass `--out` per subject, e.g. `--out results/fleetix`, to keep one directory
per project.
