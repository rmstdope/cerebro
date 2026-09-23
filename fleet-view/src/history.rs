//! The lines a full-screen program scrolls away, which no terminal keeps.
//!
//! A CLI on the alternate screen that scrolls its conversation inside a scroll region loses each
//! line off the region's top: xterm keeps no scrollback there and vt100 keeps none either, so a
//! reader of the session log could never scroll back through it. `History` watches the pty's
//! bytes beside the parser, takes each such line just before it goes, and writes it into the log
//! as a private OSC, which the web console shows above the screen.
//!
//! Only a line feed at the region's bottom and `CSI S` are watched - what full-screen CLIs scroll
//! with. The normal screen is left alone: xterm keeps its scrollback itself.

use std::collections::VecDeque;

/// The OSC number a history line travels under. `HISTORY_OSC` in `web-console/ui/src/main.tsx` is
/// its literal twin.
pub const HISTORY_OSC: u16 = 7717;

/// How many bytes of history lines are kept, to open a new log with when the old one rotates.
pub const HISTORY_BYTES: usize = 2 * 1024 * 1024;

pub struct History {
    scanner: vte::Parser,
    /// The alternate screen's scroll region, 0-based and inclusive; `None` is the whole screen.
    region: Option<(u16, u16)>,
    retained: VecDeque<Vec<u8>>,
    retained_bytes: usize,
    limit: usize,
    /// Whether the bytes so far end inside an escape sequence, where a line feed still runs but
    /// an OSC spliced in would cut the sequence short.
    in_sequence: bool,
    /// Lines taken inside a sequence, written once it ends.
    pending: Vec<Vec<u8>>,
}

impl Default for History {
    fn default() -> Self {
        Self::new(HISTORY_BYTES)
    }
}

/// What the scanner saw a byte complete, of the few things that decide what scrolls.
#[derive(Clone, Copy, Debug)]
enum Event {
    LineFeed,
    ScrollUp(u16),
    Region(u16, u16),
    /// `CSI ? 1049 h`, which clears the alternate screen and with it its region.
    FreshAlternate,
    Reset,
}

#[derive(Default)]
struct Scan {
    event: Option<Event>,
    /// A sequence ended, or a character printed: the scanner is back on the ground.
    ground: bool,
}

fn first(params: &vte::Params, index: usize) -> u16 {
    params.iter().nth(index).and_then(|param| param.first().copied()).unwrap_or(0)
}

impl vte::Perform for Scan {
    fn print(&mut self, _c: char) {
        self.ground = true;
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x0a..=0x0c => self.event = Some(Event::LineFeed),
            // CAN and SUB abandon a sequence.
            0x18 | 0x1a => self.ground = true,
            _ => {}
        }
    }

    fn unhook(&mut self) {
        self.ground = true;
    }

    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {
        self.ground = true;
    }

    fn csi_dispatch(&mut self, params: &vte::Params, intermediates: &[u8], _ignore: bool, action: char) {
        self.ground = true;
        self.event = match (intermediates, action) {
            ([], 'S') => Some(Event::ScrollUp(first(params, 0).max(1))),
            ([], 'r') => Some(Event::Region(first(params, 0), first(params, 1))),
            ([b'?'], 'h') if params.iter().any(|param| param == [1049]) => Some(Event::FreshAlternate),
            _ => None,
        };
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        self.ground = true;
        if intermediates.is_empty() && byte == b'c' {
            self.event = Some(Event::Reset);
        }
    }
}

#[derive(Clone, PartialEq, serde::Serialize)]
#[serde(untagged)]
enum Colour {
    Index(u8),
    Rgb(String),
}

fn colour(colour: vt100::Color) -> Option<Colour> {
    match colour {
        vt100::Color::Default => None,
        vt100::Color::Idx(index) => Some(Colour::Index(index)),
        vt100::Color::Rgb(r, g, b) => Some(Colour::Rgb(format!("#{r:02x}{g:02x}{b:02x}"))),
    }
}

#[derive(serde::Serialize)]
struct Run {
    t: String,
    #[serde(flatten)]
    style: Style,
}

#[derive(PartialEq, serde::Serialize)]
struct Style {
    #[serde(skip_serializing_if = "Option::is_none")]
    fg: Option<Colour>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bg: Option<Colour>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    bold: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    dim: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    italic: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    underline: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    inverse: bool,
}

