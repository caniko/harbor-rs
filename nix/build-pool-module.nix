{defaultPackage}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.harborRs.buildPool;
in {
  options.programs.harborRs.buildPool = {
    enable = lib.mkEnableOption "observe-only host build pool";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage pkgs.stdenv.hostPlatform.system;
      defaultText = lib.literalExpression "harbor-rs.packages.<system>.harbor-rs";
      description = "Package providing the harbor-rs executable.";
    };
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Seconds between observations.";
    };
  };
  config = lib.mkIf cfg.enable {
    systemd.user.services.harbor-build-pool = {
      description = "Observe shared Rust build activity";
      wantedBy = ["default.target"];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} pool serve --observe --interval ${toString cfg.interval}";
        Restart = "always";
        Nice = 10;
        CPUWeight = 20;
        MemoryMax = "256M";
      };
    };
  };
}
