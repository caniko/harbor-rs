{
  pkgs,
  realizeMacosSdk,
}:
pkgs.writeShellApplication {
  name = "init-macos-sdk";
  runtimeInputs = [realizeMacosSdk];
  text = ''
    set -euo pipefail

    usage() {
      cat <<'USAGE'
    Usage:
      nix run rs-harbor#init-macos-sdk -- /path/to/MacOSX26.1.sdk.tar.xz 26.1

    Realizes a local macOS SDK archive into a stable Nix store output.

    Output includes:
      Store path      Commit this as macosSdkStorePath in project flakes
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

    cat <<EOF
    macOS SDK initialized.

    Store path:
    $STORE_PATH

    SDK root:
    $SDK_ROOT

    Recursive hash:
    $RECURSIVE_HASH

    Commit this in rs-harbor projects:

    cross = rs-harbor.lib.mkCross {
      inherit pkgs system;
      macosSdkStorePath = "$STORE_PATH";
      osxSdkVersion = "$SDK_VERSION";
    };
    EOF
  '';
}
