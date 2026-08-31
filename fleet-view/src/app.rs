//! The screen's pure display state, its refresh schedule, and the one worker thread that keeps
//! the reader's blocking calls off the drawing thread.
//!
//! Everything a frame is drawn from lives in `App`, and every transition it can make is a method
//! here. `crate::ui` renders `App` and nothing else; `main` owns the terminal and the event loop.
//! Two rules the navigator agreed to (`docs/ui/cb-vyp-read-only-view.html`) are enforced here
//! rather than in the renderer:
//!
//! - a failed refresh never destroys a snapshot that is still worth reading. It becomes stale,
//!   carrying both the moment it was read and the moment the refresh failed.
//! - a refresh already in flight swallows another request, so `g` held down cannot queue a
//!   hundred `ps` runs. `refreshing` is the whole of that rule, and `begin_refresh` is its only
//!   door.

use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::model::FleetRow;
use crate::readers::{read_fleet, Programs, ReaderPaths, ReadError};

/// How often the fleet is re-read while nobody touches the keyboard. Agreed in the parent epic's
/// interview: fast enough that a claim appears while the navigator is still looking at the row,
/// slow enough that a `ps` per tick is not what the machine is doing.
pub const FLEET_REFRESH_INTERVAL: Duration = Duration::from_secs(5);

/// What a pane has to show, and how sure it is of it.
///
/// The four states are distinct on purpose: "nothing yet" and "nothing, and here is why" are
/// different screens, and so are "this is current" and "this was current at 12:14:04 and the
/// refresh at 12:14:05 failed".
#[derive(Clone, Debug, PartialEq)]
pub enum PaneContent<T> {
    Loading,
    Fresh {
        value: T,
        read_at: DateTime<Utc>,
    },
    Stale {
        value: T,
        read_at: DateTime<Utc>,
        failed_at: DateTime<Utc>,
        error: String,
    },
    Unavailable {
        failed_at: DateTime<Utc>,
        error: String,
    },
}

impl<T> PaneContent<T> {
    /// The value still worth rendering, fresh or stale; `None` while loading or unavailable.
    pub fn value(&self) -> Option<&T> {
        match self {
            Self::Fresh { value, .. } | Self::Stale { value, .. } => Some(value),
            Self::Loading | Self::Unavailable { .. } => None,
        }
    }
}

/// One pane's content plus whether a read for it is in flight right now.
#[derive(Clone, Debug, PartialEq)]
pub struct Pane<T> {
    pub content: PaneContent<T>,
    pub refreshing: bool,
}

impl<T> Default for Pane<T> {
    fn default() -> Self {
        Self {
            content: PaneContent::Loading,
            refreshing: false,
        }
    }
}

/// What the caller must do about the key or tick it just handed over. The app itself starts no
/// process and ends no program: it says what is wanted, and `main` does it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppAction {
    None,
    RefreshFleet,
    Quit,
}

/// Everything one frame is drawn from.
#[derive(Debug)]
pub struct App {
    pub fleet: Pane<Vec<FleetRow>>,
    /// The first document line the viewport shows. Kept as a document offset rather than a
    /// selected row, because there is no selection in this read-only screen and a refresh must
    /// leave the navigator looking at the same place.
    pub scroll: usize,
    pub quit: bool,
    last_request: Option<Instant>,
}

impl Default for App {
    fn default() -> Self {
        Self::new()
    }
}

impl App {
    pub fn new() -> Self {
        Self {
            fleet: Pane::default(),
            scroll: 0,
            quit: false,
            last_request: None,
        }
    }

    /// The schedule: a request at once, then one no sooner than `FLEET_REFRESH_INTERVAL` after
    /// the last one was asked for.
    ///
    /// It counts from the *request*, not from the answer, so a reader that takes four seconds
    /// does not turn the cadence into nine. A request while one is in flight is refused by
    /// `begin_refresh` rather than here, so the two rules stay one each.
    pub fn on_tick(&mut self, now: Instant) -> AppAction {
        let due = match self.last_request {
            None => true,
            Some(last) => now.duration_since(last) >= FLEET_REFRESH_INTERVAL,
        };
        if due {
            self.last_request = Some(now);
            AppAction::RefreshFleet
        } else {
            AppAction::None
        }
    }

