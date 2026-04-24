{
  pkgs,
  osxcross,
}:
pkgs.writeShellApplication {
  name = "init-macos-sdk";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.nix
  ];
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

    if [ "''${archive#/}" = "$archive" ]; then
      archive="$(realpath "$archive")"
    fi

    if [ ! -f "$archive" ]; then
      echo "error: SDK archive does not exist: $archive" >&2
      exit 66
    fi

    if [ -z "$sdk_version" ]; then
      echo "error: SDK version must not be empty" >&2
      exit 64
    fi

    sdk_expr="$(cat <<'NIX_EXPR'
    let
      osxcrossFlake = builtins.getFlake (builtins.getEnv "RS_HARBOR_OSXCROSS_FLAKE");
      system = builtins.currentSystem;
      sdkArchivePath = builtins.getEnv "RS_HARBOR_SDK_ARCHIVE";
      sdkVersion = builtins.getEnv "RS_HARBOR_SDK_VERSION";
      outputHash = builtins.getEnv "RS_HARBOR_SDK_OUTPUT_HASH";
      sdkArgs =
        {
          sdkArchive = /. + sdkArchivePath;
          inherit sdkVersion;
        }
        // (
          if outputHash == ""
          then {}
          else { inherit outputHash; }
        );
      osxcrossLib = builtins.getAttr system osxcrossFlake.lib;
      macosSdk =
        if osxcrossLib ? mkMacosSdk
        then osxcrossLib.mkMacosSdk sdkArgs
        else throw "init-macos-sdk requires an osxcross input that exposes lib.<system>.mkMacosSdk";
    in
      macosSdk.sdk
    NIX_EXPR
    )"

    nix_cmd=(nix --extra-experimental-features "nix-command flakes")

    export RS_HARBOR_OSXCROSS_FLAKE="${osxcross.outPath}"
    export RS_HARBOR_SDK_ARCHIVE="$archive"
    export RS_HARBOR_SDK_VERSION="$sdk_version"
    export RS_HARBOR_SDK_OUTPUT_HASH=""

    echo "Building bootstrap SDK from local archive..." >&2
    bootstrap_out="$(
      "''${nix_cmd[@]}" build --impure --no-link --print-out-paths --expr "$sdk_expr"
    )"

    recursive_hash="$("''${nix_cmd[@]}" hash path "$bootstrap_out")"

    export RS_HARBOR_SDK_OUTPUT_HASH="$recursive_hash"
    echo "Rebuilding fixed-output SDK with recursive hash..." >&2
    final_out="$(
      "''${nix_cmd[@]}" build --impure --no-link --print-out-paths --expr "$sdk_expr"
    )"

    sdk_root="$final_out/MacOSX$sdk_version.sdk"

    if [ ! -d "$sdk_root" ]; then
      echo "error: expected SDK root was not produced: $sdk_root" >&2
      exit 70
    fi

    cat <<EOF
    macOS SDK initialized.

    Store path:
    $final_out

    SDK root:
    $sdk_root

    Recursive hash:
    $recursive_hash

    Commit this in rs-harbor projects:

    cross = rs-harbor.lib.mkCross {
      inherit pkgs system;
      macosSdkStorePath = "$final_out";
      osxSdkVersion = "$sdk_version";
    };
    EOF
  '';
}
