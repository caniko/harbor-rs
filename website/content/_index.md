+++
title = "rs-harbor"

[extra]
tagline = "Rust cross-compilation infrastructure for Nix flakes"
subtitle = "Reusable toolchains, shell environments, packaging helpers, and cache integrations for projects that ship beyond the host they build on."
install = '''
{
  inputs.rs-harbor.url = "git+ssh://git@codeberg.org/caniko/rs-harbor.git";

  inputs.nixpkgs.follows = "rs-harbor/nixpkgs";
  inputs.rust-overlay.follows = "rs-harbor/rust-overlay";
  inputs.crane.follows = "rs-harbor/crane";
  inputs.flake-utils.follows = "rs-harbor/flake-utils";
}
'''
quick_start = '''
toolchain = rs-harbor.lib.mkToolchain { inherit pkgs; };
cross = rs-harbor.lib.mkCross { inherit pkgs system; };
cargoConfig = rs-harbor.lib.mkCargoConfig { inherit pkgs; };

devShells = rs-harbor.lib.mkDevShells {
  inherit pkgs cross cargoConfig;
  inherit (toolchain) craneLib;
};
'''

[[extra.features]]
title = "Composable Toolchains"
body = "Create nightly or stable Rust toolchains with crane already wired into the result."

[[extra.features]]
title = "Cross Targets Without Drift"
body = "Keep Windows and macOS cross-compilation in one reusable flake library instead of per-project shell glue."

[[extra.features]]
title = "Generated Cargo Config"
body = "Emit linker and compiler settings once, then let the dev shell write a consistent .cargo/config.toml."

[[extra.features]]
title = "Shells for Real Work"
body = "Expose native, Windows, macOS, and combined cross shells from one shared configuration."

[[extra.features]]
title = "Packaging Hooks"
body = "Wrap Linux outputs as AppImages or generate Flatpak manifests without forking your build graph."

[[extra.features]]
title = "Cache Adapters"
body = "Bridge infrastructure flakes and project flakes with typed Attic configuration and push apps."
+++

`rs-harbor` keeps Rust and Nix cross-compilation infrastructure in one place so application flakes can stay focused on their own packages, checks, and release targets. Read the docs for the full API surface, the Bevy template, and the recommended macOS SDK initialization flow.
