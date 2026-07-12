{ config, lib, pkgs, osConfig ? null, ... }:

let
  sccacheDefault = import ../lib/generated/sccache-default.nix;
  inherit (lib) mkIf mkOption types;

  osSccache = lib.attrByPath [ "programs" "rsHarbor" "sccache" ] { } osConfig;
  osSccacheEnabled = osConfig != null && (osSccache.enable or false);
  osSccacheEnv = osSccache.envVars or { };

  cfg = config.programs.rsHarbor.sccache.userDaemon;

  serviceEnv =
    builtins.removeAttrs osSccacheEnv [
      "RUSTC_WRAPPER"
      "SCCACHE_SERVER_UDS"
      "SCCACHE_DIR"
      "XDG_CACHE_HOME"
    ]
    // {
      SCCACHE_SERVER_UDS = "%t/${sccacheDefault.userSocketRel}";
      SCCACHE_DIR = "${config.xdg.cacheHome}/${sccacheDefault.userCacheRel}";
      SCCACHE_IDLE_TIMEOUT = toString cfg.idleTimeout;
    };

  serviceEnvironment = lib.mapAttrsToList (name: value: "${name}=${value}") serviceEnv;

  wrapper = pkgs.writeShellScriptBin "sccache-rustc-wrapper" ''
    set -eu

    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(${pkgs.coreutils}/bin/id -u)}"
    socket_path="$runtime_dir/${sccacheDefault.userSocketRel}"
    cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/${sccacheDefault.userCacheRel}"

    if [ ! -S "$socket_path" ]; then
      ${pkgs.systemd}/bin/systemctl --user start sccache-user-daemon.service
    fi

    if [ ! -S "$socket_path" ]; then
      echo "sccache-rustc-wrapper: $socket_path was not created by sccache-user-daemon.service" >&2
      exit 1
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
        assertion = osSccacheEnv ? SCCACHE_BUCKET && osSccacheEnv ? SCCACHE_ENDPOINT;
        message = ''
          programs.rsHarbor.sccache.userDaemon.enable requires an S3-backed
          rs-harbor sccache configuration; refusing to silently fall back to
          local-only interactive caching.
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
      Unit.Description = "User sccache compilation cache daemon";
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5";
        Environment = serviceEnvironment;
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p %t/${builtins.dirOf sccacheDefault.userSocketRel} ${config.xdg.cacheHome}/${sccacheDefault.userCacheRel}"
          "-${pkgs.coreutils}/bin/rm -f %t/${sccacheDefault.userSocketRel}"
        ];
        ExecStart = "${cfg.package}/bin/sccache --start-server";
        ExecStop = "${cfg.package}/bin/sccache --stop-server";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
