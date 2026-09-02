//! The `prune-worktrees.sh --watch` child this view keeps running beside itself.
//!
//! The port of `cerebro--prune-action`, `cerebro--start-prune-process`,
//! `cerebro--ensure-prune-watcher` and `cerebro--kill-prune-watcher`
//! (`emacs/cerebro.el:6309-6366`), and of the tick that calls them (`emacs/cerebro.el:6446-6450`):
//! a view that may act keeps exactly one watcher alive, and one that may not kills the watcher it
//! has. Two `--watch` loops must never run at once - the script holds no lock, so two would race
//! each other's `git worktree remove` rather than merely duplicating work.
//!
//! A module of its own rather than a corner of `lifecycle`, for the reason `session` is one: it
//! owns a CHILD PROCESS with a lifetime longer than any call, and `lifecycle` is pure decisions
//! plus short writes. `main` owns the `Pruner` exactly as it owns the `SessionHost`.

use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::readers::ReaderPaths;

/// How often the watcher is checked on. Five seconds, the cadence `cerebro--tick` checks it on.
pub const CHECK_INTERVAL: Duration = Duration::from_secs(5);

/// How often a failure is said out loud again while it persists. Ten minutes - the watcher's own
/// `WATCH_SECONDS`, so the line comes back exactly as often as a sweep would have happened.
///
/// The gate is unconditional and the clock is never reset by a healthy pass: a watcher that cannot
/// be started at all is retried every `CHECK_INTERVAL`, so any rule that reset on recovery would
/// strobe for a child that dies a few seconds after each start. The cost is that a second,
/// DIFFERENT fault inside ten minutes is silent on screen - and it is not lost, because
/// `Logger::error` dedupes on the message and writes a line for every distinct one.
pub const COMPLAINT_INTERVAL: Duration = Duration::from_secs(600);

/// What to do about the watcher. Pure.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PruneAction {
    /// No watcher is live and this view may act: start one.
    Start,
    /// One is already running and should stay running.
    Leave,
    /// This view may not act: kill whatever it has.
    Stop,
}

/// `cerebro--prune-action` widened by one input: elisp answers `start`/`already-running` and its
/// caller does the `may-act-p` branch outside (`emacs/cerebro.el:6446-6450`). Here both live in one
/// total function, because there is no `if` in the loop for a reader to miss.
pub fn prune_action(live: bool, may_act: bool) -> PruneAction {
    match (may_act, live) {
        (false, _) => PruneAction::Stop,
        (true, true) => PruneAction::Leave,
        (true, false) => PruneAction::Start,
    }
}

/// The red header line, verbatim from the surface the navigator approved for cb-kcs.5.2.
pub fn failure_notice(cause: &str) -> String {
    format!("Worktree pruning stopped: {cause}")
}

/// `exit status 2`, or `killed by signal 9` - what `failure_notice` is given for a watcher that
/// spawned and then ended.
///
/// NOT `ExitStatus`'s own `Display`, which is `exit status: 2` on Unix and would put two colons in
/// the approved line.
pub fn exit_cause(status: std::process::ExitStatus) -> String {
    match status.code() {
        Some(code) => format!("exit status {code}"),
        None => {
            #[cfg(unix)]
            {
                use std::os::unix::process::ExitStatusExt;
                if let Some(signal) = status.signal() {
                    return format!("killed by signal {signal}");
                }
            }
            "ended for an unknown reason".to_string()
        }
    }
}

/// The watcher, and the two clocks that keep it from being noisy.
#[derive(Debug, Default)]
pub struct Pruner {
    child: Option<Child>,
    last_check: Option<Instant>,
    last_complaint: Option<Instant>,
    /// The cause of the death `live` observed, until something takes it.
    exit: Option<String>,
}

