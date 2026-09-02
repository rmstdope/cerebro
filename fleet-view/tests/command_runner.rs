//! The real command runner's own contract, in its own process.
//!
//! This is the ONE place in this crate's tests where a process is started, and the fixtures it
//! runs are **tracked files under `tests/fixtures/`** that no test ever writes. That is the whole
//! point of the target: `ETXTBSY` ("Text file busy") can only arise while some process holds a
//! writable descriptor on the file being `exec`ed, and nothing here ever opens one. Four separate
//! patches in `src/readers.rs` were working around exactly that (`c25701f`, `4e70768`, `dd3066d`,
//! `fa52613`) before the spawning moved here.
//!
//! A new case that needs a program to behave a particular way gets a NEW TRACKED FIXTURE. It does
//! not get a helper that writes an executable — that helper is what this bead deleted.

use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use cerebro_tui::{CommandRunner, ReadError, RealCommands};

/// One of the tracked fixture scripts beside this file.
fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// Every zombie child of this process, as pids.
fn zombie_children() -> Vec<String> {
    let mine = std::process::id().to_string();
    let table = Command::new("ps").args(["-axo", "pid=,stat=,ppid="]).output().unwrap();
    String::from_utf8_lossy(&table.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next().unwrap_or("");
            let stat = fields.next().unwrap_or("");
            let ppid = fields.next().unwrap_or("");
            (stat.starts_with('Z') && ppid == mine).then(|| pid.to_string())
        })
        .collect()
}

/// Assert that no zombie child of this process OUTLIVES a short wait.
///
/// A single snapshot was the fragile version, and it went red the moment two more spawning cases
/// joined the suite (cb-kcs.4.1): cargo runs these tests as threads of one process, and EVERY
/// spawn anywhere leaves its child a zombie for the window between the child's exit and its own
/// `wait` returning — so a snapshot taken during somebody else's window fails a case that leaked
/// nothing. Somebody else's zombie is reaped within milliseconds; a leaked one never is.
fn assert_no_leaked_zombie(what: &str) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let zombies = zombie_children();
        if zombies.is_empty() {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{what} was left as a zombie: {zombies:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A child that never returns is killed, reaped and reported — never waited on forever, and never
/// left behind as a zombie. The bound is one second rather than the five the screen uses.
#[test]
fn a_child_that_never_returns_is_killed_and_reaped() {
    let started = std::time::Instant::now();
    let err = RealCommands
        .run(&fixture("slow"), &[], None, Duration::from_secs(1))
        .unwrap_err();
    let elapsed = started.elapsed();

    match err {
        ReadError::Timeout { seconds, source } => {
            assert_eq!(seconds, 1);
            assert!(source.ends_with("slow"), "the failure names the program: {source}");
        }
        other => panic!("expected Timeout, got {other:?}"),
    }
    assert!(elapsed < Duration::from_secs(10), "it waited for the child to finish: {elapsed:?}");

    assert_no_leaked_zombie("the timed-out child");
}

/// A child that writes more than one pipe buffer on BOTH streams and then exits is read whole:
/// both pipes are drained while it runs, so a large roster or process table is not a deadlock.
#[test]
fn both_pipes_are_drained_while_the_child_runs() {
    let stdout = RealCommands
        .run(&fixture("loud"), &[], None, Duration::from_secs(60))
        .unwrap();
    assert_eq!(stdout.len(), 200_000);
}

/// A non-zero exit is a failure carrying its status and what the program said.
#[test]
fn a_non_zero_exit_carries_status_and_stderr() {
    let err = RealCommands
        .run(&fixture("boom"), &[], None, Duration::from_secs(60))
        .unwrap_err();
    match err {
        ReadError::Exit { status, stderr, .. } => {
            assert_eq!(status, Some(3));
            assert!(stderr.contains("boom: it failed"), "{stderr}");
        }
        other => panic!("expected Exit, got {other:?}"),
    }
}

/// A refusal is still an answer: `scripts/fleet-supervisor` exits 2 and prints the raw offending
/// value on STDOUT, which the header has to name — so `ReadError::Exit` carries stdout too.
#[test]
fn a_refusal_carries_stdout_as_well() {
    let err = RealCommands
        .run(&fixture("refusing"), &[], None, Duration::from_secs(60))
        .unwrap_err();
    match err {
        ReadError::Exit { status, stdout, stderr, .. } => {
            assert_eq!(status, Some(2));
            assert_eq!(stdout, "raw-value\n");
            assert!(stderr.contains("refusing"), "{stderr}");
        }
        other => panic!("expected Exit, got {other:?}"),
    }
}

/// A program that is not there is a spawn failure, not an empty answer.
#[test]
fn a_program_that_does_not_exist_is_a_spawn_failure() {
    let err = RealCommands
        .run(&PathBuf::from("/does/not/exist/ps"), &[], None, Duration::from_secs(60))
        .unwrap_err();
    assert!(matches!(err, ReadError::Spawn { .. }), "expected Spawn, got {err:?}");
}

/// The runner hands bytes back; decoding them is the reader's own job, which is what lets a
/// reader turn invalid UTF-8 into its own `ReadError::Invalid`.
#[test]
fn stdout_is_returned_as_raw_bytes() {
    let stdout: Vec<u8> = RealCommands
        .run(&fixture("loud"), &[], None, Duration::from_secs(60))
        .unwrap();
    assert!(stdout.iter().all(|b| *b == b'x'));
}

/// The arguments and the working directory reach the child.
#[test]
fn arguments_and_the_working_directory_reach_the_child() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let stdout = RealCommands
        .run(
            &PathBuf::from("/bin/sh"),
            &["-c", "printf '%s\\n' \"$PWD\" \"$1\"", "sh", "an-argument"],
            Some(&dir),
            Duration::from_secs(60),
        )
        .unwrap();
    let text = String::from_utf8(stdout).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines[0].ends_with("tests/fixtures"), "the cwd reached the child: {lines:?}");
    assert_eq!(lines[1], "an-argument");
}
