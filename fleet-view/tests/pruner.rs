//! The prune watcher's own contract, in its own process.
//!
//! Here rather than in `src/pruner.rs`'s `mod tests` for `command_runner.rs`'s reason: this is a
//! test that STARTS a process, so it runs a **tracked fixture** under `tests/fixtures/` that no
//! test ever writes. A file no test writes cannot be `ETXTBSY`, which is what four patches in
//! `src/readers.rs` had been working around before cb-x3u moved the spawning out.
//!
//! What it proves that no unit test can: that exactly one watcher runs, that the child is really
//! killed when the `Pruner` drops, and that it is really REAPED. A pruner that leaked a `--watch`
//! loop per view would be invisible to every unit test and obvious on the navigator's machine a
//! week later.

use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use cerebro_tui::probe;
use cerebro_tui::pruner::Pruner;

/// One of the tracked fixture scripts beside this file.
fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)
}

/// Is PID a process at all, zombie or otherwise?
fn pid_exists(pid: u32) -> bool {
    let table = Command::new("ps").args(["-axo", "pid="]).output().expect("ps runs");
    String::from_utf8_lossy(&table.stdout)
        .lines()
        .any(|line| line.trim() == pid.to_string())
}

/// Wait for PID to be gone entirely - not merely signalled, and not a zombie of this process.
fn assert_gone(pid: u32, what: &str) {
    // Ten seconds rather than `probe::POLL_BOUND`: `ps` is a fork per attempt, and a loaded
    // runner reaps more slowly than it answers.
    assert!(
        probe::wait_until(Duration::from_secs(10), || !pid_exists(pid)),
        "{what} is still there as {pid}"
    );
}

#[test]
fn pruner_keeps_one_watcher_and_kills_it_on_drop() {
    let mut pruner = Pruner::new();
    pruner.start_command(Command::new(fixture("watching"))).expect("the watcher spawns");
    assert!(pruner.live(), "a spawned watcher is live");
    let pid = pruner.pid().expect("a pid");
    assert!(pid_exists(pid));

    drop(pruner);
    assert_gone(pid, "the watcher");
}

#[test]
fn a_watcher_that_exits_is_not_live_and_names_its_status() {
    let mut pruner = Pruner::new();
    pruner.start_command(Command::new(fixture("boom"))).expect("it spawns");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while pruner.live() {
        assert!(std::time::Instant::now() < deadline, "the fixture never exited");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(pruner.take_exit().as_deref(), Some("exit status 3"));
    assert_eq!(pruner.take_exit(), None, "the cause is taken once");
}

#[test]
fn a_stopped_watcher_is_reaped() {
    let mut pruner = Pruner::new();
    pruner.start_command(Command::new(fixture("watching"))).expect("it spawns");
    let pid = pruner.pid().expect("a pid");
    pruner.stop();
    assert!(!pruner.live(), "nothing is live after a stop");
    // Idempotent: a second stop is a no-op, not a panic and not a second kill.
    pruner.stop();
    assert_gone(pid, "the stopped watcher");
}

/// A missing script is a submodule that was never initialised - the cause the navigator needs
/// to see, in the operating system's own words.
#[test]
fn a_program_that_is_not_there_is_a_refusal_with_its_reason() {
    let dir = tempfile::tempdir().expect("a temp dir");
    let mut pruner = Pruner::new();
    let error = pruner
        .start_command(Command::new(dir.path().join("prune-worktrees.sh")))
        .expect_err("a program that is not there cannot spawn");
    assert!(error.contains("No such file or directory"), "{error}");
    assert!(!pruner.live());
}
