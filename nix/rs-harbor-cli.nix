{
  pkgs,
  craneLib,
  src ? ../.,
}: let
  rsHarborSrc = pkgs.lib.cleanSourceWith {
    inherit src;
    filter = path: type:
      (craneLib.filterCargoSources path type)
      || (builtins.match ".*/tests/fixtures/.*" path != null);
    name = "rs-harbor-source";
  };
in
  craneLib.buildPackage {
    pname = "rs-harbor";
    version = "0.1.0";
    src = rsHarborSrc;
    strictDeps = true;
    doCheck = true;
    nativeBuildInputs = [
      pkgs.clang
      pkgs.mold
    ];
    nativeCheckInputs = [
      pkgs.git
    ];
  }
