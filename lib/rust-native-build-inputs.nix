# mkRustNativeBuildInputs :: { pkgs, extra ? [], includeClang ? true, includeMold ? true } -> [package]
#
# Native tooling expected by Rust package derivations. Dev shells already expose
# these tools through mkDevShell; package derivations should carry them too so
# build-script consumers and external drv reproducers can find `cc`/`gcc`.
{
  pkgs,
  extra ? [],
  includeClang ? true,
  includeMold ? true,
}: let
  lib = pkgs.lib;
  # Top-level attributes are not spliced: in a cross package set `pkgs.clang`
  # and `pkgs.mold` are builds for the target host, which a cross derivation
  # would compile and cannot run. buildPackages is the same set natively.
  tools = pkgs.buildPackages;
in
  [
    pkgs.stdenv.cc
  ]
  ++ lib.optionals includeClang [
    tools.clang
  ]
  ++ lib.optionals includeMold [
    tools.mold
  ]
  ++ extra
