{
  # Dev-only inputs for the `dev` flake-parts partition (see dev-partition.nix),
  # locked in nix/flake.lock so consumers never lock them. It lives under nix/
  # because that directory already exists in the crane source filters; a new
  # top-level directory would change every package source hash.
  description = "harbor-rs development inputs (formatter, hooks, dev shell, checks)";

  inputs = {
    # Tooling-only nixpkgs: distinct from `nixpkgs` so the partition keeps the
    # parent's (or a superproject's) nixpkgs for checks and dev shells.
    nixpkgs-dev.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs-dev";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs-dev";
    };
    nix-opencode-lsp = {
      url = "git+https://github.com/caniko/nix-opencode-lsp.git?ref=trunk";
      inputs.nixpkgs.follows = "nixpkgs-dev";
    };
    # Only the mkCachePin check reads it; consumers pass their own source.
    nix-cache-pin = {
      url = "github:caniko/nix-cache-pin/0.3.0";
      flake = false;
    };
  };

  outputs = _: {};
}
