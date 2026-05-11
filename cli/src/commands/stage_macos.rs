//! `rs-harbor stage macos` — produce per-arch and universal Mach-O dist
//! layouts from cargo's per-target outputs, including dSYM bundles.
//!
//! Assumes the consumer compiled with `split-debuginfo = "packed"` so each
//! per-target build dir has a `<binary>.dSYM` next to the binary.

#![allow(clippy::needless_pass_by_value, clippy::unnecessary_trailing_comma)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use clap::Args;

#[derive(Args, Debug)]
pub struct StageMacosArgs {
    /// Cargo binary name (required).
    #[arg(long)]
    pub binary: String,

    /// Extra dylib to copy/lipo (repeatable, e.g. `libsteam_api.dylib`).
    #[arg(long)]
    pub dylib: Vec<String>,

    /// Comma-separated list of architectures to combine.
    #[arg(long, default_value = "x86_64,aarch64")]
    pub archs: String,

    /// Cargo target dir.
    #[arg(long, default_value = "target")]
    pub target_dir: PathBuf,

    /// Dist root (per-arch and universal outputs land here).
    #[arg(long, default_value = "dist")]
    pub dist_dir: PathBuf,

    /// dSYM output subdirectory under `dist_dir`.
    #[arg(long, default_value = "symbols/macos")]
    pub symbols_subdir: PathBuf,

    /// Skip producing per-arch directories.
    #[arg(long)]
    pub skip_per_arch: bool,

    /// Skip producing the universal slice.
    #[arg(long)]
    pub skip_universal: bool,
}

pub fn run(args: StageMacosArgs) -> Result<()> {
    let archs = parse_archs(&args.archs)?;
    verify_inputs(&args, &archs)?;
    fs::create_dir_all(&args.dist_dir)
        .with_context(|| format!("creating dist dir {}", args.dist_dir.display()))?;

    if !args.skip_per_arch {
        stage_per_arch(&args, &archs)?;
    }

    if !args.skip_universal {
        // lipo is only needed for the universal slice; resolve it lazily
        // so callers using --skip-universal don't need it on PATH.
        let lipo = which_lipo()?;
        stage_universal(&args, &archs, &lipo)?;
    }

    println!(
        "rs-harbor stage macos: staged {} for archs {} into {}/",
        args.binary,
        args.archs,
        args.dist_dir.display(),
    );
    Ok(())
}

fn parse_archs(archs: &str) -> Result<Vec<String>> {
    let archs: Vec<String> = archs
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect();
    if archs.is_empty() {
        bail!("--archs must list at least one arch");
    }
    Ok(archs)
}

fn src_for(target_dir: &Path, arch: &str) -> PathBuf {
    target_dir
        .join(format!("{arch}-apple-darwin"))
        .join("release")
}

fn dsym_name(binary: &str) -> String {
    format!("{binary}.dSYM")
}

fn verify_inputs(args: &StageMacosArgs, archs: &[String]) -> Result<()> {
    for arch in archs {
        let src = src_for(&args.target_dir, arch);
        let bin = src.join(&args.binary);
        let dsym = src.join(dsym_name(&args.binary));
        if !bin.is_file() {
            bail!("missing {}", bin.display());
        }
        if !dsym.is_dir() {
            bail!(
                "missing {} (build with split-debuginfo=\"packed\")",
                dsym.display()
            );
        }
    }
    Ok(())
}

fn stage_per_arch(args: &StageMacosArgs, archs: &[String]) -> Result<()> {
    for arch in archs {
        let src = src_for(&args.target_dir, arch);
        let out = args.dist_dir.join(format!("macos-{arch}"));
        fs::create_dir_all(&out)?;
        copy_file(&src.join(&args.binary), &out.join(&args.binary))?;
        for dylib in &args.dylib {
            let candidate = src.join(dylib);
            if candidate.is_file() {
                copy_file(&candidate, &out.join(dylib))?;
            }
        }
        let sym_out = args.dist_dir.join(&args.symbols_subdir).join(arch);
        fs::create_dir_all(&sym_out)?;
        copy_dir_recursive(
            &src.join(dsym_name(&args.binary)),
            &sym_out.join(dsym_name(&args.binary)),
        )?;
    }
    Ok(())
}

