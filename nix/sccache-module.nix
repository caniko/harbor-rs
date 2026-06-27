# NixOS module for sccache — the shared Rust/C/C++ compilation cache.
#
# Three modes:
#   - Local-only:     `programs.rsHarbor.sccache.enable = true`
#   - Shared (S3):    add `cacheEndpoint` + `cacheBucket`
#   - Authenticated:  add `accessKeyId` + `secretAccessKey`
#
# Two-layer env-var strategy:
#
#   Layer 1 — impure-env (nix daemon → all sandbox builds):
#     SCCACHE_DIR is injected via nix.settings.impure-env whenever
#     sandboxCacheDir is configured. This is safe because SCCACHE_DIR
#     is a local filesystem path, not a secret. It ensures every
#     derivation built on the host — even those from third-party
#     flakes that hardcode RUSTC_WRAPPER=sccache — can write to the
#     sccache disk cache under a writable /tmp directory.
#
#   Layer 2 — derivation-level injection (opt-in, for S3 creds):
#     config.programs.rsHarbor.sccache.envVars exports RUSTC_WRAPPER,
#     S3 endpoint/bucket, and AWS credentials. Consumers read this
#     via builtins.tryEval and apply overrideAttrs to their crane
#     builds. S3 credentials NEVER pass through impure-env.
#
#   Layer 3 — interactive/logind session (convenience):
#     environment.variables mirrors envVars so RUSTC_WRAPPER is
#     active in shells and systemd user services.
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
      { RUSTC_WRAPPER = "${cfg.package}/bin/sccache";
        SCCACHE_CONNECT_TIMEOUT = cfg.connectTimeout;
      }
      // (if cfg.cacheEndpoint != null && cfg.cacheBucket != null then {
        SCCACHE_BUCKET = cfg.cacheBucket;
        SCCACHE_ENDPOINT = cfg.cacheEndpoint;
        SCCACHE_REGION = cfg.cacheRegion;
        SCCACHE_S3_USE_SSL = if cfg.cacheUseSsl then "true" else "false";
      } else {})
      // (if cfg.cacheKeyPrefix != null then {
        SCCACHE_S3_KEY_PREFIX = cfg.cacheKeyPrefix;
      } else {})
      // (if cfg.accessKeyId != null then {
        AWS_ACCESS_KEY_ID = cfg.accessKeyId;
      } else {})
      // (if cfg.secretAccessKey != null then {
        AWS_SECRET_ACCESS_KEY = cfg.secretAccessKey;
      } else {})
      // (if cfg.sandboxCacheDir != null then {
        SCCACHE_DIR = cfg.sandboxCacheDir;
        XDG_CACHE_HOME = cfg.sandboxCacheDir;
      } else {})
      // (if cfg.daemon.enable then {
        SCCACHE_SERVER_UDS = cfg.daemon.socketPath;
      } else {})
      // cfg.extraEnv
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

    # List of package attribute names to automatically inject sccache
    # env vars into via nixpkgs overlays. Each listed package gets
    # RUSTC_WRAPPER, S3 credentials, and sccache added to
    # nativeBuildInputs — no manual overrideAttrs needed.
    # Useful in crossbow extraModules to wire S3 caching into
    # cross-compiled or native Rust packages.
    crossbowPackages = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Package attribute names to inject sccache env vars into via
        nixpkgs overlays. Each package gets sccache added to
        nativeBuildInputs and the full computedEnvVars merged into
        its derivation environment.
      '';
      example = ["identity-cli" "kanidmWithSecretProvisioning_1_10"];
    };

    connectTimeout = mkOption {
      type = types.str;
      default = "2";
      description = "SCCACHE_CONNECT_TIMEOUT in seconds. Controls how long sccache waits before falling back to local cache.";
    };

    daemon = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run a persistent sccache daemon as a systemd service bound to a
          Unix socket. Sandbox builds reach it via extra-sandbox-paths +
          impure-env instead of attempting per-build daemon spawns that
          fail under network-namespace isolation.
        '';
      };

      socketPath = mkOption {
        type = types.path;
        default = "/tmp/sccache/sock";
        description = ''
          Unix socket path for the daemon to listen on. Defaults inside
          sandboxCacheDir (/tmp/sccache) which is already bind-mounted into
          every Nix sandbox, so sandbox builds connect without needing a
          separate extra-sandbox-paths entry.
        '';
      };

      diskCacheDir = mkOption {
        type = types.path;
        default = "/var/lib/sccache";
        description = "Persistent disk cache directory for the daemon.";
      };

      idleTimeout = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Seconds before the daemon shuts down when idle. 0 = never.
          The daemon starts at boot and stays up for the session.
        '';
      };
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

    # Merge sandbox access paths from two sources:
    #   1. sandboxCacheDir — writable disk cache (also hosts the daemon socket)
    #   2. daemon.socketPath — impure-env points builds at the host daemon
    nix.settings = mkMerge [
      (mkIf (cfg.sandboxCacheDir != null) {
        extra-sandbox-paths = [cfg.sandboxCacheDir];
        impure-env = [
          "SCCACHE_DIR=${cfg.sandboxCacheDir}"
          "XDG_CACHE_HOME=${cfg.sandboxCacheDir}"
        ];
      })
      (mkIf cfg.daemon.enable {
        impure-env = ["SCCACHE_SERVER_UDS=${cfg.daemon.socketPath}"];
        experimental-features = ["configurable-impure-env"];
      })
    ];

    # Auto-generate nixpkgs overlay for crossbow packages: inject sccache
    # env vars and add sccache to nativeBuildInputs without manual
    # overrideAttrs per package.
    nixpkgs.overlays = mkIf (cfg.crossbowPackages != []) [(final: prev: let
      scc = computedEnvVars;
      overrideOne = name:
        if prev ? ${name}
        then {
          ${name} = prev.${name}.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [final.sccache];
            env = (old.env or {}) // scc;
          });
        }
        else {};
    in
      builtins.foldl' (acc: name: acc // overrideOne name) {} cfg.crossbowPackages
    )];

    # Persistent host-side daemon for sandbox builds — binds a Unix socket
    # that sandbox builds connect to via the impure-env SCCACHE_SERVER_UDS
    # and the extra-sandbox-paths bind mount above.
    users.groups.sccache = mkIf cfg.daemon.enable {};
    users.users.sccache = mkIf cfg.daemon.enable {
      isSystemUser = true;
      group = "sccache";
      description = "sccache daemon user";
    };

    systemd.services.sccache-daemon = mkIf cfg.daemon.enable {
      description = "sccache compilation cache daemon (Unix socket)";
      after = ["network.target"];
      wants = ["network.target"];
      wantedBy = ["multi-user.target"];

      environment = let
        daemonEnv = builtins.removeAttrs computedEnvVars ["RUSTC_WRAPPER"];
      in daemonEnv // {
        SCCACHE_SERVER_UDS = cfg.daemon.socketPath;
        SCCACHE_DIR = cfg.daemon.diskCacheDir;
        SCCACHE_IDLE_TIMEOUT = toString cfg.daemon.idleTimeout;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "sccache";
        Group = "sccache";
        StateDirectory = "sccache";
        StateDirectoryMode = "0700";
        ReadWritePaths = [
          cfg.daemon.diskCacheDir
        ];
        ExecStartPre = "-${pkgs.coreutils}/bin/rm -f ${cfg.daemon.socketPath}";
        ExecStart = "${cfg.package}/bin/sccache --start-server";
        ExecStartPost = "${pkgs.coreutils}/bin/chmod 0666 ${cfg.daemon.socketPath}";
        ExecStop = "${cfg.package}/bin/sccache --stop-server";
        ProtectSystem = "full";
        ProtectHome = true;
      };
    };
  };
}