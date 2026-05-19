use std::process::Command;

use anyhow::Result;

use crate::{FormatMode, ProjectConfig, cargo_workspace_args, run_command};

pub fn run_check(cfg: &ProjectConfig) -> Result<()> {
    run_fmt(cfg, FormatMode::Check)?;
    run_lint(cfg)?;
    run_test(cfg, &[])?;
    run_cargo_build(cfg, false)
}

pub fn run_fmt(cfg: &ProjectConfig, mode: FormatMode) -> Result<()> {
    let mut command = Command::new("cargo");
    command
        .current_dir(&cfg.workspace_root)
        .arg("fmt")
        .arg("--all");
    match mode {
        FormatMode::Check => {
            command.arg("--").arg("--check");
        }
        FormatMode::Write => {}
    }
    run_command(&mut command)
}

pub fn run_lint(cfg: &ProjectConfig) -> Result<()> {
    let mut command = Command::new("cargo");
    command
        .current_dir(&cfg.workspace_root)
        .arg("clippy")
        .args(cargo_workspace_args(cfg))
        .arg("--")
        .arg("-D")
        .arg("warnings");
    run_command(&mut command)
}

pub fn run_test(cfg: &ProjectConfig, extra_args: &[String]) -> Result<()> {
    let mut command = Command::new("cargo");
    command
        .current_dir(&cfg.workspace_root)
        .arg("test")
        .args(cargo_workspace_args(cfg))
        .args(extra_args);
    run_command(&mut command)
}

pub fn run_cargo_build(cfg: &ProjectConfig, release: bool) -> Result<()> {
    let mut command = Command::new("cargo");
    command
        .current_dir(&cfg.workspace_root)
        .arg("build")
        .args(cargo_workspace_args(cfg));
    if release {
        command.arg("--release");
    }
    run_command(&mut command)
}

pub fn run_cargo_package(cfg: &ProjectConfig, package: &str, extra_args: &[String]) -> Result<()> {
    let mut command = Command::new("cargo");
    command
        .current_dir(&cfg.workspace_root)
        .arg("run")
        .arg("-p")
        .arg(package);
    if !extra_args.is_empty() {
        command.arg("--").args(extra_args);
    }
    run_command(&mut command)
}
