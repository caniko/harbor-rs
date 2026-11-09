{pkgs}:
# ponytail: Nixpkgs' cargoSetupHook forces system libraries (44cddf9), but
# dioxus-cli 0.7.10 declares only openssl of the libgit2, libssh2, zlib and
# zstd its -sys crates now require, so it fails to build (uncached upstream).
# Drop once Nixpkgs declares them.
pkgs.dioxus-cli.overrideAttrs (old: {
  buildInputs = (old.buildInputs or []) ++ [pkgs.libgit2 pkgs.libssh2 pkgs.zlib pkgs.zstd];
})
