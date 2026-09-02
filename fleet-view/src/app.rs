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

use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use crate::supervisor::{ReadOnlyReason, SupervisionMode, SupervisorKind};
use crate::model::{self, Bead, FleetRow, GhSnapshot, HistoryRow, RowState, WorkBuckets};
use crate::lifecycle::LastExit;
use crate::session::SessionView;
use crate::readers::{
    read_configured_supervisor, read_fleet, read_gh, read_history, read_sweeps, read_work,
    Commands, Judged, Programs, ReaderPaths, ReadError,
};
use crate::sweeps::Finding;
use crate::triggers::GhAnswer;

/// How often the fleet is re-read while nobody touches the keyboard. Agreed in the parent epic's
/// interview: fast enough that a claim appears while the navigator is still looking at the row,
/// slow enough that a `ps` per tick is not what the machine is doing.
pub const FLEET_REFRESH_INTERVAL: Duration = Duration::from_secs(5);

/// How often the bead panel is re-read. Six times the fleet's interval, and agreed separately in
/// the same interview: work moves in the minutes a bead takes, not in the seconds a claim takes,
/// and each read is a whole `bd` query against the shared board.
pub const WORK_REFRESH_INTERVAL: Duration = Duration::from_secs(30);

/// How often `gh` is asked what is open. Ten minutes, the elisp view's own number
/// (`cerebro-gh-refresh-seconds`, `emacs/cerebro.el:5741`): each answer is three network calls,
/// and the two roles it feeds are on an hourly floor anyway, so a ten-minute reader is already
/// finer-grained than anything it can cause. Never on the five-second tick.
pub const GH_REFRESH_INTERVAL: Duration = Duration::from_secs(600);

/// How often the six sweeps re-run. Ten minutes, `cerebro-sweep-refresh-seconds`
/// (`emacs/cerebro.el`): six scripts, three of which fetch from origin, against a thirty-second
/// `bd list`. Never on the five-second tick.
pub const SWEEP_REFRESH_INTERVAL: Duration = Duration::from_secs(600);

/// How often `scripts/fleet-history` is asked what the fleet has been doing.
///
/// Five minutes, `cerebro-history-refresh-seconds` (`emacs/cerebro.el`): it is a `jq` walk over a
/// log that grows without limit, and what it feeds is a line saying how long an agent has been
/// where it is - which does not change meaningfully inside five minutes. Never on the five-second
/// tick.
pub const HISTORY_REFRESH_INTERVAL: Duration = Duration::from_secs(300);

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

/// How many rows of one Work section are drawn before the rest become `+N more`.
///
/// Eight, so the sections worth reading are not pushed off the bottom by the third. The way past
/// it is `Enter` on the `+N more` row, which opens that one section (cb-kcs.5.4).
pub const WORK_ROWS_PER_SECTION: usize = 8;

/// How a section orders its rows and what it puts at the far end of one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SectionKind {
    /// Priority, then id: P0 reads first, and a tie does not shuffle between redraws.
    Open,
    /// `Open`'s order, plus how long the bead has been waiting for a person.
    Paused,
    /// Newest first. Priority says nothing about finished work - a merged P3 is no less done
    /// than a merged P0 - so this section answers "what just landed" instead.
    Merged,
}

/// One of the Work pane's own failure states, as a line rather than as a colour: `app.rs` owns
/// the order, `ui.rs` owns the colours and the words' styling.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkNotice {
    Loading,
    /// The gold error line above a stale snapshot.
    Stale(String),
    /// `The last successful work snapshot remains visible.`
    StaleFooter,
    /// The red error line of a pane with nothing to keep.
    Unavailable(String),
    /// `No work snapshot is available.`
    NoSnapshot,
    /// `Press g to retry.`
    Retry,
}

/// What the Work cursor stands on. Three kinds, because three kinds of row can be acted on.
///
/// A NAME in every case, never an index - `App::selected`'s rule: the findings are replaced
/// wholesale every ten minutes and the beads every thirty seconds, and an index would silently
/// come to mean a different bead or a different destructive command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkCursor {
    /// A sweep finding, by `Finding::key()`.
    Finding(String),
    /// A bead, by id.
    Bead(String),
    /// The `+N more` / `all N shown` row of the named section.
    More(&'static str),
}

/// One drawn line of the Work pane, saying what that line IS rather than how it looks.
///
/// `work_body` is the ONE place the pane's structure is decided: the renderer turns each of these
/// into a `Line` and computes no structure of its own, so the row the cursor is on and the row
/// that is drawn cannot come from two pieces of arithmetic. Before cb-kcs.5.4 this covered only
/// what lay above the six queues, and a cursor that walks bead rows cannot live with that.
///
/// `PartialEq` and never `Eq`: `HistoryRow`'s neighbours carry `f64`.
#[derive(Clone, Debug, PartialEq)]
pub enum WorkBodyLine<'a> {
    /// `Sweeps {n}`, and the failed script beside it when there is one.
    SweepHeader { count: usize, error: Option<String> },
    /// The finding at this index in `App::work_findings`, and its key.
    Finding { index: usize, key: String },
    /// A spacer.
    Blank,
    /// A line of the work pane's own failure states. Never selectable.
    Notice(WorkNotice),
    SectionHeader { title: &'static str, count: usize },
    Bead { bead: &'a Bead, suffix: Option<String> },
    /// `  (none)`.
    Empty,
    /// The `+N more` row, or the `all N shown` row of an open section.
    More { section: &'static str, hidden: usize, expanded: bool },
    HistoryHeader { count: usize, failed: bool },
    HistoryRow { text: String, long: bool },
}

impl WorkBodyLine<'_> {
    /// What the cursor would be on this line, or `None` for a line no key acts on - a header, a
    /// blank, `(none)`, a notice or a History row. A grey row therefore always means a key will
    /// do something here.
    pub fn cursor(&self) -> Option<WorkCursor> {
        match self {
            Self::Finding { key, .. } => Some(WorkCursor::Finding(key.clone())),
            Self::Bead { bead, .. } => Some(WorkCursor::Bead(bead.id.clone())),
            Self::More { section, .. } => Some(WorkCursor::More(section)),
            _ => None,
        }
    }
}

/// The whole Work document, in order: the Sweeps section, the six queues, then History.
///
/// The Sweeps section is FIRST on the screen (the navigator's choice: this pane shows about
/// fourteen rows of a forty-one row document, and a section below the fold is one nobody
/// presses), and History is LAST - the `M-x cerebro` order, so the two views read alike.
///
/// Nothing at all for Sweeps - not even a blank - when there are no findings and no error. That
/// is deliberately unlike the six queues, which print `(none)`: an empty Sweeps section is the
/// ORDINARY result of every render but one. A FAILED sweep with nothing to keep still draws its
/// header, because a clean fleet and a fleet nobody could look at must not draw the same blank.
///
/// History is the one section that does NOT follow that rule: a first failure draws no section at
/// all, because a machine that has never run the fleet has no transitions log and the script
/// exiting 1 there is the ordinary state rather than news.
pub fn work_body(app: &App, now: DateTime<Utc>) -> Vec<WorkBodyLine<'_>> {
    let mut body = Vec::new();
    body.extend(sweeps_body(app));
    body.extend(queues_body(app, now));
    body.extend(history_body(app));
    body
}

fn pane_error<T>(content: &PaneContent<T>) -> Option<String> {
    match content {
        PaneContent::Stale { error, .. } | PaneContent::Unavailable { error, .. } => {
            Some(error.clone())
        }
        PaneContent::Loading | PaneContent::Fresh { .. } => None,
    }
}

fn sweeps_body(app: &App) -> Vec<WorkBodyLine<'static>> {
    let findings = app.work_findings();
    let error = pane_error(&app.sweeps.content);
    if findings.is_empty() && error.is_none() {
        return Vec::new();
    }
    let mut body = vec![WorkBodyLine::SweepHeader { count: findings.len(), error }];
    for (index, judged) in findings.iter().enumerate() {
        body.push(WorkBodyLine::Finding { index, key: judged.finding.key() });
    }
    body.push(WorkBodyLine::Blank);
    body
}

fn queues_body(app: &App, now: DateTime<Utc>) -> Vec<WorkBodyLine<'_>> {
    match &app.work.content {
        PaneContent::Loading => vec![WorkBodyLine::Notice(WorkNotice::Loading)],
        PaneContent::Fresh { value, .. } => sections_body(app, value, now),
        PaneContent::Stale { value, error, .. } => {
            let mut body = vec![
                WorkBodyLine::Notice(WorkNotice::Stale(error.clone())),
                WorkBodyLine::Blank,
            ];
            body.extend(sections_body(app, value, now));
            body.push(WorkBodyLine::Blank);
            body.push(WorkBodyLine::Notice(WorkNotice::StaleFooter));
            body
        }
        PaneContent::Unavailable { error, .. } => vec![
            WorkBodyLine::Notice(WorkNotice::Unavailable(error.clone())),
            WorkBodyLine::Blank,
            WorkBodyLine::Notice(WorkNotice::NoSnapshot),
            WorkBodyLine::Notice(WorkNotice::Retry),
        ],
    }
}

/// The six queues, in the order work moves in read backwards, and in the panel's own spelling.
fn sections_body<'a>(
    app: &App,
    buckets: &'a WorkBuckets,
    now: DateTime<Utc>,
) -> Vec<WorkBodyLine<'a>> {
    let sections: [(&'static str, &'a Vec<Bead>, SectionKind); 6] = [
        ("Claimed", &buckets.claimed, SectionKind::Open),
        ("Planned, unclaimed", &buckets.planned, SectionKind::Open),
        ("Being planned", &buckets.being_planned, SectionKind::Open),
        ("Unplanned", &buckets.unplanned, SectionKind::Open),
        ("Waiting on you", &buckets.paused, SectionKind::Paused),
        ("Merged, unverified", &buckets.merged, SectionKind::Merged),
    ];
    let mut body = Vec::new();
    for (index, (title, beads, kind)) in sections.into_iter().enumerate() {
        if index > 0 {
            body.push(WorkBodyLine::Blank);
        }
        body.extend(section_body(app, title, beads, kind, now));
    }
    body
}

/// One section: its title with the FULL count, then at most `WORK_ROWS_PER_SECTION` rows - or all
/// of them when the navigator has opened it - then what is left.
///
/// A section with nothing hidden is never expandable, so `expanded` naming it changes nothing.
fn section_body<'a>(
    app: &App,
    title: &'static str,
    beads: &'a [Bead],
    kind: SectionKind,
    now: DateTime<Utc>,
) -> Vec<WorkBodyLine<'a>> {
    let sorted = match kind {
        SectionKind::Merged => sorted_by_recency(beads),
        SectionKind::Open | SectionKind::Paused => sorted_by_priority(beads),
    };
    let mut body = vec![WorkBodyLine::SectionHeader { title, count: sorted.len() }];
    if sorted.is_empty() {
        body.push(WorkBodyLine::Empty);
        return body;
    }
    let hidden = sorted.len().saturating_sub(WORK_ROWS_PER_SECTION);
    let expanded = hidden > 0 && app.expanded.contains(title);
    let shown = if expanded { sorted.len() } else { WORK_ROWS_PER_SECTION };
    for bead in sorted.iter().take(shown) {
        let suffix = (kind == SectionKind::Paused).then(|| paused_age(bead, now));
        body.push(WorkBodyLine::Bead { bead, suffix });
    }
    if hidden > 0 {
        body.push(WorkBodyLine::More { section: title, hidden, expanded });
    }
    body
}

