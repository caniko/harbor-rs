# macOS SDK Initialization

For version-controlled project flakes, `rs-harbor` supports an explicit `macosSdkStorePath`, but that path is host-specific. Reusable flakes should accept it from host configuration instead of committing it directly. rs-harbor owns SDK discovery and validation; osxcross receives only the resolved SDK reference.

## Initialize once per host

```bash
nix run rs-harbor#init-macos-sdk -- /host/local/MacOSX26.1.sdk.tar.xz 26.1
```

The command realizes the archive, validates the SDK root, and prints:

- the host-specific store path for host configuration
- the resolved SDK root
- the recursive hash used for the fixed-output rebuild

Validation requires:

- `SDKSettings.json`
- `usr/include/TargetConditionals.h`
- `System/Library/Frameworks`
- `SystemConfiguration.framework`
- `CoreFoundation.framework`

## Inject the printed store path

```nix
canix.development.macosSdk.storePath = "/nix/store/<host-sdk>-macosx-sdk-26.1";
canix.development.macosSdk.sdkVersion = "26.1";
```

Host wrappers can then pass the value to `mkCross` as `macosSdkStorePath`. Standalone project flakes should keep it `null` so native and non-macOS cross outputs evaluate everywhere. On another machine, either run the same initialization flow with that host's local archive or fetch the realized store path from your binary cache.

## Local discovery with `MACOS_SDK`

For local impure workflows, `mkCross` can read `MACOS_SDK` when `enableImpureMacosSdkEnv = true`. The value may be:

- a direct SDK root, such as `/path/to/MacOSX26.1.sdk`
- a parent directory containing `MacOSX26.1.sdk`
- a supported SDK archive, such as `/path/to/MacOSX26.1.sdk.tar.xz`

Explicit arguments take precedence over `MACOS_SDK`: `macosSdk`, `macosSdkStorePath`, `sdkArchive`, then the environment value.
