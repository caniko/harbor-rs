# Changelog

## [Unreleased]

### Added

- `lib.mkSccacheEnv` — generate `SCCACHE_*` environment variables for
  S3-compatible sccache backends
- `nixosModules.sccache` — NixOS module for declarative sccache setup
  (`programs.rsHarbor.sccache`)
- Simit CI/release badge markers to README
- Configured canonical domain `rs-harbor.tartanoglu.com` for Codeberg Pages
  with a pre-deploy validation step
- `mkTrunkPackage` now includes `clang` and `mold` in native build inputs for
  Linux mold linker support
- `mkToolchain` now guards Crane dependency-only builds from dummifying
  `[patch.crates-io]` path crates.