/// The History section: one line per agent that is running something right now.
///
/// Nothing at all - no header - when nothing is running, exactly as the Sweeps section does and
/// for the same reason: a section saying `(none)` every five minutes is noise. A failed run keeps
/// the rows it had and names the script in red beside the header; a first failure has nothing to
/// keep and draws no section, which is the ordinary state of a machine that has never run the
/// fleet.
fn history_body(app: &App) -> Vec<WorkBodyLine<'static>> {
    let lines: Vec<(String, bool)> = app
        .history_rows()
        .iter()
        .filter_map(model::history_line)
        .collect();
    if lines.is_empty() {
        return Vec::new();
    }
    let failed = pane_error(&app.history.content).is_some();
    let mut body = vec![
        WorkBodyLine::Blank,
        WorkBodyLine::HistoryHeader { count: lines.len(), failed },
    ];
    for (text, long) in lines {
        body.push(WorkBodyLine::HistoryRow { text, long });
    }
    body
}

pub fn sorted_by_priority(beads: &[Bead]) -> Vec<&Bead> {
    let mut sorted: Vec<&Bead> = beads.iter().collect();
    // A missing priority sorts after P4 rather than before P0: an unranked bead is not urgent.
    sorted.sort_by(|a, b| {
        a.priority
            .unwrap_or(9)
            .cmp(&b.priority.unwrap_or(9))
            .then_with(|| a.id.cmp(&b.id))
    });
    sorted
}

pub fn sorted_by_recency(beads: &[Bead]) -> Vec<&Bead> {
    let mut sorted: Vec<&Bead> = beads.iter().collect();
    // Undated last, and the id breaks every tie: this list is redrawn on a timer, and one that
    // reorders under the navigator's eyes is unreadable.
    sorted.sort_by(|a, b| {
        match (a.updated_at, b.updated_at) {
            (Some(a), Some(b)) => b.cmp(&a),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        }
        .then_with(|| a.id.cmp(&b.id))
    });
    sorted
}

/// How long this bead has been waiting for a person, or an em dash when it never said.
///
/// The one place the empty string `elapsed` returns becomes something the eye can find: a bead
/// parked before the pause sites wrote `metadata.paused_at` has no age, and rendering it as a
/// small number would read as "just now".
pub fn paused_age(bead: &Bead, now: DateTime<Utc>) -> String {
    let age = crate::ui::elapsed(bead.paused_at(), now);
    if age.is_empty() {
        "—".to_string()
    } else {
        age
    }
}

/// Which line of BODY the cursor stands on, or `None` when nothing on screen carries it.
pub fn work_line_of_cursor(body: &[WorkBodyLine], cursor: &WorkCursor) -> Option<usize> {
    body.iter().position(|entry| entry.cursor().as_ref() == Some(cursor))
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
/// `RefreshAll` is "attempt each pane independently", never "all or none": the caller calls each
/// pane's own `begin_*_refresh`, and a `false` from one says nothing about the others. It was
/// `RefreshAll` until cb-kcs.5.1 gave the screen a third reader; the doc above is what it always
/// meant, so this is a rename rather than a third meaning for a word that says "two".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppAction {
    None,
    RefreshFleet,
    RefreshWork,
    /// Re-run the sweeps alone. What `x` asks for once its command has run: a finding acted on
    /// must not stay on screen for up to ten minutes.
    RefreshSweeps,
    RefreshAll,
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
    /// A one-line message shown in the header in place of the refresh/stale span, and cleared by
    /// the next key press. Gold, unless `notice_urgent`.
    pub notice: Option<String>,
    /// Is the notice a FAULT rather than news? Red when it is (cb-kcs.5.2, the navigator's choice
    /// in round one: the pruner is the first thing in this slot that is not something the view
    /// did but something that has stopped working).
    ///
    /// Cleared wherever `notice` is cleared and set by whichever writer put the line there: a
    /// stale colour is a worse lie than a stale line.
    pub notice_urgent: bool,
    /// Each name's last abnormal exit, as of the last frame. Copied from `SessionHost` by the
    /// event loop, never read from it here: `ui::draw` is pure over `App`, and a renderer that
    /// could reach the host could reach a `vt100::Parser` and a child process with it.
    ///
    /// It is deliberately NOT written into `FleetRow::bead`: that field is what an agent's state
    /// file said, and a renderer's convenience must not make it lie to anything else reading a
    /// row.
    pub exits: BTreeMap<String, LastExit>,
    /// The BEAD column of each standby row, as of the last frame. Copied in by the event loop
    /// from `triggers::standby_label`, never computed here: `ui::draw` may not reach a
    /// `TriggerFacts` any more than it may reach a child process, and the label depends on facts
    /// the work reader supplies. The twin of `App::exits`, set the same way, once per iteration.
    pub standby_labels: BTreeMap<String, String>,
    /// The names this view will start again on their trigger. The port of `cerebro--armed`, and
    /// like it, memory only - never a file, never persisted.
    ///
    /// It is on `App` rather than beside the `SessionHost` because `ui::draw` is pure over `&App`
    /// and the standby row is drawn from it. Written in exactly four places, all in `main`: a
    /// launch adds a name, a retire removes one, a confirmed disarm removes one, and the roster's
    /// `standby` declaration adds a set at startup.
    pub armed: BTreeSet<String>,
    /// Names already nudged for the question they are asking now.
    ///
    /// The poll runs every five seconds; without this the line would be typed on every tick,
    /// burying the agent's own output and resetting what it was told. A name leaves the set as
    /// soon as it is no longer `asking`, so its NEXT question is nudgeable again
    /// (`cerebro--nudged`, `emacs/cerebro.el:3879`).
    pub nudged: BTreeSet<String>,
    /// Which widget the keyboard currently acts on. Fleet by default.
    pub focus: PaneFocus,
    /// What this process is allowed to do with the checkout it is drawing (cb-kcs.1).
    ///
    /// Display state only: the lease itself lives in `main.rs`, because binding a listener is not
    /// something a struct the renderer reads should be able to do. The header line is the whole of
    /// its surface - the navigator chose that over an Ownership pane, so that ownership never
    /// takes a row or a Tab stop from Fleet and Work.
    pub supervision: SupervisionMode,
    /// The confirmation the screen is waiting on. While this is `Some`, the header shows its text
    /// in gold and EVERY key is consumed by it: `y` acts, anything else cancels silently and does
    /// nothing else, so `q` at a kill prompt cancels the kill and does not also quit (Q10).
    pub confirm: Option<Prompt>,
    /// The live agents that refused a quit, in fleet order. While this is `Some`, the whole screen
    /// is the refusal pane and ANY key clears it and does nothing else (Q8).
    pub quit_refusal: Option<Vec<String>>,
    pub quit: bool,
    /// The Fleet pane's viewport height from the last frame that was actually drawn.
    ///
    /// A refresh can move the selected row's document line with nothing pressed - a Fresh -> Stale
    /// transition shifts the whole table down by `FLEET_STALE_PREFIX_LINES`, and
    /// `reconcile_selection` can land on a row that is off screen - and following it needs a
    /// viewport. `App` has no geometry of its own, so the loop hands it the last one it drew
    /// (`note_metrics`); before the first frame it is zero, which `follow_selection` floors at one.
    fleet_viewport: usize,
    last_fleet_request: Option<Instant>,
    last_work_request: Option<Instant>,
    /// When the board was last ASKED, in wall-clock terms - for the read whose value the pane
    /// still holds. See `begin_work_refresh`.
    work_requested_at: Option<DateTime<Utc>>,
    /// The in-flight read's request time, until it answers. Promoted into `work_requested_at`
    /// only on SUCCESS, which is `cerebro--beads-read-at`'s own rule
    /// (`emacs/cerebro.el:5588-5596`): a `Stale` pane goes on handing out its last good buckets,
    /// so a request time moved by a read that failed would pair old ids with a young age.
    work_request_pending: Option<DateTime<Utc>>,
    /// What `gh` last said. A third `Pane<T>` rather than a field of its own, because the four
    /// content states ARE the staleness protocol the cadence triggers need - see
    /// `triggers::GhAnswer`. It is never rendered: no widget draws it, and it takes no Tab stop.
    /// `Pane` earns its place here for `finish`'s transitions and its own in-flight slot, not for
    /// its scroll offset.
    pub gh: Pane<GhSnapshot>,
    last_gh_request: Option<Instant>,
    /// What the six sweeps last found, on its own cadence and its own in-flight slot. A
    /// `Pane<T>` for its `finish` transitions above all: a sweep that fails must not destroy
    /// findings still worth reading, and one that answers with nothing must clear them.
    ///
    /// Its `scroll` is unused - the findings are drawn inside the Work pane, which owns the
    /// offset - and that is the price of one pane type rather than two.
    pub sweeps: Pane<Vec<Judged>>,
    last_sweep_request: Option<Instant>,
    /// Which row of the Work pane the cursor stands on: a finding, a bead, or a `+N more` row.
    ///
    /// A name, never an index, for `App::selected`'s reason: the findings are replaced wholesale
    /// every ten minutes and the beads every thirty seconds, and an index would silently come to
    /// mean a different bead or a different destructive command.
    pub work_cursor: Option<WorkCursor>,
    /// Sections the navigator has opened with `Enter`, by title. Survives a work refresh and `g`,
    /// and lives only as long as the process: a rerank of fifteen beads must not be interrupted
    /// by the section shutting under the cursor.
    pub expanded: BTreeSet<&'static str>,
    /// The last priority this view changed, as `(id, the priority it had)`.
    ///
    /// One step, because the case it exists for is a mis-keyed digit and the notice is the only
    /// warning there was. `cerebro--last-priority-change`. Spent only by USING it: it survives a
    /// refresh, a `g` and the bead scrolling out of view, and a later change overwrites it.
    pub last_priority_change: Option<(String, Option<u8>)>,
    /// What `scripts/fleet-history --summary` last said, on its own five-minute cadence and its
    /// own in-flight slot. A `Pane<T>` for `finish`'s transitions above all: a failed run must not
    /// destroy rows still worth reading, and the header names the script in red while it holds
    /// them.
    ///
    /// Its `scroll` is unused - History is drawn inside the Work pane, which owns the offset -
    /// and that is the price of one pane type rather than two.
    pub history: Pane<Vec<HistoryRow>>,
    last_history_request: Option<Instant>,
}

/// A question the screen is waiting on. `k` is the only key that asks (the navigator's choice),
/// and it asks two different questions: a live session is killed, a standby row is disarmed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Prompt {
    /// The agent to kill, and the gold line `lifecycle::kill_prompt` already built.
    Kill { name: String, text: String },
    /// The agent to disarm, and the gold line already built by `lifecycle::disarm_prompt`.
    Disarm { name: String, text: String },
    /// The sweep finding to act on, and the gold line `sweeps::prompt` built for it. The one
    /// prompt that is not about a session: it writes to the shared board, which is deliberately
    /// outside the supervision lease.
    Sweep { finding: Finding, text: String },
}

