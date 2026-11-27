{mkAndroidSdk}: {
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.harborRs.androidWorker;
  account = types.strMatching "[a-zA-Z_][a-zA-Z0-9_-]*";
  name = types.strMatching "[a-zA-Z0-9_-]+";
  unit = types.strMatching "[a-zA-Z0-9_.-]+\\.service";
  directory = types.strMatching "(/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*)+";
  adbEndpoint = "tcp:${cfg.adbHost}:${toString cfg.adbPort}";
  unitName = lib.removeSuffix ".service";
  slotUnits = map (slot: slot.systemdUnit) cfg.slots;
  slotPorts = lib.concatMap (slot: [slot.emulatorPort (slot.emulatorPort + 1)]) cfg.slots;
  slotOption = types.submodule ({config, ...}: {
    options = {
      name = mkOption {
        type = name;
        description = "Slot name, used as a directory under stateDir.";
      };
      systemdUnit = mkOption {
        type = unit;
        default = "harbor-android-${config.name}.service";
        defaultText = lib.literalExpression ''"harbor-android-''${name}.service"'';
        description = "Systemd service name, including the .service suffix.";
      };
      emulatorPort = mkOption {
        type = types.ints.between 5554 5682;
        description = "Even emulator console port. The adjacent port is reserved for emulator ADB.";
      };
      avdName = mkOption {
        type = name;
        default = config.name;
        defaultText = lib.literalExpression "name";
        description = "Name of the Android virtual device.";
      };
      apiLevel = mkOption {
        type = types.ints.positive;
        default = 35;
        description = "Android API level of the system image.";
      };
      imageType = mkOption {
        type = name;
        default = "default";
        description = "Android SDK system image type.";
      };
      abi = mkOption {
        type = name;
        default = "x86_64";
        description = "Android SDK system image ABI.";
      };
      device = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional avdmanager hardware profile name or ID.";
      };
      ramMb = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Guest memory in MiB, or null to use the emulator default.";
      };
      cores = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Guest CPU core count, or null to use the emulator default.";
      };
      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra arguments passed to the emulator. Do not override the managed AVD or ports.";
      };
    };
  });
  sdkRoot = "${cfg.androidSdk}/libexec/android-sdk";
  serviceDefaults = {
    Type = "simple";
    User = cfg.user;
    Group = cfg.group;
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ReadWritePaths = [cfg.stateDir];
    RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
  };
  avdTemplate = slot:
    pkgs.runCommand "${slot.avdName}-template" {
      nativeBuildInputs = [cfg.androidSdk pkgs.jdk21_headless];
    } ''
      export HOME="$TMPDIR/home"
      export ANDROID_HOME=${sdkRoot}
      export ANDROID_SDK_ROOT=${sdkRoot}
      export ANDROID_AVD_HOME="$out"
      mkdir -p "$HOME" "$ANDROID_AVD_HOME"
      printf 'no\n' | ${lib.escapeShellArgs ([
          "avdmanager"
          "create"
          "avd"
          "--force"
          "--name"
          slot.avdName
          "--package"
          "system-images;android-${toString slot.apiLevel};${slot.imageType};${slot.abi}"
        ]
        ++ lib.optionals (slot.device != null) ["--device" slot.device])}
    '';
  slotService = slot: let
    state = "${cfg.stateDir}/${slot.name}";
  in {
    description = "Android API ${toString slot.apiLevel} emulator slot ${slot.name}";
    requires = [cfg.adbSystemdUnit];
    after = [cfg.adbSystemdUnit];
    unitConfig.RequiresMountsFor = cfg.stateDir;
    serviceConfig =
      serviceDefaults
      // {
        ExecStartPre = [
          "${pkgs.coreutils}/bin/rm -rf ${state}"
          "${pkgs.coreutils}/bin/mkdir -p ${state}"
          "${pkgs.coreutils}/bin/cp -r --no-preserve=mode,ownership,timestamps ${avdTemplate slot}/. ${state}/"
          "${pkgs.coreutils}/bin/chmod -R u+rwX ${state}"
          "${pkgs.gnused}/bin/sed -i s|^path=.*|path=${state}/${slot.avdName}.avd| ${state}/${slot.avdName}.ini"
        ];
        ExecStart = utils.escapeSystemdExecArgs ([
            "${sdkRoot}/emulator/emulator"
            "-avd"
            slot.avdName
            "-port"
            slot.emulatorPort
            "-no-window"
            "-no-audio"
            "-no-boot-anim"
            "-no-snapshot"
            "-wipe-data"
            "-gpu"
            "swiftshader_indirect"
          ]
          ++ lib.optionals (slot.ramMb != null) ["-memory" slot.ramMb]
          ++ lib.optionals (slot.cores != null) ["-cores" slot.cores]
          ++ slot.extraArgs);
        Environment = [
          "HOME=${cfg.stateDir}/home"
          "ANDROID_HOME=${sdkRoot}"
          "ANDROID_SDK_ROOT=${sdkRoot}"
          "ANDROID_AVD_HOME=${state}"
          "ADB_SERVER_SOCKET=${adbEndpoint}"
        ];
        RuntimeMaxSec = "3h";
        TimeoutStopSec = "30s";
        KillMode = "control-group";
        Restart = "no";
        DevicePolicy = "closed";
        DeviceAllow = ["/dev/kvm rw"];
      };
  };
