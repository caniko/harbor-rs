//! End-to-end CLI smoke tests covering the rs-harbor binary's public
//! interface. Each test invokes the cargo-built binary via `assert_cmd`.

use std::fs;

use assert_cmd::Command;
use tempfile::tempdir;

fn rs_harbor() -> Command {
    Command::cargo_bin("rs-harbor").expect("locate rs-harbor binary")
}

#[test]
fn top_level_help_lists_subcommands() {
    let assert = rs_harbor().arg("--help").assert().success();
    let stdout = String::from_utf8(assert.get_output().stdout.clone()).unwrap();
    assert!(stdout.contains("audit"), "missing audit: {stdout}");
    assert!(stdout.contains("stage"), "missing stage: {stdout}");
    assert!(stdout.contains("steam-runtime"), "missing steam-runtime: {stdout}");
}

#[test]
fn audit_elf_rejects_non_binary_input() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("plain.txt");
    fs::write(&path, b"not an ELF").unwrap();

    let assert = rs_harbor()
        .args(["audit", "elf", "--skip-ldd"])
        .arg(&path)
        .assert()
        .failure();
    let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    assert!(
        stderr.contains("no candidate binaries found"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn audit_pe_rejects_non_binary_directory() {
    let dir = tempdir().unwrap();
    fs::write(dir.path().join("a.txt"), b"abcd").unwrap();
    fs::write(dir.path().join("b.txt"), b"efgh").unwrap();

    let assert = rs_harbor()
        .args(["audit", "pe"])
        .arg(dir.path())
        .assert()
        .failure();
    let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    assert!(
        stderr.contains("no candidate binaries found"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn audit_macho_rejects_non_binary_input() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("plain.bin");
    fs::write(&path, b"\x00\x01\x02\x03").unwrap();

    let assert = rs_harbor()
        .args(["audit", "macho"])
        .arg(&path)
        .assert()
        .failure();
    let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    assert!(
        stderr.contains("no candidate binaries found"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn audit_elf_rejects_missing_input_path() {
    let assert = rs_harbor()
        .args(["audit", "elf", "--skip-ldd", "/no/such/path/exists"])
        .assert()
        .failure();
    let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    assert!(
        stderr.contains("missing path:"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn stage_macos_rejects_empty_target_dir() {
    let target = tempdir().unwrap();
    let dist = tempdir().unwrap();

    let assert = rs_harbor()
        .args(["stage", "macos", "--binary", "myapp"])
        .arg("--target-dir")
        .arg(target.path())
        .arg("--dist-dir")
        .arg(dist.path())
        .assert()
        .failure();
    let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    assert!(
        stderr.contains("missing"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn steam_runtime_exec_fails_when_runner_missing() {
    let assert = rs_harbor()
        .args([
            "steam-runtime",
            "exec",
            "--image",
            "registry.example.com/sniper/sdk",
            "--container-runtime",
            "rs-harbor-no-such-runner",
            "--",
            "true",
        ])
        .assert()
        .failure();
    let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    assert!(
        stderr.contains("container runtime not found"),
        "unexpected stderr: {stderr}"
    );
}

#[test]
fn steam_runtime_exec_requires_command() {
    let assert = rs_harbor()
        .args(["steam-runtime", "exec", "--image", "img"])
        .assert()
        .failure();
    let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    assert!(
        stderr.contains("required") || stderr.contains("<COMMAND>"),
        "unexpected stderr: {stderr}"
    );
}