/// ROW of SCREEN as an OSC holding its text in runs of one style, trailing blanks dropped.
fn line(screen: &vt100::Screen, row: u16) -> Vec<u8> {
    let (_, cols) = screen.size();
    let mut runs: Vec<Run> = Vec::new();
    let mut end = 0;
    for col in 0..cols {
        let Some(cell) = screen.cell(row, col) else { break };
        if cell.is_wide_continuation() {
            continue;
        }
        let text = if cell.has_contents() { cell.contents() } else { " " };
        let style = Style {
            fg: colour(cell.fgcolor()),
            bg: colour(cell.bgcolor()),
            bold: cell.bold(),
            dim: cell.dim(),
            italic: cell.italic(),
            underline: cell.underline(),
            inverse: cell.inverse(),
        };
        if runs.last().is_none_or(|last| last.style != style) {
            runs.push(Run { t: String::new(), style });
        }
        runs.last_mut().expect("a run was just pushed").t.push_str(text);
        if text != " " || cell.bgcolor() != vt100::Color::Default || cell.inverse() || cell.underline() {
            end = runs.iter().map(|run| run.t.len()).sum();
        }
    }
    let mut kept = 0;
    runs.retain_mut(|run| {
        let room = end.saturating_sub(kept);
        kept += run.t.len();
        run.t.truncate(room);
        !run.t.is_empty()
    });
    let json = serde_json::to_string(&runs).expect("runs serialise");
    // serde leaves DEL and the C1 controls as they are, and a terminal may end an OSC on those.
    let mut body = String::with_capacity(json.len());
    for c in json.chars() {
        if ('\u{7f}'..='\u{9f}').contains(&c) {
            body.push_str(&format!("\\u{:04x}", u32::from(c)));
        } else {
            body.push(c);
        }
    }
    format!("\u{1b}]{HISTORY_OSC};{body}\u{7}").into_bytes()
}

impl History {
    pub fn new(limit: usize) -> Self {
        Self {
            scanner: vte::Parser::new(),
            region: None,
            retained: VecDeque::new(),
            retained_bytes: 0,
            limit,
            in_sequence: false,
            pending: Vec::new(),
        }
    }

    /// Feed BYTES to PARSER, and return them as the log should carry them: with an OSC holding
    /// each line the alternate screen scrolled away, after the byte that scrolled it or, when that
    /// byte came inside an escape sequence, after the sequence.
    pub fn process(&mut self, parser: &mut vt100::Parser, bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(bytes.len());
        let mut flushed = 0;
        for index in 0..bytes.len() {
            let mut scan = Scan::default();
            self.scanner.advance(&mut scan, &bytes[index..=index]);
            if scan.ground {
                self.in_sequence = false;
            }
            if bytes[index] == 0x1b {
                self.in_sequence = true;
            }
            if let Some(event) = scan.event {
                parser.process(&bytes[flushed..index]);
                let screen = parser.screen();
                let alternate = screen.alternate_screen();
                let (rows, _) = screen.size();
                let (top, bottom) = self.region.unwrap_or((0, rows.saturating_sub(1)));
                match event {
                    Event::LineFeed if alternate && screen.cursor_position().0 == bottom => {
                        self.pending.push(line(screen, top));
                    }
                    Event::ScrollUp(count) if alternate => {
                        self.pending.extend((top..=bottom).take(usize::from(count)).map(|row| line(screen, row)));
                    }
                    _ => {}
                }
                parser.process(&bytes[index..=index]);
                out.extend_from_slice(&bytes[flushed..=index]);
                flushed = index + 1;
                match event {
                    // What vt100's DECSTBM does, to whichever screen is in use when it arrives.
                    Event::Region(first, last) if alternate => {
                        let first = first.max(1) - 1;
                        let last = if last == 0 { rows } else { last }.min(rows) - 1;
                        self.region = (first < last).then_some((first, last));
                    }
                    Event::FreshAlternate | Event::Reset => self.region = None,
                    _ => {}
                }
            }
            if !self.in_sequence && !self.pending.is_empty() {
                parser.process(&bytes[flushed..=index]);
                out.extend_from_slice(&bytes[flushed..=index]);
                flushed = index + 1;
                for osc in std::mem::take(&mut self.pending) {
                    out.extend_from_slice(&osc);
                    self.retain(osc);
                }
            }
        }
        parser.process(&bytes[flushed..]);
        out.extend_from_slice(&bytes[flushed..]);
        out
    }

