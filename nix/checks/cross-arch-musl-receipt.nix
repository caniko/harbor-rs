{
  pkgs,
  mkVerifyStaticElf,
  mkStaticMuslShell,
  mkCrossArchMuslReceipt,
}: let
  arm = "aarch64-unknown-linux-musl";
  x86 = "x86_64-unknown-linux-musl";
  isArm = pkgs.stdenv.hostPlatform.isAarch64;
  rustTarget =
    if isArm
    then arm
    else x86;
  otherTarget =
    if isArm
    then x86
    else arm;
  unsupported = "x86_64-unknown-linux-gnu";
  stubRustToolchain = pkgs.writeShellScriptBin "rustc" ''
    case "''${STUB_RUSTC_MODE:-ok}" in
      fail) exit 1 ;;
      no-host)
        case "$*" in
          '--print sysroot') printf '%s\n' "$STUB_SYSROOT" ;;
          '-vV') printf 'rustc fixture\nrelease: fixture\n' ;;
          *) exit 1 ;;
        esac
        ;;
      ok)
        case "$*" in
          '--print sysroot') printf '%s\n' "$STUB_SYSROOT" ;;
          '-vV') printf 'rustc fixture\nhost: test-unknown-linux-gnu\nrelease: fixture\n' ;;
          *) exit 1 ;;
        esac
        ;;
      *) exit 1 ;;
    esac
  '';
  shellArgs = {
    inherit pkgs;
    rustToolchain = stubRustToolchain;
    shellHook = "export USER_HOOK_RAN=yes";
  };
  defaultShell = mkStaticMuslShell shellArgs;
  armShell = mkStaticMuslShell (shellArgs // {targets = [arm];});
  x86Shell = mkStaticMuslShell (shellArgs
    // {
      targets = [x86];
      extraRustflags = "-C opt-level=2";
    });
  missingRustcShell = mkStaticMuslShell (shellArgs // {rustToolchain = pkgs.emptyDirectory;});
  binary =
    pkgs.runCommand "musl-receipt-static-fixture" {
      nativeBuildInputs = [pkgs.stdenv.cc];
    } ''
      printf 'void _start(void) { for (;;) {} }\n' > start.c
      cc -nostdlib -static -no-pie -Wl,--build-id=none -o "$out" start.c
    '';
  receipt = mkCrossArchMuslReceipt {inherit pkgs binary rustTarget;};
  brokenReadelf = pkgs.writeShellScriptBin "readelf" ''
    if [[ "$2" == "''${FAIL_INSPECTION:-}" ]]; then exit 1; fi
    if [[ "$2" == "''${WARN_INSPECTION:-}" ]]; then
      echo "readelf: Warning: simulated diagnostic" >&2
    fi
    exec ${pkgs.binutils}/bin/readelf "$@"
  '';
  brokenVerifier = mkVerifyStaticElf {pkgs = pkgs // {binutils = brokenReadelf;};};
  machineLeHex =
    if isArm
    then "\\xb7\\x00"
    else "\\x3e\\x00";
  machineBeHex =
    if isArm
    then "\\x00\\xb7"
    else "\\x00\\x3e";
in
  assert builtins.all builtins.isFunction [mkVerifyStaticElf mkStaticMuslShell mkCrossArchMuslReceipt];
  assert builtins.all builtins.isString (map (shell: shell.drvPath) [defaultShell armShell x86Shell missingRustcShell]);
  assert defaultShell.CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS == "-C linker-flavor=ld.lld -C link-self-contained=yes";
  assert defaultShell.CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS == defaultShell.CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS;
  assert !(armShell ? CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS);
  assert x86Shell.CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS == "${defaultShell.CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS} -C opt-level=2";
  assert !(builtins.tryEval (mkStaticMuslShell (shellArgs // {targets = [];})).drvPath).success;
  assert !(builtins.tryEval (mkStaticMuslShell (shellArgs // {targets = [arm unsupported];})).drvPath).success;
  assert !(builtins.tryEval (mkStaticMuslShell (shellArgs // {targets = [arm arm];})).drvPath).success;
  assert !(builtins.tryEval (mkStaticMuslShell (shellArgs // {targets = arm;})).drvPath).success;
  assert !(builtins.tryEval (mkStaticMuslShell (shellArgs // {extraRustflags = ["-C" "opt-level=2"];})).drvPath).success;
  assert !(builtins.tryEval (mkStaticMuslShell (shellArgs // {shellHook = 123;})).drvPath).success;
  assert !(builtins.tryEval (mkStaticMuslShell (shellArgs // {name = 123;})).drvPath).success;
  assert !(builtins.tryEval
    (mkCrossArchMuslReceipt {
      inherit pkgs binary;
      rustTarget = unsupported;
    }).drvPath).success;
    pkgs.runCommand "check-cross-arch-musl-receipt" {
      nativeBuildInputs = [pkgs.stdenv.cc pkgs.binutils (mkVerifyStaticElf {inherit pkgs;})];
    } ''
      cp "${binary}" valid-static
      verify-static-elf --help
      verify-static-elf --target ${rustTarget} --receipt receipt.txt ./valid-static
      test "$(stat -c '%a' receipt.txt)" = 644
      grep -F 'Machine:' receipt.txt
      grep -F 'statically linked' receipt.txt
      digest=$(sha256sum < valid-static)
      grep -Fx "$digest" receipt.txt
      cmp receipt.txt "${receipt}"

      # Receipt path starting with -- is accepted; known flag value is rejected.
      verify-static-elf --target ${rustTarget} --receipt --dash-receipt.txt ./valid-static
      cmp -- --dash-receipt.txt receipt.txt
      rm -f -- --dash-receipt.txt
      if verify-static-elf --target ${rustTarget} --receipt --target ./valid-static >error.log 2>&1; then
        echo 'unexpectedly accepted --target as receipt value' >&2
        exit 1
      fi
      grep -F 'missing value for --receipt' error.log

      # CLI filename edge cases: leading dash and spaces.
      cp valid-static -- -leading-dash
      verify-static-elf --target ${rustTarget} -- -leading-dash
      cp valid-static 'binary with spaces'
      verify-static-elf --target ${rustTarget} 'binary with spaces'

      printf 'void _start(void) { for (;;) {} }\n' > start.c
      cc -nostdlib -static-pie -o static-pie start.c
      verify-static-elf --target ${rustTarget} ./static-pie

      # Anchored dynamic tag check must not false-positive on RUNPATH containing "(NEEDED)".
      cc -nostdlib -static-pie -Wl,-rpath,'(NEEDED)' -o static-pie-rpath start.c
      readelf -W -d ./static-pie-rpath | grep -F '(NEEDED)'
      verify-static-elf --target ${rustTarget} ./static-pie-rpath

      reject() {
        if verify-static-elf --target "$1" --receipt rejected.txt -- "$2" >error.log 2>&1; then
          echo "unexpectedly accepted $2 for $1" >&2
          exit 1
        fi
        test ! -e rejected.txt
        for tmpfile in rejected.txt.tmp.*; do
          if [[ -e "$tmpfile" ]]; then
            echo "leftover temp file: $tmpfile" >&2
            exit 1
          fi
        done
        if ! grep -F "$3" error.log; then
          echo "expected '$3' in error.log for $2, got:" >&2
          cat error.log >&2
          exit 1
        fi
      }
      reject ${otherTarget} ./valid-static 'wrong ELF machine'

      printf 'int main(void) { return 0; }\n' > main.c
      cc -o dynamic main.c
      reject ${rustTarget} ./dynamic 'INTERP'

      printf '#include <stdio.h>\nvoid use_libc(void) { puts("fixture"); }\n' > shared.c
      cc -shared -fPIC -o shared.so shared.c
      reject ${rustTarget} ./shared.so 'unsupported ELF type'

      printf 'not an ELF\n' > text
      reject ${rustTarget} ./text 'readelf'
      reject ${unsupported} ./valid-static 'unsupported target'
      reject ${rustTarget} ./missing 'not a regular file'
      reject ${rustTarget} . 'not a regular file'
      ln -s missing broken-link
      reject ${rustTarget} ./broken-link 'not a regular file'
      mkfifo test-fifo
      reject ${rustTarget} ./test-fifo 'not a regular file'

      # Receipt path pre-validation edge cases.
      mkdir existing-dir
      if verify-static-elf --target ${rustTarget} --receipt existing-dir ./valid-static >error.log 2>&1; then
        echo 'unexpectedly accepted directory receipt path' >&2
        exit 1
      fi
      grep -F 'receipt path is a directory' error.log

      if verify-static-elf --target ${rustTarget} --receipt missing-parent/receipt.txt ./valid-static >error.log 2>&1; then
        echo 'unexpectedly accepted missing receipt parent directory' >&2
        exit 1
      fi
      grep -F 'receipt parent directory does not exist' error.log

      if verify-static-elf --target ${rustTarget} --receipt ./valid-static ./valid-static >error.log 2>&1; then
        echo 'unexpectedly allowed receipt to overwrite binary' >&2
        exit 1
      fi
      grep -F 'receipt would replace the binary' error.log

      # Crafted negative ELF fixtures.
      zeros() {
        local n=$1
        local i
        for (( i = 0; i < n; i++ )); do printf '\x00'; done
      }
      # 1. ET_CORE (ELF64, LSB, e_type=4)
      {
        printf '\x7fELF\x02\x01\x01'; zeros 9
        printf '\x04\x00${machineLeHex}\x01\x00\x00\x00'
        zeros 28
        printf '\x40\x00'; zeros 10
      } > crafted-core
      reject ${rustTarget} ./crafted-core 'unsupported ELF type'

      # 2. ET_DYN without PT_DYNAMIC (ELF64, LSB, e_type=3)
      {
        printf '\x7fELF\x02\x01\x01'; zeros 9
        printf '\x03\x00${machineLeHex}\x01\x00\x00\x00'
        zeros 28
        printf '\x40\x00'; zeros 10
      } > crafted-dyn
      reject ${rustTarget} ./crafted-dyn 'unsupported ELF type'

      # 3. ELF32 (EI_CLASS=1, LSB, e_type=2, EM_386=3)
      {
        printf '\x7fELF\x01\x01\x01'; zeros 9
        printf '\x02\x00\x03\x00\x01\x00\x00\x00'
        zeros 16
        printf '\x34\x00'; zeros 10
      } > crafted-elf32
      reject ${rustTarget} ./crafted-elf32 'wrong ELF class'

      # 4. Big-endian MSB (ELF64, EI_DATA=2, e_type=2 BE)
      {
        printf '\x7fELF\x02\x02\x01'; zeros 9
        printf '\x00\x02${machineBeHex}\x00\x00\x00\x01'
        zeros 28
        printf '\x00\x40'; zeros 10
      } > crafted-msb
      reject ${rustTarget} ./crafted-msb 'wrong ELF data encoding'

      # 5. Truncated e_phoff (ELF64, LSB, e_type=2, e_phoff=64, e_phentsize=56, e_phnum=1, no phdr bytes)
      {
        printf '\x7fELF\x02\x01\x01'; zeros 9
        printf '\x02\x00${machineLeHex}\x01\x00\x00\x00'
        zeros 8
        printf '\x40\x00\x00\x00\x00\x00\x00\x00'
        zeros 12
        printf '\x40\x00\x38\x00\x01\x00'; zeros 6
      } > crafted-truncated
      reject ${rustTarget} ./crafted-truncated 'readelf -h reported diagnostics'

      # Real DT_NEEDED dynamic dependency on an executable without INTERP (DT_NEEDED still rejected).
      cc -nostdlib -no-pie -Wl,--no-dynamic-linker -Wl,--no-as-needed -lc -o exec-needed start.c
      reject ${rustTarget} ./exec-needed 'NEEDED'

      for mode in -h -l -d; do
        if FAIL_INSPECTION="$mode" ${brokenVerifier}/bin/verify-static-elf \
          --target ${rustTarget} --receipt rejected.txt ./valid-static 2>error.log; then
          echo "unexpectedly accepted failed readelf $mode" >&2
          exit 1
        fi
        test ! -e rejected.txt
        grep -F "readelf $mode failed" error.log

        if WARN_INSPECTION="$mode" ${brokenVerifier}/bin/verify-static-elf \
          --target ${rustTarget} --receipt rejected.txt ./valid-static 2>error.log; then
          echo "unexpectedly accepted readelf $mode stderr diagnostic" >&2
          exit 1
        fi
        test ! -e rejected.txt
        grep -F "readelf $mode reported diagnostics" error.log
      done

      # mkStaticMuslShell shellHook tests with real stub rustToolchain derivation.
      export STUB_SYSROOT="$PWD/toolchain with spaces"
      linker="$STUB_SYSROOT/lib/rustlib/test-unknown-linux-gnu/bin/rust-lld"

      # Missing rustc in rustToolchain fails cleanly.
      if ( ${missingRustcShell.shellHook}
        exit 0
      ) 2>error.log; then
        echo 'shell hook accepted missing rustc' >&2
        exit 1
      fi
      grep -F 'rustc is missing or not executable' error.log

      # Failing rustc fails cleanly.
      if (
        export STUB_RUSTC_MODE=fail
        ${defaultShell.shellHook}
        exit 0
      ) 2>error.log; then
        echo 'shell hook accepted failing rustc' >&2
        exit 1
      fi

      # rustc -vV without host: line fails cleanly.
      if (
        export STUB_RUSTC_MODE=no-host
        ${defaultShell.shellHook}
        exit 0
      ) 2>error.log; then
        echo 'shell hook accepted rustc -vV without host' >&2
        exit 1
      fi
      grep -F 'rustc -vV did not report a host triple' error.log

      # Missing rust-lld fails cleanly.
      if ( ${defaultShell.shellHook}
        exit 0
      ) 2>error.log; then
        echo 'shell hook accepted missing rust-lld' >&2
        exit 1
      fi
      grep -F 'rust-lld is missing or not executable' error.log

      # Non-executable rust-lld fails cleanly.
      install -D -m644 /dev/null "$linker"
      if ( ${defaultShell.shellHook}
        exit 0
      ) 2>error.log; then
        echo 'shell hook accepted non-executable rust-lld' >&2
        exit 1
      fi
      grep -F 'rust-lld is missing or not executable' error.log

      # Executable rust-lld succeeds for defaultShell (both targets) and armShell (only aarch64).
      chmod 0755 "$linker"
      (
        unset CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER USER_HOOK_RAN
        ${armShell.shellHook}
        test "$CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER" = "$linker"
        test -z "''${CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER+x}"
        test "$USER_HOOK_RAN" = yes
      )
      ${defaultShell.shellHook}
      test "$CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER" = "$linker"
      test "$CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER" = "$linker"
      test "$USER_HOOK_RAN" = yes
      touch "$out"
    ''
