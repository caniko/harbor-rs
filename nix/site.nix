{ pkgs }:
let
  website = pkgs.stdenv.mkDerivation {
    pname = "rs-harbor-website";
    version = "0.1.0";
    src = ../website;
    nativeBuildInputs = [pkgs.zola];
    phases = ["buildPhase" "installPhase"];
    buildPhase = ''
      cp -r --no-preserve=mode $src site
      chmod -R u+w site
      cd site && zola build
    '';
    installPhase = ''
      mkdir -p $out
      cp -r public/. $out/
    '';
  };

  docs = pkgs.stdenv.mkDerivation {
    pname = "rs-harbor-docs";
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
in {
  inherit website docs;

  site = pkgs.runCommand "rs-harbor-site" {} ''
    mkdir -p $out $out/docs
    cp -r ${website}/. $out/
    cp -r ${docs}/. $out/docs/
  '';
}
