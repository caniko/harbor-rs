# NixOS module for periodic `cargo-cache --autoclean` of one user's Cargo home.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.harborRs.cargoHousekeeping;
in {
  options.services.harborRs.cargoHousekeeping = {
    enable = lib.mkEnableOption "periodic Cargo cache housekeeping";

    user = lib.mkOption {
      type = lib.types.str;
      description = "User whose Cargo home is cleaned.";
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = config.users.users.${cfg.user}.home;
      defaultText = lib.literalExpression "config.users.users.\${user}.home";
      description = "Home directory of the housekeeping user.";
    };

    cargoHome = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.home}/.cargo";
      defaultText = lib.literalExpression ''"''${home}/.cargo"'';
      description = "Cargo home cleaned by `cargo-cache --autoclean`.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "systemd `OnCalendar` expression for the housekeeping timer.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.harbor-rs-cargo-housekeeping = {
      description = "Cargo cache housekeeping";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        WorkingDirectory = cfg.home;
        Environment = [
          "HOME=${cfg.home}"
          "CARGO_HOME=${cfg.cargoHome}"
        ];
        ExecStart = "${lib.getExe pkgs.cargo-cache} --autoclean";
      };
    };

    systemd.timers.harbor-rs-cargo-housekeeping = {
      description = "Cargo cache housekeeping";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  };
}
