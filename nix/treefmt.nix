{
  harbor-rs,
  rustfmtPackage,
}: {...}: {
  imports = [
    harbor-rs.inputs.harbor-meta.treefmtModules.nix
    harbor-rs.inputs.harbor-meta.treefmtModules.toml
    harbor-rs.treefmtModules.rust
  ];
  projectRootFile = "flake.nix";
  programs.rustfmt.package = rustfmtPackage;
  # Templates and byte-sensitive test data retain their source policy, as in
  # harbor's root formatter.
  settings.excludes = ["**/templates/**" "**/tests/fixtures/**" "**/checks/fixtures/**"];
}
