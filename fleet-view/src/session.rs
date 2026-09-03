//! One agent CLI per pty, and the pure functions that turn its bytes into a pane.
//!
//! The module splits the way the rest of the crate does. The **pure half** - `key_bytes`,
//! `paste_bytes`, `exit_line`, `materialise`, `transcript` - is tested over hand-driven parsers
//! and plain data. The **impure half** - `Session`, `SessionHost` - owns a process. `crate::ui`
//! sees neither: it is handed a slice of already-materialised `Line`s, exactly as it is handed
//! the Work pane's lines, which is what keeps `ui::draw` pure while a child writes continuously
//! into a parser on another thread.

use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use chrono::{DateTime, Utc};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

use crate::readers::{ReadError, ReaderPaths};

/// How many lines of a finished pass are kept. The navigator's number, agreed in the parent
/// epic's interview and unchanged here.
pub const SCROLLBACK_LINES: usize = 10_000;

/// The size a pty is opened at, before the first frame has told us how big the pane is.
pub const INITIAL_ROWS: u16 = 24;
pub const INITIAL_COLS: u16 = 80;

/// The bytes a child should receive for KEY, or `None` when this crate has no mapping for it.
///
/// `None` is dropped in silence - the navigator's choice, taken over naming the key in the
/// header. The table is incomplete by construction (S2): `F(5)`-`F(12)`, keypad keys and most
/// modifier combinations beyond a plain Ctrl or Alt have no entry, and each of those is a bug
/// report this crate now owns. `Tab` and `Shift-Tab` never reach here at all - they are how a
/// navigator leaves the session, `Tab` to Fleet and `Shift-Tab` to Work, so `main` takes both
/// before this is called. `Ctrl-I` remains available as `0x09` through the CONTROL arm, which is
/// how a literal tab still reaches a child.
///
/// `Backspace` is `0x7f`, not `0x08`: that is what every terminal the fleet runs under sends by
/// default and what an agent CLI's line editor expects. `Ctrl-H` remains available as `0x08`
/// through the CONTROL arm.
pub fn key_bytes(key: KeyEvent) -> Option<Vec<u8>> {
    // A terminal with the kitty protocol on reports releases too, and forwarding both halves of
    // one keystroke would type everything twice - the reason `App::on_key` returns early on one.
    if key.kind == KeyEventKind::Release {
        return None;
    }
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    match key.code {
        KeyCode::Char(c) if control => control_byte(c).map(|byte| vec![byte]),
        KeyCode::Char(c) if alt => {
            let mut bytes = vec![0x1b];
            bytes.extend_from_slice(c.encode_utf8(&mut [0u8; 4]).as_bytes());
            Some(bytes)
        }
        KeyCode::Char(c) => Some(c.encode_utf8(&mut [0u8; 4]).as_bytes().to_vec()),
        KeyCode::Enter => Some(vec![b'\r']),
        KeyCode::Backspace => Some(vec![0x7f]),
        KeyCode::Esc => Some(vec![0x1b]),
        KeyCode::Left => Some(b"\x1b[D".to_vec()),
        KeyCode::Right => Some(b"\x1b[C".to_vec()),
        KeyCode::Up => Some(b"\x1b[A".to_vec()),
        KeyCode::Down => Some(b"\x1b[B".to_vec()),
        KeyCode::Home => Some(b"\x1b[H".to_vec()),
        KeyCode::End => Some(b"\x1b[F".to_vec()),
        KeyCode::Insert => Some(b"\x1b[2~".to_vec()),
        KeyCode::Delete => Some(b"\x1b[3~".to_vec()),
        KeyCode::PageUp => Some(b"\x1b[5~".to_vec()),
        KeyCode::PageDown => Some(b"\x1b[6~".to_vec()),
        KeyCode::F(1) => Some(b"\x1bOP".to_vec()),
        KeyCode::F(2) => Some(b"\x1bOQ".to_vec()),
        KeyCode::F(3) => Some(b"\x1bOR".to_vec()),
        KeyCode::F(4) => Some(b"\x1bOS".to_vec()),
        _ => None,
    }
}

/// The C0 control byte for `Ctrl-<c>`: `a`-`z` and the six punctuation keys ASCII actually
/// defines one for. Anything else - `Ctrl-1`, `Ctrl-ä` - has no byte and is dropped.
fn control_byte(c: char) -> Option<u8> {
    let upper = c.to_ascii_uppercase();
    match upper {
        'A'..='Z' | '@' | '[' | '\\' | ']' | '^' | '_' => Some(upper as u8 - b'@'),
        _ => None,
    }
}

/// The bracketed-paste opening marker a child recognises.
const PASTE_START: &[u8] = b"\x1b[200~";
/// Its closing marker.
const PASTE_END: &[u8] = b"\x1b[201~";

/// TEXT wrapped in the bracketed-paste markers a child recognises: `ESC [ 200 ~`, the text,
/// `ESC [ 201 ~`. An agent composer that treats a bare newline as submit therefore receives four
/// pasted lines as one block rather than submitting the first of them.
///
/// The text is passed through unchanged except that any `ESC [ 201 ~` inside it is stripped: a
/// paste that closes its own bracket would hand the rest of itself to the child as keystrokes.
pub fn paste_bytes(text: &str) -> Vec<u8> {
    let mut bytes = PASTE_START.to_vec();
    bytes.extend_from_slice(text.replace("\x1b[201~", "").as_bytes());
    bytes.extend_from_slice(PASTE_END);
    bytes
}

/// vt100's colour in ratatui's vocabulary: the default stays the terminal's own (`None`, so no
/// `fg`/`bg` is set at all), an indexed colour becomes `Color::Indexed` and a true colour
/// `Color::Rgb`. Both prototype runs are the evidence that this round trip preserves what an
/// agent CLI actually paints (S1's colour lists).
fn colour(from: vt100::Color) -> Option<Color> {
    match from {
        vt100::Color::Default => None,
        vt100::Color::Idx(index) => Some(Color::Indexed(index)),
        vt100::Color::Rgb(r, g, b) => Some(Color::Rgb(r, g, b)),
    }
}

/// One cell's style, in ratatui's vocabulary.
fn cell_style(cell: &vt100::Cell) -> Style {
    let mut style = Style::default();
    if let Some(fg) = colour(cell.fgcolor()) {
        style = style.fg(fg);
    }
    if let Some(bg) = colour(cell.bgcolor()) {
        style = style.bg(bg);
    }
    for (on, modifier) in [
        (cell.bold(), Modifier::BOLD),
        (cell.dim(), Modifier::DIM),
        (cell.italic(), Modifier::ITALIC),
        (cell.underline(), Modifier::UNDERLINED),
        (cell.inverse(), Modifier::REVERSED),
    ] {
        if on {
            style = style.add_modifier(modifier);
        }
    }
    style
}

/// One row of SCREEN, as a `Line` whose spans carry the cell colours and attributes.
///
/// Cells are merged into a span while their style is unchanged, so a row of one colour is one
/// span rather than eighty. Trailing blank cells are dropped: a pane whose every row is padded to
/// its full width cannot be scrolled sensibly and doubles what a retained transcript costs.
///
/// A wide glyph's continuation cell contributes nothing - its contents belong to the cell before
/// it, and emitting them again would print the glyph twice.
fn row_line(screen: &vt100::Screen, row: u16, cols: u16) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut pending = String::new();
    let mut pending_style = Style::default();
    let flush = |text: &mut String, style: Style, spans: &mut Vec<Span<'static>>| {
        if !text.is_empty() {
            spans.push(Span::styled(std::mem::take(text), style));
        }
    };
    for col in 0..cols {
        let Some(cell) = screen.cell(row, col) else { continue };
        if cell.is_wide_continuation() {
            continue;
        }
        let style = cell_style(cell);
        let contents = cell.contents();
        // An untouched cell reads as empty; on screen it is a space, and a span of spaces is what
        // carries a background colour across a gap.
        let text = if contents.is_empty() { " " } else { contents };
        if style != pending_style {
            flush(&mut pending, pending_style, &mut spans);
            pending_style = style;
        }
        pending.push_str(text);
    }
    flush(&mut pending, pending_style, &mut spans);
    trim_trailing_blanks(&mut spans);
    Line::from(spans)
}

