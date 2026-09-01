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

use crate::supervisor::{ReadOnlyReason, SupervisionMode, SupervisorKind};
use crate::model::{FleetRow, RowState, WorkBuckets};
use crate::session::SessionView;
use crate::readers::{read_configured_supervisor, read_fleet, read_work, Programs, ReaderPaths, ReadError};

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
        clamp_scroll(&mut self.scroll, content_lines, viewport_lines);
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

/// Which of the three widgets the keyboard acts on. Fleet is focused on startup; `Tab` and
/// `Shift-Tab` cycle it in opposite directions, and arrow/page keys act on the focused pane
/// alone - moving the selection under Fleet, and that pane's own scroll under Work and Session.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PaneFocus {
    #[default]
    Fleet,
    Work,
    Session,
}

impl PaneFocus {
    /// Tab: Fleet -> Work -> Session -> Fleet.
    pub fn next(self) -> Self {
        match self {
            Self::Fleet => Self::Work,
            Self::Work => Self::Session,
            Self::Session => Self::Fleet,
        }
    }

    /// Shift-Tab: the reverse of `next`.
    pub fn previous(self) -> Self {
        match self {
            Self::Fleet => Self::Session,
            Self::Session => Self::Work,
            Self::Work => Self::Fleet,
        }
    }
}

/// The Session pane's own scroll offset, and the lines one frame draws it from. It has no reader
/// and therefore no `PaneContent`: what it shows is a child's screen, materialised by
/// `SessionHost::sync` BEFORE the frame, or one of the bodies derived from the selection and the
/// supervision mode.
///
/// `App` holds no pty, no thread and no child - only the value the renderer reads. That is what
/// keeps `ui::draw` pure while a reader thread writes into a parser continuously: the child's
/// bytes reach the screen only through a view frozen before the frame began.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionPane {
    pub scroll: usize,
    pub view: SessionView,
}

impl SessionPane {
    /// The same clamp the reader panes get, against this pane's own geometry alone.
    pub fn clamp_scroll(&mut self, content_lines: usize, viewport_lines: usize) {
        clamp_scroll(&mut self.scroll, content_lines, viewport_lines);
    }
}

/// One line of the Fleet pane's body, in order, saying what that line IS rather than how it
/// looks.
///
/// This is the one owner of the body's shape. `ui::fleet_document` renders this list one `Line`
/// per element, and `App::move_selection` finds a row's document line by looking for its
/// `Row(index)` here; neither keeps arithmetic of its own. A line added above the table - by this
/// pane's future lifecycle keys, or by anything else - is added here once and both readers follow
/// it.
#[derive(Clone, Debug, PartialEq)]
pub enum FleetBodyLine {
    /// "Loading fleet..." - a pane that has never had a snapshot.
    Loading,
    /// The retained error a stale pane opens with.
    RetainedError(String),
    /// The error an unavailable pane shows instead of a table.
    Failure(String),
    /// A spacer.
    Blank,
    /// "No fleet snapshot is available."
    NoSnapshot,
    /// "Press g to retry."
    Retry,
    /// "The last successful fleet snapshot remains visible." - a stale pane's closing line.
    StaleTrailer,
    /// The table's column heading.
    Heading,
    /// The fleet row at this index in the pane's own rows.
    Row(usize),
    /// The diagnostic line under the row at this index.
    Diagnostic(usize),
}

/// The Fleet pane's body, line by line, from the pane's content alone.
///
/// It asks neither the clock nor the pane's width, which is what lets `App::move_selection` place
/// a row on a keypress without building a frame: the fleet body's LINE COUNT does not depend on
/// width, only its column layout does.
pub fn fleet_body(content: &PaneContent<Vec<FleetRow>>) -> Vec<FleetBodyLine> {
    fn table(rows: &[FleetRow], out: &mut Vec<FleetBodyLine>) {
        out.push(FleetBodyLine::Heading);
        for (index, row) in rows.iter().enumerate() {
            out.push(FleetBodyLine::Row(index));
            if row.state == RowState::Invalid && row.diagnostic.is_some() {
                out.push(FleetBodyLine::Diagnostic(index));
            }
        }
    }

    let mut body = Vec::new();
    match content {
        PaneContent::Loading => body.push(FleetBodyLine::Loading),
        PaneContent::Fresh { value, .. } => table(value, &mut body),
        PaneContent::Stale { value, error, .. } => {
            body.push(FleetBodyLine::RetainedError(error.clone()));
            body.push(FleetBodyLine::Blank);
            table(value, &mut body);
            body.push(FleetBodyLine::Blank);
            body.push(FleetBodyLine::StaleTrailer);
        }
        PaneContent::Unavailable { error, .. } => {
            body.push(FleetBodyLine::Failure(error.clone()));
            body.push(FleetBodyLine::Blank);
            body.push(FleetBodyLine::NoSnapshot);
            body.push(FleetBodyLine::Retry);
        }
    }
    body
}

