# mkSteamRuntimeTools :: { pkgs, runtime?, customImage?, containerRuntime? } -> attrs
#
# Generic Steam Runtime helpers. Downstream projects own their release layout,
# Steam app IDs, and build commands; this module only provides runtime metadata,
# a container command wrapper, and portable dependency audit scripts.
{
  pkgs,
  runtime ? "sniper",
  customImage ? null,
  containerRuntime ? "podman",
}: let
  inherit (pkgs) lib;

  runtimes = {
    sniper = {
      name = "Steam Linux Runtime 3.0 (sniper)";
      sdkImage = "registry.gitlab.steamos.cloud/steamrt/sniper/sdk";
      platformImage = "registry.gitlab.steamos.cloud/steamrt/sniper/platform";
      steamworksToolAppId = "1628350";
    };
    scout = {
      name = "Steam Linux Runtime 1.0 (scout)";
      sdkImage = "registry.gitlab.steamos.cloud/steamrt/scout/sdk";
      platformImage = "registry.gitlab.steamos.cloud/steamrt/scout/platform";
      steamworksToolAppId = "1070560";
    };
  };

  selectedRuntime =
    if lib.hasAttr runtime runtimes
    then runtimes.${runtime}
    else {
      name = runtime;
      sdkImage = runtime;
      platformImage = runtime;
      steamworksToolAppId = null;
    };

  image =
    if customImage != null
    then customImage
    else selectedRuntime.sdkImage;

  containerCommandText = ''
    ${containerRuntime} run --rm -it \
      --volume "$PWD:$PWD" \
      --workdir "$PWD" \
      --user "$(id -u):$(id -g)" \
      ${image} -- <command>
  '';

  steamRuntimeExec = pkgs.writeShellApplication {
    name = "steam-runtime-exec";
    runtimeInputs = with pkgs; [coreutils];
    text = ''
      runtime="${runtime}"
      image="${image}"
      runner="${containerRuntime}"
      interactive=0
      mount_nix_store=0

      usage() {
        cat <<'USAGE'
      Usage: steam-runtime-exec [options] -- command [args...]

      Options:
        --runtime NAME             Runtime label for diagnostics (default from Nix)
        --image IMAGE              OCI image to execute in
        --container-runtime CMD    Container runner, usually podman or docker
        --interactive              Allocate a TTY
        --mount-nix-store          Mount /nix/store read-only for Nix-built tools
        -h, --help                 Show this help

      The wrapper mounts the current working directory at the same path and runs
      the command as the current uid/gid. It does not install project toolchains
      or assume a Cargo/Nix layout.
      USAGE
      }

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --runtime)
            runtime="$2"
            shift 2
            ;;
          --image)
            image="$2"
            shift 2
            ;;
          --container-runtime)
            runner="$2"
            shift 2
            ;;
          --interactive)
            interactive=1
            shift
            ;;
          --mount-nix-store)
            mount_nix_store=1
            shift
            ;;
          --)
            shift
            break
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            echo "steam-runtime-exec: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        esac
      done

      if [ "$#" -eq 0 ]; then
        echo "steam-runtime-exec: missing command after --" >&2
        usage >&2
        exit 2
      fi

      if ! command -v "$runner" >/dev/null 2>&1; then
        echo "steam-runtime-exec: container runtime not found: $runner" >&2
        exit 127
      fi

      tty_args=()
      if [ "$interactive" -eq 1 ]; then
        tty_args=(-it)
      fi

      nix_store_args=()
      if [ "$mount_nix_store" -eq 1 ]; then
        if [ ! -d /nix/store ]; then
          echo "steam-runtime-exec: --mount-nix-store requested but /nix/store does not exist" >&2
          exit 1
        fi
        nix_store_args=(--volume /nix/store:/nix/store:ro)
      fi

      echo "steam-runtime-exec: runtime=$runtime image=$image runner=$runner" >&2
      exec "$runner" run --rm "''${tty_args[@]}" \
        "''${nix_store_args[@]}" \
        --volume "$PWD:$PWD" \
        --workdir "$PWD" \
        --user "$(id -u):$(id -g)" \
        "$image" "$@"
    '';
  };

  auditElfRuntimeDeps = pkgs.writeShellApplication {
    name = "audit-elf-runtime-deps";
    runtimeInputs = with pkgs; [binutils coreutils file findutils gnugrep patchelf];
    text = ''
      allow_needed_regex='.*'
      forbid_path_regex='(/nix/store|/usr/local|/home/)'
      require_origin_rpath=0

      usage() {
        cat <<'USAGE'
      Usage: audit-elf-runtime-deps [options] FILE_OR_DIR

      Options:
        --allow-needed-regex REGEX  Every ELF DT_NEEDED soname must match REGEX
        --forbid-path-regex REGEX   RPATH/RUNPATH and ldd output must not match REGEX
        --require-origin-rpath      Require $ORIGIN in RPATH/RUNPATH
        -h, --help                  Show this help
      USAGE
      }

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --allow-needed-regex)
            allow_needed_regex="$2"
            shift 2
            ;;
          --forbid-path-regex)
            forbid_path_regex="$2"
            shift 2
            ;;
          --require-origin-rpath)
            require_origin_rpath=1
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "audit-elf-runtime-deps: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
          *)
            break
            ;;
        esac
      done

      if [ "$#" -ne 1 ]; then
        echo "audit-elf-runtime-deps: expected exactly one FILE_OR_DIR" >&2
        usage >&2
        exit 2
      fi

      input="$1"
      if [ ! -e "$input" ]; then
        echo "audit-elf-runtime-deps: missing path: $input" >&2
        exit 1
      fi

      failed=0
      checked=0

      check_file() {
        candidate="$1"
        if ! file "$candidate" | grep -Eq 'ELF .* (executable|shared object|pie executable)'; then
          return 0
        fi

        checked=$((checked + 1))
        echo "audit-elf-runtime-deps: checking $candidate"

        rpath="$(patchelf --print-rpath "$candidate" 2>/dev/null || true)"
        if [ -n "$rpath" ] && echo "$rpath" | grep -Eq "$forbid_path_regex"; then
          echo "audit-elf-runtime-deps: forbidden path in RPATH/RUNPATH for $candidate: $rpath" >&2
          failed=1
        fi
        if [ "$require_origin_rpath" -eq 1 ] && ! echo "$rpath" | grep -Fq "\$ORIGIN"; then
          echo "audit-elf-runtime-deps: missing \$ORIGIN RPATH/RUNPATH in $candidate" >&2
          failed=1
        fi

        while IFS= read -r needed; do
          [ -n "$needed" ] || continue
          if ! echo "$needed" | grep -Eq "$allow_needed_regex"; then
            echo "audit-elf-runtime-deps: disallowed DT_NEEDED in $candidate: $needed" >&2
            failed=1
          fi
        done < <(patchelf --print-needed "$candidate" 2>/dev/null || true)

        ldd_cmd="ldd"
        if [ -x /usr/bin/ldd ]; then
          ldd_cmd="/usr/bin/ldd"
        fi
        ldd_output="$("$ldd_cmd" "$candidate" 2>&1 || true)"
        if echo "$ldd_output" | grep -Fq 'not found'; then
          echo "audit-elf-runtime-deps: missing library for $candidate" >&2
          echo "$ldd_output" >&2
          failed=1
        fi
        if echo "$ldd_output" | grep -Eq "$forbid_path_regex"; then
          echo "audit-elf-runtime-deps: forbidden resolved path for $candidate" >&2
          echo "$ldd_output" >&2
          failed=1
        fi
      }

      if [ -d "$input" ]; then
        while IFS= read -r -d "" path; do
          check_file "$path"
        done < <(find "$input" -type f -print0)
      else
        check_file "$input"
      fi

      if [ "$checked" -eq 0 ]; then
        echo "audit-elf-runtime-deps: no ELF executables or shared objects found under $input" >&2
        exit 1
      fi

      if [ "$failed" -ne 0 ]; then
        exit 1
      fi
      echo "audit-elf-runtime-deps: checked $checked ELF file(s)"
    '';
  };

  auditWindowsRuntimeDeps = pkgs.writeShellApplication {
    name = "audit-windows-runtime-deps";
    runtimeInputs = with pkgs; [coreutils file findutils gnugrep gnused llvmPackages.llvm];
    text = ''
      allow_dll_regex='.*'
      forbid_path_regex='(/nix/store|/usr/local|/home/)'

      usage() {
        cat <<'USAGE'
      Usage: audit-windows-runtime-deps [options] FILE_OR_DIR

      Options:
        --allow-dll-regex REGEX     Every imported DLL name must match REGEX
        --forbid-path-regex REGEX   Binary strings must not match REGEX
        -h, --help                  Show this help
      USAGE
      }

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --allow-dll-regex)
            allow_dll_regex="$2"
            shift 2
            ;;
          --forbid-path-regex)
            forbid_path_regex="$2"
            shift 2
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "audit-windows-runtime-deps: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
          *)
            break
            ;;
        esac
      done

      if [ "$#" -ne 1 ]; then
        echo "audit-windows-runtime-deps: expected exactly one FILE_OR_DIR" >&2
        usage >&2
        exit 2
      fi

      input="$1"
      if [ ! -e "$input" ]; then
        echo "audit-windows-runtime-deps: missing path: $input" >&2
        exit 1
      fi

      failed=0
      checked=0

      check_file() {
        candidate="$1"
        if ! file "$candidate" | grep -Eq 'PE32'; then
          return 0
        fi

        checked=$((checked + 1))
        echo "audit-windows-runtime-deps: checking $candidate"

        while IFS= read -r dll; do
          [ -n "$dll" ] || continue
          if ! echo "$dll" | grep -Eiq "$allow_dll_regex"; then
            echo "audit-windows-runtime-deps: disallowed DLL import in $candidate: $dll" >&2
            failed=1
          fi
        done < <(llvm-objdump -p "$candidate" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p')

        if strings "$candidate" | grep -Eq "$forbid_path_regex"; then
          echo "audit-windows-runtime-deps: forbidden path string in $candidate" >&2
          failed=1
        fi
      }

      if [ -d "$input" ]; then
        while IFS= read -r -d "" path; do
          check_file "$path"
        done < <(find "$input" -type f -print0)
      else
        check_file "$input"
      fi

      if [ "$checked" -eq 0 ]; then
        echo "audit-windows-runtime-deps: no PE files found under $input" >&2
        exit 1
      fi

      if [ "$failed" -ne 0 ]; then
        exit 1
      fi
      echo "audit-windows-runtime-deps: checked $checked PE file(s)"
    '';
  };

  auditDarwinRuntimeDeps = pkgs.writeShellApplication {
    name = "audit-darwin-runtime-deps";
    runtimeInputs = with pkgs; [coreutils file findutils gawk gnugrep gnused llvmPackages.llvm];
    text = ''
      allow_dylib_regex='^(@executable_path|@rpath|/usr/lib/|/System/Library/)'
      forbid_path_regex='(/nix/store|/usr/local|/home/)'

      usage() {
        cat <<'USAGE'
      Usage: audit-darwin-runtime-deps [options] FILE_OR_DIR

      Options:
        --allow-dylib-regex REGEX   Every Mach-O dependency path must match REGEX
        --forbid-path-regex REGEX   Dependency paths must not match REGEX
        -h, --help                  Show this help
      USAGE
      }

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --allow-dylib-regex)
            allow_dylib_regex="$2"
            shift 2
            ;;
          --forbid-path-regex)
            forbid_path_regex="$2"
            shift 2
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          --)
            shift
            break
            ;;
          -*)
            echo "audit-darwin-runtime-deps: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
          *)
            break
            ;;
        esac
      done

      if [ "$#" -ne 1 ]; then
        echo "audit-darwin-runtime-deps: expected exactly one FILE_OR_DIR" >&2
        usage >&2
        exit 2
      fi

      input="$1"
      if [ ! -e "$input" ]; then
        echo "audit-darwin-runtime-deps: missing path: $input" >&2
        exit 1
      fi

      otool_cmd=""
      if command -v otool >/dev/null 2>&1; then
        otool_cmd="otool"
      elif command -v llvm-otool >/dev/null 2>&1; then
        otool_cmd="llvm-otool"
      else
        echo "audit-darwin-runtime-deps: neither otool nor llvm-otool is available" >&2
        exit 127
      fi

      failed=0
      checked=0

      check_file() {
        candidate="$1"
        if ! file "$candidate" | grep -Eq 'Mach-O'; then
          return 0
        fi

        checked=$((checked + 1))
        echo "audit-darwin-runtime-deps: checking $candidate"

        "$otool_cmd" -L "$candidate" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
          dep="$(echo "$line" | awk '{print $1}')"
          [ -n "$dep" ] || continue
          if echo "$dep" | grep -Eq "$forbid_path_regex"; then
            echo "audit-darwin-runtime-deps: forbidden dependency path in $candidate: $dep" >&2
            exit 10
          fi
          if ! echo "$dep" | grep -Eq "$allow_dylib_regex"; then
            echo "audit-darwin-runtime-deps: disallowed dependency in $candidate: $dep" >&2
            exit 11
          fi
        done || failed=1
      }

      if [ -d "$input" ]; then
        while IFS= read -r -d "" path; do
          check_file "$path"
        done < <(find "$input" -type f -print0)
      else
        check_file "$input"
      fi

      if [ "$checked" -eq 0 ]; then
        echo "audit-darwin-runtime-deps: no Mach-O files found under $input" >&2
        exit 1
      fi

      if [ "$failed" -ne 0 ]; then
        exit 1
      fi
      echo "audit-darwin-runtime-deps: checked $checked Mach-O file(s)"
    '';
  };
in {
  inherit runtimes selectedRuntime image containerCommandText;
  inherit steamRuntimeExec auditElfRuntimeDeps auditWindowsRuntimeDeps auditDarwinRuntimeDeps;

  packages = {
    inherit steamRuntimeExec auditElfRuntimeDeps auditWindowsRuntimeDeps auditDarwinRuntimeDeps;
  };
}
