{ config, lib, pkgs, osConfig ? null, ... }:

let
  sccacheDefault = import ../lib/generated/sccache-default.nix;
  sccacheService = import ../lib/sccache-service.nix {inherit pkgs;};
  inherit (lib) mkIf mkOption types;

  osSccache = lib.attrByPath [ "programs" "rsHarbor" "sccache" ] { } osConfig;
  osSccacheEnabled = osConfig != null && (osSccache.enable or false);
  osSccacheRemoteEnv = osSccache.remoteEnvVars or { };

  cfg = config.programs.rsHarbor.sccache.userDaemon;
  reservedUserEnvironment = [
    "RUSTC_WRAPPER"
    "SCCACHE_SERVER_UDS"
    "SCCACHE_DIR"
    "XDG_CACHE_HOME"
    "SCCACHE_START_SERVER"
    "SCCACHE_NO_DAEMON"
  ];

  serviceEnv =
    osSccacheRemoteEnv
    // cfg.environment
    // {
      SCCACHE_SERVER_UDS = "%t/${sccacheDefault.userSocketRel}";
      SCCACHE_DIR = "${config.xdg.cacheHome}/${sccacheDefault.userCacheRel}";
      SCCACHE_IDLE_TIMEOUT = toString cfg.idleTimeout;
      SCCACHE_START_SERVER = "1";
      SCCACHE_NO_DAEMON = "1";
      SCCACHE_LOG = "warn";
    };

  serviceEnvironment = lib.mapAttrsToList (name: value: "${name}=${value}") serviceEnv;

  wrapper = pkgs.writeShellScriptBin "sccache-rustc-wrapper" ''
    set -eu

    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
    export XDG_RUNTIME_DIR="$runtime_dir"
    if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus"
    fi
    socket_path="$runtime_dir/${sccacheDefault.userSocketRel}"
    cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/${sccacheDefault.userCacheRel}"

    service_ready() {
      ${pkgs.systemd}/bin/systemctl --user is-active --quiet sccache-user-daemon.service \
        && [ -S "$socket_path" ]
    }

    if ! service_ready; then
      if ! ${pkgs.coreutils}/bin/timeout ${toString (sccacheDefault.startupTimeout + 5)}s \
        ${pkgs.systemd}/bin/systemctl --user start sccache-user-daemon.service; then
        echo "sccache-rustc-wrapper: managed sccache service could not start; build refused" >&2
        ${pkgs.systemd}/bin/systemctl --user status sccache-user-daemon.service --no-pager -l >&2 || true
        exit 75
      fi
    fi

    if ! service_ready; then
      echo "sccache-rustc-wrapper: managed sccache socket is not ready; build refused" >&2
      ${pkgs.systemd}/bin/journalctl --user-unit=sccache-user-daemon.service --no-pager -n 80 >&2 || true
      exit 75
    fi

    export SCCACHE_SERVER_UDS="$socket_path"
    export SCCACHE_DIR="$cache_dir"
    exec ${cfg.package}/bin/sccache "$@"
  '';

  uid = osConfig.users.users.${config.home.username}.uid;
in {
  options.programs.rsHarbor.sccache.userDaemon = {
    enable = mkOption {
      type = types.bool;
      default = osSccacheEnabled;
      defaultText = lib.literalExpression
        "osConfig.programs.rsHarbor.sccache.enable";
      description = ''
        Enable a user-owned interactive sccache daemon and rustc wrapper.
        Nix sandbox builds continue to use the system rs-harbor daemon.
      '';
    };

    package = lib.mkPackageOption pkgs "sccache" { };

    idleTimeout = mkOption {
      type = types.int;
      default = sccacheDefault.idleTimeout;
      description = "Seconds before the user sccache daemon shuts down when idle. 0 = never.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = ''
        Explicit interactive-daemon environment additions. Sandbox-only
        transport variables are never inherited implicitly.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = osSccacheEnabled;
        message = ''
          programs.rsHarbor.sccache.userDaemon.enable requires integrated
          NixOS Home Manager with osConfig.programs.rsHarbor.sccache.enable = true.
        '';
      }
      {
        assertion = osSccacheRemoteEnv ? SCCACHE_BUCKET && osSccacheRemoteEnv ? SCCACHE_ENDPOINT;
        message = ''
          programs.rsHarbor.sccache.userDaemon.enable requires an S3-backed
          rs-harbor sccache configuration; refusing to silently fall back to
          local-only interactive caching.
        '';
      }
      {
        assertion = builtins.all (name: !(builtins.hasAttr name cfg.environment)) reservedUserEnvironment;
        message = ''
          programs.rsHarbor.sccache.userDaemon.environment contains a
          reserved lifecycle variable. Configure cache transport through the
          rs-harbor sccache module instead.
        '';
      }
    ];

    home.packages = [
      cfg.package
      wrapper
    ];

    home.sessionVariables = {
      RUSTC_WRAPPER = "${wrapper}/bin/sccache-rustc-wrapper";
      SCCACHE_SERVER_UDS = "/run/user/${toString uid}/${sccacheDefault.userSocketRel}";
    };

    programs.nushell.environmentVariables = {
      RUSTC_WRAPPER = "${wrapper}/bin/sccache-rustc-wrapper";
      SCCACHE_SERVER_UDS = "/run/user/${toString uid}/${sccacheDefault.userSocketRel}";
    };

    systemd.user.services.sccache-user-daemon = {
      Unit = {
        Description = "User sccache compilation cache daemon";
        StartLimitIntervalSec = "${toString sccacheDefault.restartWindow}s";
        StartLimitBurst = sccacheDefault.restartBurst;
      };
      Service = {
        Type = "exec";
        Restart = "on-failure";
        RestartSec = "${toString sccacheDefault.restartDelay}s";
        TimeoutStartSec = "${toString sccacheDefault.startupTimeout}s";
        TimeoutStopSec = "10s";
        Environment = serviceEnvironment;
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p %t/${builtins.dirOf sccacheDefault.userSocketRel} ${config.xdg.cacheHome}/${sccacheDefault.userCacheRel}"
          "${sccacheService.repairSocket} %t/${sccacheDefault.userSocketRel}"
        ];
        ExecStart = "${cfg.package}/bin/sccache";
        ExecStartPost = "${sccacheService.waitForSocket} %t/${sccacheDefault.userSocketRel} ${toString sccacheDefault.startupTimeout}";
        ExecStop = "${pkgs.coreutils}/bin/env -u SCCACHE_START_SERVER ${cfg.package}/bin/sccache --stop-server";
        KillMode = "control-group";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
