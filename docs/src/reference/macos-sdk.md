# macOS SDK Initialization

For version-controlled project flakes, `rs-harbor` prefers a stable `macosSdkStorePath` instead of committing a host-local archive path. rs-harbor owns SDK discovery and validation; osxcross receives only the resolved SDK reference.

## Initialize once per host

```bash
nix run rs-harbor#init-macos-sdk -- /host/local/MacOSX26.1.sdk.tar.xz 26.1
```

The command realizes the archive, validates the SDK root, and prints:

- the stable store path to commit
- the resolved SDK root
- the recursive hash used for the fixed-output rebuild

Validation requires:

- `SDKSettings.json`
- `usr/include/TargetConditionals.h`
- `System/Library/Frameworks`
- `SystemConfiguration.framework`
- `CoreFoundation.framework`

## Use the printed store path

```nix
cross = rs-harbor.lib.mkCross {
  inherit pkgs system;
  macosSdkStorePath = "/nix/store/<stable-hash>-macosx-sdk-26.1";
  osxSdkVersion = "26.1";
};
```

On another machine, either run the same initialization flow with that host's local archive or fetch the realized store path from your binary cache.

## Local discovery with `MACOS_SDK`

For local impure workflows, `mkCross` can read `MACOS_SDK`. The value may be:

- a direct SDK root, such as `/path/to/MacOSX26.1.sdk`
- a parent directory containing `MacOSX26.1.sdk`
- a supported SDK archive, such as `/path/to/MacOSX26.1.sdk.tar.xz`

Explicit arguments take precedence over `MACOS_SDK`: `macosSdk`, `macosSdkStorePath`, `sdkArchive`, then the environment value.
