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
//!
//! A resize loses lines without scrolling them: the CLI clears and redraws only its newest lines
//! into the new size. So the screen is taken before a resize, and once the CLI has redrawn, the
//! lines from the top of the old screen that the new one no longer shows are kept too.

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
    /// The normal screen's, which vt100 keeps apart: while one is set it keeps no scrollback.
    normal_region: Option<(u16, u16)>,
    retained: VecDeque<Vec<u8>>,
    retained_bytes: usize,
    /// Every line ever kept, dropped ones included: how far a view held still has to move.
    kept: u64,
    /// Every line the normal screen scrolled into the terminal's own scrollback, which stops
    /// counting once it is full.
    scrolled_off: u64,
    limit: usize,
    /// Whether the bytes so far end inside an escape sequence, where a line feed still runs but
    /// an OSC spliced in would cut the sequence short.
    in_sequence: bool,
    /// Lines taken inside a sequence, written once it ends.
    pending: Vec<Vec<u8>>,
    /// The alternate screen as it was before a resize, row by row, until the CLI's redraw is
    /// judged against it.
    before: Option<Vec<Row>>,
    /// Whether the screen has been erased since `before` was taken: the redraw has begun.
    erased: bool,
    /// Reads ended since the erase with the redraw not yet judged whole.
    waited: u8,
    /// Rows dropped from `before` because they scrolled away before the redraw. A redraw that
    /// shows one again at its top is showing its header.
    scrolled: String,
}

/// How many reads a redraw may take before what it shows by then is judged final.
const REDRAW_READS: u8 = 32;

/// Rows shorter than this, in characters, are shown only when a row of the redraw is the same.
const SHORT_ROW: usize = 12;

/// One row of a screen taken before a resize: its text reduced to what survives a rewrap, and
/// the OSC that keeps it.
struct Row {
    text: String,
    osc: Vec<u8>,
}

/// TEXT without what a CLI pads, borders or truncates a line with, so a line rewrapped at
/// another width is found again in the concatenated rows it now spans.
fn bare(text: &str) -> String {
    text.chars().filter(|c| !c.is_whitespace() && !matches!(c, '┃' | '│' | '…')).collect()
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
    /// `CSI 2 J` or `CSI 3 J`: the whole screen erased, as a redraw begins.
    Erase,
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
            ([], 'J') if matches!(first(params, 0), 2 | 3) => Some(Event::Erase),
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

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(untagged)]
pub enum Colour {
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

/// Text in one style, the unit a kept line is written in.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct Run {
    pub t: String,
    #[serde(flatten)]
    pub style: Style,
}