    /// The whole keyboard contract: scroll, refresh, quit. No selection, no detail, no lifecycle
    /// key - this screen may not act on the fleet at all.
    ///
    /// `viewport_lines` is what PageUp/PageDown move by: the document height the last frame
    /// actually showed, so a page is a page of what the navigator is looking at.
    pub fn on_key(&mut self, key: KeyEvent, viewport_lines: usize) -> AppAction {
        // A terminal that reports key releases (Windows, and any terminal with the kitty
        // protocol on) would otherwise scroll twice per keystroke.
        if key.kind == KeyEventKind::Release {
            return AppAction::None;
        }
        let page = viewport_lines.max(1);
        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.quit = true;
                AppAction::Quit
            }
            KeyCode::Char('q') | KeyCode::Esc => {
                self.quit = true;
                AppAction::Quit
            }
            KeyCode::Char('g') => {
                self.last_request = Some(Instant::now());
                AppAction::RefreshFleet
            }
            KeyCode::Up => {
                self.scroll = self.scroll.saturating_sub(1);
                AppAction::None
            }
            KeyCode::Down => {
                self.scroll = self.scroll.saturating_add(1);
                AppAction::None
            }
            KeyCode::PageUp => {
                self.scroll = self.scroll.saturating_sub(page);
                AppAction::None
            }
            KeyCode::PageDown => {
                self.scroll = self.scroll.saturating_add(page);
                AppAction::None
            }
            _ => AppAction::None,
        }
    }

    /// Claim the one in-flight slot: true when this request may go to the worker, false when one
    /// is already running and this one is dropped.
    pub fn begin_refresh(&mut self) -> bool {
        if self.fleet.refreshing {
            return false;
        }
        self.fleet.refreshing = true;
        true
    }

    /// The only content transition there is, and the only place `refreshing` is cleared.
    ///
    /// A success always wins - it replaces a stale snapshot and its error together. A failure
    /// keeps whatever was worth reading: `Fresh`/`Stale` become `Stale` with the original
    /// `read_at` preserved (the rows are as old as their read, not as old as the failure), while
    /// `Loading`/`Unavailable` have nothing to keep and become `Unavailable`.
    pub fn finish_refresh(&mut self, result: Result<Vec<FleetRow>, ReadError>, at: DateTime<Utc>) {
        self.fleet.refreshing = false;
        match result {
            Ok(rows) => {
                self.fleet.content = PaneContent::Fresh {
                    value: rows,
                    read_at: at,
                };
            }
            Err(error) => {
                let message = error.to_string();
                let previous = std::mem::replace(&mut self.fleet.content, PaneContent::Loading);
                self.fleet.content = match previous {
                    PaneContent::Fresh { value, read_at }
                    | PaneContent::Stale { value, read_at, .. } => PaneContent::Stale {
                        value,
                        read_at,
                        failed_at: at,
                        error: message,
                    },
                    PaneContent::Loading | PaneContent::Unavailable { .. } => {
                        PaneContent::Unavailable {
                            failed_at: at,
                            error: message,
                        }
                    }
                };
            }
        }
    }

    /// Pull `scroll` back only when the document no longer reaches it.
    ///
    /// Called after a frame is laid out, never before: it is the *rendered* document that decides
    /// what is scrollable, and a refresh that returns the same rows must leave the offset exactly
    /// where the navigator left it.
    pub fn clamp_scroll(&mut self, document_lines: usize, viewport_lines: usize) {
        let max = document_lines.saturating_sub(viewport_lines);
        if self.scroll > max {
            self.scroll = max;
        }
    }
}

