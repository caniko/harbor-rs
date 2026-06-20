# NixOS module for sccache — the shared Rust/C/C++ compilation cache.
#
# Two modes:
#   - Local-only:     `programs.rsHarbor.sccache.enable = true`
#   - Shared (S3):    add `cacheEndpoint` + `cacheBucket`
#
# Credential management (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) is
# deliberately left to the consumer module — see the canix bridge
# (root/modules/development/sccache.nix) for the LAN-wired example.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.rsHarbor.sccache;
in {
  options.programs.rsHarbor.sccache = {
    enable = lib.mkEnableOption "sccache shared compilation cache";

    package = lib.mkPackageOption pkgs "sccache" {};

    setGlobalWrapper = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Set RUSTC_WRAPPER=sccache globally via environment.variables.";
    };

    cacheEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        S3-compatible endpoint URL for shared sccache storage.
        Set along with cacheBucket to enable shared-cache mode.
        Leave null for local-only sccache (disk-backed, no sharing).
      '';
      example = "http://192.168.178.88:3900";
    };

    cacheBucket = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        S3 bucket name for sccache. Ignored when cacheEndpoint is null.
      '';
      example = "sccache";
    };

    cacheRegion = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "S3 region for sccache. Use 'auto' for custom endpoints.";
    };

    cacheKeyPrefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional S3 key prefix for cache scoping (e.g. per-project or per-host).";
      example = "atlas";
    };

    cacheUseSsl = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to use SSL for the S3 endpoint. Set true for HTTPS endpoints.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    environment.variables =
      lib.optionalAttrs cfg.setGlobalWrapper {
        RUSTC_WRAPPER = "${cfg.package}/bin/sccache";
      }
      // lib.optionalAttrs (cfg.cacheEndpoint != null && cfg.cacheBucket != null) {
        SCCACHE_BUCKET = cfg.cacheBucket;
        SCCACHE_ENDPOINT = cfg.cacheEndpoint;
        SCCACHE_REGION = cfg.cacheRegion;
        SCCACHE_S3_USE_SSL = if cfg.cacheUseSsl then "true" else "false";
      }
      // lib.optionalAttrs (cfg.cacheKeyPrefix != null) {
        SCCACHE_S3_KEY_PREFIX = cfg.cacheKeyPrefix;
      };
  };
}
