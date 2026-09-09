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
    pkgs.runCommand "harbor-rs-treefmt-modules" {
      nativeBuildInputs = [composed.build.wrapper];
    } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        cp ${pkgs.writeText "unformatted.nix" "{ x=1; }\n"} flake.nix
        cp ${pkgs.writeText "unformatted.rs" "fn main(){let x=1;println!(\"{}\",x);}\n"} main.rs
        chmod u+w flake.nix main.rs
        treefmt --tree-root . flake.nix main.rs
        ! cmp -s ${pkgs.writeText "unformatted.rs" "fn main(){let x=1;println!(\"{}\",x);}\n"} main.rs
      treefmt --tree-root . --clear-cache --fail-on-change flake.nix main.rs
        touch "$out"
    ''
