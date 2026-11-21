{
  harbor-rs,
  rustfmtPackage,
}: {...}: {
  imports = [
    harbor-rs.inputs.harbor-meta.treefmtModules.nix
    harbor-rs.inputs.harbor-meta.treefmtModules.toml
    harbor-rs.inputs.harbor-meta.treefmtModules.markdown
    harbor-rs.inputs.harbor-meta.treefmtModules.shell
    harbor-rs.inputs.harbor-meta.treefmtModules.svg
    harbor-rs.treefmtModules.rust
  ];
  projectRootFile = "flake.nix";
  programs.rustfmt.package = rustfmtPackage;
  # Templates and byte-sensitive test data retain their source policy, as in
  # harbor's root formatter.
  settings.excludes = ["templates/**" "tests/fixtures/**" "checks/fixtures/**" "**/templates/**" "**/tests/fixtures/**" "**/checks/fixtures/**"];
}
