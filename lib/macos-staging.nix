# mkMacosUniversalStager :: { pkgs, ... } -> { stager, packages }
#
# Generic helper for staging cargo's per-target macOS Mach-O outputs into a
# release `dist/` layout with per-arch directories, a universal slice produced
# via `lipo`, and matching dSYM bundles.
#
# Assumes the consumer compiled with `split-debuginfo = "packed"` so that
# rustc emitted a `<binary>.dSYM` next to each per-target binary while the
# rustc link tempdirs were still around; running `dsymutil` after the build
# is too late, since rustc removes those tempdirs at end of link.
{pkgs}: let
  # Cargo profile snippet that switches release builds to packed debug info
  # so rustc produces .dSYM bundles inline on macOS. On non-darwin targets
  # this also produces a `.dwp` file alongside the binary; harmless if
  # ignored.
  cargoMacosPackedDebuginfoSnippet = ''
    [profile.release]
    split-debuginfo = "packed"
  '';

  stager = pkgs.writeShellApplication {
    name = "stage-macos-universal";
    runtimeInputs = with pkgs; [coreutils llvmPackages.llvm];
    text = ''
      binary=""
      archs="x86_64,aarch64"
      target_dir="target"
      dist_dir="dist"
      symbols_subdir="symbols/macos"
      do_per_arch=1
      do_universal=1
      dylibs=()

      usage() {
        cat <<'USAGE'
      Usage: stage-macos-universal --binary NAME [options]

      Options:
        --binary NAME              Cargo binary name (required)
        --dylib NAME               Extra dylib to copy (repeatable, e.g. libsteam_api.dylib)
        --archs LIST               Comma-separated arch list (default: x86_64,aarch64)
        --target-dir DIR           Cargo target dir (default: target)
        --dist-dir DIR             Output dist root (default: dist)
        --symbols-subdir SUBDIR    dSYM output dir under dist (default: symbols/macos)
        --skip-per-arch            Only produce the universal slice
        --skip-universal           Only produce per-arch dirs
        -h, --help                 Show this help

      Layout produced under DIST_DIR:
        macos-<arch>/<binary>
        macos-<arch>/<dylib>...
        macos/<binary>                                (universal lipo)
        macos/<dylib>...                              (universal lipo or single-arch fallback)
        <symbols-subdir>/<arch>/<binary>.dSYM         (per-arch)
        <symbols-subdir>/<binary>.dSYM                (universal DWARF payload)
      USAGE
      }

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --binary) binary="$2"; shift 2 ;;
          --dylib) dylibs+=("$2"); shift 2 ;;
          --archs) archs="$2"; shift 2 ;;
          --target-dir) target_dir="$2"; shift 2 ;;
          --dist-dir) dist_dir="$2"; shift 2 ;;
          --symbols-subdir) symbols_subdir="$2"; shift 2 ;;
          --skip-per-arch) do_per_arch=0; shift ;;
          --skip-universal) do_universal=0; shift ;;
          -h|--help) usage; exit 0 ;;
          *) echo "stage-macos-universal: unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
      done

      if [ -z "$binary" ]; then
        echo "stage-macos-universal: --binary is required" >&2
        usage >&2
        exit 2
      fi

      if ! command -v lipo >/dev/null 2>&1; then
        if command -v llvm-lipo >/dev/null 2>&1; then
          lipo() { llvm-lipo "$@"; }
        else
          echo "stage-macos-universal: neither lipo nor llvm-lipo is available" >&2
          exit 127
        fi
      fi

      IFS=',' read -ra arch_list <<< "$archs"
      if [ "''${#arch_list[@]}" -eq 0 ]; then
        echo "stage-macos-universal: --archs must list at least one arch" >&2
        exit 2
      fi

      src_for() {
        printf '%s/%s-apple-darwin/release' "$target_dir" "$1"
      }

      # Verify per-arch binaries and dSYMs exist.
      for arch in "''${arch_list[@]}"; do
        src="$(src_for "$arch")"
        if [ ! -f "$src/$binary" ]; then
          echo "stage-macos-universal: missing $src/$binary" >&2
          exit 1
        fi
        if [ ! -d "$src/$binary.dSYM" ]; then
          echo "stage-macos-universal: missing $src/$binary.dSYM (build with split-debuginfo=\"packed\")" >&2
          exit 1
        fi
      done

      mkdir -p "$dist_dir"

      if [ "$do_per_arch" -eq 1 ]; then
        for arch in "''${arch_list[@]}"; do
          src="$(src_for "$arch")"
          out="$dist_dir/macos-$arch"
          mkdir -p "$out"
          cp "$src/$binary" "$out/"
          for dylib in "''${dylibs[@]}"; do
            if [ -f "$src/$dylib" ]; then
              cp "$src/$dylib" "$out/"
            fi
          done
          sym_out="$dist_dir/$symbols_subdir/$arch"
          mkdir -p "$sym_out"
          cp -R "$src/$binary.dSYM" "$sym_out/$binary.dSYM"
        done
      fi

      if [ "$do_universal" -eq 1 ]; then
        out="$dist_dir/macos"
        mkdir -p "$out"

        bin_inputs=()
        for arch in "''${arch_list[@]}"; do
          bin_inputs+=("$(src_for "$arch")/$binary")
        done
        if [ "''${#bin_inputs[@]}" -eq 1 ]; then
          cp "''${bin_inputs[0]}" "$out/$binary"
        else
          lipo -create "''${bin_inputs[@]}" -output "$out/$binary"
        fi

        for dylib in "''${dylibs[@]}"; do
          dy_inputs=()
          for arch in "''${arch_list[@]}"; do
            candidate="$(src_for "$arch")/$dylib"
            if [ -f "$candidate" ]; then
              dy_inputs+=("$candidate")
            fi
          done
          if [ "''${#dy_inputs[@]}" -eq 0 ]; then
            continue
          elif [ "''${#dy_inputs[@]}" -eq 1 ]; then
            cp "''${dy_inputs[0]}" "$out/$dylib"
          else
            lipo -create "''${dy_inputs[@]}" -output "$out/$dylib"
          fi
        done

        sym_dst="$dist_dir/$symbols_subdir/$binary.dSYM"
        first_src="$(src_for "''${arch_list[0]}")/$binary.dSYM"
        rm -rf "$sym_dst"
        mkdir -p "$(dirname "$sym_dst")"
        cp -R "$first_src" "$sym_dst"

        dwarf_inputs=()
        for arch in "''${arch_list[@]}"; do
          dwarf_inputs+=("$(src_for "$arch")/$binary.dSYM/Contents/Resources/DWARF/$binary")
        done
        if [ "''${#dwarf_inputs[@]}" -gt 1 ]; then
          lipo -create "''${dwarf_inputs[@]}" -output "$sym_dst/Contents/Resources/DWARF/$binary"
        fi
      fi

      echo "stage-macos-universal: staged $binary for archs $archs into $dist_dir/"
    '';
  };
in {
  inherit cargoMacosPackedDebuginfoSnippet stager;
  packages = {stageMacosUniversal = stager;};
}
