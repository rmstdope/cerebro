//! The read-only fleet screen, drawn from `App` and an injected `now` and from nothing else.
//!
//! No function here reads a file, runs a program or asks the clock: two draws of one `App` at one
//! `now` produce the same bytes, which is what makes the `TestBackend` cases below assertions
//! about the screen rather than about the machine they run on.
//!
//! Fleet and Work are two independent, bordered widgets stacked one above the other - each has its
//! own title, its own focus and border style, and its own scroll offset carried on its own `Pane`.
//! There is no longer a single scrollable document behind them: `App::on_key` moves only the
//! focused pane, and this module lays each pane out, renders it, and reports its own geometry back
//! through `metrics` so the event loop can page and clamp each one independently.
//!
//! The row vocabulary is `emacs/cerebro.el`'s, deliberately unchanged (`cerebro--glyph`,
//! `cerebro--elapsed`, `cerebro--state-label`, `cerebro--entry`): a navigator reading this screen
//! beside `M-x cerebro` must not have to learn a second set of glyphs, and a difference between
//! the two would read as a difference in the fleet. Emacs-only signals are absent rather than
//! guessed - there is no `standby` row here and no stop-flag mark, because neither is in this
//! reader's normalized model, and inventing one would show supervisor intent as observed fact.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};
use ratatui::Frame;
use unicode_width::UnicodeWidthStr;

use crate::lifecycle::LastExit;
use crate::supervisor::{ReadOnlyReason, SupervisionMode, SupervisorKind};
use crate::app::{App, FleetBodyLine, Metrics, Pane, PaneContent, PaneFocus, PaneMetrics, Prompt};
use crate::lifecycle;
use crate::model::{Bead, FleetRow, RowState, WorkBuckets};
use crate::session::SessionView;

/// The floor the whole screen needs. Below it the screen says so and shows nothing else: half a
/// row of a fleet is worse than a sentence saying the window is too small.
pub const MIN_COLUMNS: u16 = 40;
pub const MIN_ROWS: u16 = 12;

/// At and above this width the Role and For columns are shown; below it only Agent, State and
/// Bead survive, which is what the navigator chose over squeezing five columns into forty.
pub const WIDE_COLUMNS: u16 = 64;

/// At or above this width the screen splits into a fixed-width left column and a session pane;
/// below it all three panes stack. The navigator chose 100 so the session never gets fewer than
/// sixty cells beside the fleet, and so a 110-cell half-screen stays split.
pub const SPLIT_COLUMNS: u16 = 100;

/// The left column's width when the screen is split - Fleet and Work in their narrow columns, and
/// every remaining cell to the session.
pub const LEFT_COLUMN: u16 = 40;

/// The exact title agreed in the parent epic's interview, em dash and all - now the read-only
/// spelling of five, one per supervision state (`supervision_title`).
const TITLE: &str = "Cerebro — read-only";

/// The header's first span: what this process is allowed to do with the checkout (cb-kcs.1).
///
/// The navigator chose the header line as the WHOLE of the TUI's ownership surface, over a third
/// bordered pane and over an unfocusable strip: ownership must not take a Tab stop or rows from
/// Fleet and Work. So the remediation and no-action lines in `docs/ui/cb-kcs-supervisor.html`
/// are not rendered here - they remain the approved wording for the Emacs mode line, which keeps
/// them.
///
/// **The ordinary case says nothing.** A project that has not moved supervision - which is every
/// consumer today - gets the bare `Cerebro — read-only` this screen has always shown, because
/// spelling ownership out there cost the pane and scroll hints their room at a hundred columns
/// and told the navigator nothing they did not already know. The long spellings are spent where
/// there is something to say: the lease is contested, or the declaration is wrong. That is the
/// navigator's own call, taken when the measurement was put to them.
pub fn supervision_title(mode: &SupervisionMode) -> String {
    match mode {
        SupervisionMode::Supervising => "Cerebro — supervising".to_string(),
        SupervisionMode::Draining { .. } => "Cerebro — handoff pending".to_string(),
        // Configured for the other view, or configured for us and not yet asked for: the
        // uncontested cases, and the screen every consumer sees today.
        SupervisionMode::ReadOnly(ReadOnlyReason::ConfiguredFor(_))
        | SupervisionMode::ReadOnly(ReadOnlyReason::NotOwned) => TITLE.to_string(),
        // Contested: somebody else is holding a lease this project says is ours.
        SupervisionMode::ReadOnly(ReadOnlyReason::OwnedBy(SupervisorKind::Emacs)) => {
            "Cerebro — read-only; Emacs owns supervision".to_string()
        }
        SupervisionMode::ReadOnly(ReadOnlyReason::OwnedBy(SupervisorKind::Tui)) => {
            "Cerebro — read-only; another Ratatui process owns supervision".to_string()
        }
        SupervisionMode::ReadOnly(ReadOnlyReason::InvalidDeclaration(raw)) => {
            format!("Cerebro — read-only; invalid fleet_supervisor {raw:?}")
        }
        // True of every lock error, which "held by another process" was not: a bind that
        // succeeded and a record that then could not be written, and a bind refused for a reason
        // that is not `AddrInUse`, are both states in which nobody holds anything. The detail -
        // which endpoint, which other checkout - goes to stderr when the screen exits, never into
        // the header: an absolute path in a status line is unreadable at any width, and the
        // navigator asked for the short sentence here (cb-kcs.1).
        SupervisionMode::ReadOnly(ReadOnlyReason::LockError(_)) => {
            "Cerebro — read-only; the supervision lease could not be taken".to_string()
        }
        // Says nothing about who holds the lease, because this process may well be holding it:
        // what failed is reading the declaration that says whose it is.
        SupervisionMode::ReadOnly(ReadOnlyReason::DeclarationUnreadable(_)) => {
            "Cerebro — read-only; fleet_supervisor could not be read".to_string()
        }
    }
}

/// How many beads each Work section shows before it says `+N more` - the panel's own
/// `cerebro-beads-per-section`, and for the same reason: an unplanned backlog is unbounded, and
/// without a cap the two sections worth reading are pushed off the bottom by the third.
pub const WORK_ROWS_PER_SECTION: usize = 8;

const AGENT_FLOOR: usize = 14;
const ROLE_FLOOR: usize = 13;
const STATE_FLOOR: usize = 12;
const BEAD_FLOOR: usize = 10;

const GREEN: Color = Color::Green;
const GOLD: Color = Color::Yellow;
const BLUE: Color = Color::Blue;
const RED: Color = Color::Red;

/// The selected row's background. `DarkGray` rather than an RGB colour: the fleet view runs in
/// whatever terminal the navigator has, and every state colour on the row must stay legible on
/// it. Reversed video was the alternative and loses the row's own green/gold/red entirely.
const SELECTED_BG: Color = Color::DarkGray;

fn dim() -> Style {
    Style::default().add_modifier(Modifier::DIM)
}

/// True when AREA is below the floor the whole screen needs - the one frame `main`'s clamp must
/// skip entirely rather than run against, because a too-small frame's own metrics are the zeros
/// `draw_too_small` implies, and clamping either pane's real offset against a borrowed zero would
/// silently reset it the moment the terminal happens to dip below the floor and come back.
pub fn too_small(area: Rect) -> bool {
    area.width < MIN_COLUMNS || area.height < MIN_ROWS
}

/// The geometry one draw of APP at NOW in AREA would produce, one `PaneMetrics` per widget.
///
/// This calls the same `split` and `pane_geometry` helpers `draw` renders from, so a page size, a
/// clamp and a range cue can never be computed from three different geometries.
pub fn metrics(app: &App, now: DateTime<Utc>, area: Rect) -> Metrics {
    if too_small(area) {
        return Metrics {
            fleet: PaneMetrics { content_lines: 0, viewport_lines: 0, inner_width: 0 },
            work: PaneMetrics { content_lines: 0, viewport_lines: 0, inner_width: 0 },
            session: PaneMetrics { content_lines: 0, viewport_lines: 0, inner_width: 0 },
        };
    }
    let fleet_lines = fleet_document(app, now, fleet_width(area), app.selected_index());
    let (_, fleet_rect, work_rect, session_rect) =
        split(area, fleet_lines.len(), work_content_lines(app, now, area));
    let work_inner_width = (work_rect.width as usize).saturating_sub(2);
    let work_lines = work_document(app, now, work_inner_width);
    let session_lines = session_document(app);
    let (fleet_viewport, _) = pane_geometry(fleet_rect, fleet_lines.len());
    let (work_viewport, _) = pane_geometry(work_rect, work_lines.len());
    let (session_viewport, _) = pane_geometry(session_rect, session_lines.len());
    Metrics {
        fleet: PaneMetrics {
            content_lines: fleet_lines.len(),
            viewport_lines: fleet_viewport,
            inner_width: inner_width(fleet_rect),
        },
        work: PaneMetrics {
            content_lines: work_lines.len(),
            viewport_lines: work_viewport,
            inner_width: work_inner_width,
        },
        session: PaneMetrics {
            content_lines: session_lines.len(),
            viewport_lines: session_viewport,
            inner_width: inner_width(session_rect),
        },
    }
}

/// A pane's inner width in cells: its own width less the two border columns.
fn inner_width(outer: Rect) -> usize {
    (outer.width as usize).saturating_sub(2)
}

/// Split AREA into the one-line header, the Fleet, Work and Session rects.
///
/// At `SPLIT_COLUMNS` or wider: a `LEFT_COLUMN`-wide column holding Fleet over Work by the
/// existing rule - Fleet's natural outer height capped at half the column, Work taking the rest -
/// and the Session pane taking the remaining width at the column's full height.
///
/// Below it: three stacked panes. Fleet takes its natural outer height capped at a third of the
/// available height, then Work takes its natural outer height capped at half of what is left, and
/// Session takes the remainder. Both caps are floored at three outer rows, so every pane keeps at
/// least one inner row at the 40x12 minimum.
fn split(
    area: Rect,
    fleet_content_lines: usize,
    work_content_lines: usize,
) -> (Rect, Rect, Rect, Rect) {
    let rows = Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).split(area);
    let header = rows[0];
    let available = rows[1];
    let fleet_natural = fleet_content_lines + 2;

    if area.width >= SPLIT_COLUMNS {
        let columns =
            Layout::horizontal([Constraint::Length(LEFT_COLUMN), Constraint::Min(0)]).split(available);
        let left = columns[0];
        let cap = ((left.height as usize) / 2).max(3);
        let fleet_outer = fleet_natural.min(cap) as u16;
        let stacked =
            Layout::vertical([Constraint::Length(fleet_outer), Constraint::Min(0)]).split(left);
        return (header, stacked[0], stacked[1], columns[1]);
    }

    let height = available.height as usize;
    let fleet_outer = fleet_natural.min((height / 3).max(3));
    let remaining = height.saturating_sub(fleet_outer);
    let work_outer = (work_content_lines + 2).min((remaining / 2).max(3)).min(remaining);
    let panes = Layout::vertical([
        Constraint::Length(fleet_outer as u16),
        Constraint::Length(work_outer as u16),
        Constraint::Min(0),
    ])
    .split(available);
    (header, panes[0], panes[1], panes[2])
}

/// How many lines the Work pane's body will come to, for the one caller that needs it before
/// `split` has said how wide that pane is.
///
/// Only the stacked layout reads it - the split layout gives Work every row Fleet does not want,
/// whatever its body comes to - so this builds nothing at all on a wide screen. In the stacked
/// layout the pane is the screen's own width, so there is no probe and no guess: the width passed
/// here is the width the body will be built at.
///
/// It does mean a narrow terminal builds the Work body twice per `draw` and twice per `metrics`.
/// That is deliberate and measured against the alternative: threading one build through both
/// would make `split` take the lines rather than derive them, and the panes refresh on a
/// five-second and a thirty-second clock over a roster and a board of a few dozen rows.
fn work_content_lines(app: &App, now: DateTime<Utc>, area: Rect) -> usize {
    if area.width >= SPLIT_COLUMNS {
        return 0;
    }
    work_document(app, now, (area.width as usize).saturating_sub(2)).len()
}

/// How wide the Fleet pane will be, before `split` runs - `LEFT_COLUMN` when AREA is at least
/// `SPLIT_COLUMNS` wide, AREA's own width otherwise.
///
/// It exists because `draw` and `metrics` both need the fleet body before the split, and the
/// screen's width stopped being the Fleet pane's width the moment a third pane appeared beside
/// it. Safe to compute first: the fleet body's LINE COUNT does not depend on width, only its
/// column layout does.
fn fleet_width(area: Rect) -> u16 {
    if area.width >= SPLIT_COLUMNS {
        LEFT_COLUMN
    } else {
        area.width
    }
}

/// OUTER's visible body-line count and whether its content is long enough to need the range cue,
/// from OUTER's own height and TOTAL_LINES alone.
///
/// A clipped pane gives up its inner rectangle's last row to the cue, so its viewport is one
/// shorter than an unclipped pane of the same size would show. Below two inner rows there is no
/// row to spare for a cue at all, so the pane is never treated as clipped - the 40x12 floor
/// guarantees at least two inner rows once a pane has been through `split`, but this stays
/// defensive rather than relying on that.
fn pane_geometry(outer: Rect, total_lines: usize) -> (usize, bool) {
    let inner_height = outer.height.saturating_sub(2) as usize;
    if inner_height < 2 {
        (inner_height, false)
    } else if total_lines > inner_height {
        (inner_height - 1, true)
    } else {
        (inner_height, false)
    }
}

/// Render APP at NOW into FRAME.
pub fn draw(frame: &mut Frame<'_>, app: &App, now: DateTime<Utc>) {
    let area = frame.area();
    if too_small(area) {
        draw_too_small(frame, area);
        return;
    }
    // The quit refusal takes the whole screen, header included: it is the one thing here that
    // stops the navigator leaving, and it must not look like the smallest confirmation on the
    // screen (Q4). It does not scroll, and the three panes behind it keep their own offsets.
    if let Some(live) = &app.quit_refusal {
        let header = Rect { height: 1, ..area };
        let body = Rect { y: area.y + 1, height: area.height - 1, ..area };
        frame.render_widget(Paragraph::new(header_line(app, header.width)), header);
        render_alert_pane(
            frame,
            body,
            Line::from(Span::styled(
                lifecycle::quit_refusal_title(live.len()),
                Style::default().fg(RED).add_modifier(Modifier::BOLD),
            )),
            &lifecycle::quit_refusal_lines(live),
        );
        return;
    }
    let fleet_lines = fleet_document(app, now, fleet_width(area), app.selected_index());
    let (header, fleet_rect, work_rect, session_rect) =
        split(area, fleet_lines.len(), work_content_lines(app, now, area));
    frame.render_widget(Paragraph::new(header_line(app, header.width)), header);

    let fleet_count = app.fleet.content.value().map(|rows| rows.len());
    let fleet_title = pane_title(&app.fleet, "Fleet", failed(&app.work), fleet_count);
    render_pane(
        frame,
        fleet_rect,
        Line::from(Span::styled(
            fleet_title,
            title_style(&app.fleet, app.focus == PaneFocus::Fleet),
        )),
        app.focus == PaneFocus::Fleet,
        &fleet_lines,
        app.fleet.scroll,
    );

    let work_inner_width = (work_rect.width as usize).saturating_sub(2);
    let work_lines = work_document(app, now, work_inner_width);
    let work_title = pane_title(&app.work, "Work", failed(&app.fleet), None);
    render_pane(
        frame,
        work_rect,
        Line::from(Span::styled(work_title, title_style(&app.work, app.focus == PaneFocus::Work))),
        app.focus == PaneFocus::Work,
        &work_lines,
        app.work.scroll,
    );

    let session_focused = app.focus == PaneFocus::Session;
    let session_lines = session_document(app);
    // RED is this screen's spelling for a thing that went wrong, and a refused launch is the one
    // Session state that is one.
    let session_border =
        matches!(app.session.view, SessionView::Refused { .. }).then_some(RED);
    render_bordered_pane(
        frame,
        session_rect,
        session_title(app, session_focused),
        session_focused,
        session_border,
        &session_lines,
        app.session.scroll,
    );

    // The child's cursor, and only while the pane has the keyboard - the navigator's choice (Q2)
    // over painting a second, dim block into an unfocused pane. It stays deterministic: the
    // position came from `App`, materialised before the frame.
    if app.session_has_keyboard() {
        if let SessionView::Live { cursor: (row, col), .. } = &app.session.view {
            let inner = Rect {
                x: session_rect.x + 1,
                y: session_rect.y + 1,
                width: session_rect.width.saturating_sub(2),
                height: session_rect.height.saturating_sub(2),
            };
            // A child that has just been resized can report a position outside the pane for a
            // moment, and a cursor drawn over somebody else's border is worse than none.
            if *row < inner.height && *col < inner.width {
                frame.set_cursor_position(Position { x: inner.x + col, y: inner.y + row });
            }
        }
    }
}

