# Changelog

## [Unreleased]

### Added

- `mkPkgConfigEnv` and `mkDioxusPackage` helpers, with shape checks and
  packaging documentation.
- `mkToolchain` now handles unavailable source paths safely while inspecting
  Cargo path patches.
- `lib.mkSccacheEnv` — generate `SCCACHE_*` environment variables for
  S3-compatible sccache backends
- `nixosModules.sccache` — NixOS module for declarative sccache setup
  (`programs.harborRs.sccache`)
- Simit CI/release badge markers to README
- Configured canonical domain `harbor-rs.tartanoglu.com` for Codeberg Pages
  with a pre-deploy validation step
- `mkTrunkPackage` now includes `clang` and `mold` in native build inputs for
  Linux mold linker support
- `mkToolchain` now guards Crane dependency-only builds from dummifying
  `[patch.crates-io]` path crates.
- Development shells now inherit the matching Cargo configuration from
  `mkToolchain` unless the caller supplies an override.
- Added the configurable `harbor-ci` command for fast, default, and full Cargo
  validation pipelines, optional keep-going diagnostics, and JSON reports.
- Flake packages and development shells now expose `harbor-ci` for local and
  generated CI checks.

### Changed

- Cranelift code generation is now opt-in because its unsupported LLVM `\x01`
  no-mangle marker can break C and C++ FFI linkage.
- `mkToolchain` maps legacy crane `stdenv` arguments onto `stdenvSelector`
  so per-derivation stdenv overrides no longer warn.
- Android APK helpers now live in
  [harbor-android](https://github.com/caniko/harbor-android) and are
  re-exported from `harbor-rs.lib` for one migration release.
- `mkToolchain` compiler caching is now opt-in because the sandbox wrapper
  requires host-managed cache transport.
- Sandbox startup is idempotent, and wrapped Rust/CMake derivations no longer
  place the raw `sccache` package on `PATH`.
- Generated Crow checks now invoke `harbor-ci default` instead of duplicating
  Cargo command steps.
