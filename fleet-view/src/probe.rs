//! Test support for the one thing this crate's tests cannot fake: another process.
//!
//! Unconditionally `pub`, on `readers::testing`'s precedent and for its reason - `main.rs` and
//! the integration targets are separate crates and cannot see a `#[cfg(test)]` item here.

use std::net::{Ipv4Addr, SocketAddr, TcpListener};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use ratatui::text::Line;

use crate::session::SessionView;

/// How often a wait re-attempts.
///
/// Not a knob: no case in this crate asserts anything about the interval, only about the bound.
/// The three intervals the hand-rolled copies used (10ms, 20ms, 50ms) were each picked by hand
/// and never measured; the tightest of them is the one that makes every wait finish soonest and
/// none of them flakier.
pub const POLL_INTERVAL: Duration = Duration::from_millis(10);

/// The bound a peer-process assertion in this crate gets unless it says otherwise - the same five
/// seconds `readers` bounds every child it spawns at.
pub const POLL_BOUND: Duration = Duration::from_secs(5);

/// Poll ATTEMPT until it yields a value, for at most BOUND. `None` means the bound was spent.
///
/// This is the rule cb-kcs.1, cb-kcs.5.3 and cb-kcs.5.4 each paid a flake for, in a signature
/// rather than in a comment beside a loop: **a peer process's side effect is polled with a bound,
/// never read once**, and **a readiness signal says it has STARTED, never that it has finished the
/// thing you are about to assert on** - so a readiness wait and the assertion's own wait are two
/// calls to this, never one.
///
/// ATTEMPT is made once BEFORE any sleep, so a zero bound still attempts exactly once. The
/// hand-rolled `while Instant::now() < deadline` shape did not: with a spent bound it ran the body
/// no times at all and reported a failure it had never looked for.
///
/// ATTEMPT may have side effects, and several callers depend on that - `SessionHost::sync` is what
/// moves a child's bytes into the parser, so the observation and the progress are the same call.
pub fn wait_for<T>(bound: Duration, mut attempt: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + bound;
    loop {
        if let Some(value) = attempt() {
            return Some(value);
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return None;
        }
        std::thread::sleep(POLL_INTERVAL.min(left));
    }
}

/// The predicate case: `true` if READY held within BOUND.
pub fn wait_until(bound: Duration, mut ready: impl FnMut() -> bool) -> bool {
    wait_for(bound, || ready().then_some(())).is_some()
}

/// A loopback address that was free a moment ago: bound on port 0, read back, released.
///
/// There IS a window between finding it and taking it - anything on the machine may bind it in
/// between - so every caller retries rather than treating one refusal as final. That race is the
/// cb-kcs.1 flake, and it is a property of the machine rather than of this function.
pub fn free_endpoint() -> SocketAddr {
    let probe = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind probe");
    probe.local_addr().expect("probe addr")
}

/// A `Line`'s spans, joined - one string per line.
pub fn text_of(lines: &[Line<'static>]) -> Vec<String> {
    lines
        .iter()
        .map(|line| line.spans.iter().map(|span| span.content.as_ref()).collect::<String>())
        .collect()
}

/// A `SessionView`'s screen as plain strings, one per line.
///
/// **`Live` only; every other view is empty**, which is what all four hand-rolled copies did and
/// is load-bearing rather than incidental: a case waiting for a nudge to reach a child must not be
/// satisfied by finding those words in the retained transcript of a child that has died.
pub fn view_text(view: &SessionView) -> Vec<String> {
    match view {
        SessionView::Live { lines, .. } => text_of(lines),
        _ => Vec::new(),
    }
}

/// This checkout's `emacs/` directory, for `emacs -L`.
///
/// `CARGO_MANIFEST_DIR` is `fleet-view/` for every target in this package - the library, the
/// binary and the integration targets alike - so it resolves the same from all three.
pub fn emacs_lisp_dir() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../emacs"))
}

fn which_emacs() -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join("emacs")).find(|candidate| {
        // Executable, not merely present: a file named `emacs` that cannot be run would fail a
        // case for a reason that has nothing to do with what it is proving.
        std::fs::metadata(candidate)
            .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    })
}

/// A real `emacs --batch` this crate spawned, killed and reaped when it drops.
///
/// `Drop` is what makes the kill unconditional: it runs on an unwind, an early return and a
/// normal end alike, which is why the cases using this need no `catch_unwind` and report a panic
/// at the failing assertion rather than at `resume_unwind`.
pub struct RealEmacs {
    child: std::process::Child,
}