/// A pane that reports a FAILURE: red border, no focus, no scrolling.
///
/// Its two users are the quit refusal and a refused launch, and neither is focusable.
fn render_alert_pane(
    frame: &mut Frame<'_>,
    outer: Rect,
    title: Line<'static>,
    lines: &[Line<'static>],
) {
    render_bordered_pane(frame, outer, title, false, Some(RED), lines, 0);
}

/// One widget: its border (focus only), its title (status colour, bold only while focused), its
/// scrolled body, and - when its content outgrows its inner height - the reserved range-cue row.
///
/// LINES is the pane's whole body, already built for this frame's width, and is BORROWED: the
/// retained transcript is up to ten thousand lines and is handed to this function every frame.
/// SCROLL is that pane's own offset. TITLE carries its own styling - two spans for the Session
/// pane, the title in its own style and then the dim hint, and one for Fleet and Work. Borders
/// carry focus alone: an unfocused pane is always the ordinary thin, dim border whatever its title
/// reports, and a focused pane is always the thick, bright-blue one - status colour is the title's
/// own signal, not the border's, so a focused stale/unavailable pane keeps its gold/red title
/// behind a blue border rather than losing that colour to focus.
fn render_pane(
    frame: &mut Frame<'_>,
    outer: Rect,
    title: Line<'static>,
    focused: bool,
    lines: &[Line<'static>],
    scroll: usize,
) {
    render_bordered_pane(frame, outer, title, focused, None, lines, scroll);
}

/// `render_pane`, with the border colour given rather than derived from focus. RED is this
/// screen's one spelling for a thing that went wrong, and the two panes that use it - the quit
/// refusal and a refused launch - are not focusable.
#[allow(clippy::too_many_arguments)]
fn render_bordered_pane(
    frame: &mut Frame<'_>,
    outer: Rect,
    title: Line<'static>,
    focused: bool,
    border: Option<Color>,
    lines: &[Line<'static>],
    scroll: usize,
) {
    let (border_type, border_style) = match border {
        Some(color) => (BorderType::Plain, Style::default().fg(color)),
        None if focused => (BorderType::Thick, Style::default().fg(BLUE)),
        None => (BorderType::Plain, dim()),
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(border_type)
        .border_style(border_style)
        .title(title);
    let inner = block.inner(outer);
    frame.render_widget(block, outer);
    if inner.height == 0 || inner.width == 0 {
        return;
    }

    let total = lines.len();
    let (viewport_lines, clipped) = pane_geometry(outer, total);
    let body_height = viewport_lines as u16;
    let clamped_scroll = scroll.min(total.saturating_sub(viewport_lines));
    let body_rect = Rect { height: body_height, ..inner };
    // The visible window alone, rather than the whole document with `Paragraph::scroll`: nothing
    // here sets `.wrap`, so a `Paragraph` neither reflows nor re-splits lines and the rendering is
    // identical - but a pane now pays for its viewport rather than for its document, which is what
    // makes a ten-thousand-line retained transcript free to draw.
    let last = (clamped_scroll + viewport_lines).min(total);
    frame.render_widget(Paragraph::new(lines[clamped_scroll..last].to_vec()), body_rect);
    if clipped {
        let first = clamped_scroll + 1;
        let last = (clamped_scroll + viewport_lines).min(total);
        let cue_rect = Rect { y: inner.y + body_height, height: 1, ..inner };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(format!("Rows {first}–{last} of {total}"), dim()))),
            cue_rect,
        );
    }
}

/// Below the floor the screen is replaced, not cropped: the heading and these seven lines are the
/// whole screen, and the quit keys are named because a navigator who cannot resize still has to
/// get out.
fn draw_too_small(frame: &mut Frame<'_>, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .title("Terminal too small");
    let text = vec![
        Line::from("Cerebro needs at least"),
        Line::from(format!("{MIN_COLUMNS} columns x {MIN_ROWS} rows.")),
        Line::from(""),
        Line::from(format!("Current size: {} x {}.", area.width, area.height)),
        Line::from(""),
        Line::from("Resize the terminal,"),
        Line::from("or press q/Esc/Ctrl-C to quit."),
    ];
    frame.render_widget(
        Paragraph::new(text)
            .style(Style::default().fg(GOLD))
            .block(block),
        area,
    );
}

/// `HH:MM:SS`, in UTC, because `now` is: a rendered clock that depended on the machine's zone
/// would make this renderer impure in the one way its tests could not see.
fn clock(at: DateTime<Utc>) -> String {
    at.format("%H:%M:%S").to_string()
}

fn pane_color<T>(pane: &Pane<T>) -> Color {
    match &pane.content {
        PaneContent::Stale { .. } => GOLD,
        PaneContent::Unavailable { .. } => RED,
        _ => BLUE,
    }
}

/// True when this pane has nothing current to show - the condition its healthy peer answers by
/// putting its own last refresh time in its title, so a navigator reading past a failure can see
/// how current the surviving half is.
fn failed<T>(pane: &Pane<T>) -> bool {
    matches!(
        pane.content,
        PaneContent::Stale { .. } | PaneContent::Unavailable { .. }
    )
}

/// One pane's title text. NAME is `Fleet` or `Work`; COUNT is the number a fresh pane carries
/// beside its name, and `None` for Work, whose six section headers each carry one already.
fn pane_title<T>(pane: &Pane<T>, name: &str, peer_failed: bool, count: Option<usize>) -> String {
    match &pane.content {
        PaneContent::Loading => name.to_string(),
        PaneContent::Fresh { read_at, .. } => {
            if peer_failed {
                format!("{name} — refreshed {}", clock(*read_at))
            } else {
                match count {
                    Some(count) => format!("{name} {count}"),
                    None => name.to_string(),
                }
            }
        }
        PaneContent::Stale { failed_at, .. } => {
            format!("{name} — stale since {}", clock(*failed_at))
        }
        PaneContent::Unavailable { .. } => format!("{name} unavailable"),
    }
}

/// A pane's title style: status colour always wins over focus, because source health is what the
/// title exists to report. A healthy pane is bold blue only while focused and the ordinary dim
/// style otherwise; a stale or unavailable pane keeps its gold/red colour whether focused or not,
/// gaining only the bold weight focus already gives every title.
fn title_style<T>(pane: &Pane<T>, focused: bool) -> Style {
    if failed(pane) {
        let style = Style::default().fg(pane_color(pane));
        if focused { style.add_modifier(Modifier::BOLD) } else { style }
    } else if focused {
        Style::default().fg(BLUE).add_modifier(Modifier::BOLD)
    } else {
        dim()
    }
}

/// The newest failure on the screen, and whether the pane that suffered it still has something
/// worth reading.
///
/// One headline for two panes, decided while planning cb-vyp.3: the pane titles and bodies
/// already say which source failed, and naming a pane up here wraps the line sooner than the
/// approved header allows. So the header answers the only question it can answer in one clause -
/// how recently something went wrong.
fn newest_failure(app: &App) -> Option<(DateTime<Utc>, bool)> {
    fn of<T>(content: &PaneContent<T>) -> Option<(DateTime<Utc>, bool)> {
        match content {
            PaneContent::Stale { failed_at, .. } => Some((*failed_at, true)),
            PaneContent::Unavailable { failed_at, .. } => Some((*failed_at, false)),
            _ => None,
        }
    }
    let fleet = of(&app.fleet.content);
    let work = of(&app.work.content);
    match (fleet, work) {
        (Some(fleet), Some(work)) => Some(if work.0 > fleet.0 { work } else { fleet }),
        (some, None) | (None, some) => some,
    }
}

/// The lifecycle keys this mode offers, or `None` in read-only - where the header is exactly what
/// it has always been.
///
/// One function so the two hint strings cannot disagree about what they are measuring.
fn lifecycle_hint(mode: &SupervisionMode) -> Option<&'static str> {
    match mode {
        SupervisionMode::Supervising => Some("s/f/k start·finish·kill"),
        // `s` is refused while draining, and `f` and `k` are how a drain ends.
        SupervisionMode::Draining { .. } => Some("f finish | k kill"),
        SupervisionMode::ReadOnly(_) => None,
    }
}

/// The one status line: the title, what is happening right now, and the keys.
///
/// `refreshing...` wins over a retained failure: a navigator looking at a stale pane most wants
/// to know that recovery is already under way, and the pane's own title keeps saying it is
/// stale. `g retry` rather than `g refresh` until BOTH panes are fresh - the key is the same, and
/// what it is for has changed.
fn header_line(app: &App, width: u16) -> Line<'static> {
    // A live session that holds the keyboard replaces the header entirely - the navigator's
    // choice, over keeping a hint line that advertises `q`, `g` and the arrows while none of them
    // reach this screen. Everything else the header carries applies whenever one does not.
    if app.session_has_keyboard() {
        let name = app.selected.clone().unwrap_or_else(|| "The session".to_string());
        return Line::from(Span::raw(format!(
            "{name} has the keyboard | Shift-Tab leaves the session"
        )));
    }
    let mut spans = vec![Span::raw(supervision_title(&app.supervision))];
    // A notice takes the place `refreshing...` or a failure would have had: it is transient, gone
    // on the next keystroke, while a stale pane goes on saying so in its own title anyway. The
    // quit refusal and the kill confirmation come first because both own the keyboard while they
    // are up, and what the keyboard is doing outranks how fresh a pane is.
    if app.quit_refusal.is_some() {
        spans.push(Span::styled(" | quit refused", Style::default().fg(RED)));
    } else if let Some(Prompt::Kill { text, .. }) = &app.confirm {
        spans.push(Span::styled(format!(" | {text}"), Style::default().fg(GOLD)));
    } else if let Some(notice) = &app.notice {
        spans.push(Span::styled(format!(" | {notice}"), Style::default().fg(GOLD)));
    } else if app.fleet.refreshing || app.work.refreshing {
        spans.push(Span::styled(" | refreshing...", dim()));
    } else if let Some((failed_at, stale)) = newest_failure(app) {
        let (text, color) = if stale {
            (format!(" | stale — refresh failed at {}", clock(failed_at)), GOLD)
        } else {
            (format!(" | refresh failed at {}", clock(failed_at)), RED)
        };
        spans.push(Span::styled(text, Style::default().fg(color)));
    } else if let SupervisionMode::Draining { live_sessions, .. } = &app.supervision {
        // How far from done the handoff is - the one thing on screen that says so. A notice takes
        // this slot for one keystroke, which is the cost the navigator accepted (Q6).
        spans.push(Span::styled(
            format!(
                " | {live_sessions} live agent{}",
                if *live_sessions == 1 { "" } else { "s" }
            ),
            Style::default().fg(GOLD),
        ));
    }
    let refresh_key = if failed(&app.fleet) || failed(&app.work) {
        "g retry"
    } else {
        "g refresh"
    };
    // The hints give way before the state does. Ownership made the title up to twenty-eight cells
    // longer (cb-kcs.1), which pushed `q/Esc/Ctrl-C quit` off a hundred-column screen entirely -
    // and a hint the terminal has cut in half is worse than a shorter hint that fits. What is left
    // when it shortens is the two keys a navigator cannot guess from the screen: refresh and quit.
    let used: usize = spans.iter().map(|span| span.content.width()).sum();
    let keys = lifecycle_hint(&app.supervision).map(|k| format!(" | {k}")).unwrap_or_default();
    let full = format!(
        " | Tab/Shift-Tab pane | ↑/↓/PgUp/PgDn move{keys} | {refresh_key} | q/Esc/Ctrl-C quit"
    );
    // Cells, not chars: `·` and the arrows are one cell each here, but the rule is the measure.
    let hints = if used + full.width() <= width as usize {
        full
    } else {
        // The lifecycle keys survive the shortening and the movement hints do not (Q7): the keys
        // that change the fleet outlast the keys that move around it.
        format!("{keys} | {refresh_key} | q/Esc/Ctrl-C quit")
    };
    spans.push(Span::styled(hints, dim()));
    Line::from(spans)
}

/// A title style for a widget that has no reader behind it: bold blue when focused, dim
/// otherwise - the same two spellings `title_style` gives a healthy pane.
fn plain_title_style(focused: bool) -> Style {
    if focused {
        Style::default().fg(BLUE).add_modifier(Modifier::BOLD)
    } else {
        dim()
    }
}

/// The Session pane's title, and the dim hint after it.
///
/// The hint is fixed per session state and never varies with which pane happens to be focused -
/// the navigator's choice (Q9), over the approved mockup's own varying spelling:
///
/// | View                     | Title                     | Hint                          |
/// |--------------------------|---------------------------|-------------------------------|
/// | Live/Starting, unfocused | `<Name> — <phase> <bead>` | `[Tab to focus]`              |
/// | Live/Starting, focused   | `<Name> — <phase> <bead>` | `[Shift-Tab leaves]`          |
/// | Ended                    | `<Name> — ended HH:MM`    | `[retained until next start]` |
/// | None                     | `<Name>`, or `Session`    | none                          |
///
/// The live title's tail comes from the selected fleet row and nothing else (Q7): phase and bead
/// when the row has both, phase alone when it has no bead, and the bare name when it has neither
/// - so the title and the row two panes away can never disagree.
fn session_title(app: &App, focused: bool) -> Line<'static> {
    let name = app.selected.clone().unwrap_or_else(|| "Session".to_string());
    let style = plain_title_style(focused);
    let (title, hint) = match &app.session.view {
        SessionView::None => (name, None),
        SessionView::Live { .. } | SessionView::Starting => (
            live_title(app, &name),
            Some(if focused { "[Shift-Tab leaves]" } else { "[Tab to focus]" }),
        ),
        SessionView::Ended { at, .. } => (
            // A standby row and its pane use one word for one agent (Q1 of cb-kcs.4.1).
            if standby_row(app, &name) {
                format!("{name} — standby")
            } else {
                format!("{name} — ended {}", at.format("%H:%M"))
            },
            Some("[retained until next start]"),
        ),
        // No hint: the body's own last line says what to press, and the red title is the report.
        SessionView::Refused { at, .. } => {
            return Line::from(Span::styled(
                format!("{name} — launch refused {}", at.format("%H:%M")),
                Style::default().fg(RED).add_modifier(Modifier::BOLD),
            ));
        }
    };
    let mut spans = vec![Span::styled(title, style)];
    if let Some(hint) = hint {
        spans.push(Span::styled(format!(" {hint}"), dim()));
    }
    Line::from(spans)
}

/// Is NAME's fleet row on standby?
fn standby_row(app: &App, name: &str) -> bool {
    app.fleet
        .content
        .value()
        .and_then(|rows| rows.iter().find(|row| row.name == name))
        .is_some_and(|row| row.state == RowState::Standby)
}

/// `<Name> — <phase> <bead>`, `<Name> — <phase>`, or `<Name>`, from the selected fleet row.
fn live_title(app: &App, name: &str) -> String {
    let row = app
        .fleet
        .content
        .value()
        .and_then(|rows| rows.iter().find(|row| row.name == name));
    match row.and_then(|row| row.phase.as_deref()) {
        Some(phase) => match row.and_then(|row| row.bead.as_deref()) {
            Some(bead) => format!("{name} — {phase} {bead}"),
            None => format!("{name} — {phase}"),
        },
        None => name.to_string(),
    }
}

/// The Session pane's body.
///
/// `Live` and `Ended` are BORROWED from the view `SessionHost::sync` already materialised - this
/// module builds no terminal screen of its own, which is what keeps it pure, and it must not copy
/// a ten-thousand-line transcript once a frame either. `Starting` is one dim line, and the three
/// bodies below are what `SessionView::None` still produces; both are built here, hence the `Cow`.
///
/// Read-only wins over everything else: a view that does not supervise cannot host a session
/// whatever is selected, and offering `s` there would be a key that does nothing. The wording
/// names nobody deliberately (the navigator's choice) - naming Emacs would need a second spelling
/// for the case where another Ratatui process holds the lease.
fn session_document(app: &App) -> std::borrow::Cow<'_, [Line<'static>]> {
    let line = |text: &str| Line::from(Span::styled(text.to_string(), dim()));
    match &app.session.view {
        SessionView::Live { lines, .. } => return std::borrow::Cow::Borrowed(lines),
        SessionView::Ended { lines, .. } => return std::borrow::Cow::Borrowed(lines.as_slice()),
        // Built when the refusal was recorded, prefix already dropped and closing line appended.
        SessionView::Refused { lines, .. } => return std::borrow::Cow::Borrowed(lines.as_slice()),
        SessionView::Starting => {
            let name = app.selected.clone().unwrap_or_else(|| "the session".to_string());
            return std::borrow::Cow::Owned(vec![line(&format!("Starting {name}…"))]);
        }
        SessionView::None => {}
    }
    if !app.supervision.may_supervise() {
        return std::borrow::Cow::Owned(vec![
            line("Sessions are hosted by the view that supervises this"),
            line("checkout. This one does not."),
        ]);
    }
    std::borrow::Cow::Owned(match &app.selected {
        Some(name) => vec![
            line("No live session."),
            line(""),
            line(&format!("Press s to start {name}.")),
            line("The last completed pass is not available."),
        ],
        // The fleet is empty, loading, or unavailable - and a failed read must keep saying so in
        // the Fleet pane rather than reading as "nothing is wrong" here.
        None => vec![line("No agent selected.")],
    })
}

/// The Fleet pane's body. SELECTED is the index of the highlighted row, when there is one and it
/// is in these rows.
///
/// The shape is `app::fleet_body`'s and this function keeps none of its own: it maps that list
/// one `Line` per element, so the renderer and `App::move_selection` cannot disagree about where
/// a row sits.
fn fleet_document(
    app: &App,
    now: DateTime<Utc>,
    width: u16,
    selected: Option<usize>,
) -> Vec<Line<'static>> {
    let body = crate::app::fleet_body(&app.fleet.content);
    let empty: Vec<FleetRow> = Vec::new();
    let rows = app.fleet.content.value().unwrap_or(&empty);
    let columns = columns(rows, width, &app.standby_labels, &app.exits);
    let inner_width = (width as usize).saturating_sub(2);
    body.iter()
        .map(|entry| {
            fleet_body_line(
                entry,
                rows,
                &columns,
                inner_width,
                now,
                selected,
                &app.exits,
                &app.standby_labels,
            )
        })
        .collect()
}

