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

use crate::model::{FleetRow, WorkBuckets};
use crate::readers::{read_fleet, read_work, Programs, ReaderPaths, ReadError};

/// How often the fleet is re-read while nobody touches the keyboard. Agreed in the parent epic's
/// interview: fast enough that a claim appears while the navigator is still looking at the row,
/// slow enough that a `ps` per tick is not what the machine is doing.
pub const FLEET_REFRESH_INTERVAL: Duration = Duration::from_secs(5);

/// How often the bead panel is re-read. Six times the fleet's interval, and agreed separately in
/// the same interview: work moves in the minutes a bead takes, not in the seconds a claim takes,
/// and each read is a whole `bd` query against the shared board.
pub const WORK_REFRESH_INTERVAL: Duration = Duration::from_secs(30);

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

/// One pane's content plus whether a read for it is in flight right now, and its own scroll
/// offset. Bundling all three here is what keeps them from drifting apart: a pane's rendered
/// content, its refresh status and its viewport position are one unit, not three parallel fields
/// on `App` that could disagree about which pane they belong to.
#[derive(Clone, Debug, PartialEq)]
pub struct Pane<T> {
    pub content: PaneContent<T>,
    pub refreshing: bool,
    /// The first line of this pane's own body the viewport shows. Kept as a pane-local offset
    /// rather than a selected row, because there is no selection in this read-only screen and a
    /// refresh must leave the navigator looking at the same place. Fleet and Work are separate
    /// widgets and scroll independently - this offset belongs to this pane and no other.
    pub scroll: usize,
}

impl<T> Pane<T> {
    /// Claim this pane's one in-flight slot: true when the request may go to its worker, false
    /// when one is already running and this one is dropped. Per pane, deliberately - a global
    /// busy bit would let the five-second fleet cadence starve the thirty-second work read.
    fn begin(&mut self) -> bool {
        if self.refreshing {
            return false;
        }
        self.refreshing = true;
        true
    }

    /// The only content transition there is, and the only place `refreshing` is cleared.
    ///
    /// A success always wins - it replaces a stale snapshot and its error together. A failure
    /// keeps whatever was worth reading: `Fresh`/`Stale` become `Stale` with the original
    /// `read_at` preserved (the value is as old as its read, not as old as the failure), while
    /// `Loading`/`Unavailable` have nothing to keep and become `Unavailable`.
    fn finish(&mut self, result: Result<T, ReadError>, at: DateTime<Utc>) {
        self.refreshing = false;
        match result {
            Ok(value) => {
                self.content = PaneContent::Fresh { value, read_at: at };
            }
            Err(error) => {
                let message = error.to_string();
                let previous = std::mem::replace(&mut self.content, PaneContent::Loading);
                self.content = match previous {
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

    /// Pull this pane's own scroll back only when its own rendered content no longer reaches it.
    ///
    /// Called after a frame is laid out, never before: it is the *rendered* content that decides
    /// what is scrollable, and a refresh that returns the same content must leave the navigator
    /// looking at exactly where they left it. Each pane clamps against its own geometry alone -
    /// a shrinking Work pane must never pull back the Fleet pane's offset, or the reverse.
    pub fn clamp_scroll(&mut self, content_lines: usize, viewport_lines: usize) {
        let max = content_lines.saturating_sub(viewport_lines);
        if self.scroll > max {
            self.scroll = max;
        }
    }
}

impl<T> Default for Pane<T> {
    fn default() -> Self {
        Self {
            content: PaneContent::Loading,
            refreshing: false,
            scroll: 0,
        }
    }
}

/// Which of the two widgets the keyboard acts on. Fleet is focused on startup; `Tab` and
/// `Shift-Tab` both toggle it, and arrow/page keys move only the focused pane's own scroll.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PaneFocus {
    #[default]
    Fleet,
    Work,
}

impl PaneFocus {
    /// The other pane. There are exactly two, so toggling is its own inverse.
    pub fn toggled(self) -> Self {
        match self {
            Self::Fleet => Self::Work,
            Self::Work => Self::Fleet,
        }
    }
}

/// One pane's geometry for a drawn frame: how many lines its body came to, and how many the
/// viewport actually shows once its border is taken off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaneMetrics {
    pub content_lines: usize,
    pub viewport_lines: usize,
}

/// The geometry one draw of `App` at one `now` in one `Rect` would produce, one `PaneMetrics` per
/// widget. `ui::metrics` derives this from the same pure layout `ui::draw` renders from, so a
/// page size, a clamp and a range cue can never be computed from three different geometries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Metrics {
    pub fleet: PaneMetrics,
    pub work: PaneMetrics,
}

/// What the caller must do about the key or tick it just handed over. The app itself starts no
/// process and ends no program: it says what is wanted, and `main` does it.
///
/// `RefreshBoth` is "attempt each pane independently", never "both or neither": the caller calls
/// each pane's own `begin_*_refresh`, and a `false` from one says nothing about the other.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppAction {
    None,
    RefreshFleet,
    RefreshWork,
    RefreshBoth,
    Quit,
}

