# mkDevShell and mkDevShells

`mkDevShell` builds one development shell. `mkDevShells` builds the default four-shell layout used by most downstream workspaces.

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

## mkDevShells

`mkDevShells` wraps `mkDevShell` and returns:

- `default`
- `windows`
- `macos`
- `cross`

That layout works well for workspaces where some crates only need native tools while others need MinGW or osxcross.

## Example

```nix
devShells = rs-harbor.lib.mkDevShells {
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
```

When `cargoConfig` is set, the shell will write `.cargo/config.toml` if it is missing and back up mismatched files before replacing them.
