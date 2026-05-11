/*
Pure consumer-shape NixOS module for rs-harbor macOS SDK
cross-compilation.

Producer workflow (operator-driven, not declarative):
  nix run rs-harbor#publish-macos-sdk -- \
    --archive /path/to/MacOSX.sdk.tar.xz \
    --version 26.1 \
    --attic-server https://attic.candee.baby \
    --cache harbor-macos-sdk \
    --token-file /run/agenix/attic-harbor-macos-sdk-token

Commit the printed storePath into this module on every host
that wants the realized SDK; consumers substitute from the
configured Attic cache.
*/
{
  config,
  lib,
  ...
}: let
  cfg = config.programs.rsHarbor.macosSdk;
in {
  options.programs.rsHarbor.macosSdk = {
    enable = lib.mkEnableOption "rs-harbor macOS SDK realization for osxcross cross-compilation";

    sdkVersion = lib.mkOption {
      type = lib.types.str;
      default = "26.1";
      description = "macOS SDK version used when pinning the realized SDK store path.";
    };

    storePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Realized macOS SDK store path injected into rs-harbor project wrappers
        via `mkCrossArgs`. Produce it with `nix run rs-harbor#publish-macos-sdk
        -- ...` from any host, then commit the printed store path into the
        consuming NixOS configuration.
      '';
    };

    mkCrossArgs = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default =
        {osxSdkVersion = cfg.sdkVersion;}
        // lib.optionalAttrs (cfg.storePath != null) {
          macosSdkStorePath = cfg.storePath;
        };
      defaultText = lib.literalExpression ''
        {
          osxSdkVersion = config.programs.rsHarbor.macosSdk.sdkVersion;
        } // optional macosSdkStorePath
      '';
      description = "Arguments to merge into rs-harbor.lib.mkCross from project wrappers.";
    };
  };
}