/// Everything one frame is drawn from.
#[derive(Debug)]
pub struct App {
    pub fleet: Pane<Vec<FleetRow>>,
    pub work: Pane<WorkBuckets>,
    /// Which widget the keyboard currently acts on. Fleet by default.
    pub focus: PaneFocus,
    pub quit: bool,
    last_fleet_request: Option<Instant>,
    last_work_request: Option<Instant>,
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
            work: Pane::default(),
            focus: PaneFocus::default(),
            quit: false,
            last_fleet_request: None,
            last_work_request: None,
        }
    }

    /// The schedule: a request for each pane at once, then one no sooner than that pane's own
    /// interval after it last *started* a read.
    ///
    /// It counts from the request, not from the answer, so a reader that takes four seconds does
    /// not turn a five-second cadence into nine. The two panes are timed separately: a work read
    /// that is due says nothing about the fleet, and a fleet read that is refused says nothing
    /// about the work. Recording the moment is `begin_*_refresh`'s job and not this function's,
    /// so a request this returns and the caller cannot start is asked for again on the next tick
    /// rather than silently postponed by a whole interval.
    pub fn on_tick(&mut self, now: Instant) -> AppAction {
        let due = |last: Option<Instant>, interval: Duration| match last {
            None => true,
            Some(last) => now.duration_since(last) >= interval,
        };
        match (
            due(self.last_fleet_request, FLEET_REFRESH_INTERVAL),
            due(self.last_work_request, WORK_REFRESH_INTERVAL),
        ) {
            (true, true) => AppAction::RefreshBoth,
            (true, false) => AppAction::RefreshFleet,
            (false, true) => AppAction::RefreshWork,
            (false, false) => AppAction::None,
        }
    }

    /// The whole keyboard contract: focus, scroll, refresh, quit. No selection, no detail, no
    /// lifecycle key - this screen may not act on the fleet at all.
    ///
    /// `viewport_lines` is what PageUp/PageDown move the focused pane by: that pane's own body
    /// height the last frame actually showed, so a page is a page of what the navigator is
    /// looking at in the widget they are looking at. `App::focused_viewport` is the one place the
    /// at-least-one floor on that number is applied; this method never applies its own.
    pub fn on_key(&mut self, key: KeyEvent, viewport_lines: usize) -> AppAction {
        // A terminal that reports key releases (Windows, and any terminal with the kitty
        // protocol on) would otherwise scroll twice per keystroke.
        if key.kind == KeyEventKind::Release {
            return AppAction::None;
        }
        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.quit = true;
                AppAction::Quit
            }
            KeyCode::Char('q') | KeyCode::Esc => {
                self.quit = true;
                AppAction::Quit
            }
            KeyCode::Char('g') => AppAction::RefreshBoth,
            // Both bindings toggle the same way, so both are discoverable regardless of which
            // one a terminal or a navigator reaches for first. A boundary clamps within the
            // focused pane; it never transfers focus on its own.
            KeyCode::Tab | KeyCode::BackTab => {
                self.focus = self.focus.toggled();
                AppAction::None
            }
            KeyCode::Up => {
                let scroll = self.focused_scroll_mut();
                *scroll = scroll.saturating_sub(1);
                AppAction::None
            }
            KeyCode::Down => {
                let scroll = self.focused_scroll_mut();
                *scroll = scroll.saturating_add(1);
                AppAction::None
            }
            KeyCode::PageUp => {
                let scroll = self.focused_scroll_mut();
                *scroll = scroll.saturating_sub(viewport_lines);
                AppAction::None
            }
            KeyCode::PageDown => {
                let scroll = self.focused_scroll_mut();
                *scroll = scroll.saturating_add(viewport_lines);
                AppAction::None
            }
            _ => AppAction::None,
        }
    }

    /// A mutable handle on whichever pane's scroll offset the keyboard currently moves. Both
    /// panes' `scroll` fields are `usize`, so this returns the same type regardless of which one
    /// is focused - `on_key` never needs to know which pane it moved.
    fn focused_scroll_mut(&mut self) -> &mut usize {
        match self.focus {
            PaneFocus::Fleet => &mut self.fleet.scroll,
            PaneFocus::Work => &mut self.work.scroll,
        }
    }

    /// The focused pane's own viewport height, floored at one page. The single owner of that
    /// floor: callers pass this straight to `on_key` and never apply their own `.max(1)`.
    pub fn focused_viewport(&self, metrics: Metrics) -> usize {
        match self.focus {
            PaneFocus::Fleet => metrics.fleet.viewport_lines.max(1),
            PaneFocus::Work => metrics.work.viewport_lines.max(1),
        }
    }

    /// Claim the fleet's one in-flight slot: true when this request may go to the worker, false
    /// when one is already running and this one is dropped.
    ///
    /// AT is when the request is being made, and it is recorded only when the slot was free -
    /// a rejected duplicate neither postpones nor accelerates the next scheduled read.
    pub fn begin_refresh(&mut self, at: Instant) -> bool {
        if self.fleet.begin() {
            self.last_fleet_request = Some(at);
            true
        } else {
            false
        }
    }

    /// The work pane's counterpart of `begin_refresh`, on its own slot and its own clock.
    pub fn begin_work_refresh(&mut self, at: Instant) -> bool {
        if self.work.begin() {
            self.last_work_request = Some(at);
            true
        } else {
            false
        }
    }

    /// The fleet pane's content transition; see `Pane::finish` for the whole rule.
    pub fn finish_refresh(&mut self, result: Result<Vec<FleetRow>, ReadError>, at: DateTime<Utc>) {
        self.fleet.finish(result, at);
    }

    /// The work pane's content transition. It touches the work pane and nothing else: a `bd` that
    /// cannot answer must not make the fleet rows beside it look stale.
    pub fn finish_work_refresh(
        &mut self,
        result: Result<WorkBuckets, ReadError>,
        at: DateTime<Utc>,
    ) {
        self.work.finish(result, at);
    }

}

