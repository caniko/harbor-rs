use std::fs;

use harbor_xtask::{TestRunner, load_harbor_ci_config};
use tempfile::tempdir;

#[test]
fn loads_workspace_harbor_ci_metadata() {
    let temp = tempdir().expect("temporary directory");
    fs::write(
        temp.path().join("Cargo.toml"),
        r#"[workspace]
members = []

[workspace.metadata.harbor-ci]
locked = false
all-features = false
test-runner = "nextest"
docs = true
audit = true
deny = true
package = true
"#,
    )
    .unwrap();

    let config = load_harbor_ci_config(temp.path()).expect("harbor-ci config");
    assert!(!config.locked);
    assert!(!config.all_features);
    assert_eq!(config.test_runner, TestRunner::Nextest);
    assert!(config.docs && config.audit && config.deny && config.package);
}
