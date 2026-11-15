use super::*;
use std::os::unix::fs::symlink;

#[test]
fn pool_classification_and_lock_paths() {
    assert_eq!(classify("cargo", None, "sh"), Some("cargo"));
    assert_eq!(classify("cc", None, "rustc"), Some("linker"));
    assert_eq!(classify("cc", None, "sh"), None);
    assert_eq!(classify("ld.lld", None, "sh"), Some("linker"));
    assert_eq!(
        classify(
            "app-0123456789abcdef",
            Some("/tmp/not-deps/app-0123456789abcdef"),
            "sh"
        ),
        None
    );
    assert_eq!(
        classify(
            "app-0123456789abcdeg",
            Some("/tmp/deps/app-0123456789abcdeg"),
            "sh"
        ),
        None
    );
    assert_eq!(
        classify(
            "app-0123456789abcdef",
            Some("/tmp/deps/app-0123456789abcdef"),
            "sh"
        ),
        Some("test")
    );
    let temp = tempfile::tempdir().unwrap();
    let fd = temp.path().join("fd");
    std::fs::create_dir(&fd).unwrap();
    symlink("/tmp/build/.cargo-build-lock", fd.join("3")).unwrap();
    assert_eq!(build_dir(&fd), Some("/tmp/build".into()));
    let empty = temp.path().join("empty");
    std::fs::create_dir(&empty).unwrap();
    assert_eq!(build_dir(&empty), None);
}

#[test]
fn pool_identical_groups() {
    let groups = identical_groups(&[
        (1, b"cargo\0check\0".to_vec()),
        (2, b"cargo\0check\0".to_vec()),
        (3, b"cargo\0test\0".to_vec()),
    ]);
    assert_eq!(groups, vec![vec![1, 2]]);
    assert!(
        identical_groups(&[
            (1, b"cargo\0check\0".to_vec()),
            (2, b"cargo check\0".to_vec())
        ])
        .is_empty()
    );
}
