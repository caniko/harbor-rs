# NixOS module for sccache — the shared Rust/C/C++ compilation cache.
#
# Three modes:
#   - Local-only:     `programs.rsHarbor.sccache.enable = true`
#   - Shared (S3):    add `cacheEndpoint` + `cacheBucket`
#   - Authenticated:  add `accessKeyId` + `secretAccessKey`
#
# Exports config.programs.rsHarbor.sccache.envVars — the single source
# of truth for all sccache-related environment variables. Consumers
# (overlays, home-manager modules, etc.) read this to inject env vars
# at derivation level instead of relying on impure-env.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkMerge mkOption optionalAttrs types;
  cfg = config.programs.rsHarbor.sccache;

  # Compute envVars so the option definition and environment.variables
  # share the same logic without eval-order issues.
  computedEnvVars =
    if cfg.enable
    then
      (mkMerge [
        {
          RUSTC_WRAPPER = "${cfg.package}/bin/sccache";
          SCCACHE_CONNECT_TIMEOUT = cfg.connectTimeout;
        }
        (mkIf (cfg.cacheEndpoint != null && cfg.cacheBucket != null) {
          SCCACHE_BUCKET = cfg.cacheBucket;
          SCCACHE_ENDPOINT = cfg.cacheEndpoint;
          SCCACHE_REGION = cfg.cacheRegion;
          SCCACHE_S3_USE_SSL = if cfg.cacheUseSsl then "true" else "false";
        })
        (mkIf (cfg.cacheKeyPrefix != null) {
          SCCACHE_S3_KEY_PREFIX = cfg.cacheKeyPrefix;
        })
        (mkIf (cfg.accessKeyId != null) {
          AWS_ACCESS_KEY_ID = cfg.accessKeyId;
        })
        (mkIf (cfg.secretAccessKey != null) {
          AWS_SECRET_ACCESS_KEY = cfg.secretAccessKey;
        })
        (mkIf (cfg.sandboxCacheDir != null) {
          SCCACHE_DIR = cfg.sandboxCacheDir;
        })
        cfg.extraEnv
      ])
    else {};
in {
  options.programs.rsHarbor.sccache = {
    enable = lib.mkEnableOption "sccache shared compilation cache";

    package = lib.mkPackageOption pkgs "sccache" {};

    setGlobalWrapper = mkOption {
      type = types.bool;
      default = true;
      description = "Set RUSTC_WRAPPER=sccache globally via environment.variables.";
    };

    cacheEndpoint = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        S3-compatible endpoint URL for shared sccache storage.
        Set along with cacheBucket to enable shared-cache mode.
        Leave null for local-only sccache (disk-backed, no sharing).
      '';
      example = "http://192.168.178.88:3900";
    };

    cacheBucket = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        S3 bucket name for sccache. Ignored when cacheEndpoint is null.
      '';
      example = "sccache";
    };

    cacheRegion = mkOption {
      type = types.str;
      default = "auto";
      description = "S3 region for sccache. Use 'auto' for custom endpoints.";
    };

    cacheKeyPrefix = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional S3 key prefix for cache scoping (e.g. per-project or per-host).";
      example = "atlas";
    };

    cacheUseSsl = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to use SSL for the S3 endpoint. Set true for HTTPS endpoints.";
    };

    accessKeyId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "S3 access key ID for sccache. Sets AWS_ACCESS_KEY_ID when non-null.";
    };

    secretAccessKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "S3 secret access key for sccache. Sets AWS_SECRET_ACCESS_KEY when non-null.";
    };

    extraEnv = mkOption {
      type = types.attrsOf (types.nullOr types.str);
      default = {};
      description = "Additional environment variables to set alongside sccache vars. Merged last.";
    };

    sandboxCacheDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Writable directory to mount into the Nix sandbox for sccache's
        local disk cache. When set, creates a systemd tmpfiles rule and
        sets SCCACHE_DIR. Example: "/tmp/sccache".
      '';
      example = "/tmp/sccache";
    };

    connectTimeout = mkOption {
      type = types.str;
      default = "2";
      description = "SCCACHE_CONNECT_TIMEOUT in seconds. Controls how long sccache waits before falling back to local cache.";
    };

    # Exported computed env vars — single source of truth for
    # derivation-level injection by consumer modules.
    envVars = mkOption {
      type = types.attrsOf types.str;
      internal = true;
      readOnly = true;
      description = "Computed sccache environment variables. Read from config.programs.rsHarbor.sccache.envVars.";
    };
  };

  config = mkIf cfg.enable {
    programs.rsHarbor.sccache.envVars = computedEnvVars;

    environment.systemPackages = [cfg.package];

    environment.variables =
      if cfg.setGlobalWrapper
      then computedEnvVars
      else builtins.removeAttrs computedEnvVars ["RUSTC_WRAPPER"];

    systemd.tmpfiles.rules =
      lib.optionals (cfg.sandboxCacheDir != null) [
        "d ${cfg.sandboxCacheDir} 1777 root root -"
      ];

    nix.settings =
      lib.optionalAttrs (cfg.sandboxCacheDir != null) {
        extra-sandbox-paths = [cfg.sandboxCacheDir];
      };
  };
}