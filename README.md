# rs-harbor

Reusable Rust cross-compilation and toolchain infrastructure for Nix flakes.

Provides composable functions:

- **`mkToolchain`** — Rust nightly/stable toolchain with crane and cross-compilation targets
- **`mkCross`** — MinGW (Windows) and osxcross (macOS) cross-compilation toolchains
- **`mkDevShell`** — Single devShell with configurable cross-compilation env vars
- **`mkDevShells`** — Multiple devShells (default, windows, macos, cross) from one config
- **`mkGpuRenderPin`** — DevShell-ready GPU/driver pinning for visual snapshot test baselines
- **`mkAppImage`** — Bundle a built executable as a self-contained AppImage (opt-in, Linux only)
- **`mkFlatpakManifest`** — Generate a Flatpak manifest for packaging with flatpak-builder (opt-in, Linux only)

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- The `pkgs` passed to `mkToolchain` must have [rust-overlay](https://github.com/oxalica/rust-overlay) applied
- macOS cross-compilation via osxcross accepts an explicit SDK store path produced by `init-macos-sdk`; `MACOS_SDK` discovery is opt-in for local, impure workflows
- Development shells include common native build tools plus `cargo-sweep` for pruning stale Cargo build artifacts

## One-Time macOS SDK Init

Do not commit a host-local SDK archive path to project flakes. Each host should initialize the SDK once from wherever that host stores the archive:

```bash
nix run rs-harbor#init-macos-sdk -- /host/local/MacOSX26.1.sdk.tar.xz 26.1
```

The command realizes the archive, validates that it contains a complete Apple SDK, and then prints the host-specific SDK store path for host configuration:

```nix
canix.development.macosSdk.storePath = "/nix/store/<host-sdk>-macosx-sdk-26.1";
canix.development.macosSdk.sdkVersion = "26.1";
```

Reusable project flakes should accept this value from a host wrapper instead of committing it. On another host, either run the same init command with that host's local archive path or copy the printed store path from a binary cache:

```bash
nix copy --from <cache> /nix/store/<stable-hash>-macosx-sdk-26.1
```

## Usage

```nix
{
  inputs = {
    rs-harbor.url = "git+ssh://git@codeberg.org/caniko/rs-harbor.git";

    # Pin shared inputs
    nixpkgs.follows = "rs-harbor/nixpkgs";
    rust-overlay.follows = "rs-harbor/rust-overlay";
    crane.follows = "rs-harbor/crane";
    flake-utils.follows = "rs-harbor/flake-utils";
  };

  outputs = { self, nixpkgs, rs-harbor, flake-utils, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };

      toolchain = rs-harbor.lib.mkToolchain { inherit pkgs; };
      cross = rs-harbor.lib.mkCross {
        inherit pkgs system;
      };
    in {
      # Returns: { default, windows, macos, cross }
      # Use: nix develop          (native)
      #      nix develop .#cross   (all cross targets)
      #      nix develop .#windows (windows only)
      #      nix develop .#macos   (macos only)
      devShells = rs-harbor.lib.mkDevShells {
        inherit pkgs cross;
        inherit (toolchain) craneLib;

        # Your project-specific packages
        packages = with pkgs; [ just vulkan-loader ];

        # Native libraries that expose .pc files for build scripts
        pkgConfigDeps = with pkgs; [ wayland libxkbcommon udev alsa-lib ];

        # Extra environment variables
        extraEnv = {
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader ];
        };

        # Extra shell hook
        extraShellHook = ''
          echo "Welcome to my project!"
        '';
      };
    });
}
```

## API

### `mkToolchain`

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs with rust-overlay applied |
| `channel` | `"nightly"` | `"nightly"` or `"stable"` |
| `date` | `"latest"` | Pin to a date, e.g. `"2025-12-01"` |
| `extensions` | `["rust-src" "rustfmt" "rustc-codegen-cranelift-preview"]` | Rustup components |
| `crossTargets` | linux + windows + macOS | Rust target triples |

Returns: `{ rustToolchain, craneLib, crossTargets }`

### `mkCross`

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs |
| `system` | required | Host system string |
| `macosSdkStorePath` | `null` | Explicit SDK store path from `init-macos-sdk`; host-specific values should be injected by host configuration |
| `sdkArchive` | `null` | Lower-level local/archive input; useful for experiments but host-specific if committed directly |
| `macosSdk` | `null` | Existing pure macOS SDK ref from `osxcross.lib.<system>.mkMacosSdk` or `mkMacosSdkRef`; cannot be combined with `macosSdkStorePath` or `sdkArchive` |
| `macosSdkOutputHash` | `null` | Optional fixed-output hash passed to `mkMacosSdk` when using `sdkArchive` |
| `enableImpureMacosSdkEnv` | `false` | Opt into reading `MACOS_SDK` during evaluation |
| `macosSdkEnvPath` | `""` or `builtins.getEnv "MACOS_SDK"` when `enableImpureMacosSdkEnv = true` | Local SDK path fallback. Accepts a direct `.sdk` directory, a parent containing `MacOSX<version>.sdk`, or a supported SDK archive |
| `enableOsxcross` | `macosSdkStorePath != null || sdkArchive != null || macosSdk != null || macosSdkEnvPath != ""` | Enable macOS cross-compilation when a pure SDK input or local env SDK is available |
| `osxSdkVersion` | `"26.1"` | macOS SDK version |

Returns: `{ mingwCC, mingwBinutils, winpthreads, windowsEnv, macosSdk, osxcrossToolchain, osxcrossRustHelpers }`

If you already have a realized SDK store output, pass its ref instead of an archive:

```nix
cross = rs-harbor.lib.mkCross {
  inherit pkgs system macosSdk;
};
```

Resolution precedence is `macosSdk`, then `macosSdkStorePath`, then `sdkArchive`, then `macosSdkEnvPath`. `MACOS_SDK` is read only when `enableImpureMacosSdkEnv = true`. Directory SDK inputs are checked for `SDKSettings.json`, `usr/include/TargetConditionals.h`, `System/Library/Frameworks`, `SystemConfiguration.framework`, and `CoreFoundation.framework` before rs-harbor passes them to osxcross.

### `mkDevShell`

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs |
| `craneLib` | required | From `mkToolchain` |
| `cross` | required | From `mkCross` |
| `enableWindowsEnv` | `true` | Include Windows cross-compilation env vars |
| `enableOsxcrossEnv` | `true` | Include osxcross toolchain and shell hook |
| `pkgConfigDeps` | `[]` | Packages whose `dev/lib/pkgconfig` entries should populate `PKG_CONFIG_PATH` |
| `packages` | `[]` | Extra packages; `cargo-sweep` and native build tools are included automatically |
| `extraEnv` | `{}` | Extra environment variables |
| `extraShellHook` | `""` | Additional shell hook |
| `checks` | `{}` | Flake checks |

Returns: a devShell derivation

### `mkDevShells`

Builds four devShells from a single config — ideal for workspaces where not all crates cross-compile.

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs |
| `craneLib` | required | From `mkToolchain` |
| `cross` | required | From `mkCross` |
| `enableOsxcrossEnv` | `true` | Enable osxcross in the macos/cross shells |
| `pkgConfigDeps` | `[]` | Packages whose `dev/lib/pkgconfig` entries should populate `PKG_CONFIG_PATH` |
| `packages` | `[]` | Extra packages; `cargo-sweep` and native build tools are included automatically |
| `extraEnv` | `{}` | Extra environment variables |
| `extraShellHook` | `""` | Additional shell hook |
| `checks` | `{}` | Flake checks |

Returns: `{ default, windows, macos, cross }` — assign directly to `devShells` in your flake output.

| Shell | `nix develop .#<name>` | Windows env | osxcross |
|-------|------------------------|-------------|----------|
| `default` | `nix develop` | no | no |
| `windows` | `nix develop .#windows` | yes | no |
| `macos` | `nix develop .#macos` | no | yes |
| `cross` | `nix develop .#cross` | yes | yes |

### `mkGpuRenderPin`

Returns a named GPU render profile as `{ env, packages }` so downstream
devShells can export the renderer identity expected by visual snapshot tests.

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs package set |
| `profile` | `"mesa-radv"` | Named render profile |
| `expected` | `{}` | Extra or overriding expected identity env vars |

The initial `mesa-radv` profile exports Vulkan/RADV expectations and pins
`VK_DRIVER_FILES` to the Mesa RADV ICD from `pkgs.mesa`.

### `mkAppImage`

Wraps a Nix-built executable as a self-contained [AppImage](https://appimage.org/). **Opt-in:** you must add [nix-appimage](https://github.com/ralismark/nix-appimage) to your own flake inputs and pass it as an argument.

| Param | Default | Description |
|-------|---------|-------------|
| `nix-appimage` | required | The nix-appimage flake input |
| `system` | required | Host system string (must be Linux) |
| `program` | required | Absolute store path to executable, e.g. `"${pkg}/bin/my-app"` |
| `pname` | derived from program | AppImage filename stem |
| `squashfsArgs` | `[]` | Extra arguments to `mksquashfs` |

Returns: a derivation producing a `.AppImage` file

```nix
# In your flake inputs:
nix-appimage.url = "github:ralismark/nix-appimage";

# In your outputs:
packages.appimage = rs-harbor.lib.mkAppImage {
  inherit system nix-appimage;
  program = "${myPackage}/bin/my-app";
};
```

### `mkFlatpakManifest`

Generates a [Flatpak](https://flatpak.org/) manifest (JSON) for packaging a pre-built binary with `flatpak-builder`. **Opt-in:** no extra inputs required, but only useful on Linux.

| Param | Default | Description |
|-------|---------|-------------|
| `pkgs` | required | nixpkgs |
| `appId` | required | Reverse-DNS app ID, e.g. `"com.example.MyApp"` |
| `pname` | required | Binary name |
| `desktopFile` | required | Desktop entry file content (string) |
| `icon` | `null` | Path to icon file |
| `runtime` | `"org.freedesktop.Platform"` | Flatpak runtime |
| `runtimeVersion` | `"24.08"` | Runtime version |
| `sdk` | `"org.freedesktop.Sdk"` | Flatpak SDK |
| `sdkExtensions` | `[]` | SDK extensions |
| `finishArgs` | `["--share=ipc" "--socket=x11" ...]` | Sandbox permissions |
| `extraModules` | `[]` | Additional Flatpak modules |

Returns: `{ manifestText, manifestPath }`

```nix
packages.flatpak-manifest = (rs-harbor.lib.mkFlatpakManifest {
  inherit pkgs;
  appId = "com.example.MyApp";
  pname = "my-app";
  desktopFile = ''
    [Desktop Entry]
    Type=Application
    Name=My App
    Exec=my-app
  '';
}).manifestPath;
# Then: nix build .#flatpak-manifest && flatpak-builder --user --install build-dir ./result
```

## `rs-harbor` CLI

Build helpers with non-trivial logic live in a Rust binary, `rs-harbor`,
exposed as a flake package. clap handles argument parsing; goblin parses
ELF/PE/Mach-O for the audit subcommands; lipo orchestration and dSYM
bundle assembly are direct `std::fs` / `std::process::Command` calls.
20 unit + integration tests run under `cargo test` (and `nix flake check`).

```text
rs-harbor
├── audit elf   <PATH>   --allow-needed-regex / --forbid-path-regex / --require-origin-rpath / --skip-ldd
├── audit pe    <PATH>   --allow-dll-regex / --forbid-path-regex
├── audit macho <PATH>   --allow-dylib-regex / --forbid-path-regex
├── stage macos          --binary / --dylib / --archs / --skip-per-arch / --skip-universal
└── steam-runtime exec   --runtime / --image / --container-runtime / --interactive / --mount-nix-store
```

Run any subcommand directly:

```bash
nix run rs-harbor -- stage macos --binary myapp --dylib libsteam_api.dylib
nix run rs-harbor -- audit elf --skip-ldd dist/linux/myapp
```

The Nix-side helpers (`mkSteamRuntimeTools`, `mkMacosUniversalStager`)
all require an `rsHarborCli` argument so they can emit thin
`writeShellApplication` shims that wrap the matching CLI subcommand
with the project's selected runtime / image / defaults baked in:

```nix
let
  rsHarborCli = rs-harbor.packages.${system}.rs-harbor;
in {
  inherit (rs-harbor.lib.mkSteamRuntimeTools {
    inherit pkgs rsHarborCli;
  })
    auditElfRuntimeDeps
    auditWindowsRuntimeDeps
    auditDarwinRuntimeDeps
    steamRuntimeExec
    steamRuntimeCargoBootstrap
    ;
}
```

## What's included in the devShell

**Packages:** cmake, gcc, clang, mold, lld, pkg-config, mingw binutils (if Windows enabled), osxcross (if macOS enabled)

**Environment:** `LIBCLANG_PATH`, optional `PKG_CONFIG_PATH` from `pkgConfigDeps`, Windows cross-compilation (`CC_x86_64_pc_windows_gnu`, linker, rustflags)

Windows GNU targets intentionally use the MinGW GCC wrapper as the linker driver without forcing
`-fuse-ld=lld`. For this toolchain, routing through lld can inject unsupported PIE arguments and
break final linking.

## Testing

```bash
nix flake check   # Run all checks (attribute shapes, validation logic)
```

## CI

Woodpecker CI on Codeberg runs `nix flake check` on every push and pull request to verify attribute shapes and validation logic.