impl RealEmacs {
    /// Spawn `emacs --batch -L <emacs_lisp_dir> [-l LOAD] --eval PROGRAM`, with both pipes null.
    ///
    /// `None` means emacs is not on `PATH` and the calling case must `return` without asserting
    /// anything. Before answering `None` it FAILS when `CI` is set, naming PROOF: the Rust job
    /// installs Emacs, so a missing one there is a broken setup step, and skipping would turn the
    /// named proof into a green no-op.
    ///
    /// Both pipes are null deliberately. `emacs --batch` buffers its stdout, so a `princ` before a
    /// `sleep-for` arrives when the process ends - which is how one of these cases came to take
    /// two minutes to fail. A case that needs a readiness signal reports it through a FILE.
    pub fn batch(proof: &str, load: Option<&str>, program: &str) -> Option<Self> {
        let Some(emacs) = which_emacs() else {
            // CI installs Emacs in the Rust job FOR these cases. If it is missing there, the setup
            // step has broken and this would otherwise pass as a green no-op.
            assert!(
                std::env::var_os("CI").is_none(),
                "emacs is not on PATH and CI is set: the Rust job's setup-emacs step has broken, \
                 and skipping here would turn {proof} into a green no-op. (If you exported CI by \
                 hand on a machine without Emacs, that is what this is telling you.)"
            );
            eprintln!("emacs is not on PATH: skipping {proof}");
            return None;
        };
        let mut command = std::process::Command::new(emacs);
        command.arg("--batch").arg("-L").arg(emacs_lisp_dir());
        if let Some(load) = load {
            command.arg("-l").arg(load);
        }
        let child = command
            .arg("--eval")
            .arg(program)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn the Emacs child");
        Some(Self { child })
    }

    /// The child's pid, for a case that must watch it die.
    pub fn pid(&self) -> u32 {
        self.child.id()
    }
}

impl Drop for RealEmacs {
    fn drop(&mut self) {
        // Reaped, not merely signalled: the kernel closes a listener as the process is reaped, and
        // a case that takes the lease back depends on that having happened.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::text::Span;

    /// Is this pid still running? `kill -0`, which needs no crate and no unsafe block. Private to
    /// this module: `supervisor.rs`'s `alive` and `tests/pruner.rs`'s `pid_exists` are deliberately
    /// NOT this - `kill -0` succeeds on a zombie, and the pruner's case is about one being reaped.
    fn pid_alive(pid: u32) -> bool {
        std::process::Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    #[test]
    fn a_real_emacs_is_killed_and_reaped_when_it_drops() {
        let Some(emacs) = RealEmacs::batch("probe's own drop proof", None, "(sleep-for 120)")
        else {
            return;
        };
        let pid = emacs.pid();
        assert!(
            wait_until(POLL_BOUND, || pid_alive(pid)),
            "the child was spawned and is running"
        );
        drop(emacs);
        assert!(wait_until(POLL_BOUND, || !pid_alive(pid)), "Drop kills and reaps the child");
    }

    #[test]
    fn an_attempt_is_made_once_even_with_a_spent_bound() {
        let mut calls = 0;
        let got = wait_for(Duration::ZERO, || {
            calls += 1;
            Some(7)
        });
        assert_eq!(got, Some(7));
        assert_eq!(calls, 1, "a zero bound still attempts exactly once");
    }

    #[test]
    fn it_stops_at_the_first_yield() {
        let mut calls = 0;
        let got = wait_for(POLL_BOUND, || {
            calls += 1;
            (calls == 3).then_some(calls)
        });
        assert_eq!(got, Some(3));
        assert_eq!(calls, 3, "no attempt after the one that yielded");
    }

    #[test]
    fn a_bound_that_is_never_satisfied_answers_none() {
        let started = Instant::now();
        let got = wait_for(Duration::from_millis(50), || None::<()>);
        assert_eq!(got, None);
        assert!(started.elapsed() < Duration::from_secs(1), "the bound is respected");
    }

    #[test]
    fn wait_until_is_the_predicate_case() {
        let mut calls = 0;
        assert!(wait_until(POLL_BOUND, || {
            calls += 1;
            calls == 2
        }));
        assert!(!wait_until(Duration::from_millis(50), || false));
    }

    #[test]
    fn free_endpoint_answers_a_bindable_loopback_address() {
        let addr = free_endpoint();
        assert_eq!(addr.ip(), std::net::IpAddr::V4(Ipv4Addr::LOCALHOST));
        assert_ne!(addr.port(), 0, "the port was read back after the probe bound it");
        TcpListener::bind(addr).expect("the address a probe just released is bindable");
    }

    #[test]
    fn text_of_joins_a_lines_spans() {
        let lines = vec![
            Line::from(vec![Span::raw("ab"), Span::raw("cd")]),
            Line::from("ef"),
        ];
        assert_eq!(text_of(&lines), vec!["abcd".to_string(), "ef".to_string()]);
    }

    #[test]
    fn view_text_renders_a_live_screen() {
        let view = SessionView::Live {
            lines: vec![Line::from(vec![Span::raw("x"), Span::raw("y")]), Line::from("z")],
            cursor: (0, 0),
        };
        assert_eq!(view_text(&view), vec!["xy".to_string(), "z".to_string()]);
    }

    #[test]
    fn only_a_live_view_has_text() {
        use chrono::Utc;
        use std::sync::Arc;
        let lines = Arc::new(vec![Line::from("dead child said this")]);
        for view in [
            SessionView::None,
            SessionView::Starting,
            SessionView::Ended { lines: Arc::clone(&lines), at: Utc::now() },
            SessionView::Refused { lines: Arc::clone(&lines), at: Utc::now() },
        ] {
            assert_eq!(
                view_text(&view),
                Vec::<String>::new(),
                "a dead child's transcript must not satisfy a wait for something to reach a live one"
            );
        }
    }
}
