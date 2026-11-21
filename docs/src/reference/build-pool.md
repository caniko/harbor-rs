# Host build pool for harbor-rs projects

Status: design, awaiting operator approval. Nothing here is implemented.
Owner: harbor-rs (`components/rust`). Host wiring: canix. Evidence:
`ProjectState/by-project/owned/harbor-rs/research/2026-11-15-build-pool-spike/`.
Reviewed by a Fable 5.2 session on 2026-11-15 ("approve with edits"). Its
findings are folded in below.

## Problem

Atlas has 32 CPUs and 64 GB of RAM. On 2026-11-15 around 19:45Z the load
average was 99/80/65, CPU PSI some avg60 was 68%, memory PSI full was about 3%,
swap held 20.5 of 24 GB and MemAvailable was about 17 GB. A dozen cargo
processes were running at once: SynDB tests, a rust-analyzer flycheck, canix
CLI checks with three more rust-analyzers, hub release builds, foundry-circle,
chessbender, a pink-raven `dx bundle`, and a harbor-rs compile-bench campaign.

Nothing limits concurrency across processes, and each cargo defaults to `-j32`.
`CARGO_BUILD_JOBS` is set only by canix `workspace update` and `macro_ui.rs`.
Memory PSI full sits at 3–4% even at load 19–45. Seven rust-analyzers held
14.5 GB RSS against 10.6 GB for eleven rustc, so part of the pressure is not
cargo at all.

The goal is for T3 threads working in large Rust projects (SynDB, canix,
pink-raven, ...) to coordinate their builds, so the host stays responsive and a
single thread's build is not much slower than it is today.

## What a cargo-level scheduler can and cannot bound

| Consumer                                                                   | Bounded by a shared jobserver?                                                                                                                        |
| -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| rustc and build scripts started by cargo                                   | Yes: cargo needs a token to start each unit.                                                                                                          |
| rustc `-Zthreads` and LLVM codegen threads, when cargo runs rustc directly | Yes, through the inherited `CARGO_MAKEFLAGS`. To verify (step 0). Only nightly harbor-rs builds pass `-Zthreads=0`: one of six sampled rustc had it.  |
| rustc that the sccache server runs on a miss                               | Only the start is bounded. Internal threads use the server's own pool. Sampled rustc were direct children of cargo, so the split is unknown (step 0). |
| Linkers (mold)                                                             | No. They are sized by CPU count; `MOLD_JOBS` is a separate knob.                                                                                      |
| Test and bench execution                                                   | No. `RUST_TEST_THREADS` and nextest `--test-threads` control them.                                                                                    |
| rust-analyzer analysis and cache priming                                   | No. The SynDB thread owns rust-analyzer configuration.                                                                                                |
| rust-analyzer flychecks (`cargo check`)                                    | Yes, when its environment carries the variable.                                                                                                       |
| nix-daemon builders                                                        | No. They use their own `cores`/`max-jobs` and a sandboxed environment.                                                                                |

The peak mix contained test and bench runs, rust-analyzer and `dx`, none of
which a pool bounds. We do not yet know rustc's share of the load. Measuring it
comes first.

## Spike results (2026-11-15, cargo 1.99.0)

The test was six crates whose `build.rs` sleeps 3 s, run against a fifo with
one token, so cargo's implicit token makes two units concurrent.

- `CARGO_MAKEFLAGS="-j --jobserver-auth=fifo:PATH"` is honoured: 10.8 s
  against 4.6 s unbounded, and the token comes back. `MAKEFLAGS` works too. We
  would export only `CARGO_MAKEFLAGS`.
- An inherited pool overrides `-j6`, so it also overrides canix's
  `CARGO_BUILD_JOBS`.
- When the fifo path is missing, cargo warns and falls back to its private
  pool (fails open).
- SIGKILL of cargo and its children loses the token it held.
- T3 agents run in `app-t3code-agents-*.slice` scopes and inherit canix
  `environment.sessionVariables`. `CARGO_BUILD_BUILD_DIR` arrives this way.

## Step 0 results (scout, 2026-11-15)

Full record: `.../2026-11-15-build-pool-spike/step0.md`.

- **Every signal death leaks.** cargo-only SIGINT, cargo-only SIGTERM and
  process-group SIGINT each took a 4-token fifo to 0.
- **rust-analyzer kills its flycheck on every restart.** It cancels the
  in-flight flycheck with SIGKILL to the whole process group:
  `flycheck.rs` → `command.rs` → process-wrap 9.1 `killpg(SIGKILL)`.
