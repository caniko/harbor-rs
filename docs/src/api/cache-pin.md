# mkCachePin

`mkCachePin` declares a [nix-cache-pin](https://github.com/caniko/nix-cache-pin) pin from a plain flake without flake-parts. It evaluates the upstream module, so option defaults and types come from the pinned nix-cache-pin source, and returns `{ cachePinMeta, targets }`.

Packages used as-is become `packages` with consumer targets under `consumerAttr`. Each `from` derivation contributes its `buildInputs`, `nativeBuildInputs` and `propagatedBuildInputs` as required consumer targets, excluding the `from` derivations and listed packages themselves. Expose `targets` at `consumerAttr.targetsAttr` so the updater can evaluate them at candidate revisions.

```nix
cachePin = harbor-rs.lib.mkCachePin {
  inherit (inputs) nix-cache-pin; # flake = false is enough
  inherit pkgs;
  consumerAttr = "legacyPackages.${system}";
  packages = ["freecad"];
  from = {inherit paraview;};
};
# outputs
cachePinMeta = cachePin.cachePinMeta;
legacyPackages.${system} = pkgs // {cachePinTargets = cachePin.targets;};
```

Defaults: pin and input `nixpkgs`, branch `nixos-unstable`, caches `["https://cache.nixos.org"]`, `consumerFlakeRef = "."`, `lockOnly` and `verifyClosure` enabled, `pythonPackages = null`. `extra` passes or overrides any other pin option.

`cachePinMeta` stays validation-free as upstream documents; package attributes are validated by the updater or by upstream validation.