fn stage_universal(args: &StageMacosArgs, archs: &[String], lipo: &Path) -> Result<()> {
    let out = args.dist_dir.join("macos");
    fs::create_dir_all(&out)?;

    let bin_inputs: Vec<PathBuf> = archs
        .iter()
        .map(|a| src_for(&args.target_dir, a).join(&args.binary))
        .collect();
    if bin_inputs.len() == 1 {
        copy_file(&bin_inputs[0], &out.join(&args.binary))?;
    } else {
        run_lipo_create(lipo, &bin_inputs, &out.join(&args.binary))?;
    }

    for dylib in &args.dylib {
        let dy_inputs: Vec<PathBuf> = archs
            .iter()
            .map(|a| src_for(&args.target_dir, a).join(dylib))
            .filter(|p| p.is_file())
            .collect();
        match dy_inputs.len() {
            0 => {}
            1 => {
                copy_file(&dy_inputs[0], &out.join(dylib))?;
            }
            _ => run_lipo_create(lipo, &dy_inputs, &out.join(dylib))?,
        }
    }

    let sym_dst = args
        .dist_dir
        .join(&args.symbols_subdir)
        .join(dsym_name(&args.binary));
    let first_src = src_for(&args.target_dir, &archs[0]).join(dsym_name(&args.binary));
    if sym_dst.exists() {
        fs::remove_dir_all(&sym_dst)?;
    }
    if let Some(parent) = sym_dst.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_dir_recursive(&first_src, &sym_dst)?;

    if archs.len() > 1 {
        let dwarf_inputs: Vec<PathBuf> = archs
            .iter()
            .map(|a| {
                src_for(&args.target_dir, a)
                    .join(dsym_name(&args.binary))
                    .join("Contents/Resources/DWARF")
                    .join(&args.binary)
            })
            .collect();
        let dwarf_out = sym_dst.join("Contents/Resources/DWARF").join(&args.binary);
        run_lipo_create(lipo, &dwarf_inputs, &dwarf_out)?;
    }

    Ok(())
}

fn which_lipo() -> Result<PathBuf> {
    for name in ["lipo", "llvm-lipo"] {
        if let Ok(path) = which::which(name) {
            return Ok(path);
        }
    }
    bail!("neither lipo nor llvm-lipo found in PATH")
}

fn run_lipo_create(lipo: &Path, inputs: &[PathBuf], output: &Path) -> Result<()> {
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut cmd = Command::new(lipo);
    cmd.arg("-create");
    for input in inputs {
        cmd.arg(input);
    }
    cmd.arg("-output").arg(output);
    let status = cmd
        .status()
        .with_context(|| format!("running {}", lipo.display()))?;
    if !status.success() {
        bail!("{} -create failed for {}", lipo.display(), output.display(),);
    }
    Ok(())
}

fn copy_file(src: &Path, dst: &Path) -> Result<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dst)
        .with_context(|| format!("copying {} -> {}", src.display(), dst.display()))?;
    Ok(())
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    if !src.is_dir() {
        bail!("source is not a directory: {}", src.display());
    }
    if dst.exists() {
        fs::remove_dir_all(dst)?;
    }
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let dst_path = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_recursive(&entry.path(), &dst_path)?;
        } else if ty.is_symlink() {
            #[cfg(unix)]
            {
                let target = fs::read_link(entry.path())?;
                std::os::unix::fs::symlink(target, &dst_path)?;
            }
            #[cfg(not(unix))]
            {
                fs::copy(entry.path(), &dst_path)?;
            }
        } else {
            fs::copy(entry.path(), &dst_path)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[derive(Parser, Debug)]
    struct TestCli {
        #[command(flatten)]
        args: StageMacosArgs,
    }

    #[test]
    fn parses_minimal_args() {
        let cli = TestCli::try_parse_from(["stage-macos", "--binary", "myapp"]).expect("parses");
        assert_eq!(cli.args.binary, "myapp");
        assert_eq!(cli.args.archs, "x86_64,aarch64");
        assert!(cli.args.dylib.is_empty());
        assert!(!cli.args.skip_per_arch);
        assert!(!cli.args.skip_universal);
    }

    #[test]
    fn parses_repeated_dylibs_and_overrides() {
        let cli = TestCli::try_parse_from([
            "stage-macos",
            "--binary",
            "myapp",
            "--dylib",
            "libfoo.dylib",
            "--dylib",
            "libbar.dylib",
            "--archs",
            "aarch64",
            "--target-dir",
            "build/cargo",
            "--skip-per-arch",
        ])
        .expect("parses");
        assert_eq!(cli.args.dylib, vec!["libfoo.dylib", "libbar.dylib"]);
        assert_eq!(cli.args.archs, "aarch64");
        assert_eq!(cli.args.target_dir, PathBuf::from("build/cargo"));
        assert!(cli.args.skip_per_arch);
    }

    #[test]
    fn parse_archs_strips_whitespace_and_empties() {
        assert_eq!(
            parse_archs("x86_64, aarch64 ,").unwrap(),
            vec!["x86_64", "aarch64"]
        );
    }

    #[test]
    fn parse_archs_rejects_empty_list() {
        assert!(parse_archs(",,").is_err());
    }
}