- **Consequence:** with a shared fifo, rust-analyzer would drain the pool
  through ordinary use. **Option A is rejected.** No estimate-based
  reconciliation keeps up with a leak on every save.
- **rustc threads:** inconclusive. With 1 and with 16 tokens, rustc ran
  14 threads either way (12.6 s against 11.1 s, 123% against 173% CPU). The
  runs were short and the host was loaded. UNVERIFIED.
- **sccache split:** about 93% of sampled rustc are direct children of cargo
  (279 of 307 samples); 20 were spawned by the sccache server. The server's
  private pool is a minor factor.
- **make:** inconclusive. The test passed a bare `make -j`, which resets the
  jobserver by design. The cc and cmake crates do not pass a bare `-j`.
- **Environment reach:** all six rust-analyzers carried
  `CARGO_BUILD_BUILD_DIR`, so a session variable reaches them.

Enforcement candidates are now **static caps (0)** and the **per-client proxy
(E)**. E's cargo wrapper is the same wrapper the train needs
(`harbor-rs build`), so one wrapper does both. It is leak-exact under
rust-analyzer's `killpg`: the wrapper dies with the group, and the daemon
reclaims that client's tokens on socket EOF. Run the A/B with off against
static caps first, because that needs no code. Build E only if static caps
fail the acceptance criteria.

## When "build together" shares work

- **Same build dir.** This means the same worktree, since
  `CARGO_BUILD_BUILD_DIR` is keyed by workspace path.
  - Cargo's lock already serialises concurrent cargos here, per profile dir.
  - Batching saves work only for _identical_ requests: same argv and same
    build-relevant environment. One run then serves everyone who boarded
    before it started. This is sound because every boarded thread is blocked,
    not editing, at departure.
  - Different commands still run one after another. Merging different `-p`
    sets changes feature unification, so we never merge them.
  - This case is real for canix, whose AGENTS.md puts every session in one
    checkout.
- **Different worktrees at the same commit.** Nothing is shared.
  - Workspace crates miss sccache, because keys contain the workspace root and
    `CARGO_MANIFEST_DIR`.
  - Registry crates that depend on `OUT_DIR` miss too: serde and everything
    downstream.
  - Simultaneous starts are the worst case, because sccache does not
    deduplicate builds in flight.
- **Different projects.** Pure contention. Synchronised starts only raise the
  peaks.

So the operator's "wait, then build together" pays only within one build dir.
There it reduces to coalescing identical commands.

## Options

|                         | 0. Static caps                                                 | A. Shared fifo pool                              | B. Declared barrier                                      | C. Per-build-dir train                                                               | E. Per-client proxy                                                |
| ----------------------- | -------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| What it is              | Session variables: `CARGO_BUILD_JOBS=8`, `RUST_TEST_THREADS=8` | A daemon fills one fifo; every cargo inherits it | Threads declare intent, and all start when all are ready | A `harbor-rs build --` wrapper boards per build dir and coalesces identical commands | A wrapper gives each cargo a private fifo fed from a global budget |
| Host-wide cap           | No; per cargo only                                             | Yes                                              | No                                                       | No                                                                                   | Yes                                                                |
| Covers LSPs and scripts | Yes                                                            | Yes                                              | No                                                       | No                                                                                   | Only if the wrapper wins the `$CARGO`/`PATH` lookup                |
| Shares work             | No                                                             | No                                               | No                                                       | Identical commands, same dir                                                         | No                                                                 |
| Crash safety            | n/a                                                            | Leaks on any signal death (below)                | A dead participant stalls everyone until timeout         | Socket EOF releases                                                                  | Exact, per client                                                  |
| Cost                    | One line                                                       | Daemon and reconciliation                        | Fragile protocol                                         | Wrapper and train logic                                                              | Wrapper and rebalance loop                                         |

Leaks under A are routine, not rare. Any signal death skips the token return:
Ctrl-C, tool timeouts, thread interrupts, and probably rust-analyzer killing
its in-flight flycheck on every save (UNVERIFIED; step 0 tests it). With
several rust-analyzers the fifo is never idle, so idle-only refill would drain
the pool to zero. Every cargo would then run on its single implicit token,
which is worse than today. A is acceptable only with busy-time reconciliation,
and E only if step 0 shows that reconciliation drifts.