/// One body line, drawn. Every styling decision the Fleet pane makes lives here; every decision
/// about WHICH lines there are lives in `app::fleet_body`.
fn fleet_body_line(
    entry: &FleetBodyLine,
    rows: &[FleetRow],
    columns: &Columns,
    inner_width: usize,
    now: DateTime<Utc>,
    selected: Option<usize>,
    exits: &BTreeMap<String, LastExit>,
    standby_labels: &BTreeMap<String, String>,
) -> Line<'static> {
    match entry {
        FleetBodyLine::Loading => Line::from(Span::styled("Loading fleet...", dim())),
        FleetBodyLine::RetainedError(error) => {
            Line::from(Span::styled(error.clone(), Style::default().fg(GOLD)))
        }
        FleetBodyLine::Failure(error) => {
            Line::from(Span::styled(error.clone(), Style::default().fg(RED)))
        }
        FleetBodyLine::Blank => Line::from(""),
        FleetBodyLine::NoSnapshot => Line::from("No fleet snapshot is available."),
        FleetBodyLine::Retry => Line::from("Press g to retry."),
        FleetBodyLine::StaleTrailer => Line::from(Span::styled(
            "The last successful fleet snapshot remains visible.",
            dim(),
        )),
        FleetBodyLine::Heading => heading(columns),
        FleetBodyLine::Row(index) => {
            let row = &rows[*index];
            let mut line = row_line(
                row,
                now,
                columns,
                exits.get(&row.name).copied(),
                (row.state == RowState::Standby)
                    .then(|| standby_labels.get(&row.name).map(String::as_str))
                    .flatten(),
            );
            if selected == Some(*index) {
                // Padded across the pane's whole inner width so the highlight is a band rather
                // than a ragged one. A Line-level style sits BENEATH each span's own, so the row
                // keeps its green/gold/red - which reversed video would have taken away.
                let used: usize = line.spans.iter().map(|span| span.content.width()).sum();
                let gap = inner_width.saturating_sub(used);
                if gap > 0 {
                    line.spans.push(Span::raw(pad_cells("", gap)));
                }
                line = line.style(Style::default().bg(SELECTED_BG));
            }
            line
        }
        // A malformed state file gets its parser's own words, on its own line, rather than a
        // pane-wide failure: one unreadable file must not hide eighteen readable rows.
        FleetBodyLine::Diagnostic(index) => Line::from(vec![
            Span::raw("  "),
            Span::styled(
                rows[*index]
                    .diagnostic
                    .clone()
                    .expect("a Diagnostic line is only emitted for a row that has one"),
                Style::default().fg(RED),
            ),
        ]),
    }
}

/// The Work pane's body, in the same four shapes the Fleet pane has - and with the same rule
/// under them: a failed refresh never destroys queues that are still worth reading.
fn work_document(app: &App, now: DateTime<Utc>, width: usize) -> Vec<Line<'static>> {
    match &app.work.content {
        PaneContent::Loading => vec![Line::from(Span::styled("Loading work...", dim()))],
        PaneContent::Fresh { value, .. } => work_lines(value, now, width),
        PaneContent::Stale { value, error, .. } => {
            let mut lines = vec![
                Line::from(Span::styled(error.clone(), Style::default().fg(GOLD))),
                Line::from(""),
            ];
            lines.extend(work_lines(value, now, width));
            lines.push(Line::from(""));
            lines.push(Line::from(Span::styled(
                "The last successful work snapshot remains visible.",
                dim(),
            )));
            lines
        }
        PaneContent::Unavailable { error, .. } => vec![
            Line::from(Span::styled(error.clone(), Style::default().fg(RED))),
            Line::from(""),
            Line::from("No work snapshot is available."),
            Line::from("Press g to retry."),
        ],
    }
}

/// How a section orders its rows and what it puts at the far end of one.
#[derive(Clone, Copy, PartialEq, Eq)]
enum SectionKind {
    /// Priority, then id: P0 reads first, and a tie does not shuffle between redraws.
    Open,
    /// `Open`'s order, plus how long the bead has been waiting for a person.
    Paused,
    /// Newest first. Priority says nothing about finished work - a merged P3 is no less done
    /// than a merged P0 - so this section answers "what just landed" instead.
    Merged,
}

/// The six queues, in the order work moves in read backwards, and in the panel's own spelling.
///
/// Exactly the sections `cerebro--bead-panel` shows, minus the two that are Emacs's alone: this
/// view has no sweeps to act on and no history to keep.
fn work_lines(buckets: &WorkBuckets, now: DateTime<Utc>, width: usize) -> Vec<Line<'static>> {
    let sections: [(&str, &Vec<Bead>, SectionKind); 6] = [
        ("Claimed", &buckets.claimed, SectionKind::Open),
        ("Planned, unclaimed", &buckets.planned, SectionKind::Open),
        ("Being planned", &buckets.being_planned, SectionKind::Open),
        ("Unplanned", &buckets.unplanned, SectionKind::Open),
        ("Waiting on you", &buckets.paused, SectionKind::Paused),
        ("Merged, unverified", &buckets.merged, SectionKind::Merged),
    ];
    let mut lines = Vec::new();
    for (index, (title, beads, kind)) in sections.into_iter().enumerate() {
        if index > 0 {
            lines.push(Line::from(""));
        }
        lines.extend(work_section(title, beads, kind, now, width));
    }
    lines
}

/// One section: its title with the FULL count, then at most eight rows, then what is left.
///
/// The count is on the header rather than implied by the rows, because the rows are the part
/// that gets capped - and a section whose remainder is hidden still has to say how much work is
/// really in it.
fn work_section(
    title: &str,
    beads: &[Bead],
    kind: SectionKind,
    now: DateTime<Utc>,
    width: usize,
) -> Vec<Line<'static>> {
    let sorted = match kind {
        SectionKind::Merged => sorted_by_recency(beads),
        SectionKind::Open | SectionKind::Paused => sorted_by_priority(beads),
    };
    let mut lines = vec![Line::from(Span::styled(
        format!("{title} {}", sorted.len()),
        Style::default().add_modifier(Modifier::BOLD),
    ))];
    if sorted.is_empty() {
        lines.push(Line::from(Span::styled("  (none)", dim())));
        return lines;
    }
    for bead in sorted.iter().take(WORK_ROWS_PER_SECTION) {
        let suffix = (kind == SectionKind::Paused).then(|| paused_age(bead, now));
        lines.push(work_row(bead, width, suffix.as_deref()));
    }
    let hidden = sorted.len().saturating_sub(WORK_ROWS_PER_SECTION);
    if hidden > 0 {
        lines.push(Line::from(Span::styled(format!("  +{hidden} more"), dim())));
    }
    lines
}

fn sorted_by_priority(beads: &[Bead]) -> Vec<&Bead> {
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

fn sorted_by_recency(beads: &[Bead]) -> Vec<&Bead> {
    let mut sorted: Vec<&Bead> = beads.iter().collect();
    // Undated last, and the id breaks every tie: this list is redrawn on a timer, and one that
    // reorders under the navigator's eyes is unreadable.
    sorted.sort_by(|a, b| {
        match (a.updated_at, b.updated_at) {
            (Some(a), Some(b)) => b.cmp(&a),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => Ordering::Equal,
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
fn paused_age(bead: &Bead, now: DateTime<Utc>) -> String {
    let age = elapsed(bead.paused_at(), now);
    if age.is_empty() {
        "—".to_string()
    } else {
        age
    }
}

/// One bead row, fitted to WIDTH terminal cells.
///
/// `  cb-123  P1 Some title`, exactly as `cerebro--bead-line` builds it. A bead whose last
/// verification failed replaces the two-space indent with `↻ ` - two cells either way, so the id
/// and title columns of the ordinary rows beside it do not move.
///
/// Only the title is ever cut: the prefix is what makes the rows a column, and a truncated id
/// would be worse than a truncated title in every case. SUFFIX, when given, is right-aligned
/// after two separating spaces and takes its room before the title does.
fn work_row(bead: &Bead, width: usize, suffix: Option<&str>) -> Line<'static> {
    let reopened = bead.labels.iter().any(|l| l == "verification:failed");
    let priority = bead
        .priority
        .map(|p| p.to_string())
        .unwrap_or_else(|| "?".to_string());
    let prefix = format!(
        "{}{} P{priority} ",
        if reopened { "↻ " } else { "  " },
        pad_cells(&bead.id, 7),
    );
    let reserved = suffix.map(|s| s.width() + 2).unwrap_or(0);
    let room = width
        .saturating_sub(prefix.width() + reserved)
        .max(8);
    let title = truncate_cells(&bead.title, room);
    match suffix {
        Some(suffix) => {
            let gap = room.saturating_sub(title.width());
            Line::from(format!("{prefix}{title}{}  {suffix}", " ".repeat(gap)))
        }
        None => Line::from(format!("{prefix}{title}")),
    }
}

/// TEXT padded to WIDTH terminal cells, never cut: a bead id is a key, not a label.
fn pad_cells(text: &str, width: usize) -> String {
    let used = text.width();
    if used >= width {
        return text.to_string();
    }
    format!("{text}{}", " ".repeat(width - used))
}

/// TEXT cut to WIDTH terminal CELLS, ending in the Unicode ellipsis when something was removed.
///
/// Cells rather than bytes or `char`s: a title carrying a wide glyph would otherwise overflow the
/// pane and push the border off the row, and a bytewise cut would split one in half.
fn truncate_cells(text: &str, width: usize) -> String {
    if text.width() <= width {
        return text.to_string();
    }
    if width == 0 {
        return String::new();
    }
    let mut kept = String::new();
    let mut used = 0;
    for character in text.chars() {
        let cell = character.to_string().width();
        if used + cell > width - 1 {
            break;
        }
        kept.push(character);
        used += cell;
    }
    kept.push('…');
    kept
}

struct Columns {
    agent: usize,
    role: usize,
    state: usize,
    bead: usize,
    wide: bool,
}

/// Column widths from the data, with this project's floors - the same rule
/// `cerebro--column-widths` follows, and for the same reason: a width is a fact about the roster
/// in front of the navigator, not a setting they should have to find.
/// The standby labels are passed in because they occupy the BEAD column too: `→ buffer<10` is
/// eleven cells and the column takes them, since it sizes to its widest entry and only falls back
/// to the floor when the pane cannot spare more.
fn columns(
    rows: &[FleetRow],
    width: u16,
    standby_labels: &BTreeMap<String, String>,
    exits: &BTreeMap<String, LastExit>,
) -> Columns {
    let longest = |values: Vec<usize>| values.into_iter().max().unwrap_or(0);
    let natural_agent = AGENT_FLOOR.max(2 + longest(rows.iter().map(|r| r.name.chars().count()).collect()));
    let natural_role = ROLE_FLOOR.max(1 + longest(rows.iter().map(|r| r.role.chars().count()).collect()));
    let natural_bead = BEAD_FLOOR.max(
        1 + longest(
            rows.iter()
                .map(|r| {
                    // The cell this row will actually SHOW, from the one function that decides
                    // it. `✗ 5 failed starts` is seventeen cells and `↻ retry in 30s, 2 failed`
                    // twenty-four, where a column measured from `FleetRow::bead` alone is ten.
                    bead_cell(
                        r,
                        exits.get(&r.name).copied(),
                        standby_labels.get(&r.name).map(String::as_str),
                    )
                    .text()
                    .width()
                })
                .collect(),
        ),
    );
    let wide = width >= WIDE_COLUMNS;
    let fixed = if wide { STATE_FLOOR + natural_role + 4 } else { STATE_FLOOR + 1 };
    let agent = natural_agent.min((width as usize).saturating_sub(fixed + natural_bead).max(AGENT_FLOOR));
    let bead = natural_bead.min((width as usize).saturating_sub(fixed + agent).max(BEAD_FLOOR));
    let role = natural_role.min((width as usize).saturating_sub(STATE_FLOOR + agent + bead + 4).max(ROLE_FLOOR));
    Columns {
        agent,
        role,
        state: STATE_FLOOR,
        bead,
        wide,
    }
}

fn heading(columns: &Columns) -> Line<'static> {
    let mut text = String::from("  ");
    text.push_str(&pad("AGENT", columns.agent - 2));
    if columns.wide {
        text.push_str(&pad("ROLE", columns.role));
    }
    text.push_str(&pad("STATE", columns.state));
    text.push_str(&pad("BEAD", columns.bead));
    if columns.wide {
        text.push_str("FOR");
    }
    Line::from(Span::styled(
        text.trim_end().to_string(),
        Style::default().add_modifier(Modifier::BOLD),
    ))
}

fn pad(text: &str, width: usize) -> String {
    let mut out = truncate(text, width);
    let used = out.chars().count();
    if used < width {
        out.push_str(&" ".repeat(width - used));
    }
    out
}

/// TEXT cut to WIDTH, ending in an ellipsis when something was removed - `cerebro--truncate`'s
/// rule, so a long bead id is visibly cut rather than pushing the rest of the row off the screen.
fn truncate(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    if width == 0 {
        return String::new();
    }
    let kept: String = text.chars().take(width - 1).collect();
    format!("{kept}…")
}

/// The glyph and its colour, straight from `cerebro--glyph`.
fn glyph(state: &RowState) -> Span<'static> {
    match state {
        RowState::Working | RowState::Up => Span::styled("●", Style::default().fg(GREEN)),
        RowState::Asking => Span::styled("?", Style::default().fg(GOLD).add_modifier(Modifier::BOLD)),
        RowState::Waiting => Span::styled("◐", Style::default().fg(GOLD)),
        RowState::Idle => Span::styled("◆", Style::default().fg(BLUE)),
        RowState::Unknown(_) => Span::styled("●", Style::default().fg(GOLD)),
        RowState::Invalid => Span::styled("!", Style::default().fg(RED)),
        RowState::Dead => Span::styled("○", dim()),
        // Hollow rather than the filled diamond `Idle` gets, and blue rather than `Dead`'s grey:
        // somebody IS coming back, so it is not grey's "nobody is there", and nothing is running
        // here, where an idle agent has a session up with no bead.
        RowState::Standby => Span::styled("◌", Style::default().fg(BLUE)),
    }
}

/// The State column's word, from `cerebro--state-label`: a working agent shows its phase, an
/// `asking` one always shows `asking`, and a word this view does not know is shown verbatim
/// rather than translated into a lie.
fn state_label(row: &FleetRow) -> String {
    match &row.state {
        RowState::Unknown(raw) => truncate(raw, 10),
        RowState::Working => row.phase.clone().unwrap_or_else(|| "working".to_string()),
        RowState::Asking => "asking".to_string(),
        RowState::Waiting => "waiting".to_string(),
        RowState::Idle => "idle".to_string(),
        RowState::Up => "up".to_string(),
        RowState::Dead => "dead".to_string(),
        RowState::Standby => "standby".to_string(),
        RowState::Invalid => "invalid".to_string(),
    }
}

/// `12m`, `1h03` or `2d` - `cerebro--elapsed`, to the character, including the empty string for a
/// time the state file did not give.
fn elapsed(since: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    let Some(since) = since else {
        return String::new();
    };
    let seconds = (now - since).num_seconds().max(0);
    if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h{:02}", seconds / 3600, (seconds % 3600) / 60)
    } else {
        format!("{}d", seconds / 86_400)
    }
}

/// The For column: time on the bead and time in the phase, one space between them
/// (`cerebro--for-column`).
fn for_column(row: &FleetRow, now: DateTime<Utc>) -> String {
    let bead_time = elapsed(row.since, now);
    let phase_time = elapsed(row.phase_since, now);
    match (bead_time.is_empty(), phase_time.is_empty()) {
        (_, true) => bead_time,
        (true, false) => phase_time,
        (false, false) => format!("{bead_time} {phase_time}"),
    }
}

fn emphasized(style: Style, attention: bool) -> Style {
    if attention {
        style.add_modifier(Modifier::BOLD)
    } else {
        style
    }
}

/// The BEAD cell a row will show, and what it is - because `row_line` draws it and `columns`
/// sizes the column to it, and two copies of this rule are how a column comes to be sized for a
/// cell the row does not draw.
///
/// A row shows a bead, or a verdict, or a standby condition, and never two. WHICH is decided by
/// the state first, the way `cerebro--entry` decides it: a `Standby` row shows its condition or
/// its countdown even when it still carries an exit record, since cb-kcs.4.2 restates a silent
/// crash as `Standby` to be retried on the backoff and the countdown is what that row is there to
/// say. **A standby row with no condition at all falls back to the verdict**: `standby_label`
/// answers `None` for every role without a board trigger, and a `standby` roster row of one of
/// those that crashed would otherwise draw an empty cell - a failure made invisible, and one no
/// backoff will ever retry.
fn bead_cell<'a>(
    row: &'a FleetRow,
    exit: Option<LastExit>,
    standby_label: Option<&'a str>,
) -> BeadCell {
    if row.state == RowState::Standby {
        if let Some(label) = standby_label {
            return BeadCell::Standby(label.to_string());
        }
    }
    match exit {
        Some(exit) => BeadCell::Verdict(crate::lifecycle::verdict(exit)),
        None => BeadCell::Bead(row.bead.clone().unwrap_or_default()),
    }
}

/// One of the three things the BEAD column ever holds. The variant is the colour.
enum BeadCell {
    Bead(String),
    Verdict(String),
    Standby(String),
}

impl BeadCell {
    fn text(&self) -> &str {
        match self {
            BeadCell::Bead(text) | BeadCell::Verdict(text) | BeadCell::Standby(text) => text,
        }
    }

    fn colour(&self) -> Style {
        match self {
            BeadCell::Bead(_) => Style::default(),
            BeadCell::Verdict(_) => Style::default().fg(RED),
            BeadCell::Standby(_) => Style::default().fg(BLUE),
        }
    }
}