/// Which line of BODY the fleet row at INDEX occupies, or `None` when this body has no such row -
/// a loading or unavailable pane has no table at all.
pub fn body_line_of_row(body: &[FleetBodyLine], index: usize) -> Option<usize> {
    body.iter().position(|entry| *entry == FleetBodyLine::Row(index))
}

/// Pull SCROLL back only when CONTENT_LINES no longer reaches it. The one owner of that rule,
/// shared by `Pane<T>` and `SessionPane` so a third widget cannot acquire a fourth spelling.
pub fn clamp_scroll(scroll: &mut usize, content_lines: usize, viewport_lines: usize) {
    let max = content_lines.saturating_sub(viewport_lines);
    if *scroll > max {
        *scroll = max;
    }
}

/// One pane's geometry for a drawn frame: how many lines its body came to, and how many the
/// viewport actually shows once its border is taken off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaneMetrics {
    pub content_lines: usize,
    pub viewport_lines: usize,
    /// The pane's inner width in cells. Needed because a pty has to be told a width, and
    /// `ui::metrics` is the one place a pane's geometry is computed.
    pub inner_width: usize,
}

/// The geometry one draw of `App` at one `now` in one `Rect` would produce, one `PaneMetrics` per
/// widget. `ui::metrics` derives this from the same pure layout `ui::draw` renders from, so a
/// page size, a clamp and a range cue can never be computed from three different geometries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Metrics {
    pub fleet: PaneMetrics,
    pub work: PaneMetrics,
    pub session: PaneMetrics,
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
    /// The Session pane's scroll offset. Not a `Pane<T>`: no reader stands behind it.
    pub session: SessionPane,
    /// The selected agent, held by NAME rather than by index: the roster can shrink, and an
    /// index would silently come to mean a different agent. `None` only before the first
    /// successful fleet read, or when the fleet is empty.
    pub selected: Option<String>,
    /// A one-line message shown in the header in gold, in place of the refresh/stale span, and
    /// cleared by the next key press. Today it has exactly one writer: a selection lost to a
    /// roster change.
    pub notice: Option<String>,
    /// Which widget the keyboard currently acts on. Fleet by default.
    pub focus: PaneFocus,
    /// What this process is allowed to do with the checkout it is drawing (cb-kcs.1).
    ///
    /// Display state only: the lease itself lives in `main.rs`, because binding a listener is not
    /// something a struct the renderer reads should be able to do. The header line is the whole of
    /// its surface - the navigator chose that over an Ownership pane, so that ownership never
    /// takes a row or a Tab stop from Fleet and Work.
    pub supervision: SupervisionMode,
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
        Self::with_supervision(SupervisionMode::ReadOnly(ReadOnlyReason::ConfiguredFor(
            SupervisorKind::Emacs,
        )))
    }

    /// An `App` whose ownership is known before the first frame.
    ///
    /// `new()` starts read-only-because-Emacs, which is what an absent declaration means and so
    /// what almost every consumer is. Production reads the real answer before entering the
    /// terminal and constructs through this, so a process configured for the TUI never flashes an
    /// "Emacs owns supervision" frame on its way to owning the checkout.
    pub fn with_supervision(supervision: SupervisionMode) -> Self {
        Self {
            fleet: Pane::default(),
            work: Pane::default(),
            session: SessionPane::default(),
            selected: None,
            notice: None,
            focus: PaneFocus::default(),
            supervision,
            quit: false,
            last_fleet_request: None,
            last_work_request: None,
        }
    }

    /// Replace the ownership this view reports. Display state, and nothing else: the lease is the
    /// controller's, and this cannot bind, release or write anything.
    pub fn set_supervision(&mut self, supervision: SupervisionMode) {
        self.supervision = supervision;
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
        // A notice is transient by design: it survives exactly until the navigator touches the
        // keyboard, whatever they press.
        self.notice = None;
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
            // Three panes, so the two bindings are opposite directions round one cycle rather
            // than the same toggle. A boundary clamps within the focused pane; it never
            // transfers focus on its own.
            KeyCode::Tab => {
                self.focus = self.focus.next();
                AppAction::None
            }
            KeyCode::BackTab => {
                self.focus = self.focus.previous();
                AppAction::None
            }
            // Under Fleet these four move the SELECTION and let the pane follow it; under Work
            // and Session they move that pane's own offset, as they always have.
            KeyCode::Up if self.focus == PaneFocus::Fleet => {
                self.move_selection(-1, viewport_lines);
                AppAction::None
            }
            KeyCode::Down if self.focus == PaneFocus::Fleet => {
                self.move_selection(1, viewport_lines);
                AppAction::None
            }
            KeyCode::PageUp if self.focus == PaneFocus::Fleet => {
                self.move_selection(-(viewport_lines as isize), viewport_lines);
                AppAction::None
            }
            KeyCode::PageDown if self.focus == PaneFocus::Fleet => {
                self.move_selection(viewport_lines as isize, viewport_lines);
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

    /// Move the selection by DELTA rows, saturating at both ends of the current fleet, and
    /// scroll the Fleet pane by the least that keeps the new row visible. With no rows, or no
    /// selection, it does nothing at all.
    fn move_selection(&mut self, delta: isize, viewport_lines: usize) {
        let Some(current) = self.selected_index() else { return };
        let Some(rows) = self.fleet.content.value() else { return };
        if rows.is_empty() {
            return;
        }
        let last = rows.len() - 1;
        let target = (current as isize)
            .saturating_add(delta)
            .clamp(0, last as isize) as usize;
        self.selected = Some(rows[target].name.clone());
        let body = fleet_body(&self.fleet.content);
        if let Some(line) = body_line_of_row(&body, target) {
            self.follow_selection(line, viewport_lines);
        }
    }

    /// Bring DOCUMENT_LINE into the Fleet pane's viewport, moving `scroll` by the least that does
    /// so and leaving it alone when the line is already visible.
    ///
    /// DOCUMENT_LINE is where the row sits in what `ui::fleet_document` produced, which is NOT
    /// the row index: the document opens with a heading line, and a row whose state file failed
    /// to parse contributes a second line of its own. `fleet_body` is the one place that shape
    /// lives.
    ///
    /// Two rules, and the second is the exception:
    ///
    /// - **Least movement.** A line already visible moves nothing; a line outside the viewport is
    ///   brought just inside it, from whichever side it left.
    /// - **A row inside the document's first viewport snaps to the top** (`document_line <
    ///   viewport`). That is deliberately MORE movement than least: it can fire on a row that is
    ///   already visible, and it does, so that walking back up to the top of the table brings the
    ///   column heading - and, under a stale pane, the retained error and its blank line - back
    ///   into view rather than leaving the table headless. It is bounded by the viewport rather
    ///   than unconditional because snapping to 0 on a pane with ONE visible line would scroll
    ///   the selection off it, which is exactly what the 40x12 floor gives Fleet in the stacked
    ///   layout.
    ///
    /// DOCUMENT_LINE comes from `body_line_of_row` over `fleet_body`, which is the one place the
    /// body's shape is known.
    fn follow_selection(&mut self, document_line: usize, viewport_lines: usize) {
        let viewport = viewport_lines.max(1);
        if document_line < viewport {
            self.fleet.scroll = 0;
        } else if document_line < self.fleet.scroll {
            self.fleet.scroll = document_line;
        } else if document_line >= self.fleet.scroll + viewport {
            self.fleet.scroll = document_line + 1 - viewport;
        }
    }

    /// A mutable handle on whichever pane's scroll offset the keyboard currently moves. Every
    /// pane's `scroll` is a `usize`, so this returns the same type whichever is focused and
    /// `on_key` never needs to know which one it moved.
    ///
    /// The `Fleet` arm is unreachable and required: the four guarded arms above intercept every
    /// key that would reach here under Fleet focus, because Fleet's arrows move the SELECTION.
    /// It stays for exhaustiveness, and returning that pane's own offset is the only answer that
    /// could not surprise a future caller.
    fn focused_scroll_mut(&mut self) -> &mut usize {
        match self.focus {
            PaneFocus::Fleet => &mut self.fleet.scroll,
            PaneFocus::Work => &mut self.work.scroll,
            PaneFocus::Session => &mut self.session.scroll,
        }
    }

    /// The focused pane's own viewport height, floored at one page. The single owner of that
    /// floor: callers pass this straight to `on_key` and never apply their own `.max(1)`.
    pub fn focused_viewport(&self, metrics: Metrics) -> usize {
        match self.focus {
            PaneFocus::Fleet => metrics.fleet.viewport_lines.max(1),
            PaneFocus::Work => metrics.work.viewport_lines.max(1),
            PaneFocus::Session => metrics.session.viewport_lines.max(1),
        }
    }

    /// Does the focused Session pane currently hold the keyboard?
    ///
    /// True only when the Session pane is focused AND its view is `Live`: an ended or absent
    /// session leaves the arrows, `g` and `q` exactly as they are, which is what makes a retained
    /// pass scrollable at all.
    pub fn session_has_keyboard(&self) -> bool {
        self.focus == PaneFocus::Session && matches!(self.session.view, SessionView::Live { .. })
    }

    /// Install the view `SessionHost::sync` materialised for this frame.
    ///
    /// A `Live` view is never scrolled - the child redraws itself into the pane, and there is
    /// nothing above the top row to reach - so this forces the offset to 0 while a session is
    /// live and leaves it alone otherwise.
    pub fn set_session_view(&mut self, view: SessionView) {
        if matches!(view, SessionView::Live { .. }) {
            self.session.scroll = 0;
        }
        self.session.view = view;
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

    /// The selected agent's index in the current fleet rows, if there is one and it is still
    /// there. Re-derived every time rather than stored: only the name is state.
    pub fn selected_index(&self) -> Option<usize> {
        let name = self.selected.as_deref()?;
        let rows = self.fleet.content.value()?;
        rows.iter().position(|row| row.name == name)
    }

    /// Reconcile the selection against the rows a successful fleet read has just installed.
    ///
    /// PREVIOUS_INDEX is the index the selection had BEFORE this read, which is why it is a
    /// parameter: by the time this runs, the old rows are gone.
    ///
    /// Called from the `Ok` arm of `finish_refresh` alone. A failed refresh must never move or
    /// clear the selection - a five-second `ps` hiccup is not a roster change.
    fn reconcile_selection(&mut self, previous_index: Option<usize>) {
        // Read the rows in place rather than taking a copy: this runs every five seconds, and
        // the pane already owns them.
        let (first, still_there, replacement) = {
            let Some(rows) = self.fleet.content.value() else { return };
            let selected = self.selected.as_deref();
            (
                rows.first().map(|row| row.name.clone()),
                selected.is_some_and(|name| rows.iter().any(|row| row.name == name)),
                rows.get(previous_index.unwrap_or(0).min(rows.len().saturating_sub(1)))
                    .map(|row| row.name.clone()),
            )
        };
        let Some(lost) = self.selected.clone() else {
            // No selection yet: the first successful read selects the first row, silently.
            self.selected = first;
            return;
        };
        if still_there {
            return;
        }
        match replacement {
            Some(new) => {
                self.notice = Some(format!("{lost} is no longer on the roster. Selected {new}."));
                self.selected = Some(new);
            }
            None => {
                self.selected = None;
                self.notice = Some(format!("{lost} is no longer on the roster."));
            }
        }
    }

    /// The fleet pane's content transition; see `Pane::finish` for the whole rule.
    ///
    /// A successful read also reconciles the selection against the rows it brought back. A
    /// failure does not: a five-second `ps` hiccup must never silently reselect an agent.
    pub fn finish_refresh(&mut self, result: Result<Vec<FleetRow>, ReadError>, at: DateTime<Utc>) {
        let previous_index = self.selected_index();
        let succeeded = result.is_ok();
        self.fleet.finish(result, at);
        if succeeded {
            self.reconcile_selection(previous_index);
        }
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
/// Ownership's worker: `read_configured_supervisor` on its own thread (cb-kcs.1).
///
/// A third worker rather than a question asked on the UI thread, for the reason the other two
/// exist: `scripts/fleet-supervisor` is a subprocess with a five-second bound, and a declaration
/// that takes five seconds to answer would freeze the screen - keys and all - for exactly as long
/// as the thing that went wrong. The inner `Result` is the answer (`Err(raw)` for an invalid
/// declaration); the outer one is whether the reader ran at all.
pub type SupervisorWorker = Worker<Result<SupervisorKind, String>>;

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

    /// The same worker with the reader's wall-clock bound as a parameter, for the tests alone.
    ///
    /// A test that drives this worker over a fixture is asserting that the *worker* answers, not
    /// that a two-line bash script beats production's five seconds on a loaded machine — see
    /// `TEST_TIMEOUT` in `readers.rs` for what that cost before it was tracked down.
    #[cfg(test)]
    pub(crate) fn spawn_with_timeout(
        paths: ReaderPaths,
        programs: Programs,
        timeout: std::time::Duration,
    ) -> Self {
        Self::spawn_reader(move || {
            crate::readers::read_fleet_with_timeout(&paths, &programs, timeout)
        })
    }
}

impl Worker<WorkBuckets> {
    pub fn spawn(paths: ReaderPaths, programs: Programs) -> Self {
        Self::spawn_reader(move || read_work(&paths, &programs))
    }

}

impl Worker<Result<SupervisorKind, String>> {
    pub fn spawn(paths: ReaderPaths) -> Self {
        Self::spawn_reader(move || read_configured_supervisor(&paths))
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
    use crate::model::AgentKind;

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

    /// `fleet_body` is the one owner of the Fleet pane's body shape, and `body_line_of_row` is
    /// how a row index becomes a document line. Every kind of line the body can carry is here.
    #[test]
    fn the_body_names_where_every_kind_of_line_lands() {
        let invalid = |name: &str| FleetRow {
            state: RowState::Invalid,
            diagnostic: Some("bad json".into()),
            ..row(name)
        };

        let body = fleet_body(&PaneContent::Loading);
        assert_eq!(body, vec![FleetBodyLine::Loading]);
        assert_eq!(body_line_of_row(&body, 0), None, "a loading pane has no table");

        let body = fleet_body(&PaneContent::Unavailable {
            failed_at: at(5),
            error: "ps: boom".into(),
        });
        assert_eq!(
            body,
            vec![
                FleetBodyLine::Failure("ps: boom".into()),
                FleetBodyLine::Blank,
                FleetBodyLine::NoSnapshot,
                FleetBodyLine::Retry,
            ]
        );
        assert_eq!(body_line_of_row(&body, 0), None, "an unavailable pane has no table");

        let fresh = |rows: Vec<FleetRow>| PaneContent::Fresh { value: rows, read_at: at(0) };

        let body = fleet_body(&fresh(vec![]));
        assert_eq!(body, vec![FleetBodyLine::Heading], "an empty fleet still has its heading");
        assert_eq!(body_line_of_row(&body, 0), None);

        let body = fleet_body(&fresh(vec![row("A"), row("B"), row("C")]));
        assert_eq!(body_line_of_row(&body, 0), Some(1));
        assert_eq!(body_line_of_row(&body, 1), Some(2));
        assert_eq!(body_line_of_row(&body, 2), Some(3));

        // A diagnostic BEFORE the index costs a line; one AT it does not.
        let body = fleet_body(&fresh(vec![row("A"), invalid("B"), row("C"), invalid("D")]));
        assert_eq!(body_line_of_row(&body, 1), Some(2), "the invalid row's own line");
        assert_eq!(body_line_of_row(&body, 2), Some(4), "one diagnostic line above it");
        assert_eq!(body_line_of_row(&body, 3), Some(5));

        // An invalid row carrying no diagnostic emits no extra line.
        let body = fleet_body(&fresh(vec![
            FleetRow { diagnostic: None, ..invalid("A") },
            row("B"),
        ]));
        assert_eq!(body_line_of_row(&body, 1), Some(2));

        let body = fleet_body(&PaneContent::Stale {
            value: vec![row("A"), row("B"), row("C")],
            read_at: at(0),
            failed_at: at(5),
            error: "ps: boom".into(),
        });
        assert_eq!(body[0], FleetBodyLine::RetainedError("ps: boom".into()));
        assert_eq!(body[1], FleetBodyLine::Blank);
        assert_eq!(body[2], FleetBodyLine::Heading);
        assert_eq!(body[body.len() - 2], FleetBodyLine::Blank);
        assert_eq!(body[body.len() - 1], FleetBodyLine::StaleTrailer);
        assert_eq!(body_line_of_row(&body, 0), Some(3));
        assert_eq!(body_line_of_row(&body, 1), Some(4));
        assert_eq!(body_line_of_row(&body, 2), Some(5));
    }

    fn failure() -> ReadError {
        ReadError::Exit {
            source: "ps".into(),
            status: Some(3),
            stderr: "ps: boom".into(),
            stdout: String::new(),
        }
    }

    fn bd_failure() -> ReadError {
        ReadError::Exit {
            source: "bd".into(),
            status: Some(1),
            stderr: "bd list failed: database is locked".into(),
            stdout: String::new(),
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
    /// Line and page movement on a pane that scrolls: Work, since Fleet's own arrows move the
    /// selection instead (cb-kcs.2.1).
    #[test]
    fn scroll_keys_move_by_line_or_viewport() {
        let mut app = App::new();
        app.focus = PaneFocus::Work;
        assert_eq!(app.on_key(key(KeyCode::Down), 10), AppAction::None);
        assert_eq!(app.work.scroll, 1);
        assert_eq!(app.on_key(key(KeyCode::Down), 10), AppAction::None);
        assert_eq!(app.work.scroll, 2);
        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.work.scroll, 1);

        // The top is a floor, never a negative offset.
        app.on_key(key(KeyCode::Up), 10);
        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.work.scroll, 0);

        app.on_key(key(KeyCode::PageDown), 10);
        assert_eq!(app.work.scroll, 10, "a page is the viewport the frame just showed");
        app.on_key(key(KeyCode::PageDown), 7);
        assert_eq!(app.work.scroll, 17);
        app.on_key(key(KeyCode::PageUp), 7);
        assert_eq!(app.work.scroll, 10);
        app.on_key(key(KeyCode::PageUp), 100);
        assert_eq!(app.work.scroll, 0);

        // A key release is the same keystroke reported twice; it moves nothing.
        let mut release = key(KeyCode::Down);
        release.kind = KeyEventKind::Release;
        assert_eq!(app.on_key(release, 10), AppAction::None);
        assert_eq!(app.work.scroll, 0);
    }

    #[test]
    fn tab_cycles_fleet_work_session_and_backtab_reverses() {
        let mut app = App::new();
        assert_eq!(app.focus, PaneFocus::Fleet, "Fleet is focused on startup");

        for expected in [PaneFocus::Work, PaneFocus::Session, PaneFocus::Fleet, PaneFocus::Work] {
            assert_eq!(app.on_key(key(KeyCode::Tab), 10), AppAction::None);
            assert_eq!(app.focus, expected);
        }

        // Shift-Tab is the reverse of that cycle, not the same toggle.
        let mut app = App::new();
        for expected in [PaneFocus::Session, PaneFocus::Work, PaneFocus::Fleet, PaneFocus::Session] {
            assert_eq!(app.on_key(key(KeyCode::BackTab), 10), AppAction::None);
            assert_eq!(app.focus, expected);
        }
    }

    /// Arrow and page keys act on the focused pane alone; the boundary clamps within it and never
    /// transfers focus. Under Fleet they move the SELECTION, not that pane's raw offset.
    #[test]
    fn scroll_keys_move_only_the_focused_pane() {
        let mut app = App::new();
        app.on_key(key(KeyCode::Tab), 10);
        assert_eq!(app.focus, PaneFocus::Work);
        app.on_key(key(KeyCode::PageDown), 6);
        assert_eq!(app.work.scroll, 6, "the page moves by the focused pane's own viewport");
        assert_eq!(app.fleet.scroll, 0, "the fleet offset is untouched while work is focused");
        assert_eq!(app.session.scroll, 0, "and so is the session's");

        app.on_key(key(KeyCode::Up), 10);
        assert_eq!(app.work.scroll, 5);

        app.on_key(key(KeyCode::Tab), 10);
        assert_eq!(app.focus, PaneFocus::Session);
        app.on_key(key(KeyCode::PageDown), 4);
        assert_eq!(app.session.scroll, 4, "the session pane has its own offset");
        assert_eq!(app.work.scroll, 5, "and work is untouched now that session is focused");
        app.on_key(key(KeyCode::PageUp), 100);
        assert_eq!(app.session.scroll, 0, "the top is a floor for the session pane too");
        assert_eq!(app.work.scroll, 5);
    }

    /// Under Fleet focus the arrows move the selection, and the pane scrolls by the least that
    /// keeps the selected row's own DOCUMENT line visible.
    #[test]
    fn arrows_move_the_selection_and_scroll_the_fleet_to_follow_it() {
        let mut app = App::new();
        let names = ["A", "B", "C", "D", "E", "F", "G", "H"];
        app.finish_refresh(Ok(names.iter().map(|n| row(n)).collect()), at(0));
        assert_eq!(app.selected.as_deref(), Some("A"));
        assert_eq!(app.fleet.scroll, 0);

        // Three lines of viewport: the heading plus rows A and B are visible at scroll 0, so the
        // selection can reach row B (document line 2) before anything has to move.
        for _ in 0..5 {
            app.on_key(key(KeyCode::Down), 3);
        }
        assert_eq!(app.selected.as_deref(), Some("F"), "five rows down from A");
        // F is at index 5, document line 6; the least scroll showing line 6 in a 3-line viewport
        // is 4.
        assert_eq!(app.fleet.scroll, 4);
        assert_eq!(app.work.scroll, 0, "the work pane never moves for a fleet key");

        for _ in 0..5 {
            app.on_key(key(KeyCode::Up), 3);
        }
        assert_eq!(app.selected.as_deref(), Some("A"));
        assert_eq!(app.fleet.scroll, 0, "coming back to the top scrolls back to it");

        // The ends saturate rather than wrapping.
        app.on_key(key(KeyCode::Up), 3);
        assert_eq!(app.selected.as_deref(), Some("A"));
        app.on_key(key(KeyCode::PageDown), 3);
        assert_eq!(app.selected.as_deref(), Some("D"), "a page is a viewport of rows");
        app.on_key(key(KeyCode::PageDown), 100);
        assert_eq!(app.selected.as_deref(), Some("H"), "and it stops at the last row");
        app.on_key(key(KeyCode::PageUp), 100);
        assert_eq!(app.selected.as_deref(), Some("A"));
    }

    /// With no rows at all there is nothing to select and nothing to move.
    #[test]
    fn selection_keys_do_nothing_without_a_fleet() {
        let mut app = App::new();
        assert_eq!(app.on_key(key(KeyCode::Down), 10), AppAction::None);
        assert_eq!(app.selected, None);
        assert_eq!(app.fleet.scroll, 0);
    }

    /// A viewport of one line - what the 40x12 floor gives the Fleet pane in the stacked layout -
    /// must still show the selected ROW rather than the heading above it.
    #[test]
    fn a_one_line_viewport_shows_the_row_and_not_the_heading() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(["A", "B", "C"].iter().map(|n| row(n)).collect()),
            at(0),
        );
        assert_eq!(app.selected.as_deref(), Some("A"));

        // Row A is document line 1, and one visible line can hold the heading or the row, not
        // both: it must be the row.
        app.on_key(key(KeyCode::Down), 1);
        assert_eq!(app.selected.as_deref(), Some("B"));
        assert_eq!(app.fleet.scroll, 2, "row B, alone, is what the one line shows");
        app.on_key(key(KeyCode::Up), 1);
        assert_eq!(app.selected.as_deref(), Some("A"));
        assert_eq!(app.fleet.scroll, 1, "and coming back shows row A rather than the heading");
    }

    /// A stale pane's body opens with its retained error and a blank line, so following the
    /// table's own line number would leave the selected row two rows below the fold.
    #[test]
    fn the_follow_scroll_counts_a_stale_panes_own_prefix() {
        let names: Vec<FleetRow> = ["A", "B", "C", "D", "E", "F", "G", "H"]
            .iter()
            .map(|n| row(n))
            .collect();

        let mut fresh = App::new();
        fresh.finish_refresh(Ok(names.clone()), at(0));
        let mut stale = App::new();
        stale.finish_refresh(Ok(names.clone()), at(0));
        stale.finish_refresh(Err(failure()), at(5));
        assert_eq!(stale.selected.as_deref(), Some("A"), "the failure kept the selection");
        // Read the two panes' first-row lines from the bodies themselves rather than from a
        // literal: that is what the constant this replaced always meant.
        let stale_first = body_line_of_row(&fleet_body(&stale.fleet.content), 0).unwrap();
        let fresh_first = body_line_of_row(&fleet_body(&fresh.fleet.content), 0).unwrap();

        for _ in 0..5 {
            fresh.on_key(key(KeyCode::Down), 3);
            stale.on_key(key(KeyCode::Down), 3);
        }
        assert_eq!(fresh.selected.as_deref(), stale.selected.as_deref());
        assert_eq!(
            stale.fleet.scroll,
            fresh.fleet.scroll + (stale_first - fresh_first),
            "the stale pane scrolls past its own error and blank line as well"
        );

        // And back up. The fresh pane snaps to the top and brings its heading with it, because
        // three visible lines can hold both. The stale pane's first row is document line 3, so
        // three lines cannot also hold the error, the blank and the heading - least movement puts
        // the row at the top and shows none of them, which is the right trade.
        for _ in 0..5 {
            fresh.on_key(key(KeyCode::Up), 3);
            stale.on_key(key(KeyCode::Up), 3);
        }
        assert_eq!(fresh.selected.as_deref(), Some("A"));
        assert_eq!(stale.selected.as_deref(), Some("A"));
        assert_eq!(fresh.fleet.scroll, 0);
        assert_eq!(
            stale.fleet.scroll, stale_first,
            "three visible lines cannot hold the error, the blank, the heading AND the row, so \
             the row is what they show"
        );
    }

    /// Each pane's offset survives a refresh that returns the same content, and each clamps
    /// against its own geometry alone - what a third pane makes easiest to break.
    #[test]
    fn each_pane_preserves_and_clamps_its_own_scroll() {
        let mut app = App::new();
        app.finish_refresh(Ok((0..20).map(|i| row(&format!("A{i}"))).collect()), at(0));
        app.finish_work_refresh(Ok(buckets(&["cb-1", "cb-2"])), at(0));
        app.fleet.scroll = 12;
        app.work.scroll = 3;
        app.session.scroll = 2;

        // Same-sized content: every offset is exactly where it was.
        app.fleet.clamp_scroll(24, 10);
        app.work.clamp_scroll(10, 5);
        app.session.clamp_scroll(6, 3);
        assert_eq!(app.fleet.scroll, 12);
        assert_eq!(app.work.scroll, 3);
        assert_eq!(app.session.scroll, 2);

        // A refresh of either pane that returns the same content does not touch any offset.
        app.finish_refresh(Ok((0..20).map(|i| row(&format!("A{i}"))).collect()), at(5));
        assert_eq!(app.fleet.scroll, 12);
        app.finish_work_refresh(Ok(buckets(&["cb-1", "cb-2"])), at(5));
        assert_eq!(app.work.scroll, 3);
        assert_eq!(app.session.scroll, 2);

        // Only a shorter pane's own content pulls its own offset back, and only as far as its own
        // last full viewport - no other pane's offset moves with it.
        app.finish_work_refresh(Ok(WorkBuckets::default()), at(10));
        app.work.clamp_scroll(2, 10);
        assert_eq!(app.work.scroll, 0);
        assert_eq!(app.fleet.scroll, 12, "the fleet offset is untouched by the work pane shrinking");
        assert_eq!(app.session.scroll, 2, "and so is the session's");

        app.fleet.scroll = 40;
        app.finish_refresh(Ok(vec![row("Xavier")]), at(10));
        app.fleet.clamp_scroll(30, 10);
        assert_eq!(app.fleet.scroll, 20);
        assert_eq!(app.work.scroll, 0, "and the work offset is untouched by the fleet clamping");
        assert_eq!(app.session.scroll, 2);

        // The session's own clamp reaches nothing but the session.
        app.session.clamp_scroll(1, 3);
        assert_eq!(app.session.scroll, 0);
        assert_eq!(app.fleet.scroll, 20);
    }

    #[test]
    fn a_key_press_clears_the_notice() {
        let mut app = App::new();
        app.notice = Some("Storm is no longer on the roster.".into());
        app.on_key(key(KeyCode::Tab), 10);
        assert_eq!(app.notice, None);

        // A key RELEASE is not a key press, and clears nothing.
        app.notice = Some("Storm is no longer on the roster.".into());
        let mut release = key(KeyCode::Down);
        release.kind = KeyEventKind::Release;
        app.on_key(release, 10);
        assert!(app.notice.is_some());
    }

    #[test]
    fn focused_viewport_is_the_focused_panes_own_and_never_zero() {
        let mut app = App::new();
        let metrics = Metrics {
            fleet: PaneMetrics { content_lines: 30, viewport_lines: 8, inner_width: 38 },
            work: PaneMetrics { content_lines: 12, viewport_lines: 0, inner_width: 38 },
            session: PaneMetrics { content_lines: 4, viewport_lines: 3, inner_width: 58 },
        };
        assert_eq!(app.focused_viewport(metrics), 8, "Fleet is focused by default");

        app.focus = PaneFocus::Work;
        assert_eq!(
            app.focused_viewport(metrics), 1,
            "a pane with no visible rows still yields at least one page line"
        );

        app.focus = PaneFocus::Session;
        assert_eq!(app.focused_viewport(metrics), 3, "the session pane reports its own");
    }

    /// The selection is a name, never an index: a roster that shrinks under the navigator must
    /// not silently come to mean a different agent.
    #[test]
    fn a_lost_selection_moves_to_a_surviving_row_and_says_so() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![
                row("Xavier"),
                row("Beast"),
                row("Storm"),
                row("Cyclops"),
            ]),
            at(0),
        );
        assert_eq!(app.selected.as_deref(), Some("Xavier"), "the first read selects row 0");
        assert_eq!(app.notice, None, "and says nothing about it");

        app.selected = Some("Storm".into());
        app.finish_refresh(
            Ok(vec![
                row("Xavier"),
                row("Beast"),
                row("Cyclops"),
            ]),
            at(5),
        );
        assert_eq!(app.selected.as_deref(), Some("Cyclops"), "the old index, clamped into range");
        assert_eq!(
            app.notice.as_deref(),
            Some("Storm is no longer on the roster. Selected Cyclops."),
        );
    }

    #[test]
    fn a_surviving_selection_that_moved_keeps_its_row_silently() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![
                row("Xavier"),
                row("Storm"),
            ]),
            at(0),
        );
        app.selected = Some("Storm".into());
        app.finish_refresh(
            Ok(vec![
                row("Storm"),
                row("Beast"),
                row("Xavier"),
            ]),
            at(5),
        );
        assert_eq!(app.selected.as_deref(), Some("Storm"));
        assert_eq!(app.selected_index(), Some(0), "the index is re-derived, never stored");
        assert_eq!(app.notice, None);
    }

    #[test]
    fn an_emptied_fleet_leaves_nothing_selected() {
        let mut app = App::new();
        app.finish_refresh(Ok(vec![row("Storm")]), at(0));
        app.finish_refresh(Ok(vec![]), at(5));
        assert_eq!(app.selected, None);
        assert_eq!(app.notice.as_deref(), Some("Storm is no longer on the roster."));
    }

    /// A five-second `ps` hiccup must never silently reselect an agent: `reconcile_selection`
    /// is called from the `Ok` path alone.
    #[test]
    fn a_failed_refresh_never_moves_the_selection() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![
                row("Xavier"),
                row("Storm"),
            ]),
            at(0),
        );
        app.selected = Some("Storm".into());
        app.finish_refresh(Err(failure()), at(5));
        assert_eq!(app.selected.as_deref(), Some("Storm"));
        assert_eq!(app.notice, None);
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

        let worker = FleetWorker::spawn_with_timeout(
            ReaderPaths {
                consumer_root: dir.path().to_path_buf(),
                shared_root: dir.path().to_path_buf(),
                scripts_dir: scripts,
            },
            Programs {
                ps: dir.path().join("ps"),
                bd: "bd".into(),
            },
            Duration::from_secs(60),
        );
        assert!(worker.poll().is_none(), "nothing was asked for yet");
        assert!(worker.request());

        // Generous on purpose: this asserts the worker answers off the UI thread, not that a
        // fixture beats a stopwatch on a loaded machine.
        let deadline = Instant::now() + Duration::from_secs(60);
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
