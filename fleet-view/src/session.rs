//! One agent CLI per pty, and the pure functions that turn its bytes into a pane.
//!
//! The module splits the way the rest of the crate does. The **pure half** - `key_bytes`,
//! `paste_bytes`, `exit_line`, `materialise`, `transcript` - is tested over hand-driven parsers
//! and plain data. The **impure half** - `Session`, `SessionHost` - owns a process. `crate::ui`
//! sees neither: it is handed a slice of already-materialised `Line`s, exactly as it is handed
//! the Work pane's lines, which is what keeps `ui::draw` pure while a child writes continuously
//! into a parser on another thread.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
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
/// report this crate now owns. `Shift-Tab` never reaches here at all - it is how a navigator
/// leaves the session, so `main` takes it before this is called.
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
        KeyCode::Tab => Some(vec![b'\t']),
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


/// How a child ended, in this crate's own vocabulary rather than the pty crate's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ended {
    Status(u32),
    Signal(i32),
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
            (key(KeyCode::Tab), vec![9]),
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
        assert_eq!(
            key_bytes(with(KeyCode::Char('1'), KeyModifiers::CONTROL)),
            None
        );
        let mut release = key(KeyCode::Char('a'));
        release.kind = KeyEventKind::Release;
        assert_eq!(key_bytes(release), None);
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
}
