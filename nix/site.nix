{
  pkgs,
  lib,
  projectSiteLib,
}: let
  docs = pkgs.stdenv.mkDerivation {
    pname = "harbor-rs-docs";
    version = "0.1.0";
    src = ../docs;
    nativeBuildInputs = [pkgs.mdbook];
    phases = ["buildPhase" "installPhase"];
    buildPhase = ''
      cp -r --no-preserve=mode $src docs
      chmod -R u+w docs
      mdbook build docs
    '';
    installPhase = ''
      mkdir -p $out
      cp -r docs/book/. $out/
    '';
  };

  website = projectSiteLib.mkProjectSite {
    pname = "harbor-rs-website";
    domain = "harbor-rs.tartanoglu.com";
    configPath = ../website/plinth-project.toml;
    docsPackage = docs;
    staticPaths = [
      {
        source = ../website/static/harbor-rs-mark.svg;
        target = "website/static/harbor-rs-mark.svg";
      }
    ];
  };
in {
  inherit website docs;

  site = website;
}