/// One background thread per pane, running that pane's reader.
///
/// The UI thread may never block: a `ps` or a `bd` that takes five seconds to fail would
/// otherwise freeze the screen, keys and all, for exactly as long as the thing that went wrong.
/// So every read happens here, and the UI thread only ever asks (`request`) and looks (`poll`).
///
/// One thread and one request at a time per pane, deliberately: `App::begin_refresh` and
/// `App::begin_work_refresh` already guarantee a single in-flight read each, so a pool would only
/// add ways for two `ps` runs to overlap. Two workers rather than one shared thread, equally
/// deliberately: a thirty-second `bd` behind a five-second `ps` would make each wait for the
/// other, which is the one thing independent panes must not do.
pub struct Worker<T> {
    requests: Sender<()>,
    results: Receiver<Result<T, ReadError>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

/// The fleet's worker: `read_fleet` on its own thread.
pub type FleetWorker = Worker<Vec<FleetRow>>;
/// The bead panel's worker: `read_work` on its own thread.
pub type WorkWorker = Worker<WorkBuckets>;

impl<T: Send + 'static> Worker<T> {
    fn spawn_reader(reader: impl Fn() -> Result<T, ReadError> + Send + 'static) -> Self {
        let (request_tx, request_rx) = mpsc::channel::<()>();
        let (result_tx, result_rx) = mpsc::channel();
        let handle = std::thread::spawn(move || {
            // The loop ends when the sender is dropped, which is what `Drop` below does: the
            // thread cannot outlive the screen it reads for.
            while request_rx.recv().is_ok() {
                if result_tx.send(reader()).is_err() {
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
    pub fn poll(&self) -> Option<Result<T, ReadError>> {
        match self.results.try_recv() {
            Ok(result) => Some(result),
            Err(TryRecvError::Empty) | Err(TryRecvError::Disconnected) => None,
        }
    }
}

impl Worker<Vec<FleetRow>> {
    pub fn spawn(paths: ReaderPaths, programs: Programs) -> Self {
        Self::spawn_reader(move || read_fleet(&paths, &programs))
    }
}

impl Worker<WorkBuckets> {
    pub fn spawn(paths: ReaderPaths, programs: Programs) -> Self {
        Self::spawn_reader(move || read_work(&paths, &programs))
    }
}

impl<T> Drop for Worker<T> {
    fn drop(&mut self) {
        // Dropping the sender asks the loop to end, but do not join: a reader may be inside its
        // timeout while the navigator is quitting, and terminal cleanup must remain immediate.
        let (dead, _) = mpsc::channel();
        let sender = std::mem::replace(&mut self.requests, dead);
        drop(sender);
        drop(self.handle.take());
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

    fn bd_failure() -> ReadError {
        ReadError::Exit {
            source: "bd".into(),
            status: Some(1),
            stderr: "bd list failed: database is locked".into(),
        }
    }

    /// Work buckets with IDS in the claimed queue - enough to tell one snapshot from another
    /// without repeating the partition's own contract, which `model` already owns.
    fn buckets(ids: &[&str]) -> WorkBuckets {
        WorkBuckets {
            claimed: ids
                .iter()
                .map(|id| crate::model::Bead {
                    id: (*id).to_string(),
                    title: "t".into(),
                    status: "in_progress".into(),
                    issue_type: "feature".into(),
                    labels: vec![],
                    priority: Some(1),
                    updated_at: None,
                    assignee: None,
                    metadata: serde_json::Value::Null,
                })
                .collect(),
            ..WorkBuckets::default()
        }
    }

    /// What `main` does with a `RefreshBoth`, followed by both answers arriving: the request time
    /// is recorded and neither slot is left in flight.
    fn started_both(app: &mut App, when: Instant) {
        start_fleet(app, when);
        assert!(app.begin_work_refresh(when), "the work slot was free");
        app.finish_work_refresh(Ok(WorkBuckets::default()), at(0));
    }

    fn start_fleet(app: &mut App, when: Instant) {
        assert!(app.begin_refresh(when), "the fleet slot was free");
        app.finish_refresh(Ok(vec![]), at(0));
    }

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    #[test]
    fn first_tick_requests_both_panes() {
        let mut app = App::new();
        assert!(matches!(app.fleet.content, PaneContent::Loading));
        assert!(matches!(app.work.content, PaneContent::Loading));
        assert_eq!(app.focus, PaneFocus::Fleet, "Fleet is focused on startup");
        assert_eq!(app.fleet.scroll, 0);
        assert_eq!(app.work.scroll, 0);
        assert!(!app.quit);

        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshBoth);
        assert!(app.begin_refresh(start));
        assert!(app.begin_work_refresh(start));
        // No second request on the very next tick: both reads are in flight and neither interval
        // has passed.
        assert_eq!(app.on_tick(start + Duration::from_millis(1)), AppAction::None);
    }

    #[test]
    fn fleet_refresh_is_due_every_five_seconds() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshBoth);
        started_both(&mut app, start);
        assert_eq!(app.on_tick(start + Duration::from_millis(4_999)), AppAction::None);
        assert_eq!(app.on_tick(start + Duration::from_secs(5)), AppAction::RefreshFleet);
        start_fleet(&mut app, start + Duration::from_secs(5));
        assert_eq!(app.on_tick(start + Duration::from_secs(9)), AppAction::None);
        assert_eq!(app.on_tick(start + Duration::from_secs(10)), AppAction::RefreshFleet);
    }

    #[test]
    fn work_refresh_is_due_every_thirty_seconds() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshBoth);
        started_both(&mut app, start);

        // Every fleet tick in between is the fleet's alone; the work read is not due again for
        // half a minute.
        for seconds in [5, 10, 15, 20, 26] {
            let at = start + Duration::from_secs(seconds);
            assert_eq!(app.on_tick(at), AppAction::RefreshFleet, "at {seconds}s");
            start_fleet(&mut app, at);
        }
        let at = start + Duration::from_secs(30);
        assert_eq!(app.on_tick(at), AppAction::RefreshWork, "the fleet is not due at 30s");
        started_both(&mut app, at);
        assert_eq!(app.on_tick(at + Duration::from_secs(30)), AppAction::RefreshBoth);
    }

    /// Each pane counts from its own last *start*, so a work read that took twenty seconds does
    /// not push the fleet's five-second cadence out, and a refused duplicate moves neither.
    #[test]
    fn fleet_and_work_cadences_are_independent() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshBoth);
        assert!(app.begin_refresh(start));
        assert!(app.begin_work_refresh(start));
        // The fleet answers; the work read is still running.
        app.finish_refresh(Ok(vec![row("Xavier")]), at(0));