#[derive(Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Style {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fg: Option<Colour>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bg: Option<Colour>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub bold: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub dim: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub italic: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub underline: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub inverse: bool,
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
            normal_region: None,
            retained: VecDeque::new(),
            retained_bytes: 0,
            kept: 0,
            scrolled_off: 0,
            limit,
            in_sequence: false,
            pending: Vec::new(),
            before: None,
            erased: false,
            waited: 0,
            scrolled: String::new(),
        }
    }

    /// The pty is about to be resized: take SCREEN as it is, unless a resize before this one is
    /// still waiting for its redraw, which is then the screen to judge the redraw against.
    pub fn resizing(&mut self, screen: &vt100::Screen) {
        if !screen.alternate_screen() || self.before.is_some() {
            return;
        }
        let (rows, cols) = screen.size();
        let texts = screen.rows(0, cols);
        self.before = Some(texts.zip(0..rows).map(|(text, row)| Row { text: bare(&text), osc: line(screen, row) }).collect());
        self.erased = false;
        self.waited = 0;
        self.scrolled.clear();
    }

    /// Judge the redraw on SCREEN against the screen taken before the resize, and keep the lines
    /// it left out: after the rows it still shows at the top (a header), the run of rows it no
    /// longer shows, up to the first it does. Below that are lines it still shows and a footer
    /// that changes on its own, neither of which was lost; a run no shown row ends is that footer.
    ///
    /// A run no shown row ends may also be a redraw not yet whole, so it is judged again after
    /// the next read, until LAST: a scroll, or `REDRAW_READS` reads, after which it is the footer.
    ///
    /// Lines lost off the top leave the first line that survived directly under the header. A
    /// run the new screen does not start with that line is only drawn differently at a new
    /// width - truncated elsewhere, a timer moved on - and nothing was lost. A screen taken with
    /// no header cannot say where the redraw's header ends, so the redraw's rows it never held
    /// are passed over.
    fn settle(&mut self, screen: &vt100::Screen, last: bool) {
        let Some(before) = self.before.as_ref() else { return };
        let (_, cols) = screen.size();
        let rows: Vec<String> = screen.rows(0, cols).map(|text| bare(&text)).collect();
        let now: String = rows.concat();
        // A short row - a timer, one wrapped word - is somewhere in any screen, so it is shown
        // only as a row of its own.
        let shown = |text: &str| now.contains(text) && (text.chars().count() >= SHORT_ROW || rows.iter().any(|row| row == text));
        let mut header = String::new();
        let mut lost: Vec<Vec<u8>> = Vec::new();
        let mut survivor = None;
        for row in before {
            if row.text.is_empty() {
                if !lost.is_empty() {
                    lost.push(row.osc.clone());
                }
            } else if !shown(&row.text) {
                lost.push(row.osc.clone());
            } else if lost.is_empty() {
                header.push_str(&row.text);
            } else {
                survivor = Some(row.text.as_str());
                break;
            }
        }
        if survivor.is_none() && !last {
            return;
        }
        let drawn = |row: &str, kept: &str| row.starts_with(kept) || kept.starts_with(row);
        let under_header = survivor.is_some_and(|survivor| {
            rows.iter()
                .filter(|row| !row.is_empty() && !header.contains(row.as_str()) && !self.scrolled.contains(row.as_str()))
                .find(|row| !header.is_empty() || before.iter().any(|kept| !kept.text.is_empty() && drawn(row, &kept.text)))
                .is_some_and(|first| drawn(first, survivor))
        });
        self.before = None;
        self.erased = false;
        // A run that nothing shown follows is the footer, which changes on its own.
        if !under_header {
            return;
        }
        while lost.last().is_some_and(|osc| osc.ends_with(format!("{HISTORY_OSC};[]\u{7}").as_bytes())) {
            lost.pop();
        }
        self.pending.extend(lost);
    }

    /// ROWS of SCREEN are about to scroll away and be kept. After a redraw, the redraw is judged
    /// first; before one, those rows are no longer the redraw's to leave out, so they are
    /// dropped from the screen taken, which would otherwise keep them a second time.
    fn scrolling(&mut self, screen: &vt100::Screen, rows: std::ops::RangeInclusive<u16>) {
        if self.erased {
            self.settle(screen, true);
            return;
        }
        let Some(before) = self.before.as_mut() else { return };
        let (_, cols) = screen.size();
        let texts: Vec<String> = screen.rows(0, cols).map(|text| bare(&text)).collect();
        for row in rows {
            let Some(text) = texts.get(usize::from(row)).filter(|text| !text.is_empty()) else { continue };
            // A narrower screen has cut the row at its new width.
            let index = before.iter().position(|kept| kept.text == *text).or_else(|| before.iter().position(|kept| kept.text.starts_with(text.as_str())));
            if let Some(index) = index {
                before.remove(index);
                self.scrolled.push_str(text);
            }
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
                        self.scrolling(screen, top..=top);
                        self.pending.push(line(screen, top));
                    }
                    Event::ScrollUp(count) if alternate => {
                        let last = bottom.min(top.saturating_add(count.saturating_sub(1)));
                        self.scrolling(screen, top..=last);
                        self.pending.extend((top..=last).map(|row| line(screen, row)));
                    }
                    Event::LineFeed if !alternate && self.normal_region.is_none() && screen.cursor_position().0 + 1 == rows => self.scrolled_off += 1,
                    Event::ScrollUp(count) if !alternate && self.normal_region.is_none() => self.scrolled_off += u64::from(count.min(rows)),
                    _ => {}
                }
                parser.process(&bytes[index..=index]);
                out.extend_from_slice(&bytes[flushed..=index]);
                flushed = index + 1;
                match event {
                    // What vt100's DECSTBM does, to whichever screen is in use when it arrives.
                    Event::Region(first, last) => {
                        let first = first.max(1) - 1;
                        let last = if last == 0 { rows } else { last }.min(rows) - 1;
                        if alternate {
                            self.region = (first < last).then_some((first, last));
                        } else {
                            self.normal_region = (first < last && (first, last) != (0, rows - 1)).then_some((first, last));
                        }
                    }
                    Event::Reset => {
                        self.normal_region = None;
                        self.region = None;
                        self.before = None;
                        self.erased = false;
                    }
                    Event::FreshAlternate => {
                        self.region = None;
                        self.before = None;
                        self.erased = false;
                    }
                    Event::Erase if self.before.is_some() => {
                        self.erased = true;
                        self.waited = 0;
                    }
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
        if self.before.is_some() && !self.in_sequence {
            self.waited = self.waited.saturating_add(1);
        }
        // No redraw came - the CLI drew in place, left the alternate screen or exited - so the
        // screen taken is forgotten rather than judged, long after, against another one.
        if self.before.is_some() && !self.erased && (self.waited >= REDRAW_READS || !parser.screen().alternate_screen()) {
            self.before = None;
        }
        if self.erased && !self.in_sequence {
            self.settle(parser.screen(), self.waited >= REDRAW_READS);
            for osc in std::mem::take(&mut self.pending) {
                out.extend_from_slice(&osc);
                self.retain(osc);
            }
        }
        out
    }

    fn retain(&mut self, osc: Vec<u8>) {
        self.kept += 1;
        self.retained_bytes += osc.len();
        self.retained.push_back(osc);
        while self.retained_bytes > self.limit {
            let Some(oldest) = self.retained.pop_front() else { break };
            self.retained_bytes -= oldest.len();
        }
    }

    /// The pty was resized from OLD_ROWS to ROWS; vt100 moves the region's bottom the same way.
    pub fn resize(&mut self, old_rows: u16, rows: u16) {
        let moved = |(top, bottom): (u16, u16)| {
            let bottom = if bottom + 1 == old_rows { rows } else { (bottom + 1).min(rows) } - 1;
            (if bottom < top { 0 } else { top }, bottom)
        };
        self.region = self.region.map(moved);
        self.normal_region = self.normal_region.map(moved).filter(|&region| region != (0, rows - 1));
    }

    /// The history lines kept, oldest first, each a complete OSC.
    pub fn retained(&self) -> impl Iterator<Item = &[u8]> {
        self.retained.iter().map(Vec::as_slice)
    }

    /// How many lines are kept now.
    pub fn depth(&self) -> usize {
        self.retained.len()
    }

    /// How many lines were ever kept.
    pub fn kept(&self) -> u64 {
        self.kept
    }

    /// How many lines the normal screen ever scrolled off.
    pub fn scrolled_off(&self) -> u64 {
        self.scrolled_off
    }

    /// The runs of the kept line at INDEX, oldest first.
    pub fn runs(&self, index: usize) -> Vec<Run> {
        let Some(osc) = self.retained.get(index) else { return Vec::new() };
        let prefix = format!("\u{1b}]{HISTORY_OSC};");
        let body = osc.strip_prefix(prefix.as_bytes()).and_then(|body| body.strip_suffix(b"\x07")).unwrap_or_default();
        serde_json::from_slice(body).unwrap_or_default()
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

    /// The terminal's own scrollback stops growing once full, so the lines it took are counted.
    #[test]
    fn lines_the_normal_screen_scrolls_off_are_counted_and_not_kept() {
        let mut parser = vt100::Parser::new(3, 20, 2);
        let mut history = History::default();
        feed(&mut history, &mut parser, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\x1b[2S");

        assert_eq!(history.scrolled_off(), 5);
        assert_eq!(history.depth(), 0);
    }

    /// vt100 keeps no scrollback for a screen scrolling inside a region, nor more of a `CSI S`
    /// than the screen holds.
    #[test]
    fn only_what_reaches_the_normal_screens_scrollback_is_counted() {
        let mut parser = vt100::Parser::new(3, 20, 100);
        let mut history = History::default();
        feed(&mut history, &mut parser, "\x1b[2;3r\x1b[3;1Hone\ntwo\n\x1b[5S\x1b[r\x1b[9S");

        assert_eq!(history.scrolled_off(), 3);
        parser.screen_mut().set_scrollback(100);
        assert_eq!(parser.screen().scrollback(), 3, "vt100 kept as many");
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

    /// Resize PARSER to ROWS x COLS the way `Session::resize` does.
    fn resize(history: &mut History, parser: &mut vt100::Parser, rows: u16, cols: u16) {
        history.resizing(parser.screen());
        history.resize(parser.screen().size().0, rows);
        parser.screen_mut().set_size(rows, cols);
    }

    const FULL: &str = "\x1b[?1049hheader\r\none\r\ntwo\r\nthree\r\nfour\r\nfoot 1s";

    /// A full-screen CLI redraws only its newest lines into a smaller screen, so the ones above
    /// them leave without ever scrolling.
    #[test]
    fn lines_a_redraw_after_a_shrink_leaves_out_are_kept() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, FULL);

        resize(&mut history, &mut parser, 4, 20);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthree\r\nfour\r\nfoot 2s");

        assert_eq!(texts(&log), vec!["one", "two"]);
        let mut replay = vt100::Parser::new(4, 20, 0);
        replay.process(b"\x1b[?1049h");
        replay.process(&log);
        assert_eq!(replay.screen().contents(), parser.screen().contents(), "the OSC changes nothing on screen");
    }

    #[test]
    fn a_burst_of_resizes_is_measured_from_the_screen_before_it() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, FULL);

        resize(&mut history, &mut parser, 5, 20);
        resize(&mut history, &mut parser, 4, 16);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthree\r\nfour\r\nfoot 2s");

        assert_eq!(texts(&log), vec!["one", "two"]);
    }

    #[test]
    fn a_line_rewrapped_at_a_new_width_is_not_taken_for_lost() {
        let mut parser = vt100::Parser::new(4, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, "\x1b[?1049hheader\r\nold words\r\nsome long words \u{2503}\r\nfoot");

        resize(&mut history, &mut parser, 4, 10);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nsome long\r\n words\r\nfoot");

        assert_eq!(texts(&log), vec!["old words"]);
    }

    #[test]
    fn a_redraw_split_across_reads_is_judged_once_it_is_whole() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, FULL);

        resize(&mut history, &mut parser, 4, 20);
        let mut log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthr");
        log.extend(feed(&mut history, &mut parser, "ee\r\nfour\r\nfoot 2s"));

        assert_eq!(texts(&log), vec!["one", "two"]);
    }

    /// Output the CLI wrote for the old size can still be arriving after the resize; a scroll in
    /// it comes before the redraw and says nothing about what the redraw leaves out.
    #[test]
    fn a_scroll_before_the_redraw_does_not_judge_it() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, FULL);

        resize(&mut history, &mut parser, 4, 20);
        let early = feed(&mut history, &mut parser, "\x1b[4;1H\n");
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthree\r\nfour\r\nfoot 2s");

        assert_eq!(texts(&early), vec!["header"]);
        assert_eq!(texts(&log), vec!["one", "two"]);
    }

    #[test]
    fn a_line_scrolled_before_the_redraw_is_kept_once() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, FULL);

        resize(&mut history, &mut parser, 4, 20);
        let mut log = feed(&mut history, &mut parser, "\x1b[2;3r\x1b[3;1H\n\x1b[1;4r");
        log.extend(feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthree\r\nfour\r\nfoot 2s"));

        assert_eq!(texts(&log), vec!["one", "two"]);
    }

    /// A narrower screen truncates the line a stale scroll takes, and it is still kept once.
    #[test]
    fn a_truncated_line_scrolled_before_the_redraw_is_kept_once() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, "\x1b[?1049hheader\r\nthe first long one\r\ntwo\r\nthree\r\nfour\r\nfoot 1s");

        resize(&mut history, &mut parser, 4, 8);
        let mut log = feed(&mut history, &mut parser, "\x1b[2;3r\x1b[3;1H\n\x1b[1;4r");
        log.extend(feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthree\r\nfour\r\nfoot 2s"));

        assert_eq!(texts(&log), vec!["the firs", "two"]);
    }

    /// A resize no redraw follows - the CLI drew in place, left, or exited - is forgotten, so a
    /// later erase is not judged against a screen long gone.
    #[test]
    fn a_resize_no_redraw_follows_is_forgotten() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, FULL);

        resize(&mut history, &mut parser, 4, 20);
        for _ in 0..REDRAW_READS {
            feed(&mut history, &mut parser, "\x1b[2;1Hthree\x1b[3;1Hfour");
        }
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nfour\r\nfive\r\nfoot 2s");
        assert!(texts(&log).is_empty(), "{:?}", texts(&log));

        resize(&mut history, &mut parser, 3, 20);
        feed(&mut history, &mut parser, "\x1b[?1049l\x1b[?1049h");
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nfive\r\nfoot");
        assert!(texts(&log).is_empty(), "a fresh alternate screen starts afresh: {:?}", texts(&log));
    }

    /// A redraw at another width renders the same lines differently - truncated elsewhere, a
    /// timer moved on, a rule of another length - so rows can differ that were never lost. A
    /// line lost off the top leaves the first line that survived directly under the header.
    #[test]
    fn rows_a_redraw_only_renders_differently_are_not_taken_for_lost() {
        let mut parser = vt100::Parser::new(6, 30, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, "\x1b[?1049hlogo\r\nrun x      5s\r\n\r\n\r\nfoot a\r\n> input");

        resize(&mut history, &mut parser, 6, 20);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jlogo\r\nrun x    6s\r\n\r\n\r\nfoot b\r\n> input");

        assert!(texts(&log).is_empty(), "{:?}", texts(&log));
    }

    #[test]
    fn a_redraw_that_still_shows_every_line_keeps_nothing() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, "\x1b[?1049hheader\r\none\r\ntwo\r\n\r\n\r\nfoot 1s");

        resize(&mut history, &mut parser, 5, 20);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\none\r\ntwo\r\n\r\nfoot 2s");
        assert!(texts(&log).is_empty());

        resize(&mut history, &mut parser, 8, 20);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\none\r\ntwo\r\n\r\n\r\n\r\n\r\nfoot 3s");
        assert!(texts(&log).is_empty(), "growing loses nothing");
    }

    #[test]
    fn a_resize_on_the_normal_screen_is_left_to_the_terminal() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, "header\r\none\r\ntwo\r\nthree\r\nfour\r\nfoot");

        resize(&mut history, &mut parser, 4, 20);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthree\r\nfour\r\nfoot");

        assert!(texts(&log).is_empty());
    }

    /// A redraw split across reads is judged once it is whole: the lines scrolled after it, or
    /// the end of a later read, whichever comes first, never a half-drawn screen.
    #[test]
    fn lines_left_out_are_kept_before_a_line_scrolled_after_the_redraw() {
        let mut parser = vt100::Parser::new(6, 20, 0);
        let mut history = History::default();
        feed(&mut history, &mut parser, FULL);

        resize(&mut history, &mut parser, 4, 20);
        let log = feed(&mut history, &mut parser, "\x1b[H\x1b[2Jheader\r\nthree\r\nfour\x1b[2;3r\x1b[3;1H\nfive\x1b[1;4r\x1b[4;1Hfoot");

        assert_eq!(texts(&log), vec!["one", "two", "three"]);
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
