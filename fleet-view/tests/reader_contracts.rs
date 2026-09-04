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
    //
    // From the SAME `stdout`, never a second run of the script: `open_min` is elapsed-since-open,
    // recomputed from the clock on every invocation, so two runs straddling a tenth of a minute
    // disagree by 0.1 and the comparison below is a coin toss - and one that can only ever come
    // up on a machine with an open transition, which is the navigator's own fleet and never CI.
    let rows: Vec<model::HistoryRow> =
        serde_json::from_slice(&stdout).expect("the same bytes `read_history` parses");
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

/// The same contract over the health reader: this checkout's own `scripts/fleet-health --json`,
/// deserialized into `FleetHealth`, with the REAL object's key set asserted against the struct's
/// own field names (cb-xhu.4.2).
///
/// The key set and not merely a successful deserialize, because every numeric field carries
/// `#[serde(default)]`: a renamed field would deserialize silently to `None` or `0`, and four
/// green unit cases against invented JSON would all agree with the same misreading (cb-os4).
///
/// A machine that has never run the fleet has no logs and the script exits non-zero there, which
/// is the ORDINARY state rather than a failure: this case ends rather than failing on it. **On CI
/// this therefore proves nothing** — it is the navigator's own machine that runs it for real.
#[test]
fn real_fleet_health_output_matches_the_health_struct() {
    let root = repo_root();
    let paths = ReaderPaths {
        consumer_root: root.clone(),
        shared_root: root.clone(),
        scripts_dir: root.join("scripts"),
    };
    // ONE invocation, deserialized twice - as `FleetHealth` and as an untyped object - rather
    // than `read_health` plus a second run for the raw keys. A second run is another `jq` walk
    // over the same growing logs, and the two can disagree: a rotation between them would make
    // the key comparison a coin toss, which is the History case's own `open_min` reasoning.
    // What `read_health` adds over this call is its argv, cwd and bound, and those are pinned
    // exactly by `readers::tests::read_health_asks_fleet_health_for_json` - the same split the
    // crate already makes between parsing and spawning (cb-x3u).
    let Ok(stdout) = RealCommands.run(
        &paths.scripts_dir.join("fleet-health"),
        &["--json"],
        Some(&paths.consumer_root),
        Duration::from_secs(30),
    ) else {
        // No logs: the script says so on stderr and exits non-zero, and the pane draws no Health
        // section at all. Nothing more to prove here.
        return;
    };
    let health: model::FleetHealth =
        serde_json::from_slice(&stdout).expect("what `read_health` deserializes");
    let raw: serde_json::Map<String, serde_json::Value> =
        serde_json::from_slice(&stdout).expect("the same bytes, untyped");

    let top = [
        "since",
        "until",
        "start_ceiling",
        "long_minutes",
        "starts",
        "passes",
        "running",
        "disarmed",
    ];
    let mut keys: Vec<&str> = raw.keys().map(String::as_str).collect();
    keys.sort_unstable();
    let mut want = top;
    want.sort_unstable();
    assert_eq!(keys, want, "every key of the real object reaches a field of `FleetHealth`");

    let row_keys = |value: &serde_json::Value| -> Vec<String> {
        let mut keys: Vec<String> = value
            .as_array()
            .expect("a section is an array")
            .first()
            .map(|row| row.as_object().expect("a row is an object").keys().cloned().collect())
            .unwrap_or_default();
        keys.sort_unstable();
        keys
    };
    for (section, mut want) in [
        ("starts", vec!["agent", "count", "over"]),
        ("passes", vec!["agent", "holds_beads", "noop", "total"]),
        ("running", vec!["agent", "bead", "long", "minutes", "phase", "state"]),
        ("disarmed", vec!["agent", "detail", "event", "ts"]),
    ] {
        let keys = row_keys(&raw[section]);
        if keys.is_empty() {
            continue; // An empty section on this machine proves nothing about its row shape.
        }
        want.sort_unstable();
        assert_eq!(keys, want, "`{section}`'s row keys reach the struct that reads them");
    }

    // And the values landed where the struct says: the window round-trips, and the display
    // judgement runs over whatever the real fleet actually looks like.
    assert!(!health.since.is_empty() && !health.until.is_empty());
    for finding in model::health_findings(&health) {
        assert!(!finding.text.is_empty());
    }
}
