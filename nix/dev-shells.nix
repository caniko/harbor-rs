{
  harbor,
  opencodeLsp,
  pkgs,
  toolchain,
  cross,
  cargoConfig,
  plinthProject,
  rsHarborCli,
}: let
  docsPackages = with pkgs; [
    mdbook
    plinthProject
  ];
  rsHarborShellTools = harbor.mkProjectCliShellTools {
    inherit pkgs;
    package = rsHarborCli;
    commandName = "rs-harbor";
    hint = "rs-harbor dev shell - run `rs-harbor --help`";
  };
  docsShellHook = ''
    echo "Project site: plinth-project serve --config website/plinth-project.toml --out website/.plinth-project/public"
    echo "Documentation: mdbook serve docs"
  '';
in
  (harbor.mkDevShells {
    inherit pkgs cross cargoConfig;
    inherit (toolchain) craneLib;
    packages = docsPackages ++ rsHarborShellTools.packages;
    extraShellHook = docsShellHook + rsHarborShellTools.shellHook;
  })
  // {
    docs = harbor.mkDocsShell {
      inherit pkgs cross cargoConfig;
      inherit (toolchain) craneLib;
      packages = docsPackages;
      extraShellHook = docsShellHook;
    };
    opencode-lsp = opencodeLsp.mkShell {
      inherit pkgs;
      rustAnalyzer = toolchain.rustToolchain;
    };
  }