fn row_line(
    row: &FleetRow,
    now: DateTime<Utc>,
    columns: &Columns,
    exit: Option<LastExit>,
    standby_label: Option<&str>,
) -> Line<'static> {
    // Bold is the row-level signal, and it is spent on exactly one state: an agent waiting for an
    // answer from the navigator (`cerebro--wants-attention-p`).
    let attention = row.state == RowState::Asking;
    let invalid = row.state == RowState::Invalid;
    let name_style = if invalid {
        Style::default().fg(RED)
    } else {
        Style::default()
    };

    let mut spans = vec![glyph(&row.state), Span::raw(" ")];
    spans.push(Span::styled(
        pad(&row.name, columns.agent - 2),
        emphasized(name_style, attention),
    ));
    if columns.wide {
        spans.push(Span::styled(
            pad(&row.role, columns.role),
            emphasized(Style::default(), attention),
        ));
    }
    spans.extend(state_spans(row, columns, invalid, attention));
    // The BEAD column carries a bead id or a verdict and never both: an agent with a bead in
    // flight is not one that has exited. The verdict is red on a row that is otherwise dim, and a
    // span of its own, so the selection band sits beneath it and the colour survives being
    // selected - the rule the state glyph already follows.
    // `bead_cell` is the one place the three are chosen between; a verdict and a standby
    // condition each get a span of their own so the selection band sits beneath the colour.
    let cell = bead_cell(row, exit, standby_label);
    spans.push(Span::styled(
        pad(cell.text(), columns.bead),
        emphasized(cell.colour(), attention),
    ));
    if columns.wide {
        spans.push(Span::styled(
            for_column(row, now),
            emphasized(Style::default(), attention),
        ));
    }
    Line::from(spans)
}

