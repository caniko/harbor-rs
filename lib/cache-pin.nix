# nix-cache-pin metadata for plain (non-flake-parts) flakes. The upstream
# flake-parts module is evaluated directly so its option defaults and types
# stay authoritative; `perSystem` is accepted but never forced.
{
  nix-cache-pin,
  pkgs,
  consumerAttr,
  name ? "nixpkgs",
  inputName ? "nixpkgs",
  packages ? [],
  from ? {},
  targetsAttr ? "cachePinTargets",
  caches ? ["https://cache.nixos.org"],
  branch ? "nixos-unstable",
  extra ? {},
}: let
  inherit (pkgs) lib;

  # Derivations compare by outPath, so `elem`/`unique` dedupe exact outputs.
  custom = builtins.attrValues from;
  pinned = builtins.filter (drv: drv != null) (map (attr: lib.attrByPath (lib.splitString "." attr) null pkgs) packages);
  inputsOf = drv:
    builtins.filter lib.isDerivation (lib.flatten [
      (drv.buildInputs or [])
      (drv.nativeBuildInputs or [])
      (drv.propagatedBuildInputs or [])
    ]);
  derived = lib.unique (builtins.filter (drv: !(builtins.elem drv (custom ++ pinned))) (lib.concatMap inputsOf custom));

  sanitize = text: builtins.concatStringsSep "-" (builtins.filter builtins.isString (builtins.split "[^A-Za-z0-9_-]+" text));
  baseLabel = drv: sanitize (lib.getName drv + lib.optionalString ((drv.outputName or "out") != "out") "-${drv.outputName}");
  # Labels follow `from` attribute order, then input order; collisions get -2, -3, ...
  targets = builtins.foldl' (acc: drv: let
    base = baseLabel drv;
    pick = i: let
      label =
        if i == 1
        then base
        else "${base}-${toString i}";
    in
      if acc ? ${label} || builtins.elem label packages
      then pick (i + 1)
      else label;
  in
    acc // {${pick 1} = drv;}) {}
  derived;

  evaluated = lib.evalModules {
    modules = [
      (import "${nix-cache-pin}/nix/module.nix" {cachePinSelf = null;})
      {
        options.flake = lib.mkOption {type = lib.types.lazyAttrsOf lib.types.raw;};
        options.perSystem = lib.mkOption {type = lib.types.raw;};
        config.cache-pin = {
          nixpkgs = pkgs;
          pins.${name} =
            {
              inherit packages inputName caches branch;
              attrPrefix = "pkgs";
              pythonPackages = null;
              consumerFlakeRef = ".";
              consumerTargets = lib.genAttrs packages (attr: "${consumerAttr}.${attr}");
              requiredConsumerTargets = lib.mapAttrs (label: _: "${consumerAttr}.${targetsAttr}.${label}") targets;
              lockOnly = true;
              verifyClosure = true;
            }
            // extra;
        };
      }
    ];
  };
in {
  inherit (evaluated.config.flake) cachePinMeta;
  inherit targets;
}