/// Drop the trailing run of unstyled spaces from SPANS - the padding a terminal row always
/// carries. A span that is blank but *styled* is kept: a coloured background running to the edge
/// of the screen is something the child painted deliberately.
fn trim_trailing_blanks(spans: &mut Vec<Span<'static>>) {
    while let Some(last) = spans.last_mut() {
        if last.style != Style::default() {
            break;
        }
        let trimmed = last.content.trim_end_matches(' ').to_string();
        if trimmed.is_empty() {
            spans.pop();
        } else {
            last.content = trimmed.into();
            break;
        }
    }
}

/// Every visible row of SCREEN, top to bottom.
pub fn materialise(screen: &vt100::Screen, rows: u16, cols: u16) -> Vec<Line<'static>> {
    (0..rows).map(|row| row_line(screen, row, cols)).collect()
}


/// The signal `portable_pty::Child::kill` sends FIRST on the platforms this fleet runs on.
///
/// **SIGHUP, not SIGKILL, and it is only the first of two.** The plan for cb-kcs.2.3 allowed for
/// either and asked for the crate to be read rather than assumed. `portable-pty` 0.9's
/// `ChildKiller for std::process::Child` (`src/lib.rs:340-373`) sends `libc::SIGHUP`, then polls
/// `try_wait` five times over about 200ms, and **falls through to `std::process::Child::kill` -
/// SIGKILL - if the child is still alive at the end of that**. So a child that installs a SIGHUP
/// handler and does not exit within the grace period dies by signal 9 while this constant says 1.
///
/// That is a known imprecision, and it is deliberately not papered over. This view can report a
/// number at all only because it asked for the kill - `ended_from` cannot, since 0.9 renders a
/// terminating signal as a NAME (`"Killed: 9"`) rather than as an integer - and the one number it
/// can state without guessing is the signal it causes to be delivered first. Reporting the
/// escalation honestly would need an exit status the crate does not expose; when it does, this is
/// the one place to change.
///
/// The same grace loop is why `Session::signal` is not free: `child.kill()` can block its caller -
/// the keystroke thread - for up to about 200ms.
const KILL_SIGNAL: i32 = 1;

/// How a child ended, in this crate's own vocabulary rather than the pty crate's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ended {
    Status(u32),
    Signal(i32),
    /// This view ended the session on purpose - a finished pass, or a stop flag.
    ByView,
}

/// The line the view writes under a finished pass, and whether it is a failure (red).
///
/// The three sentences are the navigator's own, verbatim (Q4): a failed pass is one red line and
/// keeps its ordinary border, because a red border is this view's spelling for *a reader failed*
/// and spending it here would make two different things look the same.
pub fn exit_line(name: &str, ended: Ended) -> (String, bool) {
    match ended {
        Ended::Status(0) => (format!("{name} finished with status 0."), false),
        Ended::Status(status) => (format!("{name} finished with status {status}."), true),
        Ended::Signal(signal) => (format!("{name} was killed by signal {signal}."), true),
        // ONE sentence for both causes - a finished pass and a stop flag - and in the ordinary
        // colour (the navigator's choice, Q3.1). Ending a session is technically a signal 9, so
        // without this a pass that went perfectly would close in red saying it was killed; and
        // the header notice has already said which of the two it was, so a second sentence here
        // would be two rules to keep in step.
        Ended::ByView => (format!("{name} finished its pass; the view ended it."), false),
    }
}

/// `portable_pty::ExitStatus` in this crate's vocabulary.
///
/// **Every non-success is `Status`, and `Signal` is never produced here.** The plan allowed for
/// either, depending on what the vendored crate can report, and 0.9 reports a terminating signal
/// as a NAME (`strsignal`: `"Killed: 9"`, `"Terminated"`) rather than as a number, while the
/// sentence the navigator approved carries a number. Rendering `was killed by signal Killed: 9.`
/// to keep the arm reachable would be worse than the documented degrade, so `Ended::Signal` is
/// reached by `exit_line`'s own unit case alone. Nothing in the fleet signals a session until `k`
/// lands in cb-kcs.2.3, and that is the bead where a number can be obtained honestly.
fn ended_from(status: portable_pty::ExitStatus) -> Ended {
    Ended::Status(status.exit_code())
}

/// How many lines have scrolled off PARSER's screen, at most `SCROLLBACK_LINES`.
///
/// `Parser::set_scrollback` clamps to what is actually available and `Screen::scrollback` reports
/// where it landed, so this asks the parser rather than the documentation. The offset is restored
/// to 0 before it returns: a parser left scrolled back would draw a live child's old screen.
fn scrollback_depth(parser: &mut vt100::Parser) -> usize {
    parser.screen_mut().set_scrollback(SCROLLBACK_LINES);
    let depth = parser.screen().scrollback();
    parser.screen_mut().set_scrollback(0);
    depth
}

/// The whole of a finished pass: every line that scrolled off, oldest first, then the final
/// screen, then the view's own closing lines.
///
/// Built once, when the child is reaped, and the parser and the pty are dropped immediately after
/// - a retained pass is a document, not a live terminal. Trailing blank lines are trimmed before
/// the closing lines are appended, or the exit line sits twenty rows below the last thing the
/// agent said.
pub fn transcript(
    parser: &mut vt100::Parser,
    rows: u16,
    cols: u16,
    ended: Ended,
    name: &str,
) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    // Each window's TOP row is the one line that window brought into view, so walking the offset
    // down from the deepest to one takes every scrolled-off line exactly once.
    for offset in (1..=scrollback_depth(parser)).rev() {
        parser.screen_mut().set_scrollback(offset);
        lines.push(row_line(parser.screen(), 0, cols));
    }
    parser.screen_mut().set_scrollback(0);
    lines.extend(materialise(parser.screen(), rows, cols));
    while lines.last().is_some_and(|line| line.spans.is_empty()) {
        lines.pop();
    }
    let (text, failed) = exit_line(name, ended);
    let style = if failed { Style::default().fg(Color::Red) } else { Style::default() };
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(text, style)));
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "End of retained scrollback. Up/Down scroll while focused.".to_string(),
        Style::default().add_modifier(Modifier::DIM),
    )));
    lines
}

/// Every non-blank line of the child's own screen, as one message.
///
/// The SCREEN rather than a transcript, so nothing here has to recognise - and so nothing here can
/// mistake - the closing lines a transcript appends.
fn screen_message(session: &Session, rows: u16, cols: u16) -> String {
    let Some(lines) = session.screen(rows, cols) else { return String::new() };
    let text: Vec<String> = lines
        .iter()
        .map(|line| line.spans.iter().map(|span| span.content.as_ref()).collect::<String>())
        .map(|line| line.trim_end().to_string())
        .filter(|line| !line.trim().is_empty())
        .collect();
    text.join("\n")
}

/// A refusal, as the lines the pane draws: the launcher's own words in red, then what to do.
///
/// `scripts/launch-refused` writes exactly `cerebro: $message` to stderr, and the approved pane
/// drops that prefix before showing it - the pane's title already says whose refusal it is.
fn refusal_lines(message: &str) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = message
        .lines()
        .map(|line| line.strip_prefix("cerebro: ").unwrap_or(line).to_string())
        .map(|line| Line::from(Span::styled(line, Style::default().fg(Color::Red))))
        .collect();
    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            "The launcher refused, and said nothing.".to_string(),
            Style::default().fg(Color::Red),
        )));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "Press s to try again.".to_string(),
        Style::default().add_modifier(Modifier::DIM),
    )));
    lines
}

