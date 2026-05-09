{
  pkgs,
  realizeMacosSdk,
  validateMacosSdk,
}:
pkgs.writeShellApplication {
  name = "init-macos-sdk";
  runtimeInputs = [
    realizeMacosSdk
    validateMacosSdk
  ];
  text = ''
    set -euo pipefail

    usage() {
      cat <<'USAGE'
    Usage:
      nix run rs-harbor#init-macos-sdk -- /path/to/MacOSX26.1.sdk.tar.xz 26.1

    Realizes and validates a local macOS SDK archive into a stable Nix store output.

    Output includes:
      Store path      Host-specific store path for host/module configuration
      SDK root        Direct MacOSX<version>.sdk path
      Recursive hash  Fixed-output hash for cache/debugging
    USAGE
    }

    if [ "''${1:-}" = "--help" ] || [ "''${1:-}" = "-h" ]; then
      usage
      exit 0
    fi

    if [ "$#" -ne 2 ]; then
      usage >&2
      exit 64
    fi

    archive="$1"
    sdk_version="$2"
    STORE_PATH=""
    SDK_ROOT=""
    SDK_VERSION=""
    RECURSIVE_HASH=""
    eval "$(realize-macos-sdk --env "$archive" "$sdk_version")"
    validate-macos-sdk "$SDK_ROOT" "$SDK_VERSION" >/dev/null

    cat <<EOF
    macOS SDK initialized.

    Store path:
    $STORE_PATH

    SDK root:
    $SDK_ROOT

    Recursive hash:
    $RECURSIVE_HASH

    Commit this in host configuration, not reusable project flakes:

    programs.rsHarbor.macosSdk.storePath = "$STORE_PATH";
    programs.rsHarbor.macosSdk.sdkVersion = "$SDK_VERSION";
    EOF
  '';
}
