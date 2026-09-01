//! One agent CLI per pty, and the pure functions that turn its bytes into a pane.
//!
//! The module splits the way the rest of the crate does. The **pure half** - `key_bytes`,
//! `paste_bytes`, `exit_line`, `materialise`, `transcript` - is tested over hand-driven parsers
//! and plain data. The **impure half** - `Session`, `SessionHost` - owns a process. `crate::ui`
//! sees neither: it is handed a slice of already-materialised `Line`s, exactly as it is handed
//! the Work pane's lines, which is what keeps `ui::draw` pure while a child writes continuously
//! into a parser on another thread.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

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
