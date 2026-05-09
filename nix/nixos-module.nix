self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.rsHarbor.macosSdk;
  initMacosSdk = self.packages.${pkgs.stdenv.hostPlatform.system}.init-macos-sdk;

  initCommand = pkgs.writeShellApplication {
    name = "rs-harbor-init-macos-sdk";
    runtimeInputs = [
      initMacosSdk
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      set -euo pipefail

      archive_path=${lib.escapeShellArg (toString cfg.archivePath)}
      sdk_version=${lib.escapeShellArg cfg.sdkVersion}
      state_dir=${lib.escapeShellArg cfg.stateDir}
      env_file="$state_dir/env"

      if [ -z "$archive_path" ]; then
        cat >&2 <<EOF
      error: programs.rsHarbor.macosSdk.archivePath is unset on this host.

      Set archivePath to a local Apple-licensed SDK tarball before running
      rs-harbor-init-macos-sdk, or pin storePath directly if the realized SDK
      is being substituted from a binary cache.
      EOF
        exit 64
      fi

      if [ ! -f "$archive_path" ]; then
        cat >&2 <<EOF
      error: macOS SDK archive is missing: $archive_path

      This host must provide the private SDK archive at the configured path
      before macOS cross-compilation can be initialized.
      EOF
        exit 66
      fi

      output="$(init-macos-sdk "$archive_path" "$sdk_version")"

      store_path="$(printf '%s\n' "$output" | awk '
        $0 ~ /^[[:space:]]*Store path:[[:space:]]*$/ { getline; print; exit }
      ')"
      sdk_root="$(printf '%s\n' "$output" | awk '
        $0 ~ /^[[:space:]]*SDK root:[[:space:]]*$/ { getline; print; exit }
      ')"
      recursive_hash="$(printf '%s\n' "$output" | awk '
        $0 ~ /^[[:space:]]*Recursive hash:[[:space:]]*$/ { getline; print; exit }
      ')"

      if [ -z "$store_path" ] || [ -z "$sdk_root" ] || [ -z "$recursive_hash" ]; then
        echo "error: failed to parse rs-harbor init-macos-sdk output" >&2
        printf '%s\n' "$output" >&2
        exit 70
      fi

      if [ ! -d "$sdk_root" ]; then
        echo "error: expected SDK root was not produced: $sdk_root" >&2
        exit 70
      fi

      install -d -m 0755 "$state_dir"
      tmp="$(mktemp "$state_dir/env.XXXXXX")"
      {
        printf 'STORE_PATH=%q\n' "$store_path"
        printf 'SDK_ROOT=%q\n' "$sdk_root"
        printf 'SDK_VERSION=%q\n' "$sdk_version"
        printf 'RECURSIVE_HASH=%q\n' "$recursive_hash"
      } > "$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" "$env_file"

      cat <<EOF
      macOS SDK initialized.

      Env file:
      $env_file

      Store path:
      $store_path

      SDK root:
      $sdk_root

      Commit this in this host's configuration:

      programs.rsHarbor.macosSdk.storePath = "$store_path";
      programs.rsHarbor.macosSdk.sdkVersion = "$sdk_version";
      EOF
    '';
  };
in {
  options.programs.rsHarbor.macosSdk = {
    enable = lib.mkEnableOption "rs-harbor macOS SDK realization for osxcross cross-compilation";

    sdkVersion = lib.mkOption {
      type = lib.types.str;
      default = "26.1";
      description = "macOS SDK version passed to rs-harbor init-macos-sdk.";
    };

    archivePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host-local Apple-licensed macOS SDK archive path. Only required on the
        host that realizes the SDK into the Nix store. Hosts that consume the
        already-realized SDK from a binary cache may leave this null and pin
        only `storePath`.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/rs-harbor/macos-sdk";
      description = "Directory where rs-harbor-init-macos-sdk writes the generated env file.";
    };

    storePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Realized macOS SDK store path injected into rs-harbor project wrappers
        via `mkCrossArgs`. Produced by running `rs-harbor-init-macos-sdk` on a
        host that has the SDK archive, then committed verbatim on hosts that
        consume the SDK from a binary cache.
      '';
    };

    installInitCommand = lib.mkOption {
      type = lib.types.bool;
      default = cfg.archivePath != null;
      defaultText = lib.literalExpression "config.programs.rsHarbor.macosSdk.archivePath != null";
      description = ''
        Install the `rs-harbor-init-macos-sdk` shell command system-wide. By
        default this is enabled only on hosts that supply an `archivePath`,
        i.e. hosts capable of producing the realized SDK store path. Pure
        consumers (those that only pin `storePath`) do not need it.
      '';
    };

    mkCrossArgs = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default =
        {osxSdkVersion = cfg.sdkVersion;}
        // lib.optionalAttrs (cfg.storePath != null) {
          macosSdkStorePath = cfg.storePath;
        };
      defaultText = lib.literalExpression ''
        {
          osxSdkVersion = config.programs.rsHarbor.macosSdk.sdkVersion;
        } // optional macosSdkStorePath
      '';
      description = "Arguments to merge into rs-harbor.lib.mkCross from project wrappers.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.mkIf cfg.installInitCommand [initCommand];
  };
}
