use std::path::PathBuf;

use harbor_xtask::{
    CargoCiOptions, CargoWorkspace, CheckProfile, ProjectConfig, TestRunner, cargo_ci_plan,
};

fn config() -> ProjectConfig {
    ProjectConfig {
        workspace_root: PathBuf::from("/tmp/project"),
        cargo_workspace: CargoWorkspace {
            packages: Vec::new(),
            all_features: false,
        },
        spec_file: None,
        copr: None,
        docs: Vec::new(),
        nix_packages: Vec::new(),
    }
}

#[test]
fn default_plan_has_stable_cargo_order_and_arguments() {
    let plan = cargo_ci_plan(
        &config(),
        CheckProfile::Default,
        CargoCiOptions {
            locked: true,
            all_features: true,
            ..CargoCiOptions::default()
        },
    );
    let commands = plan.steps();
    assert_eq!(commands.len(), 4);
    assert_eq!(commands[0].args, ["fmt", "--all", "--", "--check"]);
    assert_eq!(
        commands[1].args,
        [
            "clippy",
            "--workspace",
            "--all-features",
            "--locked",
            "--all-targets",
            "--",
            "-D",
            "warnings"
        ]
    );
    assert_eq!(
        commands[2].args,
        ["test", "--workspace", "--all-features", "--locked"]
    );
    assert_eq!(
        commands[3].args,
        ["build", "--workspace", "--all-features", "--locked"]
    );
}

#[test]
fn full_plan_adds_configured_quality_steps() {
    let plan = cargo_ci_plan(
        &config(),
        CheckProfile::Full,
        CargoCiOptions {
            test_runner: TestRunner::Nextest,
            docs: true,
            audit: true,
            deny: true,
            package: true,
            ..CargoCiOptions::default()
        },
    );
    assert_eq!(plan.steps().len(), 8);
    assert_eq!(plan.steps()[2].args[0..2], ["nextest", "run"]);
    assert_eq!(plan.steps()[7].args[0..2], ["package", "--workspace"]);
}
