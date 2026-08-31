//! The read-only fleet screen, drawn from `App` and an injected `now` and from nothing else.
//!
//! No function here reads a file, runs a program or asks the clock: two draws of one `App` at one
//! `now` produce the same bytes, which is what makes the `TestBackend` cases below assertions
//! about the screen rather than about the machine they run on.
//!
//! The row vocabulary is `emacs/cerebro.el`'s, deliberately unchanged (`cerebro--glyph`,
//! `cerebro--elapsed`, `cerebro--state-label`, `cerebro--entry`): a navigator reading this screen
//! beside `M-x cerebro` must not have to learn a second set of glyphs, and a difference between
//! the two would read as a difference in the fleet. Emacs-only signals are absent rather than
//! guessed - there is no `standby` row here and no stop-flag mark, because neither is in this
//! reader's normalized model, and inventing one would show supervisor intent as observed fact.

use chrono::{DateTime, Utc};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};
use ratatui::Frame;

use crate::app::{App, PaneContent};
use crate::model::{FleetRow, RowState};

/// The floor the whole document needs. Below it the screen says so and shows nothing else: half a
/// row of a fleet is worse than a sentence saying the window is too small.
pub const MIN_COLUMNS: u16 = 40;
pub const MIN_ROWS: u16 = 12;

/// At and above this width the Role and For columns are shown; below it only Agent, State and
/// Bead survive, which is what the navigator chose over squeezing five columns into forty.
pub const WIDE_COLUMNS: u16 = 64;

/// The exact title agreed in the parent epic's interview, em dash and all.
const TITLE: &str = "Cerebro — read-only";

const AGENT_FLOOR: usize = 14;
const ROLE_FLOOR: usize = 13;
const STATE_FLOOR: usize = 12;
const BEAD_FLOOR: usize = 10;

const GREEN: Color = Color::Green;
const GOLD: Color = Color::Yellow;
const BLUE: Color = Color::Blue;
const RED: Color = Color::Red;

fn dim() -> Style {
    Style::default().add_modifier(Modifier::DIM)
}

/// What one frame's geometry came to, for the caller that has to clamp the scroll offset and page
/// by what the navigator can actually see.
///
/// `draw` does not return it: the event loop needs the numbers between frames as well as after
/// one, so they are computed by the same functions the renderer draws from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Metrics {
    pub document_lines: usize,
    pub viewport_lines: usize,
}

/// The geometry one draw of APP at NOW in AREA would produce.
pub fn metrics(app: &App, now: DateTime<Utc>, area: Rect) -> Metrics {
    if too_small(area) {
        return Metrics {
            document_lines: 0,
            viewport_lines: 0,
        };
    }
    let inner = inner_area(pane_area(area));
    Metrics {
        document_lines: document(app, now, area.width).len(),
        viewport_lines: inner.height as usize,
    }
}

fn too_small(area: Rect) -> bool {
    area.width < MIN_COLUMNS || area.height < MIN_ROWS
}

fn pane_area(area: Rect) -> Rect {
    Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).split(area)[1]
}

fn inner_area(pane: Rect) -> Rect {
    Block::default().borders(Borders::ALL).inner(pane)
}

/// Render APP at NOW into FRAME.
pub fn draw(frame: &mut Frame<'_>, app: &App, now: DateTime<Utc>) {
    let area = frame.area();
    if too_small(area) {
        draw_too_small(frame, area);
        return;
    }
    let rows = Layout::vertical([Constraint::Length(1), Constraint::Min(0)]).split(area);
    frame.render_widget(Paragraph::new(header_line(app)), rows[0]);

    let pane = rows[1];
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(pane_color(app)))
        .title(Span::styled(
            pane_title(app),
            Style::default().fg(pane_color(app)),
        ));
    // The wide/narrow decision is about the TERMINAL the navigator sized, not about the pane's
    // inner width: 64 columns is what was agreed, and taking the border off first would move the
    // boundary to 66 for no reason anyone could see.
    let lines = document(app, now, area.width);
    frame.render_widget(
        Paragraph::new(lines)
            .block(block)
            .scroll((u16::try_from(app.scroll).unwrap_or(u16::MAX), 0)),
        pane,
    );
}

