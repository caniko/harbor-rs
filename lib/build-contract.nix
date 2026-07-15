let
  toolchain = builtins.fromTOML (builtins.readFile ../rust-toolchain.toml);
in {
  inherit toolchain;

  mkBuildContract = {
    pkgs,
    namespaceScope ? "rs-harbor-rust",
    namespaceGeneration ? 1,
  }:
    {
      schemaVersion = 1;
      rustToolchain = toolchain.toolchain;
      sccache = {
        version = pkgs.sccache.version;
        inherit namespaceScope namespaceGeneration;
      };
    };
}
