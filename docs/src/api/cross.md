# mkCross

`mkCross` assembles the cross-compilation helpers for Windows and macOS.

## Windows support

MinGW toolchain components are exposed through the returned environment and can be enabled in dev shells without extra project-specific setup.

## macOS support

osxcross is optional and turns on when one of these inputs is available:

- `macosSdkStorePath`: preferred for version-controlled flakes
- `sdkArchive`: a local SDK archive path
- `macosSdk`: an already realized SDK reference
- `MACOS_SDK`: legacy environment-variable fallback

Only one of `macosSdkStorePath`, `sdkArchive`, or `macosSdk` can be provided at a time.

## Example

```nix
cross = rs-harbor.lib.mkCross {
  inherit pkgs system;
  macosSdkStorePath = "/nix/store/<stable-hash>-macosx-sdk-26.1";
  osxSdkVersion = "26.1";
};
```

See [macOS SDK Initialization](../reference/macos-sdk.md) for the recommended way to create `macosSdkStorePath`.
