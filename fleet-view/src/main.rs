//! `cerebro-tui`: the standalone fleet screen, started by
//! `.claude/cerebro/scripts/cerebro-tui` and never by hand.
//!
//! It owns five things and nothing else: the terminal, the event loop, the workers that keep the
//! readers off the drawing thread, the sessions it hosts (cb-kcs.2.2), and - since cb-kcs.1 - the
//! supervision lease, through `SupervisorController`. Since cb-kcs.2.3 `s`, `f` and `k` reach the
//! fleet through `route_key` and `lifecycle_key`: it starts an agent, writes and clears a stop
//! flag, and kills a session it hosts, each refused with a visible line unless the lease says it
//! may. It writes no state file - `scripts/agent-state` is the one author of those, and this view
//! only ever DELETES one whose session it is ending. Since cb-kcs.5.1 it DOES write a bead: `x`
//! on a sweep finding runs the exact `bd` the confirmation named, and then `bd dolt push`. That
//! one write is deliberately outside the lease - the board is shared, and a view that may start
//! nothing may still close a delivered bead. Holding the lease is what makes
//! any of it legal; a view that does not hold it is exactly the reader it always was. The
//! controller owns the lease because ownership must end when the process does, and `TerminalGuard` beside it is the proof that a `Drop` is the only cleanup
//! a `?`, an early return and a panic all respect.
//!
//! Everything it needs to find the fleet is handed to it by the launcher in the environment. It
//! deliberately does not resolve a consumer root of its own: `scripts/consumer-root` is the one
//! place that question is answered, and a second answer in Rust would be a second answer.

use std::collections::BTreeMap;
use std::io::{self, Stdout, Write};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use crossterm::event::{
    DisableBracketedPaste, EnableBracketedPaste, Event, KeyCode, KeyEvent, KeyEventKind,
};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::{execute, ExecutableCommand};
use ratatui::backend::{Backend, CrosstermBackend};
use ratatui::layout::Rect;
use ratatui::Terminal;

use cerebro_tui::app::{
    self, App, AppAction, FleetWorker, GhWorker, SupervisorWorker, SweepWorker, WorkWorker,
};
use cerebro_tui::lifecycle;
use cerebro_tui::log::{self, Logger};
use cerebro_tui::model::{AgentKind, RosterEntry, RowState};
use cerebro_tui::readers::{
    self, CommandRunner, Commands, Programs, ReadError, ReaderPaths, RealCommands,
};
use cerebro_tui::supervisor::{
    reconcile_supervision, AcquireError, ReadOnlyReason, ReconcileAction, SupervisionMode,
    SupervisorKind, SupervisorLease,
};
use cerebro_tui::session::{self, SessionHost};
use cerebro_tui::triggers::{self, StartLedger, TriggerFacts};
use cerebro_tui::ui;

/// How long the loop waits for a keystroke before drawing again. Short enough that an elapsed
/// time on screen is never more than this out of date, long enough that an idle screen is not a
/// busy loop.
const POLL_INTERVAL: Duration = Duration::from_millis(200);

/// The variables the launcher exports, in the order a missing one is reported. Fixed on purpose:
/// a navigator who started this by hand under `cargo run` gets the same first line every time,
/// naming the launcher that would have set them all.
const REQUIRED: [&str; 4] = [
    "CEREBRO_CONSUMER_ROOT",
    "CEREBRO_CONSUMER_SHARED_ROOT",
    "CEREBRO_CONSUMER_MOUNT",
    "CEREBRO_SCRIPTS",
];

fn main() -> ExitCode {
    let paths = match reader_paths(|name| std::env::var(name).ok()) {
        Ok(paths) => paths,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };

    match start(paths) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            // The guard has already restored the terminal by the time this prints: it is dropped
            // inside `start`, whatever went wrong in there.
            eprintln!("cerebro-tui: {error}");
            ExitCode::FAILURE
        }
    }
}

/// The launcher's environment, turned into the roots the readers use.
///
/// An empty value is missing: `export CEREBRO_SCRIPTS=` is the same accident as never exporting
/// it, and an empty path would send `roster` looking in the process's cwd.
fn reader_paths(read: impl Fn(&str) -> Option<String>) -> Result<ReaderPaths, String> {
    let mut values = Vec::new();
    for name in REQUIRED {
        match read(name) {
            Some(value) if !value.is_empty() => values.push(value),
            _ => {
                return Err(format!(
                    "cerebro-tui: {name} is missing - start it with .claude/cerebro/scripts/cerebro-tui"
                ))
            }
        }
    }
    Ok(ReaderPaths {
        consumer_root: values[0].clone().into(),
        // The SHARED root, not the enclosing one: state files live in the checkout every worktree
        // shares, and it is what `scripts/launch` roots every session's marker sentence at.
        shared_root: values[1].clone().into(),
        scripts_dir: values[3].clone().into(),
    })
}


/// The lease, and the one place this binary decides what to do with it (cb-kcs.1).
///
/// It owns the `SupervisorLease` because ownership must end when the process does: dropping this
/// releases the listener, and `TerminalGuard` already proves that a `Drop` is the only cleanup an
/// early return, a `?` and a panic all respect.
///
/// The endpoint, identity and record are read ONCE, before the terminal is entered. They are
/// facts about the checkout rather than about this run, and reading them here is what lets a
/// process configured for the TUI own the checkout on its first frame instead of flashing
/// "Emacs owns supervision" on its way there.
struct SupervisorController {
    lease: Option<SupervisorLease>,
    endpoint: Option<SocketAddr>,
    identity: Option<String>,
    record: Option<PathBuf>,
    /// This child hosts no agent sessions - `cb-kcs.2` is what gives it PTYs to count. The drain
    /// rule is written and tested now so that bead adds a number here rather than a rule.
    hosted_sessions: usize,
    last_request: Option<Instant>,
    /// The last ownership diagnostic worth a navigator's attention, printed to stderr when the
    /// screen exits.
    ///
    /// The header says the short sentence the navigator approved; the detail - which endpoint,
    /// which other checkout, which record was malformed - has to go SOMEWHERE, or an endpoint
    /// collision between two checkouts is undiagnosable by design. It cannot go on the screen
    /// (an absolute path in a status line is unreadable) and it cannot be printed while the
    /// alternate screen is up, so it is kept and printed on the way out.
    diagnostic: Option<String>,
}

impl SupervisorController {
    /// Read what cannot change, and answer what this process is before the first frame.
    fn new(paths: &ReaderPaths, commands: &dyn CommandRunner) -> Self {
        Self {
            lease: None,
            endpoint: readers::read_supervisor_endpoint(paths, commands).ok(),
            identity: readers::read_supervisor_identity(paths, commands).ok(),
            record: readers::read_supervisor_record(paths, commands).ok(),
            hosted_sessions: 0,
            last_request: None,
            diagnostic: None,
        }
    }

    /// Keep the latest ownership fault, for the exit line.
    ///
    /// One slot, not a log: the screen exits once, and the parting line should be what was wrong
    /// when it exited rather than the first thing that ever went wrong.
    fn note_diagnostic(&mut self, message: String) {
        self.diagnostic = Some(message);
    }

    /// Forget it. A fault that resolved must not be the parting line of an hour-long session -
    /// Emacs re-arms on recovery the same way, and the two sides are meant to say the same thing.
    fn clear_diagnostic(&mut self) {
        self.diagnostic = None;
    }

    /// What to print on the way out, if anything.
    fn diagnostic(&self) -> Option<&str> {
        self.diagnostic.as_deref()
    }

    /// Is a fresh reading of the declaration due? Five seconds, the fleet pane's own cadence: a
    /// declaration that moved supervision has to be obeyed about as fast as a state file that
    /// moved an agent.
    fn due(&self, now: Instant) -> bool {
        match self.last_request {
            None => true,
            Some(last) => now.duration_since(last) >= SUPERVISION_INTERVAL,
        }
    }

    fn requested(&mut self, now: Instant) {
        self.last_request = Some(now);
    }

    /// Apply one answer from the worker: decide, act on the lease, and return what to display.
    ///
    /// A reader that could not run at all gets `DeclarationUnreadable` - its own reason, which
    /// says nothing about who holds the lease, because this process may well be holding it.
    /// Rounding it to `emacs` would be the fail-open this whole bead exists to refuse.
    fn apply(&mut self, answer: Result<Result<SupervisorKind, String>, ReadError>) -> SupervisionMode {
        let configured = match answer {
            Ok(configured) => configured,
            // A reader that could not run is read-only, and KEEPS whatever lease it holds. The
            // failures here are transient - a five-second timeout, a fork that failed, a
            // non-answer - and releasing on one would hand the checkout to an observer over a
            // subprocess hiccup, which from cb-kcs.2 means moving live sessions. It is the same
            // rule the table already states for a declaration that is not ours: never release out
            // from under something. Emacs does not release here either.
            Err(error) => {
                // Its OWN reason, not a lock error: this process may be holding the lease while
                // this happens, and "the lease is held by another process" would be false twice.
                self.note_diagnostic(format!("cannot read fleet_supervisor: {error}"));
                return SupervisionMode::ReadOnly(ReadOnlyReason::DeclarationUnreadable(
                    error.to_string(),
                ));
            }
        };
        let (mode, action) = reconcile_supervision(
            SupervisorKind::Tui,
            configured,
            self.lease.is_some(),
            self.hosted_sessions,
        );
        let mode = match action {
            ReconcileAction::Keep => mode,
            ReconcileAction::Release => {
                self.release();
                mode
            }
            ReconcileAction::Acquire => self.acquire(),
        };
        if !Self::keeps_diagnostic(&mode) {
            self.clear_diagnostic();
        }
        mode
    }

    /// Is this mode one in which the exit diagnostic is still worth printing?
    ///
    /// Everything else is healthy - supervising, draining, an honest owner, a declaration that
    /// names the other view - and a fault that resolved must not be the parting line of an
    /// hour-long session. Emacs re-arms on exactly the same rule
    /// (`cerebro--report-supervision-error`), and the two sides are meant to say the same thing.
    fn keeps_diagnostic(mode: &SupervisionMode) -> bool {
        matches!(
            mode,
            SupervisionMode::ReadOnly(ReadOnlyReason::LockError(_))
                | SupervisionMode::ReadOnly(ReadOnlyReason::DeclarationUnreadable(_))
        )
    }

    fn acquire(&mut self) -> SupervisionMode {
        let (Some(endpoint), Some(identity), Some(record)) =
            (self.endpoint, self.identity.as_ref(), self.record.as_ref())
        else {
            // No diagnostic: this is the DOCUMENTED degrade path, not a fault. A consumer whose
            // submodule predates `scripts/fleet-supervisor` has no lease for anybody to hold, and
            // Emacs says nothing in exactly this case ("the behaviour every consumer had before
            // ownership existed"). Printing here would make the new output channel loudest where
            // nothing is wrong.
            return SupervisionMode::ReadOnly(ReadOnlyReason::DeclarationUnreadable(
                "cannot locate the supervision lease".to_string(),
            ));
        };
        match SupervisorLease::try_acquire(endpoint, record, identity, SupervisorKind::Tui) {
            Ok(lease) => {
                self.lease = Some(lease);
                SupervisionMode::Supervising
            }
            // An honest live owner is the ordinary case and says everything on the header.
            Err(AcquireError::OwnedBy(kind)) => {
                SupervisionMode::ReadOnly(ReadOnlyReason::OwnedBy(kind))
            }
            // Everything else is a diagnosis the navigator cannot make from the header alone -
            // an endpoint collision naming another checkout above all, which the whole
            // two-checksum port design rests on being VISIBLE.
            Err(other) => {
                self.note_diagnostic(format!("supervision lease at {endpoint}: {other}"));
                SupervisionMode::ReadOnly(ReadOnlyReason::LockError(other.to_string()))
            }
        }
    }

    fn release(&mut self) {
        self.lease = None;
    }
}

/// How often the declaration is re-read. The fleet pane's cadence, for the same reason.
const SUPERVISION_INTERVAL: Duration = Duration::from_secs(5);

/// Anything that can end the loop: a terminal that stopped working, an event source that failed.
/// Boxed because the terminal's own error type is the backend's, and the test backend's is
/// `Infallible` - a concrete type here would make the loop untestable without a real terminal.
type Fatal = Box<dyn std::error::Error>;

fn start(paths: ReaderPaths) -> Result<(), Fatal> {
    // One worker per pane: a thirty-second `bd` behind a five-second `ps` would make each wait
    // for the other, which is the one thing two independently refreshed panes must not do.
    // The one runner this process ever uses. Every reader takes it as a parameter (cb-x3u), so
    // that a test about parsing answers from a table instead of starting a process.
    let commands: Commands = Arc::new(RealCommands);
    let fleet_worker = FleetWorker::spawn(paths.clone(), Programs::default(), commands.clone());
    let work_worker = WorkWorker::spawn(paths.clone(), Programs::default(), commands.clone());
    // A fourth thread for `gh`, on its own ten-minute cadence: three network calls behind a
    // rate limit would otherwise freeze the screen, keys and all (cb-kcs.4.3).
    let gh_worker = GhWorker::spawn(paths.clone(), Programs::default(), commands.clone());
    // A fifth thread for the six sweep scripts, on their own ten-minute cadence: three of them
    // fetch from origin (cb-kcs.5.1).
    let sweep_worker = SweepWorker::spawn(paths.clone(), Programs::default(), commands.clone());
    let supervisor_worker = SupervisorWorker::spawn(paths.clone(), commands.clone());
    // Ownership before the first frame: the one blocking read this binary allows itself, and the
    // reason a TUI that owns the checkout never shows an "Emacs owns supervision" frame first.
    let mut controller = SupervisorController::new(&paths, commands.as_ref());
    let initial = controller.apply(readers::read_configured_supervisor(&paths, commands.as_ref()));
    let enabled = initial.may_end();
    let mut app = App::with_supervision(initial);
    let mut ledger = StartLedger::default();
    // Created here and enabled from the mode this frame is drawn with: a logger that defaulted to
    // enabled would have one window - construction to that call - in which a read-only view
    // writes. The root is passed in and never resolved by the logger itself.
    let mut logger = Logger::new(&paths.shared_root);
    logger.set_enabled(enabled);

    // BEFORE the terminal guard, so it is dropped AFTER it: a child killed on the way out must
    // not be killed while the alternate screen is still up.
    let mut host = SessionHost::default();

    // Raw mode and the alternate screen are entered HERE and nowhere else, under a guard whose
    // `Drop` leaves them. A sequence of cleanup calls after the loop is skipped by `?`, by an
    // early return and by a panic - each of which has left somebody's terminal in raw mode with
    // no echo and no prompt.
    // The roster's own declaration, performed once as the view comes up, and only by a view that
    // may act on this checkout. The spacing is read here too - once, in the one place, and only
    // when it will be used: a fork per role per five-second tick is not a thing this view may do.
    let mut spacing = BTreeMap::new();
    if app.supervision.may_supervise() {
        let (declared, complaints) =
            readers::read_role_spacing(&paths, &SPACED_ROLES, commands.as_ref());
        spacing = declared;
        if let Some(notice) =
            arm_and_autostart(
                &mut app,
                &mut host,
                &mut ledger,
                &mut logger,
                &paths,
                commands.as_ref(),
                &complaints,
                Utc::now(),
            )
        {
            app.set_notice(notice);
        }
    }

    let mut guard = TerminalGuard::enter(CrosstermTerminal)?;
    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal = Terminal::new(backend)?;
    let mut events = CrosstermEvents;
    let result = run(
        &mut terminal,
        &mut events,
        &mut app,
        &fleet_worker,
        &work_worker,
        &gh_worker,
        &sweep_worker,
        &supervisor_worker,
        &mut controller,
        &mut host,
        &mut ledger,
        &mut logger,
        &paths,
        &Programs::default(),
        &spacing,
        Utc::now,
    );
    guard.leave()?;
    // After the alternate screen is gone, so it is readable: the header carries the short
    // sentence, and this is where the detail behind it goes.
    if let Some(diagnostic) = controller.diagnostic() {
        eprintln!("cerebro-tui: {diagnostic}");
    }
    result
}

