let
  machines = {
    aarch64-unknown-linux-musl = "AArch64";
    x86_64-unknown-linux-musl = "Advanced Micro Devices X86-64";
  };
  supported = target: builtins.isString target && builtins.hasAttr target machines;
  cargoTarget = lib: target: "CARGO_TARGET_${lib.toUpper (builtins.replaceStrings ["-"] ["_"] target)}";

  mkVerifyStaticElf = {pkgs}:
    pkgs.writeShellApplication {
      name = "verify-static-elf";
      runtimeInputs = [pkgs.binutils pkgs.file pkgs.coreutils];
      text = ''
        export LC_ALL=C

        usage() {
          echo 'Usage: verify-static-elf --target <rust-triple> [--receipt <path>] <binary>'
          echo 'Targets: ${pkgs.lib.concatStringsSep ", " (builtins.attrNames machines)}'
          echo 'A receipt is written only after successful validation.'
        }

        fail() {
          printf 'verify-static-elf: %s\n' "$*" >&2
          exit 1
        }

        tmp=
        err_file=
        cleanup() {
          if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi
          if [[ -n "$err_file" ]]; then rm -f -- "$err_file"; fi
        }
        trap cleanup EXIT

        target=
        receipt=
        while (( $# )); do
          case "$1" in
            --help) usage; exit 0 ;;
            --target)
              (( $# >= 2 )) && [[ -n "$2" && "$2" != -* ]] || fail "missing value for $1"
              target=$2
              shift 2 ;;
            --receipt)
              (( $# >= 2 )) && [[ -n "$2" ]] || fail "missing value for $1"
              case "$2" in
                --help|--target|--receipt) fail "missing value for $1" ;;
              esac
              receipt=$2
              shift 2 ;;
            --) shift; break ;;
            -*) fail "unknown option: $1" ;;
            *) break ;;
          esac
        done
        [[ -n "$target" && $# == 1 ]] || { usage >&2; exit 1; }
        binary=$1

        case "$target" in
          ${pkgs.lib.concatStringsSep "\n          " (pkgs.lib.mapAttrsToList (
            target: machine: "${target}) expected=${pkgs.lib.escapeShellArg machine} ;;"
          )
          machines)}
          *) fail "unsupported target: $target" ;;
        esac
        [[ -f "$binary" ]] || fail "not a regular file: $binary"

        if [[ -n "$receipt" ]]; then
          [[ ! -d "$receipt" ]] || fail "receipt path is a directory: $receipt"
          receipt_dir=$(dirname -- "$receipt")
          [[ -d "$receipt_dir" ]] || fail "receipt parent directory does not exist: $receipt_dir"
          [[ ! "$receipt" -ef "$binary" ]] || fail "receipt would replace the binary: $receipt"
        fi

        err_file=$(mktemp) || fail "mktemp failed"

        run_readelf() {
          local flag=$1
          local out
          : > "$err_file"
          if ! out=$(readelf -W "$flag" -- "$binary" 2>"$err_file"); then
            if [[ -s "$err_file" ]]; then cat "$err_file" >&2; fi
            fail "readelf $flag failed: $binary"
          fi
          if [[ -s "$err_file" ]]; then
            cat "$err_file" >&2
            fail "readelf $flag reported diagnostics: $binary"
          fi
          printf '%s' "$out"
        }

        digest_before=$(sha256sum < "$binary") || fail "sha256sum failed: $binary"

        # Brief output excludes the filename from the evidence and the match.
        description=$(file -bLE -- "$binary") || fail "file failed: $binary"
        header=$(run_readelf -h) || exit 1
        programs=$(run_readelf -l) || exit 1
        dynamic=$(run_readelf -d) || exit 1

        digest_after=$(sha256sum < "$binary") || fail "sha256sum failed: $binary"
        [[ "$digest_before" == "$digest_after" ]] || fail "binary changed during verification: $binary"

        class_re=$'(^|\n)[[:blank:]]*Class:[[:blank:]]+ELF64(\n|$)'
        [[ "$header" =~ $class_re ]] || fail "wrong ELF class (expected ELF64): $binary"

        data_re=$'(^|\n)[[:blank:]]*Data:[[:blank:]]+2\'s complement, little endian(\n|$)'
        [[ "$header" =~ $data_re ]] || fail "wrong ELF data encoding (expected little endian): $binary"

        exec_type_re=$'(^|\n)[[:blank:]]*Type:[[:blank:]]+EXEC \\(Executable file\\)(\n|$)'
        pie_type_re=$'(^|\n)[[:blank:]]*Type:[[:blank:]]+DYN \\(Position-Independent Executable file\\)(\n|$)'
        if [[ "$header" =~ $exec_type_re ]]; then
          elf_type="exec"
        elif [[ "$header" =~ $pie_type_re ]]; then
          elf_type="pie"
        else
          fail "unsupported ELF type (expected EXEC or PIE): $binary"
        fi

        [[ "$header" =~ (^|$'\n')[[:blank:]]*Machine:[[:blank:]]+"$expected"($'\n'|$) ]] ||
          fail "wrong ELF machine for $target (expected $expected): $binary"

        interp_re=$'(^|\n)[[:blank:]]*INTERP([[:space:]]|$)'
        if [[ "$programs" =~ $interp_re ]]; then
          fail "has an INTERP program header: $binary"
        fi

        dyn_dep_re=$'(^|\n)[[:blank:]]*0x[0-9a-fA-F]+[[:blank:]]+\\((NEEDED|AUXILIARY|FILTER|AUDIT|DEPAUDIT)\\)([[:space:]]|$)'
        if [[ "$dynamic" =~ $dyn_dep_re ]]; then
          fail "has an external dynamic dependency (''${BASH_REMATCH[2]}): $binary"
        fi

        if [[ "$elf_type" == exec ]]; then
          [[ "$description" =~ ^ELF\ 64-bit\ LSB\ executable,.*,[[:blank:]]statically\ linked(,|$) ]] ||
            fail "file does not identify a statically linked ELF executable: $binary"
        else
          [[ "$description" =~ ^ELF\ 64-bit\ LSB\ pie\ executable,.*,[[:blank:]]static-pie\ linked(,|$) ]] ||
            fail "file does not identify a static-pie linked ELF executable: $binary"
        fi

        if [[ -n "$receipt" ]]; then
          tmp=$(mktemp -- "$receipt.tmp.XXXXXXXX") || fail "mktemp failed for receipt: $receipt"
          printf 'target: %s\nfile: %s\n\nreadelf -W -h:\n%s\n\nreadelf -W -l:\n%s\n\nreadelf -W -d:\n%s\n\nsha256sum:\n%s\n' \
            "$target" "$description" "$header" "$programs" "$dynamic" "$digest_after" > "$tmp"
          chmod 0644 -- "$tmp"
          mv -fT -- "$tmp" "$receipt"
          tmp=
        fi
      '';
    };
