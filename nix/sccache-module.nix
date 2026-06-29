# NixOS module for sccache — the shared Rust/C/C++ compilation cache.
#
# Three modes:
#   - Local-only:     `programs.rsHarbor.sccache.enable = true`
#   - Shared (S3):    add `cacheEndpoint` + `cacheBucket`
#   - Authenticated:  add `accessKeyId` + `secretAccessKey`
#
# Two env-var layers under three sandbox access models:
#
#   Local-only mode (sandboxCacheDir set, daemon.enable = false):
#     SCCACHE_DIR is injected via nix.settings.impure-env from the
#     world-writable sandboxCacheDir (/tmp/sccache). Every derivation
#     gets a writable disk cache path.
#
#   Daemon mode (daemon.enable = true, sandboxCacheDir MUST be null):
#     A persistent sccache daemon (systemd service, user "sccache")
#     owns all disk caching under daemon.diskCacheDir and binds a
#     Unix socket at daemon.socketPath (/run/sccache/sock by default).
#     The socket lives in a systemd RuntimeDirectory owned by user
#     sccache (mode 0755) — separate from any world-writable scratch
#     dir — so sticky-bit races on stale socket files are impossible.
#     Sandbox builds reach the socket via extra-sandbox-paths and
#     SCCACHE_SERVER_UDS in impure-env.
#
#   Local + daemon compat (sandboxCacheDir set, daemon.enable = true):
#     NOT ALLOWED — the assertion layer catches this at eval time.
#     sandboxCacheDir and daemon.enable are mutually exclusive.
#     Remove sandboxCacheDir when enabling the daemon.
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

  socketParentDir = builtins.dirOf cfg.daemon.socketPath;

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
      // (if cfg.sandboxCacheDir != null && !cfg.daemon.enable then {
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
        default = "/run/sccache/sock";
        description = ''
          Unix socket path for the daemon to listen on. Defaults under
          /run/sccache — a systemd RuntimeDirectory owned by the sccache
          user (mode 0755). Systemd creates the directory before ExecStart
          and wipes it on stop, so stale-socket races under sticky-bit
          /tmp directories are impossible. Sandbox builds reach the socket
          via extra-sandbox-paths + impure-env SCCACHE_SERVER_UDS.
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

      requiresServices = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Systemd unit names that the sccache daemon requires and must start
          after. Use when the S3 backend (Garage, MinIO, etc.) is a local
          systemd service — the daemon's startup check (.sccache_check)
          fails if the backend is not yet accepting connections.

          Example: ["garage-init-sccache.service"] for a garage-backed cache.
          The daemon's unit gets Requires= + After= for each listed name.
        '';
        example = ["garage-init-sccache.service"];
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
    assertions = [{
      assertion = !(cfg.daemon.enable && cfg.sandboxCacheDir != null);
      message = ''
        programs.rsHarbor.sccache: sandboxCacheDir (= "${cfg.sandboxCacheDir}") and
        daemon.enable are mutually exclusive.

        In daemon mode the daemon owns all disk caching at
        daemon.diskCacheDir (= "${cfg.daemon.diskCacheDir}") and its Unix
        socket lives in a dedicated RuntimeDirectory (/run/sccache) outside
        the world-writable sandbox.

        To fix: remove sandboxCacheDir from hosts that enable the daemon.
      '';
    }];

    programs.rsHarbor.sccache.envVars = computedEnvVars;

    environment.systemPackages = [cfg.package];

    environment.variables =
      if cfg.setGlobalWrapper
      then computedEnvVars
      else builtins.removeAttrs computedEnvVars ["RUSTC_WRAPPER"];

    systemd.tmpfiles.rules =
      lib.optionals (cfg.sandboxCacheDir != null && !cfg.daemon.enable) [
        "d ${cfg.sandboxCacheDir} 1777 root root -"
      ];

    # Sandbox access paths — mutually exclusive between local-only and
    # daemon mode (enforced by the assertion above):
    #   1. sandboxCacheDir — writable disk cache (local-only)
    #   2. daemon socket — dedicated RuntimeDirectory at socketParentDir
    nix.settings = mkMerge [
      (mkIf (cfg.sandboxCacheDir != null && !cfg.daemon.enable) {
        extra-sandbox-paths = [cfg.sandboxCacheDir];
        impure-env = [
          "SCCACHE_DIR=${cfg.sandboxCacheDir}"
          "XDG_CACHE_HOME=${cfg.sandboxCacheDir}"
        ];
        experimental-features = ["configurable-impure-env"];
      })
      (mkIf cfg.daemon.enable {
        extra-sandbox-paths = [socketParentDir];
        impure-env = ["SCCACHE_SERVER_UDS=${cfg.daemon.socketPath}"];
        experimental-features = ["configurable-impure-env"];
      })
    ];

    # Crossbow-package overlay — inject sccache into every Rust
    # package listed in crossbowPackages so sandbox builds route rustc
    # through the sccache wrapper.
    #
    # Each named package gets:
    #   - cfg.package (sccache binary) in nativeBuildInputs
    #   - computedEnvVars (RUSTC_WRAPPER, SCCACHE_SERVER_UDS, S3 creds ...)
    #     merged into the derivation environment
    #
    # The overlay is safe to enable whenever cfg.computedEnvVars is
    # populated.  In daemon mode (cfg.daemon.enable = true) the socket is
    # reachable from the sandbox via extra-sandbox-paths + impure-env,
    # and the daemon handles persistent disk/S3 caching — no per-build
    # SCCACHE_DIR is needed.  In local-only mode (sandboxCacheDir set)
    # the sandbox gets a writable SCCACHE_DIR via impure-env + tmpfiles,
    # so sccache's preprocessor cache has a home.
    nixpkgs.overlays = [
      (_: prev: builtins.foldl'
        (acc: name:
          if prev ? ${name}
          then acc // {
            ${name} = prev.${name}.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or []) ++ [cfg.package];
              env = (old.env or {}) // computedEnvVars;
            });
          }
          else acc)
        {}
        cfg.crossbowPackages)
    ];

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
      after = ["network.target"] ++ cfg.daemon.requiresServices;
      wants = ["network.target"];
      requires = cfg.daemon.requiresServices;
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
        Restart = "on-failure";
        RestartSec = "5";
        User = "sccache";
        Group = "sccache";
        RuntimeDirectory = "sccache";
        RuntimeDirectoryMode = "0755";
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