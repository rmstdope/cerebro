//! The Edge half of `lifecycle.rs` (cb-0ddn): the cases that read and write real files under a
//! temp dir. `.cerebro/test-architecture.md` keeps files out of the Unit level, so the unit module
//! holds only the decisions and these run here, once, against the crate's public surface.
//!
//! No case asks the machine for the time: an age is an mtime set to a fixed instant and a `now`
//! a fixed distance after it, so the assertion is exact.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use cerebro_tui::lifecycle::{
    clear_stop_flag, delete_state_file, handover_path, read_given, read_handover,
    read_worktree_records, state_file_path, stop_flag_path, stop_flag_set, worktree_records_dir,
    write_stop_flag,
};
use cerebro_tui::model::{AgentKind, RosterEntry, StateObservation};
use cerebro_tui::readers::read_states;
use cerebro_tui::ReaderPaths;

fn paths(root: &Path) -> ReaderPaths {
    ReaderPaths {
        consumer_root: root.join("worktree"),
        shared_root: root.to_path_buf(),
        scripts_dir: root.join("scripts"),
    }
}

/// `.cerebro/state` under the shared root, made: the module's own `state_dir` is private, and the
/// state file's parent is the same directory by construction.
fn make_state_dir(paths: &ReaderPaths) -> PathBuf {
    let dir = state_file_path(paths, "any").parent().unwrap().to_path_buf();
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A fixed instant, 2026-01-01T00:00:00Z.
fn fixed() -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_767_225_600)
}

fn set_mtime(path: &Path, at: SystemTime) {
    File::options().write(true).open(path).unwrap().set_modified(at).unwrap();
}

#[test]
fn worktree_records_are_read_sorted_with_owner_and_age() {
    let dir = tempfile::tempdir().unwrap();
    let paths = ReaderPaths {
        consumer_root: dir.path().to_path_buf(),
        shared_root: dir.path().to_path_buf(),
        scripts_dir: dir.path().to_path_buf(),
    };
    assert!(read_worktree_records(&paths, fixed()).is_empty(), "a missing directory is no records");
    let records = worktree_records_dir(&paths);
    std::fs::create_dir_all(&records).unwrap();
    for (bead, owner) in [("cb-b", "Rogue\n"), ("cb-a", "Gambit\n"), ("cb-c", ""), ("cb-d.123.tmp", "Rogue\n")] {
        std::fs::write(records.join(bead), owner).unwrap();
        set_mtime(&records.join(bead), fixed());
    }
    set_mtime(&records.join("cb-a"), fixed() - Duration::from_secs(90));

    let read = read_worktree_records(&paths, fixed() + Duration::from_secs(10));
    assert_eq!(read.len(), 2, "the empty record and the temp file are skipped: {read:?}");
    assert_eq!((read[0].bead.as_str(), read[0].owner.as_str(), read[0].age_seconds), ("cb-a", "Gambit", 100));
    assert_eq!((read[1].bead.as_str(), read[1].owner.as_str(), read[1].age_seconds), ("cb-b", "Rogue", 10));
}

#[test]
fn a_given_handover_is_read_by_its_second_line() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths(dir.path());
    assert_eq!(read_given(&paths, "Rogue"), None);
    make_state_dir(&paths);
    for (text, expected) in [
        ("cb-x\ngiven\n", Some("cb-x")),
        ("cb-x\n", None),
        ("cb-x\nother\n", None),
        ("", None),
    ] {
        std::fs::write(handover_path(&paths, "Rogue"), text).unwrap();
        assert_eq!(read_given(&paths, "Rogue").as_deref(), expected, "{text:?}");
    }
}

#[test]
fn a_handover_file_is_read_with_its_age() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths(dir.path());
    assert_eq!(read_handover(&paths, "Rogue", fixed()), None);
    make_state_dir(&paths);
    let path = handover_path(&paths, "Rogue");
    std::fs::write(&path, "cb-x\n").unwrap();
    set_mtime(&path, fixed());
    assert_eq!(read_handover(&paths, "Rogue", fixed() + Duration::from_secs(90)), Some(("cb-x".to_string(), 90)));
    // A clock behind the file is age zero, not a negative age or no answer.
    assert_eq!(read_handover(&paths, "Rogue", fixed() - Duration::from_secs(5)), Some(("cb-x".to_string(), 0)));
    std::fs::write(&path, "").unwrap();
    assert_eq!(read_handover(&paths, "Rogue", fixed()), None, "an empty handover is none");
}

#[test]
fn a_stop_flag_is_an_empty_file_under_the_shared_root() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths(dir.path());

    let path = stop_flag_path(&paths, "Cyclops");
    assert!(path.ends_with(".cerebro/state/Cyclops.stop"), "{}", path.display());
    assert!(path.starts_with(dir.path()));

    assert!(!stop_flag_set(&paths, "Cyclops"));
    write_stop_flag(&paths, "Cyclops").unwrap();
    assert!(stop_flag_set(&paths, "Cyclops"));
    assert_eq!(std::fs::read(&path).unwrap(), Vec::<u8>::new());

    clear_stop_flag(&paths, "Cyclops").unwrap();
    assert!(!stop_flag_set(&paths, "Cyclops"));
}

#[test]
fn clearing_a_flag_that_is_not_there_is_success() {
    let dir = tempfile::tempdir().unwrap();
    clear_stop_flag(&paths(dir.path()), "Nobody").unwrap();
}

#[test]
fn deleting_a_state_file_that_is_not_there_is_success() {
    let dir = tempfile::tempdir().unwrap();
    delete_state_file(&paths(dir.path()), "Nobody").unwrap();
}

#[test]
fn a_state_file_is_deleted_when_it_is_there() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths(dir.path());
    make_state_dir(&paths);
    let path = state_file_path(&paths, "Cyclops");
    std::fs::write(&path, "{}").unwrap();
    delete_state_file(&paths, "Cyclops").unwrap();
    assert!(!path.exists());
}

/// `readers::read_states` must open the path `lifecycle` builds, not a second spelling of it.
///
/// Asserted by writing a file at `state_file_path` and checking the reader parsed it: a
/// re-inlined path in `readers.rs` would read nothing and answer `Missing`, which is what a test
/// that only re-derived the literal could never see.
#[test]
fn the_state_file_path_is_the_one_the_readers_use() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths(dir.path());
    let path = state_file_path(&paths, "Xavier");
    assert_eq!(path, paths.shared_root.join(".cerebro/state").join("Xavier.state.json"));

    make_state_dir(&paths);
    std::fs::write(&path, r#"{"state":"working","bead":"cb-1","since":"2026-01-01T00:00:00Z","pid":1}"#)
        .unwrap();

    let roster = vec![RosterEntry {
        name: "Xavier".to_string(),
        role: "planner".to_string(),
        kind: AgentKind::Interactive,
    }];
    match read_states(&paths, &roster).get("Xavier") {
        Some(StateObservation::Parsed(record)) => assert_eq!(record.bead.as_deref(), Some("cb-1")),
        other => panic!("read_states did not read the file state_file_path names: {other:?}"),
    }
}
