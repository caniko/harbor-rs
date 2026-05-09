{
  harbor,
  pkgs,
  toolchain,
  cross,
  cargoConfig,
}:
harbor.mkDevShells {
  inherit pkgs cross cargoConfig;
  inherit (toolchain) craneLib;
  packages = with pkgs; [
    zola
    mdbook
  ];
  extraShellHook = ''
    echo "Website: cd website && zola serve"
    echo "Documentation: cd docs && mdbook serve"
  '';
}