    fn retain(&mut self, osc: Vec<u8>) {
        self.retained_bytes += osc.len();
        self.retained.push_back(osc);
        while self.retained_bytes > self.limit {
            let Some(oldest) = self.retained.pop_front() else { break };
            self.retained_bytes -= oldest.len();
        }
    }

    /// The pty was resized from OLD_ROWS to ROWS; vt100 moves the region's bottom the same way.
    pub fn resize(&mut self, old_rows: u16, rows: u16) {
        if let Some((top, bottom)) = self.region {
            let bottom = if bottom + 1 == old_rows { rows } else { (bottom + 1).min(rows) } - 1;
            self.region = Some((if bottom < top { 0 } else { top }, bottom));
        }
    }

    /// The history lines kept, oldest first, each a complete OSC.
    pub fn retained(&self) -> impl Iterator<Item = &[u8]> {
        self.retained.iter().map(Vec::as_slice)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The history lines in LOG, as the web console would read them.
    fn lines(log: &[u8]) -> Vec<serde_json::Value> {
        let log = String::from_utf8_lossy(log);
        let start = format!("\u{1b}]{HISTORY_OSC};");
        log.split(start.as_str())
            .skip(1)
            .map(|rest| serde_json::from_str(rest.split('\u{7}').next().unwrap()).unwrap())
            .collect()
    }

    fn texts(log: &[u8]) -> Vec<String> {
        lines(log)
            .iter()
            .map(|line| line.as_array().unwrap().iter().map(|run| run["t"].as_str().unwrap()).collect())
            .collect()
    }

    fn feed(history: &mut History, parser: &mut vt100::Parser, bytes: &str) -> Vec<u8> {
        history.process(parser, bytes.as_bytes())
    }

    #[test]
    fn a_line_scrolled_out_of_an_alternate_screen_region_is_kept() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "\x1b[?1049h\x1b[1;1Hheader\x1b[2;4r\x1b[2;1Hone\r\ntwo\r\nthree\r\nfour");

