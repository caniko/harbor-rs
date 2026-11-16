# Reproducible before/after compile-time measurement for any harbor-rs
# consumer: one generated `.cargo/config.toml` per bench variant, timed with
# hyperfine inside a memory-capped systemd user unit.
{
  pkgs,
  mkCargoConfig,
}: let
  inherit (pkgs) lib;

  # One variant per knob that could become a default. `none` is today's crane
  # dev shell without a generated config; everything else differs from
  # `current` in a single knob (plus its fixed environment).
  variantsFor = channel: let
    mk = args: (mkCargoConfig ({inherit pkgs channel;} // args)).configText;
    nightlyOnly = lib.optional (channel == "nightly");
    # `wild` owns its target table, because a second [target.<triple>] table
    # would not parse. It repeats `current`'s codegen flags on purpose: only
    # the linker differs, or the run measures two changes at once.
    wildFlags =
      ["-C" "link-arg=--ld-path=wild"]
      ++ nightlyOnly "-Zshare-generics=y"
      ++ nightlyOnly "-Zthreads=8";
    quote = f: "\"${f}\"";
  in
    {
      none = "";
      current = mk {};
      lld = mk {enableMold = null;};
      wild = mk {
        enableMold = false;
        crossTargets = [];
        extraConfig = ''
          [target.x86_64-unknown-linux-gnu]
          linker = "clang"
          rustflags = [${lib.concatMapStringsSep ", " quote wildFlags}]
        '';
      };
      buildopt = mk {devBuildOverrideOptLevel = 3;};
      incremental = mk {};
      aslived = mk {};
    }
    // lib.optionalAttrs (channel == "nightly") {
      threads0 = mk {parallelFrontendThreads = 0;};
      nothreads = mk {enableParallelFrontend = false;};
      nohint = mk {enableHintMostlyUnused = false;};
      cranelift = mk {enableCranelift = true;};
    };

  variants = lib.genAttrs ["nightly" "stable"] variantsFor;

  variantConfigs = pkgs.linkFarm "cargo-config-variants" (lib.concatLists (lib.mapAttrsToList
    (channel: byVariant:
      lib.mapAttrsToList (variant: text: {
        name = "${channel}/${variant}.toml";
        path = pkgs.writeText "cargo-config-${channel}-${variant}.toml" text;
      })
      byVariant)
    variants));

  package = pkgs.writeShellApplication {
    name = "harbor-compile-bench";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.hyperfine
      pkgs.jq
      pkgs.systemd
      pkgs.wild
    ];
    text = ''
      variants_root=${variantConfigs}
      # Generated configs name `clang` and `-fuse-ld=mold`; plain crane shells
      # lack both. Append, so the consumer's own cc/clang still win.
      export PATH="$PATH:${lib.makeBinPath [pkgs.clang pkgs.mold]}"

      usage() {
        cat <<'USAGE'
      Usage: harbor-compile-bench [options]

      Runs the compile-bench scenarios for one consumer against every variant's
      generated .cargo/config.toml. Run it from the consumer's dev shell.

        --edit-file PATH   file the one-line edit touches (required for S3/S5)
        --variants a,b     variants to run (default: every variant on this channel)
        --scenarios S1,S3  scenarios to run (default: S1,S3)
        --memory-max SIZE  systemd MemoryMax for each unit (default: min(24G, free - 4G))
        --out DIR          result directory (default: ./compile-bench-results)
        --list-variants    print the variant table and exit

      Scenarios: S1 clean build, S2 no-op rebuild, S3 build after the edit,
      S4 clean check, S5 check after the edit. Results land in
      $out/<variant>/<scenario>.json (hyperfine), .peak-bytes and .sh (the run).
      USAGE
      }

      die() {
        echo "harbor-compile-bench: $*" >&2
        exit 1
      }

      edit_file=""
      variant_list=""
      scenario_list="S1,S3"
      memory_max=""
      out_dir="$PWD/compile-bench-results"

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --edit-file) edit_file="''${2:?--edit-file needs a path}"; shift 2 ;;
          --variants) variant_list="''${2:?--variants needs a list}"; shift 2 ;;
          --scenarios) scenario_list="''${2:?--scenarios needs a list}"; shift 2 ;;
          --memory-max) memory_max="''${2:?--memory-max needs a size}"; shift 2 ;;
          --out) out_dir="''${2:?--out needs a directory}"; shift 2 ;;
          --list-variants) list_variants=1; shift ;;
          -h | --help) usage; exit 0 ;;
          *) die "unknown argument: $1 (see --help)" ;;
        esac
      done

      if [ -n "''${list_variants:-}" ]; then
        printf '%-8s %s\n' CHANNEL VARIANT
        for dir in "$variants_root"/*; do
          for file in "$dir"/*.toml; do
            printf '%-8s %s\n' "$(basename "$dir")" "$(basename "$file" .toml)"
          done
        done
        exit 0
      fi

      command -v rustc >/dev/null || die "rustc is not on PATH; run this from the consumer's dev shell"
      channel=stable
      case "$(rustc -V)" in
        *nightly*) channel=nightly ;;
      esac

      case ",$scenario_list," in
        *,S3,* | *,S5,*) [ -n "$edit_file" ] || die "--edit-file is required for S3 and S5" ;;
      esac

      if [ -n "$variant_list" ]; then
        IFS=, read -r -a selected <<<"$variant_list"
      else
        selected=()
        for file in "$variants_root/$channel"/*.toml; do
          selected+=("$(basename "$file" .toml)")
        done
      fi
      IFS=, read -r -a scenarios <<<"$scenario_list"
      for variant in "''${selected[@]}"; do
        [ -f "$variants_root/$channel/$variant.toml" ] \
          || die "variant '$variant' does not exist on channel $channel (see --list-variants)"
      done

      if [ -z "$memory_max" ]; then
        available_gib=$(($(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1048576))
        size_gib=$((available_gib - 4))
        if [ "$size_gib" -gt 24 ]; then size_gib=24; fi
        if [ "$size_gib" -lt 12 ]; then
          die "only ''${size_gib}G available for a benchmark unit; need at least 12G (see --memory-max)"
        fi
        memory_max="''${size_gib}G"
      fi

      work=$(mktemp -d)
      backup=""
      if [ -n "$edit_file" ]; then
        backup="$work/edit-backup"
        cp "$edit_file" "$backup"
      fi
      unit=""
      cleanup() {
        if [ -n "$unit" ]; then systemctl --user stop "$unit" 2>/dev/null || true; fi
        if [ -n "$backup" ]; then cp -f "$backup" "$edit_file"; fi
        rm -rf "$work"
      }
      trap cleanup EXIT

      mkdir -p "$out_dir"
      export -p > "$work/env.bash"
      if git rev-parse HEAD >/dev/null 2>&1; then
        git rev-parse HEAD > "$out_dir/rev"
      fi
      { rustc -vV; cargo -V; } > "$out_dir/toolchain"
      echo "channel=$channel variants=''${selected[*]} scenarios=$scenario_list memory=$memory_max out=$out_dir"

      for variant in "''${selected[@]}"; do
        variant_home="$work/home-$variant"
        target_dir="$work/target-$variant"
        mkdir -p "$variant_home" "$out_dir/$variant"
        # `none` keeps Cargo's defaults; every other variant installs its file.
        if [ -s "$variants_root/$channel/$variant.toml" ]; then
          cp "$variants_root/$channel/$variant.toml" "$variant_home/config.toml"
        fi
        for dir in registry git; do
          if [ -d "''${CARGO_HOME:-$HOME/.cargo}/$dir" ] && [ ! -e "$variant_home/$dir" ]; then
            ln -s "''${CARGO_HOME:-$HOME/.cargo}/$dir" "$variant_home/$dir"
          fi
        done

        for scenario in "''${scenarios[@]}"; do
          case "$scenario" in
            S1) runs=3; warmup=0; command="cargo build --workspace"; prepare="rm -rf $target_dir" ;;
            S2) runs=5; warmup=1; command="cargo build --workspace"; prepare=":" ;;
            S3) runs=5; warmup=1; command="cargo build --workspace"
                prepare="printf \"\\n// harbor-compile-bench edit\\n\" >> \"$edit_file\"" ;;
            S4) runs=3; warmup=0; command="cargo check --workspace"; prepare="rm -rf $target_dir" ;;
            S5) runs=5; warmup=1; command="cargo check --workspace"
                prepare="printf \"\\n// harbor-compile-bench edit\\n\" >> \"$edit_file\"" ;;
            *) die "unknown scenario: $scenario" ;;
          esac

          runner="$out_dir/$variant/$scenario.sh"
          {
            echo '#!${pkgs.bash}/bin/bash'
            echo 'set -a'
            echo "source '$work/env.bash'"
            echo 'set +a'
            echo "export CARGO_HOME='$variant_home'"
            echo "export CARGO_TARGET_DIR='$target_dir'"
            echo 'export CARGO_BUILD_JOBS=16'
            echo 'unset CARGO_BUILD_BUILD_DIR'
            case "$variant" in
              incremental) echo 'unset CARGO_INCREMENTAL'; echo 'unset RUSTC_WRAPPER' ;;
              aslived) ;;
              *) echo 'export CARGO_INCREMENTAL=0'; echo 'unset RUSTC_WRAPPER' ;;
            esac
            echo "hyperfine --shell=bash --runs $runs --warmup $warmup \\"
            echo "  --prepare '$prepare' --export-json '$out_dir/$variant/$scenario.json' \\"
            echo "  '$command'"
            echo "status=\$?"
            echo "cgroup=\$(sed -n 's/^0:://p' /proc/self/cgroup)"
            echo "peak=\$(cat \"/sys/fs/cgroup\$cgroup/memory.peak\" 2>/dev/null) && echo \"\$peak\" > '$out_dir/$variant/$scenario.peak-bytes'"
            echo "exit \$status"
          } > "$runner"
          chmod +x "$runner"

          echo "==> $variant $scenario ($runs runs, memory max $memory_max)"
          unit="harbor-compile-bench-$$-$variant-$scenario"
          systemd-run --user --wait --collect --quiet --pipe --unit "$unit" \
            -p "MemoryMax=$memory_max" -p MemorySwapMax=0 -p MemoryAccounting=yes \
            --working-directory "$PWD" "$runner" </dev/null
          unit=""

          jq -r --arg variant "$variant" --arg scenario "$scenario" \
            '"\($variant) \($scenario) mean=\(.results[0].mean)s stddev=\(.results[0].stddev)s"' \
            "$out_dir/$variant/$scenario.json"
        done
      done
    '';
  };
in {
  inherit variants variantConfigs package;
}
