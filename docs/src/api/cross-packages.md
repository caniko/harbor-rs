# mkCrossPackages

`mkCrossPackages` builds a single Rust workspace for several targets at once,
lifting the per-target crane boilerplate (separate `cargoArtifacts`, the right
`CARGO_BUILD_TARGET`, and the matching cross env) out of consumer flakes. It is
the reusable form of the hand-rolled cross matrix that projects such as
`rs-modde` previously kept inline.

## Signature

```nix
rs-harbor.lib.mkCrossPackages {
  pkgs;            # native build-system pkgs with rust-overlay applied
  craneLib;        # native craneLib from rs-harbor.lib.mkToolchain
  cross;           # result of rs-harbor.lib.mkCross
  pname;           # base package name, e.g. "modde"
  commonArgs;      # base crane args shared across targets; MUST include `src`
  targets ? [ "native" ];   # subset of the supported target names
  targetArgs ? {};          # optional per-target extra crane args
}
```

It returns an attrset of derivations keyed by **output attribute name**:

| target name      | output attr name        | builder                                                      |
| ---------------- | ----------------------- | ------------------------------------------------------------ |
| `native`         | `${pname}`              | native `craneLib.buildPackage`                               |
| `aarch64-linux`  | `${pname}-aarch64-linux`| craneLib built from `pkgsCross.aarch64-multiplatform`        |
| `windows`        | `${pname}-windows`      | native craneLib + `cross.windowsEnv` + MinGW                 |
| `darwin-x86_64`  | `${pname}-darwin-x86_64`| `cross.osxcrossRustHelpers.mkCrossBuilder`                   |
| `darwin-aarch64` | `${pname}-darwin-aarch64`| `cross.osxcrossRustHelpers.mkCrossBuilder`                  |

Only the requested targets' attrs are returned.

## Merge order

For each target, args are merged as:

1. `commonArgs` (must include `src`)
2. the target's `pname` and cross env (`CARGO_BUILD_TARGET`, linker/CC vars,
   `PKG_CONFIG_ALLOW_CROSS`, …)
3. `targetArgs.<target>` **last**, so consumers can inject project dependencies
   (`buildInputs`, `nativeBuildInputs`, `postInstall`, `cargoBuildExtraArgs`,
   `doCheck`, …) and override anything above.

## Darwin fallback

The `darwin-x86_64` and `darwin-aarch64` targets require osxcross with a realized
macOS SDK. When `cross.osxcrossRustHelpers == null` (no SDK configured), those
outputs fall back to a `runCommand` that exits 1 at build time with a clear
message, so the attribute still evaluates and the flake stays usable on hosts
without an SDK.

## Example

```nix
let
  toolchain = rs-harbor.lib.mkToolchain { inherit pkgs; };
  cross = rs-harbor.lib.mkCross { inherit pkgs system; };

  commonArgs = {
    inherit src;
    version = "1.0.0";
    strictDeps = true;
  };

  crossPkgs = rs-harbor.lib.mkCrossPackages {
    inherit pkgs cross commonArgs;
    inherit (toolchain) craneLib;
    pname = "my-app";
    targets = [ "native" "aarch64-linux" "windows" "darwin-aarch64" ];
    targetArgs = {
      native.buildInputs = [ pkgs.openssl ];
      aarch64-linux.buildInputs = [ cross.linuxAarch64.pkgsCross.openssl ];
      windows.buildInputs = with pkgs.pkgsCross.mingwW64; [ openssl windows.pthreads ];
    };
  };
in {
  packages = crossPkgs // { default = crossPkgs."my-app"; };
}
```

See [mkCross](./cross.md) for the cross toolchain inputs (`windowsEnv`,
`linuxAarch64`, `osxcrossRustHelpers`) that this helper consumes.
