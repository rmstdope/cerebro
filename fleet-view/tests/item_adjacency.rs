use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

use cerebro_tui::item_adjacency::{changed_metadata, items};

#[test]
fn keeps_metadata_with_its_existing_item_when_an_item_is_inserted() {
    let before = r#"
/// Describes the existing item.
#[allow(dead_code)]
fn existing() {}
"#;
    let after = r#"
fn inserted() {}

/// Describes the existing item.
#[allow(dead_code)]
fn existing() {}
"#;

    assert!(changed_metadata(before, after).is_empty());
}

#[test]
fn reports_metadata_reparented_by_an_insertion() {
    let before = r#"
/// Describes the existing item.
#[allow(dead_code)]
fn existing() {}
"#;
    let after = r#"
/// Describes the existing item.
#[allow(dead_code)]
fn inserted() {}
fn existing() {}
"#;

    let changed = changed_metadata(before, after);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].identity, "fn existing");
    assert_eq!(
        changed[0].before.docs,
        vec!["/// Describes the existing item."]
    );
    assert_eq!(changed[0].after.docs, Vec::<String>::new());
    assert_eq!(changed[0].before.attributes, vec!["#[allow(dead_code)]"]);
    assert_eq!(changed[0].after.attributes, Vec::<String>::new());
}

#[test]
fn reports_metadata_reparented_by_a_deletion() {
    let before = r#"
fn before() {}

/// Describes the retained item.
#[allow(dead_code)]
fn retained() {}
"#;
    let after = r#"
/// Describes the retained item.
#[allow(dead_code)]
fn before() {}
"#;

    let changed = changed_metadata(before, after);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].identity, "fn before");
    assert_eq!(changed[0].before.docs, Vec::<String>::new());
    assert_eq!(
        changed[0].after.docs,
        vec!["/// Describes the retained item."]
    );
}

#[test]
fn recognizes_documentation_and_attributes_as_one_item_boundary() {
    let source = r#"
/// Describes a type.
#[derive(Clone, Debug)]
pub struct Example;
"#;

    let found = items(source);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].identity, "struct Example");
    assert_eq!(found[0].docs, vec!["/// Describes a type."]);
    assert_eq!(found[0].attributes, vec!["#[derive(Clone, Debug)]"]);
}

#[test]
fn recognizes_an_implementation_item_boundary() {
    let source = r#"
/// Describes an implementation.
#[allow(dead_code)]
impl Example {
}
"#;

    let found = items(source);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].identity, "impl Example");
    assert_eq!(found[0].docs, vec!["/// Describes an implementation."]);
    assert_eq!(found[0].attributes, vec!["#[allow(dead_code)]"]);
}

#[test]
fn current_rust_diff_keeps_metadata_with_its_existing_items() {
    let root = repo_root();
    let base = git(&root, &["merge-base", "origin/main", "HEAD"]);
    let paths = git(
        &root,
        &[
            "diff",
            "--name-only",
            &format!("{base}...HEAD"),
            "--",
            "fleet-view/src",
        ],
    );

    let mut failures = BTreeMap::new();
    for path in paths.lines().filter(|path| path.ends_with(".rs")) {
        let Some(before) = git_optional(&root, &["show", &format!("{base}:{path}")]) else {
            continue;
        };
        let after = std::fs::read_to_string(root.join(path))
            .unwrap_or_else(|error| panic!("cannot read changed Rust source {path}: {error}"));
        let changed = changed_metadata(&before, &after);
        if !changed.is_empty() {
            failures.insert(path, changed);
        }
    }

    assert!(
        failures.is_empty(),
        "Rust item metadata moved away from an existing declaration: {failures:#?}"
    );
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fleet-view has a parent directory")
        .to_path_buf()
}

fn git(root: &std::path::Path, args: &[&str]) -> String {
    git_optional(root, args).unwrap_or_else(|| {
        panic!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(
                &Command::new("git")
                    .args(args)
                    .current_dir(root)
                    .output()
                    .expect("the failed git command can be run again")
                    .stderr
            )
        )
    })
}

fn git_optional(root: &std::path::Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(root)
        .output()
        .unwrap_or_else(|error| panic!("cannot run git {}: {error}", args.join(" ")));
    output.status.success().then(|| {
        String::from_utf8(output.stdout)
            .unwrap_or_else(|error| {
                panic!("git {} returned non-UTF-8 output: {error}", args.join(" "))
            })
            .trim()
            .to_owned()
    })
}