        assert_eq!(texts(&log), vec!["one"]);
        assert_eq!(parser.screen().contents(), "header\ntwo\nthree\nfour");
        let mut replay = vt100::Parser::new(6, 20, 0);
        replay.process(&log);
        assert_eq!(replay.screen().contents(), parser.screen().contents(), "the OSC changes nothing on screen");
        assert_eq!(history.retained().count(), 1);
    }

    #[test]
    fn the_whole_alternate_screen_scrolling_is_kept_too() {
        let mut parser = vt100::Parser::new(3, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "\x1b[?1049hone\r\ntwo\r\nthree\r\nfour\x1b[2S");

        assert_eq!(texts(&log), vec!["one", "two", "three"]);
    }

    #[test]
    fn the_normal_screen_is_left_to_the_terminal() {
        let mut parser = vt100::Parser::new(3, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "one\r\ntwo\r\nthree\r\nfour\x1b[1;2r\x1b[2;1H\n\n");

        assert!(texts(&log).is_empty());
        assert_eq!(log, b"one\r\ntwo\r\nthree\r\nfour\x1b[1;2r\x1b[2;1H\n\n");
    }

    #[test]
    fn a_line_feed_above_the_region_bottom_scrolls_nothing() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "\x1b[?1049h\x1b[2;4r\x1b[6;1Hfooter\n\n\x1b[1;1H\n\n");

        assert!(texts(&log).is_empty());
    }

    #[test]
    fn entering_the_alternate_screen_afresh_clears_its_region() {
        let mut parser = vt100::Parser::new(4, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "\x1b[?1049h\x1b[2;3r\x1b[?1049l\x1b[?1049hone\r\ntwo\r\nthree\r\nfour\r\n");

        assert_eq!(texts(&log), vec!["one"], "the whole screen scrolls, not rows 2 to 3");
    }

    #[test]
    fn a_region_set_on_the_normal_screen_is_not_the_alternate_ones() {
        let mut parser = vt100::Parser::new(4, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "\x1b[2;3r\x1b[?1049hone\r\ntwo\r\nthree\r\nfour\r\n");

        assert_eq!(texts(&log), vec!["one"], "the whole screen scrolls, not rows 2 to 3");
    }

    #[test]
    fn a_resize_moves_a_region_that_reached_the_bottom() {
        let mut parser = vt100::Parser::new(4, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, "\x1b[?1049h\x1b[2;4r");
        parser.screen_mut().set_size(6, 20);
        history.resize(4, 6);
        let log = feed(&mut history, &mut parser, "\x1b[2;1Hone\x1b[5;1Hfive\n");

        assert!(texts(&log).is_empty(), "row 4 is no longer the bottom");
        let log = feed(&mut history, &mut parser, "\x1b[6;1Hsix\n");
        assert_eq!(texts(&log), vec!["one"]);
    }

    #[test]
    fn a_kept_line_carries_its_colours_and_attributes() {
        let mut parser = vt100::Parser::new(2, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "\x1b[?1049h\x1b[1;31mred\x1b[m plain \x1b[38;2;1;2;3;48;5;200mrgb\x1b[m   \r\nnext\r\n");

        let line = &lines(&log)[0];
        assert_eq!(
            line,
            &serde_json::json!([
                { "t": "red", "fg": 1, "bold": true },
                { "t": " plain " },
                { "t": "rgb", "fg": "#010203", "bg": 200 },
            ]),
            "trailing blanks are dropped"
        );
    }

    #[test]
    fn a_kept_line_cannot_end_its_osc_early() {
        let mut parser = vt100::Parser::new(2, 20, 0);
        let mut history = History::default();
        let log = feed(&mut history, &mut parser, "\x1b[?1049hst\u{9c} del\u{7f} end\r\nnext\r\n");

        let osc = String::from_utf8(history.retained().next().unwrap().to_vec()).unwrap();
        let body = osc.strip_prefix(&format!("\u{1b}]{HISTORY_OSC};")).unwrap().strip_suffix('\u{7}').unwrap();
        assert!(!body.chars().any(|c| c < ' ' || ('\u{7f}'..='\u{9f}').contains(&c)), "{body:?}");
        assert_eq!(texts(&log).len(), 1);
    }

    #[test]
    fn a_sequence_split_across_reads_is_still_seen() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        let mut log = feed(&mut history, &mut parser, "\x1b[?1049h\x1b[2;");
        log.extend(feed(&mut history, &mut parser, "4r\x1b[2;1Hone\r\ntwo\r\nthree\r"));
        log.extend(feed(&mut history, &mut parser, "\nfour"));

        assert_eq!(texts(&log), vec!["one"]);
    }

    #[test]
    fn a_line_fed_inside_a_sequence_is_written_after_the_sequence() {
        let mut parser = vt100::Parser::new(2, 20, 0);
        let mut history = History::default();
        let mut log = feed(&mut history, &mut parser, "\x1b[?1049hone\r\ntwo\x1b[2");
        log.extend(feed(&mut history, &mut parser, "\n;5Hx"));

        let log = String::from_utf8(log).unwrap();
        assert!(log.contains("\x1b[2\n;5H\x1b]7717;"), "{log:?}");
        assert_eq!(texts(log.as_bytes()), vec!["one"]);
        let mut replay = vt100::Parser::new(2, 20, 0);
        replay.process(log.as_bytes());
        assert_eq!(replay.screen().contents(), parser.screen().contents());
    }

    #[test]
    fn only_so_many_bytes_of_history_are_kept() {
        let mut parser = vt100::Parser::new(2, 20, 0);
        let mut history = History::new(100);
        let mut input = String::from("\x1b[?1049h");
        for n in 0..20 {
            input.push_str(&format!("line {n}\r\n"));
        }
        let log = feed(&mut history, &mut parser, &input);

        assert_eq!(texts(&log).len(), 19, "the log carries every line");
        let kept: usize = history.retained().map(<[u8]>::len).sum();
        assert!(kept <= 100 && kept > 0, "{kept}");
        assert!(String::from_utf8_lossy(history.retained().last().unwrap()).contains("line 18"));
    }
}