/// Act on what `lifecycle::supervise_action` says about each row of the fleet snapshot that was
/// just applied - the three things this view does on its own, from what a hosted agent wrote in
/// its state file.
///
/// After the refresh and not before, and on the snapshot just derived rather than on one read
/// five seconds ago (`cerebro--tick`'s own order, `emacs/cerebro.el:6343-6353`): a row ended on
/// this tick must be restated by the next read, not acted on twice.
///
/// Gated on `mode.may_end()`, which is `Supervising` or `Draining`: the sessions a draining view
/// already hosts must be allowed to finish, since that is what ends the drain. The nudge alone
/// additionally asks `may_supervise()` - a nudge is a NEW instruction, and a view handing
/// supervision over issues none (`emacs/cerebro.el:4550`).
///
/// One agent's failure never stops the others: each row's work is fallible and a failure sets the
/// notice, exactly as an `f` that could not write its flag does.
#[allow(clippy::too_many_arguments)]
fn supervise(
    app: &mut App,
    host: &mut SessionHost,
    ledger: &mut StartLedger,
    logger: &mut Logger,
    paths: &ReaderPaths,
    now: DateTime<Utc>,
    at: Instant,
) {
    // The whole of the drain behaviour: a draining view finishes the sessions it hosts and
    // starts nothing, so every armed name is a promise it will not keep. Clearing the set turns
    // each row grey on the next fleet read, and it is correct for `ReadOnly` too, where the set
    // should never have held anything. A view that later re-acquires the lease comes back with an
    // empty armed set - the roster's declaration is read once at startup - so the navigator
    // presses `s` for the first session of each name, exactly as `M-x cerebro` behaves.
    if !app.supervision.may_supervise() {
        app.armed.clear();
    }
    if !app.supervision.may_end() {
        return;
    }
    let rows: Vec<(String, String, AgentKind, RowState, Option<String>, Option<i64>)> = app
        .fleet
        .content
        .value()
        .map(|rows| {
            rows.iter()
                .map(|row| {
                    (
                        row.name.clone(),
                        row.role.clone(),
                        row.kind,
                        row.state.clone(),
                        row.bead.clone(),
                        row.since.map(|since| (now - since).num_seconds()),
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    for (name, role, kind, state, bead, stood) in rows {
        // Before any action is decided, and for every row: a name that asked, was nudged, was
        // answered and asks again is nudgeable again.
        if state != RowState::Asking {
            app.nudged.remove(&name);
        }
        let agent = lifecycle::Supervised {
            kind,
            state: &state,
            ours: host.supervisable(&name),
            stop_flag: lifecycle::stop_flag_set(paths, &name),
            // `cerebro-idle-ends-pass-roles` is empty in this fleet, and this crate has no place
            // to declare one. Do not invent a declaration for it.
            idle_ends_pass: false,
            stood,
        };
        let Some(action) = lifecycle::supervise_action(agent) else { continue };
        // The record of the decision, before it is carried out and whatever it is: the five
        // fields elisp writes, in its order. `state` is the ROW's own word, so an `Unknown(w)`
        // contributes `w`; `stop_flag` is the string `"set"` or null, never a boolean.
        logger.write(
            match action {
                lifecycle::Supervision::Retire => log::Event::Retire,
                lifecycle::Supervision::End => log::Event::End,
                lifecycle::Supervision::Nudge => log::Event::Nudge,
            },
            now,
            &[
                ("agent", serde_json::Value::from(name.as_str())),
                ("role", serde_json::Value::from(role.as_str())),
                ("state", serde_json::Value::from(state.word())),
                ("bead", bead.clone().map_or(serde_json::Value::Null, serde_json::Value::from)),
                (
                    "stop_flag",
                    if agent.stop_flag {
                        serde_json::Value::from("set")
                    } else {
                        serde_json::Value::Null
                    },
                ),
            ],
        );
        match action {
            lifecycle::Supervision::Retire => {
                // Retiring disarms, which is what makes a stop flag on a standby implementer mean
                // *disarmed* rather than *retried*. `End` deliberately does NOT: ending a pass is
                // exactly the moment a name should stay armed, since the trigger that starts its
                // next session is what the armed set exists to allow.
                app.armed.remove(&name);
                // The instruction before the record (`emacs/cerebro.el:4537-4540`'s own order):
                // the flag is what the next session under that name would otherwise inherit, and
                // ending is the step that can fail.
                if let Err(error) = lifecycle::clear_stop_flag(paths, &name) {
                    let text = format!("Could not clear the stop flag for {name}: {error}");
                    logger.error(&format!("supervise {name}"), &text, now);
                    app.set_notice(text);
                    continue;
                }
                host.end(paths, &name);
                ledger.note_ended(&name, now);
                app.set_notice(lifecycle::supervision_notice(action, &name));
            }
            lifecycle::Supervision::End => {
                host.end(paths, &name);
                // The authoritative `ended_at`: the moment this view ended the pass, which is
                // what the unchanged-work guard measures a start against.
                ledger.note_ended(&name, now);
                app.set_notice(lifecycle::supervision_notice(action, &name));
            }
            lifecycle::Supervision::Nudge => {
                if !app.supervision.may_supervise() || app.nudged.contains(&name) {
                    continue;
                }
                app.nudged.insert(name.clone());
                host.type_line(&name, lifecycle::NUDGE_MESSAGE, at);
                app.set_notice(lifecycle::supervision_notice(action, &name));
            }
        }
    }
}


/// Start every standby row whose trigger is true. The port of `cerebro--start-due`, less its
/// retry and give-up branches, which are cb-kcs.4.2's.
///
/// After `supervise` and not before (`cerebro--tick`'s own order): a session ended on this tick
/// must not also be started on it, and a row restated by the next read is what makes that true.
///
/// Gated on `mode.may_supervise()`, which is `Supervising` alone - NOT `may_end`. A draining view
/// finishes what it hosts and starts nothing.
///
/// One agent's failure never stops the others: each row's work is fallible, and a failure is
/// reported exactly as an `s` that could not launch is.
#[allow(clippy::too_many_arguments)]
fn start_due(
    app: &mut App,
    host: &mut SessionHost,
    ledger: &mut StartLedger,
    logger: &mut Logger,
    paths: &ReaderPaths,
    spacing: &BTreeMap<String, u64>,
    roster: &[RosterEntry],
    now: DateTime<Utc>,
) {
    if !app.supervision.may_supervise() {
        return;
    }
    // No board, no starts. This is `most-positive-fixnum`'s whole job in elisp, said without a
    // sentinel: a `Stale` work pane still carries its last good buckets and is used.
    let Some(buckets) = app.work.content.value() else { return };
    let facts = TriggerFacts::derive(
        buckets,
        roster,
        |name| lifecycle::stop_flag_set(paths, name),
        app.gh_answer(),
    );

    let standby: Vec<(String, String)> = app
        .fleet_rows()
        .iter()
        .filter(|row| row.state == RowState::Standby)
        .map(|row| (row.name.clone(), row.role.clone()))
        .collect();
    // The cadence roles' cell counts down to a moment, so the label needs the row's own
    // `ended_at` and the clock as well as the fleet's facts (cb-kcs.4.3).
    app.set_standby_labels(
        standby
            .iter()
            .filter_map(|(name, role)| {
                let agent = triggers::AgentFacts {
                    role,
                    ended_at: ledger.ended_at(name),
                    started_at: ledger.started_at(name),
                    last_fingerprint: ledger.fingerprint(name),
                };
                let failures = ledger.failures(name);
                triggers::standby_cell(
                    role,
                    &facts,
                    agent,
                    now,
                    failures,
                    triggers::retry_wait(failures, ledger.started_at(name), now),
                )
                .map(|cell| (name.clone(), cell))
            })
            .collect(),
    );

    for (name, role) in &standby {
        // A flagged name is never started, whatever its trigger says: that is what `f` means. A
        // deliberate, named divergence from `cerebro--start-due`, which checks no flag at all
        // even though `cerebro--supervise-action`'s own comment says a standby role's flag
        // belongs there. Strictly fewer starts, and it makes `f` mean one thing.
        let flagged = lifecycle::stop_flag_set(paths, name);
        let agent = triggers::AgentFacts {
            role,
            ended_at: ledger.ended_at(name),
            started_at: ledger.started_at(name),
            last_fingerprint: ledger.fingerprint(name),
        };
        // Every guard is CONSULTED before anything is decided, rather than each one returning as
        // it fires, because cb-kcs.4.4's evaluation line carries all of them: a row that started
        // nothing has to say which guard was the reason, and a `continue` says nothing at all.
        // The order below is the order the guards used to run in, and each is still asked only
        // when the ones before it let it through - `role_start_too_soon` reads a map `note_started`
        // writes into, so asking it for a row that was never going to start would be a different
        // question from the one that used to be asked.
        let reason = triggers::trigger(&facts, agent, now);
        let held_by_guard = reason.is_none() && triggers::held_by_unchanged_work(&facts, agent);
        let spacing_value = triggers::spacing_for(role, spacing);
        // Inside the loop, not before it, because `note_started` writes into the same map - so
        // the second planner in this very pass already sees the first.
        let spaced_out = !flagged
            && reason.is_some()
            && triggers::role_start_too_soon(
                &triggers::role_peers(name, role, roster),
                ledger.started_at_map(),
                spacing_value,
                now,
            );
        let started = ledger.started_at(name);
        let failures = ledger.failures(name);
        let failed = triggers::start_failed(started, ledger.ended_at(name));
        // Backed off: a launch that produced no session is retried, but not on every tick. This
        // comes BEFORE the give-up, so a name at four failures counts its ten minutes down and
        // gives up when the wait expires rather than when the fourth failure lands.
        let backed_off = !flagged
            && reason.is_some()
            && !spaced_out
            && failed
            && triggers::retry_wait(failures, started, now) > 0;
        let acts = !flagged && reason.is_some() && !spaced_out && !backed_off;
        let gives_up = acts && triggers::give_up(failed, failures);

        // What the trigger read and what held it, before anything is done about it: the file
        // reads *here is what it saw, then here is what it did*.
        let flag = |set: bool| if set { serde_json::Value::Bool(true) } else { serde_json::Value::Null };
        logger.evaluation(
            now,
            &[
                ("agent", serde_json::Value::from(name.as_str())),
                ("role", serde_json::Value::from(role.as_str())),
                (
                    "reason",
                    reason.clone().map_or(serde_json::Value::Null, serde_json::Value::from),
                ),
                ("planned", serde_json::Value::from(facts.planned)),
                (
                    "planned_ids",
                    if facts.planned_ids.is_empty() {
                        serde_json::Value::Null
                    } else {
                        serde_json::Value::from(facts.planned_ids.clone())
                    },
                ),
                ("implementers", serde_json::Value::from(facts.implementers)),
                (
                    "p0_unplanned",
                    if facts.p0_unplanned.is_empty() {
                        serde_json::Value::Null
                    } else {
                        serde_json::Value::from(facts.p0_unplanned.clone())
                    },
                ),
                ("p4_unranked", serde_json::Value::from(facts.unranked_ids.len())),
                ("merged_unverified", serde_json::Value::from(facts.merged_unverified)),
                ("stale_verdicts", serde_json::Value::from(facts.stale_verdicts)),
                ("held_by_guard", flag(held_by_guard)),
                ("spaced_out", flag(spaced_out)),
                (
                    "spacing",
                    spacing_value.map_or(serde_json::Value::Null, serde_json::Value::from),
                ),
                ("backed_off", flag(backed_off)),
                ("stop_flag", flag(flagged)),
                // Standby when the list was built and not armed now: something disarmed it
                // earlier in this tick.
                ("disarmed", flag(!app.armed.contains(name))),
                ("failed_starts", serde_json::Value::from(failures)),
            ],
        );

        if !acts {
            continue;
        }
        if gives_up {
            // The counter holds the failures BEFORE this start, and the one that brought us here
            // is what the notice and the row name; left behind, they say different numbers about
            // the same sessions.
            let total = failures + 1;
            ledger.set_failures(name, total);
            host.note_gave_up(name, total);
            // In this order, or the row is restated from an `exits` map that does not yet know.
            app.set_exits(host.exits());
            app.armed.remove(name);
            app.reapply_standby();
            let text = triggers::give_up_notice(name, total);
            logger.write(
                log::Event::GiveUp,
                now,
                &[
                    ("agent", serde_json::Value::from(name.as_str())),
                    ("role", serde_json::Value::from(role.as_str())),
                    ("failed_starts", serde_json::Value::from(total)),
                ],
            );
            // And the same sentence the row and the notice carry, in the file the navigator is
            // sent to.
            logger.error(&format!("start {name}"), &text, now);
            app.set_notice(text);
            continue;
        }

        ledger.set_failures(name, if failed { failures + 1 } else { 0 });
        // `clears_flag` is `false` and can only be: a flagged name was skipped above.
        match lifecycle::start(host, paths, name, false) {
            Ok(_) => {
                app.armed.insert(name.clone());
                ledger.note_started(name, now, triggers::fingerprint(role, &facts));
                let reason = reason.unwrap_or_default();
                log_start(logger, name, role, Some(&reason), now);
                app.set_notice(triggers::start_notice(name, &reason));
            }
            // The red Session pane is the report, which is the rule `s` already follows.
            Err(error) => {
                logger.error(&format!("start {name}"), &error.to_string(), now);
                host.note_refusal(name, &error.to_string(), now);
            }
        }
    }

    let seen: Vec<String> = app
        .fleet_rows()
        .iter()
        .filter(|row| {
            !matches!(row.state, RowState::Dead | RowState::Standby | RowState::Invalid)
        })
        .map(|row| row.name.clone())
        .collect();
    for name in seen {
        ledger.note_seen_up(&name, now);
    }
}

/// One `exit` line per child reaped since the last frame.
///
/// Its own function rather than eight lines in the frame block, so the rule it encodes -
/// which endings are this view's own doing - is testable without a terminal.
fn log_exits(logger: &mut Logger, host: &mut SessionHost, now: DateTime<Utc>) {
    // An `exit` line only for an ending this view did NOT cause: `end` has already said
    // what happened when it did, and `exit` keeps meaning what it means in Emacs's file.
    // `classify_exit` is the same test the verdict column uses rather than a second one.
    for (name, ended) in host.take_reaped() {
        if matches!(ended, session::Ended::Signal(_) | session::Ended::ByView) {
            continue;
        }
        let code = match ended {
            session::Ended::Status(status) => status.to_string(),
            // Unreachable: both are skipped above. A word rather than a panic, because a
            // log is not a place to bring the view down.
            _ => "by-view".to_string(),
        };
        logger.write(
            log::Event::Exit,
            now,
            &[
                ("agent", serde_json::Value::from(name.as_str())),
                ("code", serde_json::Value::from(code)),
                // `true` or null, never `false`: a clean exit is not an abnormal one, and
                // a boolean would quietly change the shape a reader splits on.
                (
                    "abnormal",
                    if lifecycle::classify_exit(ended).is_some() {
                        serde_json::Value::Bool(true)
                    } else {
                        serde_json::Value::Null
                    },
                ),
                // This crate keeps the last line on the retained screen rather than in a
                // field, which is what cb-kcs.3 decided when it dropped `LastExit`'s
                // `:line`.
                ("last_line", serde_json::Value::Null),
            ],
        );
    }
}

/// One `start` line. `by` is `"trigger"` when a trigger's reason produced it and `"navigator"`
/// otherwise - `s` and the roster's own `autostart` alike. Two words and only two.
fn log_start(
    logger: &mut Logger,
    name: &str,
    role: &str,
    reason: Option<&str>,
    now: DateTime<Utc>,
) {
    logger.write(
        log::Event::Start,
        now,
        &[
            ("agent", serde_json::Value::from(name)),
            ("role", serde_json::Value::from(role)),
            ("reason", reason.map_or(serde_json::Value::Null, serde_json::Value::from)),
            ("by", serde_json::Value::from(if reason.is_some() { "trigger" } else { "navigator" })),
        ],
    );
}

/// NAME's role as the last fleet read saw it, or the empty string.
///
/// For `s` alone, which has a selected row and therefore a fleet read behind it. `arm_and_autostart`
/// runs BEFORE the fleet worker has been polled even once and must never use this: it reads the
/// roster, which is where a name's role comes from at that moment.
fn role_of(app: &App, name: &str) -> String {
    app.fleet_rows()
        .iter()
        .find(|row| row.name == name)
        .map(|row| row.role.clone())
        .unwrap_or_default()
}

/// Perform the roster's `autostart` declaration and arm its `standby` one, once, as the view
/// comes up. The port of `cerebro--autostart`, less its vterm check, which has no counterpart.
///
/// Returns the startup notice, or `None` when the roster declared neither.
#[allow(clippy::too_many_arguments)]
fn arm_and_autostart(
    app: &mut App,
    host: &mut SessionHost,
    ledger: &mut StartLedger,
    logger: &mut Logger,
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
    complaints: &[String],
    now: DateTime<Utc>,
) -> Option<String> {
    // A declaration this view cannot read is treated as an empty list AND said out loud: a fleet
    // where nothing is armed and nothing is started must not be indistinguishable from a roster
    // that declared neither.
    let mut complaints = complaints.to_vec();
    let mut names = |flag: &str, read: Result<Vec<String>, ReadError>| match read {
        Ok(names) => names,
        Err(error) => {
            complaints.push(format!("roster {flag} could not be read: {error}"));
            Vec::new()
        }
    };
    let autostart = names("--autostart", readers::read_autostart_names(paths, commands));
    let standby = names("--standby", readers::read_standby_names(paths, commands));
    // The roles, from the same declaration the names came from. The fleet pane has NOT been read
    // yet - this runs before the first poll - so `role_of` would answer the empty string for every
    // name here, and both views write into one file.
    //
    // This is a THIRD read of the roster and fails on its own: the two complaints above are about
    // `--autostart` and `--standby`, so a bare `roster` that refuses or parses badly is silent
    // here and costs one empty `role` field. That is the right price - a startup that refused to
    // arm anything because a log field could not be filled would be a fleet that cannot start.
    let roles: BTreeMap<String, String> = readers::read_roster(paths, commands)
        .map(|entries| entries.into_iter().map(|e| (e.name, e.role)).collect())
        .unwrap_or_default();
    drop(names);
    let role_of_name = |name: &String| roles.get(name).cloned().unwrap_or_default();
    let mut started = Vec::new();
    for name in &autostart {
        if host.is_live(name) {
            continue;
        }
        // For EVERY kind here, not implementers only, which is `cerebro--autostart-action`'s own
        // widening: a name declared `autostart` under a stale flag would otherwise come up and be
        // retired at once.
        let clears_flag = lifecycle::stop_flag_set(paths, name);
        match lifecycle::start(host, paths, name, clears_flag) {
            Ok(_) => {
                app.armed.insert(name.clone());
                ledger.note_started(name, now, None);
                // A declaration, not a trigger: it starts whatever the countdown said, and says
                // the failures behind it do not count.
                ledger.clear_failures(name);
                // A declaration is the navigator's own act, which is what `by` says: two words
                // and only two, byte-parity with the file Emacs has written since May.
                log_start(logger, name, &role_of_name(name), None, now);
                started.push(name.clone());
            }
            // A start that fails is reported and does not stop the others.
            Err(error) => {
                logger.error(&format!("start {name}"), &error.to_string(), now);
                host.note_refusal(name, &error.to_string(), now);
            }
        }
    }
    for name in &standby {
        app.armed.insert(name.clone());
        ledger.note_armed(name, now);
        // Only for the STANDBY half of the declaration: an autostarted name gets its `start` line
        // instead, exactly as elisp writes it.
        logger.write(
            log::Event::Arm,
            now,
            &[
                ("agent", serde_json::Value::from(name.as_str())),
                ("role", serde_json::Value::from(role_of_name(name))),
                ("by", serde_json::Value::from("roster")),
            ],
        );
    }
    startup_notice(&started, &standby, &complaints)
}

/// The roles a spacing is asked about, once, at startup.
const SPACED_ROLES: [&str; 4] = ["planner", "implementer", "verifier", "orchestrator"];

/// The startup line, naming both halves of the roster's declaration - because the declaration did
/// both and only one of them is otherwise audible. An empty half drops its clause along with the
/// `; `. Each unparseable spacing is appended as its own sentence, `cerebro--project-spacing`'s
/// own wording.
fn startup_notice(started: &[String], standby: &[String], complaints: &[String]) -> Option<String> {
    let mut clauses = Vec::new();
    if !started.is_empty() {
        clauses.push(format!("Started {}", lifecycle::join_names(started)));
    }
    if !standby.is_empty() {
        clauses.push(format!(
            "{} {} on standby",
            lifecycle::join_names(standby),
            if standby.len() == 1 { "is" } else { "are" }
        ));
    }
    let mut notice = if clauses.is_empty() {
        if complaints.is_empty() {
            return None;
        }
        String::new()
    } else {
        format!("{}.", clauses.join("; "))
    };
    for complaint in complaints {
        if !notice.is_empty() {
            notice.push(' ');
        }
        notice.push_str(complaint);
    }
    Some(notice)
}

/// The whole loop, generic over its terminal and its event source so the cases below can drive it
/// without taking over the developer's own terminal.
#[allow(clippy::too_many_arguments)]
fn run<B: Backend, E: Events>(
    terminal: &mut Terminal<B>,
    events: &mut E,
    app: &mut App,
    fleet_worker: &FleetWorker,
    work_worker: &WorkWorker,
    gh_worker: &GhWorker,
    sweep_worker: &SweepWorker,
    supervisor_worker: &SupervisorWorker,
    controller: &mut SupervisorController,
    host: &mut SessionHost,
    ledger: &mut StartLedger,
    logger: &mut Logger,
    paths: &ReaderPaths,
    programs: &Programs,
    spacing: &BTreeMap<String, u64>,
    clock: impl Fn() -> DateTime<Utc>,
) -> Result<(), Fatal>
where
    B::Error: std::error::Error + 'static,
{
    while !app.quit {
        let now = clock();
        // The child's screen is materialised BEFORE the frame, from the geometry the last
        // `metrics` gave the Session pane - which is what keeps `ui::draw` pure while a reader
        // thread writes into a parser continuously, and what sizes the child to the pane it is
        // drawn in.
        {
            let size = terminal.size()?;
            let area = Rect::new(0, 0, size.width, size.height);
            let session = ui::metrics(app, now, area).session;
            let view = host.sync(
                app.selected.as_deref(),
                session.viewport_lines as u16,
                session.inner_width as u16,
                now,
            );
            app.set_session_view(view);
            host.flush_returns(Instant::now());
            app.set_exits(host.exits());
            log_exits(logger, host, now);
        }
        terminal.draw(|frame| ui::draw(frame, app, now))?;

        let size = terminal.size()?;
        let area = Rect::new(0, 0, size.width, size.height);
        let metrics = ui::metrics(app, now, area);
        // Kept for the refresh that moves the selected row with nothing pressed - the only place
        // `App` learns any geometry, and always from a frame that was actually drawn.
        app.note_metrics(metrics);
        // A page is a page of the FOCUSED pane's own viewport, not the other pane's and not the
        // whole terminal: `App::focused_viewport` is the one place the at-least-one floor lives.
        let viewport_lines = app.focused_viewport(metrics);
        // Clamped from the frame that was just drawn, never before it, and each pane against its
        // own geometry alone: a refresh that returns the same rows must leave the navigator
        // looking at the same line in whichever pane they were reading. A too-small frame is
        // skipped entirely rather than clamped against its own borrowed-zero metrics: neither
        // pane is actually shorter just because the terminal briefly dipped below the floor, and
        // clamping there would silently reset whichever offset a navigator had scrolled to the
        // moment they resized back.
        if !ui::too_small(area) {
            app.fleet.clamp_scroll(metrics.fleet.content_lines, metrics.fleet.viewport_lines);
            app.work.clamp_scroll(metrics.work.content_lines, metrics.work.viewport_lines);
            app.session.clamp_scroll(metrics.session.content_lines, metrics.session.viewport_lines);
        }

        // Each answer updates only its own pane. Neither poll blocks.
        if let Some(result) = fleet_worker.poll() {
            let succeeded = result.is_ok();
            match &result {
                // One successful fleet read proves both halves ran, so it clears both contexts.
                Ok(_) => {
                    logger.clear_error("fleet");
                    logger.clear_error("roster");
                }
                Err(error) => {
                    logger.error(&log::reader_context("fleet", error), &error.to_string(), clock())
                }
            }
            app.finish_refresh(result, clock());
            // On the snapshot just applied, and only when the read succeeded: a failed read says
            // nothing about any agent, and acting on the last good one would end a session on
            // evidence five seconds stale.
            if succeeded {
                let now = clock();
                supervise(app, host, ledger, logger, paths, now, Instant::now());
                // After `supervise` and not before: a session ended on this tick must not also be
                // started on it, and a row restated by the next read is what makes that true.
                let roster: Vec<RosterEntry> = app
                    .fleet_rows()
                    .iter()
                    .map(|row| RosterEntry {
                        name: row.name.clone(),
                        role: row.role.clone(),
                        kind: row.kind,
                    })
                    .collect();
                start_due(app, host, ledger, logger, paths, spacing, &roster, now);
            }
        }
        if let Some(result) = work_worker.poll() {
            match &result {
                Ok(_) => logger.clear_error("work"),
                Err(error) => {
                    logger.error(&log::reader_context("work", error), &error.to_string(), clock())
                }
            }
            app.finish_work_refresh(result, clock());
        }
        // The `gh` answer draws nothing; it is polled for the same reason it is read at all, so
        // that the two cadence triggers see a current one.
        if let Some(result) = gh_worker.poll() {
            app.finish_gh_refresh(result, clock());
        }
        // The sweeps fail apart from the two panes, exactly as `gh` does: six scripts nobody
        // could run says nothing about the fleet or the board. The underlying cause is written
        // where it is still in hand - `ReadError::Sweep`'s Display is one word by the navigator's
        // own choice - so the log keeps what the header cannot say.
        if let Some(result) = sweep_worker.poll() {
            match &result {
                Ok(_) => logger.clear_error("sweep"),
                Err(error) => logger.error("sweep", &error.to_string(), clock()),
            }
            app.finish_sweep_refresh(result, clock());
        }
        // Ownership is a third state, polled like the other two and failing apart from them: a
        // declaration that cannot be read says nothing about the fleet or the board.
        if let Some(answer) = supervisor_worker.poll() {
            let mode = controller.apply(answer);
            // Before anything else this tick writes: a view that has just gone read-only must
            // have written nothing further, and one that has just taken the checkout may.
            logger.set_enabled(mode.may_end());
            match controller.diagnostic() {
                // Already one-per-fault by construction (`clear_diagnostic`); `Logger::error`'s
                // own dedupe is what keeps a persisting one to a single line.
                Some(diagnostic) => {
                    let diagnostic = diagnostic.to_string();
                    logger.error("supervision", &diagnostic, clock());
                }
                None => logger.clear_error("supervision"),
            }
            app.set_supervision(mode);
        }
        // What makes `reconcile_supervision`'s drain branch reachable: a declaration that moved
        // supervision while this process hosts children keeps the lease until the last one ends.
        controller.hosted_sessions = host.live_count();
        if controller.due(Instant::now()) && supervisor_worker.request() {
            controller.requested(Instant::now());
        }

        dispatch(app.on_tick(Instant::now()), app, fleet_worker, work_worker, gh_worker, sweep_worker, &clock);

        if events.poll(POLL_INTERVAL)? {
            match events.read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => {
                    let action =
                        route_key(key, app, host, ledger, logger, paths, programs, viewport_lines, clock());
                    if action == AppAction::Quit {
                        break;
                    }
                    // `g` retries ownership as well as data (the navigator's choice): a second
                    // Ratatui stays open as a read-only observer and takes the checkout with `g`
                    // once the owner closes. Its own request, so an in-flight ownership read can
                    // never swallow the fleet/work retry the key was pressed for.
                    if action == AppAction::RefreshAll && supervisor_worker.request() {
                        controller.requested(Instant::now());
                    }
                    dispatch(action, app, fleet_worker, work_worker, gh_worker, sweep_worker, &clock);
                }
                // Forwarded as a PASTE (Q3), so an agent composer that treats a bare newline as
                // submit receives four pasted lines as one block rather than submitting the
                // first of them. With no live focused session there is nobody to give it to.
                Event::Paste(text) => {
                    if let Some(name) = app.selected.clone() {
                        if app.session_has_keyboard() {
                            host.send(&name, &session::paste_bytes(&text));
                        }
                    }
                }
                // A resize needs nothing but the redraw at the top of the loop.
                _ => {}
            }
        }
    }
    Ok(())
}

/// The keystroke path, in this order, each branch returning:
///
/// 1. the quit-refusal pane owns the screen: ANY key clears it and does nothing else (Q8);
/// 2. a kill confirmation owns the keyboard: `y` kills, anything else cancels silently (Q10), and
///    the cancelling keystroke is consumed - `q` at the prompt does not also quit. Before the
///    session branch because a confirmation can only exist if `k` was pressed, which requires the
///    Session pane NOT to hold the keyboard;
/// 3. a live session that holds the keyboard gets the bytes, as cb-kcs.2.2 left it;
/// 4. `s`, `f` and `k`, unmodified, are the lifecycle;
/// 5. everything else is `App::on_key` - and a `Quit` from it over a live session is refused.
///
/// In branch 3, `Shift-Tab` is held back and handed to `App::on_key` as the only way out (Q8),
/// which is the reason the child can never receive it; everything else goes to
/// `session::key_bytes`, and a `None` is dropped without a word (Q1), because the pane is a window
/// onto the child rather than a commentary on it. So `q`, `Esc`, `Ctrl-C` and `g` do NOT quit or
/// refresh while a live session is focused - they are the child's, which is exactly what the
/// replaced header line says.
#[allow(clippy::too_many_arguments)]
fn route_key(
    key: KeyEvent,
    app: &mut App,
    host: &mut SessionHost,
    ledger: &mut StartLedger,
    logger: &mut Logger,
    paths: &ReaderPaths,
    // Injectable for the reason every other program in this crate is: `x` runs a `bd` that
    // WRITES, and a case that used the default would act on the developer's own board.
    programs: &Programs,
    viewport_lines: usize,
    now: DateTime<Utc>,
) -> AppAction {
    // A notice is transient by design: whatever the navigator presses is what clears it, and that
    // has to be true of the keys these two panes consume as well - or a gold line outlives the
    // keystroke that should have cleared it and reappears when the pane closes.
    if app.quit_refusal.is_some() {
        app.notice = None;
        app.quit_refusal = None;
        return AppAction::None;
    }
    if let Some(prompt) = app.confirm.take() {
        app.notice = None;
        let confirmed = key.code == KeyCode::Char('y') && key.modifiers.is_empty();
        // Anything other than `y` cancels silently and does nothing else.
        if !confirmed {
            return AppAction::None;
        }
        return match prompt {
            app::Prompt::Kill { name, .. } => {
                host.kill(paths, &name);
                // A killed agent must not wait up to five seconds to disappear from the fleet.
                AppAction::RefreshFleet
            }
            app::Prompt::Disarm { name, .. } => {
                app.armed.remove(&name);
                app.set_notice(lifecycle::disarm_notice(&name));
                // So the row goes grey at once rather than up to five seconds later.
                AppAction::RefreshFleet
            }
            // The one prompt that writes to the shared board rather than to this checkout's
            // sessions. The `sweep` line is written BEFORE the command runs, exactly as
            // `cerebro-sweep-act` writes it: a decision the view made is worth keeping whether or
            // not the write then succeeded.
            app::Prompt::Sweep { finding, .. } => {
                logger.write(
                    log::Event::Sweep,
                    now,
                    &[(
                        "command",
                        serde_json::Value::from(
                            cerebro_tui::sweeps::finding_command(&finding, &programs.bd)
                                .join(" "),
                        ),
                    )],
                );
                let outcome = lifecycle::run_finding(paths, programs, &finding);
                app.set_notice(match outcome {
                    lifecycle::FindingOutcome::Ran { text }
                    | lifecycle::FindingOutcome::Pushed { text }
                    | lifecycle::FindingOutcome::Failed { text } => text,
                });
                // So a finding that has just been acted on leaves the section at once rather
                // than sitting there for up to ten minutes.
                AppAction::RefreshSweeps
            }
        };
    }
    if app.session_has_keyboard() && key.code != KeyCode::BackTab {
        if let (Some(name), Some(bytes)) = (app.selected.clone(), session::key_bytes(key)) {
            host.send(&name, &bytes);
        }
        return AppAction::None;
    }
    // AFTER the live-session branch, so a session holding the keyboard still gets the byte, and
    // from ANY focus, exactly as `s`/`f`/`k` are. With no finding under the cursor it does
    // nothing and says nothing: the cursor rule puts one there whenever any exist, so the empty
    // case is unreachable from the keyboard and a refusal sentence for it would be a string
    // nobody can produce.
    if key.modifiers.is_empty() && key.code == KeyCode::Char('x') {
        app.notice = None;
        if let Some(judged) = app.selected_finding() {
            let finding = judged.finding.clone();
            let text = cerebro_tui::sweeps::prompt(&finding, &programs.bd);
            app.confirm = Some(app::Prompt::Sweep { finding, text });
        }
        return AppAction::None;
    }
    if key.modifiers.is_empty() {
        if let KeyCode::Char(c @ ('s' | 'f' | 'k')) = key.code {
            // A notice is transient exactly as it is under `on_key`: the keystroke that reads it
            // is the one that clears it, and this key may then write its own.
            app.notice = None;
            return lifecycle_key(c, app, host, ledger, logger, paths, now);
        }
    }
    let action = app.on_key(key, viewport_lines);
    if action == AppAction::Quit {
        let live = host.live_names(&app.roster_order());
        if !live.is_empty() {
            app.refuse_quit(live);
            return AppAction::None;
        }
    }
    action
}

/// Build the `Situation`, ask `lifecycle`, and carry out what it said.
///
/// Each of the three sets at most one notice, and each ends with `RefreshFleet` when it changed
/// something - a started or killed agent must not wait up to five seconds to appear.
#[allow(clippy::too_many_arguments)]
fn lifecycle_key(
    key: char,
    app: &mut App,
    host: &mut SessionHost,
    ledger: &mut StartLedger,
    logger: &mut Logger,
    paths: &ReaderPaths,
    now: DateTime<Utc>,
) -> AppAction {
    let Some(name) = app.selected.clone() else { return AppAction::None };
    let row = app.selected_row().cloned();
    let situation = lifecycle::Situation {
        mode: &app.supervision,
        row: row.as_ref(),
        hosted: host.is_live(&name),
        stop_flag: lifecycle::stop_flag_set(paths, &name),
    };
    match key {
        's' => match lifecycle::start_outcome(situation) {
            lifecycle::StartOutcome::Launch { clears_flag } => {
                match lifecycle::start(host, paths, &name, clears_flag) {
                    Ok(line) => {
                        // The navigator asking for a session is what says the last failures do
                        // not count - and without the start being recorded at all, the row would
                        // count down against a start that never happened.
                        ledger.note_started(&name, now, None);
                        ledger.clear_failures(&name);
                        log_start(logger, &name, &role_of(app, &name), None, now);
                        app.set_notice(line);
                    }
                    // The red Session pane is the report; a gold line saying the same thing twice
                    // is not. A refusal of the KEY is not an error and writes nothing; a launch
                    // that was attempted and failed is one.
                    Err(error) => {
                        logger.error(&format!("start {name}"), &error.to_string(), now);
                        host.note_refusal(&name, &error.to_string(), now);
                    }
                }
                AppAction::RefreshFleet
            }
            lifecycle::StartOutcome::Refuse(text) => {
                app.set_notice(text);
                AppAction::None
            }
            lifecycle::StartOutcome::Ignore => AppAction::None,
        },
        'f' => {
            let (result, line) = match lifecycle::finish_outcome(situation) {
                lifecycle::FinishOutcome::Write => (
                    Some(lifecycle::write_stop_flag(paths, &name)),
                    format!("{name} will finish after this pass."),
                ),
                lifecycle::FinishOutcome::Clear => (
                    Some(lifecycle::clear_stop_flag(paths, &name)),
                    format!("{name} will keep going."),
                ),
                lifecycle::FinishOutcome::Refuse(text) => (None, text),
                lifecycle::FinishOutcome::Ignore => return AppAction::None,
            };
            match result {
                // A key that reported success over a file it did not write is the one failure `f`
                // can have, so the io error is the notice.
                Some(Err(error)) => app.set_notice(error.to_string()),
                Some(Ok(())) => app.set_notice(line),
                None => app.set_notice(line),
            }
            AppAction::None
        }
        'k' => match lifecycle::kill_outcome(situation) {
            lifecycle::KillOutcome::Confirm { prompt, disarm } => {
                // `k` asks two different questions: a live session is killed, a standby row is
                // disarmed. WHICH is `lifecycle`'s answer, beside the sentence it wrote, so the
                // prompt and the action it confirms cannot part company.
                app.confirm = Some(if disarm {
                    app::Prompt::Disarm { name, text: prompt }
                } else {
                    app::Prompt::Kill { name, text: prompt }
                });
                AppAction::None
            }
            lifecycle::KillOutcome::Refuse(text) => {
                app.set_notice(text);
                AppAction::None
            }
            lifecycle::KillOutcome::Ignore => AppAction::None,
        },
        _ => AppAction::None,
    }
}

/// Turn one `AppAction` into requests. `RefreshAll` asks each pane in turn and never as a set:
/// a fleet read already in flight must not swallow the work retry the navigator pressed `g` for.
fn dispatch(
    action: AppAction,
    app: &mut App,
    fleet_worker: &FleetWorker,
    work_worker: &WorkWorker,
    gh_worker: &GhWorker,
    sweep_worker: &SweepWorker,
    clock: &impl Fn() -> DateTime<Utc>,
) {
    let now = Instant::now();
    if matches!(action, AppAction::RefreshFleet | AppAction::RefreshAll)
        && app.begin_refresh(now)
        && !fleet_worker.request()
    {
        app.finish_refresh(Err(worker_gone("fleet reader")), clock());
    }
    if matches!(action, AppAction::RefreshWork | AppAction::RefreshAll)
        && app.begin_work_refresh(now)
        && !work_worker.request()
    {
        app.finish_work_refresh(Err(worker_gone("work reader")), clock());
    }
    // `g` re-asks `gh` as well as the two panes, so a navigator who fixes their network sees the
    // `gh?` suffix clear at once instead of waiting out the ten-minute clock. `begin_gh_refresh`
    // is what stops a held-down `g` from asking more than once: a request in flight is not
    // stacked, exactly as the two panes behave.
    if (matches!(action, AppAction::RefreshAll) || app.gh_due(now))
        && app.begin_gh_refresh(now)
        && !gh_worker.request()
    {
        app.finish_gh_refresh(Err(worker_gone("gh reader")), clock());
    }
    // `g` re-runs the sweeps as well, and so does `x` once its command has run - waiting ten
    // minutes to watch a finding you have just acted on disappear is the moment a navigator
    // presses `g` anyway. Otherwise it is the ten-minute clock alone.
    if (matches!(action, AppAction::RefreshAll | AppAction::RefreshSweeps) || app.sweep_due(now))
        && app.begin_sweep_refresh(now)
        && !sweep_worker.request()
    {
        app.finish_sweep_refresh(Err(worker_gone("sweep reader")), clock());
    }
}

/// A worker that has stopped answering is a failed refresh on screen rather than a silent
/// `refreshing...` forever.
fn worker_gone(source: &str) -> ReadError {
    ReadError::Spawn {
        source: source.to_string(),
        message: "the reader thread has stopped".into(),
    }
}

/// Where keystrokes come from, injectable so a case can hand the loop a failure.
trait Events {
    fn poll(&mut self, timeout: Duration) -> io::Result<bool>;
    fn read(&mut self) -> io::Result<Event>;
}

struct CrosstermEvents;

impl Events for CrosstermEvents {
    fn poll(&mut self, timeout: Duration) -> io::Result<bool> {
        crossterm::event::poll(timeout)
    }
    fn read(&mut self) -> io::Result<Event> {
        crossterm::event::read()
    }
}

/// The terminal modes this process turns on, and turns off again. A trait so the guard's contract
/// can be proved without a real terminal - the guarantee being tested is "whatever happens, leave
/// runs exactly once", which has nothing to do with which escape codes it writes.
trait TerminalModes {
    fn enter(&mut self) -> io::Result<()>;
    fn leave(&mut self) -> io::Result<()>;
}

struct CrosstermTerminal;

impl TerminalModes for CrosstermTerminal {
    fn enter(&mut self) -> io::Result<()> {
        enable_raw_mode()?;
        let mut out: Stdout = io::stdout();
        execute!(out, EnterAlternateScreen, EnableBracketedPaste, crossterm::cursor::Hide)?;
        out.flush()
    }

    fn leave(&mut self) -> io::Result<()> {
        // Every step is attempted even when an earlier one failed: a terminal left in raw mode is
        // worse than a terminal left on the alternate screen, and the first failure must not skip
        // the rest.
        let mut out: Stdout = io::stdout();
        let cursor = out.execute(crossterm::cursor::Show).err();
        let paste = out.execute(DisableBracketedPaste).err();
        let screen = out.execute(LeaveAlternateScreen).err();
        let raw = disable_raw_mode().err();
        let _ = out.flush();
        first_error([cursor, paste, screen, raw])
    }
}

/// The four undo steps' outcomes folded into one result: the first failure, or `Ok`.
///
/// A free function so the rule the comment above states - every step is attempted, and a failure
/// in one does not shadow the rest - is assertable. `Recorder` substitutes for
/// `CrosstermTerminal` entirely and so can never see its crossterm commands; this is the half of
/// `leave` that can be tested without a real terminal, and it is the half that grew a fourth
/// step when bracketed paste arrived.
fn first_error(steps: [Option<io::Error>; 4]) -> io::Result<()> {
    match steps.into_iter().flatten().next() {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

/// Raw mode and the alternate screen, entered on construction and left in `Drop`.
///
/// RAII rather than a cleanup call at the end of the loop: `?`, an early return and a panic all
/// skip the call and none of them skips the drop.
struct TerminalGuard<M: TerminalModes> {
    modes: M,
    entered: bool,
}

impl<M: TerminalModes> TerminalGuard<M> {
    fn enter(modes: M) -> io::Result<Self> {
        let mut guard = Self {
            modes,
            entered: true,
        };
        if let Err(error) = guard.modes.enter() {
            let _ = guard.leave();
            return Err(error);
        }
        Ok(guard)
    }

    /// Leave now, and report a failure to do so. `Drop` still runs and does nothing, because
    /// leaving twice would disable raw mode the shell may have re-enabled by then.
    fn leave(&mut self) -> io::Result<()> {
        if !self.entered {
            return Ok(());
        }
        self.entered = false;
        self.modes.leave()
    }
}

impl<M: TerminalModes> Drop for TerminalGuard<M> {
    fn drop(&mut self) {
        // Silent: this runs while something has already gone wrong, and a panic in a drop during
        // unwinding aborts the process.
        let _ = self.leave();
    }
}

#[cfg(test)]
mod main_tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;
    use ratatui::backend::TestBackend;
    use ratatui::buffer::Cell;
    use ratatui::layout::{Position, Size};

    #[derive(Default)]
    struct Recorder {
        events: Rc<RefCell<Vec<&'static str>>>,
        fail_on_leave: bool,
    }

    impl TerminalModes for Recorder {
        fn enter(&mut self) -> io::Result<()> {
            self.events.borrow_mut().push("enter");
            Ok(())
        }
        fn leave(&mut self) -> io::Result<()> {
            self.events.borrow_mut().push("leave");
            if self.fail_on_leave {
                return Err(io::Error::other("leave failed"));
            }
            Ok(())
        }
    }

    /// A backend that draws nothing and fails, for the one thing `TestBackend` cannot be: a
    /// terminal that stops working mid-frame.
    struct FailingBackend;

    impl Backend for FailingBackend {
        type Error = io::Error;

        fn draw<'a, I>(&mut self, _content: I) -> io::Result<()>
        where
            I: Iterator<Item = (u16, u16, &'a Cell)>,
        {
            Err(io::Error::other("the terminal went away"))
        }
        fn hide_cursor(&mut self) -> io::Result<()> {
            Ok(())
        }
        fn show_cursor(&mut self) -> io::Result<()> {
            Ok(())
        }
        fn get_cursor_position(&mut self) -> io::Result<Position> {
            Ok(Position::new(0, 0))
        }
        fn set_cursor_position<P: Into<Position>>(&mut self, _position: P) -> io::Result<()> {
            Ok(())
        }
        fn clear(&mut self) -> io::Result<()> {
            Ok(())
        }
        fn clear_region(&mut self, _clear_type: ratatui::backend::ClearType) -> io::Result<()> {
            Ok(())
        }
        fn size(&self) -> io::Result<Size> {
            Ok(Size::new(100, 20))
        }
        fn window_size(&mut self) -> io::Result<ratatui::backend::WindowSize> {
            Ok(ratatui::backend::WindowSize {
                columns_rows: Size::new(100, 20),
                pixels: Size::new(0, 0),
            })
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct ScriptedEvents {
        poll_fails: bool,
        read_fails: bool,
    }

    impl Events for ScriptedEvents {
        fn poll(&mut self, _timeout: Duration) -> io::Result<bool> {
            if self.poll_fails {
                return Err(io::Error::other("poll failed"));
            }
            Ok(true)
        }
        fn read(&mut self) -> io::Result<Event> {
            if self.read_fails {
                return Err(io::Error::other("read failed"));
            }
            Ok(Event::Key(crossterm::event::KeyEvent::new(
                crossterm::event::KeyCode::Char('q'),
                crossterm::event::KeyModifiers::NONE,
            )))
        }
    }

    /// A fixed list of keystrokes, handed to the loop one per poll. `ScriptedEvents` above says
    /// only "always the same key"; this says what a navigator typed, in order.
    struct QueuedEvents {
        keys: std::collections::VecDeque<crossterm::event::KeyEvent>,
        /// End the loop when the keys run out, rather than spinning until something quits.
        ///
        /// The cases that assert a REFUSED quit have no keystroke that ends `run` - refusing is
        /// the whole point of them - so the event source stops the loop instead, by failing the
        /// poll. `drive` expects that error and asserts on the state the loop left behind.
        stop_when_empty: bool,
    }

    impl QueuedEvents {
        /// Bare key codes, each with no modifier - what almost every case wants.
        fn new(keys: Vec<crossterm::event::KeyCode>) -> Self {
            Self::spinning(
                keys.into_iter()
                    .map(|code| {
                        crossterm::event::KeyEvent::new(
                            code,
                            crossterm::event::KeyModifiers::NONE,
                        )
                    })
                    .collect(),
            )
        }

        /// The original shape: an exhausted queue polls false for ever, and the case's own final
        /// `q` is what ends the loop.
        fn spinning(keys: Vec<crossterm::event::KeyEvent>) -> Self {
            Self { keys: keys.into(), stop_when_empty: false }
        }

        /// Whole key events, for a case that needs `Ctrl-C` or another modifier - and which ends
        /// the loop when its keys run out.
        fn events(keys: Vec<crossterm::event::KeyEvent>) -> Self {
            Self { keys: keys.into(), stop_when_empty: true }
        }

        fn remaining(&self) -> usize {
            self.keys.len()
        }
    }

    impl Events for QueuedEvents {
        fn poll(&mut self, _timeout: Duration) -> io::Result<bool> {
            if self.keys.is_empty() && self.stop_when_empty {
                return Err(io::Error::other("the case's keystrokes are spent"));
            }
            Ok(!self.keys.is_empty())
        }
        fn read(&mut self) -> io::Result<Event> {
            let key = self
                .keys
                .pop_front()
                .ok_or_else(|| io::Error::other("no keystroke left"))?;
            Ok(Event::Key(key))
        }
    }


    /// An event source that replays whole `Event`s, not only bare key codes: these cases need
    /// modifiers and a paste, and neither fits `QueuedEvents`.
    struct ReplayedEvents {
        events: std::collections::VecDeque<Event>,
        stop_when_empty: bool,
    }

    impl ReplayedEvents {
        /// An exhausted queue polls false for ever, and the case's own quit ends the loop.
        fn new(events: Vec<Event>) -> Self {
            Self { events: events.into(), stop_when_empty: false }
        }

        /// An exhausted queue ENDS the loop instead: for a case whose last keystroke is REFUSED
        /// (a quit over a live session, since cb-kcs.2.3), where nothing else would stop it.
        fn stopping(events: Vec<Event>) -> Self {
            Self { events: events.into(), stop_when_empty: true }
        }
    }

    impl Events for ReplayedEvents {
        fn poll(&mut self, _timeout: Duration) -> io::Result<bool> {
            if self.events.is_empty() && self.stop_when_empty {
                return Err(io::Error::other("the case's events are spent"));
            }
            Ok(!self.events.is_empty())
        }
        fn read(&mut self) -> io::Result<Event> {
            self.events.pop_front().ok_or_else(|| io::Error::other("no event left"))
        }
    }

    fn key(code: KeyCode) -> Event {
        Event::Key(KeyEvent::new(code, crossterm::event::KeyModifiers::NONE))
    }

    fn ctrl(code: KeyCode) -> Event {
        Event::Key(KeyEvent::new(code, crossterm::event::KeyModifiers::CONTROL))
    }

    /// A child that echoes every byte back printably, so a case can read what the navigator's
    /// keystrokes became. `cat -v` renders `ESC` as `^[` and `Ctrl-C` as `^C`, and `stty raw`
    /// stops the line discipline from turning either into a signal.
    fn echoing_session() -> cerebro_tui::session::Session {
        let mut command = portable_pty::CommandBuilder::new("/bin/sh");
        command.arg("-c");
        // The greeting comes AFTER `stty`, deliberately: the line discipline echoes what is
        // written to the pty until `-echo` takes effect, so a case that settled on the first
        // bytes could be reading its own input back before `cat` was ever running - and the next
        // keystroke would then reach a shell that still had ISIG on and be killed by its own
        // Ctrl-C.
        command.arg("stty raw -echo; printf 'ready\r\n'; cat -v");
        command.env("TERM", "dumb");
        cerebro_tui::session::Session::spawn_command("Storm", command, 24, 80)
            .expect("the session spawns")
    }

    /// An `App` whose Session pane is focused and holding a live child, with that child's first
    /// bytes already seen - so the very first pass of the loop routes to it rather than to `App`.
    fn hosting(host: &mut SessionHost) -> App {
        use cerebro_tui::model::{AgentKind, RowState};
        let mut app = App::with_supervision(SupervisionMode::Supervising);
        app.finish_refresh(
            Ok(vec![cerebro_tui::model::FleetRow {
                name: "Storm".into(),
                role: "implementer".into(),
                kind: AgentKind::Interactive,
                state: RowState::Working,
                phase: None,
                bead: None,
                since: None,
                phase_since: None,
                pid: None,
                sessions: 0,
                diagnostic: None,
            }]),
            Utc::now(),
        );
        app.focus = cerebro_tui::app::PaneFocus::Session;
        host.insert("Storm", echoing_session());
        // Until the child has said `ready`, `stty` has not run and the view is `Starting`: the
        // keyboard would still be the app's, and a keystroke would reach the wrong process.
        settle_view(host, &mut app);
        app
    }

    /// Poll `sync` until the child's view is `Live`, for at most five seconds - the bound every
    /// other child in this crate gets.
    fn settle_view(host: &mut SessionHost, app: &mut App) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let view = host.sync(app.selected.as_deref(), 20, 80, Utc::now());
            let ready = match &view {
                cerebro_tui::session::SessionView::Live { lines, .. } => {
                    lines.iter().any(|line| {
                        line.spans.iter().any(|span| span.content.contains("ready"))
                    })
                }
                _ => false,
            };
            app.set_session_view(view);
            if ready {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the child never announced itself");
    }

    /// What the child has echoed back, as one string.
    fn echoed(host: &mut SessionHost, app: &App, wanted: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut text = String::new();
        while Instant::now() < deadline {
            if let cerebro_tui::session::SessionView::Live { lines, .. } =
                host.sync(app.selected.as_deref(), 20, 80, Utc::now())
            {
                text = lines
                    .iter()
                    .map(|line| {
                        line.spans.iter().map(|span| span.content.to_string()).collect::<String>()
                    })
                    .collect::<Vec<_>>()
                    .join("");
                if text.contains(wanted) {
                    return text;
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        text
    }

    #[test]
    fn a_focused_live_session_receives_every_key_but_shift_tab() {
        let mut host = SessionHost::default();
        let mut app = hosting(&mut host);
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        let mut events = ReplayedEvents::stopping(vec![
            key(KeyCode::Char('x')),
            key(KeyCode::Esc),
            ctrl(KeyCode::Char('c')),
            key(KeyCode::BackTab),
            // Focus is Work by then, so this key reaches `App::on_key` rather than the child -
            // and since cb-kcs.2.3 the live session it just left is what REFUSES the quit.
            key(KeyCode::Char('q')),
        ]);
        // `Err` is the ordinary ending: the quit is refused, so nothing ends the loop but the
        // event source running out.
        let _ = run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now);

        assert!(!app.quit, "the session this case hosts is what refuses the quit");
        assert!(app.quit_refusal.is_some(), "and the refusal pane says so");
        assert_eq!(
            app.focus,
            cerebro_tui::app::PaneFocus::Work,
            "Shift-Tab is the way out, and it is the plain cycle"
        );
        let text = echoed(&mut host, &app, "^C");
        assert!(text.contains('x'), "the plain char reached the child: {text:?}");
        assert!(text.contains("^["), "and Escape did too: {text:?}");
        assert!(text.contains("^C"), "and so did Ctrl-C: {text:?}");
    }

    #[test]
    fn q_and_ctrl_c_still_quit_when_no_session_holds_the_keyboard() {
        let mut app = App::new();
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        let mut events = ReplayedEvents::new(vec![ctrl(KeyCode::Char('c'))]);
        run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now)
            .unwrap();
        assert!(app.quit);
    }

    #[test]
    fn an_ended_session_scrolls_instead_of_typing() {
        let mut host = SessionHost::default();
        let mut app = hosting(&mut host);
        // A child that prints forty lines and exits: the pass ends, and `sync` retains it as a
        // document long enough to have somewhere to scroll.
        let mut command = portable_pty::CommandBuilder::new("/bin/sh");
        command.arg("-c");
        command.arg(r#"i=1; while [ $i -le 40 ]; do printf "line %s\r\n" $i; i=$((i+1)); done"#);
        command.env("TERM", "dumb");
        host.insert(
            "Storm",
            cerebro_tui::session::Session::spawn_command("Storm", command, 24, 80).unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let view = host.sync(app.selected.as_deref(), 20, 80, Utc::now());
            let ended = matches!(view, cerebro_tui::session::SessionView::Ended { .. });
            app.set_session_view(view);
            if ended {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            matches!(app.session.view, cerebro_tui::session::SessionView::Ended { .. }),
            "the pass ended and was retained"
        );

        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        let mut events = ReplayedEvents::new(vec![key(KeyCode::Down), key(KeyCode::Char('q'))]);
        run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now).unwrap();

        assert_eq!(app.session.scroll, 1, "Down scrolled the retained pass");
        assert!(app.quit, "and q still quits: a retained pass does not hold the keyboard");
    }

    #[test]
    fn a_paste_reaches_the_child_as_one_block() {
        let mut host = SessionHost::default();
        let mut app = hosting(&mut host);
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        // `stopping`, because the session this case hosts is what refuses the final quit since
        // cb-kcs.2.3: the event source is then the only thing that ends the loop.
        let mut events = ReplayedEvents::stopping(vec![
            Event::Paste("one\ntwo".to_string()),
            key(KeyCode::BackTab),
            key(KeyCode::Char('q')),
        ]);
        let _ = run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now);
        let text = echoed(&mut host, &app, "^[[201~");
        assert!(text.contains("^[[200~one"), "the paste arrived bracketed: {text:?}");
        assert!(text.contains("^[[201~"), "and closed: {text:?}");

        // With no live focused session there is nobody to give a paste to, and it is dropped.
        let mut app = App::new();
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        let mut events =
            ReplayedEvents::new(vec![Event::Paste("ignored".into()), key(KeyCode::Char('q'))]);
        run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now)
            .unwrap();
        assert!(app.quit);
    }

    #[test]
    fn a_hosted_session_is_counted_for_supervision() {
        let mut host = SessionHost::default();
        let mut app = hosting(&mut host);
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        // Same as above: a hosted session refuses the quit, so the source ends the loop.
        let mut events =
            ReplayedEvents::stopping(vec![key(KeyCode::BackTab), key(KeyCode::Char('q'))]);
        let (worker_handle, mut controller) = supervision();
        let _ = run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &worker_handle, &mut controller, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now);
        assert_eq!(
            controller.hosted_sessions, 1,
            "the drain branch of `reconcile_supervision` is reachable for the first time"
        );
    }

    /// A logger pointed at a root that does not exist, and never enabled.
    ///
    /// Two independent reasons it writes nothing: `Logger::new` starts disabled, and the root
    /// cannot be created. A test that wants the log asserts over its OWN `tempfile::tempdir()`;
    /// no test in this crate may hand a logger a path it did not create, or it would append
    /// fabricated starts and exits to the live file the navigator reads.
    fn test_logger() -> Logger {
        Logger::new(std::path::Path::new("/nonexistent/cb-kcs.4.4"))
    }

    fn nowhere() -> (ReaderPaths, Programs) {
        // Programs that do not exist: every read fails at once, which is the loop's ordinary
        // failure path and needs no fixture on disk.
        (
            ReaderPaths {
                consumer_root: "/nonexistent".into(),
                shared_root: "/nonexistent".into(),
                scripts_dir: "/nonexistent".into(),
            },
            Programs {
                bd: "/nonexistent/bd".into(),
                ps: "/nonexistent/ps".into(),
                // `gh` too, and not by accident: `dispatch`'s clause fires on the first loop
                // iteration of every case here, so a default `gh` would keep these tests off the
                // network only by the accident of an unspawnable cwd (review finding 1).
                gh: "/nonexistent/gh".into(),
            },
        )
    }

    fn worker() -> FleetWorker {
        let (paths, programs) = nowhere();
        FleetWorker::spawn(paths, programs, Arc::new(RealCommands))
    }

    fn work_worker() -> WorkWorker {
        let (paths, programs) = nowhere();
        WorkWorker::spawn(paths, programs, Arc::new(RealCommands))
    }

    fn gh_worker() -> GhWorker {
        let (paths, programs) = nowhere();
        GhWorker::spawn(paths, programs, Arc::new(RealCommands))
    }

    /// The sweeps' worker, pointed at a directory with no sweep scripts in it - so every request
    /// answers `sweep-claims failed` and the section is never drawn.
    fn sweep_worker() -> SweepWorker {
        let (paths, programs) = nowhere();
        SweepWorker::spawn(paths, programs, Arc::new(RealCommands))
    }

    /// The two ownership parameters, pointed at a directory with no `fleet-supervisor` in it.
    /// Every reader fails, which is exactly the read-only-with-a-lock-error case: these cases are
    /// about the terminal and the event source, and ownership must not be what decides them.
    fn supervision() -> (SupervisorWorker, SupervisorController) {
        let (paths, _) = nowhere();
        (
            SupervisorWorker::spawn(paths.clone(), Arc::new(RealCommands)),
            SupervisorController::new(&paths, &RealCommands),
        )
    }

    /// A reader that could not answer must not cost this process a lease it holds.
    ///
    /// `read_configured_supervisor` fails on a five-second timeout, a fork that failed, or any
    /// non-2 exit - all transient. Releasing on one would hand the checkout to an observer over a
    /// subprocess hiccup, which from cb-kcs.2 means moving live sessions; Emacs does not release
    /// here either.
    #[test]
    fn a_transient_reader_failure_goes_read_only_without_releasing() {
        let (paths, _) = nowhere();
        let mut controller = SupervisorController::new(&paths, &RealCommands);

        // Hold a lease on a port this test owns for its whole life.
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        controller.identity = Some("/repos/x".to_string());
        controller.record = Some(record.clone());
        // Whatever port is actually free: between a probe closing and the lease binding, anything
        // on the machine may take it, so a lost race here is setup noise and simply tries again.
        let mut held = false;
        for _ in 0..64 {
            let listener =
                std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).expect("probe");
            let addr = listener.local_addr().expect("addr");
            drop(listener);
            controller.endpoint = Some(addr);
            if controller.apply(Ok(Ok(SupervisorKind::Tui))) == SupervisionMode::Supervising {
                held = true;
                break;
            }
        }
        assert!(held && controller.lease.is_some(), "the setup must actually hold a lease");

        let failure = ReadError::Timeout { source: "fleet-supervisor".into(), seconds: 5 };
        let mode = controller.apply(Err(failure));
        assert!(
            matches!(mode, SupervisionMode::ReadOnly(ReadOnlyReason::DeclarationUnreadable(_))),
            "a failed read is read-only for its own reason: {mode:?}"
        );
        assert!(
            controller.lease.is_some(),
            "and it keeps the lease: a subprocess hiccup must not hand the checkout away"
        );
        // ... and it must not claim somebody else holds what it is holding.
        assert_eq!(
            cerebro_tui::ui::supervision_title(&mode),
            "Cerebro — read-only; fleet_supervisor could not be read",
            "a holder must never be told the lease is held by another process"
        );
        assert!(
            controller.diagnostic().is_some(),
            "and the detail is kept for the exit line rather than thrown away"
        );

        // The next good answer takes it straight back to supervising, with no reacquisition.
        assert_eq!(controller.apply(Ok(Ok(SupervisorKind::Tui))), SupervisionMode::Supervising);
        assert!(
            controller.diagnostic().is_none(),
            "a fault that resolved must not be the parting line of an hour-long session"
        );
    }

    /// A collision that resolved into a healthy mode is not the parting line either - and
    /// "healthy" is every mode but the two that ARE the fault, not `Supervising` alone.
    #[test]
    fn a_resolved_collision_does_not_become_the_parting_line() {
        let (paths, _) = nowhere();
        let mut controller = SupervisorController::new(&paths, &RealCommands);
        controller.note_diagnostic("supervision lease at 127.0.0.1:9: collided".to_string());

        let mode = controller.apply(Ok(Ok(SupervisorKind::Emacs)));
        assert_eq!(
            mode,
            SupervisionMode::ReadOnly(ReadOnlyReason::ConfiguredFor(SupervisorKind::Emacs)),
            "configured for the other view, holding nothing: healthy"
        );
        assert!(
            controller.diagnostic().is_none(),
            "a fault that resolved must not be printed on the way out"
        );
    }

    /// The documented degrade - a consumer with no lease machinery at all - notes NOTHING, so the
    /// new output channel is not loudest where nothing is wrong.
    #[test]
    fn a_consumer_with_no_lease_machinery_degrades_silently() {
        let (paths, _) = nowhere();
        let mut controller = SupervisorController::new(&paths, &RealCommands);
        assert!(
            controller.endpoint.is_none()
                && controller.identity.is_none()
                && controller.record.is_none(),
            "the setup must actually have no lease machinery"
        );

        let mode = controller.apply(Ok(Ok(SupervisorKind::Tui)));
        match mode {
            SupervisionMode::ReadOnly(ReadOnlyReason::DeclarationUnreadable(ref detail)) => {
                assert_eq!(detail, "cannot locate the supervision lease")
            }
            other => panic!("the degrade path has its own reason: {other:?}"),
        }
        assert!(
            controller.diagnostic().is_none(),
            "the degrade is not a fault and must print nothing on the way out"
        );
    }

    #[test]
    fn terminal_is_restored_after_draw_and_event_errors() {
        // 1. A draw that fails: the loop returns the error and the guard has still left the
        //    terminal.
        let events = Rc::new(RefCell::new(Vec::new()));
        {
            let mut guard = TerminalGuard::enter(Recorder {
                events: Rc::clone(&events),
                fail_on_leave: false,
            })
            .unwrap();
            let mut terminal = Terminal::new(FailingBackend).unwrap();
            let mut app = App::new();
            let error = run(
                &mut terminal,
                &mut ScriptedEvents { poll_fails: false, read_fails: false },
                &mut app,
                &worker(),
                &work_worker(),
                &gh_worker(),
                &sweep_worker(),
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(),
                &nowhere().0,
                &nowhere().1,
                &std::collections::BTreeMap::new(),
                Utc::now,
            )
            .unwrap_err();
            assert!(error.to_string().contains("the terminal went away"));
            drop(guard.leave());
        }
        assert_eq!(*events.borrow(), vec!["enter", "leave"], "left exactly once");

        // 2. An event source that fails: the same.
        let events = Rc::new(RefCell::new(Vec::new()));
        {
            let _guard = TerminalGuard::enter(Recorder {
                events: Rc::clone(&events),
                fail_on_leave: false,
            })
            .unwrap();
            let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
            let mut app = App::new();
            let error = run(
                &mut terminal,
                &mut ScriptedEvents { poll_fails: true, read_fails: false },
                &mut app,
                &worker(),
                &work_worker(),
                &gh_worker(),
                &sweep_worker(),
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(),
                &nowhere().0,
                &nowhere().1,
                &std::collections::BTreeMap::new(),
                Utc::now,
            )
            .unwrap_err();
            assert!(error.to_string().contains("poll failed"));
            // No explicit leave at all: the drop at the end of this block is the whole cleanup,
            // which is the point of the guard.
        }
        assert_eq!(*events.borrow(), vec!["enter", "leave"]);

        // 3. A read that fails after a successful poll.
        let events = Rc::new(RefCell::new(Vec::new()));
        {
            let _guard = TerminalGuard::enter(Recorder {
                events: Rc::clone(&events),
                fail_on_leave: false,
            })
            .unwrap();
            let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
            let mut app = App::new();
            assert!(run(
                &mut terminal,
                &mut ScriptedEvents { poll_fails: false, read_fails: true },
                &mut app,
                &worker(),
                &work_worker(),
                &gh_worker(),
                &sweep_worker(),
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(),
                &nowhere().0,
                &nowhere().1,
                &std::collections::BTreeMap::new(),
                Utc::now,
            )
            .is_err());
        }
        assert_eq!(*events.borrow(), vec!["enter", "leave"]);

        // 4. A panic unwinding through the guard restores the terminal too.
        let events = Rc::new(RefCell::new(Vec::new()));
        let recorded = Rc::clone(&events);
        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            let _guard = TerminalGuard::enter(Recorder {
                events: recorded,
                fail_on_leave: false,
            })
            .unwrap();
            panic!("something went wrong mid-frame");
        }));
        assert!(panicked.is_err());
        assert_eq!(*events.borrow(), vec!["enter", "leave"]);

        // 5. `q' exits cleanly, and the terminal is restored on the ordinary path as well.
        let events = Rc::new(RefCell::new(Vec::new()));
        {
            let mut guard = TerminalGuard::enter(Recorder {
                events: Rc::clone(&events),
                fail_on_leave: false,
            })
            .unwrap();
            let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
            let mut app = App::new();
            run(
                &mut terminal,
                &mut ScriptedEvents { poll_fails: false, read_fails: false },
                &mut app,
                &worker(),
                &work_worker(),
                &gh_worker(),
                &sweep_worker(),
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(),
                &nowhere().0,
                &nowhere().1,
                &std::collections::BTreeMap::new(),
                Utc::now,
            )
            .unwrap();
            assert!(app.quit, "q sets quit");
            guard.leave().unwrap();
        }
        assert_eq!(*events.borrow(), vec!["enter", "leave"], "leaving twice is refused");
    }

    /// A `bd` that takes a whole second must not stop the screen from drawing or the keyboard
    /// from working for that second. The work read runs on its own thread, so the loop goes on
    /// handling every keystroke while it is still in flight.
    #[test]
    fn work_reader_never_blocks_terminal_events() {
        // Thirty seconds, not one: the window this test needs is "longer than the loop takes",
        // and the loop's duration is the machine's business. Since cb-x3u the slowness is the
        // FAKE's rather than a bash script's - this test is about the loop, and writing an
        // executable to make it wait was scaffolding that broke four separate times.
        let slow = cerebro_tui::readers::testing::FakeCommands::new(|_| {
            std::thread::sleep(Duration::from_secs(30));
            Ok(b"[]".to_vec())
        });

        let work = WorkWorker::spawn(
            ReaderPaths {
                consumer_root: PathBuf::from("/consumer"),
                shared_root: PathBuf::from("/consumer"),
                scripts_dir: PathBuf::from("/consumer/scripts"),
            },
            Programs::default(),
            Arc::new(slow),
        );

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        let mut app = App::new();
        let mut events = QueuedEvents::new(vec![
            crossterm::event::KeyCode::Down,
            crossterm::event::KeyCode::PageDown,
            crossterm::event::KeyCode::Char('q'),
        ]);

        run(&mut terminal, &mut events, &mut app, &worker(), &work, &gh_worker(), &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now).unwrap();

        assert!(events.remaining() == 0, "every keystroke was read while bd was running");
        assert!(app.quit, "and the last of them still quit");
        // THE assertion, and why there is no stopwatch beside it. `refreshing` is true only while
        // the read has neither answered nor timed out, so a loop that waited for the reader
        // arrives here with it false — proved by mutation: making the loop block on the work read
        // fails this line, and the `PaneContent::Fresh` test tried first did NOT fail it, because
        // a blocked loop gets the reader's five-second timeout rather than the fixture's answer.
        //
        // The stopwatch this replaces read `elapsed < 500ms`, and a machine that can add five
        // seconds to a `fork` can add half a second to three keystrokes — it would have failed as
        // an accusation about production code, which is the same defect the rest of this change
        // removes, one crate over and ten times tighter. What is left has the FAKE's sleep as its
        // whole margin: nothing bounds a `FakeCommands`, so the worker sleeps all thirty seconds,
        // against the microseconds three queued keystrokes actually take. (Before cb-x3u the
        // margin was the reader's own five-second timeout, because the slowness was a real
        // child's.)
        assert!(
            app.work.refreshing,
            "the loop waited for the reader: the work read had finished by the time it exited"
        );
    }

    /// Fleet is focused on startup, so `Down` moves only Fleet's own offset. `Tab` toggles focus
    /// without touching either offset. `PageDown` then moves Work - now focused - by Work's own
    /// visible body height, never Fleet's and never the whole terminal: this is what proves
    /// `run` wires `App::focused_viewport` and each pane's own `clamp_scroll` into the loop,
    /// rather than a page size chosen once for the whole frame the way the single-document
    /// screen used to.
    #[test]
    fn keys_use_the_focused_pane_viewport() {
        use cerebro_tui::model::{AgentKind, Bead, FleetRow, RowState, WorkBuckets};

        let mut app = App::new();
        app.finish_refresh(
            Ok((0..30)
                .map(|i| FleetRow {
                    name: format!("A{i:02}"),
                    role: "implementer".into(),
                    kind: AgentKind::Interactive,
                    state: RowState::Dead,
                    phase: None,
                    bead: None,
                    since: None,
                    phase_since: None,
                    pid: None,
                    sessions: 0,
                    diagnostic: None,
                })
                .collect()),
            Utc::now(),
        );
        app.finish_work_refresh(
            Ok(WorkBuckets {
                unplanned: (1..=20)
                    .map(|n| Bead {
                        id: format!("cb-{n:03}"),
                        title: format!("item {n}"),
                        status: "open".into(),
                        issue_type: "feature".into(),
                        labels: vec![],
                        priority: Some(1),
                        updated_at: None,
                        assignee: None,
                        metadata: serde_json::Value::Null,
                        external_ref: None,
                    })
                    .collect(),
                ..WorkBuckets::default()
            }),
            Utc::now(),
        );

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        let mut events = QueuedEvents::new(vec![
            crossterm::event::KeyCode::Down,
            crossterm::event::KeyCode::Tab,
            crossterm::event::KeyCode::PageDown,
            crossterm::event::KeyCode::Char('q'),
        ]);

        // The exact viewport PageDown should move Work by, from the same layout `run` clamps by.
        let area = Rect::new(0, 0, 100, 20);
        let expected_work_page = ui::metrics(&app, Utc::now(), area).work.viewport_lines;
        assert!(expected_work_page > 0, "the fixture must actually be scrollable, or this proves nothing");

        run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now).unwrap();

        assert!(app.quit, "q still quits once both panes have been exercised");
        assert_eq!(
            app.selected.as_deref(),
            Some("A01"),
            "Down moved the SELECTION in Fleet, which is focused by default"
        );
        assert_eq!(app.focus, cerebro_tui::app::PaneFocus::Work, "Tab moved focus to Work");
        assert_eq!(app.work.scroll, expected_work_page, "PageDown moved Work by its own viewport");
    }

    /// A terminal that dips below the 40x12 floor draws the "too small" replacement screen, whose
    /// own metrics are all zero (`ui::too_small`) - and the loop must not clamp either pane's real
    /// offset against that borrowed zero, or a navigator who briefly shrank the terminal would find
    /// their scroll position silently reset the moment it came back, breaking the plan's promise
    /// that both offsets survive resizing.
    #[test]
    fn a_too_small_terminal_does_not_clamp_either_offset() {
        use cerebro_tui::model::{AgentKind, RowState};

        let mut app = App::new();
        app.finish_refresh(
            Ok((0..30)
                .map(|i| cerebro_tui::model::FleetRow {
                    name: format!("A{i:02}"),
                    role: "implementer".into(),
                    kind: AgentKind::Interactive,
                    state: RowState::Dead,
                    phase: None,
                    bead: None,
                    since: None,
                    phase_since: None,
                    pid: None,
                    sessions: 0,
                    diagnostic: None,
                })
                .collect()),
            Utc::now(),
        );
        app.fleet.scroll = 20;
        app.work.scroll = 5;
        app.session.scroll = 2;

        // Below the 40x12 floor: every draw this loop makes is the too-small replacement screen.
        let mut terminal = Terminal::new(TestBackend::new(30, 10)).unwrap();
        let mut events = QueuedEvents::new(vec![
            crossterm::event::KeyCode::Char('g'),
            crossterm::event::KeyCode::Char('q'),
        ]);
        run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now).unwrap();

        assert_eq!(app.fleet.scroll, 20, "a too-small frame must not silently reset Fleet's offset");
        assert_eq!(app.work.scroll, 5, "or Work's");
        assert_eq!(app.session.scroll, 2, "or the Session pane's");
    }

    /// The loop clamps all three offsets from the frame it has just drawn, not two of them.
    #[test]
    fn the_session_offset_is_clamped_like_the_other_two() {
        let mut app = App::with_supervision(cerebro_tui::supervisor::SupervisionMode::Supervising);
        app.finish_refresh(
            Ok(vec![cerebro_tui::model::FleetRow {
                name: "Storm".into(),
                role: "implementer".into(),
                kind: cerebro_tui::model::AgentKind::Implementer,
                state: cerebro_tui::model::RowState::Idle,
                phase: None,
                bead: None,
                since: None,
                phase_since: None,
                pid: None,
                sessions: 0,
                diagnostic: None,
            }]),
            Utc::now(),
        );
        // Far past a four-line body: the clamp must pull it back to what that body reaches.
        app.session.scroll = 500;

        let mut terminal = Terminal::new(TestBackend::new(120, 30)).unwrap();
        let mut events = QueuedEvents::new(vec![crossterm::event::KeyCode::Char('q')]);
        let area = Rect::new(0, 0, 120, 30);
        let m = ui::metrics(&app, Utc::now(), area);
        let expected = m.session.content_lines.saturating_sub(m.session.viewport_lines);

        run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &nowhere().0, &nowhere().1, &std::collections::BTreeMap::new(), Utc::now).unwrap();

        assert_eq!(app.session.scroll, expected, "the session offset is pulled back like the others");
    }

    #[test]
    fn a_failed_leave_is_reported_rather_than_swallowed() {
        let events = Rc::new(RefCell::new(Vec::new()));
        let mut guard = TerminalGuard::enter(Recorder {
            events: Rc::clone(&events),
            fail_on_leave: true,
        })
        .unwrap();
        assert!(guard.leave().is_err(), "a terminal that would not be restored says so");
        // And the drop that follows does not try again.
        drop(guard);
        assert_eq!(*events.borrow(), vec!["enter", "leave"]);
    }

    /// `leave` undoes four modes now that bracketed paste is one of them, and the rule that
    /// every step runs even after one fails lives in this fold. `Recorder` replaces
    /// `CrosstermTerminal` outright, so the crossterm calls themselves are not observable; the
    /// fold is, and it is what the fourth step changed.
    #[test]
    fn a_failed_undo_step_neither_hides_the_others_nor_the_first_error() {
        let err = |text: &str| Some(io::Error::other(text.to_string()));

        assert!(first_error([None, None, None, None]).is_ok());

        // The first failure is what is reported, whichever step it is - and a later failure
        // never shadows it.
        let reported = first_error([err("cursor"), err("paste"), None, err("raw")])
            .expect_err("a failed undo is reported");
        assert_eq!(reported.to_string(), "cursor");

        // A failure in the FIRST step must not be the only thing this can report: the caller
        // ran every step regardless, and the third one's error still surfaces on its own.
        let reported =
            first_error([None, None, err("screen"), None]).expect_err("a failed undo is reported");
        assert_eq!(reported.to_string(), "screen");

        let reported =
            first_error([None, err("paste"), None, None]).expect_err("bracketed paste too");
        assert_eq!(reported.to_string(), "paste");
    }

    #[test]
    fn missing_launcher_variables_are_named_in_a_fixed_order() {
        let all = |name: &str| Some(format!("/consumer/{name}"));
        let paths = reader_paths(all).expect("a complete environment is accepted");
        assert_eq!(paths.consumer_root.to_string_lossy(), "/consumer/CEREBRO_CONSUMER_ROOT");
        assert_eq!(
            paths.shared_root.to_string_lossy(),
            "/consumer/CEREBRO_CONSUMER_SHARED_ROOT",
            "the readers use the SHARED root"
        );
        assert_eq!(paths.scripts_dir.to_string_lossy(), "/consumer/CEREBRO_SCRIPTS");

        // The first missing name is the one reported, in the launcher's own order.
        for (missing, expected) in [
            (vec!["CEREBRO_CONSUMER_ROOT"], "CEREBRO_CONSUMER_ROOT"),
            (vec!["CEREBRO_CONSUMER_SHARED_ROOT", "CEREBRO_SCRIPTS"], "CEREBRO_CONSUMER_SHARED_ROOT"),
            (vec!["CEREBRO_CONSUMER_MOUNT"], "CEREBRO_CONSUMER_MOUNT"),
            (vec!["CEREBRO_SCRIPTS"], "CEREBRO_SCRIPTS"),
        ] {
            let missing: Vec<String> = missing.into_iter().map(str::to_string).collect();
            let message = reader_paths(|name| {
                if missing.iter().any(|m| m == name) {
                    None
                } else {
                    Some("/consumer".to_string())
                }
            })
            .unwrap_err();
            assert_eq!(
                message,
                format!(
                    "cerebro-tui: {expected} is missing - start it with .claude/cerebro/scripts/cerebro-tui"
                )
            );
        }

        // An empty value is missing: an exported-but-empty root would send `roster' looking in
        // this process's own working directory.
        let message = reader_paths(|name| {
            Some(if name == "CEREBRO_SCRIPTS" { String::new() } else { "/consumer".into() })
        })
        .unwrap_err();
        assert!(message.contains("CEREBRO_SCRIPTS is missing"), "{message}");
    }

    // ---- cb-kcs.2.3: the lifecycle keys -------------------------------------------------

    /// A scratch checkout with a `launch` that is a shell script rather than the real launcher: a
    /// case that started an agent CLI would claim a bead. EXIT is what that script does.
    fn scratch(dir: &std::path::Path, launch_body: &str) -> ReaderPaths {
        use std::os::unix::fs::PermissionsExt;
        std::fs::create_dir_all(dir.join(".cerebro/state")).unwrap();
        let launch = dir.join("launch");
        std::fs::write(&launch, format!("#!/bin/sh\n{launch_body}\n")).unwrap();
        let mut perms = std::fs::metadata(&launch).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&launch, perms).unwrap();
        ReaderPaths {
            consumer_root: dir.to_path_buf(),
            shared_root: dir.to_path_buf(),
            scripts_dir: dir.to_path_buf(),
        }
    }

    fn fleet_row(name: &str, kind: cerebro_tui::model::AgentKind, state: cerebro_tui::model::RowState) -> cerebro_tui::model::FleetRow {
        cerebro_tui::model::FleetRow {
            name: name.into(),
            role: "implementer".into(),
            kind,
            state,
            phase: None,
            bead: None,
            since: None,
            phase_since: None,
            pid: None,
            sessions: 0,
            diagnostic: None,
        }
    }

    /// An app with ROWS, the first selected, in the given supervision mode.
    fn lifecycle_app(
        mode: cerebro_tui::supervisor::SupervisionMode,
        rows: Vec<cerebro_tui::model::FleetRow>,
    ) -> App {
        let mut app = App::with_supervision(mode);
        let first = rows[0].name.clone();
        app.finish_refresh(Ok(rows), Utc::now());
        app.selected = Some(first);
        app
    }

    /// Send KEYS through `route_key`, which is the whole keystroke path this bead adds.
    ///
    /// Deliberately NOT through `run` for the cases that depend on the supervision mode. `run`
    /// polls the ownership worker before it reads a key, and this fixture's worker answers from a
    /// directory with no `fleet-supervisor` in it - so it replaces `Supervising` with a read-only
    /// lock error at a moment decided by how fast a thread ran, and a case asserting what `s` did
    /// while supervising would pass or fail on that race. `route_key` is the same code the loop
    /// calls, with the mode held still.
    fn drive(
        app: &mut App,
        host: &mut SessionHost,
        paths: &ReaderPaths,
        keys: Vec<crossterm::event::KeyEvent>,
    ) {
        for key in keys {
            route_key(key, app, host, &mut StartLedger::default(), &mut test_logger(), paths, &Programs::default(), 10, Utc::now());
        }
    }

    /// The same keys, through the whole loop - for the cases about quitting, which the supervision
    /// mode has no part in.
    fn drive_loop(
        app: &mut App,
        host: &mut SessionHost,
        paths: &ReaderPaths,
        keys: Vec<crossterm::event::KeyEvent>,
    ) {
        let mut terminal = Terminal::new(TestBackend::new(120, 24)).unwrap();
        let mut events = QueuedEvents::events(keys);
        // `Err` is the ordinary ending here: the source stops the loop when the keys are spent.
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let _ = run(&mut terminal, &mut events, app, &worker(), &work_worker(),
                &gh_worker(),
                &sweep_worker(),
            &supervision().0, &mut supervision().1, host, &mut ledger, &mut test_logger(), paths,
            &nowhere().1, &std::collections::BTreeMap::new(), Utc::now);
    }


    /// `SessionHost::kill` signals the child and leaves it to be reaped by the next `sync`, so a
    /// killed pass becomes an ordinary retained transcript. Poll until that has happened.
    fn settle_gone(host: &mut SessionHost, name: &str) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while host.is_live(name) {
            host.sync(Some(name), 24, 80, Utc::now());
            if std::time::Instant::now() >= deadline {
                panic!("{name} was signalled and never reaped");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    // ---- cb-kcs.3: what the view does unattended ----------------------------------------

    /// A fleet row with a state file's `since` STOOD seconds ago.
    fn stood_row(
        name: &str,
        kind: cerebro_tui::model::AgentKind,
        state: cerebro_tui::model::RowState,
        stood: i64,
        now: DateTime<Utc>,
    ) -> cerebro_tui::model::FleetRow {
        cerebro_tui::model::FleetRow {
            since: Some(now - chrono::Duration::seconds(stood)),
            ..fleet_row(name, kind, state)
        }
    }

    /// A hosted session under NAME that stays up until something ends it, and a state file for
    /// it - the two things supervision acts on.
    fn hosted(host: &mut SessionHost, paths: &ReaderPaths, name: &str) {
        let mut command = portable_pty::CommandBuilder::new("/bin/sh");
        command.arg("-c");
        command.arg("while :; do sleep 1; done");
        host.insert(
            name,
            cerebro_tui::session::Session::spawn_command(name, command, 24, 80)
                .expect("the session spawns"),
        );
        std::fs::write(cerebro_tui::lifecycle::state_file_path(paths, name), "{}")
            .expect("a state file");
    }

    fn supervising() -> cerebro_tui::supervisor::SupervisionMode {
        cerebro_tui::supervisor::SupervisionMode::Supervising
    }

    #[test]
    fn a_finished_pass_is_ended_after_the_grace_and_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        hosted(&mut host, &paths, "Cyclops");
        let flag = cerebro_tui::lifecycle::stop_flag_path(&paths, "Cyclops");

        let mut app = lifecycle_app(
            supervising(),
            vec![stood_row("Cyclops", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Waiting, 31, now)],
        );
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, Instant::now());

        assert!(!host.supervisable("Cyclops"), "the session was ended");
        assert!(
            !cerebro_tui::lifecycle::state_file_path(&paths, "Cyclops").exists(),
            "a file naming an ended session names a pid that is gone"
        );
        assert!(!flag.exists(), "an end writes no flag");
        assert_eq!(app.notice.as_deref(), Some("Cyclops finished its pass and was ended."));
        settle_gone(&mut host, "Cyclops");
    }

    #[test]
    fn a_stop_flag_retires_at_once_and_clears_itself() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        hosted(&mut host, &paths, "Storm");
        let flag = cerebro_tui::lifecycle::stop_flag_path(&paths, "Storm");
        std::fs::write(&flag, "").unwrap();

        // Ten seconds old: nothing is in flight, so there is nothing for the grace to protect.
        let mut app = lifecycle_app(
            supervising(),
            vec![stood_row("Storm", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Waiting, 10, now)],
        );
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, Instant::now());

        assert!(!host.supervisable("Storm"));
        assert!(!flag.exists(), "the next session under that name must not inherit the flag");
        assert_eq!(app.notice.as_deref(), Some("Storm was retired; its stop flag is cleared."));
        settle_gone(&mut host, "Storm");
    }

    #[test]
    fn a_session_this_view_does_not_host_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let state = cerebro_tui::lifecycle::state_file_path(&paths, "Rogue");
        std::fs::write(&state, "{}").unwrap();

        let mut app = lifecycle_app(
            supervising(),
            vec![stood_row("Rogue", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Waiting, 5_000, now)],
        );
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, Instant::now());

        assert!(state.exists(), "somebody else's session is theirs to end");
        assert_eq!(app.notice, None);
    }

    #[test]
    fn a_read_only_view_supervises_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        hosted(&mut host, &paths, "Cyclops");

        let mut app = lifecycle_app(
            cerebro_tui::supervisor::SupervisionMode::ReadOnly(
                cerebro_tui::supervisor::ReadOnlyReason::NotOwned,
            ),
            vec![stood_row("Cyclops", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Waiting, 5_000, now)],
        );
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, Instant::now());

        assert!(host.supervisable("Cyclops"), "a read-only view ends nothing");
        assert!(cerebro_tui::lifecycle::state_file_path(&paths, "Cyclops").exists());
        assert_eq!(app.notice, None);
    }

    #[test]
    fn a_draining_view_still_ends_but_does_not_nudge() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        hosted(&mut host, &paths, "Cyclops");
        hosted(&mut host, &paths, "Storm");

        let draining = cerebro_tui::supervisor::SupervisionMode::Draining {
            configured_for: Some(cerebro_tui::supervisor::SupervisorKind::Emacs),
            live_sessions: 2,
        };
        let mut app = lifecycle_app(
            draining,
            vec![
                stood_row("Storm", cerebro_tui::model::AgentKind::Implementer,
                    cerebro_tui::model::RowState::Asking, 5_000, now),
                stood_row("Cyclops", cerebro_tui::model::AgentKind::Implementer,
                    cerebro_tui::model::RowState::Waiting, 31, now),
            ],
        );
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, Instant::now());

        // Ending is what ends the drain, so it still happens.
        assert!(!host.supervisable("Cyclops"));
        // A nudge is a NEW instruction, and a view handing supervision over issues none.
        assert!(app.nudged.is_empty(), "a draining view nudges nobody");
        assert!(host.supervisable("Storm"));
        settle_gone(&mut host, "Cyclops");
    }

    #[test]
    fn a_question_nobody_answered_is_nudged_once() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        // A shell that echoes each line it is given, so the nudge is observable as output.
        let mut command = portable_pty::CommandBuilder::new("/bin/sh");
        command.arg("-c");
        command.arg("while read line; do printf 'got:%s\r\n' \"$line\"; done");
        host.insert(
            "Cyclops",
            cerebro_tui::session::Session::spawn_command("Cyclops", command, 24, 200)
                .expect("the session spawns"),
        );

        let asking = |stood| {
            vec![stood_row("Cyclops", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Asking, stood, now)]
        };
        let mut app = lifecycle_app(supervising(), asking(16 * 60));
        let at = Instant::now();
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, at);
        assert!(app.nudged.contains("Cyclops"));
        assert_eq!(app.notice.as_deref(), Some("Cyclops was asked to hand its question back."));

        // The return is sent separately, and only once it is due.
        host.flush_returns(at);
        app.notice = None;
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, at);
        assert_eq!(app.notice, None, "one nudge per question, not one per tick");
        host.flush_returns(at + cerebro_tui::session::RETURN_DELAY);

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let view = host.sync(Some("Cyclops"), 24, 200, Utc::now());
            let text: Vec<String> = match &view {
                cerebro_tui::session::SessionView::Live { lines, .. } => lines
                    .iter()
                    .map(|line| {
                        line.spans.iter().map(|s| s.content.as_ref()).collect::<String>()
                    })
                    .collect(),
                _ => Vec::new(),
            };
            if text.iter().any(|line| line.contains("got:[cerebro] Nobody answered")) {
                break;
            }
            if std::time::Instant::now() >= deadline {
                panic!("the nudge never reached the child: {text:?}");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        // Answered, and asking again: nudgeable again.
        app.finish_refresh(
            Ok(vec![stood_row("Cyclops", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Working, 1, now)]),
            now,
        );
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, at);
        assert!(app.nudged.is_empty(), "a name leaves the set as soon as it stops asking");

        app.finish_refresh(Ok(asking(16 * 60)), now);
        app.notice = None;
        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, at);
        assert_eq!(app.notice.as_deref(), Some("Cyclops was asked to hand its question back."));
    }

    fn ch(c: char) -> crossterm::event::KeyEvent {
        crossterm::event::KeyEvent::new(
            crossterm::event::KeyCode::Char(c),
            crossterm::event::KeyModifiers::NONE,
        )
    }

    use cerebro_tui::model::{AgentKind, RowState};
    use cerebro_tui::supervisor::SupervisionMode;

    #[test]
    fn s_starts_the_selected_agent_and_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![fleet_row("Rogue", AgentKind::Interactive, RowState::Dead)],
        );
        let mut host = SessionHost::default();
        drive(&mut app, &mut host, &paths, vec![ch('s')]);

        assert!(host.is_live("Rogue"), "the host holds a session for the selected agent");
        assert_eq!(app.notice.as_deref(), Some("Started Rogue."));
    }

    #[test]
    fn s_on_an_implementer_with_a_stale_flag_clears_it_and_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        cerebro_tui::lifecycle::write_stop_flag(&paths, "Cyclops").unwrap();
        // A state file a previous session left behind: a start deletes it, because one that
        // outlives its session outlives its pid.
        std::fs::write(cerebro_tui::lifecycle::state_file_path(&paths, "Cyclops"), "{}").unwrap();

        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Dead)],
        );
        let mut host = SessionHost::default();
        drive(&mut app, &mut host, &paths, vec![ch('s')]);

        assert!(!cerebro_tui::lifecycle::stop_flag_set(&paths, "Cyclops"));
        assert!(!cerebro_tui::lifecycle::state_file_path(&paths, "Cyclops").exists());
        assert_eq!(
            app.notice.as_deref(),
            Some("Started Cyclops, and cleared a stale stop flag.")
        );
    }

    #[test]
    fn f_is_a_toggle() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Working)],
        );
        let mut host = SessionHost::default();
        host.insert("Cyclops", forever());

        drive(&mut app, &mut host, &paths, vec![ch('f')]);
        assert!(cerebro_tui::lifecycle::stop_flag_set(&paths, "Cyclops"));
        assert_eq!(app.notice.as_deref(), Some("Cyclops will finish after this pass."));

        drive(&mut app, &mut host, &paths, vec![ch('f')]);
        assert!(!cerebro_tui::lifecycle::stop_flag_set(&paths, "Cyclops"));
        assert_eq!(app.notice.as_deref(), Some("Cyclops will keep going."));
    }

    #[test]
    fn k_asks_before_it_kills() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        cerebro_tui::lifecycle::write_stop_flag(&paths, "Cyclops").unwrap();
        std::fs::write(cerebro_tui::lifecycle::state_file_path(&paths, "Cyclops"), "{}").unwrap();

        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Working)],
        );
        let mut host = SessionHost::default();
        host.insert("Cyclops", forever());

        // `k` alone asks, and kills nothing. `q` at the prompt cancels it rather than quitting,
        // so a second `q` is what ends the loop.
        drive(&mut app, &mut host, &paths, vec![ch('k')]);
        assert!(
            matches!(&app.confirm, Some(cerebro_tui::app::Prompt::Kill { name, .. }) if name == "Cyclops"),
            "{:?}",
            app.confirm
        );
        assert!(host.is_live("Cyclops"), "asking kills nothing");

        drive(&mut app, &mut host, &paths, vec![ch('y')]);
        assert_eq!(app.confirm, None);
        settle_gone(&mut host, "Cyclops");
        assert!(!host.is_live("Cyclops"), "y kills it");
        assert!(
            !cerebro_tui::lifecycle::state_file_path(&paths, "Cyclops").exists(),
            "and the state file goes with the session"
        );
        assert!(
            cerebro_tui::lifecycle::stop_flag_set(&paths, "Cyclops"),
            "the stop flag is left alone: k is not a retire"
        );
    }

    #[test]
    fn any_key_but_y_cancels_a_kill_silently() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Working)],
        );
        let mut host = SessionHost::default();
        host.insert("Cyclops", forever());

        drive(&mut app, &mut host, &paths, vec![ch('k'), ch('q')]);
        assert!(host.is_live("Cyclops"), "nothing was killed");
        assert_eq!(app.confirm, None, "the confirmation is gone");
        assert_eq!(app.notice, None, "a line for a non-event is not written (Q10)");
        assert!(!app.quit, "q at the prompt cancels the kill and does not also quit");
    }

    #[test]
    fn a_read_only_view_refuses_every_lifecycle_key() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let read_only = SupervisionMode::ReadOnly(
            cerebro_tui::supervisor::ReadOnlyReason::ConfiguredFor(
                cerebro_tui::supervisor::SupervisorKind::Emacs,
            ),
        );
        for key in ['s', 'f', 'k'] {
            let mut app = lifecycle_app(
                read_only.clone(),
                vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Dead)],
            );
            let mut host = SessionHost::default();
            drive(&mut app, &mut host, &paths, vec![ch(key)]);
            assert_eq!(host.live_count(), 0, "{key} started nothing");
            assert!(!cerebro_tui::lifecycle::stop_flag_set(&paths, "Cyclops"), "{key} wrote nothing");
            assert_eq!(
                app.notice.as_deref(),
                Some("This view is read-only; it starts and stops nothing"),
                "for {key}"
            );
        }
    }

    #[test]
    fn a_draining_view_refuses_s_and_allows_k() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let draining = SupervisionMode::Draining { configured_for: None, live_sessions: 1 };

        let mut app = lifecycle_app(
            draining.clone(),
            vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Working)],
        );
        let mut host = SessionHost::default();
        host.insert("Cyclops", forever());
        drive(&mut app, &mut host, &paths, vec![ch('s')]);
        assert_eq!(
            app.notice.as_deref(),
            Some("Handoff pending: 1 session still hosted; only f and k act now")
        );

        drive(&mut app, &mut host, &paths, vec![ch('k'), ch('y')]);
        settle_gone(&mut host, "Cyclops");
        assert!(!host.is_live("Cyclops"), "ending a hosted session is what ends a drain");
    }

    #[test]
    fn k_refuses_an_agent_this_view_did_not_start() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![fleet_row("Storm", AgentKind::Implementer, RowState::Working)],
        );
        let mut host = SessionHost::default();
        drive(&mut app, &mut host, &paths, vec![ch('k')]);
        assert_eq!(app.confirm, None, "nothing was even asked");
        assert_eq!(
            app.notice.as_deref(),
            Some("Storm is running outside this view - stop it from its own terminal")
        );
    }

    #[test]
    fn quitting_over_a_live_agent_is_refused_and_any_key_returns() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![
                fleet_row("Xavier", AgentKind::Interactive, RowState::Working),
                fleet_row("Cyclops", AgentKind::Implementer, RowState::Working),
            ],
        );
        let mut host = SessionHost::default();
        host.insert("Cyclops", forever());

        drive_loop(&mut app, &mut host, &paths, vec![ch('q')]);
        assert!(!app.quit, "a live agent stops the navigator leaving");
        assert_eq!(app.quit_refusal.as_deref(), Some(&["Cyclops".to_string()][..]));

        // Any key returns from the pane and does nothing else - `k` included, which must not kill.
        drive_loop(&mut app, &mut host, &paths, vec![ch('k')]);
        assert_eq!(app.quit_refusal, None);
        assert_eq!(app.confirm, None, "the dismissing key did not also act");
        assert!(host.is_live("Cyclops"));

        // With no session hosted, `q` exits exactly as it always has.
        let mut empty = SessionHost::default();
        drive_loop(&mut app, &mut empty, &paths, vec![ch('q')]);
        assert!(app.quit);
    }

    /// The one case the quit refusal exists for, and the one this bead first got wrong.
    ///
    /// `roster_order()` is empty until a fleet read has SUCCEEDED, so with a hosted child and a
    /// fleet reader that has never answered - the ordinary state of the first few seconds, and the
    /// permanent state of a broken `scripts/roster` - a refusal built from the roster alone would
    /// name nobody, read as "nothing is live", and let `q` through. `Session::Drop` would then kill
    /// the agents on the way out.
    #[test]
    fn a_quit_is_refused_even_before_the_fleet_has_been_read() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        // No `finish_refresh` at all: the fleet pane has never had a value.
        let mut app = App::with_supervision(SupervisionMode::Supervising);
        assert!(app.roster_order().is_empty(), "the fixture must have no roster, or this proves nothing");

        let mut host = SessionHost::default();
        host.insert("Cyclops", forever());
        drive_loop(&mut app, &mut host, &paths, vec![ch('q')]);

        assert!(!app.quit, "a hosted child the roster does not name still refuses the quit");
        assert_eq!(
            app.quit_refusal.as_deref(),
            Some(&["Cyclops".to_string()][..]),
            "and it is named, because a pane that named nobody would say nothing is live"
        );
    }

    #[test]
    fn ctrl_c_and_esc_are_refused_the_same_way() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let ctrl_c = crossterm::event::KeyEvent::new(
            crossterm::event::KeyCode::Char('c'),
            crossterm::event::KeyModifiers::CONTROL,
        );
        let esc = crossterm::event::KeyEvent::new(
            crossterm::event::KeyCode::Esc,
            crossterm::event::KeyModifiers::NONE,
        );
        for key in [ctrl_c, esc] {
            let mut app = lifecycle_app(
                SupervisionMode::Supervising,
                vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Working)],
            );
            let mut host = SessionHost::default();
            host.insert("Cyclops", forever());
            drive_loop(&mut app, &mut host, &paths, vec![key]);
            assert!(!app.quit, "{key:?} is refused too");
            assert!(app.quit_refusal.is_some(), "{key:?}");
        }
    }

    /// A child that stays up for the length of a case. `/bin/sh` and nothing else: a case that
    /// started a real agent would claim a bead.
    fn forever() -> cerebro_tui::session::Session {
        let mut command = portable_pty::CommandBuilder::new("/bin/sh");
        command.arg("-c");
        command.arg("while :; do sleep 1; done");
        command.env("TERM", "dumb");
        cerebro_tui::session::Session::spawn_command("child", command, 24, 80)
            .expect("the session spawns")
    }

    // ---- cb-kcs.4.1: what the view starts by itself --------------------------------------

    fn planner_row(name: &str, state: cerebro_tui::model::RowState) -> cerebro_tui::model::FleetRow {
        cerebro_tui::model::FleetRow {
            role: "planner".into(),
            ..fleet_row(name, cerebro_tui::model::AgentKind::Interactive, state)
        }
    }

    fn planner_roster(names: &[&str]) -> Vec<cerebro_tui::model::RosterEntry> {
        names
            .iter()
            .map(|name| cerebro_tui::model::RosterEntry {
                name: (*name).to_string(),
                role: "planner".to_string(),
                kind: cerebro_tui::model::AgentKind::Interactive,
            })
            .collect()
    }

    /// A board with one unplanned P4 bead and nothing planned: a short buffer with something to
    /// plan, which is the planner's second arm.
    fn short_buffer() -> cerebro_tui::model::WorkBuckets {
        cerebro_tui::model::partition_beads(vec![cerebro_tui::model::Bead {
            id: "cb-a".into(),
            title: "cb-a".into(),
            status: "open".into(),
            issue_type: "task".into(),
            labels: Vec::new(),
            priority: Some(4),
            updated_at: None,
            assignee: None,
            metadata: serde_json::Value::Null,
            external_ref: None,
        }])
    }

    /// An app on standby for NAMES, with the given work snapshot applied.
    fn standby_app(
        mode: cerebro_tui::supervisor::SupervisionMode,
        rows: Vec<cerebro_tui::model::FleetRow>,
        work: Option<cerebro_tui::model::WorkBuckets>,
        now: DateTime<Utc>,
    ) -> App {
        let mut app = App::with_supervision(mode);
        app.armed = rows.iter().map(|row| row.name.clone()).collect();
        app.finish_refresh(Ok(rows), now);
        if let Some(work) = work {
            app.finish_work_refresh(Ok(work), now);
        }
        app
    }

    #[test]
    fn a_standby_planner_whose_buffer_is_short_is_started() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(short_buffer()),
            now,
        );
        assert_eq!(app.fleet_rows()[0].state, cerebro_tui::model::RowState::Standby);

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(), &roster, now);

        assert!(host.is_live("Xavier"), "the standby planner was started");
        assert!(app.armed.contains("Xavier"), "and stays armed");
        assert_eq!(ledger.started_at("Xavier"), Some(now));
        assert!(ledger.fingerprint("Xavier").is_some(), "with what triggered it");
        assert_eq!(app.notice.as_deref(), Some("Started Xavier — buffer 0 of 2."));
        assert_eq!(
            app.standby_labels.get("Xavier").map(String::as_str),
            Some("→ buffer<2")
        );
        host.kill(&paths, "Xavier");
        settle_gone(&mut host, "Xavier");
    }

    #[test]
    fn two_planners_are_not_started_in_the_same_breath() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier", "Beast"]);
        let mut app = standby_app(
            supervising(),
            vec![
                planner_row("Xavier", cerebro_tui::model::RowState::Dead),
                planner_row("Beast", cerebro_tui::model::RowState::Dead),
            ],
            Some(short_buffer()),
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(), &roster, now);

        // The spacing is read INSIDE the loop, so the second planner already sees the first.
        assert!(host.is_live("Xavier"));
        assert!(!host.is_live("Beast"), "the second is held by role-start spacing");
        assert_eq!(ledger.started_at("Beast"), None);
        host.kill(&paths, "Xavier");
        settle_gone(&mut host, "Xavier");
    }

    #[test]
    fn a_flagged_standby_name_is_never_started() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        cerebro_tui::lifecycle::write_stop_flag(&paths, "Xavier").unwrap();
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(short_buffer()),
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(), &roster, now);

        assert!(!host.is_live("Xavier"), "a flagged name is never started, whatever its trigger");
        assert!(
            cerebro_tui::lifecycle::stop_flag_path(&paths, "Xavier").exists(),
            "and its flag is left alone"
        );
    }

    #[test]
    fn no_work_snapshot_starts_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            None,
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(), &roster, now);

        assert!(!host.is_live("Xavier"), "no board, no starts");
    }

    #[test]
    fn a_draining_view_starts_nothing_and_clears_the_armed_set() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        let draining = cerebro_tui::supervisor::SupervisionMode::Draining {
            configured_for: Some(cerebro_tui::supervisor::SupervisorKind::Emacs),
            live_sessions: 1,
        };
        let mut app = standby_app(
            draining,
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(short_buffer()),
            now,
        );

        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, Instant::now());
        assert!(app.armed.is_empty(), "a drain keeps no promise it will not keep");

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(), &roster, now);
        assert!(!host.is_live("Xavier"));
    }

    #[test]
    fn a_confirmed_disarm_greys_the_row_and_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut host = SessionHost::default();
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            None,
            Utc::now(),
        );
        app.selected = Some("Xavier".to_string());

        drive(&mut app, &mut host, &paths, vec![ch('k')]);
        assert!(
            matches!(&app.confirm, Some(cerebro_tui::app::Prompt::Disarm { name, .. }) if name == "Xavier")
        );
        drive(&mut app, &mut host, &paths, vec![ch('y')]);

        assert!(!app.armed.contains("Xavier"), "the name left the armed set");
        assert_eq!(
            app.notice.as_deref(),
            Some("Xavier is disarmed; the view will not bring it back.")
        );
        // And the row greys on the refresh the key asked for: `apply_standby` has nothing left to
        // restate it from.
        app.finish_refresh(
            Ok(vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)]),
            Utc::now(),
        );
        assert_eq!(app.fleet_rows()[0].state, cerebro_tui::model::RowState::Dead);
    }

    #[test]
    fn a_cancelled_disarm_leaves_the_name_armed() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut host = SessionHost::default();
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            None,
            Utc::now(),
        );
        app.selected = Some("Xavier".to_string());

        drive(&mut app, &mut host, &paths, vec![ch('k'), ch('n')]);
        assert!(app.confirm.is_none(), "anything but y cancels");
        assert!(app.armed.contains("Xavier"));
        assert_eq!(app.notice, None);
    }

    #[test]
    fn retiring_a_standby_implementer_disarms_it() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        cerebro_tui::lifecycle::write_stop_flag(&paths, "Cyclops").unwrap();
        let mut app = standby_app(
            supervising(),
            vec![fleet_row("Cyclops", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Dead)],
            None,
            now,
        );

        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(), &mut test_logger(), &paths, now, Instant::now());

        assert!(!app.armed.contains("Cyclops"), "a retire disarms");
        assert!(!cerebro_tui::lifecycle::stop_flag_path(&paths, "Cyclops").exists());
    }

    #[test]
    fn a_start_that_could_not_spawn_parks_the_row_rather_than_retrying_for_ever() {
        let dir = tempfile::tempdir().unwrap();
        // No `launch` in this scratch checkout at all: `lifecycle::start` returns Err, which is
        // the one refusal path that never becomes a process and so has no exit status to read.
        std::fs::create_dir_all(dir.path().join(".cerebro/state")).unwrap();
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().to_path_buf(),
            scripts_dir: dir.path().to_path_buf(),
        };
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(short_buffer()),
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, now);
        assert!(!host.is_live("Xavier"));
        assert!(
            host.exits().contains_key("Xavier"),
            "a spawn that failed is a verdict, or nothing parks the row"
        );

        // The next fleet read parks it: no blue dotted circle, so no second launch on this or any
        // later tick. Without a backoff (cb-kcs.4.2's), that is the whole of Q5.
        app.set_exits(host.exits());
        app.finish_refresh(
            Ok(vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)]),
            now,
        );
        assert_eq!(app.fleet_rows()[0].state, cerebro_tui::model::RowState::Dead);

        // A second tick, a minute later. `is_live` would be false either way in a checkout with
        // no launcher, so what is asserted is that no SECOND attempt was made: a retry would
        // replace the refusal with one stamped `later`.
        let later = now + chrono::Duration::seconds(60);
        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, later);
        match host.sync(Some("Xavier"), 24, 80, later) {
            cerebro_tui::session::SessionView::Refused { at, .. } => {
                assert_eq!(at, now, "the row was not started again");
            }
            other => panic!("expected the refusal to stand, got {other:?}"),
        }
    }

    // --- cb-kcs.4.4: the two logs -------------------------------------------------------------
    //
    // Every case here builds its own root and points the logger at it. NONE of them may reach the
    // repository's own `.cerebro/state`.

    /// An enabled logger over ROOT, which is also the fixture's shared root.
    fn logging(root: &std::path::Path) -> Logger {
        let mut logger = Logger::new(root);
        logger.set_enabled(true);
        logger
    }

    fn log_lines(root: &std::path::Path, base: &str) -> Vec<String> {
        match std::fs::read_to_string(cerebro_tui::log_file(root, base, None)) {
            Ok(text) => text.lines().map(str::to_string).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// The one line whose `"event"` is EVENT, or a panic naming what was there instead.
    fn one_line(root: &std::path::Path, base: &str, event: &str) -> String {
        let wanted = format!(r#"{{"event":"{event}","#);
        let all = log_lines(root, base);
        let mut found: Vec<String> =
            all.iter().filter(|line| line.starts_with(&wanted)).cloned().collect();
        assert_eq!(found.len(), 1, "expected exactly one {event} line, got {all:#?}");
        found.remove(0)
    }

    #[test]
    fn a_start_the_trigger_decided_names_the_trigger_that_fired() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut logger = logging(dir.path());
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(short_buffer()),
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut logger, &paths, &BTreeMap::new(), &roster, now);

        assert!(host.is_live("Xavier"));
        let line = one_line(dir.path(), "decisions", "start");
        assert!(line.contains(r#""agent":"Xavier","role":"planner","reason":"buffer 0 of 2","by":"trigger""#), "{line}");
        host.kill(&paths, "Xavier");
        settle_gone(&mut host, "Xavier");
    }

    #[test]
    fn a_start_the_navigator_asked_for_says_navigator() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut logger = logging(dir.path());
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = lifecycle_app(
            supervising(),
            vec![fleet_row("Rogue", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Dead)],
        );

        route_key(ch('s'), &mut app, &mut host, &mut ledger, &mut logger, &paths, &Programs::default(), 10, now);

        assert!(host.is_live("Rogue"));
        let line = one_line(dir.path(), "decisions", "start");
        assert!(
            line.contains(r#""agent":"Rogue","role":"implementer","reason":null,"by":"navigator""#),
            "{line}"
        );
        host.kill(&paths, "Rogue");
        settle_gone(&mut host, "Rogue");
    }

    #[test]
    fn the_roster_arms_the_standby_half_and_logs_nothing_for_the_other() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let declaration = declaring_with_table(
            "Cyclops",
            "Xavier\nBeast",
            "Cyclops\timplementer\timplementer\nXavier\tplanner\tinteractive\nBeast\tplanner\tinteractive\n",
        );
        let mut logger = logging(dir.path());
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = App::with_supervision(supervising());

        arm_and_autostart(
            &mut app,
            &mut host,
            &mut ledger,
            &mut logger,
            &paths,
            &declaration,
            &[],
            now,
        );

        let arms: Vec<String> = log_lines(dir.path(), "decisions")
            .into_iter()
            .filter(|line| line.starts_with(r#"{"event":"arm","#))
            .collect();
        assert_eq!(arms.len(), 2, "one per standby name, and none for the autostart one: {arms:#?}");
        // The ROLE too, and it is the whole of review finding 1: this runs before the fleet worker
        // has been polled once, so a role taken from the fleet pane is the empty string here
        // ALWAYS rather than rarely - and Emacs writes the real one into the same file.
        assert!(
            arms[0].contains(r#""agent":"Xavier","role":"planner","by":"roster""#),
            "{}", arms[0]
        );
        assert!(arms[1].contains(r#""agent":"Beast","role":"planner","by":"roster""#), "{}", arms[1]);
        // And the autostarted name got a `start` line instead, as the navigator's own act.
        let start = one_line(dir.path(), "decisions", "start");
        assert!(
            start.contains(r#""agent":"Cyclops","role":"implementer","reason":null,"by":"navigator""#),
            "{start}"
        );
        host.kill(&paths, "Cyclops");
        settle_gone(&mut host, "Cyclops");
    }

    /// A row whose pass is over and one under a stop flag: both are decisions, and both are
    /// written with the five fields elisp writes.
    #[test]
    fn ending_and_retiring_are_both_written_down() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut logger = logging(dir.path());
        let now = Utc::now();
        let mut host = SessionHost::default();
        cerebro_tui::lifecycle::start(&mut host, &paths, "Rogue", false).unwrap();
        cerebro_tui::lifecycle::start(&mut host, &paths, "Storm", false).unwrap();
        cerebro_tui::lifecycle::write_stop_flag(&paths, "Storm").unwrap();
        let mut waiting = fleet_row("Rogue", cerebro_tui::model::AgentKind::Implementer,
            cerebro_tui::model::RowState::Waiting);
        waiting.since = Some(now - chrono::Duration::seconds(600));
        waiting.bead = Some("cb-kcs.4.4".to_string());
        let mut flagged = fleet_row("Storm", cerebro_tui::model::AgentKind::Implementer,
            cerebro_tui::model::RowState::Idle);
        flagged.since = Some(now);
        let mut app = lifecycle_app(supervising(), vec![waiting, flagged]);

        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(),
            &mut logger, &paths, now, Instant::now());

        let end = one_line(dir.path(), "decisions", "end");
        assert!(
            end.contains(r#""agent":"Rogue","role":"implementer","state":"waiting","bead":"cb-kcs.4.4","stop_flag":null"#),
            "{end}"
        );
        let retire = one_line(dir.path(), "decisions", "retire");
        assert!(
            retire.contains(r#""agent":"Storm","role":"implementer","state":"idle","bead":null,"stop_flag":"set""#),
            "{retire}"
        );
    }

    #[test]
    fn an_exit_is_written_for_an_ending_this_view_did_not_cause() {
        let dir = tempfile::tempdir().unwrap();
        let mut logger = logging(dir.path());
        let now = Utc::now();
        let mut host = SessionHost::default();

        // A child that ended on its own, and one this view ended: both are reaped, one is logged.
        let paths = scratch(dir.path(), "exit 3");
        cerebro_tui::lifecycle::start(&mut host, &paths, "Rogue", false).unwrap();
        let paths_long = scratch(&dir.path().join("long"), "sleep 5");
        cerebro_tui::lifecycle::start(&mut host, &paths_long, "Storm", false).unwrap();
        host.end(&paths_long, "Storm");
        settle_gone(&mut host, "Rogue");
        settle_gone(&mut host, "Storm");

        log_exits(&mut logger, &mut host, now);

        let exit = one_line(dir.path(), "decisions", "exit");
        assert!(
            exit.contains(r#""agent":"Rogue","code":"3","abnormal":true,"last_line":null"#),
            "the child that died on its own, with `abnormal` true and never false: {exit}"
        );
        assert!(!exit.contains("Storm"), "and nothing at all for the one this view ended");
    }

    #[test]
    fn a_name_given_up_on_is_written_to_both_files() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut logger = logging(dir.path());
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        // Four failed starts already, and the last one long enough ago that the backoff has run
        // out: the fifth is the one that gives up.
        // The end is BEFORE the start: a launch that never became a session leaves the previous
        // pass's end behind it, which is exactly what `start_failed` reads.
        ledger.note_ended("Xavier", now - chrono::Duration::seconds(3700));
        ledger.note_started("Xavier", now - chrono::Duration::seconds(3600), None);
        ledger.set_failures("Xavier", 4);
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(short_buffer()),
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut logger, &paths, &BTreeMap::new(), &roster, now);

        assert!(!host.is_live("Xavier"), "the fifth start is not attempted");
        let gave_up = one_line(dir.path(), "decisions", "give-up");
        assert!(
            gave_up.contains(r#""agent":"Xavier","role":"planner","failed_starts":5"#),
            "the count INCLUDES the start that just failed: {gave_up}"
        );
        let error = one_line(dir.path(), "errors", "error");
        assert!(error.contains(r#""context":"start Xavier""#), "{error}");
        assert!(
            error.contains(&cerebro_tui::triggers::give_up_notice("Xavier", 5)),
            "the same sentence the row and the notice carry: {error}"
        );
    }

    #[test]
    fn an_evaluation_records_what_the_trigger_read() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let mut logger = logging(dir.path());
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        // Two planners, so the second is held by role-start spacing while the first starts.
        let roster = planner_roster(&["Xavier", "Beast"]);
        let mut spacing = BTreeMap::new();
        spacing.insert("planner".to_string(), 30);
        let mut app = standby_app(
            supervising(),
            vec![
                planner_row("Xavier", cerebro_tui::model::RowState::Dead),
                planner_row("Beast", cerebro_tui::model::RowState::Dead),
            ],
            Some(short_buffer()),
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut logger, &paths, &spacing, &roster, now);

        let lines = log_lines(dir.path(), "decisions");
        let evaluations: Vec<&String> = lines
            .iter()
            .filter(|line| line.starts_with(r#"{"event":"evaluate","#))
            .collect();
        assert_eq!(evaluations.len(), 2, "one per armed row per tick: {lines:#?}");
        // The seventeen fields, in order, with the nulls that are nulls: asserted as raw
        // substrings, because both the ORDER and the null-not-false shape are what is pinned and
        // a parse would prove neither.
        let xavier = evaluations[0];
        assert!(xavier.contains(r#""agent":"Xavier","role":"planner","reason":"buffer 0 of 2""#), "{xavier}");
        assert!(xavier.contains(r#""planned":0,"planned_ids":null,"implementers":0,"p0_unplanned":null"#), "{xavier}");
        assert!(xavier.contains(r#""p4_unranked":1,"merged_unverified":0,"stale_verdicts":0"#), "{xavier}");
        assert!(xavier.contains(r#""held_by_guard":null,"spaced_out":null,"spacing":30"#), "{xavier}");
        assert!(xavier.contains(r#""backed_off":null,"stop_flag":null,"disarmed":null,"failed_starts":0}"#), "{xavier}");
        // And the one the spacing held says so, on the same line as the number that did it.
        let beast = evaluations[1];
        assert!(beast.contains(r#""agent":"Beast""#) && beast.contains(r#""spaced_out":true,"spacing":30"#), "{beast}");
        host.kill(&paths, "Xavier");
        settle_gone(&mut host, "Xavier");
    }

    /// A read-only view decides nothing, so it records nothing - not even a reader failure.
    #[test]
    fn a_read_only_view_writes_no_log() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        // The production wiring: `Logger::new` starts disabled, and only `may_end()` enables it.
        let mut logger = Logger::new(dir.path());
        let read_only = cerebro_tui::supervisor::SupervisionMode::ReadOnly(
            cerebro_tui::supervisor::ReadOnlyReason::ConfiguredFor(
                cerebro_tui::supervisor::SupervisorKind::Emacs,
            ),
        );
        logger.set_enabled(read_only.may_end());
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let roster = planner_roster(&["Xavier"]);
        let mut app = standby_app(
            read_only,
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(short_buffer()),
            now,
        );

        supervise(&mut app, &mut host, &mut cerebro_tui::triggers::StartLedger::default(),
            &mut logger, &paths, now, Instant::now());
        start_due(&mut app, &mut host, &mut ledger, &mut logger, &paths, &BTreeMap::new(), &roster, now);
        logger.error("work", "bd: database is locked", now);

        assert!(log_lines(dir.path(), "decisions").is_empty(), "not a decision");
        assert!(log_lines(dir.path(), "errors").is_empty(), "and not an error either");
    }

    #[test]
    fn a_roster_that_cannot_be_read_says_so() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        // A `roster` that cannot be read: nothing is armed, nothing is started, and the
        // navigator is told why rather than shown a fleet indistinguishable from one that
        // declared neither.
        let unreadable = cerebro_tui::readers::testing::FakeCommands::failing(|| ReadError::Spawn {
            source: "roster".into(),
            message: "No such file or directory".into(),
        });
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = App::with_supervision(supervising());

        let notice = arm_and_autostart(
            &mut app,
            &mut host,
            &mut ledger,
            &mut test_logger(),
            &paths,
            &unreadable,
            &[],
            Utc::now(),
        )
            .expect("a read that failed is reported");

        assert!(notice.contains("--autostart could not be read"), "{notice}");
        assert!(notice.contains("--standby could not be read"), "{notice}");
        assert!(app.armed.is_empty());
    }

    #[test]
    fn a_refused_launch_is_never_standby_even_for_one_frame() {
        let now = Utc::now();
        let mut app = App::with_supervision(supervising());
        app.armed = ["Rogue"].into_iter().map(String::from).collect();
        app.set_exits(
            [("Rogue".to_string(), cerebro_tui::lifecycle::LastExit::Refused)]
                .into_iter()
                .collect(),
        );
        app.finish_refresh(
            Ok(vec![fleet_row("Rogue", cerebro_tui::model::AgentKind::Implementer,
                cerebro_tui::model::RowState::Dead)]),
            now,
        );
        assert_eq!(app.fleet_rows()[0].state, cerebro_tui::model::RowState::Dead);
    }

    #[test]
    fn the_roster_declaration_starts_one_half_and_arms_the_other() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        // The declaration answers from a fake; the SESSION it starts is still a real child of
        // `scratch`'s `launch`, which is what this case is about.
        let declaration = declaring("Cyclops", "Xavier\nBeast");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = App::with_supervision(supervising());

        let notice = arm_and_autostart(
            &mut app,
            &mut host,
            &mut ledger,
            &mut test_logger(),
            &paths,
            &declaration,
            &[],
            now,
        );

        assert!(host.is_live("Cyclops"), "the autostart half is started");
        assert!(app.armed.contains("Cyclops"), "and armed by the start");
        assert!(app.armed.contains("Xavier") && app.armed.contains("Beast"));
        assert!(!host.is_live("Xavier"), "the standby half is armed without being started");
        assert_eq!(ledger.started_at("Xavier"), None);
        assert_eq!(ledger.ended_at("Xavier"), Some(now), "with a moment to count from");
        assert_eq!(
            notice.as_deref(),
            Some("Started Cyclops; Xavier and Beast are on standby.")
        );
        host.kill(&paths, "Cyclops");
        settle_gone(&mut host, "Cyclops");
    }

    #[test]
    fn the_startup_line_names_both_halves() {
        assert_eq!(
            startup_notice(
                &["Cyclops".to_string(), "Rogue".to_string()],
                &["Xavier".to_string(), "Beast".to_string(), "Psylocke".to_string(),
                  "Cerebro".to_string()],
                &[],
            )
            .as_deref(),
            Some("Started Cyclops and Rogue; Xavier, Beast, Psylocke and Cerebro are on standby.")
        );
        // One half empty drops its clause along with the `; `.
        assert_eq!(
            startup_notice(&["Cyclops".to_string()], &[], &[]).as_deref(),
            Some("Started Cyclops.")
        );
        assert_eq!(
            startup_notice(&[], &["Xavier".to_string()], &[]).as_deref(),
            Some("Xavier is on standby.")
        );
        // The roster declared neither.
        assert_eq!(startup_notice(&[], &[], &[]), None);
        // A spacing that could not be parsed is its own sentence.
        assert_eq!(
            startup_notice(
                &[],
                &["Xavier".to_string()],
                &["project.conf: role_start_spacing_planner is not a whole number of seconds (\"30s\"); using 30.".to_string()],
            )
            .as_deref(),
            Some("Xavier is on standby. project.conf: role_start_spacing_planner is not a whole number of seconds (\"30s\"); using 30.")
        );
    }

    /// A runner answering the roster's two declaration flags, and nothing else.
    fn declaring(autostart: &str, standby: &str) -> cerebro_tui::readers::testing::FakeCommands {
        declaring_with_table(autostart, standby, "")
    }

    /// The same, plus what a BARE `roster` answers - `NAME<TAB>ROLE<TAB>KIND` per line, which is
    /// what `read_roster` parses. `arm_and_autostart` reads it for the roles it logs, so a case
    /// about those lines has to declare one.
    fn declaring_with_table(
        autostart: &str,
        standby: &str,
        table: &str,
    ) -> cerebro_tui::readers::testing::FakeCommands {
        let autostart = format!("{autostart}\n");
        let standby = format!("{standby}\n");
        let table = table.to_string();
        cerebro_tui::readers::testing::FakeCommands::new(move |call| {
            match call.args.first().map(String::as_str) {
                Some("--autostart") => Ok(autostart.clone().into_bytes()),
                Some("--standby") => Ok(standby.clone().into_bytes()),
                _ => Ok(table.clone().into_bytes()),
            }
        })
    }

    // --- cb-kcs.4.3: the roles whose work arrives from outside the fleet -----------------------

    fn outside_row(name: &str, role: &str) -> cerebro_tui::model::FleetRow {
        cerebro_tui::model::FleetRow {
            role: role.into(),
            ..fleet_row(name, cerebro_tui::model::AgentKind::Interactive, cerebro_tui::model::RowState::Dead)
        }
    }

    fn outside_roster(name: &str, role: &str) -> Vec<cerebro_tui::model::RosterEntry> {
        vec![cerebro_tui::model::RosterEntry {
            name: name.to_string(),
            role: role.to_string(),
            kind: cerebro_tui::model::AgentKind::Interactive,
        }]
    }

    #[test]
    fn a_standby_moira_whose_issue_moved_is_started() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = standby_app(
            supervising(),
            vec![outside_row("Moira", "user-feedback")],
            Some(cerebro_tui::model::WorkBuckets::default()),
            now,
        );
        // Her pass ended half an hour ago, and the issue moved a minute later.
        ledger.note_ended("Moira", now - chrono::Duration::minutes(30));
        app.finish_gh_refresh(
            Ok(cerebro_tui::model::GhSnapshot {
                issues: vec![cerebro_tui::model::GhIssue {
                    number: 212,
                    updated_at: Some(now - chrono::Duration::minutes(29)),
                }],
                prs: Vec::new(),
                me: Some("navigator".into()),
            }),
            now,
        );

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(),
                  &outside_roster("Moira", "user-feedback"), now);

        assert!(host.is_live("Moira"), "the standby row was started");
        assert_eq!(app.notice.as_deref(), Some("Started Moira — issue #212 moved."));
        host.kill(&paths, "Moira");
        settle_gone(&mut host, "Moira");
    }

    #[test]
    fn forge_starts_on_its_floor_alone() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = standby_app(
            supervising(),
            vec![outside_row("Forge", "architect")],
            Some(cerebro_tui::model::WorkBuckets::default()),
            now,
        );
        // No `gh` answer at all, and nothing on the board: the clock is its whole trigger.
        ledger.note_ended("Forge", now - chrono::Duration::minutes(60));

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(),
                  &outside_roster("Forge", "architect"), now);

        assert!(host.is_live("Forge"));
        assert_eq!(app.notice.as_deref(), Some("Started Forge — 60m since its last sweep."));
        host.kill(&paths, "Forge");
        settle_gone(&mut host, "Forge");
    }

    #[test]
    fn a_cadence_row_that_is_not_due_counts_down_and_says_gh_is_down() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = standby_app(
            supervising(),
            vec![outside_row("Moira", "user-feedback"), outside_row("Forge", "architect")],
            Some(cerebro_tui::model::WorkBuckets::default()),
            now,
        );
        ledger.note_ended("Moira", now - chrono::Duration::minutes(17));
        ledger.note_ended("Forge", now - chrono::Duration::minutes(17));
        app.finish_gh_refresh(Err(worker_gone("gh reader")), now);

        let mut roster = outside_roster("Moira", "user-feedback");
        roster.extend(outside_roster("Forge", "architect"));
        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &std::collections::BTreeMap::new(),
                  &roster, now);

        assert!(!host.is_live("Moira"), "nothing moved and the floor is not due");
        assert_eq!(app.standby_labels.get("Moira").map(String::as_str), Some("→ 43m gh?"));
        assert_eq!(
            app.standby_labels.get("Forge").map(String::as_str),
            Some("→ 43m"),
            "Forge reads no gh, so it never carries the suffix"
        );
    }

    // --- the backoff and the give-up (cb-kcs.4.2) ---------------------------------------------

    /// A board with nothing on it: every condition is false, which is what makes the countdown's
    /// precedence over the condition observable.
    fn empty_board() -> cerebro_tui::model::WorkBuckets {
        cerebro_tui::model::partition_beads(Vec::new())
    }

    /// A standby planner primed with FAILURES consecutive failed starts, the last of them AGO
    /// seconds before NOW.
    fn backing_off(
        failures: u32,
        ago: i64,
        work: cerebro_tui::model::WorkBuckets,
        now: DateTime<Utc>,
    ) -> (App, cerebro_tui::triggers::StartLedger) {
        let app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            Some(work),
            now,
        );
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        // No fingerprint: a start whose trigger is not compared against anything, so the
        // unchanged-work guard cannot be what holds the retry.
        ledger.note_started("Xavier", now - chrono::Duration::seconds(ago), None);
        ledger.set_failures("Xavier", failures);
        (app, ledger)
    }

    #[test]
    fn a_failed_start_is_not_retried_on_the_next_tick() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let roster = planner_roster(&["Xavier"]);
        let mut host = SessionHost::default();
        // One failed start behind it: the first entry of the schedule is 0, so it comes straight
        // back.
        let (mut app, mut ledger) = backing_off(1, 100, short_buffer(), now);

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, now);
        assert!(host.is_live("Xavier"), "one failure waits nothing at all");
        assert_eq!(ledger.failures("Xavier"), 2, "counted before the launch");
        host.kill(&paths, "Xavier");
        settle_gone(&mut host, "Xavier");

        // That start produced no pass either. Five seconds later, thirty are owed.
        let later = now + chrono::Duration::seconds(5);
        app.finish_refresh(
            Ok(vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)]),
            later,
        );
        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, later);
        assert!(!host.is_live("Xavier"), "the second failure is backed off");
        assert_eq!(ledger.failures("Xavier"), 2, "and the count is not advanced by a skip");
        assert_eq!(
            app.standby_labels.get("Xavier").map(String::as_str),
            Some("↻ retry in 25s, 2 failed")
        );
    }

    #[test]
    fn g_re_asks_gh_and_a_held_key_asks_once() {
        let mut app = App::default();
        let clock = Utc::now;
        let (fleet, work, gh, sweeps) = (worker(), work_worker(), gh_worker(), sweep_worker());

        dispatch(AppAction::RefreshAll, &mut app, &fleet, &work, &gh, &sweeps, &clock);
        // The slot is claimed, so the second press is not stacked: whatever the reader answers,
        // only one request is in flight.
        assert!(!app.begin_gh_refresh(Instant::now()), "a request is already in flight");
        dispatch(AppAction::RefreshAll, &mut app, &fleet, &work, &gh, &sweeps, &clock);

        // A fleet-only refresh does not ask `gh` while its own ten-minute clock is unspent.
        app.finish_gh_refresh(Ok(cerebro_tui::model::GhSnapshot::default()), clock());
        dispatch(AppAction::RefreshFleet, &mut app, &fleet, &work, &gh, &sweeps, &clock);
        assert!(
            app.begin_gh_refresh(Instant::now()),
            "the slot is free, so RefreshFleet asked nothing of gh"
        );
    }

    #[test]
    fn a_row_backing_off_shows_its_countdown_and_not_its_condition() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let roster = planner_roster(&["Xavier"]);
        let mut host = SessionHost::default();
        // An empty board: the planner's condition is false, and the countdown wins anyway.
        let (mut app, mut ledger) = backing_off(3, 60, empty_board(), now);

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, now);

        assert_eq!(
            app.standby_labels.get("Xavier").map(String::as_str),
            Some("↻ retry in 1m, 3 failed"),
            "while a backoff is running the row says so, and a failure is never invisible"
        );
        assert!(!host.is_live("Xavier"));
    }

    #[test]
    fn the_view_stops_after_five_starts_that_produced_no_pass() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let roster = planner_roster(&["Xavier"]);
        let mut host = SessionHost::default();
        // Four failures behind it and the fourth's ten minutes counted out.
        let (mut app, mut ledger) = backing_off(4, 700, short_buffer(), now);

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, now);

        assert!(!host.is_live("Xavier"), "no sixth start is attempted");
        assert!(!app.armed.contains("Xavier"), "the name left the armed set");
        assert_eq!(ledger.failures("Xavier"), 5, "brought up to what the notice says");
        assert_eq!(
            host.last_exit("Xavier"),
            Some(cerebro_tui::lifecycle::LastExit::GaveUp { failures: 5 })
        );
        assert_eq!(
            app.exits.get("Xavier"),
            Some(&cerebro_tui::lifecycle::LastExit::GaveUp { failures: 5 }),
            "and the renderer is told in the same frame"
        );
        assert_eq!(
            app.notice.as_deref(),
            Some("Xavier: 5 starts produced no pass; the view has stopped trying.")
        );

        // And it stays given up: a later tick starts nothing, the row being disarmed.
        let later = now + chrono::Duration::seconds(600);
        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, later);
        assert!(!host.is_live("Xavier"));
    }

    #[test]
    fn giving_up_takes_the_row_out_of_standby_in_the_same_frame() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let roster = planner_roster(&["Xavier"]);
        let mut host = SessionHost::default();
        let (mut app, mut ledger) = backing_off(4, 700, short_buffer(), now);
        assert_eq!(app.fleet_rows()[0].state, cerebro_tui::model::RowState::Standby);

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, now);

        // No fleet read in between: a row promising a retry the view has just decided against is
        // the one thing this must never leave on the screen.
        assert_eq!(app.fleet_rows()[0].state, cerebro_tui::model::RowState::Dead);
    }

    #[test]
    fn a_pass_that_ran_starts_the_count_over() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let roster = planner_roster(&["Xavier"]);
        let mut host = SessionHost::default();
        let (mut app, mut ledger) = backing_off(3, 100, short_buffer(), now);
        // A pass ran and ended: the three before it do not count.
        ledger.note_ended("Xavier", now - chrono::Duration::seconds(50));

        start_due(&mut app, &mut host, &mut ledger, &mut test_logger(), &paths, &BTreeMap::new(), &roster, now);

        assert!(host.is_live("Xavier"), "nothing is owed after a pass that ran");
        assert_eq!(ledger.failures("Xavier"), 0);
        host.kill(&paths, "Xavier");
        settle_gone(&mut host, "Xavier");
    }

    #[test]
    fn pressing_s_clears_the_backoff() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let now = Utc::now();
        let mut host = SessionHost::default();
        let mut ledger = cerebro_tui::triggers::StartLedger::default();
        let mut app = standby_app(
            supervising(),
            vec![planner_row("Xavier", cerebro_tui::model::RowState::Dead)],
            None,
            now,
        );
        ledger.note_started("Xavier", now - chrono::Duration::seconds(10), None);
        ledger.set_failures("Xavier", 3);
        app.selected = Some("Xavier".to_string());

        route_key(
            crossterm::event::KeyEvent::from(crossterm::event::KeyCode::Char('s')),
            &mut app,
            &mut host,
            &mut ledger,
            &mut test_logger(),
            &paths,
            &Programs::default(),
            10,
            now,
        );

        assert!(host.is_live("Xavier"), "the navigator's start is never held: {:?}", app.notice);
        assert_eq!(ledger.failures("Xavier"), 0, "and the last three do not count");
        assert_eq!(ledger.started_at("Xavier"), Some(now), "the start is recorded");
        host.kill(&paths, "Xavier");
        settle_gone(&mut host, "Xavier");
    }
    // --- x: the first board write (cb-kcs.5.1) -----------------------------------------------

    /// The tracked `bd` that records rather than writes. The `x` path is the one `bd` in this
    /// crate that WRITES, so no case here may reach the real one - and the recorder is tracked
    /// rather than written here, because a file a test writes and then spawns races the writer on
    /// Linux and dies `ETXTBSY`.
    fn stub_programs() -> Programs {
        Programs {
            bd: std::path::PathBuf::from(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/recording-bd"
            )),
            ..Programs::default()
        }
    }

    fn app_with_finding(mode: SupervisionMode) -> App {
        let mut app = lifecycle_app(
            mode,
            vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Working)],
        );
        app.finish_sweep_refresh(
            Ok(vec![cerebro_tui::readers::Judged {
                finding: cerebro_tui::sweeps::Finding::Unclaim { id: "cb-a".into() },
                label: "unclaim cb-a — Cyclops stalled".into(),
            }]),
            Utc::now(),
        );
        app
    }

    fn drive_with(
        app: &mut App,
        host: &mut SessionHost,
        paths: &ReaderPaths,
        programs: &Programs,
        keys: Vec<crossterm::event::KeyEvent>,
    ) -> AppAction {
        let mut action = AppAction::None;
        for key in keys {
            action = route_key(
                key,
                app,
                host,
                &mut StartLedger::default(),
                &mut test_logger(),
                paths,
                programs,
                10,
                Utc::now(),
            );
        }
        action
    }

    /// The recorder writes into the cwd `run_finding` gives it - `paths.shared_root`, which
    /// `scratch` points at this case's own tempdir.
    fn stub_calls(paths: &ReaderPaths) -> Vec<String> {
        std::fs::read_to_string(paths.shared_root.join("calls"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    /// `x` asks, and nothing is written until `y`. The confirmation names the exact command.
    #[test]
    fn x_asks_before_it_writes() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let programs = stub_programs();
        let mut app = app_with_finding(SupervisionMode::Supervising);
        let mut host = SessionHost::default();

        drive_with(&mut app, &mut host, &paths, &programs, vec![ch('x')]);
        assert!(stub_calls(&paths).is_empty(), "nothing ran on the question alone");
        assert!(matches!(
            &app.confirm,
            Some(cerebro_tui::app::Prompt::Sweep { text, .. })
                if text.ends_with("unclaim cb-a ?  y / n")
        ), "{:?}", app.confirm);

        let action = drive_with(&mut app, &mut host, &paths, &programs, vec![ch('y')]);
        assert_eq!(stub_calls(&paths), vec!["unclaim cb-a", "dolt push"]);
        assert_eq!(app.notice.as_deref().map(|n| n.contains("unclaim cb-a")), Some(true));
        // And the section is re-run at once rather than in up to ten minutes.
        assert_eq!(action, AppAction::RefreshSweeps);
    }

    /// Anything else cancels silently - including `q`, which must not also quit (Q10, now for
    /// three prompts).
    #[test]
    fn any_other_key_cancels_a_sweep_and_is_consumed() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let programs = stub_programs();
        let mut app = app_with_finding(SupervisionMode::Supervising);
        let mut host = SessionHost::default();

        drive_with(&mut app, &mut host, &paths, &programs, vec![ch('x'), ch('q')]);
        assert!(stub_calls(&paths).is_empty(), "nothing ran");
        assert!(app.confirm.is_none(), "and the question is gone");
        assert!(!app.quit, "the cancel is not also a quit");
    }

    /// `x` acts on the Work cursor from ANY focus, exactly as `s`/`f`/`k` do.
    #[test]
    fn x_from_fleet_focus_acts_on_the_work_cursor() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let programs = stub_programs();
        let mut app = app_with_finding(SupervisionMode::Supervising);
        assert_eq!(app.focus, cerebro_tui::app::PaneFocus::Fleet);
        let mut host = SessionHost::default();
        drive_with(&mut app, &mut host, &paths, &programs, vec![ch('x'), ch('y')]);
        assert_eq!(stub_calls(&paths), vec!["unclaim cb-a", "dolt push"]);
    }

    /// And a read-only view acts too: the board writes are deliberately outside the supervision
    /// lease, so a view that may start nothing may still close a delivered bead.
    #[test]
    fn a_read_only_view_still_acts_on_a_finding() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let programs = stub_programs();
        let mut app = app_with_finding(SupervisionMode::ReadOnly(
            cerebro_tui::supervisor::ReadOnlyReason::ConfiguredFor(
                cerebro_tui::supervisor::SupervisorKind::Emacs,
            ),
        ));
        let mut host = SessionHost::default();
        drive_with(&mut app, &mut host, &paths, &programs, vec![ch('x'), ch('y')]);
        assert_eq!(stub_calls(&paths), vec!["unclaim cb-a", "dolt push"]);
    }

    /// With no finding under the cursor `x` does nothing and says nothing - and it is consumed,
    /// so it can never reach a pane's scroll.
    #[test]
    fn x_with_no_finding_does_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let programs = stub_programs();
        let mut app = lifecycle_app(
            SupervisionMode::Supervising,
            vec![fleet_row("Cyclops", AgentKind::Implementer, RowState::Working)],
        );
        let mut host = SessionHost::default();
        drive_with(&mut app, &mut host, &paths, &programs, vec![ch('x')]);
        assert!(app.confirm.is_none());
        assert_eq!(app.notice, None);
        assert!(stub_calls(&paths).is_empty());
    }

    /// A live session holding the keyboard still gets the byte: the `x` branch is after it.
    #[test]
    fn a_live_session_still_gets_the_x() {
        let dir = tempfile::tempdir().unwrap();
        let paths = scratch(dir.path(), "sleep 5");
        let programs = stub_programs();
        let mut app = app_with_finding(SupervisionMode::Supervising);
        app.focus = cerebro_tui::app::PaneFocus::Session;
        let mut host = SessionHost::default();
        host.insert("Cyclops", forever());
        app.selected = Some("Cyclops".into());
        app.set_session_view(cerebro_tui::session::SessionView::Live { lines: Vec::new(), cursor: (0, 0) });

        drive_with(&mut app, &mut host, &paths, &programs, vec![ch('x')]);
        assert!(app.confirm.is_none(), "the child took the key, not the prompt");
        let text = echoed(&mut host, &app, "x");
        assert!(text.contains('x'), "the byte reached the child: {text:?}");
    }

    /// `g` re-runs the sweeps as well as the two panes: after closing a bead by hand, waiting ten
    /// minutes to watch a finding disappear is the moment the navigator presses `g` anyway.
    #[test]
    fn g_re_runs_the_sweeps_and_a_held_key_asks_once() {
        let mut app = App::default();
        let clock = Utc::now;
        let (fleet, work, gh, sweeps) = (worker(), work_worker(), gh_worker(), sweep_worker());

        dispatch(AppAction::RefreshAll, &mut app, &fleet, &work, &gh, &sweeps, &clock);
        assert!(!app.begin_sweep_refresh(Instant::now()), "a request is already in flight");
        app.finish_sweep_refresh(Ok(Vec::new()), clock());

        // The ten-minute clock is unspent, so a fleet-only refresh does not re-run six scripts.
        dispatch(AppAction::RefreshFleet, &mut app, &fleet, &work, &gh, &sweeps, &clock);
        assert!(!app.sweeps.refreshing, "the sweeps keep their own cadence");

        // And `x` asks for them alone, so a finding acted on leaves the section at once.
        dispatch(AppAction::RefreshSweeps, &mut app, &fleet, &work, &gh, &sweeps, &clock);
        assert!(app.sweeps.refreshing, "RefreshSweeps asks for the sweeps");
    }

}