/// Below the floor the document is replaced, not cropped: the heading and these seven lines are
/// the whole screen, and the quit keys are named because a navigator who cannot resize still has
/// to get out.
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

fn pane_color(app: &App) -> Color {
    match &app.fleet.content {
        PaneContent::Stale { .. } => GOLD,
        PaneContent::Unavailable { .. } => RED,
        _ => BLUE,
    }
}

fn pane_title(app: &App) -> String {
    match &app.fleet.content {
        PaneContent::Loading => "Fleet".to_string(),
        PaneContent::Fresh { value, .. } => format!("Fleet {}", value.len()),
        PaneContent::Stale { failed_at, .. } => {
            format!("Fleet — stale since {}", clock(*failed_at))
        }
        PaneContent::Unavailable { .. } => "Fleet unavailable".to_string(),
    }
}

/// The one status line: the title, what is happening to the fleet right now, and the keys.
///
/// `g retry` rather than `g refresh` once something has failed - the key is the same, and what it
/// is for has changed.
fn header_line(app: &App) -> Line<'static> {
    let mut spans = vec![Span::raw(TITLE)];
    if app.fleet.refreshing {
        spans.push(Span::styled(" | refreshing...", dim()));
    }
    match &app.fleet.content {
        PaneContent::Stale { failed_at, .. } => spans.push(Span::styled(
            format!(" | stale — refresh failed at {}", clock(*failed_at)),
            Style::default().fg(GOLD),
        )),
        PaneContent::Unavailable { failed_at, .. } => spans.push(Span::styled(
            format!(" | refresh failed at {}", clock(*failed_at)),
            Style::default().fg(RED),
        )),
        _ => {}
    }
    let refresh_key = match &app.fleet.content {
        PaneContent::Stale { .. } | PaneContent::Unavailable { .. } => "g retry",
        _ => "g refresh",
    };
    spans.push(Span::styled(
        format!(" | ↑/↓/PgUp/PgDn scroll | {refresh_key} | q/Esc/Ctrl-C quit"),
        dim(),
    ));
    Line::from(spans)
}

/// The pane's whole document, before scrolling. WIDTH is the terminal's own width, which decides
/// how many columns each row carries.
fn document(app: &App, now: DateTime<Utc>, width: u16) -> Vec<Line<'static>> {
    match &app.fleet.content {
        PaneContent::Loading => vec![Line::from(Span::styled("Loading fleet...", dim()))],
        PaneContent::Fresh { value, .. } => fleet_lines(value, now, width),
        PaneContent::Stale { value, error, .. } => {
            let mut lines = vec![
                Line::from(Span::styled(error.clone(), Style::default().fg(GOLD))),
                Line::from(""),
            ];
            lines.extend(fleet_lines(value, now, width));
            lines.push(Line::from(""));
            lines.push(Line::from(Span::styled(
                "The last successful fleet snapshot remains visible.",
                dim(),
            )));
            lines
        }
        PaneContent::Unavailable { error, .. } => vec![
            Line::from(Span::styled(error.clone(), Style::default().fg(RED))),
            Line::from(""),
            Line::from("No fleet snapshot is available."),
            Line::from("Press g to retry."),
        ],
    }
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
fn columns(rows: &[FleetRow], width: u16) -> Columns {
    let longest = |values: Vec<usize>| values.into_iter().max().unwrap_or(0);
    let agent = AGENT_FLOOR.max(2 + longest(rows.iter().map(|r| r.name.chars().count()).collect()));
    let role = ROLE_FLOOR.max(1 + longest(rows.iter().map(|r| r.role.chars().count()).collect()));
    let bead = BEAD_FLOOR.max(
        1 + longest(
            rows.iter()
                .map(|r| r.bead.as_deref().unwrap_or("").chars().count())
                .collect(),
        ),
    );
    Columns {
        agent,
        role,
        state: STATE_FLOOR,
        bead,
        wide: width >= WIDE_COLUMNS,
    }
}

