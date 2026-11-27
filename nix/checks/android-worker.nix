{
  nixpkgs,
  self,
  system,
}: let
  worker = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.androidWorker
      ({...}: {
        system.stateVersion = "26.05";
        boot.isContainer = true;
        users.users.operator.isNormalUser = true;
        programs.harborRs.androidWorker = {
          enable = true;
          operatorUser = "operator";
          adbPort = 15037;
          slots = [
            {
              name = "first";
              emulatorPort = 5600;
              ramMb = 2048;
              cores = 2;
              extraArgs = ["-prop" "example=literal value"];
            }
            {
              name = "second";
              emulatorPort = 5558;
              avdName = "custom-avd";
              systemdUnit = "custom-android.service";
            }
          ];
        };
        systemd.services.custom-android.unitConfig.ConditionACPower = true;
      })
    ];
  };
  inherit (worker) config pkgs;
  inherit (pkgs) lib;
  adb = config.systemd.services.harbor-android-adb;
  first = config.systemd.services.harbor-android-first;
  second = config.systemd.services.custom-android;
  polkit = config.security.polkit.extraConfig;
in
  assert lib.all (entry: entry.assertion) config.assertions;
  assert lib.hasInfix "tcp:127.0.0.1:15037" adb.serviceConfig.ExecStart;
  assert adb.wantedBy == [] && adb.unitConfig.StopWhenUnneeded;
  assert first.requires == ["harbor-android-adb.service"] && first.wantedBy == [];
  assert builtins.elem "ADB_SERVER_SOCKET=tcp:127.0.0.1:15037" first.serviceConfig.Environment;
  assert builtins.elem "ANDROID_ADB_SERVER_PORT=15037" first.serviceConfig.Environment;
  assert builtins.elem "/dev/kvm rw" first.serviceConfig.DeviceAllow;
  assert builtins.elem "kvm" config.users.users.android-worker.extraGroups;
  assert lib.hasInfix ''"example=literal value"'' first.serviceConfig.ExecStart;
  assert lib.hasInfix "custom-avd" second.serviceConfig.ExecStart;
  assert second.unitConfig.ConditionACPower && !(first.unitConfig ? ConditionACPower);
  assert builtins.elem "d /var/lib/android-worker/home 0750 android-worker android-worker -" config.systemd.tmpfiles.rules;
  assert builtins.elem "d /run/lock/android-worker 0770 operator android-worker -" config.systemd.tmpfiles.rules;
  assert config.security.polkit.enable && lib.hasInfix ''subject.user == "operator"'' polkit;
  assert lib.hasInfix ''["harbor-android-first.service","custom-android.service"]'' polkit;
  assert !(lib.hasInfix "harbor-android-adb.service" polkit);
    pkgs.runCommand "android-worker-module-eval" {} "touch $out"
