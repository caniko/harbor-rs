{
  pkgs,
  mkCachePin,
  nix-cache-pin,
}: let
  inherit (pkgs) lib;
  consumerAttr = "legacyPackages.${pkgs.stdenv.hostPlatform.system}";
  custom = pkgs.stdenv.mkDerivation {
    name = "cache-pin-custom";
    buildInputs = [pkgs.zlib pkgs.zlib.dev null pkgs.hello];
    nativeBuildInputs = [pkgs.cmake];
  };
  dependent = pkgs.stdenv.mkDerivation {
    name = "cache-pin-dependent";
    buildInputs = [custom pkgs.zlib];
  };
  result = mkCachePin {
    inherit nix-cache-pin pkgs consumerAttr;
    packages = ["hello" "python3Packages.six"];
    from = {inherit custom dependent;};
  };
  pin = result.cachePinMeta.pins.nixpkgs;
  required = builtins.attrNames pin.requiredConsumerTargets;
  # Feed the published pin back through upstream validation, which upstream only
  # forces from its per-system apps; stub everything but the validation path.
  validation = lib.evalModules {
    modules = [
      (import "${nix-cache-pin}/nix/module.nix" {cachePinSelf.packages.stub.all-binaries = "";})
      {
        options.flake = lib.mkOption {type = lib.types.lazyAttrsOf lib.types.raw;};
        options.perSystem = lib.mkOption {type = lib.types.raw;};
        config.cache-pin = {
          nixpkgs = pkgs;
          inherit (result.cachePinMeta) pins;
        };
      }
    ];
  };
  validatedApp =
    (validation.config.perSystem {
      system = "stub";
      pkgs = {
        nix = "";
        git = "";
        gh = "";
        writeText = _: text: text;
        writeShellScriptBin = _: text: text;
      };
    }).content.apps.cache-pin.program;
in
  assert result.cachePinMeta.schemaVersion == 4;
  assert pin.hydraUrl == "https://hydra.nixos.org";
  assert pin.caches == ["https://cache.nixos.org"];
  assert pin.consumerFlakeRef == "." && pin.lockOnly && pin.verifyClosure && pin.pythonPackages == null;
  assert pin.consumerTargets
  == {
    hello = "${consumerAttr}.hello";
    "python3Packages.six" = "${consumerAttr}.python3Packages.six";
  };
  # stdenv selects zlib.dev for both inputs; `custom` and `hello` are excluded.
  assert required == ["cmake" "zlib-dev"];
  assert pin.requiredConsumerTargets.zlib-dev == "${consumerAttr}.cachePinTargets.zlib-dev";
  assert result.targets.zlib-dev == pkgs.zlib.dev;
  assert builtins.isString validatedApp;
    pkgs.runCommand "check-mk-cache-pin" {} "touch $out"