        // A work read still in flight at 30s: the tick still says so, and the refusal leaves the
        // work clock where it was rather than postponing it by another thirty seconds.
        let due = start + Duration::from_secs(30);
        assert_eq!(app.on_tick(due), AppAction::RefreshBoth);
        assert!(app.begin_refresh(due));
        assert!(!app.begin_work_refresh(due), "the work read is still running");
        app.finish_refresh(Ok(vec![row("Xavier")]), at(1));

        assert_eq!(
            app.on_tick(due + Duration::from_millis(1)),
            AppAction::RefreshWork,
            "the refused work request is asked for again, not deferred"
        );
    }

    #[test]
    fn duplicate_refresh_is_ignored() {
        let mut app = App::new();
        let start = Instant::now();
        assert!(app.begin_refresh(start), "the first request takes the slot");
        assert!(app.fleet.refreshing);
        assert!(
            !app.begin_refresh(start + Duration::from_secs(1)),
            "a second request while one is in flight is dropped"
        );

        app.finish_refresh(Ok(vec![row("Xavier")]), at(0));
        assert!(!app.fleet.refreshing, "finishing always frees the slot");
        assert!(app.begin_refresh(start + Duration::from_secs(2)), "and the next request may take it");

        app.finish_refresh(Err(failure()), at(1));
        assert!(!app.fleet.refreshing, "a failed read frees the slot too");
    }

    /// The two slots are separate. A fleet read in flight may not swallow a work request, which
    /// is what a single global `busy` bit would have done six times a minute.
    #[test]
    fn duplicate_work_refresh_is_ignored_without_blocking_fleet() {
        let mut app = App::new();
        let start = Instant::now();
        assert!(app.begin_work_refresh(start));
        assert!(app.work.refreshing);
        assert!(!app.begin_work_refresh(start), "a second work request is dropped");
        assert!(!app.fleet.refreshing, "and it never touched the fleet's slot");
        assert!(app.begin_refresh(start), "the fleet may still start its own read");

        app.finish_work_refresh(Ok(WorkBuckets::default()), at(0));
        assert!(!app.work.refreshing);
        assert!(app.fleet.refreshing, "finishing one pane frees only that pane");
    }

    #[test]
    fn first_failure_is_unavailable() {
        let mut app = App::new();
        app.begin_refresh(Instant::now());
        app.finish_refresh(Err(failure()), at(5));
        match &app.fleet.content {
            PaneContent::Unavailable { failed_at, error } => {
                assert_eq!(*failed_at, at(5));
                assert!(error.contains("boom"), "the exact error is kept: {error}");
            }
            other => panic!("expected Unavailable, got {other:?}"),
        }

        // A second failure with still nothing to show stays unavailable, with the newer moment.
        app.begin_refresh(Instant::now());
        app.finish_refresh(Err(failure()), at(10));
        match &app.fleet.content {
            PaneContent::Unavailable { failed_at, .. } => assert_eq!(*failed_at, at(10)),
            other => panic!("expected Unavailable, got {other:?}"),
        }
    }

    #[test]
    fn work_first_failure_is_unavailable() {
        let mut app = App::new();
        app.begin_work_refresh(Instant::now());
        app.finish_work_refresh(Err(bd_failure()), at(5));
        match &app.work.content {
            PaneContent::Unavailable { failed_at, error } => {
                assert_eq!(*failed_at, at(5));
                assert!(error.contains("database is locked"), "{error}");
            }
            other => panic!("expected Unavailable, got {other:?}"),
        }
    }

    #[test]
    fn work_later_failure_keeps_the_last_snapshot() {
        let mut app = App::new();
        app.finish_work_refresh(Ok(buckets(&["cb-1", "cb-2"])), at(4));
        app.finish_work_refresh(Err(bd_failure()), at(5));
        match &app.work.content {
            PaneContent::Stale { value, read_at, failed_at, error } => {
                assert_eq!(value.claimed.len(), 2, "the queues are still worth reading");
                assert_eq!(*read_at, at(4));
                assert_eq!(*failed_at, at(5));
                assert!(error.contains("database is locked"));
            }
            other => panic!("expected Stale, got {other:?}"),
        }

        app.finish_work_refresh(Err(bd_failure()), at(10));
        match &app.work.content {
            PaneContent::Stale { value, read_at, failed_at, .. } => {
                assert_eq!(value.claimed.len(), 2);
                assert_eq!(*read_at, at(4), "the queues are as old as their read");
                assert_eq!(*failed_at, at(10));
            }
            other => panic!("expected Stale, got {other:?}"),
        }
    }

    #[test]
    fn work_success_clears_its_stale_error() {
        let mut app = App::new();
        app.finish_work_refresh(Ok(buckets(&["cb-1"])), at(4));
        app.finish_work_refresh(Err(bd_failure()), at(5));
        app.finish_work_refresh(Ok(buckets(&["cb-1", "cb-2"])), at(9));
        match &app.work.content {
            PaneContent::Fresh { value, read_at } => {
                assert_eq!(value.claimed.len(), 2);
                assert_eq!(*read_at, at(9));
            }
            other => panic!("expected Fresh, got {other:?}"),
        }
    }

    /// The whole point of two panes: `bd` being unreadable says nothing about the fleet, and the
    /// fleet being unreadable says nothing about the board.
    #[test]
    fn work_failure_does_not_stale_fleet() {
        let mut app = App::new();
        app.finish_refresh(Ok(vec![row("Xavier")]), at(4));
        app.finish_work_refresh(Ok(buckets(&["cb-1"])), at(4));

        app.finish_work_refresh(Err(bd_failure()), at(5));
        match &app.fleet.content {
            PaneContent::Fresh { read_at, .. } => assert_eq!(*read_at, at(4)),
            other => panic!("the fleet is untouched by a work failure: {other:?}"),
        }
        assert!(matches!(app.work.content, PaneContent::Stale { .. }));

        // And the other way round.
        app.finish_work_refresh(Ok(buckets(&["cb-1"])), at(6));
        app.finish_refresh(Err(failure()), at(7));
        match &app.work.content {
            PaneContent::Fresh { read_at, .. } => assert_eq!(*read_at, at(6)),
            other => panic!("the work pane is untouched by a fleet failure: {other:?}"),
        }
        assert!(matches!(app.fleet.content, PaneContent::Stale { .. }));
    }

    #[test]
    fn later_failure_keeps_the_last_snapshot_stale() {
        let mut app = App::new();
        app.begin_refresh(Instant::now());
        app.finish_refresh(Ok(vec![row("Xavier"), row("Beast")]), at(4));
        app.begin_refresh(Instant::now());
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
        app.begin_refresh(Instant::now());
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

    /// Each pane clamps against its own content and viewport alone: a shrinking Work pane must
    /// never pull back the Fleet pane's offset, and the reverse.
    #[test]
    fn each_pane_preserves_and_clamps_its_own_scroll() {
        let mut app = App::new();
        app.finish_refresh(Ok((0..20).map(|i| row(&format!("A{i}"))).collect()), at(0));
        app.finish_work_refresh(Ok(buckets(&["cb-1", "cb-2"])), at(0));
        app.fleet.scroll = 12;
        app.work.scroll = 3;

        // Same-sized content: both offsets are exactly where they were.
        app.fleet.clamp_scroll(24, 10);
        app.work.clamp_scroll(10, 5);
        assert_eq!(app.fleet.scroll, 12);
        assert_eq!(app.work.scroll, 3);

        // A refresh of either pane that returns the same content does not touch either offset.
        app.finish_refresh(Ok((0..20).map(|i| row(&format!("A{i}"))).collect()), at(5));
        assert_eq!(app.fleet.scroll, 12);
        app.finish_work_refresh(Ok(buckets(&["cb-1", "cb-2"])), at(5));
        assert_eq!(app.work.scroll, 3);

        // Only a shorter pane's own content pulls its own offset back, and only as far as its own
        // last full viewport - the other pane's offset is untouched.
        app.finish_work_refresh(Ok(WorkBuckets::default()), at(10));
        app.work.clamp_scroll(2, 10);
        assert_eq!(app.work.scroll, 0);
        assert_eq!(app.fleet.scroll, 12, "the fleet offset is untouched by the work pane shrinking");

        app.fleet.scroll = 40;
        app.finish_refresh(Ok(vec![row("Xavier")]), at(10));
        app.fleet.clamp_scroll(30, 10);
        assert_eq!(app.fleet.scroll, 20);
        assert_eq!(app.work.scroll, 0, "and the work offset is untouched by the fleet clamping");
    }

    // --- the keyboard ---------------------------------------------------------------------------

    #[test]
    fn scroll_keys_move_by_line_or_viewport() {
        let mut app = App::new();
        assert_eq!(app.on_key(key(KeyCode::Down), 10), AppAction::None);
        assert_eq!(app.fleet.scroll, 1);
        assert_eq!(app.on_key(key(KeyCode::Down), 10), AppAction::None);
        assert_eq!(app.fleet.scroll, 2);
        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.fleet.scroll, 1);

        // The top is a floor, never a negative offset.
        app.on_key(key(KeyCode::Up), 10);
        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.fleet.scroll, 0);

        app.on_key(key(KeyCode::PageDown), 10);
        assert_eq!(app.fleet.scroll, 10, "a page is the viewport the frame just showed");
        app.on_key(key(KeyCode::PageDown), 7);
        assert_eq!(app.fleet.scroll, 17);
        app.on_key(key(KeyCode::PageUp), 7);
        assert_eq!(app.fleet.scroll, 10);
        app.on_key(key(KeyCode::PageUp), 100);
        assert_eq!(app.fleet.scroll, 0);

        // A key release is the same keystroke reported twice; it moves nothing.
        let mut release = key(KeyCode::Down);
        release.kind = KeyEventKind::Release;
        assert_eq!(app.on_key(release, 10), AppAction::None);
        assert_eq!(app.fleet.scroll, 0);
    }

    #[test]
    fn tab_and_backtab_toggle_the_focused_pane() {
        let mut app = App::new();
        assert_eq!(app.focus, PaneFocus::Fleet, "Fleet is focused on startup");

        assert_eq!(app.on_key(key(KeyCode::Tab), 10), AppAction::None);
        assert_eq!(app.focus, PaneFocus::Work);
        assert_eq!(app.on_key(key(KeyCode::Tab), 10), AppAction::None);
        assert_eq!(app.focus, PaneFocus::Fleet, "Tab toggles back");

        // Shift-Tab (BackTab) is the same two-pane toggle as Tab, not its own direction.
        assert_eq!(app.on_key(key(KeyCode::BackTab), 10), AppAction::None);
        assert_eq!(app.focus, PaneFocus::Work);
        assert_eq!(app.on_key(key(KeyCode::BackTab), 10), AppAction::None);
        assert_eq!(app.focus, PaneFocus::Fleet);
    }

    /// Arrow and page keys act on the focused pane alone; the boundary clamps within it and never
    /// transfers focus.
    #[test]
    fn scroll_keys_move_only_the_focused_pane() {
        let mut app = App::new();
        app.on_key(key(KeyCode::Down), 10);
        assert_eq!(app.fleet.scroll, 1);
        assert_eq!(app.work.scroll, 0, "Work is not focused, so it does not move");

        app.on_key(key(KeyCode::Tab), 10);
        assert_eq!(app.focus, PaneFocus::Work);
        app.on_key(key(KeyCode::PageDown), 6);
        assert_eq!(app.work.scroll, 6, "the page moves by the focused pane's own viewport");
        assert_eq!(app.fleet.scroll, 1, "the fleet offset is untouched while work is focused");

        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.work.scroll, 5);
        assert_eq!(app.fleet.scroll, 1);

        app.on_key(key(KeyCode::Tab), 10);
        assert_eq!(app.focus, PaneFocus::Fleet);
        app.on_key(key(KeyCode::PageUp), 100);
        assert_eq!(app.fleet.scroll, 0, "the top is a floor for the fleet pane too");
        assert_eq!(app.work.scroll, 5, "and work is untouched now that fleet is focused");
    }

    #[test]
    fn focused_viewport_is_the_focused_panes_own_and_never_zero() {
        let mut app = App::new();
        let metrics = Metrics {
            fleet: PaneMetrics { content_lines: 30, viewport_lines: 8 },
            work: PaneMetrics { content_lines: 12, viewport_lines: 0 },
        };
        assert_eq!(app.focused_viewport(metrics), 8, "Fleet is focused by default");

        app.focus = PaneFocus::Work;
        assert_eq!(
            app.focused_viewport(metrics), 1,
            "a pane with no visible rows still yields at least one page line"
        );
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
    fn g_requests_both_readers() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10), AppAction::RefreshBoth);
        assert!(app.begin_refresh(start));
        assert!(app.begin_work_refresh(start));

        // The request is only honoured once per pane: a second `g' while both reads run is
        // dropped at each pane's own door.
        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10), AppAction::RefreshBoth);
        assert!(!app.begin_refresh(start + Duration::from_secs(1)));
        assert!(!app.begin_work_refresh(start + Duration::from_secs(1)));

        // A manual refresh restarts both cadences rather than leaving a tick due immediately
        // after it.
        assert_eq!(app.on_tick(start + Duration::from_millis(1)), AppAction::None);
    }

    /// `g` is a request per pane, not one request for the pair: a fleet read in flight must not
    /// swallow the retry the navigator pressed `g` for.
    #[test]
    fn g_starts_the_idle_reader_when_the_other_is_busy() {
        let mut app = App::new();
        let start = Instant::now();
        assert!(app.begin_refresh(start), "the fleet is already reading");

        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10), AppAction::RefreshBoth);
        assert!(!app.begin_refresh(start), "the busy pane refuses");
        assert!(app.begin_work_refresh(start), "and the idle one still starts");
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