/// One agent CLI, in one pty, with one thread draining it.
///
/// The `Arc<RwLock<Parser>>` belongs to this struct rather than to the pty, which is the whole
/// reason a killed child's screen is still drawable (S4): the reader thread ends at EOF and the
/// parser it wrote into is untouched.
pub struct Session {
    name: String,
    child: Box<dyn portable_pty::Child + Send + Sync>,
    master: Box<dyn portable_pty::MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    parser: Arc<RwLock<vt100::Parser>>,
    /// Bytes seen so far. Zero is what `SessionView::Starting` means.
    seen: Arc<AtomicUsize>,
    size: (u16, u16),
    reader: Option<std::thread::JoinHandle<()>>,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session").field("name", &self.name).field("size", &self.size).finish()
    }
}

fn spawn_error(name: &str, error: impl std::fmt::Display) -> ReadError {
    ReadError::Spawn { source: format!("the session for {name}"), message: error.to_string() }
}

impl Session {
    /// Spawn `<scripts_dir>/launch <name>` in a fresh pty, with the consumer root as its working
    /// directory and this process's environment.
    ///
    /// The command is the launcher and the agent's name and nothing else - the same two tokens
    /// `cerebro--launch-command` builds in Emacs. No model flag, no provider flag, no prompt:
    /// every one of those is the launcher's own business, and a second opinion here is a second
    /// answer.
    pub fn spawn(name: &str, paths: &ReaderPaths) -> Result<Self, ReadError> {
        let mut command = portable_pty::CommandBuilder::new(paths.scripts_dir.join("launch"));
        command.arg(name);
        command.cwd(&paths.consumer_root);
        Self::spawn_command(name, command, INITIAL_ROWS, INITIAL_COLS)
    }

    /// `spawn`, with the command given rather than built: the seam every pty case runs through,
    /// so no test ever starts a real agent - which would claim a bead.
    pub fn spawn_command(
        name: &str,
        command: portable_pty::CommandBuilder,
        rows: u16,
        cols: u16,
    ) -> Result<Self, ReadError> {
        let rows = rows.max(1);
        let cols = cols.max(1);
        let pair = portable_pty::native_pty_system()
            .openpty(portable_pty::PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|error| spawn_error(name, error))?;
        let child = pair.slave.spawn_command(command).map_err(|error| spawn_error(name, error))?;
        // The slave is dropped here, with the child holding the only other reference to it: that
        // is what makes the master read EOF when the child ends, and the reader thread finish.
        drop(pair.slave);
        let mut reader =
            pair.master.try_clone_reader().map_err(|error| spawn_error(name, error))?;
        let writer = pair.master.take_writer().map_err(|error| spawn_error(name, error))?;
        let parser = Arc::new(RwLock::new(vt100::Parser::new(rows, cols, SCROLLBACK_LINES)));
        let seen = Arc::new(AtomicUsize::new(0));
        let thread_parser = Arc::clone(&parser);
        let thread_seen = Arc::clone(&seen);
        // Unconditional, whether or not the pane is visible or focused: a child that writes more
        // than the pty buffer holds blocks for ever if nobody drains it.
        let handle = std::thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(count) => {
                        if let Ok(mut parser) = thread_parser.write() {
                            parser.process(&buffer[..count]);
                        }
                        thread_seen.fetch_add(count, Ordering::SeqCst);
                    }
                }
            }
        });
        Ok(Self {
            name: name.to_string(),
            child,
            master: pair.master,
            writer,
            parser,
            seen,
            size: (rows, cols),
            reader: Some(handle),
        })
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Tell the child the pane's size, if it has changed. The navigator chose the pane's real
    /// size over a floor of 80x24 (Q6): a two-row pane means a two-row agent.
    pub fn resize(&mut self, rows: u16, cols: u16) {
        let (rows, cols) = (rows.max(1), cols.max(1));
        if self.size == (rows, cols) {
            return;
        }
        self.size = (rows, cols);
        let _ = self
            .master
            .resize(portable_pty::PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
        if let Ok(mut parser) = self.parser.write() {
            parser.screen_mut().set_size(rows, cols);
        }
    }

    /// Send bytes to the child. A write that fails is dropped - the child is on its way out, and
    /// the exit is what the pane will show.
    pub fn send(&mut self, bytes: &[u8]) {
        if self.writer.write_all(bytes).is_ok() {
            let _ = self.writer.flush();
        }
    }

    /// `Some(ended)` once the child has exited; never blocks.
    pub fn poll_exit(&mut self) -> Option<Ended> {
        match self.child.try_wait() {
            Ok(Some(status)) => Some(ended_from(status)),
            // A child whose status cannot be read at all is gone as far as this view is concerned,
            // and saying so is better than a pane that stays live for ever.
            Err(_) => Some(Ended::Status(1)),
            Ok(None) => None,
        }
    }

    /// The child's current screen, materialised. `None` before the first byte, which is what
    /// `SessionView::Starting` is derived from.
    pub fn screen(&self, rows: u16, cols: u16) -> Option<Vec<Line<'static>>> {
        if self.seen.load(Ordering::SeqCst) == 0 {
            return None;
        }
        let parser = self.parser.read().ok()?;
        Some(materialise(parser.screen(), rows, cols))
    }

    /// Where the child's cursor is, as (row, column) inside the pane's inner rect.
    pub fn cursor(&self) -> (u16, u16) {
        self.parser
            .read()
            .map(|parser| parser.screen().cursor_position())
            .unwrap_or((0, 0))
    }

    /// Everything the pass left behind. Consumes the session: the pty and the parser go with it.
    pub fn into_transcript(mut self, rows: u16, cols: u16, ended: Ended) -> Vec<Line<'static>> {
        // The reader thread is joined first, so every byte the child wrote before it died is in
        // the parser before the transcript is taken from it.
        self.stop();
        let name = self.name.clone();
        match self.parser.write() {
            Ok(mut parser) => transcript(&mut parser, rows, cols, ended, &name),
            // A poisoned lock means the reader thread panicked mid-write; the pass still ended,
            // and the line saying so is the one thing worth keeping.
            Err(_) => {
                let (text, failed) = exit_line(&name, ended);
                let style =
                    if failed { Style::default().fg(Color::Red) } else { Style::default() };
                vec![Line::from(Span::styled(text, style))]
            }
        }
    }

    /// Signal the child and leave it to be reaped by the next `sync`, so a killed pass becomes an
    /// ordinary retained transcript rather than vanishing. Returns the signal that is sent first -
    /// see `KILL_SIGNAL`, including what the pty crate does when the child ignores it.
    ///
    /// The reader thread is NOT joined here: it ends at EOF on its own, and joining it would make
    /// a keystroke wait for the child's whole output to drain. `child.kill()` itself is not
    /// instant either - `KILL_SIGNAL` has the measurement - but it is bounded and short.
    fn signal(&mut self) -> i32 {
        let _ = self.child.kill();
        KILL_SIGNAL
    }

    /// Kill the child and let the reader thread end at EOF. Idempotent: `into_transcript` calls
    /// it, and so does `Drop`.
    fn stop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(handle) = self.reader.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Session {
    /// A pane the navigator can no longer see must not leave an agent running against a bead
    /// nobody is watching.
    fn drop(&mut self) {
        self.stop();
    }
}


