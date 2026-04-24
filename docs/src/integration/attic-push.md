# mkAtticPush

`mkAtticPush` creates a Nix app that logs into Attic and pushes one or more store paths, optionally including their closures.

## Example

```nix
apps.push-cache = rs-harbor.lib.mkAtticPush {
  inherit pkgs;
  adapter = infra.harborAdapter;
  paths = [ self.packages.${system}.default ];
};
```

Run it with:

```bash
nix run .#push-cache
```

The generated script expects the token environment variable described by the adapter, defaulting to `ATTIC_TOKEN`.
