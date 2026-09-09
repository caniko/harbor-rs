{
  pkgs,
  treefmt-nix,
  rustModule,
  baseModules,
  rustToolchain,
}: let
  standalone = (treefmt-nix.lib.evalModule pkgs {imports = [rustModule];}).config;
  composed =
    (treefmt-nix.lib.evalModule pkgs {
      imports = baseModules ++ [rustModule];
      projectRootFile = "flake.nix";
      programs.rustfmt.package = rustToolchain;
      programs.rustfmt.edition = "2024";
    }).config;
in
  assert builtins.attrNames standalone.settings.formatter == ["rustfmt"];
  assert composed.programs.rustfmt.package == rustToolchain;
  assert composed.programs.rustfmt.edition == "2024";
  assert builtins.attrNames composed.settings.formatter == ["alejandra" "rustfmt" "taplo"];
    pkgs.runCommand "harbor-rs-treefmt-modules" {} "touch $out"
