//! The Rust half of CLAUDE.md's "each impure reader has one case that runs it for real".
//!
//! A pure function tested exhaustively against invented inputs can still be wrong about every
//! real one (cb-os4), so one case runs THIS CHECKOUT's own `scripts/roster` through the real
//! runner and feeds what comes back straight into the pure deriver. It lives in its own
//! integration target rather than in `src/readers.rs` because since cb-x3u the unit tests there
//! start no process at all, and this one must.

use std::path::PathBuf;
use std::time::Duration;

use cerebro_tui::model::{self, StateInputs};
use cerebro_tui::readers::{read_history, CommandRunner};
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

/// The same contract over the History reader: this checkout's own `scripts/fleet-history
/// --summary`, deserialized into `HistoryRow`, with every row fed to `model::history_line`.
///
/// The one case that would have caught a field name that never matched — four green unit cases
/// against invented JSON would all have agreed with the same misreading. **Every numeric field
/// carries `#[serde(default)]`, so a renamed one deserializes silently to `None` rather than
/// failing**: the key set of the script's own first object is therefore asserted against the
/// struct's field names directly, which is the only check a rename cannot pass.
///
/// A machine that has never run the fleet has no transitions log and the script exits 1 there,
/// which is the ORDINARY state rather than a failure — CI is exactly such a machine — so a
/// refusal ends the case rather than failing it. What that costs is stated plainly: on CI this
/// proves nothing, and it is the developer's own run and the one below that carry it.
#[test]
fn real_fleet_history_output_names_the_fields_history_row_reads() {
    let root = repo_root();
    let paths = ReaderPaths {
        consumer_root: root.clone(),
        shared_root: root.clone(),
        scripts_dir: root.join("scripts"),
    };
    // The RAW bytes, so the key set can be compared: `read_history` has already thrown the
    // unknown keys away, which is precisely the defect this guards.
    let Ok(stdout) = RealCommands.run(
        &paths.scripts_dir.join("fleet-history"),
        &["--summary"],
        Some(&paths.consumer_root),
        Duration::from_secs(30),
    ) else {
        return;
    };
    let raw: Vec<serde_json::Map<String, serde_json::Value>> =
        serde_json::from_slice(&stdout).expect("--summary is a JSON array of objects");
    let Some(first) = raw.first() else { return };
    let mut keys: Vec<&str> = first.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        ["agent", "count", "max_min", "median_min", "open_min", "state", "total_min"],
        "every key `HistoryRow` reads, and no key it silently drops"
    );

    // And the other direction: a number the script printed reaches the field that reads it. The
    // list above pins the SCRIPT's key set; this pins the STRUCT's, so a `rename` on either side
    // is red rather than a silent `None`.
    let rows = read_history(&paths, &RealCommands).expect("the script answered a moment ago");
    for (raw, row) in raw.iter().zip(rows.iter()) {
        for (key, value) in raw {
            let Some(number) = value.as_f64() else { continue };
            let read = match key.as_str() {
                "count" => Some(row.count as f64),
                "total_min" => row.total_min,
                "median_min" => row.median_min,
                "max_min" => row.max_min,
                "open_min" => row.open_min,
                _ => continue,
            };
            assert_eq!(read, Some(number), "{key} reached the field that reads it");
        }
    }
}

/// The same contract over the History reader: this checkout's own `scripts/fleet-history
/// --summary`, deserialized into `HistoryRow`, with every row fed to `model::history_line`.
///
/// The one case that would have caught a field name that never matched — four green unit cases
/// against invented JSON would all have agreed with the same misreading.
///
/// A machine that has never run the fleet has no transitions log and the script exits 1 there,
/// which is the ORDINARY state rather than a failure: this case accepts either answer, and
/// asserts about the rows only when there are some. CI is exactly such a machine.
#[test]
fn real_fleet_history_output_feeds_the_history_line() {
    let root = repo_root();
    let paths = ReaderPaths {
        consumer_root: root.clone(),
        shared_root: root.clone(),
        scripts_dir: root.join("scripts"),
    };
    let Ok(rows) = read_history(&paths, &RealCommands) else {
        // No `.cerebro/state/transitions.jsonl`: the script says so on stderr and exits 1, and
        // the pane draws no History section at all. Nothing more to prove here.
        return;
    };
    for row in &rows {
        assert!(!row.agent.is_empty(), "every summary row names an agent");
        assert!(!row.state.is_empty(), "and a state");
        // Pure consumption: whatever the script actually emits, the line function accepts it.
        match model::history_line(row) {
            Some((text, long)) => {
                assert!(text.starts_with("  "), "{text:?}");
                assert!(text.contains(&row.agent), "{text:?}");
                assert!(text.contains(&row.state), "{text:?}");
                assert!(!long || text.contains("- long, median"), "{text:?}");
            }
            // `open_min` is null: this agent is not in this state at the moment, and has no line.
            None => assert!(row.open_min.is_none(), "{row:?}"),
        }
    }
}