fn fleet_lines(rows: &[FleetRow], now: DateTime<Utc>, width: u16) -> Vec<Line<'static>> {
    let columns = columns(rows, width);
    let mut lines = vec![heading(&columns)];
    for row in rows {
        lines.push(row_line(row, now, &columns));
        // A malformed state file gets its parser's own words, on its own line, rather than a
        // pane-wide failure: one unreadable file must not hide eighteen readable rows.
        if row.state == RowState::Invalid {
            if let Some(diagnostic) = &row.diagnostic {
                lines.push(Line::from(vec![
                    Span::raw("  "),
                    Span::styled(diagnostic.clone(), Style::default().fg(RED)),
                ]));
            }
        }
    }
    lines
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

fn row_line(row: &FleetRow, now: DateTime<Utc>, columns: &Columns) -> Line<'static> {
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
    spans.push(Span::styled(
        pad(row.bead.as_deref().unwrap_or(""), columns.bead),
        emphasized(Style::default(), attention),
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
    use crate::model::AgentKind;
    use crate::readers::ReadError;
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

    fn line_with<'a>(rendered: &'a [String], needle: &str) -> &'a String {
        rendered.iter().find(|line| line.contains(needle)).unwrap_or_else(|| {
            panic!("no line contains {needle:?}; screen was:\n{}", rendered.join("\n"))
        })
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

        let heading = line_with(&rendered, "AGENT");
        for column in ["AGENT", "ROLE", "STATE", "BEAD", "FOR"] {
            assert!(heading.contains(column), "the wide heading shows {column}: {heading:?}");
        }

        let xavier = line_with(&rendered, "Xavier");
        assert!(xavier.contains("● Xavier"), "{xavier:?}");
        assert!(xavier.contains("planner"), "{xavier:?}");
        assert!(xavier.contains("plan "), "a working row shows its phase: {xavier:?}");
        assert!(xavier.contains("cb-kcs"), "{xavier:?}");
        assert!(xavier.contains("18m 18m"), "bead time and phase time: {xavier:?}");

        let cerebro = line_with(&rendered, "? Cerebro");
        assert!(cerebro.contains("asking"), "{cerebro:?}");
        let moira = line_with(&rendered, "Moira");
        assert!(moira.contains("◆ Moira") && moira.contains("idle"), "{moira:?}");
        let psylocke = line_with(&rendered, "Psylocke");
        assert!(psylocke.contains("○ Psylocke") && psylocke.contains("dead"), "{psylocke:?}");
        let storm = line_with(&rendered, "Storm");
        assert!(storm.contains("◐ Storm") && storm.contains("waiting"), "{storm:?}");

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
        assert!(app.begin_refresh());
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

        let rendered = lines(&render(&app, 100, 20));
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

        let rendered = lines(&render(&app, 100, 20));
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

        let buffer = render(&app, 100, 20);
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

        let buffer = render(&app, 100, 20);
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
        let rendered = lines(&render(&app, 100, 20));
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
            assert!(!joined.contains("read-only"), "the document is replaced, not added to");
        }

        // 40x12 is the floor itself, and it renders the fleet.
        let rendered = lines(&render(&app, 40, 12));
        assert!(rendered[0].contains("Cerebro — read-only"));
        assert!(line_with(&rendered, "Xavier").contains("● Xavier"));
    }

    #[test]
    fn scrolling_moves_the_document_under_the_viewport() {
        let mut app = App::new();
        let rows: Vec<FleetRow> = (0..30)
            .map(|i| row(&format!("Agent{i:02}"), "implementer", RowState::Dead))
            .collect();
        app.finish_refresh(Ok(rows), at(86_400));

        let top = lines(&render(&app, 100, 14));
        assert!(top.iter().any(|line| line.contains("Agent00")));
        assert!(!top.iter().any(|line| line.contains("Agent20")));

        app.scroll = 20;
        let scrolled = lines(&render(&app, 100, 14));
        assert!(!scrolled.iter().any(|line| line.contains("Agent00")));
        assert!(scrolled.iter().any(|line| line.contains("Agent20")));

        // The geometry the caller clamps by: one heading line plus thirty rows, in a viewport of
        // the pane's inner height.
        let area = Rect::new(0, 0, 100, 14);
        let metrics = metrics(&app, now(), area);
        assert_eq!(metrics.document_lines, 31);
        assert_eq!(metrics.viewport_lines, 11);
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
        let buffer = render(&app, 100, 20);
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
}
