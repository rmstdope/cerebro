//! The Rust half of CLAUDE.md's "each impure reader has one case that runs it for real".
//!
//! A pure function tested exhaustively against invented inputs can still be wrong about every
//! real one (cb-os4), so one case runs THIS CHECKOUT's own `scripts/roster` through the real
//! runner and feeds what comes back straight into the pure deriver. It lives in its own
//! integration target rather than in `src/readers.rs` because since cb-x3u the unit tests there
//! start no process at all, and this one must.

use std::path::PathBuf;

use cerebro_tui::model::{self, StateInputs};
use cerebro_tui::{read_roster, ReaderPaths, RealCommands};

/// This repository's root — `fleet-view/`'s parent, which is the same in an integration target.
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fleet-view has a parent directory")
        .to_path_buf()
}

#[test]
fn real_roster_output_feeds_fleet_derivation() {
    let root = repo_root();
    let paths = ReaderPaths {
        consumer_root: root.clone(),
        shared_root: root.clone(),
        scripts_dir: root.join("scripts"),
    };
    let roster =
        read_roster(&paths, &RealCommands).expect("this checkout's scripts/roster must run");
    assert!(!roster.is_empty(), "this repository's roster must declare at least one agent");

    // Pure consumption: feed the impure read straight into the pure deriver, with no state and no
    // processes, and prove every row comes back Dead in roster order - the read produced data the
    // model layer can actually consume, without touching a real process table or state file.
    let rows = model::derive_fleet(&roster, &StateInputs::new(), &[], &root);
    assert_eq!(rows.len(), roster.len());
    for (row, entry) in rows.iter().zip(roster.iter()) {
        assert_eq!(row.name, entry.name);
        assert_eq!(row.state, model::RowState::Dead);
    }
}
