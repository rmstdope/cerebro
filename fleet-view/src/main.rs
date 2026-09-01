//! `cerebro-tui`: the standalone fleet screen, started by
//! `.claude/cerebro/scripts/cerebro-tui` and never by hand.
//!
//! It owns five things and nothing else: the terminal, the event loop, the workers that keep the
//! readers off the drawing thread, the sessions it hosts (cb-kcs.2.2), and - since cb-kcs.1 - the
//! supervision lease, through `SupervisorController`. Since cb-kcs.2.3 `s`, `f` and `k` reach the
//! fleet through `route_key` and `lifecycle_key`: it starts an agent, writes and clears a stop
//! flag, and kills a session it hosts, each refused with a visible line unless the lease says it
//! may. It writes no state file - `scripts/agent-state` is the one author of those, and this view
//! only ever DELETES one whose session it is ending - and no bead. Holding the lease is what makes
//! any of it legal; a view that does not hold it is exactly the reader it always was. The
//! controller owns the lease because ownership must end when the process does, and `TerminalGuard` beside it is the proof that a `Drop` is the only cleanup
//! a `?`, an early return and a panic all respect.
//!
//! Everything it needs to find the fleet is handed to it by the launcher in the environment. It
//! deliberately does not resolve a consumer root of its own: `scripts/consumer-root` is the one
//! place that question is answered, and a second answer in Rust would be a second answer.

use std::io::{self, Stdout, Write};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;
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

