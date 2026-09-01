//! One agent CLI per pty, and the pure functions that turn its bytes into a pane.
//!
//! The module splits the way the rest of the crate does. The **pure half** - `key_bytes`,
//! `paste_bytes`, `exit_line`, `materialise`, `transcript` - is tested over hand-driven parsers
//! and plain data. The **impure half** - `Session`, `SessionHost` - owns a process. `crate::ui`
//! sees neither: it is handed a slice of already-materialised `Line`s, exactly as it is handed
//! the Work pane's lines, which is what keeps `ui::draw` pure while a child writes continuously
//! into a parser on another thread.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

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