in {
  options.programs.harborRs.androidWorker = {
    enable = lib.mkEnableOption "on-demand headless Android emulator slots";
    user = mkOption {
      type = account;
      default = "android-worker";
      description = "Dedicated system account created to run ADB and the emulators.";
    };
    group = mkOption {
      type = account;
      default = cfg.user;
      defaultText = lib.literalExpression "config.programs.harborRs.androidWorker.user";
      description = "Group shared by the worker and its optional operator.";
    };
    operatorUser = mkOption {
      type = types.nullOr account;
      default = null;
      description = "Existing user allowed to start, stop, and restart slot units through polkit and use the lock directory.";
    };
    stateDir = mkOption {
      type = directory;
      default = "/var/lib/android-worker";
      description = "Absolute worker state path outside home directories. Each slot directory is replaced on start.";
    };
    lockDir = mkOption {
      type = directory;
      default = "/run/lock/android-worker";
      description = "Separate absolute path for external slot locks.";
    };
    adbHost = mkOption {
      type = types.strMatching "127(\\.(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){3}";
      default = "127.0.0.1";
      description = "IPv4 loopback address for the local ADB server.";
    };
    adbPort = mkOption {
      type = types.ints.between 1024 65535;
      default = 5037;
      description = "TCP port of the local ADB server.";
    };
    adbSystemdUnit = mkOption {
      type = unit;
      default = "harbor-android-adb.service";
      description = "Systemd service name of the local ADB server, including the .service suffix.";
    };
    androidSdk = mkOption {
      type = types.package;
      default =
        (mkAndroidSdk {
          inherit pkgs;
          platformVersions = lib.unique (map (slot: toString slot.apiLevel) cfg.slots);
          systemImageTypes = lib.unique (map (slot: slot.imageType) cfg.slots);
          abiVersions = lib.unique (map (slot: slot.abi) cfg.slots);
          buildToolsVersions = ["35.0.0"];
          ndkVersions = ["29.0.14206865"];
          includeNDK = false;
          includeEmulator = true;
          includeSystemImages = true;
        }).androidsdk;
      defaultText = lib.literalExpression "mkAndroidSdk with platforms and system images from slots";
      description = "SDK package with avdmanager in bin and adb, emulator, and the slot images under libexec/android-sdk. Set this to supply a custom SDK.";
    };
    slots = mkOption {
      type = types.listOf slotOption;
      default = [];
      description = "On-demand emulator slots. Apply host policy through systemd.services.<unit-name>.unitConfig or .serviceConfig (omit the .service suffix).";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.slots != [] && lib.allUnique (map (slot: slot.name) cfg.slots) && lib.all (slot: slot.name != "home") cfg.slots;
          message = "Android worker requires unique slot names, and 'home' is reserved.";
        }
        {
          assertion = lib.allUnique ([cfg.adbSystemdUnit] ++ slotUnits);
          message = "Android worker slot and ADB service names must be distinct.";
        }
        {
          assertion = lib.all (slot: lib.mod slot.emulatorPort 2 == 0) cfg.slots && lib.allUnique ([cfg.adbPort] ++ slotPorts);
          message = "Android worker emulator console ports must be even and neither they nor their adjacent ADB ports may overlap.";
        }
        {
          assertion = cfg.stateDir != cfg.lockDir && !(lib.hasPrefix "${cfg.stateDir}/" cfg.lockDir) && !(lib.hasPrefix "${cfg.lockDir}/" cfg.stateDir);
          message = "Android worker stateDir and lockDir must be separate, non-nested directories.";
        }
        {
          assertion = cfg.operatorUser == null || (cfg.operatorUser != cfg.user && builtins.hasAttr cfg.operatorUser config.users.users);
          message = "Android worker operatorUser must name an existing user other than the worker account.";
        }
      ];
      users.groups.${cfg.group} = {};
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = "${cfg.stateDir}/home";
        extraGroups = ["kvm"];
      };
      systemd.tmpfiles.rules = [
        "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
        "d ${cfg.stateDir}/home 0750 ${cfg.user} ${cfg.group} -"
        "d ${cfg.lockDir} 0770 ${
          if cfg.operatorUser == null
          then cfg.user
          else cfg.operatorUser
        } ${cfg.group} -"
      ];
      systemd.services =
        builtins.listToAttrs (map (slot: lib.nameValuePair (unitName slot.systemdUnit) (slotService slot)) cfg.slots)
        // {
          ${unitName cfg.adbSystemdUnit} = {
            description = "Loopback ADB server for Android emulator workers";
            unitConfig = {
              RequiresMountsFor = cfg.stateDir;
              StopWhenUnneeded = true;
            };
            serviceConfig =
              serviceDefaults
              // {
                ExecStart = "${sdkRoot}/platform-tools/adb -L ${adbEndpoint} nodaemon server";
                Environment = ["HOME=${cfg.stateDir}/home"];
                Restart = "on-failure";
                RestartSec = "1s";
              };
          };
        };
    }
    (lib.mkIf (cfg.operatorUser != null) {
      users.users.${cfg.operatorUser}.extraGroups = [cfg.group];
      security.polkit = {
        enable = true;
        extraConfig = ''
          polkit.addRule(function(action, subject) {
            var units = ${builtins.toJSON slotUnits};
            if (
              action.id == "org.freedesktop.systemd1.manage-units" &&
              subject.user == ${builtins.toJSON cfg.operatorUser} &&
              units.indexOf(action.lookup("unit")) >= 0 &&
              ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0
            ) {
              return polkit.Result.YES;
            }
          });
        '';
      };
    })
  ]);
}