impl Prompt {
    /// The gold line the header draws for whichever prompt is up.
    ///
    /// A method rather than a `match` in the renderer, and that is the whole of cb-4cn: `ui.rs`
    /// rendered `Prompt::Kill` by name, so cb-kcs.4.1's disarm confirmation was built and never
    /// drawn - a destructive question the navigator could not see, answered by their next
    /// keystroke. A fourth variant cannot repeat it.
    pub fn text(&self) -> &str {
        match self {
            Self::Kill { text, .. } | Self::Disarm { text, .. } | Self::Sweep { text, .. } => text,
        }
    }
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
            notice_urgent: false,
            exits: BTreeMap::new(),
            standby_labels: BTreeMap::new(),
            armed: BTreeSet::new(),
            nudged: BTreeSet::new(),
            focus: PaneFocus::default(),
            supervision,
            confirm: None,
            quit_refusal: None,
            quit: false,
            fleet_viewport: 0,
            last_fleet_request: None,
            last_work_request: None,
            work_requested_at: None,
            work_request_pending: None,
            gh: Pane::default(),
            last_gh_request: None,
            sweeps: Pane::default(),
            last_sweep_request: None,
            work_cursor: None,
            expanded: BTreeSet::new(),
            last_priority_change: None,
            history: Pane::default(),
            last_history_request: None,
        }
    }

    /// Replace the ownership this view reports. Display state, and nothing else: the lease is the
    /// controller's, and this cannot bind, release or write anything.
    pub fn set_supervision(&mut self, supervision: SupervisionMode) {
        self.supervision = supervision;
    }

    /// Refuse a quit over LIVE agents: show the pane, and undo the `quit` flag `on_key` set.
    pub fn refuse_quit(&mut self, live: Vec<String>) {
        self.quit = false;
        self.quit_refusal = Some(live);
    }

    /// Replace the standby conditions. One call per loop iteration, beside `set_exits`.
    pub fn set_standby_labels(&mut self, labels: BTreeMap<String, String>) {
        self.standby_labels = labels;
    }

    /// The rows the fleet pane last read, or an empty slice. What `main` walks to supervise, to
    /// start, and to note who was seen up.
    pub fn fleet_rows(&self) -> &[FleetRow] {
        self.fleet.content.value().map(Vec::as_slice).unwrap_or(&[])
    }

    /// The names whose recorded exit keeps their row `Dead` rather than restating it as
    /// `Standby` (`cerebro--failed-names`), which asks whether the record has anything to SAY
    /// rather than whether one exists:
    ///
    ///     LastExit::Refused        -> parked. The launcher said why, and it will not say
    ///                                anything different in thirty seconds.
    ///     LastExit::GaveUp { .. }  -> parked. Nothing is coming; `s` is the way back.
    ///     LastExit::Code(_)        -> NOT parked. A session that died - the machine slept, the
    ///                                process was killed from outside, the agent crashed - is
    ///                                promised a retry on the backoff, so its row stays `Standby`
    ///                                (cb-ccl).
    ///
    /// cb-kcs.4.1 passed the whole key set of `exits` to `apply_standby`, which parked every
    /// failure, because there was no backoff yet and a silently crashing agent would have been
    /// relaunched every five seconds. This REPLACES that: two answers to one question is how a
    /// row and a decision come to disagree.
    pub fn parked_names(&self) -> BTreeSet<String> {
        self.exits
            .iter()
            .filter(|(_, exit)| !matches!(exit, LastExit::Code(_)))
            .map(|(name, _)| name.clone())
            .collect()
    }

    /// Re-run `model::apply_standby` over the rows the fleet pane already holds, with `armed` and
    /// `parked_names` as they are NOW.
    ///
    /// `finish_refresh` applies standby when rows arrive, so a row that stops being armed between
    /// two fleet reads would otherwise keep a blue dotted circle for up to five seconds - and the
    /// one thing this must never draw is a row promising a retry the view has just decided
    /// against. `route_key`'s confirmed disarm solves the same problem with `AppAction::
    /// RefreshFleet`; giving up happens inside the loop, where no key is being routed and no
    /// refresh can be asked for.
    ///
    /// It never changes freshness, `read_at` or the error - it is not a refresh and must not be
    /// mistaken for one.
    pub fn reapply_standby(&mut self) {
        let parked = self.parked_names();
        let armed = self.armed.clone();
        let restate = |rows: Vec<FleetRow>| model::apply_standby(rows, &armed, &parked);
        match std::mem::replace(&mut self.fleet.content, PaneContent::Loading) {
            PaneContent::Fresh { value, read_at } => {
                self.fleet.content = PaneContent::Fresh { value: restate(value), read_at };
            }
            PaneContent::Stale { value, read_at, failed_at, error } => {
                self.fleet.content =
                    PaneContent::Stale { value: restate(value), read_at, failed_at, error };
            }
            other => self.fleet.content = other,
        }
    }

    /// Replace the verdicts. One call per loop iteration, beside `set_session_view`.
    pub fn set_exits(&mut self, exits: BTreeMap<String, LastExit>) {
        self.exits = exits;
    }

    /// Put TEXT in the notice slot. The one writer other than `reconcile_selection`; `on_key`
    /// remains the one place it is cleared.
    pub fn set_notice(&mut self, text: String) {
        self.notice = Some(text);
        self.notice_urgent = false;
    }

    /// Put TEXT in the notice slot, in red: something is broken rather than something happened.
    pub fn set_error_notice(&mut self, text: String) {
        self.notice = Some(text);
        self.notice_urgent = true;
    }

    /// Every roster name, in fleet order, for `SessionHost::live_names` to ORDER its answer by.
    ///
    /// Empty until a fleet read has succeeded, and that is exactly why it may not be the whole of
    /// the answer: `live_names` names every live session and uses this only for the order, so a
    /// child hosted before the first successful read is still named and still refuses a quit. A
    /// caller that treated an empty roster as "nothing is live" would let `q` through and let
    /// `Session::Drop` kill the agents on the way out.
    pub fn roster_order(&self) -> Vec<String> {
        self.fleet
            .content
            .value()
            .map(|rows| rows.iter().map(|row| row.name.clone()).collect())
            .unwrap_or_default()
    }

    /// The selected fleet row, when a successful read has one under that name.
    pub fn selected_row(&self) -> Option<&FleetRow> {
        let name = self.selected.as_deref()?;
        self.fleet.content.value()?.iter().find(|row| row.name == name)
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
            (true, true) => AppAction::RefreshAll,
            (true, false) => AppAction::RefreshFleet,
            (false, true) => AppAction::RefreshWork,
            (false, false) => AppAction::None,
        }
    }

    /// The whole keyboard contract this method owns: focus, scroll, refresh, quit.
    ///
    /// The lifecycle keys are NOT here. `main::route_key` takes `s`, `f` and `k` before this is
    /// reached, and the quit-refusal and kill-confirmation panes consume every key ahead of it, so
    /// by the time a key arrives here it is one of the movement, refresh and quit keys alone. They
    /// cannot travel through this method because `AppAction` is `Copy` and field-less and is
    /// compared with `==` in the loop, so no variant may carry an agent's name.
    ///
    /// `viewport_lines` is what PageUp/PageDown move the focused pane by: that pane's own body
    /// height the last frame actually showed, so a page is a page of what the navigator is
    /// looking at in the widget they are looking at. `App::focused_viewport` is the one place the
    /// at-least-one floor on that number is applied; this method never applies its own.
    /// NOW is threaded in rather than asked of the clock: `work_body` needs one for the `Paused`
    /// suffix, and a key case that called `Utc::now()` would race the wall clock in every test.
    pub fn on_key(
        &mut self,
        key: KeyEvent,
        viewport_lines: usize,
        now: DateTime<Utc>,
    ) -> AppAction {
        // A terminal that reports key releases (Windows, and any terminal with the kitty
        // protocol on) would otherwise scroll twice per keystroke.
        if key.kind == KeyEventKind::Release {
            return AppAction::None;
        }
        // A notice is transient by design: it survives exactly until the navigator touches the
        // keyboard, whatever they press.
        self.notice = None;
        self.notice_urgent = false;
        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.quit = true;
                AppAction::Quit
            }
            KeyCode::Char('q') | KeyCode::Esc => {
                self.quit = true;
                AppAction::Quit
            }
            KeyCode::Char('g') => AppAction::RefreshAll,
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
            // Under Work these four move the CURSOR while there are findings to move over, and
            // that pane's own offset when there are none - which is the ordinary day, and the
            // whole reason `n`/`p` were not ported as keys of their own.
            KeyCode::Up if self.focus == PaneFocus::Work => {
                if !self.move_work_cursor(-1, viewport_lines, now) {
                    let scroll = self.focused_scroll_mut();
                    *scroll = scroll.saturating_sub(1);
                }
                AppAction::None
            }
            KeyCode::Down if self.focus == PaneFocus::Work => {
                if !self.move_work_cursor(1, viewport_lines, now) {
                    let scroll = self.focused_scroll_mut();
                    *scroll = scroll.saturating_add(1);
                }
                AppAction::None
            }
            KeyCode::PageUp if self.focus == PaneFocus::Work => {
                if !self.move_work_cursor(-(viewport_lines as isize), viewport_lines, now) {
                    let scroll = self.focused_scroll_mut();
                    *scroll = scroll.saturating_sub(viewport_lines);
                }
                AppAction::None
            }
            KeyCode::PageDown if self.focus == PaneFocus::Work => {
                if !self.move_work_cursor(viewport_lines as isize, viewport_lines, now) {
                    let scroll = self.focused_scroll_mut();
                    *scroll = scroll.saturating_add(viewport_lines);
                }
                AppAction::None
            }
            // `Enter` opens the section under a `+N more` row, and closes it again. The one way
            // past the eight-row cap, and the only reason a bead in the P4 backlog can be
            // reranked at all.
            KeyCode::Enter if self.focus == PaneFocus::Work => {
                if let Some(WorkCursor::More(section)) = self.work_cursor.clone() {
                    if !self.expanded.remove(section) {
                        self.expanded.insert(section);
                    }
                }
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

    /// Bring DOCUMENT_LINE into the Fleet pane's viewport, by the two rules below: the least
    /// movement that reveals it, except for the snap-to-top that follows.
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

    /// Remember the geometry of the frame just drawn, so a refresh that moves the selected row
    /// can scroll the Fleet pane to it without a keystroke.
    pub fn note_metrics(&mut self, metrics: Metrics) {
        self.fleet_viewport = metrics.fleet.viewport_lines;
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
    ///
    /// `now` is the wall-clock moment the board was ASKED, held pending until the read answers.
    /// The triage guard needs that and not `Pane::read_at`, which is when the answer arrived -
    /// later, so an arrival-based age is smaller and passes the guard in cases the rule refuses
    /// (`cerebro--beads-read-at`'s own reason, `emacs/cerebro.el:5520-5527`). It reaches
    /// `work_requested_at` in `finish_work_refresh`, and only on success.
    pub fn begin_work_refresh(&mut self, at: Instant, now: DateTime<Utc>) -> bool {
        if self.work.begin() {
            self.last_work_request = Some(at);
            self.work_request_pending = Some(now);
            true
        } else {
            false
        }
    }

    /// Whether the sweeps are due at NOW. Kept off `on_tick`'s `AppAction` for `gh_due`'s
    /// reason: the enum is what the navigator's two panes need, and the sweeps have their own
    /// ten-minute clock that no keystroke schedules.
    pub fn sweep_due(&self, now: Instant) -> bool {
        match self.last_sweep_request {
            None => true,
            Some(last) => now.duration_since(last) >= SWEEP_REFRESH_INTERVAL,
        }
    }

    /// Claim the sweeps' in-flight slot and stamp the request. Its own slot, deliberately: a
    /// two-minute sweep chain behind a five-second fleet read is the one thing independent panes
    /// must not do.
    pub fn begin_sweep_refresh(&mut self, at: Instant) -> bool {
        if self.sweeps.begin() {
            self.last_sweep_request = Some(at);
            true
        } else {
            false
        }
    }

    /// The sweeps pane's content transition; see `Pane::finish` for the whole rule. It touches
    /// that pane and nothing else, and it reconciles the cursor against what came back.
    pub fn finish_sweep_refresh(&mut self, result: Result<Vec<Judged>, ReadError>, at: DateTime<Utc>) {
        let previous_index = self.work_cursor_index(at);
        let succeeded = result.is_ok();
        self.sweeps.finish(result, at);
        if succeeded {
            self.reconcile_work_cursor(previous_index, at);
        }
    }

    /// Whether History is due at NOW. Its own clock, for `sweep_due`'s reason: a five-minute
    /// reader that no keystroke schedules has no business on the five-second tick.
    pub fn history_due(&self, now: Instant) -> bool {
        match self.last_history_request {
            None => true,
            Some(last) => now.duration_since(last) >= HISTORY_REFRESH_INTERVAL,
        }
    }

    /// Claim History's in-flight slot and stamp the request. Its own slot, deliberately.
    pub fn begin_history_refresh(&mut self, at: Instant) -> bool {
        if self.history.begin() {
            self.last_history_request = Some(at);
            true
        } else {
            false
        }
    }

    /// History's content transition; see `Pane::finish` for the whole rule. It touches that pane
    /// and nothing else.
    pub fn finish_history_refresh(
        &mut self,
        result: Result<Vec<HistoryRow>, ReadError>,
        at: DateTime<Utc>,
    ) {
        let previous_index = self.work_cursor_index(at);
        let succeeded = result.is_ok();
        self.history.finish(result, at);
        if succeeded {
            self.reconcile_work_cursor(previous_index, at);
        }
    }

    /// The History rows the Work pane is currently showing, `Fresh` and `Stale` alike; empty
    /// otherwise.
    pub fn history_rows(&self) -> &[HistoryRow] {
        self.history.content.value().map(Vec::as_slice).unwrap_or(&[])
    }

    /// The findings the Work pane is currently showing, `Fresh` and `Stale` alike; empty
    /// otherwise. One accessor, so the cursor, the renderer and `x` cannot disagree about what is
    /// on screen.
    pub fn work_findings(&self) -> &[Judged] {
        self.sweeps.content.value().map(Vec::as_slice).unwrap_or(&[])
    }

    /// The document's selectable rows, in order: findings, bead rows and `+N more` rows.
    fn work_cursor_targets(&self, now: DateTime<Utc>) -> Vec<WorkCursor> {
        work_body(self, now)
            .iter()
            .filter_map(WorkBodyLine::cursor)
            .collect()
    }

    /// Where the cursor is among the document's selectable rows, if it is still one of them.
    pub fn work_cursor_index(&self, now: DateTime<Utc>) -> Option<usize> {
        let cursor = self.work_cursor.as_ref()?;
        self.work_cursor_targets(now).iter().position(|target| target == cursor)
    }

    /// The finding under the cursor, if the cursor is on one. What `x` acts on.
    pub fn selected_finding(&self) -> Option<&Judged> {
        let WorkCursor::Finding(key) = self.work_cursor.as_ref()? else {
            return None;
        };
        self.work_findings().iter().find(|judged| judged.finding.key() == *key)
    }

    /// The bead under the cursor, if the cursor is on one. What the priority keys act on.
    pub fn selected_bead(&self, now: DateTime<Utc>) -> Option<&Bead> {
        let WorkCursor::Bead(id) = self.work_cursor.as_ref()? else {
            return None;
        };
        work_body(self, now).into_iter().find_map(|line| match line {
            WorkBodyLine::Bead { bead, .. } if bead.id == *id => Some(bead),
            _ => None,
        })
    }

    /// Put the cursor back on something after a refresh that changed the document.
    ///
    /// A cursor whose row is gone takes the selectable row at its old index, clamped, and `None`
    /// when there is nothing selectable at all - and the FIRST row when there was no cursor and
    /// there now is one, which is what gives the navigator a grey row on the first frame with no
    /// separate code path.
    ///
    /// Unlike the fleet's selection it sets NO notice: a roster shrinking under the navigator is
    /// news, whereas this cursor is where they last happened to be. What guards them from acting
    /// on the wrong thing is the confirmation, which always names the command.
    fn reconcile_work_cursor(&mut self, previous_index: Option<usize>, now: DateTime<Utc>) {
        let targets = self.work_cursor_targets(now);
        if targets.is_empty() {
            self.work_cursor = None;
            return;
        }
        if self.work_cursor_index(now).is_some() {
            return;
        }
        let index = previous_index.unwrap_or(0).min(targets.len() - 1);
        self.work_cursor = Some(targets[index].clone());
    }

    /// Move the cursor by DELTA rows, saturating at both ends, and scroll the Work pane by the
    /// least that keeps the new line visible.
    ///
    /// Returns whether the cursor actually moved. FALSE means there was nothing selectable, or it
    /// was already at that end - and in both cases `on_key` scrolls the pane instead, which is
    /// what keeps the lines BELOW the last selectable row reachable at all: History and the stale
    /// footer carry no cursor by the navigator's own choice, so a cursor clamped at the last bead
    /// row would otherwise put the whole History section under a floor the pane could never
    /// scroll past.
    fn move_work_cursor(&mut self, delta: isize, viewport_lines: usize, now: DateTime<Utc>) -> bool {
        let targets = self.work_cursor_targets(now);
        if targets.is_empty() {
            return false;
        }
        // No cursor, or one naming a row that has gone - a section collapsed under it, a finding
        // acted on: seat it on the first row rather than treating it as index 0, which would make
        // an `Up` on a stale cursor look like a cursor already at the top and leave it stale for
        // ever.
        let Some(current) = self.work_cursor_index(now) else {
            self.place_work_cursor(targets[0].clone(), viewport_lines, now);
            return true;
        };
        let last = targets.len() - 1;
        let target = (current as isize).saturating_add(delta).clamp(0, last as isize) as usize;
        if target == current {
            return false;
        }
        self.place_work_cursor(targets[target].clone(), viewport_lines, now);
        true
    }

    /// Put the cursor on CURSOR and scroll the Work pane by the least that keeps its line visible,
    /// in both directions: a move onto a row already on screen leaves the pane exactly where it
    /// was, and one onto a row near the top of the document does not snap the pane to the top.
    fn place_work_cursor(
        &mut self,
        cursor: WorkCursor,
        viewport_lines: usize,
        now: DateTime<Utc>,
    ) {
        self.work_cursor = Some(cursor.clone());
        let line = work_line_of_cursor(&work_body(self, now), &cursor);
        if let Some(line) = line {
            let viewport = viewport_lines.max(1);
            if line < self.work.scroll {
                self.work.scroll = line;
            } else if line >= self.work.scroll + viewport {
                self.work.scroll = line + 1 - viewport;
            }
        }
    }

    /// Whether a `gh` read is due at NOW. Kept off `on_tick`'s `AppAction` deliberately: that
    /// enum is a closed vocabulary of what the navigator's two panes need, and a third
    /// refreshable thing nobody draws would take it from five variants to eight.
    pub fn gh_due(&self, now: Instant) -> bool {
        match self.last_gh_request {
            None => true,
            Some(last) => now.duration_since(last) >= GH_REFRESH_INTERVAL,
        }
    }

    /// Claim the `gh` pane's in-flight slot and stamp the request. The twin of
    /// `begin_work_refresh`, on its own slot and its own clock.
    pub fn begin_gh_refresh(&mut self, at: Instant) -> bool {
        if self.gh.begin() {
            self.last_gh_request = Some(at);
            true
        } else {
            false
        }
    }

    /// The `gh` pane's content transition. It touches that pane and nothing else.
    pub fn finish_gh_refresh(&mut self, result: Result<GhSnapshot, ReadError>, at: DateTime<Utc>) {
        self.gh.finish(result, at);
    }

    /// The pane's content as a trigger reads it. See `triggers::GhAnswer` for the mapping, and
    /// why `Stale` - a value, and a newer failure - is `Failed` rather than `Answered`.
    pub fn gh_answer(&self) -> GhAnswer {
        match &self.gh.content {
            PaneContent::Loading => GhAnswer::Unanswered,
            PaneContent::Fresh { value, .. } => GhAnswer::Answered(value.clone()),
            PaneContent::Stale { .. } | PaneContent::Unavailable { .. } => GhAnswer::Failed,
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
                self.set_notice(format!("{lost} is no longer on the roster. Selected {new}."));
                self.selected = Some(new);
            }
            None => {
                self.selected = None;
                self.set_notice(format!("{lost} is no longer on the roster."));
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
        // Applied on the way past, on success only, so the rows the pane holds are the rows any
        // reader inspects and a new caller cannot forget the transformation.
        let parked = self.parked_names();
        let result = result.map(|rows| model::apply_standby(rows, &self.armed, &parked));
        self.fleet.finish(result, at);
        if succeeded {
            self.reconcile_selection(previous_index);
            // A refresh can move the selected row's document line with nothing pressed: the stale
            // prefix appearing or going, and a reconciled selection landing on another row. Both
            // used to self-correct only on the next arrow press, which left the selection below
            // the fold in the meantime (cb-kcs.2.1's review, round 4).
            self.follow_current_selection();
        }
    }

    /// Scroll the Fleet pane to wherever the selection now sits, using the last drawn frame's
    /// viewport. Does nothing without rows or a selection.
    fn follow_current_selection(&mut self) {
        // Before the first frame there is no viewport to follow into, and guessing one would
        // scroll the heading off a pane nobody has drawn yet.
        if self.fleet_viewport == 0 {
            return;
        }
        let Some(index) = self.selected_index() else { return };
        // `fleet_body` already carries the stale prefix and every diagnostic line, so this asks
        // it rather than re-deriving an offset that would then have two owners (cb-0ps).
        let body = fleet_body(&self.fleet.content);
        let Some(line) = body_line_of_row(&body, index) else { return };
        self.follow_selection(line, self.fleet_viewport);
    }

    /// When the board was last ASKED, for the read whose value the pane still holds, or `None`
    /// before one has answered.
    pub fn work_requested_at(&self) -> Option<DateTime<Utc>> {
        self.work_requested_at
    }

    /// The work pane's content transition. It touches the work pane and nothing else: a `bd` that
    /// cannot answer must not make the fleet rows beside it look stale.
    pub fn finish_work_refresh(
        &mut self,
        result: Result<WorkBuckets, ReadError>,
        at: DateTime<Utc>,
    ) {
        // The request time is promoted WITH the value and never ahead of it: a failed read leaves
        // `work_requested_at` pointing at the request that produced the buckets still held, so
        // the triage guard can never measure old ids against a young age.
        if result.is_ok() {
            self.work_requested_at = self.work_request_pending;
        }
        self.work_request_pending = None;
        let previous_index = self.work_cursor_index(at);
        let succeeded = result.is_ok();
        self.work.finish(result, at);
        // Every refresh that changes the document reconciles the cursor, not the sweeps alone:
        // the beads are replaced every thirty seconds and the cursor now walks them.
        if succeeded {
            self.reconcile_work_cursor(previous_index, at);
        }
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
    /// `FnMut`, not `Fn`: the `gh` reader keeps the login it has learnt between requests, and the
    /// loop below calls it from one thread only. A `RefCell` in the closure instead would be
    /// interior mutability bought to preserve a bound nothing needed.
    fn spawn_reader(mut reader: impl FnMut() -> Result<T, ReadError> + Send + 'static) -> Self {
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
    pub fn spawn(paths: ReaderPaths, programs: Programs, commands: Commands) -> Self {
        Self::spawn_reader(move || read_fleet(&paths, &programs, commands.as_ref()))
    }
}

impl Worker<WorkBuckets> {
    pub fn spawn(paths: ReaderPaths, programs: Programs, commands: Commands) -> Self {
        Self::spawn_reader(move || read_work(&paths, &programs, commands.as_ref()))
    }
}

/// The sweeps' worker: `read_sweeps` on its own thread.
///
/// A fifth thread rather than a call on the UI thread, for the reason the others exist: it is six
/// subprocesses, three of which fetch from origin, and a slow network would otherwise freeze the
/// screen - keys and all - for as long as the thing that went wrong.
pub type SweepWorker = Worker<Vec<Judged>>;

impl Worker<Vec<Judged>> {
    pub fn spawn(paths: ReaderPaths, programs: Programs, commands: Commands) -> Self {
        Self::spawn_reader(move || read_sweeps(&paths, &programs, commands.as_ref()))
    }
}

/// History's worker: `read_history` on its own thread.
///
/// A sixth thread rather than a call on the UI thread, for the reason the others exist: it is a
/// `jq` walk over a log that grows without limit, and a slow one would otherwise freeze the
/// screen - keys and all - for as long as it took.
pub type HistoryWorker = Worker<Vec<HistoryRow>>;

impl Worker<Vec<HistoryRow>> {
    pub fn spawn(paths: ReaderPaths, commands: Commands) -> Self {
        Self::spawn_reader(move || read_history(&paths, commands.as_ref()))
    }
}

/// The GitHub reader's worker: `read_gh` on its own thread (`readers::read_gh`).
///
/// A fourth thread rather than a call on the UI thread, for the reason the other three exist: it
/// is three network calls, and a rate-limited `gh` would otherwise freeze the screen - keys and
/// all - for as long as the thing that went wrong.
pub type GhWorker = Worker<GhSnapshot>;

impl Worker<GhSnapshot> {
    /// The learnt login lives in the closure, so it survives between requests and is asked for
    /// only until it answers - which is why the reader bound is `FnMut`.
    pub fn spawn(paths: ReaderPaths, programs: Programs, commands: Commands) -> Self {
        let mut me: Option<String> = None;
        Self::spawn_reader(move || read_gh(&paths, &programs, &mut me, commands.as_ref()))
    }
}

impl Worker<Result<SupervisorKind, String>> {
    pub fn spawn(paths: ReaderPaths, commands: Commands) -> Self {
        Self::spawn_reader(move || read_configured_supervisor(&paths, commands.as_ref()))
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

    // --- the sweeps pane, its cadence, and the Work cursor (cb-kcs.5.1) ---------------------

    fn judged(action_id: &str) -> Judged {
        let finding = match action_id {
            "unclaim" => Finding::Unclaim { id: "cb-a".into() },
            "reclaim" => Finding::Reclaim { id: "cb-b".into() },
            "epic" => Finding::EpicClose { id: "cb-c".into() },
            other => panic!("no such fixture {other}"),
        };
        Judged { label: format!("{} — a line", finding.key()), finding }
    }

    fn sweep_error() -> ReadError {
        ReadError::Sweep { script: "sweep-claims".into(), cause: "bd exited 1".into() }
    }

    /// A failed refresh never destroys findings still worth reading - the pane rule, over the
    /// third reader. Three scripts of six `git fetch`, so this is ordinary rather than rare.
    #[test]
    fn a_failed_sweep_keeps_the_findings_it_had() {
        let mut app = App::default();
        app.finish_sweep_refresh(Ok(vec![judged("unclaim")]), at(0));
        app.finish_sweep_refresh(Err(sweep_error()), at(5));
        assert_eq!(app.work_findings().len(), 1);
        assert!(matches!(
            &app.sweeps.content,
            PaneContent::Stale { error, .. } if error == "sweep-claims failed"
        ));
    }

    /// And a first failure has nothing to keep: the header still says `Sweeps 0`, with the
    /// reason, because a clean fleet and a fleet nobody could look at must not draw one blank.
    #[test]
    fn a_failed_first_sweep_has_no_findings_and_an_error() {
        let mut app = App::default();
        app.finish_sweep_refresh(Err(sweep_error()), at(0));
        assert!(app.work_findings().is_empty());
        assert_eq!(
            &work_body(&app, at(0))[..2],
            &[
                WorkBodyLine::SweepHeader { count: 0, error: Some("sweep-claims failed".into()) },
                WorkBodyLine::Blank,
            ]
        );
    }

    /// A success replaces value and error together, so a genuinely empty answer clears both the
    /// findings and the section.
    #[test]
    fn an_empty_answer_clears_the_section() {
        let mut app = App::default();
        app.finish_sweep_refresh(Err(sweep_error()), at(0));
        app.finish_sweep_refresh(Ok(Vec::new()), at(5));
        // No Sweeps section at all: the document opens with the queues' own state.
        assert_eq!(
            work_body(&app, at(0)).first(),
            Some(&WorkBodyLine::Notice(WorkNotice::Loading))
        );
        assert_eq!(app.work_cursor, None);
    }

    /// The sweeps have their own in-flight slot and their own clock: a two-minute chain behind a
    /// five-second fleet read is the one thing independent panes must not do.
    #[test]
    fn the_sweep_cadence_is_its_own() {
        let mut app = App::default();
        let start = Instant::now();
        assert!(app.sweep_due(start), "nothing has been asked yet");
        assert!(app.begin_sweep_refresh(start));
        assert!(!app.begin_sweep_refresh(start), "one at a time");
        // A work read in flight says nothing about the sweeps, and the reverse.
        assert!(app.begin_work_refresh(start, Utc::now()));
        assert!(app.begin_refresh(start));
        app.finish_sweep_refresh(Ok(Vec::new()), at(0));
        assert!(!app.sweep_due(start + Duration::from_secs(599)));
        assert!(app.sweep_due(start + SWEEP_REFRESH_INTERVAL));
    }

    /// Under Work the arrows move the cursor while findings exist, and the pane follows it.
    #[test]
    fn the_work_cursor_moves_over_findings_only() {
        let mut app = App::default();
        app.focus = PaneFocus::Work;
        app.finish_sweep_refresh(
            Ok(vec![judged("unclaim"), judged("reclaim"), judged("epic")]),
            at(0),
        );
        // The first successful read puts the cursor on the first finding, silently.
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("unclaim:cb-a".into())));
        app.on_key(key(KeyCode::Down), 10, at(0));
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("reclaim:cb-b".into())));
        assert_eq!(app.selected_finding().map(|j| j.finding.key()).as_deref(), Some("reclaim:cb-b"));
        // Saturating at both ends, exactly as the fleet selection is.
        app.on_key(key(KeyCode::PageDown), 10, at(0));
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("epic-close:cb-c".into())));
        app.on_key(key(KeyCode::PageUp), 10, at(0));
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("unclaim:cb-a".into())));
        // And nothing scrolled: three findings fit a ten-line viewport.
        assert_eq!(app.work.scroll, 0);
    }

    /// On the ordinary day there are no findings at all, and the pane behaves exactly as it did
    /// before this bead - which is why `n`/`p` were not ported as keys of their own.
    #[test]
    fn the_work_cursor_scrolls_when_there_are_no_findings() {
        let mut app = App::default();
        app.focus = PaneFocus::Work;
        app.finish_sweep_refresh(Ok(Vec::new()), at(0));
        app.on_key(key(KeyCode::Down), 10, at(0));
        assert_eq!(app.work.scroll, 1);
        assert_eq!(app.work_cursor, None);
    }

    /// A cursor whose finding is gone takes the row at its old index, clamped - and says nothing.
    /// The findings are replaced every ten minutes and after every `x`; a gold line on each of
    /// those is the noise this section is careful about, and the confirmation is what guards the
    /// navigator from acting on the wrong thing.
    #[test]
    fn a_cursor_whose_finding_is_gone_takes_the_row_at_its_index_and_sets_no_notice() {
        let mut app = App::default();
        app.finish_sweep_refresh(
            Ok(vec![judged("unclaim"), judged("reclaim"), judged("epic")]),
            at(0),
        );
        app.focus = PaneFocus::Work;
        app.on_key(key(KeyCode::Down), 10, at(0));
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("reclaim:cb-b".into())));
        // The middle finding is acted on and gone; index 1 is now the third.
        app.finish_sweep_refresh(Ok(vec![judged("unclaim"), judged("epic")]), at(10));
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("epic-close:cb-c".into())));
        assert_eq!(app.notice, None);
        // Past the end, it clamps to the last.
        app.finish_sweep_refresh(Ok(vec![judged("unclaim")]), at(20));
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("unclaim:cb-a".into())));
        assert_eq!(app.notice, None);
    }

    /// A FAILED read never moves the cursor: a two-minute chain that timed out is not a finding
    /// being resolved.
    #[test]
    fn a_failed_sweep_leaves_the_cursor_alone() {
        let mut app = App::default();
        app.finish_sweep_refresh(Ok(vec![judged("unclaim"), judged("reclaim")]), at(0));
        app.focus = PaneFocus::Work;
        app.on_key(key(KeyCode::Down), 10, at(0));
        app.finish_sweep_refresh(Err(sweep_error()), at(5));
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("reclaim:cb-b".into())));
    }

    /// The findings are the first lines of the Work document, so a finding's line depends on the
    /// sweeps alone - which is what lets the cursor place one without building a frame.
    #[test]
    fn a_findings_line_is_known_without_a_frame() {
        let mut app = App::default();
        app.finish_sweep_refresh(Ok(vec![judged("unclaim"), judged("reclaim")]), at(0));
        let body = work_body(&app, at(0));
        assert_eq!(
            &body[..4],
            &[
                WorkBodyLine::SweepHeader { count: 2, error: None },
                WorkBodyLine::Finding { index: 0, key: "unclaim:cb-a".into() },
                WorkBodyLine::Finding { index: 1, key: "reclaim:cb-b".into() },
                WorkBodyLine::Blank,
            ]
        );
        let line = |key: &str| {
            work_line_of_cursor(&body, &WorkCursor::Finding(key.to_string()))
        };
        assert_eq!(line("unclaim:cb-a"), Some(1));
        assert_eq!(line("reclaim:cb-b"), Some(2));
        assert_eq!(line("epic-close:cb-z"), None);
    }

    /// A pane with many findings scrolls to follow the cursor down, by the least that reveals it.
    #[test]
    fn the_work_pane_follows_its_cursor() {
        let mut app = App::default();
        let many: Vec<Judged> = (0..20)
            .map(|n| {
                let finding = Finding::Unclaim { id: format!("cb-{n:02}") };
                Judged { label: finding.key(), finding }
            })
            .collect();
        app.finish_sweep_refresh(Ok(many), at(0));
        app.focus = PaneFocus::Work;
        for _ in 0..10 {
            app.on_key(key(KeyCode::Down), 5, at(0));
        }
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("unclaim:cb-10".into())));
        // Line 11 of the body (header, then ten findings above it), in a five-line viewport.
        assert_eq!(app.work.scroll, 7);
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


    /// Two paths move the selected row's document line with nothing pressed: the stale prefix
    /// appearing (or going), and a reconciled selection landing on a row further down. Both used
    /// to leave the selection below the fold until the next arrow press (cb-kcs.2.1's review).
    #[test]
    fn a_refresh_scrolls_the_fleet_back_to_the_selected_row() {
        let rows: Vec<FleetRow> = (0..12)
            .map(|i| row(&format!("A{i:02}")))
            .collect();
        let mut app = App::new();
        app.note_metrics(Metrics {
            fleet: PaneMetrics { content_lines: 13, viewport_lines: 4, inner_width: 38 },
            work: PaneMetrics { content_lines: 0, viewport_lines: 4, inner_width: 38 },
            session: PaneMetrics { content_lines: 0, viewport_lines: 4, inner_width: 58 },
        });
        app.finish_refresh(Ok(rows.clone()), Utc::now());
        app.selected = Some("A08".to_string());
        app.fleet.scroll = 6;

        // A failed read makes the pane stale, which pushes the whole table down by the retained
        // error and its blank line - and a failure must not move the selection at all.
        app.finish_refresh(Err(failure()), Utc::now());
        assert_eq!(app.selected.as_deref(), Some("A08"));
        // The next successful read re-follows: A08 is document line 9, plus nothing (fresh again).
        app.finish_refresh(Ok(rows.clone()), Utc::now());
        assert!(
            app.fleet.scroll <= 9 && 9 < app.fleet.scroll + 4,
            "the selected row is inside the viewport again, scroll was {}",
            app.fleet.scroll
        );

        // And a selection that leaves the roster: the replacement is scrolled to as well.
        let shorter: Vec<FleetRow> = rows.iter().take(9).cloned().collect();
        app.fleet.scroll = 0;
        app.finish_refresh(Ok(shorter), Utc::now());
        assert_eq!(app.selected.as_deref(), Some("A08"), "the row at the old index, clamped");
        assert!(app.fleet.scroll > 0, "and the pane scrolled to it: {}", app.fleet.scroll);
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
                    external_ref: None,
                })
                .collect(),
            ..WorkBuckets::default()
        }
    }

    /// What `main` does with a `RefreshAll`, followed by both answers arriving: the request time
    /// is recorded and neither slot is left in flight.
    fn started_both(app: &mut App, when: Instant) {
        start_fleet(app, when);
        assert!(app.begin_work_refresh(when, Utc::now()), "the work slot was free");
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
        assert_eq!(app.on_tick(start), AppAction::RefreshAll);
        assert!(app.begin_refresh(start));
        assert!(app.begin_work_refresh(start, Utc::now()));
        // No second request on the very next tick: both reads are in flight and neither interval
        // has passed.
        assert_eq!(app.on_tick(start + Duration::from_millis(1)), AppAction::None);
    }

    #[test]
    fn fleet_refresh_is_due_every_five_seconds() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshAll);
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
        assert_eq!(app.on_tick(start), AppAction::RefreshAll);
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
        assert_eq!(app.on_tick(at + Duration::from_secs(30)), AppAction::RefreshAll);
    }

    /// Each pane counts from its own last *start*, so a work read that took twenty seconds does
    /// not push the fleet's five-second cadence out, and a refused duplicate moves neither.
    #[test]
    fn fleet_and_work_cadences_are_independent() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_tick(start), AppAction::RefreshAll);
        assert!(app.begin_refresh(start));
        assert!(app.begin_work_refresh(start, Utc::now()));
        // The fleet answers; the work read is still running.
        app.finish_refresh(Ok(vec![row("Xavier")]), at(0));

        // A work read still in flight at 30s: the tick still says so, and the refusal leaves the
        // work clock where it was rather than postponing it by another thirty seconds.
        let due = start + Duration::from_secs(30);
        assert_eq!(app.on_tick(due), AppAction::RefreshAll);
        assert!(app.begin_refresh(due));
        assert!(!app.begin_work_refresh(due, Utc::now()), "the work read is still running");
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
        assert!(app.begin_work_refresh(start, Utc::now()));
        assert!(app.work.refreshing);
        assert!(!app.begin_work_refresh(start, Utc::now()), "a second work request is dropped");
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
        app.begin_work_refresh(Instant::now(), Utc::now());
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
        assert_eq!(app.on_key(key(KeyCode::Down), 10, at(0)), AppAction::None);
        assert_eq!(app.work.scroll, 1);
        assert_eq!(app.on_key(key(KeyCode::Down), 10, at(0)), AppAction::None);
        assert_eq!(app.work.scroll, 2);
        app.on_key(key(KeyCode::Up), 10, at(0));
        assert_eq!(app.work.scroll, 1);

        // The top is a floor, never a negative offset.
        app.on_key(key(KeyCode::Up), 10, at(0));
        app.on_key(key(KeyCode::Up), 10, at(0));
        assert_eq!(app.work.scroll, 0);

        app.on_key(key(KeyCode::PageDown), 10, at(0));
        assert_eq!(app.work.scroll, 10, "a page is the viewport the frame just showed");
        app.on_key(key(KeyCode::PageDown), 7, at(0));
        assert_eq!(app.work.scroll, 17);
        app.on_key(key(KeyCode::PageUp), 7, at(0));
        assert_eq!(app.work.scroll, 10);
        app.on_key(key(KeyCode::PageUp), 100, at(0));
        assert_eq!(app.work.scroll, 0);

        // A key release is the same keystroke reported twice; it moves nothing.
        let mut release = key(KeyCode::Down);
        release.kind = KeyEventKind::Release;
        assert_eq!(app.on_key(release, 10, at(0)), AppAction::None);
        assert_eq!(app.work.scroll, 0);
    }

    #[test]
    fn tab_cycles_fleet_work_session_and_backtab_reverses() {
        let mut app = App::new();
        assert_eq!(app.focus, PaneFocus::Fleet, "Fleet is focused on startup");

        for expected in [PaneFocus::Work, PaneFocus::Session, PaneFocus::Fleet, PaneFocus::Work] {
            assert_eq!(app.on_key(key(KeyCode::Tab), 10, at(0)), AppAction::None);
            assert_eq!(app.focus, expected);
        }

        // Shift-Tab is the reverse of that cycle, not the same toggle.
        let mut app = App::new();
        for expected in [PaneFocus::Session, PaneFocus::Work, PaneFocus::Fleet, PaneFocus::Session] {
            assert_eq!(app.on_key(key(KeyCode::BackTab), 10, at(0)), AppAction::None);
            assert_eq!(app.focus, expected);
        }
    }

    /// Arrow and page keys act on the focused pane alone; the boundary clamps within it and never
    /// transfers focus. Under Fleet they move the SELECTION, not that pane's raw offset.
    #[test]
    fn scroll_keys_move_only_the_focused_pane() {
        let mut app = App::new();
        app.on_key(key(KeyCode::Tab), 10, at(0));
        assert_eq!(app.focus, PaneFocus::Work);
        app.on_key(key(KeyCode::PageDown), 6, at(0));
        assert_eq!(app.work.scroll, 6, "the page moves by the focused pane's own viewport");
        assert_eq!(app.fleet.scroll, 0, "the fleet offset is untouched while work is focused");
        assert_eq!(app.session.scroll, 0, "and so is the session's");

        app.on_key(key(KeyCode::Up), 10, at(0));
        assert_eq!(app.work.scroll, 5);

        app.on_key(key(KeyCode::Tab), 10, at(0));
        assert_eq!(app.focus, PaneFocus::Session);
        app.on_key(key(KeyCode::PageDown), 4, at(0));
        assert_eq!(app.session.scroll, 4, "the session pane has its own offset");
        assert_eq!(app.work.scroll, 5, "and work is untouched now that session is focused");
        app.on_key(key(KeyCode::PageUp), 100, at(0));
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
            app.on_key(key(KeyCode::Down), 3, at(0));
        }
        assert_eq!(app.selected.as_deref(), Some("F"), "five rows down from A");
        // F is at index 5, document line 6; the least scroll showing line 6 in a 3-line viewport
        // is 4.
        assert_eq!(app.fleet.scroll, 4);
        assert_eq!(app.work.scroll, 0, "the work pane never moves for a fleet key");

        for _ in 0..5 {
            app.on_key(key(KeyCode::Up), 3, at(0));
        }
        assert_eq!(app.selected.as_deref(), Some("A"));
        assert_eq!(app.fleet.scroll, 0, "coming back to the top scrolls back to it");

        // The ends saturate rather than wrapping.
        app.on_key(key(KeyCode::Up), 3, at(0));
        assert_eq!(app.selected.as_deref(), Some("A"));
        app.on_key(key(KeyCode::PageDown), 3, at(0));
        assert_eq!(app.selected.as_deref(), Some("D"), "a page is a viewport of rows");
        app.on_key(key(KeyCode::PageDown), 100, at(0));
        assert_eq!(app.selected.as_deref(), Some("H"), "and it stops at the last row");
        app.on_key(key(KeyCode::PageUp), 100, at(0));
        assert_eq!(app.selected.as_deref(), Some("A"));
    }

    /// With no rows at all there is nothing to select and nothing to move.
    #[test]
    fn selection_keys_do_nothing_without_a_fleet() {
        let mut app = App::new();
        assert_eq!(app.on_key(key(KeyCode::Down), 10, at(0)), AppAction::None);
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
        app.on_key(key(KeyCode::Down), 1, at(0));
        assert_eq!(app.selected.as_deref(), Some("B"));
        assert_eq!(app.fleet.scroll, 2, "row B, alone, is what the one line shows");
        app.on_key(key(KeyCode::Up), 1, at(0));
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
            fresh.on_key(key(KeyCode::Down), 3, at(0));
            stale.on_key(key(KeyCode::Down), 3, at(0));
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
            fresh.on_key(key(KeyCode::Up), 3, at(0));
            stale.on_key(key(KeyCode::Up), 3, at(0));
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
        app.on_key(key(KeyCode::Tab), 10, at(0));
        assert_eq!(app.notice, None);

        // A key RELEASE is not a key press, and clears nothing.
        app.notice = Some("Storm is no longer on the roster.".into());
        let mut release = key(KeyCode::Down);
        release.kind = KeyEventKind::Release;
        app.on_key(release, 10, at(0));
        assert!(app.notice.is_some());
    }

    /// The notice slot has had one colour since it existed; the pruner's failure is the first
    /// thing in it that is not news but a fault (cb-kcs.5.2).
    #[test]
    fn an_error_notice_is_urgent_and_a_plain_one_is_not() {
        let mut app = App::new();
        assert!(!app.notice_urgent, "nothing is urgent before anything is said");
        app.set_error_notice("Worktree pruning stopped: exit status 2".into());
        assert_eq!(app.notice.as_deref(), Some("Worktree pruning stopped: exit status 2"));
        assert!(app.notice_urgent);
        // A plain notice after an urgent one is not urgent: a stale colour is a worse lie than a
        // stale line.
        app.set_notice("Cerebro was asked to rank 2 unranked beads.".into());
        assert!(!app.notice_urgent);
    }

    #[test]
    fn a_key_clears_the_colour_with_the_notice() {
        let mut app = App::new();
        app.set_error_notice("Worktree pruning stopped: exit status 2".into());
        app.on_key(key(KeyCode::Tab), 10, at(0));
        assert_eq!(app.notice, None);
        assert!(!app.notice_urgent);
    }

    /// When the board was ASKED, not when it answered. The triage guard proves the figures
    /// postdate the agent's transition, and arrival is later - an arrival-based age is smaller and
    /// would pass the guard in cases the rule refuses.
    #[test]
    fn the_work_request_time_is_when_it_was_asked() {
        let mut app = App::new();
        assert_eq!(app.work_requested_at(), None, "before the board has been asked");
        let asked = Utc::now();
        assert!(app.begin_work_refresh(Instant::now(), asked));
        let answered = asked + chrono::Duration::seconds(4);
        app.finish_work_refresh(Ok(WorkBuckets::default()), answered);
        assert_eq!(app.work_requested_at(), Some(asked), "the earlier of the two");
    }

    /// The request time is promoted WITH the value and never ahead of it
    /// (`cerebro--beads-read-at`'s own rule, `emacs/cerebro.el:5588-5596`).
    ///
    /// A `Stale` pane still hands its last good buckets to `triage_tell`, so a request time
    /// stamped by a read that then FAILED would pair old ids with a young age - and the triage
    /// guard, which exists to prove the figures postdate the agent's transition, would pass on a
    /// set Cerebro had already ranked.
    #[test]
    fn a_failed_work_read_does_not_move_the_request_time() {
        let mut app = App::new();
        let asked = Utc::now();
        assert!(app.begin_work_refresh(Instant::now(), asked));
        app.finish_work_refresh(Ok(WorkBuckets::default()), asked);

        let asked_again = asked + chrono::Duration::seconds(30);
        assert!(app.begin_work_refresh(Instant::now(), asked_again));
        app.finish_work_refresh(
            Err(ReadError::Spawn { source: "bd".into(), message: "no".into() }),
            asked_again,
        );

        assert!(app.work.content.value().is_some(), "the stale buckets are still rendered");
        assert_eq!(
            app.work_requested_at(),
            Some(asked),
            "the age belongs to the read that produced the ids still held"
        );
    }

    /// A notice set on a successful fleet read must not inherit the previous line's colour.
    #[test]
    fn a_selection_notice_is_never_left_red() {
        let mut app = App::new();
        app.finish_refresh(Ok(vec![row("Storm"), row("Cyclops")]), Utc::now());
        app.selected = Some("Storm".into());
        app.set_error_notice("Worktree pruning stopped: exit status 2".into());

        app.finish_refresh(Ok(vec![row("Cyclops")]), Utc::now());

        assert!(app.notice.as_deref().is_some_and(|n| n.contains("no longer on the roster")));
        assert!(!app.notice_urgent, "a roster change is news, not a fault");
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
            assert_eq!(app.on_key(key(code), 10, at(0)), AppAction::Quit);
            assert!(app.quit, "{code:?} sets quit immediately");
        }
        let mut app = App::new();
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(app.on_key(ctrl_c, 10, at(0)), AppAction::Quit);
        assert!(app.quit);

        // A plain `c' is not Ctrl-C, and nothing else quits.
        let mut app = App::new();
        assert_eq!(app.on_key(key(KeyCode::Char('c')), 10, at(0)), AppAction::None);
        assert_eq!(app.on_key(key(KeyCode::Char('x')), 10, at(0)), AppAction::None);
        assert!(!app.quit);
    }

    #[test]
    fn g_requests_both_readers() {
        let mut app = App::new();
        let start = Instant::now();
        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10, at(0)), AppAction::RefreshAll);
        assert!(app.begin_refresh(start));
        assert!(app.begin_work_refresh(start, Utc::now()));

        // The request is only honoured once per pane: a second `g' while both reads run is
        // dropped at each pane's own door.
        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10, at(0)), AppAction::RefreshAll);
        assert!(!app.begin_refresh(start + Duration::from_secs(1)));
        assert!(!app.begin_work_refresh(start + Duration::from_secs(1), Utc::now()));

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

        assert_eq!(app.on_key(key(KeyCode::Char('g')), 10, at(0)), AppAction::RefreshAll);
        assert!(!app.begin_refresh(start), "the busy pane refuses");
        assert!(app.begin_work_refresh(start, Utc::now()), "and the idle one still starts");
    }

    /// The worker answers off the UI thread. Since cb-x3u it answers from a `FakeCommands`
    /// rather than from two executables this test wrote: the claim is about the WORKER - a read
    /// asked for on the UI thread comes back from another one - and starting a process to make
    /// it was scaffolding that broke four separate times.
    #[test]
    fn the_worker_answers_off_the_ui_thread() {
        let fake = crate::readers::testing::FakeCommands::new(|call| {
            if call.program.ends_with("roster") {
                Ok(b"Xavier\tplanner\tinteractive\n".to_vec())
            } else {
                Ok(Vec::new())
            }
        });
        let worker = FleetWorker::spawn(
            ReaderPaths {
                consumer_root: std::path::PathBuf::from("/consumer"),
                shared_root: std::path::PathBuf::from("/consumer"),
                scripts_dir: std::path::PathBuf::from("/consumer/scripts"),
            },
            Programs::default(),
            std::sync::Arc::new(fake),
        );
        assert!(worker.poll().is_none(), "nothing was asked for yet");
        assert!(worker.request());

        let deadline = Instant::now() + Duration::from_secs(60);
        let result = loop {
            if let Some(result) = worker.poll() {
                break result;
            }
            assert!(Instant::now() < deadline, "the worker never answered");
            std::thread::sleep(Duration::from_millis(10));
        };
        let rows = result.expect("the fake answers both reads");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "Xavier");
    }

    // --- the gh pane (cb-kcs.4.3) --------------------------------------------------------------

    #[test]
    fn a_gh_failure_is_stale_then_answers_again() {
        let mut app = App::default();
        assert_eq!(app.gh_answer(), GhAnswer::Unanswered, "before the first request");

        let snapshot = GhSnapshot { me: Some("navigator".into()), ..GhSnapshot::default() };
        app.finish_gh_refresh(Ok(snapshot.clone()), at(1));
        assert_eq!(app.gh_answer(), GhAnswer::Answered(snapshot.clone()));

        // A failure keeps the value worth reading and is still `Failed` to a trigger: the last
        // good answer stands, and the ORDER of the two is what says it is not current.
        app.finish_gh_refresh(Err(bd_failure()), at(2));
        assert_eq!(app.gh_answer(), GhAnswer::Failed);
        assert!(app.gh.content.value().is_some(), "and the value is kept");

        app.finish_gh_refresh(Ok(snapshot.clone()), at(3));
        assert_eq!(app.gh_answer(), GhAnswer::Answered(snapshot));

        let mut fresh = App::default();
        fresh.finish_gh_refresh(Err(bd_failure()), at(1));
        assert_eq!(fresh.gh_answer(), GhAnswer::Failed, "a failure with nothing to keep");
    }

    #[test]
    fn gh_has_its_own_ten_minute_clock() {
        let mut app = App::default();
        let start = Instant::now();
        assert!(app.gh_due(start), "never asked");
        assert!(app.begin_gh_refresh(start));
        assert!(!app.begin_gh_refresh(start), "a request in flight is not stacked");
        assert!(!app.gh_due(start + GH_REFRESH_INTERVAL - Duration::from_secs(1)));
        assert!(app.gh_due(start + GH_REFRESH_INTERVAL));
        // The five-second tick never carries it.
        assert!(!app.gh_due(start + FLEET_REFRESH_INTERVAL));
    }

    fn dead(name: &str) -> FleetRow {
        FleetRow { state: RowState::Dead, ..row(name) }
    }

    /// A session that DIED is promised a retry on the backoff, so its row stays `Standby`; a
    /// launcher refusal and a give-up are not, and stay `Dead` (cb-ccl).
    #[test]
    fn a_crash_returns_to_standby_and_a_refusal_does_not() {
        let mut app = App::new();
        app.armed = ["Storm", "Rogue", "Xavier"].into_iter().map(String::from).collect();
        app.set_exits(
            [
                ("Storm".to_string(), LastExit::Code(137)),
                ("Rogue".to_string(), LastExit::Refused),
                ("Xavier".to_string(), LastExit::GaveUp { failures: 5 }),
            ]
            .into_iter()
            .collect(),
        );
        assert_eq!(
            app.parked_names(),
            ["Rogue".to_string(), "Xavier".to_string()].into_iter().collect()
        );

        app.finish_refresh(Ok(vec![dead("Storm"), dead("Rogue"), dead("Xavier")]), at(0));
        let states: Vec<RowState> = app.fleet_rows().iter().map(|r| r.state.clone()).collect();
        assert_eq!(states, vec![RowState::Standby, RowState::Dead, RowState::Dead]);
    }

    #[test]
    fn reapplying_standby_changes_neither_freshness_nor_read_at() {
        let mut app = App::new();
        app.armed = ["Storm"].into_iter().map(String::from).collect();
        app.finish_refresh(Ok(vec![dead("Storm")]), at(0));
        assert_eq!(app.fleet_rows()[0].state, RowState::Standby);

        // The give-up happens inside the loop, where no refresh can be asked for: the row must
        // stop promising a retry in the same frame.
        app.set_exits(
            [("Storm".to_string(), LastExit::GaveUp { failures: 5 })].into_iter().collect(),
        );
        app.armed.remove("Storm");
        app.reapply_standby();
        assert_eq!(app.fleet_rows()[0].state, RowState::Dead);
        assert!(
            matches!(app.fleet.content, PaneContent::Fresh { read_at, .. } if read_at == at(0)),
            "not a refresh: neither freshness nor read_at moves"
        );

        // And it is not a read: a pane with nothing in it is left exactly as it was.
        let mut empty = App::new();
        empty.reapply_standby();
        assert!(matches!(empty.fleet.content, PaneContent::Loading));
        empty.finish_refresh(
            Err(ReadError::Spawn { source: "ps".into(), message: "no".into() }),
            at(5),
        );
        empty.reapply_standby();
        assert!(matches!(empty.fleet.content, PaneContent::Unavailable { .. }));
    }

    /// History has its own five-minute clock and its own in-flight slot, exactly as the sweeps
    /// and `gh` do: a thirty-second `jq` walk behind a five-second fleet read is the one thing
    /// independent panes must not do.
    #[test]
    fn the_history_cadence_is_its_own() {
        let mut app = App::default();
        let start = Instant::now();
        assert!(app.history_due(start), "nothing has been asked yet");
        assert!(app.begin_history_refresh(start));
        assert!(!app.begin_history_refresh(start), "one at a time");
        // A work or fleet read in flight says nothing about History, and the reverse.
        assert!(app.begin_work_refresh(start, Utc::now()));
        assert!(app.begin_refresh(start));
        app.finish_history_refresh(Ok(Vec::new()), at(0));
        assert!(!app.history_due(start + Duration::from_secs(299)));
        assert!(app.history_due(start + HISTORY_REFRESH_INTERVAL));
    }

    #[test]
    fn a_failed_history_read_keeps_the_rows_it_had() {
        let mut app = App::default();
        let row = model::HistoryRow {
            agent: "Cyclops".into(),
            state: "working".into(),
            open_min: Some(3.0),
            ..model::HistoryRow::default()
        };
        app.begin_history_refresh(Instant::now());
        app.finish_history_refresh(Ok(vec![row.clone()]), at(0));
        assert!(matches!(app.history.content, PaneContent::Fresh { .. }));

        app.begin_history_refresh(Instant::now());
        app.finish_history_refresh(
            Err(ReadError::Invalid { source: "fleet-history".into(), message: "nope".into() }),
            at(60),
        );
        match &app.history.content {
            PaneContent::Stale { value, read_at, .. } => {
                assert_eq!(value, &vec![row]);
                assert_eq!(*read_at, at(0), "as old as its read, not as old as the failure");
            }
            other => panic!("{other:?}"),
        }
    }

    // --- the whole Work document, the widened cursor and `Enter` (cb-kcs.5.4) ----------------

    fn test_bead(id: &str, priority: Option<u8>) -> Bead {
        Bead {
            id: id.to_string(),
            title: format!("title of {id}"),
            status: "open".into(),
            issue_type: "task".into(),
            labels: Vec::new(),
            priority,
            updated_at: None,
            assignee: None,
            metadata: serde_json::Value::Null,
            external_ref: None,
        }
    }

    fn history(agent: &str, open: f64, median: Option<f64>) -> HistoryRow {
        HistoryRow {
            agent: agent.to_string(),
            state: "working".into(),
            open_min: Some(open),
            median_min: median,
            ..HistoryRow::default()
        }
    }

    /// Two findings, two claimed beads, five empty sections, a section of twelve, and three
    /// History rows - and every drawn line named.
    fn document_app() -> App {
        let mut app = App::default();
        app.finish_sweep_refresh(Ok(vec![judged("unclaim"), judged("reclaim")]), at(0));
        app.finish_work_refresh(
            Ok(WorkBuckets {
                claimed: vec![test_bead("cb-a", Some(1)), test_bead("cb-b", Some(0))],
                unplanned: (1..=12).map(|n| test_bead(&format!("cb-{n:02}"), Some(4))).collect(),
                ..WorkBuckets::default()
            }),
            at(0),
        );
        app.finish_history_refresh(
            Ok(vec![
                history("Cyclops", 2.4, Some(21.9)),
                history("Psylocke", 536.6, Some(2.2)),
                // Not running: no line, and not counted.
                HistoryRow { open_min: None, ..history("Beast", 0.0, Some(3.0)) },
            ]),
            at(0),
        );
        app
    }

    #[test]
    fn the_body_names_every_line_of_the_work_pane() {
        let app = document_app();
        let body = work_body(&app, at(0));
        let shape: Vec<String> = body
            .iter()
            .map(|line| match line {
                WorkBodyLine::SweepHeader { count, .. } => format!("sweep-header {count}"),
                WorkBodyLine::Finding { key, .. } => format!("finding {key}"),
                WorkBodyLine::Blank => "blank".into(),
                WorkBodyLine::Notice(n) => format!("notice {n:?}"),
                WorkBodyLine::SectionHeader { title, count } => format!("header {title} {count}"),
                WorkBodyLine::Bead { bead, .. } => format!("bead {}", bead.id),
                WorkBodyLine::Empty => "(none)".into(),
                WorkBodyLine::More { section, hidden, expanded } => {
                    format!("more {section} {hidden} {expanded}")
                }
                WorkBodyLine::HistoryHeader { count, failed } => {
                    format!("history-header {count} {failed}")
                }
                WorkBodyLine::HistoryRow { text, long } => format!("history {text} {long}"),
            })
            .collect();
        assert_eq!(
            shape,
            vec![
                "sweep-header 2",
                "finding unclaim:cb-a",
                "finding reclaim:cb-b",
                "blank",
                // The six queues, in the order work moves in read backwards.
                "header Claimed 2",
                // P0 before P1: the section's own order, which the document owns now.
                "bead cb-b",
                "bead cb-a",
                "blank",
                "header Planned, unclaimed 0",
                "(none)",
                "blank",
                "header Being planned 0",
                "(none)",
                "blank",
                "header Unplanned 12",
                "bead cb-01",
                "bead cb-02",
                "bead cb-03",
                "bead cb-04",
                "bead cb-05",
                "bead cb-06",
                "bead cb-07",
                "bead cb-08",
                "more Unplanned 4 false",
                "blank",
                "header Waiting on you 0",
                "(none)",
                "blank",
                "header Merged, unverified 0",
                "(none)",
                // History last, after `Merged, unverified` - the `M-x cerebro` order.
                "blank",
                "history-header 2 false",
                "history   Cyclops working 2m false",
                "history   Psylocke working 537m - long, median 2m true",
            ]
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>(),
            "{shape:#?}"
        );
    }

    /// A section with nothing hidden is never expandable, so no `More` row is drawn for it and
    /// `expanded` naming it changes nothing.
    #[test]
    fn a_section_with_nothing_hidden_has_no_more_row() {
        let mut app = App::default();
        app.expanded.insert("Claimed");
        app.finish_work_refresh(
            Ok(WorkBuckets {
                claimed: (1..=8).map(|n| test_bead(&format!("cb-{n}"), Some(1))).collect(),
                ..WorkBuckets::default()
            }),
            at(0),
        );
        assert!(
            !work_body(&app, at(0))
                .iter()
                .any(|line| matches!(line, WorkBodyLine::More { .. })),
            "eight rows are all of them"
        );
    }

    #[test]
    fn the_work_cursor_moves_over_findings_beads_and_more() {
        let mut app = document_app();
        app.focus = PaneFocus::Work;
        // From the first frame it is on the first selectable row, with nothing pressed.
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("unclaim:cb-a".into())));

        let mut seen = vec![app.work_cursor.clone().unwrap()];
        for _ in 0..13 {
            app.on_key(key(KeyCode::Down), 10, at(0));
            seen.push(app.work_cursor.clone().unwrap());
        }
        assert_eq!(
            seen,
            vec![
                WorkCursor::Finding("unclaim:cb-a".into()),
                WorkCursor::Finding("reclaim:cb-b".into()),
                // Straight onto the bead rows: no header, blank or `(none)` in between.
                WorkCursor::Bead("cb-b".into()),
                WorkCursor::Bead("cb-a".into()),
                WorkCursor::Bead("cb-01".into()),
                WorkCursor::Bead("cb-02".into()),
                WorkCursor::Bead("cb-03".into()),
                WorkCursor::Bead("cb-04".into()),
                WorkCursor::Bead("cb-05".into()),
                WorkCursor::Bead("cb-06".into()),
                WorkCursor::Bead("cb-07".into()),
                WorkCursor::Bead("cb-08".into()),
                WorkCursor::More("Unplanned"),
                // Clamped: History rows are never selectable, so this is the last row there is.
                WorkCursor::More("Unplanned"),
            ]
        );

        // And clamped at the top, too.
        for _ in 0..40 {
            app.on_key(key(KeyCode::Up), 10, at(0));
        }
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("unclaim:cb-a".into())));
        // PgDn moves a viewport of selectable rows.
        app.on_key(key(KeyCode::PageDown), 5, at(0));
        assert_eq!(app.work_cursor_index(at(0)), Some(5));
    }

    /// A cursor whose row is gone takes the selectable row at its index, clamped - and says
    /// nothing about it.
    #[test]
    fn a_cursor_whose_bead_is_gone_takes_the_row_at_its_index() {
        let mut app = App::default();
        app.focus = PaneFocus::Work;
        app.finish_work_refresh(
            Ok(WorkBuckets {
                claimed: vec![test_bead("cb-a", Some(1)), test_bead("cb-b", Some(2))],
                ..WorkBuckets::default()
            }),
            at(0),
        );
        app.on_key(key(KeyCode::Down), 10, at(0));
        assert_eq!(app.work_cursor, Some(WorkCursor::Bead("cb-b".into())));

        // cb-b is closed and gone; the row at index 1 is now cb-c.
        app.finish_work_refresh(
            Ok(WorkBuckets {
                claimed: vec![test_bead("cb-a", Some(1)), test_bead("cb-c", Some(3))],
                ..WorkBuckets::default()
            }),
            at(30),
        );
        assert_eq!(app.work_cursor, Some(WorkCursor::Bead("cb-c".into())));
        assert_eq!(app.notice, None, "a refresh is not news");
    }

    #[test]
    fn enter_opens_and_closes_one_section() {
        let mut app = document_app();
        app.focus = PaneFocus::Work;
        for _ in 0..12 {
            app.on_key(key(KeyCode::Down), 10, at(0));
        }
        assert_eq!(app.work_cursor, Some(WorkCursor::More("Unplanned")));

        app.on_key(key(KeyCode::Enter), 10, at(0));
        let body = work_body(&app, at(0));
        assert_eq!(
            body.iter().filter(|l| matches!(l, WorkBodyLine::Bead { .. })).count(),
            14,
            "all twelve of the open section, plus the two claimed"
        );
        assert!(body.iter().any(|l| matches!(
            l,
            WorkBodyLine::More { section: "Unplanned", hidden: 4, expanded: true }
        )));

        // It survives a work refresh: a rerank of fifteen beads must not be interrupted by the
        // section shutting under the cursor.
        app.finish_work_refresh(
            Ok(WorkBuckets {
                unplanned: (1..=12).map(|n| test_bead(&format!("cb-{n:02}"), Some(4))).collect(),
                ..WorkBuckets::default()
            }),
            at(30),
        );
        assert!(app.expanded.contains("Unplanned"));

        // And `Enter` again folds it.
        app.work_cursor = Some(WorkCursor::More("Unplanned"));
        app.on_key(key(KeyCode::Enter), 10, at(30));
        assert!(!app.expanded.contains("Unplanned"));
    }

    /// History and the stale footer carry no cursor by the navigator's own choice, so a cursor
    /// clamped at the last bead row would put every line below it under a floor the pane could
    /// never scroll past - which is half of what this bead delivers, invisible on any real board.
    /// At the end of the cursor's run the keys go back to scrolling the pane.
    #[test]
    fn the_pane_scrolls_past_the_last_selectable_row_to_reach_history() {
        let mut app = document_app();
        app.focus = PaneFocus::Work;
        let lines = work_body(&app, at(0)).len();
        let viewport = 6;

        // Walk the cursor to the last selectable row, and past it.
        for _ in 0..40 {
            app.on_key(key(KeyCode::Down), viewport, at(0));
        }
        assert_eq!(app.work_cursor, Some(WorkCursor::More("Unplanned")));
        assert!(
            app.work.scroll + viewport >= lines,
            "the last line of the document — a History row — is on screen: \
             scroll {} + {viewport} of {lines}",
            app.work.scroll
        );

        // And back up again: the pane follows the keys the whole way.
        for _ in 0..40 {
            app.on_key(key(KeyCode::Up), viewport, at(0));
        }
        assert_eq!(app.work_cursor, Some(WorkCursor::Finding("unclaim:cb-a".into())));
        assert_eq!(app.work.scroll, 0);
    }

    /// The least that keeps the new line visible, in both directions: a move onto a row already
    /// on screen leaves the pane where it was.
    #[test]
    fn a_cursor_move_within_the_viewport_does_not_move_the_pane() {
        let mut app = document_app();
        app.focus = PaneFocus::Work;
        for _ in 0..12 {
            app.on_key(key(KeyCode::Down), 6, at(0));
        }
        let scrolled = app.work.scroll;
        assert!(scrolled > 0, "the fixture must have scrolled, or this proves nothing");
        app.on_key(key(KeyCode::Up), 6, at(0));
        assert_eq!(app.work.scroll, scrolled, "the row above is already on screen");
    }

    /// A cursor naming a row that has gone is not a cursor at index 0: `Up` must re-seat it
    /// rather than reading as "already at the top" and leaving it stale for ever. Reachable from
    /// the keyboard with no refresh at all — collapse the section the cursor is standing in.
    #[test]
    fn up_reseats_a_cursor_whose_row_has_gone() {
        let mut app = document_app();
        app.focus = PaneFocus::Work;
        app.expanded.insert("Unplanned");
        // A bead only the OPEN section shows.
        app.work_cursor = Some(WorkCursor::Bead("cb-12".into()));
        assert!(app.work_cursor_index(at(0)).is_some(), "it is a target while the section is open");

        app.expanded.remove("Unplanned");
        assert_eq!(app.work_cursor_index(at(0)), None, "and gone once it is folded");

        app.on_key(key(KeyCode::Up), 10, at(0));
        assert_eq!(
            app.work_cursor,
            Some(WorkCursor::Finding("unclaim:cb-a".into())),
            "Up put it back on a real row"
        );
    }
}
