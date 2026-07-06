# mkDevShell, mkDocsShell, and mkDevShells

`mkDevShell` builds one development shell. `mkDocsShell` builds a dedicated docs/tooling shell with the same base toolchain wiring but with Windows and macOS cross environment variables disabled by default. `mkDevShells` builds the default four-shell layout used by most downstream workspaces. All generated shells include `cargo-sweep` and the shared native build tools before project-specific packages are appended.

## mkDevShell

Use `mkDevShell` when you want a single environment with precise control over Windows and macOS helpers.

Important parameters:

- `pkgs`
- `craneLib`
- `cross`
- `enableWindowsEnv`
- `enableOsxcrossEnv`
- `pkgConfigDeps`
- `packages`
- `extraEnv`
- `extraShellHook`
- `checks`
- `cargoConfig`

## mkProjectCliShellTools

Use `mkProjectCliShellTools` when a project wants its flake-built CLI available in `direnv` or `nix develop`:

```nix
projectCli = rs-harbor.lib.mkProjectCliShellTools {
  inherit pkgs;
  package = self'.packages.my-cli;
  commandName = "my-cli";
  hint = "my-cli dev shell - run `my-cli --help`";
  versionCheck.expected = version;
};
```

Append `projectCli.packages` to the shell packages and `projectCli.shellHook` to the shell hook. The hook fails if `command -v` resolves to a different binary than the package output, which prevents stale tools earlier on `PATH` from shadowing the current flake build.

## mkDevShells

`mkDevShells` wraps `mkDevShell` and returns:

- `default`
- `windows`
- `macos`
- `cross`

That layout works well for workspaces where some crates only need native tools while others need MinGW or osxcross.

## mkDocsShell

Use `mkDocsShell` for CI and local workflows that only need docs or project-site tooling:

- `nix develop .#docs -c cargo doc --no-deps --all-features`
- `nix develop .#docs -c mdbook serve docs`
- `nix develop .#docs -c plinth-project serve --config website/plinth-project.toml`

## Example

```nix
devShells =
  (rs-harbor.lib.mkDevShells {
    inherit pkgs cross cargoConfig;
    inherit (toolchain) craneLib;
    packages = with pkgs; [ just vulkan-loader ];
    pkgConfigDeps = with pkgs; [ wayland libxkbcommon udev alsa-lib ];
    extraEnv = {
      LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader ];
    };
    extraShellHook = ''
      echo "Welcome to my project!"
    '';
  };
  })
  // {
    docs = rs-harbor.lib.mkDocsShell {
      inherit pkgs cross cargoConfig;
      inherit (toolchain) craneLib;
      packages = with pkgs; [ mdbook ];
    };
  };
```

When `cargoConfig` is set, the shell will write `.cargo/config.toml` if it is missing and back up mismatched files before replacing them.
