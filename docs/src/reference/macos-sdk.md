# macOS SDK Initialization

For version-controlled project flakes, `rs-harbor` prefers a stable `macosSdkStorePath` instead of committing a host-local archive path.

## Initialize once per host

```bash
nix run rs-harbor#init-macos-sdk -- /host/local/MacOSX26.1.sdk.tar.xz 26.1
```

The command prints:

- the stable store path to commit
- the resolved SDK root
- the recursive hash used for the fixed-output rebuild

## Use the printed store path

```nix
cross = rs-harbor.lib.mkCross {
  inherit pkgs system;
  macosSdkStorePath = "/nix/store/<stable-hash>-macosx-sdk-26.1";
  osxSdkVersion = "26.1";
};
```

On another machine, either run the same initialization flow with that host's local archive or fetch the realized store path from your binary cache.
