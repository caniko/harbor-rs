# Installation

Use `harbor-rs` as a flake input and follow its pinned shared dependencies from your project.

## Requirements

- Nix with flakes enabled
- `rust-overlay` applied to the `pkgs` you pass into `mkToolchain`
- A macOS SDK only if you want Darwin cross-compilation through osxcross

## Add the flake input

```nix
{
  inputs = {
    harbor-rs.url = "git+https://github.com/caniko/harbor-rs.git";

    nixpkgs.follows = "harbor-rs/nixpkgs";
    rust-overlay.follows = "harbor-rs/rust-overlay";
    crane.follows = "harbor-rs/crane";
    flake-utils.follows = "harbor-rs/flake-utils";
  };
}
```

Ready-made starting points:

```bash
nix flake init -t git+https://github.com/caniko/harbor-rs.git
nix flake init -t git+https://github.com/caniko/harbor-rs.git#bevy
```

For a working configuration after the input is added, continue to [Quick Start](./quick-start.md).