in {
  inherit mkVerifyStaticElf;

  # The caller supplies a toolchain with the Rust standard library for each target.
  mkStaticMuslShell = {
    pkgs,
    rustToolchain,
    targets ? builtins.attrNames machines,
    extraPackages ? [],
    extraRustflags ? "",
    shellHook ? "",
    name ? "cross-arch-musl-receipt",
  }: let
    inherit (pkgs) lib;
    targetEnv = cargoTarget lib;
    rustflags = "-C linker-flavor=ld.lld -C link-self-contained=yes" + lib.optionalString (extraRustflags != "") " ${extraRustflags}";
  in
    assert lib.assertMsg (builtins.isList targets && targets != [] && builtins.all supported targets)
    "harbor-rs: mkStaticMuslShell targets must be a non-empty list of supported Linux musl triples: ${lib.concatStringsSep ", " (builtins.attrNames machines)}";
    assert lib.assertMsg (builtins.length (lib.unique targets) == builtins.length targets)
    "harbor-rs: mkStaticMuslShell targets must not contain duplicates";
    assert lib.assertMsg (builtins.isString extraRustflags)
    "harbor-rs: mkStaticMuslShell extraRustflags must be a string";
    assert lib.assertMsg (builtins.isString shellHook)
    "harbor-rs: mkStaticMuslShell shellHook must be a string";
    assert lib.assertMsg (builtins.isString name)
    "harbor-rs: mkStaticMuslShell name must be a string";
      pkgs.mkShellNoCC ({
          inherit name;
          packages = [rustToolchain pkgs.binutils pkgs.file pkgs.jq pkgs.coreutils (mkVerifyStaticElf {inherit pkgs;})] ++ extraPackages;
          shellHook = ''
            harbor_rs_rust_lld="$(
              rustc_bin=${lib.escapeShellArg "${rustToolchain}/bin/rustc"}
              if [[ ! -x "$rustc_bin" ]]; then
                printf 'harbor-rs: rustc is missing or not executable: %s\n' "$rustc_bin" >&2
                exit 1
              fi
              sysroot=$("$rustc_bin" --print sysroot) && rust_version=$("$rustc_bin" -vV) || exit 1
              if [[ "$rust_version" =~ (^|$'\n')'host: '([^[:space:]]+) ]]; then
                linker="$sysroot/lib/rustlib/''${BASH_REMATCH[2]}/bin/rust-lld"
                if [[ -f "$linker" && -x "$linker" ]]; then
                  printf '%s\n' "$linker"
                  exit 0
                fi
                printf 'harbor-rs: rust-lld is missing or not executable: %s\n' "$linker" >&2
              else
                echo 'harbor-rs: rustc -vV did not report a host triple' >&2
              fi
              exit 1
            )" || exit 1
            ${lib.concatMapStringsSep "\n" (target: ''export ${targetEnv target}_LINKER="$harbor_rs_rust_lld"'') targets}
            unset harbor_rs_rust_lld
            ${shellHook}
          '';
        }
        // builtins.listToAttrs (map (target: lib.nameValuePair "${targetEnv target}_RUSTFLAGS" rustflags) targets));

  # Verifies ELF architecture and static linkage, not libc or compiler provenance.
  mkCrossArchMuslReceipt = {
    pkgs,
    binary,
    rustTarget,
    name ? "static-elf-${rustTarget}-receipt",
  }:
    assert pkgs.lib.assertMsg (supported rustTarget) "harbor-rs: mkCrossArchMuslReceipt requires a supported Linux musl triple";
      pkgs.runCommand name {
        nativeBuildInputs = [(mkVerifyStaticElf {inherit pkgs;})];
        binaryPath = "${binary}";
      } ''
        verify-static-elf --target ${pkgs.lib.escapeShellArg rustTarget} --receipt "$out" -- "$binaryPath"
      '';
}