impl Pruner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether `CHECK_INTERVAL` has passed; records AT when it answers true.
    pub fn due(&mut self, at: Instant) -> bool {
        let due = match self.last_check {
            None => true,
            Some(last) => at.duration_since(last) >= CHECK_INTERVAL,
        };
        if due {
            self.last_check = Some(at);
        }
        due
    }

    /// Is a watcher running? REAPS FIRST, so a child that has exited is not live and its status is
    /// kept for `take_exit`. Without the `try_wait` the dead watcher is a zombie and this would
    /// answer true for ever.
    pub fn live(&mut self) -> bool {
        let Some(child) = self.child.as_mut() else { return false };
        match child.try_wait() {
            Ok(Some(status)) => {
                self.exit = Some(exit_cause(status));
                self.child = None;
                false
            }
            Ok(None) => true,
            // A child whose status cannot be read is not one to keep waiting on.
            Err(error) => {
                self.exit = Some(error.to_string());
                self.child = None;
                false
            }
        }
    }

    /// The cause of the death `live` observed, once. `None` if it did not die.
    pub fn take_exit(&mut self) -> Option<String> {
        self.exit.take()
    }

    /// Spawn `<scripts_dir>/prune-worktrees.sh --watch` in the consumer root.
    pub fn start(&mut self, paths: &ReaderPaths) -> Result<(), String> {
        let mut command = Command::new(paths.scripts_dir.join("prune-worktrees.sh"));
        command.arg("--watch").current_dir(&paths.consumer_root);
        self.start_command(command)
    }

    /// The test seam, `Session::spawn_command`'s shape: everything above but the command.
    ///
    /// `stdout` and `stderr` are NULL, not piped. Emacs sends them to a hidden buffer nobody
    /// reads; a pipe nobody drains is a deadlock, and this child runs for the life of the process.
    pub fn start_command(&mut self, mut command: Command) -> Result<(), String> {
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        match command.spawn() {
            Ok(child) => {
                self.child = Some(child);
                Ok(())
            }
            Err(error) => Err(error.to_string()),
        }
    }

    /// Kill the watcher and reap it. Idempotent.
    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Whether a failure may be said out loud now; records AT when it answers true.
    pub fn should_complain(&mut self, at: Instant) -> bool {
        let due = match self.last_complaint {
            None => true,
            Some(last) => at.duration_since(last) >= COMPLAINT_INTERVAL,
        };
        if due {
            self.last_complaint = Some(at);
        }
        due
    }

    /// The child's pid, for a test that needs to look for it afterwards.
    pub fn pid(&self) -> Option<u32> {
        self.child.as_ref().map(Child::id)
    }
}

/// A `--watch` loop that outlives the view is a `git worktree remove` nobody is watching -
/// `Session`'s own reason for its `Drop`. The one cleanup a `?`, an early return and a panic all
/// respect.
impl Drop for Pruner {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_view_that_may_act_keeps_one_watcher() {
        assert_eq!(prune_action(false, true), PruneAction::Start);
        assert_eq!(prune_action(true, true), PruneAction::Leave);
        // A drain is not a failure, and a read-only view keeps none at all.
        assert_eq!(prune_action(false, false), PruneAction::Stop);
        assert_eq!(prune_action(true, false), PruneAction::Stop);
    }

    #[test]
    fn the_failure_line_is_the_approved_one() {
        assert_eq!(
            failure_notice("No such file or directory (os error 2)"),
            "Worktree pruning stopped: No such file or directory (os error 2)"
        );
        assert_eq!(failure_notice("exit status 2"), "Worktree pruning stopped: exit status 2");
    }

    /// `ExitStatus`'s own `Display` is `exit status: 2`, which would put two colons in the
    /// approved line.
    #[test]
    fn an_exit_status_reads_without_a_second_colon() {
        let status = std::process::Command::new("/bin/sh")
            .args(["-c", "exit 2"])
            .status()
            .expect("a shell");
        assert_eq!(exit_cause(status), "exit status 2");
        assert_eq!(failure_notice(&exit_cause(status)).matches(':').count(), 1);
    }

    #[test]
    fn a_persisting_failure_is_said_once_in_ten_minutes() {
        let mut pruner = Pruner::new();
        let start = Instant::now();
        assert!(pruner.should_complain(start), "the first failure is always said");
        assert!(!pruner.should_complain(start + Duration::from_secs(599)));
        assert!(pruner.should_complain(start + Duration::from_secs(600)));
        // And not again until another ten minutes, even though every check between failed.
        for second in 601..1200 {
            assert!(
                !pruner.should_complain(start + Duration::from_secs(second)),
                "said again at {second}s"
            );
        }
        assert!(pruner.should_complain(start + Duration::from_secs(1200)));
    }

    #[test]
    fn the_check_is_due_every_five_seconds() {
        let mut pruner = Pruner::new();
        let start = Instant::now();
        assert!(pruner.due(start), "the first tick is always due");
        assert!(!pruner.due(start + Duration::from_secs(4)));
        assert!(pruner.due(start + Duration::from_secs(5)));
    }
}