/// What the Session pane shows, materialised before the frame so `ui` stays pure over `App`.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionView {
    /// No live session and no retained pass for the selection. `ui` draws its three existing
    /// bodies from this, unchanged.
    None,
    /// Spawned, and the child has printed nothing yet.
    Starting,
    /// At most the pane's own height, rebuilt every frame - which costs nothing.
    Live { lines: Vec<Line<'static>>, cursor: (u16, u16) },
    /// A launch this view attempted and the launcher refused. Kept until that agent is started
    /// again, exactly as a retained pass is, and drawn in a red pane.
    Refused { lines: Arc<Vec<Line<'static>>>, at: DateTime<Utc> },
    /// Up to `SCROLLBACK_LINES` lines, built once when the child is reaped and shared by
    /// reference from then on. **The `Arc` is load-bearing**: `sync` runs five times a second,
    /// and cloning ten thousand `Line`s per frame would be the most expensive thing this program
    /// does.
    Ended { lines: Arc<Vec<Line<'static>>>, at: DateTime<Utc> },
}

impl Default for SessionView {
    fn default() -> Self {
        Self::None
    }
}

/// `cerebro-return-delay`'s default (`emacs/cerebro.el:1976-1989`), 0.3 seconds.
pub const RETURN_DELAY: Duration = Duration::from_millis(300);

/// A pass that has ended, kept until that agent starts again.
#[derive(Clone, Debug)]
pub struct Retained {
    pub lines: Arc<Vec<Line<'static>>>,
    pub at: DateTime<Utc>,
}

/// A stop this view performed, remembered until the child is reaped, so the retained pass says
/// what happened rather than what the pty crate could see.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Deliberate {
    /// `k`: the navigator killed it, with this signal.
    Killed(i32),
    /// Supervision ended it: a finished pass, or a stop flag.
    ByView,
}

/// Every session this process is hosting, plus every pass it has retained, by agent name.
///
/// `main` owns it. `App` never does: `App` is what the renderer reads, and a struct holding
/// process handles is not something `ui::draw` should be able to reach.
#[derive(Default, Debug)]
pub struct SessionHost {
    live: HashMap<String, Session>,
    retained: HashMap<String, Retained>,
    /// Launches this view attempted and the launcher refused, kept until that agent starts again.
    refused: HashMap<String, Retained>,
    /// Stops this view performed, remembered until the child is reaped. The reap path trusts
    /// this over whatever the pty crate says the status was, because this view is the one that
    /// stopped the child - and 0.9 renders a terminating signal as a NAME rather than a number.
    ending: HashMap<String, Deliberate>,
    /// Each name's last abnormal exit, kept by the host because the host is what reaps. Cleared
    /// by a start, exactly as a retained pass is: a verdict that outlived the run that produced
    /// it would sit on a row whose session is perfectly healthy.
    exits: BTreeMap<String, crate::lifecycle::LastExit>,
    /// Carriage returns owed to sessions that have been typed a line, and when each is due.
    pending: Vec<(String, Instant)>,
    /// Children reaped since `take_reaped` was last called. See it.
    reaped: Vec<(String, Ended)>,
}

impl SessionHost {
    /// Start NAME. Replaces that agent's retained pass, which is what "retained until the next
    /// start" means. Refuses when NAME already has a live session.
    pub fn spawn(&mut self, name: &str, paths: &ReaderPaths) -> Result<(), ReadError> {
        self.insert(name, Session::spawn(name, paths)?);
        Ok(())
    }

    /// `spawn`, with the session already made - the seam the cases use, and the one `cb-kcs.2.3`
    /// will put behind the `s` key.
    pub fn insert(&mut self, name: &str, session: Session) {
        self.retained.remove(name);
        self.refused.remove(name);
        self.ending.remove(name);
        self.exits.remove(name);
        self.live.insert(name.to_string(), session);
    }

    /// Kill NAME's live session, if there is one, and delete its state file. Returns whether there
    /// was one.
    ///
    /// The child is killed and left to be reaped by the next `sync`, so a killed pass becomes an
    /// ordinary retained view carrying `<Name> was killed by signal 1.` - the navigator's choice
    /// (Q13), and where `k` parts company with Emacs, which removes the buffer and its output
    /// with it. The stop flag is NOT touched: `k` is not a retire.
    pub fn kill(&mut self, paths: &ReaderPaths, name: &str) -> bool {
        let Some(session) = self.live.get_mut(name) else { return false };
        let signal = session.signal();
        self.ending.insert(name.to_string(), Deliberate::Killed(signal));
        // A state file that outlives its session outlives its pid, and a pid is reused.
        let _ = crate::lifecycle::delete_state_file(paths, name);
        true
    }

    /// End NAME's session because the view decided to - a finished pass, or a stop flag.
    ///
    /// Kills the child, records that this view did it so the reap says so rather than reporting a
    /// killing, and deletes the state file: a file naming a session that has been ended is a
    /// claim about a pid that no longer exists, and pids are recycled. The stop flag is NOT
    /// touched - clearing it belongs to a retire and to nothing else, and the caller does it.
    ///
    /// **The retained transcript is always kept** (the navigator's choice, Q4). `emacs/cerebro.el`
    /// keeps a buffer for an interactive role and a `waiting` implementer and kills it for an
    /// `idle` or `standby` one; that exception is deliberately not carried over. One rule instead
    /// of two, and a transcript thrown away cannot be recovered.
    ///
    /// Returns whether there was a session to end.
    pub fn end(&mut self, paths: &ReaderPaths, name: &str) -> bool {
        let Some(session) = self.live.get_mut(name) else { return false };
        session.signal();
        self.ending.insert(name.to_string(), Deliberate::ByView);
        let _ = crate::lifecycle::delete_state_file(paths, name);
        true
    }

    /// NAME's last abnormal exit, if it had one.
    pub fn last_exit(&self, name: &str) -> Option<crate::lifecycle::LastExit> {
        self.exits.get(name).copied()
    }

    /// Every child reaped since this was last called, and what ended it.
    ///
    /// A queue rather than a field on `exits`, because the two answer different questions:
    /// `exits` is the row's standing verdict and forgets a clean ending, where this is the record
    /// of an ending having happened at all - which is what cb-kcs.4.4's `exit` line is. Drained
    /// once per frame; nothing here writes a file, and this module keeps its own contract of
    /// knowing nothing about the log.
    ///
    /// **This call is the only thing that bounds the queue** - `main::log_exits` is its one caller
    /// and runs once per frame, so a host nobody drains keeps one entry per session it ever
    /// reaped. That is every bare `SessionHost` in the tests, where it is a handful of entries and
    /// the host is dropped with the case.
    pub fn take_reaped(&mut self) -> Vec<(String, Ended)> {
        std::mem::take(&mut self.reaped)
    }

    /// Every name's last abnormal exit, for `App::set_exits`. A small map cloned once per frame.
    pub fn exits(&self) -> BTreeMap<String, crate::lifecycle::LastExit> {
        self.exits.clone()
    }

    /// Is NAME a session this view may act on - live, and not one it has already stopped?
    ///
    /// `is_live` alone is not that: `end` and `kill` leave the child to be reaped by the next
    /// `sync`, so a name stays `is_live` for a frame or two after this view has finished with it,
    /// and a supervision loop reading `is_live` would end the same session on every tick and
    /// announce it every time.
    pub fn supervisable(&self, name: &str) -> bool {
        self.is_live(name) && !self.ending.contains_key(name)
    }

    /// The names of EVERY live session, in ROSTER order first: the quit-refusal pane names them,
    /// and a map's iteration order would reorder them between frames.
    ///
    /// A live session whose name the roster does not carry is still named, sorted, after the rest.
    /// That is not tidiness: the quit refusal is built from this list, and a name missing from it
    /// is an agent this view would kill on the way out - which is the one thing that pane exists
    /// to prevent. The roster is empty until a fleet read has succeeded, so it happens.
    pub fn live_names(&self, roster_order: &[String]) -> Vec<String> {
        let mut named: Vec<String> =
            roster_order.iter().filter(|name| self.live.contains_key(*name)).cloned().collect();
        let mut rest: Vec<String> = self
            .live
            .keys()
            .filter(|name| !roster_order.contains(name))
            .cloned()
            .collect();
        rest.sort();
        named.extend(rest);
        named
    }

    /// Record that NAME's launch was refused, with the launcher's own words. Replaces that agent's
    /// retained pass, the way a start does.
    ///
    /// It also records the refusal as that name's last exit. A launch that never became a process
    /// has no status for `classify_exit` to read, and without this it would leave no verdict at
    /// all - so `model::apply_standby` would restate the row as `Standby` and the trigger, having
    /// no `started_at` to measure a floor against, would launch it again on the next fleet read,
    /// for ever (cb-kcs.4.1's Q5, and the 135-launches shape it exists to prevent).
    pub fn note_refusal(&mut self, name: &str, message: &str, at: DateTime<Utc>) {
        self.retained.remove(name);
        let lines = refusal_lines(message);
        self.refused.insert(name.to_string(), Retained { lines: Arc::new(lines), at });
        self.exits.insert(name.to_string(), crate::lifecycle::LastExit::Refused);
    }

    /// Record that the view has stopped retrying NAME. Overwrites whatever exit record it had -
    /// the give-up is the more useful of the two, and the code it replaces is already on the
    /// retained screen. `insert` removing NAME's entry is what makes `s` the way back.
    pub fn note_gave_up(&mut self, name: &str, failures: u32) {
        self.exits
            .insert(name.to_string(), crate::lifecycle::LastExit::GaveUp { failures });
    }

    /// How many children are alive. This is what `SupervisorController::hosted_sessions` reads.
    pub fn live_count(&self) -> usize {
        self.live.len()
    }

    /// Is NAME's session live and able to take a keystroke?
    pub fn is_live(&self, name: &str) -> bool {
        self.live.contains_key(name)
    }

    /// Forward BYTES to NAME's live session, if there is one.
    pub fn send(&mut self, name: &str, bytes: &[u8]) {
        if let Some(session) = self.live.get_mut(name) {
            session.send(bytes);
        }
    }

    /// Send TEXT to NAME's session now, and its carriage return `RETURN_DELAY` later.
    ///
    /// Two writes, not one, and this is not a nicety: sent together they arrive in one terminal
    /// read, and a TUI that treats a burst ending in a return as a paste puts the newline in its
    /// composer instead of submitting it - which leaves a nudged agent sitting on the message it
    /// was nudged with.
    ///
    /// It goes through `send`, which does not care whether the pane is focused: a nudge is the
    /// view typing into a session nobody is looking at.
    pub fn type_line(&mut self, name: &str, text: &str, at: Instant) {
        if !self.is_live(name) {
            return;
        }
        self.send(name, text.as_bytes());
        self.pending.push((name.to_string(), at + RETURN_DELAY));
    }

    /// Send any carriage return that has come due. Called once per loop iteration, beside `sync`.
    ///
    /// A name whose session has gone in the meantime is dropped silently, exactly as the elisp
    /// timer re-checks buffer liveness before it sends.
    pub fn flush_returns(&mut self, at: Instant) {
        let due: Vec<String> = self
            .pending
            .iter()
            .filter(|(_, when)| *when <= at)
            .map(|(name, _)| name.clone())
            .collect();
        self.pending.retain(|(_, when)| *when > at);
        for name in due {
            self.send(&name, b"\r");
        }
    }

    /// Once per frame: reap any child that has exited into `retained`, resize the selected
    /// agent's session to the pane it is drawn in, and return what the pane should show.
    ///
    /// ROWS and COLS are the Session pane's own inner geometry from `ui::metrics`, so the child
    /// is always the size of the pane it is drawn in.
    pub fn sync(
        &mut self,
        selected: Option<&str>,
        rows: u16,
        cols: u16,
        now: DateTime<Utc>,
    ) -> SessionView {
        // Every child is reaped, not only the selected one: an unwatched pass that ended must
        // still become a retained transcript, and its pty must still be released.
        let ended: Vec<(String, Ended)> = self
            .live
            .iter_mut()
            .filter_map(|(name, session)| session.poll_exit().map(|ended| (name.clone(), ended)))
            .collect();
        for (name, end) in ended {
            let Some(session) = self.live.remove(&name) else { continue };
            // This view knows what it signalled; the pty crate cannot say. See `KILL_SIGNAL`.
            let end = match self.ending.remove(&name) {
                Some(Deliberate::Killed(signal)) => Ended::Signal(signal),
                Some(Deliberate::ByView) => Ended::ByView,
                None => end,
            };
            self.reaped.push((name.clone(), end));
            match crate::lifecycle::classify_exit(end) {
                Some(exit) => {
                    self.exits.insert(name.clone(), exit);
                }
                None => {
                    self.exits.remove(&name);
                }
            }
            let (child_rows, child_cols) = session.size;
            // `scripts/launch-preflight` and `scripts/launch` refuse with exit 2 and one line on
            // stderr in every one of their refusal paths; `launch` then EXECS the agent CLI, so
            // every other non-zero status belongs to the CLI rather than to the launcher.
            //
            // The refusal's words are taken from the CHILD'S OWN SCREEN, before the transcript is
            // built: a transcript carries `exit_line`'s closing lines too, and recognising those
            // by their wording would make the refusal pane quote the exit line back at the
            // navigator the day that sentence changed.
            if end == Ended::Status(2) {
                let message = screen_message(&session, child_rows, child_cols);
                self.note_refusal(&name, &message, now);
                continue;
            }
            // The transcript is taken at the size the child was last drawn at, which is the size
            // its own screen was written for.
            let lines = session.into_transcript(child_rows, child_cols, end);
            self.retained.insert(name, Retained { lines: Arc::new(lines), at: now });
        }
        let Some(name) = selected else { return SessionView::None };
        if let Some(session) = self.live.get_mut(name) {
            session.resize(rows, cols);
            return match session.screen(rows, cols) {
                Some(lines) => SessionView::Live { lines, cursor: session.cursor() },
                // Spawned and silent: never `None`, which would read as "no session at all".
                None => SessionView::Starting,
            };
        }
        if let Some(refused) = self.refused.get(name) {
            return SessionView::Refused { lines: Arc::clone(&refused.lines), at: refused.at };
        }
        match self.retained.get(name) {
            Some(retained) => {
                SessionView::Ended { lines: Arc::clone(&retained.lines), at: retained.at }
            }
            None => SessionView::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn with(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, modifiers)
    }

    #[test]
    fn keys_become_the_bytes_a_child_expects() {
        let cases: Vec<(KeyEvent, Vec<u8>)> = vec![
            (key(KeyCode::Char('a')), vec![97]),
            (with(KeyCode::Char('c'), KeyModifiers::CONTROL), vec![3]),
            (with(KeyCode::Char('@'), KeyModifiers::CONTROL), vec![0]),
            (with(KeyCode::Char('x'), KeyModifiers::ALT), vec![27, 120]),
            (key(KeyCode::Enter), vec![13]),
            (key(KeyCode::Backspace), vec![127]),
            (key(KeyCode::Esc), vec![27]),
            (key(KeyCode::Left), vec![27, 91, 68]),
            (key(KeyCode::Right), vec![27, 91, 67]),
            (key(KeyCode::Up), vec![27, 91, 65]),
            (key(KeyCode::Down), vec![27, 91, 66]),
            (key(KeyCode::Home), vec![27, 91, 72]),
            (key(KeyCode::End), vec![27, 91, 70]),
            (key(KeyCode::Insert), vec![27, 91, 50, 126]),
            (key(KeyCode::Delete), vec![27, 91, 51, 126]),
            (key(KeyCode::PageUp), vec![27, 91, 53, 126]),
            (key(KeyCode::PageDown), vec![27, 91, 54, 126]),
            (key(KeyCode::F(1)), vec![27, 79, 80]),
            (key(KeyCode::F(4)), vec![27, 79, 83]),
            // A multi-byte char travels as its UTF-8, not as a lossy single byte.
            (key(KeyCode::Char('ä')), vec![0xc3, 0xa4]),
        ];
        for (event, expected) in cases {
            assert_eq!(key_bytes(event), Some(expected), "for {event:?}");
        }
    }

    #[test]
    fn an_unmapped_key_produces_no_bytes() {
        assert_eq!(key_bytes(key(KeyCode::F(9))), None);
        assert_eq!(key_bytes(key(KeyCode::BackTab)), None);
        assert_eq!(key_bytes(key(KeyCode::Tab)), None);
        assert_eq!(
            key_bytes(with(KeyCode::Char('1'), KeyModifiers::CONTROL)),
            None
        );
        let mut release = key(KeyCode::Char('a'));
        release.kind = KeyEventKind::Release;
        assert_eq!(key_bytes(release), None);
    }

    /// The hatch that pays for `Tab` being held back: `Ctrl-I` IS `0x09`, and always was.
    #[test]
    fn ctrl_i_still_sends_a_literal_tab() {
        assert_eq!(
            key_bytes(with(KeyCode::Char('i'), KeyModifiers::CONTROL)),
            Some(vec![9])
        );
    }

    /// A parser of the given size, fed BYTES.
    fn parser(rows: u16, cols: u16, bytes: &[u8]) -> vt100::Parser {
        let mut parser = vt100::Parser::new(rows, cols, SCROLLBACK_LINES);
        parser.process(bytes);
        parser
    }

    fn texts(line: &Line<'static>) -> Vec<String> {
        line.spans.iter().map(|span| span.content.to_string()).collect()
    }

    #[test]
    fn a_coloured_line_materialises_into_styled_spans() {
        // Bold red `hi', then ordinary `there'.
        let parser = parser(4, 20, b"\x1b[1;31mhi\x1b[0m there");
        let lines = materialise(parser.screen(), 4, 20);
        assert_eq!(texts(&lines[0]), vec!["hi".to_string(), " there".to_string()]);
        assert_eq!(
            lines[0].spans[0].style,
            Style::default().fg(Color::Indexed(1)).add_modifier(Modifier::BOLD)
        );
        assert_eq!(lines[0].spans[1].style, Style::default());
        // The row is twenty cells wide and the padding is gone.
        assert_eq!(lines[0].spans.len(), 2);
    }

    #[test]
    fn an_indexed_and_a_true_colour_both_survive() {
        let parser = parser(2, 20, b"\x1b[38;5;208ma\x1b[38;2;10;20;30mb");
        let lines = materialise(parser.screen(), 2, 20);
        assert_eq!(lines[0].spans[0].style.fg, Some(Color::Indexed(208)));
        assert_eq!(lines[0].spans[1].style.fg, Some(Color::Rgb(10, 20, 30)));
    }

    #[test]
    fn a_blank_screen_materialises_to_blank_lines() {
        let parser = parser(3, 10, b"");
        let lines = materialise(parser.screen(), 3, 10);
        assert_eq!(lines.len(), 3);
        for line in &lines {
            assert!(line.spans.is_empty(), "expected an empty line, got {line:?}");
        }
    }


    /// A `/bin/sh -c' session, at the given size. POSIX utilities only, and never
    /// `scripts/launch': a case that started a real agent would claim a bead.
    fn shell(script: &str, rows: u16, cols: u16) -> Session {
        let mut command = portable_pty::CommandBuilder::new("/bin/sh");
        command.arg("-c");
        command.arg(script);
        // A child that inherited the developer's own TERM would emit whatever that terminal
        // wants; `dumb' keeps the bytes a plain stream on every machine.
        command.env("TERM", "dumb");
        Session::spawn_command("Cyclops", command, rows, cols).expect("the session spawns")
    }

    /// Poll every 10ms for up to five seconds until PREDICATE holds; panic with what the screen
    /// said if it never does. A bare `sleep' is either flaky or slow, and an unbounded loop is a
    /// CI job that hangs until the runner kills it. Five seconds is the bound every other child
    /// in this crate already gets (`readers.rs').
    fn settle(session: &mut Session, what: &str, mut predicate: impl FnMut(&mut Session) -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while std::time::Instant::now() < deadline {
            if predicate(session) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("never settled: {what}\nscreen was {:?}", session.screen(24, 80));
    }

    /// The screen's rows as plain text, blank rows and all.
    fn screen_text(session: &Session, rows: u16, cols: u16) -> Vec<String> {
        session
            .screen(rows, cols)
            .unwrap_or_default()
            .iter()
            .map(|line| texts(line).join(""))
            .collect()
    }

    fn text_of(lines: &[Line<'static>]) -> Vec<String> {
        lines.iter().map(|line| texts(line).join("")).collect()
    }

    #[test]
    fn a_launcher_that_exits_two_becomes_a_refusal() {
        let mut host = SessionHost::default();
        host.insert(
            "Rogue",
            shell(r#"printf "cerebro: agents/implementer.md is missing\r\n" >&2; exit 2"#, 24, 80),
        );
        let view = settle_host(&mut host, "Rogue", |view| {
            matches!(view, SessionView::Refused { .. })
        });
        let SessionView::Refused { lines, .. } = view else { panic!("not a refusal: {view:?}") };
        let text = text_of(&lines);
        assert!(
            text.iter().any(|line| line == "agents/implementer.md is missing"),
            "the launcher's own words, without its prefix: {text:?}"
        );
        assert!(
            !text.iter().any(|line| line.contains("cerebro: ")),
            "the prefix is dropped: {text:?}"
        );
    }

    /// Exit 2 is the launcher's; every other non-zero status belongs to the agent CLI it execs.
    #[test]
    fn any_other_non_zero_status_is_an_ordinary_ended_pass() {
        let mut host = SessionHost::default();
        host.insert("Rogue", shell("exit 101", 24, 80));
        let view = settle_host(&mut host, "Rogue", |view| {
            matches!(view, SessionView::Ended { .. } | SessionView::Refused { .. })
        });
        assert!(matches!(view, SessionView::Ended { .. }), "{view:?}");
    }

    #[test]
    fn starting_again_replaces_a_refusal() {
        let mut host = SessionHost::default();
        host.note_refusal("Rogue", "cerebro: nope", at("2026-01-01T00:00:00Z"));
        host.insert("Rogue", shell("sleep 5", 24, 80));
        let view = host.sync(Some("Rogue"), 24, 80, at("2026-01-01T00:00:01Z"));
        assert!(matches!(view, SessionView::Starting | SessionView::Live { .. }), "{view:?}");
    }

    #[test]
    fn a_killed_session_says_it_was_killed() {
        let mut host = SessionHost::default();
        host.insert("Cyclops", shell("while :; do sleep 1; done", 24, 80));
        let paths = ReaderPaths {
            consumer_root: std::path::PathBuf::from("/nonexistent"),
            shared_root: std::path::PathBuf::from("/nonexistent"),
            scripts_dir: std::path::PathBuf::from("/nonexistent"),
        };
        assert!(host.kill(&paths, "Cyclops"));
        assert!(!host.kill(&paths, "Storm"), "a name with no session here is not killed");

        let view = settle_host(&mut host, "Cyclops", |view| {
            matches!(view, SessionView::Ended { .. })
        });
        let SessionView::Ended { lines, .. } = view else { panic!("{view:?}") };
        let text = text_of(&lines);
        assert!(
            text.iter().any(|line| line == "Cyclops was killed by signal 1."),
            "this view sent the signal and knows which, and 0.9 sends SIGHUP: {text:?}"
        );
        let killed = lines
            .iter()
            .find(|line| texts(line).join("") == "Cyclops was killed by signal 1.")
            .expect("the exit line");
        assert_eq!(killed.spans[0].style.fg, Some(Color::Red));
    }

    #[test]
    fn a_session_the_view_ended_says_so_rather_than_reading_as_killed() {
        // Ending a session IS a signal 9 (or a SIGHUP that escalates), and saying so to somebody
        // whose agent worked perfectly is exactly the wrong sentence.
        let (text, failed) = exit_line("Cyclops", Ended::ByView);
        assert_eq!(text, "Cyclops finished its pass; the view ended it.");
        assert!(!failed, "a pass the view ended on purpose is not a failure");
    }

    #[test]
    fn a_transcript_of_a_view_ended_pass_closes_with_that_line() {
        let mut parser = vt100::Parser::new(4, 20, SCROLLBACK_LINES);
        parser.process(b"the pass\r\n");
        let lines = transcript(&mut parser, 4, 20, Ended::ByView, "Cyclops");
        let text = text_of(&lines);
        assert!(
            text.iter().any(|line| line == "Cyclops finished its pass; the view ended it."),
            "{text:?}"
        );
        let closing = lines
            .iter()
            .find(|line| texts(line).join("") == "Cyclops finished its pass; the view ended it.")
            .expect("the exit line");
        assert_eq!(closing.spans[0].style.fg, None, "ended on purpose is not red");
    }

    #[test]
    fn end_kills_retains_and_takes_the_state_file_with_it() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let paths = ReaderPaths {
            consumer_root: dir.path().join("worktree"),
            shared_root: dir.path().to_path_buf(),
            scripts_dir: dir.path().join("scripts"),
        };
        std::fs::create_dir_all(dir.path().join(".cerebro/state")).expect("the state directory");
        let state = crate::lifecycle::state_file_path(&paths, "Cyclops");
        let flag = crate::lifecycle::stop_flag_path(&paths, "Cyclops");
        std::fs::write(&state, "{}").expect("a state file");
        std::fs::write(&flag, "").expect("a stop flag");

        let mut host = SessionHost::default();
        host.insert("Cyclops", shell("while :; do sleep 1; done", 24, 80));
        assert!(host.supervisable("Cyclops"));
        assert!(host.end(&paths, "Cyclops"));
        // Between the end and the reap the child is still `is_live`, and a supervision loop
        // reading THAT would end the same session on every tick and announce it every time.
        assert!(host.is_live("Cyclops"));
        assert!(!host.supervisable("Cyclops"));
        assert!(!host.end(&paths, "Storm"), "a name with no session here is not ended");

        assert!(!state.exists(), "a file naming an ended session names a pid that is gone");
        assert!(flag.exists(), "clearing the flag belongs to a retire, and the caller does it");

        let view = settle_host(&mut host, "Cyclops", |view| {
            matches!(view, SessionView::Ended { .. })
        });
        let SessionView::Ended { lines, .. } = view else { panic!("{view:?}") };
        assert!(
            text_of(&lines).iter().any(|line| line == "Cyclops finished its pass; the view ended it."),
            "the transcript is kept, and closes with the view's own sentence"
        );
    }

    /// The reap is the only place a verdict is recorded, and a start is the only thing that
    /// clears one - a verdict that outlived the run that produced it would sit on a row whose
    /// session is perfectly healthy.
    #[test]
    fn a_reaped_child_leaves_a_verdict_until_it_starts_again() {
        let mut host = SessionHost::default();
        host.insert("Storm", shell("exit 2", 24, 80));
        settle_host(&mut host, "Storm", |view| matches!(view, SessionView::Refused { .. }));
        assert_eq!(host.last_exit("Storm"), Some(crate::lifecycle::LastExit::Refused));

        host.insert("Rogue", shell("exit 101", 24, 80));
        settle_host(&mut host, "Rogue", |view| matches!(view, SessionView::Ended { .. }));
        assert_eq!(host.last_exit("Rogue"), Some(crate::lifecycle::LastExit::Code(101)));
        assert_eq!(host.exits().len(), 2, "one per name that has had an abnormal exit");

        // A clean exit is no verdict at all: a blank BEAD column is what "nobody started it"
        // looks like, and that is the truth for a pass that ended with status 0.
        host.insert("Gambit", shell("exit 0", 24, 80));
        settle_host(&mut host, "Gambit", |view| matches!(view, SessionView::Ended { .. }));
        assert_eq!(host.last_exit("Gambit"), None);

        // And neither is this view's own doing: an end reaps as `ByView`, a kill as a signal.
        let paths = ReaderPaths {
            consumer_root: std::path::PathBuf::from("/nonexistent"),
            shared_root: std::path::PathBuf::from("/nonexistent"),
            scripts_dir: std::path::PathBuf::from("/nonexistent"),
        };
        host.insert("Cyclops", shell("while :; do sleep 1; done", 24, 80));
        assert!(host.end(&paths, "Cyclops"));
        settle_host(&mut host, "Cyclops", |view| matches!(view, SessionView::Ended { .. }));
        assert_eq!(host.last_exit("Cyclops"), None);

        // Starting again is what clears a verdict.
        host.insert("Storm", shell("sleep 5", 24, 80));
        assert_eq!(host.last_exit("Storm"), None);
        assert_eq!(host.exits().len(), 1, "only Rogue's verdict is left");
    }

    #[test]
    fn a_typed_line_sends_its_return_separately() {
        let mut host = SessionHost::default();
        host.insert(
            "Cyclops",
            shell(r#"while read line; do printf "got:%s\r\n" "$line"; done"#, 24, 80),
        );
        let at = std::time::Instant::now();
        host.type_line("Cyclops", "hello", at);
        // Before the delay, nothing more is sent: a burst ending in a return would be read as a
        // paste, and the agent would sit on the line it was typed.
        host.flush_returns(at);
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(
            !host_text(&mut host, "Cyclops").iter().any(|line| line.contains("got:hello")),
            "the line was submitted before its return was due"
        );

        host.flush_returns(at + RETURN_DELAY);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !host_text(&mut host, "Cyclops").iter().any(|line| line.contains("got:hello")) {
            if std::time::Instant::now() >= deadline {
                panic!("the return never arrived");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    /// The live screen of NAME's session, as plain strings.
    fn host_text(host: &mut SessionHost, name: &str) -> Vec<String> {
        match host.sync(Some(name), 24, 80, at("2026-01-01T00:00:00Z")) {
            SessionView::Live { lines, .. } => text_of(&lines),
            _ => Vec::new(),
        }
    }

    #[test]
    fn live_names_follow_the_roster_rather_than_the_map() {
        let mut host = SessionHost::default();
        for name in ["Cyclops", "Xavier", "Beast"] {
            host.insert(name, shell("sleep 5", 24, 80));
        }
        let order: Vec<String> =
            ["Xavier", "Beast", "Storm", "Cyclops"].iter().map(|n| n.to_string()).collect();
        assert_eq!(
            host.live_names(&order),
            vec!["Xavier".to_string(), "Beast".to_string(), "Cyclops".to_string()]
        );
    }

    /// Poll `sync` until PREDICATE holds, so a case never depends on how fast a child exits.
    fn settle_host(
        host: &mut SessionHost,
        name: &str,
        predicate: impl Fn(&SessionView) -> bool,
    ) -> SessionView {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let view = host.sync(Some(name), 24, 80, at("2026-01-01T00:00:00Z"));
            if predicate(&view) {
                return view;
            }
            if std::time::Instant::now() >= deadline {
                panic!("never settled for {name}: {view:?}");
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    #[test]
    fn a_child_that_prints_appears_on_the_session_screen() {
        let mut session = shell(r#"printf "hello from the pty\r\n""#, 24, 80);
        settle(&mut session, "the greeting", |session| {
            screen_text(session, 24, 80).first().is_some_and(|line| line == "hello from the pty")
        });
    }

    #[test]
    fn a_session_with_no_output_yet_has_no_screen() {
        // A child that says nothing for a moment: the pane must be able to tell "spawned, nothing
        // yet" from "no session", which is what `SessionView::Starting' is.
        let session = shell("sleep 5", 24, 80);
        assert!(session.screen(24, 80).is_none());
    }

    #[test]
    fn bytes_written_to_a_session_come_back_as_output() {
        let mut session = shell(r#"read line; printf "got:%s\r\n" "$line""#, 24, 80);
        session.send(b"hi\r");
        settle(&mut session, "the echoed line", |session| {
            screen_text(session, 24, 80).iter().any(|line| line.contains("got:hi"))
        });
    }

    #[test]
    fn resizing_the_pane_resizes_the_child() {
        let mut session = shell("stty size; read _; stty size", 24, 80);
        settle(&mut session, "the first size", |session| {
            screen_text(session, 24, 80).iter().any(|line| line.contains("24 80"))
        });
        session.resize(10, 40);
        session.send(b"\r");
        settle(&mut session, "the second size", |session| {
            screen_text(session, 10, 40).iter().any(|line| line.contains("10 40"))
        });
    }

    #[test]
    fn exit_lines_read_as_agreed() {
        assert_eq!(
            exit_line("Cyclops", Ended::Status(0)),
            ("Cyclops finished with status 0.".to_string(), false)
        );
        assert_eq!(
            exit_line("Cyclops", Ended::Status(101)),
            ("Cyclops finished with status 101.".to_string(), true)
        );
        assert_eq!(
            exit_line("Cyclops", Ended::Signal(9)),
            ("Cyclops was killed by signal 9.".to_string(), true)
        );
    }

    #[test]
    fn a_finished_child_leaves_its_screen_and_a_status_line() {
        let mut session = shell(r#"printf "done\r\n""#, 24, 80);
        let mut ended = None;
        settle(&mut session, "the exit", |session| {
            ended = session.poll_exit();
            ended.is_some()
        });
        assert_eq!(ended, Some(Ended::Status(0)));
        let lines = text_of(&session.into_transcript(24, 80, Ended::Status(0)));
        assert_eq!(
            lines,
            vec![
                "done".to_string(),
                String::new(),
                "Cyclops finished with status 0.".to_string(),
                String::new(),
                "End of retained scrollback. Up/Down scroll while focused.".to_string(),
            ]
        );
    }

    #[test]
    fn a_failing_child_is_reported_with_its_status() {
        let mut session = shell("exit 101", 24, 80);
        let mut ended = None;
        settle(&mut session, "the exit", |session| {
            ended = session.poll_exit();
            ended.is_some()
        });
        assert_eq!(ended, Some(Ended::Status(101)));
        let (text, failed) = exit_line("Cyclops", ended.unwrap());
        assert_eq!(text, "Cyclops finished with status 101.");
        assert!(failed);
        let lines = session.into_transcript(24, 80, ended.unwrap());
        let status = lines.iter().find(|line| texts(line).join("").starts_with("Cyclops")).unwrap();
        assert_eq!(status.spans[0].style.fg, Some(Color::Red));
    }

    #[test]
    fn the_retained_transcript_carries_every_line_that_scrolled_off() {
        let mut session = shell(
            r#"i=1; while [ $i -le 200 ]; do printf "line %s\r\n" $i; i=$((i+1)); done"#,
            24,
            80,
        );
        let mut ended = None;
        settle(&mut session, "the exit", |session| {
            ended = session.poll_exit();
            ended.is_some()
        });
        let lines = text_of(&session.into_transcript(24, 80, ended.unwrap()));
        assert_eq!(lines.first().map(String::as_str), Some("line 1"));
        // The three closing lines the view adds sit under the last thing the agent said.
        let content: Vec<&String> = lines.iter().take(lines.len() - 4).collect();
        assert_eq!(content.last().map(|line| line.as_str()), Some("line 200"));
        assert_eq!(lines.iter().filter(|line| *line == "line 137").count(), 1);
    }


    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn a_finished_session_becomes_a_retained_pass_and_starting_again_replaces_it() {
        let mut host = SessionHost::default();
        host.insert("Cyclops", shell(r#"printf "first pass\r\n""#, 24, 80));
        let mut view = SessionView::None;
        for _ in 0..500 {
            view = host.sync(Some("Cyclops"), 24, 80, at("2026-09-01T15:42:00Z"));
            if matches!(view, SessionView::Ended { .. }) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let SessionView::Ended { lines, at: ended_at } = view else {
            panic!("expected a retained pass, got {view:?}");
        };
        assert_eq!(ended_at, at("2026-09-01T15:42:00Z"));
        assert!(text_of(&lines).iter().any(|line| line == "first pass"), "{:?}", text_of(&lines));
        assert_eq!(host.live_count(), 0);

        // Starting again throws the retained pass away: it is kept until the next start, and no
        // longer.
        host.insert("Cyclops", shell("sleep 5", 24, 80));
        let view = host.sync(Some("Cyclops"), 24, 80, at("2026-09-01T15:45:00Z"));
        assert_eq!(view, SessionView::Starting);
        assert!(host.is_live("Cyclops"));
    }

    #[test]
    fn sync_returns_none_for_an_agent_with_neither() {
        let mut host = SessionHost::default();
        assert_eq!(host.sync(Some("Moira"), 24, 80, at("2026-09-01T15:42:00Z")), SessionView::None);
        assert_eq!(host.sync(None, 24, 80, at("2026-09-01T15:42:00Z")), SessionView::None);
    }

    #[test]
    fn live_count_counts_only_live_children() {
        let mut host = SessionHost::default();
        assert_eq!(host.live_count(), 0);
        host.insert("Cyclops", shell("sleep 5", 24, 80));
        host.insert("Moira", shell("sleep 5", 24, 80));
        assert_eq!(host.live_count(), 2);
        // Two children are independently selectable, and neither answers for the other.
        host.send("Cyclops", b"");
        assert!(host.is_live("Moira"));
        assert!(!host.is_live("Beast"));
    }

    #[test]
    fn a_paste_is_wrapped_in_bracketed_paste_markers() {
        assert_eq!(
            paste_bytes("one\ntwo"),
            b"\x1b[200~one\ntwo\x1b[201~".to_vec()
        );
        // A payload that closes its own bracket would hand the rest of itself to the child as
        // keystrokes; the marker is stripped and the rest travels as pasted text.
        assert_eq!(
            paste_bytes("a\x1b[201~rm -rf /"),
            b"\x1b[200~arm -rf /\x1b[201~".to_vec()
        );
    }

    #[test]
    fn a_name_the_view_gave_up_on_carries_its_count() {
        let mut host = SessionHost::default();
        host.note_refusal("Xavier", "cerebro: nope", at("2026-01-01T00:00:00Z"));
        host.note_gave_up("Xavier", 5);
        assert_eq!(
            host.last_exit("Xavier"),
            Some(crate::lifecycle::LastExit::GaveUp { failures: 5 }),
            "the give-up replaces whatever record the name had"
        );
        // `s` is the way back: a start clears it, as it clears every other kind.
        host.insert("Xavier", shell("exit 0", 24, 80));
        assert_eq!(host.last_exit("Xavier"), None);
    }
}
