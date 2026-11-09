{pkgs}:
# Dioxus' workspace wrapper captures linker and asset arguments, but older
# releases invoke rustc directly.  Keep the capture layer and delegate the
# compiler invocation to harbor-rs's sccache wrapper when requested.
(import ./dioxus-cli-base.nix {inherit pkgs;}).overrideAttrs (old: {
  patches = (old.patches or []) ++ [./../patches/dioxus-cli-inner-wrapper.patch];
})
