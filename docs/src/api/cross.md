# mkCross

`mkCross` assembles the cross-compilation helpers for Windows and macOS.

## Windows support

MinGW toolchain components are exposed through the returned environment and can be enabled in dev shells without extra project-specific setup.

## macOS support

osxcross is optional and turns on when one of these inputs is available:

- `macosSdk`: an already realized SDK reference
- `macosSdkStorePath`: explicit SDK store path, normally injected by host configuration
- `sdkArchive`: a local SDK archive path
- `macosSdkEnvPath`: explicit local discovery path
- `MACOS_SDK`: opt-in local discovery fallback when `enableImpureMacosSdkEnv = true`

Only one of `macosSdkStorePath`, `sdkArchive`, or `macosSdk` can be provided at a time.
Resolution precedence is `macosSdk`, then `macosSdkStorePath`, then `sdkArchive`, then `macosSdkEnvPath`.

`macosSdkEnvPath` and the opt-in `MACOS_SDK` fallback accept a direct `MacOSX<version>.sdk` directory, a parent directory containing that SDK, or a supported SDK archive. Directory inputs are validated for the SDK settings file, `TargetConditionals.h`, and the required CoreFoundation/SystemConfiguration frameworks before osxcross is invoked.

## Example

```nix
cross = rs-harbor.lib.mkCross {
  inherit pkgs system;
};
```

See [macOS SDK Initialization](../reference/macos-sdk.md) for the recommended way to create and inject `macosSdkStorePath` from host configuration.