/// The State cell: the word, then the two qualifications Emacs shows in the same order - a dim
/// ` ?` when the pid names this agent but not this consumer's root, and a gold ` ×N` when more
/// than one session of the name is up (`cerebro--entry`).
fn state_spans(
    row: &FleetRow,
    columns: &Columns,
    invalid: bool,
    attention: bool,
) -> Vec<Span<'static>> {
    let label = state_label(row);
    let unverified = row.diagnostic.is_some() && !invalid;
    let word_style = if invalid {
        Style::default().fg(RED)
    } else {
        Style::default()
    };

    let mut used = label.chars().count();
    let mut spans = vec![Span::styled(label, emphasized(word_style, attention))];
    if unverified {
        spans.push(Span::styled(" ?", dim()));
        used += 2;
    }
    if row.sessions > 1 {
        let count = format!(" ×{}", row.sessions);
        used += count.chars().count();
        spans.push(Span::styled(count, Style::default().fg(GOLD)));
    }
    let padding = columns.state.saturating_sub(used).max(1);
    spans.push(Span::raw(" ".repeat(padding)));
    spans
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::Prompt;
    use crate::model::AgentKind;
    use crate::readers::ReadError;
    use std::time::Instant;
    use ratatui::backend::TestBackend;
    use ratatui::buffer::Buffer;
    use ratatui::Terminal;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_767_225_600 + seconds, 0).expect("a valid timestamp")
    }

    fn now() -> DateTime<Utc> {
        at(86_400)
    }

    fn row(name: &str, role: &str, state: RowState) -> FleetRow {
        FleetRow {
            name: name.into(),
            role: role.into(),
            kind: AgentKind::Interactive,
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

    fn working(name: &str, role: &str, phase: &str, bead: &str) -> FleetRow {
        FleetRow {
            phase: Some(phase.into()),
            bead: Some(bead.into()),
            since: Some(now() - chrono::Duration::minutes(18)),
            phase_since: Some(now() - chrono::Duration::minutes(18)),
            pid: Some(4242),
            sessions: 1,
            ..row(name, role, RowState::Working)
        }
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

    fn render(app: &App, width: u16, height: u16) -> Buffer {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal.draw(|frame| draw(frame, app, now())).unwrap();
        terminal.backend().buffer().clone()
    }

    fn lines(buffer: &Buffer) -> Vec<String> {
        let area = buffer.area;
        (0..area.height)
            .map(|y| {
                (0..area.width)
                    .map(|x| {
                        buffer
                            .cell((x, y))
                            .map(|c| c.symbol())
                            .unwrap_or(" ")
                            .to_string()
                    })
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    /// Each pane's own border stripped off: a top border row becomes exactly the title text it
    /// carries, a bottom border row (which carries nothing) disappears, and every other row keeps
    /// its content with the left/right border cell taken off each end. The header row, which
    /// carries no border at all, passes through untouched. This is what makes the rest of this
    /// module's assertions read like the single scrollable document the screen used to be, even
    /// though Fleet and Work are now two independently bordered widgets.
    fn body(buffer: &Buffer) -> Vec<String> {
        lines(buffer)
            .into_iter()
            .filter_map(|line| {
                if line.starts_with(['└', '┗']) {
                    None
                } else if line.starts_with(['┌', '┏']) {
                    Some(border_title(&line))
                } else if line.starts_with(['│', '┃']) {
                    Some(strip_sides(&line))
                } else {
                    Some(line)
                }
            })
            .collect()
    }

    /// The title text a top border row carries: everything between the corner and the run of
    /// horizontal border glyphs that fills the rest of the row.
    fn border_title(line: &str) -> String {
        let stripped = line.trim_start_matches(['┌', '┏']);
        let end = stripped
            .find(['─', '━', '┐', '┓'])
            .unwrap_or(stripped.len());
        stripped[..end].to_string()
    }

    fn strip_sides(line: &str) -> String {
        line.trim_start_matches(['│', '┃'])
            .trim_end_matches(['│', '┃'])
            .trim_end()
            .to_string()
    }

    fn line_with<'a>(rendered: &'a [String], needle: &str) -> &'a String {
        rendered.iter().find(|line| line.contains(needle)).unwrap_or_else(|| {
            panic!("no line contains {needle:?}; screen was:\n{}", rendered.join("\n"))
        })
    }

    /// The index of the first rendered line containing NEEDLE, so an order can be asserted
    /// without a whitespace snapshot of the whole frame.
    fn index_of(rendered: &[String], needle: &str) -> usize {
        rendered
            .iter()
            .position(|line| line.contains(needle))
            .unwrap_or_else(|| {
                panic!("no line contains {needle:?}; screen was:\n{}", rendered.join("\n"))
            })
    }

    /// A row that is not running carries WHY in the BEAD column, in red - the navigator's choice
    /// (Q1, variant C): one line per agent at every width, so a nineteen-name roster still fits
    /// and a bad morning is a column you can read down, and a fleet where three things went wrong
    /// never looks identical to a fleet nobody started.
    #[test]
    fn a_dead_row_carries_its_verdict_in_the_bead_column() {
        for (width, height) in [(120u16, 24u16), (80, 30)] {
            let mut app = App::default();
            app.finish_refresh(
                Ok(vec![
                    row("Storm", "implementer", RowState::Dead),
                    row("Rogue", "implementer", RowState::Dead),
                    row("Gambit", "implementer", RowState::Dead),
                ]),
                now(),
            );
            app.set_exits(
                [
                    ("Storm".to_string(), LastExit::Refused),
                    ("Rogue".to_string(), LastExit::Code(137)),
                ]
                .into_iter()
                .collect(),
            );
            app.selected = Some("Storm".to_string());

            let buffer = render(&app, width, height);
            let rendered = body(&buffer);
            assert!(
                line_with(&rendered, "Storm").contains("✗ refused"),
                "at {width}: {rendered:?}"
            );
            assert!(
                line_with(&rendered, "Rogue").contains("✗ code 137"),
                "at {width}: {rendered:?}"
            );
            // A name with no abnormal exit says nothing at all: a blank BEAD column is what
            // "nobody has started it" looks like, and that is the truth for this one.
            assert!(
                !line_with(&rendered, "Gambit").contains('✗'),
                "at {width}: {rendered:?}"
            );

            // Red, and its own span, so the selection band sits BENEATH it - the rule the state
            // glyph already follows.
            let verdict_cell = style_of(&buffer, "✗");
            assert_eq!(verdict_cell.fg, Some(RED), "at {width}");
            assert_eq!(
                verdict_cell.bg,
                Some(SELECTED_BG),
                "the selected row's verdict keeps its red under the band, at {width}"
            );
        }
    }

    /// The style of the first cell whose symbol is NEEDLE.
    fn style_of(buffer: &Buffer, needle: &str) -> Style {
        let area = buffer.area;
        for y in 0..area.height {
            for x in 0..area.width {
                if let Some(cell) = buffer.cell((x, y)) {
                    if cell.symbol() == needle {
                        return Style::default()
                            .fg(cell.fg)
                            .bg(cell.bg)
                            .add_modifier(cell.modifier);
                    }
                }
            }
        }
        panic!("no cell carries {needle:?}");
    }

    /// The style of the first cell of NEEDLE, wherever it is on the screen. Cell-for-character,
    /// which every string asserted here is.
    fn style_where(buffer: &Buffer, needle: &str) -> Style {
        let rendered = lines(buffer);
        let y = index_of(&rendered, needle) as u16;
        let x = rendered[y as usize]
            .char_indices()
            .position(|(index, _)| rendered[y as usize][index..].starts_with(needle))
            .expect("the needle is on that line") as u16;
        let cell = buffer.cell((x, y)).expect("a cell inside the frame");
        Style::default()
            .fg(cell.fg)
            .bg(cell.bg)
            .add_modifier(cell.modifier)
    }

    fn populated() -> App {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![
                working("Xavier", "planner", "plan", "cb-kcs"),
                FleetRow {
                    since: Some(now() - chrono::Duration::minutes(4)),
                    ..row("Cerebro", "orchestrator", RowState::Asking)
                },
                row("Moira", "user-feedback", RowState::Idle),
                row("Psylocke", "verifier", RowState::Dead),
                FleetRow {
                    since: Some(now()),
                    ..row("Storm", "implementer", RowState::Waiting)
                },
            ]),
            at(86_400),
        );
        app
    }

    fn bead(id: &str, priority: Option<u8>, title: &str) -> Bead {
        Bead {
            id: id.into(),
            title: title.into(),
            status: "open".into(),
            issue_type: "feature".into(),
            labels: vec![],
            priority,
            updated_at: None,
            assignee: None,
            metadata: serde_json::Value::Null,
            external_ref: None,
        }
    }

    fn work_app(buckets: WorkBuckets) -> App {
        let mut app = App::new();
        app.finish_work_refresh(Ok(buckets), at(86_400));
        app
    }

    /// `populated()`, but owning supervision - what a project declaring `fleet_supervisor tui`
    /// gets, and the only mode in which the Session pane offers to start anything.
    fn supervising() -> App {
        let mut app = populated();
        app.set_supervision(SupervisionMode::Supervising);
        app
    }

    /// A view told to hand over, still hosting SESSIONS - where `s` is refused and `f`/`k` are not.
    fn handing_over(sessions: usize) -> App {
        let mut app = populated();
        app.set_supervision(SupervisionMode::Draining {
            configured_for: Some(SupervisorKind::Emacs),
            live_sessions: sessions,
        });
        app
    }

    /// Both panes populated with enough rows that each needs to scroll on its own - the fixture
    /// the pane-independence and range-cue cases share.
    fn both_populated() -> App {
        let mut app = populated();
        app.finish_work_refresh(
            Ok(WorkBuckets {
                claimed: vec![bead("cb-123", Some(1), "Preserve session output")],
                unplanned: (1..=10)
                    .map(|n| bead(&format!("cb-{n:03}"), Some(1), &format!("item {n}")))
                    .collect(),
                ..WorkBuckets::default()
            }),
            at(86_400),
        );
        app
    }


    /// A `Live` view of three lines, so no case has to build a parser.
    fn live(app: &mut App, texts: &[&str]) {
        app.set_session_view(SessionView::Live {
            lines: texts.iter().map(|text| Line::from(text.to_string())).collect(),
            cursor: (1, 3),
        });
    }

    /// An `Ended` view long enough to need the range cue.
    fn ended(app: &mut App, count: usize) {
        app.set_session_view(SessionView::Ended {
            lines: std::sync::Arc::new(
                (1..=count).map(|n| Line::from(format!("retained {n}"))).collect(),
            ),
            at: at(56_520), // 15:42 UTC
        });
    }

    #[test]
    fn the_session_pane_draws_a_live_child() {
        let mut app = supervising();
        app.selected = Some("Xavier".to_string());
        live(&mut app, &["$ bd ready", "cb-kcs.2.2 claimed", "building"]);
        // `lines' rather than `body': in the split layout the Session pane's own border row is
        // drawn beside the Fleet pane's, and `body' keeps only the leftmost title.
        let rendered = lines(&render(&app, 120, 20));
        assert!(rendered.iter().any(|line| line.contains("cb-kcs.2.2 claimed")), "{rendered:?}");
        assert!(
            rendered.iter().any(|line| line.contains("Xavier — plan cb-kcs [Tab to focus]")),
            "{rendered:?}"
        );
    }

    #[test]
    fn a_starting_session_says_so() {
        let mut app = supervising();
        app.selected = Some("Xavier".to_string());
        app.set_session_view(SessionView::Starting);
        let buffer = render(&app, 120, 20);
        assert!(lines(&buffer).iter().any(|line| line.contains("Starting Xavier…")), "{:?}", lines(&buffer));
        // `style_where`, not `style_of`: the latter takes the first `S` anywhere on the buffer,
        // which was the header's `Shift-Tab` until the supervising header's lifecycle keys pushed
        // that hint off a 120-column screen. The assertion always meant this line.
        assert!(style_where(&buffer, "Starting Xavier…").add_modifier.contains(Modifier::DIM));
    }

    #[test]
    fn an_ended_pass_is_titled_by_its_time_and_scrolls() {
        let mut app = supervising();
        app.selected = Some("Xavier".to_string());
        ended(&mut app, 60);
        let rendered = lines(&render(&app, 120, 20));
        assert!(
            rendered.iter().any(|line| line.contains("Xavier — ended 15:42 [retained until next start]")),
            "{rendered:?}"
        );
        // Long enough that `render_pane` treats it like any other clipped body.
        assert!(rendered.iter().any(|line| line.contains("Rows 1–")), "{rendered:?}");
    }

    #[test]
    fn a_live_session_title_falls_back_through_phase_and_name() {
        let mut app = supervising();
        app.selected = Some("Xavier".to_string());
        live(&mut app, &["x"]);
        assert!(session_title(&app, false).to_string().starts_with("Xavier — plan cb-kcs"));

        // A phase and no bead.
        app.finish_refresh(
            Ok(vec![FleetRow { bead: None, ..working("Cerebro", "orchestrator", "triage", "cb-1") }]),
            at(86_400),
        );
        app.selected = Some("Cerebro".to_string());
        assert!(session_title(&app, false).to_string().starts_with("Cerebro — triage"));

        // Neither.
        app.finish_refresh(Ok(vec![row("Moira", "user-feedback", RowState::Working)]), at(86_400));
        app.selected = Some("Moira".to_string());
        assert!(session_title(&app, false).to_string().starts_with("Moira"));
        assert!(!session_title(&app, false).to_string().contains('—'));
    }

    #[test]
    fn the_session_pane_still_says_why_there_is_no_session() {
        // Read-only, which is what every consumer sees today.
        let rendered = lines(&render(&populated(), 120, 20));
        assert!(
            rendered.iter().any(|line| line.contains("Sessions are hosted by the view")),
            "{rendered:?}"
        );

        // Supervising, with a selection.
        let mut app = supervising();
        app.selected = Some("Xavier".to_string());
        let rendered = lines(&render(&app, 120, 20));
        assert!(rendered.iter().any(|line| line.contains("Press s to start Xavier.")), "{rendered:?}");

        // Supervising, with none.
        let mut app = supervising();
        app.selected = None;
        let rendered = lines(&render(&app, 120, 20));
        assert!(rendered.iter().any(|line| line.contains("No agent selected.")), "{rendered:?}");
    }


    #[test]
    fn a_focused_live_session_replaces_the_header() {
        let mut app = supervising();
        app.selected = Some("Xavier".to_string());
        app.focus = PaneFocus::Session;
        live(&mut app, &["building"]);
        let rendered = lines(&render(&app, 120, 20));
        assert_eq!(rendered[0], "Xavier has the keyboard | Shift-Tab leaves the session");

        // Unfocused, the ordinary header is back untouched - ownership span, hints and all.
        app.focus = PaneFocus::Fleet;
        let rendered = lines(&render(&app, 120, 20));
        assert!(rendered[0].starts_with("Cerebro — supervising"), "{:?}", rendered[0]);
        assert!(rendered[0].contains("q/Esc/Ctrl-C quit"), "{:?}", rendered[0]);
    }

    #[test]
    fn the_cursor_is_placed_only_while_the_session_has_the_keyboard() {
        let mut app = supervising();
        app.selected = Some("Xavier".to_string());
        live(&mut app, &["one", "two", "three"]);

        app.focus = PaneFocus::Session;
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        terminal.draw(|frame| draw(frame, &app, now())).unwrap();
        let focused = terminal.get_cursor_position().unwrap();
        // The session pane starts at column LEFT_COLUMN in the split layout, one row under the
        // header, and the view's cursor is (1, 3) inside it.
        assert_eq!((focused.x, focused.y), (LEFT_COLUMN + 1 + 3, 1 + 1 + 1));

        app.focus = PaneFocus::Fleet;
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        terminal.draw(|frame| draw(frame, &app, now())).unwrap();
        let unfocused = terminal.get_cursor_position().unwrap();
        assert_ne!(
            (unfocused.x, unfocused.y),
            (focused.x, focused.y),
            "an unfocused pane must not move the terminal cursor into the child"
        );
    }

    #[test]
    fn renders_the_approved_wide_fleet_screen() {
        let app = populated();
        let buffer = render(&app, 100, 20);
        let rendered = lines(&buffer);

        assert!(rendered[0].starts_with("Cerebro — read-only"), "{:?}", rendered[0]);
        assert!(rendered[0].contains("g refresh"), "{:?}", rendered[0]);
        assert!(rendered[0].contains("q/Esc/Ctrl-C quit"), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("refreshing..."), "nothing is in flight");
        assert!(line_with(&rendered, "Fleet 5").contains("Fleet 5"), "the pane counts its rows");

        // The screen is split: the fleet lives in a `LEFT_COLUMN`-wide column, so it shows the
        // narrow three-column table rather than the five-column one. The navigator chose that
        // (a fixed left column, the session taking the rest) over half and half, which would
        // have kept ROLE and FOR at the cost of the session's width.
        let heading = line_with(&rendered, "AGENT");
        for column in ["AGENT", "STATE", "BEAD"] {
            assert!(heading.contains(column), "the narrow heading shows {column}: {heading:?}");
        }
        assert!(!heading.contains("ROLE"), "and not the wide ones: {heading:?}");

        let xavier = line_with(&rendered, "● Xavier");
        assert!(xavier.contains("● Xavier"), "{xavier:?}");
        assert!(xavier.contains("plan "), "a working row shows its phase: {xavier:?}");
        assert!(xavier.contains("cb-kcs"), "{xavier:?}");

        let cerebro = line_with(&rendered, "? Cerebro");
        assert!(cerebro.contains("asking"), "{cerebro:?}");
        let moira = line_with(&rendered, "Moira");
        assert!(moira.contains("◆ Moira") && moira.contains("idle"), "{moira:?}");
        let psylocke = line_with(&rendered, "Psylocke");
        assert!(psylocke.contains("○ Psylocke") && psylocke.contains("dead"), "{psylocke:?}");
        let storm = line_with(&rendered, "Storm");
        assert!(storm.contains("◐ Storm") && storm.contains("waiting"), "{storm:?}");

        // The third pane is there, and it says why it holds no session.
        assert!(
            line_with(&rendered, "Sessions are hosted by").contains("supervises this"),
            "{rendered:?}"
        );

        // The glyph colours are the Emacs vocabulary, and `asking' is the one bold row.
        assert_eq!(style_of(&buffer, "●").fg, Some(GREEN));
        assert_eq!(style_of(&buffer, "◆").fg, Some(BLUE));
        assert_eq!(style_of(&buffer, "◐").fg, Some(GOLD));
        let asking = style_of(&buffer, "?");
        assert_eq!(asking.fg, Some(GOLD));
        assert!(asking.add_modifier.contains(Modifier::BOLD));

        // Two draws of one App at one `now' are byte-stable.
        assert_eq!(lines(&render(&app, 100, 20)), rendered);
    }

    #[test]
    fn loading_and_refreshing_are_explicit() {
        let app = App::new();
        let rendered = lines(&render(&app, 100, 20));
        assert!(line_with(&rendered, "Loading fleet...").contains("Loading fleet..."));
        assert!(!rendered[0].contains("refreshing..."), "nothing is in flight yet");
        assert!(line_with(&rendered, "Fleet").contains("Fleet"));

        let mut app = App::new();
        assert!(app.begin_refresh(Instant::now()));
        let rendered = lines(&render(&app, 100, 20));
        assert!(rendered[0].contains("refreshing..."), "a read in flight says so: {:?}", rendered[0]);

        // A refresh that has finished stops saying it.
        app.finish_refresh(Ok(vec![working("Xavier", "planner", "plan", "cb-kcs")]), at(86_400));
        let rendered = lines(&render(&app, 100, 20));
        assert!(!rendered[0].contains("refreshing..."), "{:?}", rendered[0]);
    }

    #[test]
    fn first_failure_is_unavailable_with_recovery_guidance() {
        let mut app = App::new();
        app.finish_refresh(Err(failure()), at(86_400 + 5));

        // Wide enough that the whole header - now carrying the focus/scroll hint too - is not
        // clipped before the failure clause and the retry key it drives.
        let rendered = lines(&render(&app, 99, 40));
        assert!(rendered[0].contains("refresh failed at 00:00:05"), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("stale"), "there is nothing to be stale: {:?}", rendered[0]);
        assert!(rendered[0].contains("g retry"), "the key hint changes: {:?}", rendered[0]);
        assert!(line_with(&rendered, "Fleet unavailable").contains("Fleet unavailable"));
        assert!(line_with(&rendered, "boom").contains("ps exited with status Some(3)"));
        assert!(line_with(&rendered, "No fleet snapshot is available.").contains("No fleet"));
        assert!(line_with(&rendered, "Press g to retry.").contains("Press g to retry."));
    }

    #[test]
    fn stale_fleet_keeps_rows_and_exact_error() {
        let mut app = populated();
        app.finish_refresh(Err(failure()), at(86_400 + 5));

        // Tall enough that Fleet's whole stale body - the error, the retained rows and the
        // trailing note - fits without being clipped; this test is about what is kept, not
        // about the range cue a shorter pane would need instead.
        let rendered = lines(&render(&app, 99, 60));
        assert!(rendered[0].contains("stale — refresh failed at 00:00:05"), "{:?}", rendered[0]);
        assert!(rendered[0].contains("g retry"), "{:?}", rendered[0]);
        assert!(line_with(&rendered, "stale since 00:00:05").contains("Fleet"));
        assert!(line_with(&rendered, "boom").contains("boom"), "the exact error is shown");
        assert!(line_with(&rendered, "Xavier").contains("● Xavier"), "the rows are retained");
        assert!(line_with(&rendered, "The last successful fleet snapshot remains visible.")
            .contains("remains visible."));
    }

    #[test]
    fn invalid_state_is_a_red_row_with_its_diagnostic() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![
                working("Xavier", "planner", "plan", "cb-kcs"),
                FleetRow {
                    diagnostic: Some("Beast.state.json: expected `,` at line 1 column 19".into()),
                    ..row("Beast", "planner", RowState::Invalid)
                },
            ]),
            at(86_400),
        );

        let buffer = render(&app, 99, 40);
        let rendered = lines(&buffer);
        let beast = line_with(&rendered, "! Beast");
        assert!(beast.contains("invalid"), "{beast:?}");
        assert!(!beast.contains("cb-"), "an invalid row carries no bead: {beast:?}");
        assert!(
            line_with(&rendered, "expected `,`").contains("  Beast.state.json"),
            "the parser's own words are on the next line, indented"
        );
        assert_eq!(style_of(&buffer, "!").fg, Some(RED));

        // Every other row is untouched: one bad file is one bad row.
        assert!(line_with(&rendered, "Xavier").contains("● Xavier"));
    }

    #[test]
    fn unverified_state_dims_only_the_question_mark() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![FleetRow {
                diagnostic: Some("pid 4242 names Beast but not this consumer's root".into()),
                ..working("Beast", "planner", "plan", "cb-kcs")
            }]),
            at(86_400),
        );

        let buffer = render(&app, 99, 40);
        let rendered = lines(&buffer);
        let beast = line_with(&rendered, "Beast");
        assert!(beast.contains("plan ?"), "the state word is qualified, not replaced: {beast:?}");
        assert!(beast.contains("cb-kcs"), "the row is kept whole: {beast:?}");
        assert!(
            !rendered.iter().any(|line| line.contains("not this consumer")),
            "an unverified pid is a mark, not a diagnostic line"
        );

        // The mark is dim; the phase word beside it is not, and the glyph stays green.
        assert!(style_of(&buffer, "?").add_modifier.contains(Modifier::DIM));
        assert_eq!(style_of(&buffer, "●").fg, Some(GREEN));
        assert!(!style_of(&buffer, "l").add_modifier.contains(Modifier::DIM));
    }

    #[test]
    fn duplicate_sessions_are_counted_on_the_row() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![FleetRow {
                sessions: 2,
                ..working("Cyclops", "implementer", "build", "cb-123")
            }]),
            at(86_400),
        );
        let rendered = lines(&render(&app, 99, 40));
        assert!(line_with(&rendered, "Cyclops").contains("build ×2"));
    }

    #[test]
    fn narrow_screen_keeps_agent_state_and_bead() {
        let app = populated();
        let rendered = lines(&render(&app, 50, 20));

        let heading = line_with(&rendered, "AGENT");
        assert!(heading.contains("AGENT") && heading.contains("STATE") && heading.contains("BEAD"));
        assert!(!heading.contains("ROLE"), "below 64 columns Role is hidden: {heading:?}");
        assert!(!heading.contains("FOR"), "below 64 columns For is hidden: {heading:?}");

        let xavier = line_with(&rendered, "Xavier");
        assert!(xavier.contains("● Xavier"), "{xavier:?}");
        assert!(xavier.contains("plan"), "{xavier:?}");
        assert!(xavier.contains("cb-kcs"), "{xavier:?}");
        assert!(!xavier.contains("planner"), "the Role column is gone: {xavier:?}");
        assert!(!xavier.contains("18m"), "the For column is gone: {xavier:?}");

        // 64 is the boundary itself, and it is wide.
        let wide = lines(&render(&app, 64, 20));
        assert!(line_with(&wide, "AGENT").contains("ROLE"));
    }

    #[test]
    fn tiny_screen_replaces_the_document() {
        let app = populated();
        for (width, height) in [(34, 9), (39, 20), (100, 11)] {
            let rendered = lines(&render(&app, width, height));
            let joined = rendered.join("\n");
            assert!(joined.contains("Terminal too small"), "{width}x{height}: {joined}");
            assert!(joined.contains("Cerebro needs at least"), "{width}x{height}");
            assert!(joined.contains("40 columns x 12 rows."), "{width}x{height}");
            assert!(
                joined.contains(&format!("Current size: {width} x {height}.")),
                "{width}x{height}: {joined}"
            );
            assert!(joined.contains("Resize the terminal,"), "{width}x{height}");
            assert!(joined.contains("or press q/Esc/Ctrl-C to quit."), "{width}x{height}");
            assert!(!joined.contains("Xavier"), "no partial rows below the floor: {joined}");
            assert!(!joined.contains("read-only"), "the screen is replaced, not added to");
        }

        // 40x12 is the floor itself, and it renders the fleet screen rather than the
        // replacement. Its own rows are below the fold at that size, so the heading is what
        // proves the pane is the fleet's.
        let rendered = lines(&render(&app, 40, 12));
        assert!(rendered[0].contains("Cerebro — read-only"));
        assert!(line_with(&rendered, "AGENT").contains("AGENT"));
    }

    /// The five approved header spellings, and nothing else (cb-kcs.1).
    ///
    /// The navigator chose the header line as the whole of the TUI's ownership surface, so this
    /// is where every ownership state has to be legible. A sixth spelling appearing here is a
    /// design change, not a refactor.
    #[test]
    fn the_header_names_every_supervision_state() {
        let cases = [
            (SupervisionMode::Supervising, "Cerebro — supervising"),
            // The ordinary case is silent: no project has moved supervision, so the screen says
            // what it has always said and keeps every hint (the navigator's call).
            (
                SupervisionMode::ReadOnly(ReadOnlyReason::ConfiguredFor(SupervisorKind::Emacs)),
                "Cerebro — read-only",
            ),
            (
                SupervisionMode::ReadOnly(ReadOnlyReason::LockError(
                    "the supervision lease is held, but /some/very/long/path.json is malformed"
                        .into(),
                )),
                "Cerebro — read-only; the supervision lease could not be taken",
            ),
            (
                SupervisionMode::ReadOnly(ReadOnlyReason::OwnedBy(SupervisorKind::Tui)),
                "Cerebro — read-only; another Ratatui process owns supervision",
            ),
            (
                SupervisionMode::ReadOnly(ReadOnlyReason::InvalidDeclaration("rat".into())),
                "Cerebro — read-only; invalid fleet_supervisor \"rat\"",
            ),
            (
                SupervisionMode::Draining { configured_for: Some(SupervisorKind::Tui), live_sessions: 2 },
                "Cerebro — handoff pending",
            ),
        ];
        for (mode, expected) in cases {
            let mut app = populated();
            app.set_supervision(mode.clone());
            let rendered = lines(&render(&app, 120, 20));
            assert!(rendered[0].starts_with(expected), "{mode:?}: {:?}", rendered[0]);
            // Ownership lives on the header and NOWHERE else: no pane, no strip, no Tab stop.
            let below: String = rendered[1..].join("\n");
            assert!(!below.contains("supervision"), "{mode:?} leaked below the header: {below}");
            assert!(!below.contains("Ownership"), "{mode:?} added an Ownership pane: {below}");
        }
    }

    #[test]
    fn a_refused_launch_is_drawn_in_red() {
        let mut app = supervising();
        app.selected = Some("Rogue".to_string());
        app.set_session_view(SessionView::Refused {
            lines: std::sync::Arc::new(vec![
                Line::from(Span::styled(
                    "agents/implementer.md is missing".to_string(),
                    Style::default().fg(RED),
                )),
                Line::from(""),
                Line::from(Span::styled("Press s to try again.".to_string(), dim())),
            ]),
            at: at(50_820),
        });
        let buffer = render(&app, 200, 20);
        let rendered = lines(&buffer);
        assert!(
            rendered.iter().any(|line| line.contains("Rogue — launch refused 14:07")),
            "{rendered:?}"
        );
        assert!(
            !rendered.iter().any(|line| line.contains("[Tab to focus]")),
            "a refused launch carries no hint: {rendered:?}"
        );
        assert!(
            rendered.iter().any(|line| line.contains("agents/implementer.md is missing")),
            "{rendered:?}"
        );
        assert!(
            rendered.iter().any(|line| line.contains("Press s to try again.")),
            "{rendered:?}"
        );
        assert_eq!(style_where(&buffer, "Rogue — launch refused").fg, Some(RED));
    }

    #[test]
    fn a_kill_prompt_replaces_the_header_span_in_gold() {
        let mut app = supervising();
        app.confirm = Some(Prompt::Kill {
            name: "Cyclops".to_string(),
            text: "Kill Cyclops? Its bead cb-42k stays claimed.  y / n".to_string(),
        });
        let buffer = render(&app, 200, 20);
        let rendered = lines(&buffer);
        assert!(
            rendered[0].contains("| Kill Cyclops? Its bead cb-42k stays claimed.  y / n"),
            "{:?}",
            rendered[0]
        );
        assert_eq!(style_where(&buffer, "Kill Cyclops?").fg, Some(GOLD));
        assert!(!rendered[0].contains("refreshing"), "{:?}", rendered[0]);
    }

    #[test]
    fn the_quit_refusal_takes_the_whole_screen() {
        let mut app = supervising();
        app.refuse_quit(vec![
            "Xavier".to_string(),
            "Beast".to_string(),
            "Cyclops".to_string(),
        ]);
        let buffer = render(&app, 200, 20);
        let rendered = lines(&buffer);
        assert!(rendered[0].contains("| quit refused"), "{:?}", rendered[0]);
        assert_eq!(style_where(&buffer, "quit refused").fg, Some(RED));
        assert!(
            rendered.iter().any(|line| line.contains("3 live agents prevent exit")),
            "{rendered:?}"
        );
        assert!(
            rendered
                .iter()
                .any(|line| line.contains("Cerebro is supervising Xavier, Beast and Cyclops.")),
            "{rendered:?}"
        );
        assert!(
            rendered.iter().any(|line| line.contains("No agent was stopped. Any key returns.")),
            "{rendered:?}"
        );
        for pane in ["Fleet", "Work", "Session"] {
            assert!(
                !rendered.iter().any(|line| line.contains(pane)),
                "no {pane} pane behind the refusal: {rendered:?}"
            );
        }
    }

    #[test]
    fn one_live_agent_is_named_in_the_singular() {
        let mut app = supervising();
        app.refuse_quit(vec!["Cyclops".to_string()]);
        let rendered = lines(&render(&app, 200, 20));
        assert!(
            rendered.iter().any(|line| line.contains("1 live agent prevents exit")),
            "{rendered:?}"
        );
        assert!(
            rendered.iter().any(|line| line.contains("Cerebro is supervising Cyclops.")),
            "{rendered:?}"
        );
    }

    #[test]
    fn the_supervising_header_offers_the_lifecycle_keys() {
        let rendered = lines(&render(&supervising(), 200, 20));
        assert!(
            rendered[0].contains("s/f/k start·finish·kill"),
            "a supervising view offers its lifecycle keys: {:?}",
            rendered[0]
        );
    }

    /// The keys that change the fleet outlast the keys that move around it (Q7).
    #[test]
    fn the_lifecycle_keys_outlast_the_movement_hints() {
        let rendered = lines(&render(&supervising(), 100, 20));
        assert!(rendered[0].contains("s/f/k start·finish·kill"), "{:?}", rendered[0]);
        assert!(rendered[0].contains("g refresh"), "{:?}", rendered[0]);
        assert!(rendered[0].contains("q/Esc/Ctrl-C quit"), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("Tab/Shift-Tab"), "the pane hint gave way: {:?}", rendered[0]);
    }

    /// The read-only screen is exactly what it was: this is what proves the increment stayed put.
    #[test]
    fn a_read_only_header_offers_no_lifecycle_key() {
        let rendered = lines(&render(&populated(), 200, 20));
        assert!(!rendered[0].contains("s/f/k"), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("finish"), "{:?}", rendered[0]);
    }

    #[test]
    fn a_handing_over_header_offers_f_and_k_and_counts_the_agents() {
        let three = render(&handing_over(3), 200, 20);
        let rendered = lines(&three);
        assert!(rendered[0].contains("| 3 live agents"), "{:?}", rendered[0]);
        assert_eq!(style_where(&three, "3 live agents").fg, Some(GOLD));
        assert!(rendered[0].contains("f finish | k kill"), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("s/f/k"), "s is refused while draining: {:?}", rendered[0]);

        let one = lines(&render(&handing_over(1), 200, 20));
        assert!(one[0].contains("| 1 live agent "), "{:?}", one[0]);
    }

    /// The cost the navigator accepted explicitly (Q6): a notice takes that slot for one keystroke.
    #[test]
    fn a_notice_hides_the_live_count_for_one_keystroke() {
        let mut app = handing_over(3);
        app.set_notice("Cyclops will finish after this pass.".to_string());
        let rendered = lines(&render(&app, 200, 20));
        assert!(rendered[0].contains("Cyclops will finish after this pass."), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("3 live agents"), "{:?}", rendered[0]);
    }

    /// The screen every consumer sees today keeps every hint it had before this bead.
    ///
    /// This is the assertion the navigator asked for by name: ownership must not cost the default
    /// hundred-column screen its pane and scroll hints, because that is the only place either is
    /// discoverable.
    #[test]
    fn the_ordinary_screen_keeps_every_hint_at_a_hundred_columns() {
        let app = populated(); // App::new(): no declaration, so read-only because Emacs
        let rendered = lines(&render(&app, 100, 20));
        assert!(rendered[0].starts_with("Cerebro — read-only |"), "{:?}", rendered[0]);
        for hint in ["Tab/Shift-Tab pane", "↑/↓/PgUp/PgDn move", "g refresh", "q/Esc/Ctrl-C quit"] {
            assert!(rendered[0].contains(hint), "the default screen keeps {hint}: {:?}", rendered[0]);
        }

        // A supervising sibling at the same width. It does NOT keep every hint - the lifecycle
        // keys cost more than the shorter title saves, and `the_lifecycle_keys_outlast_the_movement_hints`
        // is where that trade is asserted. What matters here is that the two keys a navigator
        // cannot guess from the screen survive it.
        let supervising = lines(&render(&supervising(), 100, 20));
        assert!(supervising[0].contains("s/f/k start·finish·kill"), "{:?}", supervising[0]);
        assert!(supervising[0].contains("g refresh"), "{:?}", supervising[0]);
        assert!(supervising[0].contains("q/Esc/Ctrl-C quit"), "{:?}", supervising[0]);
    }

    /// When there IS something to say, the hints give way before the state does.
    ///
    /// A contested lease makes the title long enough to push `q/Esc/Ctrl-C quit` off a
    /// hundred-column screen. A hint the terminal has cut in half is worse than a shorter hint
    /// that fits, so the scroll and pane hints go first and the two keys a navigator cannot guess
    /// from the screen stay.
    #[test]
    fn a_long_ownership_title_shortens_the_hints_rather_than_losing_them() {
        let mut app = populated();
        app.set_supervision(SupervisionMode::ReadOnly(ReadOnlyReason::OwnedBy(
            SupervisorKind::Tui,
        )));

        let narrow = lines(&render(&app, 100, 20));
        assert!(narrow[0].contains("another Ratatui process owns supervision"), "{:?}", narrow[0]);
        assert!(narrow[0].contains("g refresh"), "the refresh key survives: {:?}", narrow[0]);
        assert!(narrow[0].contains("q/Esc/Ctrl-C quit"), "the quit key survives: {:?}", narrow[0]);
        assert!(!narrow[0].contains("Tab/Shift-Tab"), "the pane hint gave way: {:?}", narrow[0]);

        // With room for everything, everything is shown.
        let wide = lines(&render(&app, 160, 20));
        assert!(wide[0].contains("Tab/Shift-Tab pane"), "{:?}", wide[0]);
        assert!(wide[0].contains("↑/↓/PgUp/PgDn move"), "{:?}", wide[0]);

        // A supervising sibling at the same two widths: the lifecycle keys survive both, and the
        // movement hints are what give way when they must.
        let supervising = supervising();
        let narrow = lines(&render(&supervising, 60, 20));
        assert!(narrow[0].contains("s/f/k start·finish·kill"), "{:?}", narrow[0]);
        assert!(!narrow[0].contains("Tab/Shift-Tab"), "{:?}", narrow[0]);
        let wide = lines(&render(&supervising, 200, 20));
        assert!(wide[0].contains("Tab/Shift-Tab pane"), "{:?}", wide[0]);
        assert!(wide[0].contains("s/f/k start·finish·kill"), "{:?}", wide[0]);
    }

    #[test]
    fn elapsed_matches_the_emacs_vocabulary() {
        let base = at(0);
        assert_eq!(elapsed(None, base), "");
        assert_eq!(elapsed(Some(base), base), "0m");
        assert_eq!(elapsed(Some(base - chrono::Duration::minutes(12)), base), "12m");
        assert_eq!(elapsed(Some(base - chrono::Duration::minutes(63)), base), "1h03");
        assert_eq!(elapsed(Some(base - chrono::Duration::hours(49)), base), "2d");
    }

    #[test]
    fn an_unknown_state_word_is_shown_verbatim_and_truncated() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![
                row("Beast", "planner", RowState::Unknown("perplexed".into())),
                row("Storm", "implementer", RowState::Unknown("absolutely-baffled".into())),
            ]),
            at(86_400),
        );
        let buffer = render(&app, 99, 40);
        let rendered = lines(&buffer);
        assert!(line_with(&rendered, "Beast").contains("perplexed"));
        assert!(
            line_with(&rendered, "Storm").contains("absolutel…"),
            "a word longer than the column is cut with an ellipsis: {:?}",
            line_with(&rendered, "Storm")
        );
        // Gold, never the blue of `idle': a state this view does not understand is not "free".
        assert_eq!(style_of(&buffer, "●").fg, Some(GOLD));
    }

    // --- the two widgets, independently ------------------------------------------------------------

    #[test]
    fn fleet_and_work_render_as_separate_stacked_widgets() {
        let app = populated();
        let buffer = render(&app, 99, 60);
        let rendered = lines(&buffer);

        // Fleet is focused by default: a thick, bright-blue one-cell border and a bold blue title.
        let fleet_top = line_with(&rendered, "Fleet 5");
        assert!(fleet_top.starts_with('┏'), "the focused pane's border is thick: {fleet_top:?}");
        assert_eq!(style_where(&buffer, "┏").fg, Some(BLUE));
        assert_eq!(style_where(&buffer, "Fleet 5").fg, Some(BLUE));
        assert!(style_where(&buffer, "Fleet 5").add_modifier.contains(Modifier::BOLD));

        // Work is not focused: the ordinary thin, dim border and an undecorated dim title.
        let work_top = rendered
            .iter()
            .find(|line| line.starts_with(['┌', '┏']) && line.contains("Work"))
            .expect("Work's own top border");
        assert!(work_top.starts_with('┌'), "the unfocused pane's border stays thin: {work_top:?}");
        assert!(style_where(&buffer, "┌").add_modifier.contains(Modifier::DIM));
        assert!(
            !style_where(&buffer, "┌").add_modifier.contains(Modifier::BOLD),
            "the unfocused title is not bold"
        );

        // Each widget's own body content is unchanged.
        assert!(line_with(&rendered, "● Xavier").contains("● Xavier"));
        assert!(index_of(&rendered, "Work") > index_of(&rendered, "Fleet 5"), "Work sits below Fleet");

        // And the Session pane is a third widget of the same kind, below Work, with a plain
        // unfocused title of its own.
        assert_eq!(top_corners(&buffer).len(), 3, "{rendered:?}");
        assert!(
            index_of(&rendered, "Sessions are hosted by") > index_of(&rendered, "Work"),
            "Session sits below Work: {rendered:?}"
        );

        // Focusing it gives it the thick blue border and bold title, and takes them off Fleet.
        let mut focused = populated();
        focused.focus = PaneFocus::Session;
        let buffer = focused_buffer(&focused);
        // At the session pane's own origin, so this cannot accidentally read the fleet row of
        // the same name one line below.
        let (row, column) = top_corners(&buffer)[1];
        let title = buffer
            .cell((column + 1, row))
            .map(|c| Style::default().fg(c.fg).add_modifier(c.modifier))
            .expect("the session title's first cell");
        assert_eq!(title.fg, Some(BLUE), "the session title is focused");
        assert!(title.add_modifier.contains(Modifier::BOLD));
        assert!(
            !style_where(&buffer, "Fleet 5").add_modifier.contains(Modifier::BOLD),
            "and Fleet's is not"
        );
    }

    /// `render` at the wide split size, named for what the case beside it is asking about.
    fn focused_buffer(app: &App) -> Buffer {
        render(app, 120, 30)
    }

    /// Every top-left corner on the screen, as (row, column): one per bordered widget.
    fn top_corners(buffer: &Buffer) -> Vec<(u16, u16)> {
        let area = buffer.area;
        let mut found = Vec::new();
        for y in 0..area.height {
            for x in 0..area.width {
                if buffer
                    .cell((x, y))
                    .is_some_and(|c| matches!(c.symbol(), "┌" | "┏"))
                {
                    found.push((y, x));
                }
            }
        }
        found
    }

    /// The columns a top border row's corners sit in.
    fn corners_on_row(buffer: &Buffer, row: u16) -> Vec<u16> {
        (0..buffer.area.width)
            .filter(|&x| {
                buffer
                    .cell((x, row))
                    .is_some_and(|c| matches!(c.symbol(), "┌" | "┏" | "┐" | "┓"))
            })
            .collect()
    }

    /// At `SPLIT_COLUMNS` and wider the screen is a fixed left column of Fleet over Work, with
    /// the Session pane taking every remaining cell at the column's full height.
    /// The selected row is a band across the pane's whole inner width, and the row keeps its own
    /// state colour: a Line-level background sits beneath each span's own style.
    #[test]
    fn the_selected_row_is_highlighted_across_the_pane() {
        let app = populated();
        assert_eq!(app.selected.as_deref(), Some("Xavier"), "the first read selects row 0");
        let buffer = render(&app, 120, 30);
        let rendered = lines(&buffer);

        let selected_y = index_of(&rendered, "● Xavier") as u16;
        // Every cell of the pane's inner width, border to border.
        for x in 1..LEFT_COLUMN - 1 {
            assert_eq!(
                buffer.cell((x, selected_y)).map(|c| c.bg),
                Some(SELECTED_BG),
                "column {x} of the selected row is highlighted: {:?}",
                rendered[selected_y as usize]
            );
        }

        // No other fleet row is, and the row's own glyph colour survives the band.
        let other_y = index_of(&rendered, "? Cerebro") as u16;
        assert_eq!(buffer.cell((1, other_y)).map(|c| c.bg), Some(Color::Reset));
        assert_eq!(style_of(&buffer, "●").fg, Some(GREEN), "the glyph keeps its own colour");
    }

    /// The highlight lands on the line `app::fleet_body` names - the test that keeps the shape
    /// and the renderer from drifting apart.
    #[test]
    fn the_highlight_lands_on_the_line_the_body_names() {
        let rows = vec![
            row("Xavier", "planner", RowState::Idle),
            FleetRow {
                diagnostic: Some("bad json".into()),
                ..row("Beast", "planner", RowState::Invalid)
            },
            row("Storm", "implementer", RowState::Idle),
        ];
        let mut app = App::new();
        app.finish_refresh(Ok(rows.clone()), at(86_400));
        app.selected = Some("Storm".into());

        let buffer = render(&app, 120, 30);
        let rendered = lines(&buffer);
        // The fleet pane's body starts one row below its top border.
        let body_top = top_corners(&buffer)[0].0 + 1;
        let expected = body_top
            + crate::app::body_line_of_row(&crate::app::fleet_body(&app.fleet.content), 2)
                .expect("the body names row 2") as u16;

        assert_eq!(
            buffer.cell((1, expected)).map(|c| c.bg),
            Some(SELECTED_BG),
            "the highlight is on the line the body names: {rendered:?}"
        );
        assert!(rendered[expected as usize].contains("Storm"), "{rendered:?}");
    }

    /// Every row `app::fleet_body` names is where this renderer actually draws it, fresh pane and
    /// stale pane alike. This is the case that keeps the one owner of the body's shape honest: the
    /// renderer maps that list, so a document of a different length or with a row elsewhere means
    /// the two have parted company.
    #[test]
    fn every_row_the_body_names_is_where_the_renderer_draws_it() {
        let rows = vec![
            row("Xavier", "planner", RowState::Idle),
            FleetRow {
                diagnostic: Some("bad json".into()),
                ..row("Beast", "planner", RowState::Invalid)
            },
            row("Storm", "implementer", RowState::Idle),
        ];

        let mut fresh = App::new();
        fresh.finish_refresh(Ok(rows.clone()), at(0));
        let mut stale = App::new();
        stale.finish_refresh(Ok(rows.clone()), at(0));
        stale.finish_refresh(Err(failure()), at(5));

        for app in [&fresh, &stale] {
            let document = fleet_document(app, now(), 99, app.selected_index());
            let body = crate::app::fleet_body(&app.fleet.content);
            let flat: Vec<String> = document
                .iter()
                .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
                .collect();
            assert_eq!(document.len(), body.len(), "one line per body entry: {flat:?}");
            for (index, expected) in rows.iter().enumerate() {
                let line = crate::app::body_line_of_row(&body, index)
                    .expect("the body names every row of a table it drew");
                assert!(
                    flat[line].contains(&expected.name),
                    "row {index} ({}) is drawn on the line the body names: {flat:?}",
                    expected.name
                );
            }
        }
    }

    /// The Session pane's three shapes, verbatim.
    #[test]
    fn the_session_pane_says_why_there_is_no_session() {
        // Read-only wins over everything else, and names nobody.
        let app = populated();
        let rendered = lines(&render(&app, 120, 30));
        assert!(line_with(&rendered, "Sessions are hosted by")
            .contains("Sessions are hosted by the view that supervises this"));
        assert!(line_with(&rendered, "checkout. This one").contains("checkout. This one does not."));
        assert!(!rendered.join("\n").contains("Press s to start"), "no key that does not exist");

        // Supervising, with an agent selected: its name is the title, and the body offers `s`.
        let app = supervising();
        let buffer = render(&app, 120, 30);
        let rendered = lines(&buffer);
        let session_top = &rendered[top_corners(&buffer)[1].0 as usize];
        assert!(
            session_top.contains("┌Xavier"),
            "the pane is titled with the selected agent's name: {session_top:?}"
        );
        assert!(line_with(&rendered, "No live session.").contains("No live session."));
        assert!(line_with(&rendered, "Press s to start").contains("Press s to start Xavier."));
        assert!(line_with(&rendered, "The last completed pass")
            .contains("The last completed pass is not available."));

        // Supervising with nothing selected - a fleet that is loading, empty or unavailable.
        let mut app = App::with_supervision(SupervisionMode::Supervising);
        app.finish_refresh(Ok(vec![]), at(86_400));
        let buffer = render(&app, 120, 30);
        let rendered = lines(&buffer);
        assert!(line_with(&rendered, "No agent selected.").contains("No agent selected."));
        let session_top = &rendered[top_corners(&buffer)[1].0 as usize];
        assert!(
            session_top.contains("┌Session"),
            "with nothing selected the pane is titled Session: {session_top:?}"
        );
    }

    /// A notice takes the place of the refresh/stale span, in gold, and the hints still follow.
    #[test]
    fn a_notice_replaces_the_refresh_span_and_is_gold() {
        let mut app = populated();
        app.notice = Some("Storm is no longer on the roster. Selected Cyclops.".into());
        assert!(app.begin_refresh(Instant::now()));

        let buffer = render(&app, 160, 30);
        let rendered = lines(&buffer);
        assert!(rendered[0].contains("Storm is no longer on the roster."), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("refreshing..."), "the notice wins: {:?}", rendered[0]);
        assert!(rendered[0].contains("q/Esc/Ctrl-C quit"), "the hints still follow");
        assert_eq!(style_where(&buffer, "Storm is no longer").fg, Some(GOLD));
    }

    #[test]
    fn a_wide_screen_splits_into_a_left_column_and_a_session_pane() {
        let app = supervising();
        let buffer = render(&app, 120, 30);

        let corners = top_corners(&buffer);
        assert_eq!(corners.len(), 3, "three bordered widgets: {:?}", lines(&buffer));

        // Fleet and Session open on the same row; Fleet ends at the left column's last cell and
        // Session runs from the next one to the right edge.
        let (fleet_row, fleet_col) = corners[0];
        assert_eq!(fleet_col, 0);
        assert_eq!(corners[1], (fleet_row, LEFT_COLUMN), "Session opens beside Fleet");
        assert_eq!(corners_on_row(&buffer, fleet_row), vec![0, LEFT_COLUMN - 1, LEFT_COLUMN, 119]);

        // Work sits below Fleet, in the same left column and no wider.
        let (work_row, work_col) = corners[2];
        assert!(work_row > fleet_row);
        assert_eq!(work_col, 0);
        assert_eq!(corners_on_row(&buffer, work_row), vec![0, LEFT_COLUMN - 1]);

        // The Session pane spans the whole column height beside them: its own bottom border is
        // the screen's last row.
        let last = buffer.area.height - 1;
        assert_eq!(
            buffer.cell((LEFT_COLUMN, last)).map(|c| c.symbol()),
            Some("└"),
            "the session pane reaches the bottom: {:?}",
            lines(&buffer)[last as usize]
        );
    }

    #[test]
    fn a_screen_below_the_split_width_stacks_all_three_panes() {
        let app = supervising();
        let buffer = render(&app, 99, 30);
        let rendered = lines(&buffer);

        let corners = top_corners(&buffer);
        assert_eq!(corners.len(), 3, "three stacked widgets: {rendered:?}");
        for (row, column) in &corners {
            assert_eq!(*column, 0, "every stacked pane starts at the left edge");
            assert_eq!(corners_on_row(&buffer, *row), vec![0, 98], "and is full width");
        }
        assert!(corners[0].0 < corners[1].0 && corners[1].0 < corners[2].0);
        assert!(
            index_of(&rendered, "Fleet") < index_of(&rendered, "Work")
                && index_of(&rendered, "Work") < index_of(&rendered, "No live session."),
            "Fleet, Work, Session, in that order: {rendered:?}"
        );
    }

    #[test]
    fn fleet_natural_height_is_capped_at_half_the_screen() {
        let mut app = App::new();
        app.finish_refresh(
            Ok((0..30)
                .map(|i| row(&format!("A{i:02}"), "implementer", RowState::Dead))
                .collect()),
            at(0),
        );
        // available = 30 - 1 = 29; half = 14 (floor); cap = max(3, 14) = 14. Fleet's body (a
        // heading plus 30 rows = 31 lines) is far past that, so Fleet is capped rather than
        // given its natural height.
        let rendered = lines(&render(&app, 100, 30));
        let work_top = rendered
            .iter()
            .position(|line| line.starts_with(['┌', '┏']) && line.contains("Work"))
            .expect("Work's own top border");
        assert_eq!(work_top, 1 + 14, "Fleet is capped at half the available height: {rendered:?}");
    }

    #[test]
    fn forty_by_twelve_gives_all_three_widgets_a_body() {
        let app = both_populated();
        let rendered = lines(&render(&app, 40, 12));

        // Below `SPLIT_COLUMNS` all three stack, and each keeps one inner row at the floor.
        let tops: Vec<usize> = (0..rendered.len())
            .filter(|&y| rendered[y].starts_with(['┌', '┏']))
            .collect();
        assert_eq!(tops.len(), 3, "three widgets at the floor: {rendered:?}");

        let m = metrics(&app, now(), Rect::new(0, 0, 40, 12));
        assert!(m.fleet.viewport_lines >= 1, "Fleet keeps at least one visible body row");
        assert!(m.work.viewport_lines >= 1, "Work keeps at least one visible body row");
        assert!(m.session.viewport_lines >= 1, "and so does Session");
    }

    #[test]
    fn each_clipped_widget_shows_its_visible_row_range() {
        let mut app = App::new();
        app.finish_refresh(
            Ok((0..30)
                .map(|i| row(&format!("A{i:02}"), "implementer", RowState::Dead))
                .collect()),
            at(0),
        );
        // At 100x30: available = 29, cap = 14, Fleet's outer height is 14 (its 31-line body is
        // capped), so its inner height is 12 and its visible body is 11 once the cue row is
        // reserved. Total content is 31: a heading plus 30 rows.
        app.fleet.scroll = 0;
        let rendered = lines(&render(&app, 100, 30));
        assert!(line_with(&rendered, "Rows").contains("Rows 1–11 of 31"), "{rendered:?}");

        app.fleet.scroll = 10;
        let rendered = lines(&render(&app, 100, 30));
        assert!(line_with(&rendered, "Rows").contains("Rows 11–21 of 31"), "{rendered:?}");

        app.fleet.scroll = 20;
        let rendered = lines(&render(&app, 100, 30));
        assert!(line_with(&rendered, "Rows").contains("Rows 21–31 of 31"), "{rendered:?}");

        // Work's own cue is independent, and derived the same way from its own geometry.
        let app = work_app(WorkBuckets {
            unplanned: (1..=31)
                .map(|n| bead(&format!("cb-{n:03}"), Some(1), &format!("item {n}")))
                .collect(),
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 100, 20));
        let cue = rendered
            .iter()
            .find(|line| line.contains("Rows ") && line.contains(" of "))
            .expect("Work's own range cue");
        assert!(cue.starts_with("Rows 1–"), "{cue:?}");

        // The Session pane gets the same cue from the same helper, at no extra cost.
        let mut app = App::with_supervision(SupervisionMode::Supervising);
        app.finish_refresh(Ok(vec![row("Storm", "implementer", RowState::Idle)]), at(0));
        let rendered = body(&render(&app, 99, 12));
        assert!(
            rendered.iter().any(|line| line.contains("Rows 1–2 of 4")),
            "the session body carries its own range cue: {rendered:?}"
        );

        // A retained pass is a document like any other, and gets the same cue from the same rule.
        let mut app = App::with_supervision(SupervisionMode::Supervising);
        app.finish_refresh(Ok(vec![row("Storm", "implementer", RowState::Idle)]), at(0));
        app.selected = Some("Storm".to_string());
        ended(&mut app, 40);
        let rendered = lines(&render(&app, 99, 12));
        assert!(
            rendered.iter().any(|line| line.contains("Rows 1–") && line.contains(" of 40")),
            "the retained pass carries its own range cue: {rendered:?}"
        );
    }

    #[test]
    fn pane_offsets_scroll_only_their_own_bodies() {
        let mut app = both_populated();
        app.finish_refresh(
            Ok((0..30)
                .map(|i| row(&format!("A{i:02}"), "implementer", RowState::Dead))
                .collect()),
            at(0),
        );

        // Stacked, so each pane is a full-width band and `body` reads as one document.
        let unscrolled = body(&render(&app, 99, 40));
        assert!(unscrolled.iter().any(|line| line.contains("○ A00")));
        assert!(!unscrolled.iter().any(|line| line.contains("○ A25")));

        app.fleet.scroll = 20;
        let fleet_scrolled = body(&render(&app, 99, 40));
        assert!(!fleet_scrolled.iter().any(|line| line.contains("○ A00")));
        assert!(fleet_scrolled.iter().any(|line| line.contains("○ A25")));
        // Scrolling Fleet alone never moves Work: its own section headers stay exactly where
        // they were.
        assert_eq!(
            index_of(&unscrolled, "Claimed 1") - index_of(&unscrolled, "Work"),
            index_of(&fleet_scrolled, "Claimed 1") - index_of(&fleet_scrolled, "Work"),
        );

        app.fleet.scroll = 0;
        app.work.scroll = 3;
        let work_scrolled = body(&render(&app, 99, 40));
        assert!(
            work_scrolled.iter().any(|line| line.contains("○ A00")),
            "Fleet is untouched while Work scrolls: {work_scrolled:?}"
        );
        assert_ne!(
            index_of(&unscrolled, "Claimed 1"),
            work_scrolled
                .iter()
                .position(|line| line.contains("Claimed 1"))
                .unwrap_or(usize::MAX),
            "Work's own body has moved under its own offset"
        );

        // And the Session pane's offset is its own third: moving it moves neither of the others.
        let mut app = App::with_supervision(SupervisionMode::Supervising);
        app.finish_refresh(Ok(vec![row("Storm", "implementer", RowState::Idle)]), at(0));
        // Short enough that the session's own body is clipped and its offset has somewhere to go.
        let flat = body(&render(&app, 99, 12));
        assert!(flat.iter().any(|line| line.contains("No live session.")));
        app.session.scroll = 2;
        let scrolled = body(&render(&app, 99, 12));
        assert!(
            !scrolled.iter().any(|line| line.contains("No live session.")),
            "the session body scrolled under its own offset: {scrolled:?}"
        );
        assert!(
            scrolled.iter().any(|line| line.contains("Press s to start Storm.")),
            "{scrolled:?}"
        );
        assert!(
            scrolled.iter().any(|line| line.contains("AGENT")),
            "Fleet's own body did not move: {scrolled:?}"
        );
    }

    #[test]
    fn focused_failure_titles_keep_status_colors() {
        // Work, focused and stale: the title stays gold, never the focus blue, while its border
        // is still the thick one that marks it as focused.
        let mut app = populated();
        app.focus = PaneFocus::Work;
        app.finish_work_refresh(Ok(WorkBuckets::default()), at(86_400));
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 5));

        let buffer = render(&app, 100, 30);
        let rendered = lines(&buffer);
        let work_title_row = line_with(&rendered, "stale since 00:00:05");
        assert!(work_title_row.starts_with('┏'), "{work_title_row:?}");
        assert_eq!(style_where(&buffer, "stale since").fg, Some(GOLD));

        // Fleet, unfocused and healthy, is the ordinary dim style rather than blue.
        let fleet_title_row = rendered
            .iter()
            .find(|line| line.starts_with(['┌', '┏']) && line.contains("Fleet"))
            .expect("Fleet's own top border");
        assert!(fleet_title_row.starts_with('┌'), "{fleet_title_row:?}");
        assert!(style_where(&buffer, "Fleet").add_modifier.contains(Modifier::DIM));

        // Unavailable, focused, stays red the same way.
        let mut app = App::new();
        app.focus = PaneFocus::Work;
        app.finish_work_refresh(Err(bd_failure()), at(86_400));
        let buffer = render(&app, 100, 20);
        assert_eq!(style_where(&buffer, "Work unavailable").fg, Some(RED));
        let rendered = lines(&buffer);
        assert!(line_with(&rendered, "Work unavailable").starts_with('┏'));
    }

    // --- cb-vyp.3: the Work pane -----------------------------------------------------------------

    #[test]
    fn renders_all_six_work_sections_in_lifecycle_order() {
        let app = work_app(WorkBuckets {
            claimed: vec![bead("cb-123", Some(1), "Preserve session output")],
            being_planned: vec![
                bead("cb-kcs", Some(1), "Ratatui supervises the fleet"),
                bead("cb-vyp", Some(1), "Standalone Ratatui fleet view"),
            ],
            paused: vec![bead("cb-9xy", Some(2), "Choose compact rows")],
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 99, 80));

        // The order work moves in, read backwards - and the Work pane is below the Fleet one.
        let order = [
            "Claimed 1",
            "Planned, unclaimed 0",
            "Being planned 2",
            "Unplanned 0",
            "Waiting on you 1",
            "Merged, unverified 0",
        ];
        let mut previous = index_of(&rendered, "Work");
        for title in order {
            let index = index_of(&rendered, title);
            assert!(index > previous, "{title:?} is out of order: {rendered:?}");
            previous = index;
        }
        assert!(
            index_of(&rendered, "Work") > index_of(&rendered, "Loading fleet..."),
            "Work is rendered below Fleet"
        );

        assert!(line_with(&rendered, "cb-123").contains("  cb-123  P1 Preserve session output"));
        assert!(line_with(&rendered, "cb-kcs").contains("  cb-kcs  P1 Ratatui supervises the fleet"));
        assert_eq!(
            rendered[index_of(&rendered, "Planned, unclaimed 0") + 1],
            "  (none)",
            "an empty bucket says so rather than disappearing"
        );
        assert_eq!(rendered[index_of(&rendered, "Being planned 2") - 1], "");

        // The pane title carries no aggregate count: all six headers already have one.
        assert_eq!(rendered[index_of(&rendered, "Claimed 1") - 1], "Work");
    }

    #[test]
    fn work_sections_count_all_rows_and_show_only_eight() {
        let app = work_app(WorkBuckets {
            unplanned: (1..=31)
                .map(|n| bead(&format!("cb-{n:03}"), Some(1), &format!("item {n}")))
                .collect(),
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 99, 120));

        assert!(line_with(&rendered, "Unplanned").contains("Unplanned 31"), "the FULL count");
        let first = index_of(&rendered, "Unplanned 31");
        let shown: Vec<&String> = rendered[first + 1..first + 9].iter().collect();
        assert_eq!(shown.len(), 8);
        assert!(shown[0].contains("cb-001"), "{shown:?}");
        assert!(shown[7].contains("cb-008"), "{shown:?}");
        assert_eq!(rendered[first + 9], "  +23 more");
        assert!(
            !rendered.iter().any(|line| line.contains("cb-009")),
            "the ninth row is behind the count, not on the screen"
        );

        // A section at exactly the cap says nothing extra.
        let app = work_app(WorkBuckets {
            unplanned: (1..=8)
                .map(|n| bead(&format!("cb-{n:03}"), Some(1), &format!("item {n}")))
                .collect(),
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 99, 120));
        assert!(!rendered.iter().any(|line| line.contains("more")), "{rendered:?}");
    }

    #[test]
    fn work_rows_sort_open_by_priority_then_id_and_merged_by_recency() {
        let dated = |id: &str, when: Option<&str>| Bead {
            updated_at: when.map(|w| {
                chrono::DateTime::parse_from_rfc3339(w).unwrap().with_timezone(&Utc)
            }),
            status: "closed".into(),
            ..bead(id, Some(1), &format!("{id} landed"))
        };
        let app = work_app(WorkBuckets {
            unplanned: vec![
                bead("cb-b", Some(2), "second"),
                bead("cb-d", None, "unranked"),
                bead("cb-a", Some(2), "first"),
                bead("cb-c", Some(0), "urgent"),
            ],
            merged: vec![
                dated("cb-old", Some("2026-01-01T00:00:00Z")),
                dated("cb-undated-b", None),
                dated("cb-new", Some("2026-02-01T00:00:00Z")),
                dated("cb-undated-a", None),
            ],
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 100, 60));

        let open = index_of(&rendered, "Unplanned 4");
        let ids: Vec<&str> = rendered[open + 1..open + 5]
            .iter()
            .map(|line| line.split_whitespace().next().unwrap())
            .collect();
        assert_eq!(ids, ["cb-c", "cb-a", "cb-b", "cb-d"], "priority, then id, unranked last");

        let merged = index_of(&rendered, "Merged, unverified 4");
        let ids: Vec<&str> = rendered[merged + 1..merged + 5]
            .iter()
            .map(|line| line.split_whitespace().next().unwrap())
            .collect();
        assert_eq!(
            ids,
            ["cb-new", "cb-old", "cb-undated-a", "cb-undated-b"],
            "newest first, undated last, id breaking the tie"
        );
    }

    #[test]
    fn work_rows_truncate_only_titles() {
        let app = work_app(WorkBuckets {
            unplanned: vec![
                bead("cb-verylongid", Some(1), "short"),
                bead("cb-001", Some(1), &"a very long title that cannot fit ".repeat(4)),
                bead("cb-002", Some(1), "四字熟語 とても長い題名 ばかり ならんで いる 行 です とても"),
            ],
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 60, 40));
        let inner = 60 - 2;

        let long = line_with(&rendered, "cb-001");
        assert!(long.ends_with('…'), "only the title is cut: {long:?}");
        assert!(long.width() <= inner, "the row fits the pane: {} in {long:?}", long.width());

        // A wide-glyph title is measured in terminal cells, never in bytes or `char's - asserted
        // on the row the renderer builds, because the test backend spreads a wide glyph over two
        // cells and a string read back out of it no longer measures what was drawn.
        let wide = work_row(
            &bead("cb-002", Some(1), "四字熟語 とても長い題名 ばかり ならんで いる 行 です とても"),
            inner,
            None,
        );
        let wide: String = wide.spans.iter().map(|span| span.content.as_ref()).collect();
        assert!(wide.ends_with('…'), "{wide:?}");
        assert!(wide.width() <= inner, "{} cells in {wide:?}", wide.width());
        assert!(rendered.iter().any(|line| line.contains("cb-002")), "and it is on the screen");

        // The prefix is never truncated, whatever it costs: an id is a key, not a label.
        let over = line_with(&rendered, "cb-verylongid");
        assert!(over.starts_with("  cb-verylongid P1 short"), "{over:?}");
    }

    #[test]
    fn reopened_and_paused_rows_keep_their_markers_and_columns() {
        let reopened = Bead {
            labels: vec!["verification:failed".into()],
            ..bead("cb-777", Some(0), "came back")
        };
        let parked = |id: &str, minutes: Option<i64>| Bead {
            metadata: match minutes {
                Some(minutes) => serde_json::json!({
                    "paused_at": (now() - chrono::Duration::minutes(minutes)).to_rfc3339()
                }),
                None => serde_json::Value::Null,
            },
            ..bead(id, Some(2), "waiting for a person")
        };
        let app = work_app(WorkBuckets {
            unplanned: vec![reopened, bead("cb-888", Some(0), "arrived")],
            paused: vec![parked("cb-9xy", Some(123)), parked("cb-9zz", None)],
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 99, 80));

        let back = line_with(&rendered, "cb-777");
        let ordinary = line_with(&rendered, "cb-888");
        assert!(back.starts_with("↻ cb-777  P0 came back"), "{back:?}");
        assert!(ordinary.starts_with("  cb-888  P0 arrived"), "{ordinary:?}");
        let column = |line: &str, needle: &str| {
            line.char_indices()
                .position(|(index, _)| line[index..].starts_with(needle))
                .expect("the needle is on that line")
        };
        assert_eq!(
            column(back, "P0"),
            column(ordinary, "P0"),
            "the marker replaces the indent; it does not shift the columns"
        );

        // The paused age is right-aligned, in the fleet's own elapsed spelling, and an em dash
        // when the bead never said when it was parked.
        let aged = line_with(&rendered, "cb-9xy");
        assert!(aged.ends_with("2h03"), "{aged:?}");
        let undated = line_with(&rendered, "cb-9zz");
        assert!(undated.ends_with('—'), "{undated:?}");
        assert_eq!(aged.width(), undated.width(), "one column, whatever it says");
    }

    #[test]
    fn loading_work_is_visible_below_fleet() {
        let app = App::new();
        let rendered = body(&render(&app, 99, 40));
        assert_eq!(rendered[index_of(&rendered, "Loading work...")], "Loading work...");
        assert!(
            index_of(&rendered, "Loading work...") > index_of(&rendered, "Loading fleet..."),
            "{rendered:?}"
        );
        assert_eq!(rendered[index_of(&rendered, "Loading work...") - 1], "Work");
        assert!(!rendered[0].contains("refreshing..."), "nothing is in flight yet");
    }

    #[test]
    fn stale_work_keeps_all_last_good_sections_and_exact_error() {
        let mut app = work_app(WorkBuckets {
            claimed: vec![bead("cb-123", Some(1), "Preserve session output")],
            ..WorkBuckets::default()
        });
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 5));

        let rendered = body(&render(&app, 99, 80));
        assert!(rendered[0].contains("stale — refresh failed at 00:00:05"), "{:?}", rendered[0]);
        assert!(rendered[0].contains("g retry"), "{:?}", rendered[0]);
        assert!(line_with(&rendered, "Work — stale since 00:00:05").contains("Work"));
        assert!(line_with(&rendered, "database is locked").contains("bd exited with status"));
        assert!(line_with(&rendered, "cb-123").contains("Preserve session output"));
        for title in [
            "Claimed 1",
            "Planned, unclaimed 0",
            "Being planned 0",
            "Unplanned 0",
            "Waiting on you 0",
            "Merged, unverified 0",
        ] {
            assert!(rendered.iter().any(|line| line.contains(title)), "{title} survived");
        }
        assert!(line_with(&rendered, "The last successful work snapshot remains visible.")
            .contains("remains visible."));
    }

    #[test]
    fn first_work_failure_is_unavailable_with_recovery_guidance() {
        let mut app = App::new();
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 5));

        let rendered = body(&render(&app, 99, 40));
        assert!(rendered[0].contains("refresh failed at 00:00:05"), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("stale"), "there is nothing to be stale: {:?}", rendered[0]);
        assert!(rendered[0].contains("g retry"), "{:?}", rendered[0]);
        assert!(line_with(&rendered, "Work unavailable").contains("Work unavailable"));
        assert!(line_with(&rendered, "database is locked").contains("database is locked"));
        assert_eq!(rendered[index_of(&rendered, "No work snapshot is available.")],
                   "No work snapshot is available.");
        assert_eq!(rendered[index_of(&rendered, "Press g to retry.")], "Press g to retry.");
        assert!(
            !rendered.iter().any(|line| line.contains("Claimed")),
            "a first failure has no queues to keep"
        );
    }

    #[test]
    fn narrow_work_keeps_sections_counts_and_overflow() {
        let app = work_app(WorkBuckets {
            unplanned: (1..=31)
                .map(|n| bead(&format!("cb-{n:03}"), Some(1), "This title is cut at some point"))
                .collect(),
            ..WorkBuckets::default()
        });
        let rendered = body(&render(&app, 44, 60));

        assert!(line_with(&rendered, "Unplanned").contains("Unplanned 31"));
        assert_eq!(rendered[index_of(&rendered, "Unplanned 31") + 9], "  +23 more");
        for title in ["Claimed 0", "Planned, unclaimed 0", "Merged, unverified 0"] {
            assert!(rendered.iter().any(|line| line.contains(title)), "{title} at 44 columns");
        }
        let row = line_with(&rendered, "cb-001");
        assert!(row.ends_with('…'), "the title is cut, not the row: {row:?}");
        assert!(row.width() <= 42, "{} cells in {row:?}", row.width());
    }

    // --- the two panes together ------------------------------------------------------------------

    #[test]
    fn refreshing_header_wins_over_an_existing_pane_failure() {
        let mut app = populated();
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 5));
        assert!(app.begin_work_refresh(Instant::now()), "the retry is under way");

        let rendered = body(&render(&app, 100, 30));
        assert!(rendered[0].contains("refreshing..."), "{:?}", rendered[0]);
        assert!(
            !rendered[0].contains("refresh failed at"),
            "active recovery is the headline, not the failure it is recovering from: {:?}",
            rendered[0]
        );
        // The pane still says what happened to it, which is where a failure belongs.
        assert!(line_with(&rendered, "Work unavailable").contains("Work unavailable"));
    }

    #[test]
    fn failure_keeps_the_retry_hint_while_the_peer_refreshes() {
        let mut app = populated();
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 5));
        assert!(app.begin_refresh(Instant::now()), "the FLEET is the one refreshing");

        let rendered = body(&render(&app, 100, 30));
        assert!(rendered[0].contains("refreshing..."), "{:?}", rendered[0]);
        assert!(
            rendered[0].contains("g retry"),
            "the key stays a retry until BOTH panes are fresh: {:?}",
            rendered[0]
        );

        // And it goes back to `g refresh' only when the failed pane recovers.
        app.finish_refresh(Ok(vec![working("Xavier", "planner", "plan", "cb-kcs")]), at(86_400 + 6));
        app.finish_work_refresh(Ok(WorkBuckets::default()), at(86_400 + 7));
        let rendered = body(&render(&app, 100, 30));
        assert!(rendered[0].contains("g refresh"), "{:?}", rendered[0]);
    }

    #[test]
    fn header_uses_the_newest_failure_when_both_panes_fail() {
        let mut app = App::new();
        app.finish_refresh(Err(failure()), at(86_400 + 5));
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 9));

        let rendered = body(&render(&app, 100, 30));
        assert!(rendered[0].contains("refresh failed at 00:00:09"), "{:?}", rendered[0]);
        assert!(!rendered[0].contains("00:00:05"), "the older failure is not the headline");
        // Neither pane is named up here - both bodies already say which source failed.
        assert!(!rendered[0].contains("Fleet") && !rendered[0].contains("Work"), "{:?}", rendered[0]);
        assert!(line_with(&rendered, "Fleet unavailable").contains("Fleet unavailable"));
        assert!(line_with(&rendered, "Work unavailable").contains("Work unavailable"));

        // A retained snapshot behind the newest failure is what makes it `stale'.
        let mut app = App::new();
        app.finish_refresh(Err(failure()), at(86_400 + 9));
        app.finish_work_refresh(Ok(WorkBuckets::default()), at(86_400));
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 11));
        let rendered = body(&render(&app, 100, 30));
        assert!(rendered[0].contains("stale — refresh failed at 00:00:11"), "{:?}", rendered[0]);
    }

    #[test]
    fn one_failed_pane_does_not_apply_failure_style_to_the_fresh_pane() {
        let mut app = populated();
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 5));

        let buffer = render(&app, 99, 60);
        let rendered = lines(&buffer);
        assert_eq!(style_where(&buffer, "Work unavailable").fg, Some(RED));
        assert_eq!(
            style_where(&buffer, "Fleet —").fg,
            Some(BLUE),
            "the healthy, focused pane keeps its own colour: {rendered:?}"
        );
        assert!(line_with(&rendered, "Xavier").contains("● Xavier"), "and its own rows");
        assert_eq!(style_where(&buffer, "● Xavier").fg, Some(GREEN));
    }

    #[test]
    fn healthy_peer_shows_its_last_refresh_time() {
        let mut app = App::new();
        app.finish_refresh(
            Ok(vec![working("Xavier", "planner", "plan", "cb-kcs")]),
            at(86_400 + 4),
        );
        app.finish_work_refresh(Err(bd_failure()), at(86_400 + 5));

        let rendered = body(&render(&app, 100, 30));
        assert!(
            line_with(&rendered, "Fleet — refreshed 00:00:04").contains("refreshed 00:00:04"),
            "{rendered:?}"
        );
        assert!(!rendered.iter().any(|line| line.contains("Fleet 1")), "not the count: {rendered:?}");

        // The other way round, and with the ordinary titles back once both are fresh.
        let mut app = App::new();
        app.finish_refresh(Err(failure()), at(86_400 + 5));
        app.finish_work_refresh(Ok(WorkBuckets::default()), at(86_400 + 4));
        let rendered = body(&render(&app, 100, 30));
        assert!(line_with(&rendered, "Work — refreshed 00:00:04").contains("refreshed 00:00:04"));

        app.finish_refresh(Ok(vec![working("Xavier", "planner", "plan", "cb-kcs")]), at(86_400 + 6));
        let rendered = body(&render(&app, 100, 30));
        assert!(line_with(&rendered, "Fleet 1").contains("Fleet 1"));
        assert_eq!(rendered[index_of(&rendered, "Claimed 0") - 1], "Work");
    }

    #[test]
    fn tiny_screen_still_replaces_both_panes() {
        let mut app = populated();
        app.finish_work_refresh(
            Ok(WorkBuckets {
                claimed: vec![bead("cb-123", Some(1), "Preserve session output")],
                ..WorkBuckets::default()
            }),
            at(86_400),
        );

        for (width, height) in [(34, 9), (39, 20), (100, 11)] {
            let joined = body(&render(&app, width, height)).join("\n");
            assert!(joined.contains("Terminal too small"), "{width}x{height}: {joined}");
            assert!(!joined.contains("Xavier"), "no fleet rows below the floor: {joined}");
            assert!(!joined.contains("Claimed"), "and no work sections either: {joined}");
            assert!(!joined.contains("cb-123"), "{joined}");
        }

        // 40x12 is the floor itself, and all three panes are there rather than replaced. The
        // fleet's own rows are below its one inner row at that size (cb-kcs.2.1's three-pane
        // stack), so what is asserted here is that the screen is the fleet screen at all.
        let rendered = body(&render(&app, 40, 12));
        assert!(line_with(&rendered, "AGENT").contains("AGENT"));
        assert!(!rendered.join("\n").contains("Terminal too small"));
        let metrics = metrics(&app, now(), Rect::new(0, 0, 40, 12));
        assert!(
            metrics.work.content_lines > metrics.work.viewport_lines,
            "the work sections are below the fold, and scrolling is what reaches them"
        );
    }

    // --- the standby row (cb-kcs.4.1) -----------------------------------------------------------

    #[test]
    fn a_standby_row_is_a_blue_dotted_circle_and_its_condition() {
        let mut app = App::new();
        app.armed = ["Beast"].into_iter().map(String::from).collect();
        app.finish_refresh(
            Ok(vec![
                row("Beast", "planner", RowState::Dead),
                working("Xavier", "planner", "plan", "cb-kcs"),
            ]),
            at(86_400),
        );
        app.set_standby_labels(
            [("Beast".to_string(), "→ buffer<4".to_string())]
                .into_iter()
                .collect(),
        );
        app.selected = Some("Beast".to_string());

        let buffer = render(&app, 120, 24);
        let rendered = body(&buffer);
        let line = line_with(&rendered, "Beast");
        assert!(line.contains('◌'), "{rendered:?}");
        assert!(line.contains("standby"), "{rendered:?}");
        assert!(line.contains("→ buffer<4"), "{rendered:?}");

        let glyph = style_of(&buffer, "◌");
        assert_eq!(glyph.fg, Some(BLUE));
        let condition = style_where(&buffer, "→ buffer<4");
        assert_eq!(condition.fg, Some(BLUE));
        // Its own span, so the selection band sits beneath it and the colour survives.
        assert_eq!(condition.bg, Some(SELECTED_BG));
        assert_eq!(glyph.bg, Some(SELECTED_BG));
    }

    #[test]
    fn a_ten_implementer_fleet_still_reads_its_whole_condition() {
        // `→ buffer<10` is eleven cells; the column takes them rather than truncating to the lie
        // `→ buffer<1`.
        let mut app = App::new();
        app.armed = ["Beast"].into_iter().map(String::from).collect();
        app.finish_refresh(Ok(vec![row("Beast", "planner", RowState::Dead)]), at(86_400));
        app.set_standby_labels(
            [("Beast".to_string(), "→ buffer<10".to_string())]
                .into_iter()
                .collect(),
        );

        let rendered = body(&render(&app, 120, 24));
        assert!(line_with(&rendered, "Beast").contains("→ buffer<10"), "{rendered:?}");
    }

    /// Seventeen cells, where `✗ refused` and `✗ code 137` fit inside `BEAD_FLOOR`. The column
    /// sizes to the cell it will actually DRAW - a bead id, a verdict, or a standby condition -
    /// and not to `FleetRow::bead` alone, which is only the first of the three.
    #[test]
    fn a_row_that_gave_up_says_how_many_starts_failed() {
        let mut app = App::new();
        app.finish_refresh(Ok(vec![row("Xavier", "planner", RowState::Dead)]), at(86_400));
        app.set_exits(
            [("Xavier".to_string(), LastExit::GaveUp { failures: 5 })]
                .into_iter()
                .collect(),
        );
        app.selected = Some("Xavier".to_string());

        // Below `SPLIT_COLUMNS`, so the Fleet pane has the whole width: seventeen cells do not
        // fit in the 40-column Fleet pane of a split screen, and the case below is what says so.
        let buffer = render(&app, 80, 24);
        let rendered = body(&buffer);
        assert!(
            line_with(&rendered, "Xavier").contains("✗ 5 failed starts"),
            "drawn whole: {rendered:?}"
        );
        let cell = style_where(&buffer, "✗ 5 failed starts");
        assert_eq!(cell.fg, Some(RED));
        assert_eq!(cell.bg, Some(SELECTED_BG), "red survives the selection band");
    }

    #[test]
    fn the_bead_column_is_sized_by_the_cell_it_draws() {
        let rows = vec![row("Xavier", "planner", RowState::Dead)];
        let exits: BTreeMap<String, LastExit> =
            [("Xavier".to_string(), LastExit::GaveUp { failures: 5 })]
                .into_iter()
                .collect();
        let columns = columns(&rows, 80, &BTreeMap::new(), &exits);
        assert_eq!(columns.bead, 18, "seventeen cells and the column's own gap");

        // A pane too narrow to spare them cuts the cell - the clamp below the measurement,
        // unchanged - rather than widening the column past the pane.
        let narrow = self::columns(&rows, 40, &BTreeMap::new(), &exits);
        assert!(narrow.bead < 18, "the clamp still bites: {}", narrow.bead);
        let mut app = App::new();
        app.finish_refresh(Ok(rows), at(86_400));
        app.set_exits(exits);
        let rendered = body(&render(&app, 40, 24));
        assert!(
            !line_with(&rendered, "Xavier").contains("failed starts"),
            "{rendered:?}"
        );
    }

    /// A crash is the ONLY way a row reaches the backoff - a refusal is parked from the first
    /// failure - so the record it left behind must not be what the row shows. The elisp being
    /// ported picks the cell by STATE (`cerebro--entry`), and so does this.
    #[test]
    fn a_backing_off_row_shows_its_countdown_and_not_the_crash_behind_it() {
        let mut app = App::new();
        app.armed = ["Xavier"].into_iter().map(String::from).collect();
        app.set_exits(
            [("Xavier".to_string(), LastExit::Code(137))].into_iter().collect(),
        );
        app.finish_refresh(Ok(vec![row("Xavier", "planner", RowState::Dead)]), at(86_400));
        assert_eq!(app.fleet_rows()[0].state, RowState::Standby, "a crash is retried");
        app.set_standby_labels(
            [("Xavier".to_string(), "↻ retry in 30s, 2 failed".to_string())]
                .into_iter()
                .collect(),
        );

        let buffer = render(&app, 80, 24);
        let rendered = body(&buffer);
        let line = line_with(&rendered, "Xavier");
        assert!(line.contains("↻ retry in 30s, 2 failed"), "drawn whole: {rendered:?}");
        assert!(!line.contains("✗ code 137"), "a bead, a verdict or a condition, never two: {line}");
        assert_eq!(style_where(&buffer, "↻ retry in 30s, 2 failed").fg, Some(BLUE));
    }

    /// Arming is roster-driven, not role-driven: a `standby` roster row of a role with no board
    /// trigger has no condition to show, and its crash must not become invisible on a row nothing
    /// will ever retry.
    #[test]
    fn a_standby_row_with_no_condition_still_shows_why_it_died() {
        let mut app = App::new();
        app.armed = ["Moira"].into_iter().map(String::from).collect();
        app.set_exits([("Moira".to_string(), LastExit::Code(137))].into_iter().collect());
        app.finish_refresh(
            Ok(vec![row("Moira", "user-feedback", RowState::Dead)]),
            at(86_400),
        );
        assert_eq!(app.fleet_rows()[0].state, RowState::Standby);
        // `standby_cell` answers `None` for this role, so `start_due` records no label for it.
        assert!(app.standby_labels.is_empty());

        let buffer = render(&app, 80, 24);
        let rendered = body(&buffer);
        assert!(line_with(&rendered, "Moira").contains("✗ code 137"), "{rendered:?}");
        assert_eq!(style_where(&buffer, "✗ code 137").fg, Some(RED));
    }

    #[test]
    fn a_standby_session_pane_says_standby() {
        let mut app = App::new();
        app.armed = ["Beast"].into_iter().map(String::from).collect();
        app.finish_refresh(Ok(vec![row("Beast", "planner", RowState::Dead)]), at(86_400));
        app.selected = Some("Beast".to_string());
        app.set_session_view(SessionView::Ended {
            at: now(),
            lines: std::sync::Arc::new(vec![Line::from("a retained pass")]),
        });

        // The Session pane's title sits in its own right-hand border row, which `body` folds
        // into the Fleet pane's title line - so this reads the raw screen.
        let rendered = lines(&render(&app, 120, 24));
        assert!(
            rendered.iter().any(|line| line.contains("Beast — standby")),
            "{rendered:?}"
        );
        assert!(
            !rendered.iter().any(|line| line.contains("Beast — ended")),
            "{rendered:?}"
        );
    }
}