B is rejected. A T3 agent cannot be interrupted in the middle of a tool call,
so a thread that declared intent can keep everyone waiting for minutes.

AMC is not deployed on Atlas (there is no `/run/amc-host`), and canix's
`nix-eval.d` ledger belongs to evaluation and is unreadable by the agent user.
We reuse the principle (admit by memory, crash-safe liveness) and depend on
neither.

Sharing a pool with the sccache server is rejected. Cargos can hold every
token while they block on sccache clients, and the server needs a token for
each spawn, so it can deadlock (UNVERIFIED, from sccache's spawn path).

## Recommendation

Measure first, then pick the cheapest enforcement that works, and build the
train only where it pays.

1. **Observe.** `harbor-rs pool serve --observe` scans `/proc` every 5–10 s,
   looking only at cargo, rustc, test binaries, rust-analyzer and the linker.
   It exports nothing and enforces nothing. Exporting a high-capacity fifo as
   an "observe" mode would lift every per-cargo `-j` cap, so we do not do that.
   - Logged as JSONL under `~/.local/state/harbor-rs/pool/`:
     - CPU time and RSS by class (rustc, test binaries, rust-analyzer, linker,
       and nix-daemon from its cgroup);
     - cargos per build dir, and overlaps of identical argv (the train gate);
     - holder tree RSS against rust-analyzer RSS (for the memory question).
   - The MCP tool `build_status` serves the same data.
2. **Step 0 and the A/B** (see the measurement plan) decide enforcement:
   - If static caps get most of the gain, ship option 0 and stop. There is no
     daemon to maintain.
   - Otherwise ship E, built into the train's wrapper. A was rejected by
     step 0.
   - Enforcement is gated on rustc and cargo being a large share of CPU time.
     If tests, rust-analyzer and links dominate, a jobserver is the wrong
     tool.
3. **The train (C)**, built flycheck-first after the observe scanner (see
   Decisions). It is the only part that delivers "wait, then build together";
   phase 1 delivers none of it.

### Enforcement mechanics for A (rejected by step 0; kept for the record)

- **Inode.** The daemon creates `/run/user/<uid>/harbor-rs/jobserver.fifo` and
  keeps the descriptor in systemd's fd store (`FDSTORE=1`,
  `FileDescriptorStorePreserve=restart`), so restarts keep the same inode and
  tokens. Renaming a fresh fifo over the path would let old cargos keep the
  old inode's free tokens, up to twice the capacity. The path is removed only
  when the operator disables the pool; cargo then fails open with a warning.
- **Reconciliation** runs every 5–10 s, also while busy.
  - Upper bound on held tokens: for each cargo, its live rustc/build-script
    children minus one; for each rustc, its threads beyond the main one.
  - Scan, read the level (`FIONREAD`), then scan again. Set the level exactly,
    in both directions, toward `capacity − withheld − held_bound`, after the
    same deficit has appeared on three scans.
  - Ceiling: the bound overestimates, so the pool under-refills; it never
    over-issues. Cargos under other uids are invisible to the scan.
- **Memory withholding** is log-only at first: the daemon records "would
  withhold". At the current pressure (PSI full of 3–4% at low load) any
  threshold near 2% would latch at the floor. Withholding also cannot relieve
  rust-analyzer RSS or swap, and every cargo keeps an implicit token. A
  non-blocking 1 Hz read probably loses to blocked readers under saturation.
  Thresholds come from the observe data. If per-build memory admission turns
  out to be needed, it belongs in the train wrapper, which admits whole cargo
  invocations.
- **Opt-in.** A harbor-rs NixOS module, `programs.harborRs.buildPool = {
enable; user; capacity; }`, defines the user service and sets
  `environment.sessionVariables.CARGO_MAKEFLAGS`, the mechanism that already
  delivers `CARGO_BUILD_BUILD_DIR` to agents. harbor-rs `mkDevShells` exports
  it when the fifo exists. Canix enables the module on Atlas.
  - Opt-outs (`env -u CARGO_MAKEFLAGS`): compile-bench campaigns, because the
    pool corrupts their timings, and canix `workspace update` workers, because
    their memory permits assume their own per-worker cores.
- **Rollout.** Session variables reach only new sessions. Plan a cut-over, and
  expect a stale variable to warn on every cargo after the pool is disabled.

### MCP surface