use cerebro_tui::app::{self, App, AppAction, FleetWorker, SupervisorWorker, WorkWorker};
use cerebro_tui::lifecycle;
use cerebro_tui::readers::{self, Programs, ReadError, ReaderPaths};
use cerebro_tui::supervisor::{
    reconcile_supervision, AcquireError, ReadOnlyReason, ReconcileAction, SupervisionMode,
    SupervisorKind, SupervisorLease,
};
use cerebro_tui::session::{self, SessionHost};
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
    fn new(paths: &ReaderPaths) -> Self {
        Self {
            lease: None,
            endpoint: readers::read_supervisor_endpoint(paths).ok(),
            identity: readers::read_supervisor_identity(paths).ok(),
            record: readers::read_supervisor_record(paths).ok(),
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
    let fleet_worker = FleetWorker::spawn(paths.clone(), Programs::default());
    let work_worker = WorkWorker::spawn(paths.clone(), Programs::default());
    let supervisor_worker = SupervisorWorker::spawn(paths.clone());
    // Ownership before the first frame: the one blocking read this binary allows itself, and the
    // reason a TUI that owns the checkout never shows an "Emacs owns supervision" frame first.
    let mut controller = SupervisorController::new(&paths);
    let initial = controller.apply(readers::read_configured_supervisor(&paths));
    let mut app = App::with_supervision(initial);

    // BEFORE the terminal guard, so it is dropped AFTER it: a child killed on the way out must
    // not be killed while the alternate screen is still up.
    let mut host = SessionHost::default();

    // Raw mode and the alternate screen are entered HERE and nowhere else, under a guard whose
    // `Drop` leaves them. A sequence of cleanup calls after the loop is skipped by `?`, by an
    // early return and by a panic - each of which has left somebody's terminal in raw mode with
    // no echo and no prompt.
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
        &supervisor_worker,
        &mut controller,
        &mut host,
        &paths,
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

/// The whole loop, generic over its terminal and its event source so the cases below can drive it
/// without taking over the developer's own terminal.
#[allow(clippy::too_many_arguments)]
fn run<B: Backend, E: Events>(
    terminal: &mut Terminal<B>,
    events: &mut E,
    app: &mut App,
    fleet_worker: &FleetWorker,
    work_worker: &WorkWorker,
    supervisor_worker: &SupervisorWorker,
    controller: &mut SupervisorController,
    host: &mut SessionHost,
    paths: &ReaderPaths,
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
            app.finish_refresh(result, clock());
        }
        if let Some(result) = work_worker.poll() {
            app.finish_work_refresh(result, clock());
        }
        // Ownership is a third state, polled like the other two and failing apart from them: a
        // declaration that cannot be read says nothing about the fleet or the board.
        if let Some(answer) = supervisor_worker.poll() {
            let mode = controller.apply(answer);
            app.set_supervision(mode);
        }
        // What makes `reconcile_supervision`'s drain branch reachable: a declaration that moved
        // supervision while this process hosts children keeps the lease until the last one ends.
        controller.hosted_sessions = host.live_count();
        if controller.due(Instant::now()) && supervisor_worker.request() {
            controller.requested(Instant::now());
        }

        dispatch(app.on_tick(Instant::now()), app, fleet_worker, work_worker, &clock);

        if events.poll(POLL_INTERVAL)? {
            match events.read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => {
                    let action = route_key(key, app, host, paths, viewport_lines, clock());
                    if action == AppAction::Quit {
                        break;
                    }
                    // `g` retries ownership as well as data (the navigator's choice): a second
                    // Ratatui stays open as a read-only observer and takes the checkout with `g`
                    // once the owner closes. Its own request, so an in-flight ownership read can
                    // never swallow the fleet/work retry the key was pressed for.
                    if action == AppAction::RefreshBoth && supervisor_worker.request() {
                        controller.requested(Instant::now());
                    }
                    dispatch(action, app, fleet_worker, work_worker, &clock);
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

/// The keystroke path when a live session is focused.
///
/// `Shift-Tab` is taken first and handed to `App::on_key` as the only way out (Q8) - which is the
/// reason the child can never receive it. Everything else goes to `session::key_bytes`, and a
/// `None` is dropped without a word (Q1): the pane is a window onto the child rather than a
/// commentary on it.
///
/// So `q`, `Esc`, `Ctrl-C` and `g` do NOT quit or refresh while a live session is focused - they
/// are the child's, which is exactly what the replaced header line says.
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
fn route_key(
    key: KeyEvent,
    app: &mut App,
    host: &mut SessionHost,
    paths: &ReaderPaths,
    viewport_lines: usize,
    now: DateTime<Utc>,
) -> AppAction {
    if app.quit_refusal.is_some() {
        app.quit_refusal = None;
        return AppAction::None;
    }
    if let Some(app::Prompt::Kill { name, .. }) = app.confirm.take() {
        if key.code == KeyCode::Char('y') && key.modifiers.is_empty() {
            host.kill(paths, &name);
            // A killed agent must not wait up to five seconds to disappear from the fleet.
            return AppAction::RefreshFleet;
        }
        return AppAction::None;
    }
    if app.session_has_keyboard() && key.code != KeyCode::BackTab {
        if let (Some(name), Some(bytes)) = (app.selected.clone(), session::key_bytes(key)) {
            host.send(&name, &bytes);
        }
        return AppAction::None;
    }
    if key.modifiers.is_empty() {
        if let KeyCode::Char(c @ ('s' | 'f' | 'k')) = key.code {
            // A notice is transient exactly as it is under `on_key`: the keystroke that reads it
            // is the one that clears it, and this key may then write its own.
            app.notice = None;
            return lifecycle_key(c, app, host, paths, now);
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
fn lifecycle_key(
    key: char,
    app: &mut App,
    host: &mut SessionHost,
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
                    Ok(line) => app.set_notice(line),
                    // The red Session pane is the report; a gold line saying the same thing twice
                    // is not.
                    Err(error) => host.note_refusal(&name, &error.to_string(), now),
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
            lifecycle::KillOutcome::Confirm { prompt } => {
                app.confirm = Some(app::Prompt::Kill { name, text: prompt });
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

/// Turn one `AppAction` into requests. `RefreshBoth` asks each pane in turn and never as a pair:
/// a fleet read already in flight must not swallow the work retry the navigator pressed `g` for.
fn dispatch(
    action: AppAction,
    app: &mut App,
    fleet_worker: &FleetWorker,
    work_worker: &WorkWorker,
    clock: &impl Fn() -> DateTime<Utc>,
) {
    let now = Instant::now();
    if matches!(action, AppAction::RefreshFleet | AppAction::RefreshBoth)
        && app.begin_refresh(now)
        && !fleet_worker.request()
    {
        app.finish_refresh(Err(worker_gone("fleet reader")), clock());
    }
    if matches!(action, AppAction::RefreshWork | AppAction::RefreshBoth)
        && app.begin_work_refresh(now)
        && !work_worker.request()
    {
        app.finish_work_refresh(Err(worker_gone("work reader")), clock());
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
            &supervision().0, &mut supervision().1, &mut host, &nowhere().0, Utc::now);

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
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &nowhere().0, Utc::now)
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
            &supervision().0, &mut supervision().1, &mut host, &nowhere().0, Utc::now).unwrap();

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
            &supervision().0, &mut supervision().1, &mut host, &nowhere().0, Utc::now);
        let text = echoed(&mut host, &app, "^[[201~");
        assert!(text.contains("^[[200~one"), "the paste arrived bracketed: {text:?}");
        assert!(text.contains("^[[201~"), "and closed: {text:?}");

        // With no live focused session there is nobody to give a paste to, and it is dropped.
        let mut app = App::new();
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        let mut events =
            ReplayedEvents::new(vec![Event::Paste("ignored".into()), key(KeyCode::Char('q'))]);
        run(&mut terminal, &mut events, &mut app, &worker(), &work_worker(),
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &nowhere().0, Utc::now)
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
            &worker_handle, &mut controller, &mut host, &nowhere().0, Utc::now);
        assert_eq!(
            controller.hosted_sessions, 1,
            "the drain branch of `reconcile_supervision` is reachable for the first time"
        );
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
            },
        )
    }

    fn worker() -> FleetWorker {
        let (paths, programs) = nowhere();
        FleetWorker::spawn(paths, programs)
    }

    fn work_worker() -> WorkWorker {
        let (paths, programs) = nowhere();
        WorkWorker::spawn(paths, programs)
    }

    /// The two ownership parameters, pointed at a directory with no `fleet-supervisor` in it.
    /// Every reader fails, which is exactly the read-only-with-a-lock-error case: these cases are
    /// about the terminal and the event source, and ownership must not be what decides them.
    fn supervision() -> (SupervisorWorker, SupervisorController) {
        let (paths, _) = nowhere();
        (SupervisorWorker::spawn(paths.clone()), SupervisorController::new(&paths))
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
        let mut controller = SupervisorController::new(&paths);

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
        let mut controller = SupervisorController::new(&paths);
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
        let mut controller = SupervisorController::new(&paths);
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
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &nowhere().0,
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
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &nowhere().0,
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
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &nowhere().0,
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
                &supervision().0,
                &mut supervision().1,
                &mut SessionHost::default(),
                &nowhere().0,
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
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let slow_bd = dir.path().join("bd");
        // Thirty seconds, not one: the window this test needs is "longer than the loop takes",
        // and the loop's duration is the machine's business. Paired with the injected bound below,
        // load cannot close it.
        std::fs::write(&slow_bd, "#!/usr/bin/env bash\nsleep 30\nprintf '[]\\n'\n").unwrap();
        let mut perms = std::fs::metadata(&slow_bd).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&slow_bd, perms).unwrap();

        let work = WorkWorker::spawn(
            ReaderPaths {
                consumer_root: dir.path().to_path_buf(),
                shared_root: dir.path().to_path_buf(),
                scripts_dir: dir.path().to_path_buf(),
            },
            Programs { bd: slow_bd, ps: "/nonexistent/ps".into() },
        );

        let mut terminal = Terminal::new(TestBackend::new(100, 20)).unwrap();
        let mut app = App::new();
        let mut events = QueuedEvents::new(vec![
            crossterm::event::KeyCode::Down,
            crossterm::event::KeyCode::PageDown,
            crossterm::event::KeyCode::Char('q'),
        ]);

        run(&mut terminal, &mut events, &mut app, &worker(), &work,
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &nowhere().0, Utc::now).unwrap();

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
        // removes, one crate over and ten times tighter. What is left has the reader's own bound
        // as its margin: the fixture sleeps thirty seconds, so this loop has five to finish in,
        // against the microseconds three queued keystrokes actually take.
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
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &nowhere().0, Utc::now).unwrap();

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
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &nowhere().0, Utc::now).unwrap();

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
            &supervision().0, &mut supervision().1, &mut SessionHost::default(), &nowhere().0, Utc::now).unwrap();

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
            route_key(key, app, host, paths, 10, Utc::now());
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
        let _ = run(&mut terminal, &mut events, app, &worker(), &work_worker(),
            &supervision().0, &mut supervision().1, host, paths, Utc::now);
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
}
