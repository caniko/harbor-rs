# mkCross

`mkCross` assembles the cross-compilation helpers for Windows and macOS.

## Windows support

MinGW toolchain components are exposed through the returned environment and can be enabled in dev shells without extra project-specific setup.

## macOS support

osxcross is optional and turns on when one of these inputs is available:

- `macosSdk`: an already realized SDK reference
- `macosSdkStorePath`: preferred for version-controlled flakes
- `sdkArchive`: a local SDK archive path
- `MACOS_SDK`: local discovery fallback owned by rs-harbor

Only one of `macosSdkStorePath`, `sdkArchive`, or `macosSdk` can be provided at a time.
Resolution precedence is `macosSdk`, then `macosSdkStorePath`, then `sdkArchive`, then `MACOS_SDK`.

`MACOS_SDK` accepts a direct `MacOSX<version>.sdk` directory, a parent directory containing that SDK, or a supported SDK archive. Directory inputs are validated for the SDK settings file, `TargetConditionals.h`, and the required CoreFoundation/SystemConfiguration frameworks before osxcross is invoked.

## Example

```nix
cross = rs-harbor.lib.mkCross {
  inherit pkgs system;
  macosSdkStorePath = "/nix/store/<stable-hash>-macosx-sdk-26.1";
  osxSdkVersion = "26.1";
};
```

See [macOS SDK Initialization](../reference/macos-sdk.md) for the recommended way to create `macosSdkStorePath`.