`harbor-rs mcp` is a stdio thin client of the daemon socket,
`/run/user/<uid>/harbor-rs/pool.sock`. Each harness session starts its own MCP
process, so state lives in the daemon. It is registered once in canix
`fleetix.mcp.servers` as `harbor-rs` on Atlas. The rmcp skeleton is copied from
harbor-mcp, but this does not live there: harbor-mcp is a semver planner with
its own release cadence.

| Tool           | Phase | Arguments                      | Returns                                                                                                                                                                                                                                                 |
| -------------- | ----- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build_status` | 1     | `cwd?`, `build_dir?`           | Host `{mem_available, psi}` and CPU/RSS by class. Running cargos `{pid, build_dir, cwd, argv, class: agent\|flycheck\|terminal, started, rss}`. When A is enforced, also pool `{capacity, level, held_bound, withheld}` and reconciliation corrections. |
| `build_result` | Train | `ticket`, `wait_seconds` ≤ 300 | The outcome and output tail of a train run. Call it again to keep waiting (the `pin_result` pattern).                                                                                                                                                   |

There is no `build_wait`. In canix's checkout, with flychecks on every save,
the build dir is never idle: waiters would time out, then stampede when it
does go idle. Waiting on cargo's lock costs the same wall time with no tool
round trips.

### The train (gated)

`harbor-rs build [--class interactive|batch] -- cargo ...` is a CLI wrapper
that runs in the agent's own shell. Only that shell has the devshell
environment and the agent's memory-limited scope, so an MCP process cannot run
the build.

- **Key.** The build dir plus a hash of the argv and the build-relevant
  environment (`RUSTFLAGS`, `CARGO_*`, the toolchain).
- **Departure.** If the dir is idle and nobody is boarding, the build starts
  immediately, so a single thread pays nothing. Otherwise the request boards
  the next train. A train departs when the build it waits behind finishes,
  plus a 2 s grace, or 15 s after it opens on an idle dir.
- **Coalescing.** The first identical request executes. The others get its
  streamed output and exit code through the daemon. Non-identical requests run
  back to back.
- **Liveness.** Participants hold a socket to the daemon, and EOF drops them.
  If the executor is cancelled, the other participants re-board.
- **Batch class** (benches, campaigns, release builds) departs only after the
  host has been below a load threshold for 30 s. It has no deadline.
- **Fallback.** If the daemon is unreachable, the wrapper execs cargo
  unchanged.
- **Waking.** Run the wrapper in the foreground: the extra wait is at most the
  boarding window. Long runs go to a T3 background task with
  `t3_background_wait`. `build_result` serves threads that want someone else's
  result.
- **Flychecks.** rust-analyzer's `check.overrideCommand` may point at the
  wrapper, so that flychecks coalesce. That is the SynDB thread's call; this
  design only provides the hook.

## Failure modes

| Failure                                                 | Effect                                                             | Handling                                                         |
| ------------------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------- |
| A token holder dies by any signal (A)                   | Capacity shrinks                                                   | Busy-time reconciliation; E if step 0 shows drift.               |
| Daemon crash or restart (A)                             | None: the fd store keeps the inode                                 | `Restart=always`.                                                |
| Pool disabled while the variable is still set           | Warning on every cargo, private pool                               | Fails open; next session picks up the change.                    |
| Concurrent top-up race (A)                              | ±1 token                                                           | Scan, read, scan, then set the exact level.                      |
| Nested cargo (xtask, build scripts, `dx`)               | None: each cargo keeps its implicit token, so there is no deadlock | None needed.                                                     |
| make older than 4.4 in a `-sys` crate                   | Falls back to `-j1` on a fifo jobserver                            | Step 0 tests one cmake/make crate.                               |
| Memory spike                                            | OOM is still possible                                              | Agent-scope MemoryMax and systemd-oomd remain the backstop.      |
| Cargos under other uids or in nix-daemon                | Not counted                                                        | Shown through PSI and the nix-daemon cgroup in the observe data. |
| (Train) A participant dies or the executor is cancelled | Socket EOF                                                         | It is dropped, or the others re-board.                           |

## Measurement plan

Goal: show that the enforcement lowers host pressure under the real mix
without slowing any single job by more than 10%.

0. **Spikes, about 30 min, before enforcement code.**
   - Leaks under SIGINT, SIGTERM, and a rust-analyzer flycheck restart on
     save.
   - Whether `-Zthreads` and codegen threads draw from the fifo, on the pinned
     nightly.
   - How many rustc sccache runs as children of the server rather than of
     cargo.
   - One cmake/make `-sys` crate (make older than 4.4).
   - That the variable reaches rust-analyzer as launched by Claude Code and by
     OpenCode (`/proc/PID/environ`).
1. **One observe week.** CPU time by class and the train and enforcement gates
   above.
2. **Controlled A/B on Atlas.** One replay runs four jobs at once: a SynDB
   `cargo test --no-run -p etl` in worktree 1, a SynDB
   `cargo check --workspace --all-targets` in worktree 2, a canix
   `cargo check` in `cli/`, and a pink-raven `cargo build`.
   - Setup: dependencies warm, workspace crates touched, separate build dirs
     per arm. The whole run sits in one
     `systemd-run --user -p MemoryMax=40G -p MemorySwapMax=0` scope.
   - Arms:
     - A/A noise floor;
     - off;
     - static caps (option 0);
     - pool at capacity 24 and at 32;
     - sccache on and off for both off and the best arm.
   - Interleaved order, at least 5 repetitions per arm, median and range
     reported.
   - A solo arm runs the SynDB check alone with off and with the best arm.
   - Metrics:
     - wall time of each job within the mix, makespan, swap-in and minimum
       MemAvailable;
     - a latency probe: a fixed single-CPU task timed every 10 s during the
       mix;
     - OOM events.
       CPU PSI some is reported but is not an acceptance criterion. A pool
       satisfies it by construction, because the waiting moves from the run
       queue into the fifo.
   - Acceptance:
     - the latency probe improves by at least 30%;
     - swap-in and OOMs do not get worse;
     - each job in the mix and the solo job stay within +10% of off, beyond
       the A/A noise floor.
       Choose the cheapest arm that passes.

## Work breakdown, after approval

- harbor-rs:
  - `pool serve --observe` and `build_status` in the CLI, with the rmcp server;
  - the NixOS module, docs, and a test that runs a 1-token fifo against two
    cargo units and asserts the serial timing;
  - then the arm that wins the A/B: either static caps in the module, or the
    reconciling pool.
- canix: enable the module on Atlas, add the `fleetix.mcp.servers.harbor-rs`
  entry and a row in the mcp.md table.
- The train only after its gate.

## Decisions (operator, 2026-11-15)

1. **Measure before enforcing.** Static caps win if they get most of the gain.
   Measurement is a scout-level task, run by the scout route
   (`openai/gpt-6.1-terra`, low) from the scripted steps above, not by a
   reasoning model. Step 0 needs no new code. Steps 1–2 use the observe
   scanner and a replay script. A scout runs them and reports numbers; the
   enforcement decision comes back to the orchestrating thread.
2. **The train is the right reading of "build together", and canix alone
   justifies it.** The operator delegated this assessment. It rests on a
   60-second sample at 21:10Z:
   - Same-build-dir overlap is real, but it does not come from agents batching
     with each other. In `canix/cli`, two rust-analyzer flychecks with
     identical argv
     (`cargo check --workspace --all-targets --keep-going`) and two agent
     commands (`cargo test -p canix-foundation --lib nix_eval_lock` and
     `cargo build --bin canix`) had been waiting on the same
     `.cargo-build-lock` for 19–23 minutes. All four were behind one
     sccache-wrapped `canix_foundation` compile that had been asleep for
     19 minutes. pink-raven showed the same pattern with two rust-analyzers.
   - Agent commands rarely match each other. Cargo's lock and fingerprints
     already make an identical follower run nearly free, so coalescing agent
     commands saves only the reruns caused by other sessions' edits.
   - So the train is built **flycheck-first**:
     - identical flychecks in one build dir coalesce into one run;
     - an interactive request that boards a build dir cancels a flycheck run
       there, which is safe because rust-analyzer reruns on the next save;
     - agent-to-agent coalescing comes along at no extra cost.
   - This needs rust-analyzer's `check.overrideCommand` to point at
     `harbor-rs build --class flycheck --`. The SynDB thread owns that change.
     Without it the train does not pay, and it is not built.
   - Order: the observe scanner first, then the train. The train does not
     wait for the observe week, because the sample already meets its gate in
     canix. The week only sizes it.
3. **Code lives in the harbor-rs CLI.**

Separate finding, owner canix/sccache: an sccache client can sleep for
19+ minutes on a single compile while holding a build dir's lock, which stalls
every other cargo in that checkout. That is a hang, not load. A train that
cancels flychecks would have unblocked the two agent builds here, but the
underlying stall needs its own investigation.
