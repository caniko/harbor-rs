{
  harbor,
  pkgs,
  toolchain,
  cross,
  cargoConfig,
  plinthProject,
}: let
  docsPackages = with pkgs; [
    mdbook
    plinthProject
  ];
  docsShellHook = ''
    echo "Project site: plinth-project serve --config website/plinth-project.toml --out website/.plinth-project/public"
    echo "Documentation: mdbook serve docs"
  '';
in
  (harbor.mkDevShells {
    inherit pkgs cross cargoConfig;
    inherit (toolchain) craneLib;
    packages = docsPackages;
    extraShellHook = docsShellHook;
  })
  // {
    docs = harbor.mkDocsShell {
      inherit pkgs cross cargoConfig;
      inherit (toolchain) craneLib;
      packages = docsPackages;
      extraShellHook = docsShellHook;
    };
  }