/// The one background thread that runs the readers.
///
/// The UI thread may never block: a `ps` that takes five seconds to fail would otherwise freeze
/// the screen, keys and all, for exactly as long as the thing that went wrong. So every read
/// happens here, and the UI thread only ever asks (`request`) and looks (`poll`).
///
/// One thread and one request at a time, deliberately: `App::begin_refresh` already guarantees a
/// single in-flight read, so a pool would only add ways for two `ps` runs to overlap.
pub struct FleetWorker {
    requests: Sender<()>,
    results: Receiver<Result<Vec<FleetRow>, ReadError>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl FleetWorker {
    pub fn spawn(paths: ReaderPaths, programs: Programs) -> Self {
        let (request_tx, request_rx) = mpsc::channel::<()>();
        let (result_tx, result_rx) = mpsc::channel();
        let handle = std::thread::spawn(move || {
            // The loop ends when the sender is dropped, which is what `Drop` below does: the
            // thread cannot outlive the screen it reads for.
            while request_rx.recv().is_ok() {
                if result_tx.send(read_fleet(&paths, &programs)).is_err() {
                    break;
                }
            }
        });
        Self {
            requests: request_tx,
            results: result_rx,
            handle: Some(handle),
        }
    }

    /// Ask for one read. False only when the worker thread is gone, which the caller shows as a
    /// failed refresh rather than treating as a reason to exit.
    pub fn request(&self) -> bool {
        self.requests.send(()).is_ok()
    }

    /// The finished read, if one is waiting. Never blocks.
    pub fn poll(&self) -> Option<Result<Vec<FleetRow>, ReadError>> {
        match self.results.try_recv() {
            Ok(result) => Some(result),
            Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => None,
        }
    }
}

impl Drop for FleetWorker {
    fn drop(&mut self) {
        // Dropping the sender ends the loop above; joining then guarantees no reader is still
        // running while the terminal is being restored.
        let (dead, _) = mpsc::channel();
        let sender = std::mem::replace(&mut self.requests, dead);
        drop(sender);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AgentKind, RowState};

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_767_225_600 + seconds, 0).expect("a valid timestamp")
    }

    fn row(name: &str) -> FleetRow {
        FleetRow {
            name: name.to_string(),
            role: "planner".into(),
            kind: AgentKind::Interactive,
            state: RowState::Idle,
            phase: None,
            bead: None,
            since: None,
            phase_since: None,
            pid: None,
            sessions: 0,
            diagnostic: None,
        }
    }

    fn failure() -> ReadError {
        ReadError::Exit {
            source: "ps".into(),
            status: Some(3),
            stderr: "ps: boom".into(),
        }
    }

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    #[test]
    fn first_tick_requests_fleet_immediately() {
        let mut app = App::new();
        assert!(matches!(app.fleet.content, PaneContent::Loading));
        assert_eq!(app.scroll, 0);
        assert!(!app.quit);

        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshFleet);
        // No second request on the very next tick: one read is in flight and the interval has
        // not passed.
        assert_eq!(app.on_tick(start + Duration::from_millis(1)), AppAction::None);
    }

    #[test]
    fn fleet_refresh_is_due_every_five_seconds() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshFleet);
        assert_eq!(app.on_tick(start + Duration::from_millis(4_999)), AppAction::None);
        assert_eq!(app.on_tick(start + Duration::from_secs(5)), AppAction::RefreshFleet);
        assert_eq!(app.on_tick(start + Duration::from_secs(9)), AppAction::None);
        assert_eq!(app.on_tick(start + Duration::from_secs(10)), AppAction::RefreshFleet);
    }

    #[test]
    fn duplicate_refresh_is_ignored() {
        let mut app = App::new();
        assert!(app.begin_refresh(), "the first request takes the slot");
        assert!(app.fleet.refreshing);
        assert!(!app.begin_refresh(), "a second request while one is in flight is dropped");

        app.finish_refresh(Ok(vec![row("Xavier")]), at(0));
        assert!(!app.fleet.refreshing, "finishing always frees the slot");
        assert!(app.begin_refresh(), "and the next request may take it");

        app.finish_refresh(Err(failure()), at(1));
        assert!(!app.fleet.refreshing, "a failed read frees the slot too");
    }

    #[test]
    fn first_failure_is_unavailable() {
        let mut app = App::new();
        app.begin_refresh();
        app.finish_refresh(Err(failure()), at(5));
        match &app.fleet.content {
            PaneContent::Unavailable { failed_at, error } => {
                assert_eq!(*failed_at, at(5));
                assert!(error.contains("boom"), "the exact error is kept: {error}");
            }
            other => panic!("expected Unavailable, got {other:?}"),
        }

        // A second failure with still nothing to show stays unavailable, with the newer moment.
        app.begin_refresh();
        app.finish_refresh(Err(failure()), at(10));
        match &app.fleet.content {
            PaneContent::Unavailable { failed_at, .. } => assert_eq!(*failed_at, at(10)),
            other => panic!("expected Unavailable, got {other:?}"),
        }
    }

    #[test]
    fn later_failure_keeps_the_last_snapshot_stale() {
        let mut app = App::new();
        app.begin_refresh();
        app.finish_refresh(Ok(vec![row("Xavier"), row("Beast")]), at(4));
        app.begin_refresh();
        app.finish_refresh(Err(failure()), at(5));

        match &app.fleet.content {
            PaneContent::Stale { value, read_at, failed_at, error } => {
                assert_eq!(value.len(), 2, "the rows are still worth reading");
                assert_eq!(*read_at, at(4), "read_at is when the rows were read");
                assert_eq!(*failed_at, at(5), "failed_at is when the refresh failed");
                assert!(error.contains("boom"));
            }
            other => panic!("expected Stale, got {other:?}"),
        }

        // Failing again keeps the same rows and the same read_at, moving only the failure.
        app.begin_refresh();
        app.finish_refresh(Err(failure()), at(10));
        match &app.fleet.content {
            PaneContent::Stale { value, read_at, failed_at, .. } => {
                assert_eq!(value.len(), 2);
                assert_eq!(*read_at, at(4));
                assert_eq!(*failed_at, at(10));
            }
            other => panic!("expected Stale, got {other:?}"),
        }
    }

    #[test]
    fn success_clears_a_stale_error() {
        let mut app = App::new();
        app.finish_refresh(Ok(vec![row("Xavier")]), at(4));
        app.finish_refresh(Err(failure()), at(5));
        app.finish_refresh(Ok(vec![row("Xavier"), row("Storm")]), at(9));

        match &app.fleet.content {
            PaneContent::Fresh { value, read_at } => {
                assert_eq!(value.len(), 2);
                assert_eq!(*read_at, at(9));
            }
            other => panic!("expected Fresh, got {other:?}"),
        }
    }

    #[test]
    fn refresh_preserves_and_clamps_scroll() {
        let mut app = App::new();
        app.finish_refresh(Ok((0..20).map(|i| row(&format!("A{i}"))).collect()), at(0));
        app.scroll = 12;

        // Same-sized document: the offset is exactly where it was.
        app.clamp_scroll(24, 10);
        assert_eq!(app.scroll, 12);

        // A refresh that returns rows does not touch the offset on its own.
        app.finish_refresh(Ok((0..20).map(|i| row(&format!("A{i}"))).collect()), at(5));
        assert_eq!(app.scroll, 12);

        // Only a shorter document pulls it back, and only as far as the last full viewport.
        app.finish_refresh(Ok(vec![row("Xavier")]), at(10));
        app.clamp_scroll(5, 10);
        assert_eq!(app.scroll, 0);

        app.scroll = 40;
        app.clamp_scroll(30, 10);
        assert_eq!(app.scroll, 20);
    }

    // --- the keyboard ---------------------------------------------------------------------------

    #[test]
    fn scroll_keys_move_by_line_or_viewport() {
        let mut app = App::new();
        assert_eq!(app.on_key(key(KeyCode::Down), 10), AppAction::None);
        assert_eq!(app.scroll, 1);
        assert_eq!(app.on_key(key(KeyCode::Down), 10), AppAction::None);
        assert_eq!(app.scroll, 2);
        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.scroll, 1);

        // The top is a floor, never a negative offset.
        app.on_key(key(KeyCode::Up), 10);
        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.scroll, 0);

        app.on_key(key(KeyCode::PageDown), 10);
        assert_eq!(app.scroll, 10, "a page is the viewport the frame just showed");
        app.on_key(key(KeyCode::PageDown), 7);
        assert_eq!(app.scroll, 17);
        app.on_key(key(KeyCode::PageUp), 7);
        assert_eq!(app.scroll, 10);
        app.on_key(key(KeyCode::PageUp), 100);
        assert_eq!(app.scroll, 0);

        // A key release is the same keystroke reported twice; it moves nothing.
        let mut release = key(KeyCode::Down);
        release.kind = KeyEventKind::Release;
        assert_eq!(app.on_key(release, 10), AppAction::None);
        assert_eq!(app.scroll, 0);
    }

    #[test]
    fn quit_keys_all_exit() {
        for code in [KeyCode::Char('q'), KeyCode::Esc] {
            let mut app = App::new();
            assert_eq!(app.on_key(key(code), 10), AppAction::Quit);
            assert!(app.quit, "{code:?} sets quit immediately");
        }
        let mut app = App::new();
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(app.on_key(ctrl_c, 10), AppAction::Quit);
        assert!(app.quit);

        // A plain `c' is not Ctrl-C, and nothing else quits.
        let mut app = App::new();
        assert_eq!(app.on_key(key(KeyCode::Char('c')), 10), AppAction::None);
        assert_eq!(app.on_key(key(KeyCode::Char('x')), 10), AppAction::None);
        assert!(!app.quit);
    }

    #[test]
    fn g_requests_the_fleet_reader() {
        let mut app = App::new();
        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10), AppAction::RefreshFleet);
        // The request is only honoured once: `begin_refresh' is what the caller asks next, and a
        // second `g' while that read runs is dropped there.
        assert!(app.begin_refresh());
        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10), AppAction::RefreshFleet);
        assert!(!app.begin_refresh(), "a second g while one is in flight changes nothing");

        // A manual refresh restarts the cadence rather than leaving a tick due immediately after.
        assert_eq!(app.on_tick(Instant::now()), AppAction::None);
    }

    #[test]
    fn the_worker_answers_off_the_ui_thread() {
        let dir = tempfile::tempdir().unwrap();
        let scripts = dir.path().join("scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        std::fs::write(
            scripts.join("roster"),
            "#!/usr/bin/env bash\nprintf '%s\\n' 'Xavier\tplanner\tinteractive'\n",
        )
        .unwrap();
        std::fs::write(dir.path().join("ps"), "#!/usr/bin/env bash\nprintf ''\n").unwrap();
        for path in [scripts.join("roster"), dir.path().join("ps")] {
            let mut perms = std::fs::metadata(&path).unwrap().permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut perms, 0o755);
            std::fs::set_permissions(&path, perms).unwrap();
        }

        let worker = FleetWorker::spawn(
            ReaderPaths {
                consumer_root: dir.path().to_path_buf(),
                shared_root: dir.path().to_path_buf(),
                scripts_dir: scripts,
            },
            Programs {
                ps: dir.path().join("ps"),
                bd: "bd".into(),
            },
        );
        assert!(worker.poll().is_none(), "nothing was asked for yet");
        assert!(worker.request());

        let deadline = Instant::now() + Duration::from_secs(10);
        let result = loop {
            if let Some(result) = worker.poll() {
                break result;
            }
            assert!(Instant::now() < deadline, "the worker never answered");
            std::thread::sleep(Duration::from_millis(10));
        };
        let rows = result.expect("the fixture roster and ps both succeed");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "Xavier");
    }
}
