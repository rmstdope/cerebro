//! The two append-only JSONL files this view writes: what it decided, and what went wrong.
//!
//! The port of `emacs/cerebro.el`'s own log (`cerebro--log` and its neighbours). The SAME two
//! files, in the same directory, in the same shapes: the lease guarantees exactly one supervisor,
//! so the two views can never write at once, and a navigator who switches supervisor keeps one
//! continuous history.
//!
//! Split the way the rest of the crate is: a pure half that is a total function of plain data and
//! is tested over literals, and one small impure half - `Logger` - which owns the two files.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};

use crate::readers::ReadError;

/// How much of what the view decides is written. The port of `cerebro-log-verbosity`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verbosity {
    /// Only what the view did.
    Decisions,
    /// The decisions, plus one line each time an armed role's trigger ANSWER changes.
    Changes,
    /// The decisions, plus every trigger evaluation on every tick. The complete record.
    Evaluations,
    /// Nothing at all.
    None,
}

/// What this view writes, and there is no way to change it.
///
/// A constant, not a setting: this view has no customisation layer at all, and cb-kcs.4.1, .2 and
/// .3 each made every other number a constant for the same reason. At `Changes` a view that has
/// silently stopped evaluating anything looks exactly like a quiet fleet, where here the absence
/// of lines is itself the alarm.
pub const VERBOSITY: Verbosity = Verbosity::Evaluations;

/// `cerebro-log-max-bytes`: 25 MiB, the size a log may PASS before it is rotated.
pub const MAX_BYTES: u64 = 25 * 1024 * 1024;

/// `cerebro-log-generations`: three rotated generations kept, oldest discarded.
pub const GENERATIONS: u32 = 3;

/// Every event either file carries. Closed, and smaller than elisp's twelve.
///
/// `sweep` and `triage` are absent because this view does neither: it runs no sweeps, and
/// cb-kcs.4.1 declined `cerebro--triage-tell`. There is no `disarm` and no second `arm`: where a
/// name LEFT the armed set is already readable from the `retire` or `give-up` line that put it
/// there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    Start,
    End,
    Retire,
    Nudge,
    Arm,
    Exit,
    GiveUp,
    Evaluate,
    Error,
}

impl Event {
    /// The `event` field's value. `GiveUp` is `"give-up"` - a hyphen, matching elisp's symbol.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::End => "end",
            Self::Retire => "retire",
            Self::Nudge => "nudge",
            Self::Arm => "arm",
            Self::Exit => "exit",
            Self::GiveUp => "give-up",
            Self::Evaluate => "evaluate",
            Self::Error => "error",
        }
    }

    /// Which log this event belongs in: `"errors"` or `"decisions"`.
    ///
    /// The port of `cerebro--log-basename`. Two files, not one, and the reason is the question
    /// each answers: the decisions log is tens of thousands of lines a day and is read by
    /// searching it; the error log is read by OPENING it, because somebody was pointed at it. An
    /// error buried in the first is a file nobody can be sent to.
    pub fn basename(self) -> &'static str {
        if matches!(self, Self::Error) {
            "errors"
        } else {
            "decisions"
        }
    }
}

/// `<shared root>/.cerebro/state/<base>.jsonl`, or its GENERATIONth rotated copy
/// `<base>.<n>.jsonl`. The port of `cerebro--log-file`.
///
/// **The number goes BEFORE the extension** - `decisions.1.jsonl`, not `decisions.jsonl.1` -
/// which is the shape `scripts/agent-state` uses for `transitions.1.jsonl` too, and what a
/// navigator's existing directory already holds.
///
/// The SHARED root, not the enclosing one, exactly as `lifecycle::state_dir` is: this file is the
/// fleet's, and one written from inside a worktree is a file nobody reads.
pub fn log_file(shared_root: &Path, base: &str, generation: Option<u32>) -> PathBuf {
    let name = match generation {
        Some(n) => format!("{base}.{n}.jsonl"),
        None => format!("{base}.jsonl"),
    };
    shared_root.join(".cerebro/state").join(name)
}

/// Whether EVENT is written at VERBOSITY. The port of `cerebro--log-event-p`.
///
/// `None` silences everything; every other verbosity still records what the view DID, and only
/// `Evaluate` is gated. That asymmetry is elisp's and is deliberate: losing the record of a start
/// is a worse failure than a misconfigured verbosity, and `Error` is on the always-written side
/// rather than behind a level of its own - somebody asking for less noise is not asking for a
/// fleet that fails silently.
pub fn log_event_p(event: Event, verbosity: Verbosity) -> bool {
    match verbosity {
        Verbosity::None => false,
        Verbosity::Decisions => !matches!(event, Event::Evaluate),
        Verbosity::Changes | Verbosity::Evaluations => true,
    }
}

/// Whether NAME's evaluation answering REASON is written now. The port of
/// `cerebro--log-evaluation-p`.
///
/// At `Evaluations` every tick is written; at `Changes` only an answer that differs from this
/// agent's last one. `seen` is the caller's memory of that, keyed by name; a name it has never
/// seen is always written.
pub fn log_evaluation_p(
    name: &str,
    reason: Option<&str>,
    seen: &BTreeMap<String, Option<String>>,
    verbosity: Verbosity,
) -> bool {
    if verbosity == Verbosity::Evaluations {
        return true;
    }
    match seen.get(name) {
        Some(last) => last.as_deref() != reason,
        None => true,
    }
}

/// Whether a log of SIZE bytes has passed MAX_BYTES. The port of `cerebro--log-rotate-p`.
///
/// **Strictly greater than**, and `None` - no file yet - is never a rotation.
pub fn log_rotate_p(size: Option<u64>, max_bytes: u64) -> bool {
    matches!(size, Some(size) if size > max_bytes)
}

/// `%Y-%m-%dT%H:%M:%SZ` in UTC, to the second, no fractional part - what `format-time-string`
/// produces in elisp, and what every line already in the navigator's file carries. **Not
/// `to_rfc3339`**, which would emit an offset and a fraction.
fn timestamp(ts: DateTime<Utc>) -> String {
    ts.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// One JSON object, one line: EVENT, TS, then FIELDS **in the order given**, with no trailing
/// newline. The port of `cerebro--log-line`.
///
/// **Built by concatenation over the slice, never through a `serde_json::Map`.** Without the
/// `preserve_order` feature a `Map` is a `BTreeMap` and sorts its keys alphabetically, which would
/// silently reorder every line this view writes away from the shape elisp has been writing for
/// months - and reorder it CONSISTENTLY, so nothing would look wrong. Each value is rendered with
/// `serde_json::to_string`, which is what gets the escaping right; only the object's own braces,
/// commas and colons are written here.
///
/// A `null` field is written rather than dropped: "evaluated, and there was no reason" is the
/// answer half these lines carry, and a missing key would read as "not evaluated".
pub fn log_line(event: Event, ts: DateTime<Utc>, fields: &[(&str, serde_json::Value)]) -> String {
    fn push(key: &str, value: &serde_json::Value, out: &mut String) {
        if out.len() > 1 {
            out.push(',');
        }
        // `to_string` is what gets the escaping right; only the braces, commas and colons are
        // written here. Neither call can fail for a `Value` or a `str`, and a failure would be a
        // dropped field rather than a lost line.
        out.push_str(&serde_json::to_string(key).unwrap_or_default());
        out.push(':');
        out.push_str(&serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()));
    }
    let mut out = String::from("{");
    push("event", &serde_json::Value::from(event.as_str()), &mut out);
    push("ts", &serde_json::Value::from(timestamp(ts)), &mut out);
    for (key, value) in fields {
        push(key, value, &mut out);
    }
    out.push('}');
    out
}

/// The `context` for a failed pane read: the pane's own name, or `"roster"` when the failure was
/// the roster reader's.
///
/// `pane` is `"fleet"` or `"work"` - this view's own screen titles, lowercased, so an error names
/// the pane that went red. The roster is the exception because `read_fleet` runs it as the first
/// half of the fleet read, and a roster that refuses is a different fault from a `ps` that timed
/// out. The discriminator is `ReadError`'s own `source`, which every variant carries and which the
/// reader sets to the program it ran.
pub fn reader_context(pane: &str, error: &ReadError) -> String {
    let source = match error {
        ReadError::Spawn { source, .. }
        | ReadError::Exit { source, .. }
        | ReadError::Invalid { source, .. }
        | ReadError::Timeout { source, .. } => source.as_str(),
    };
    // The path `readers::read_roster` builds - `<scripts_dir>/roster` - and nothing else. A bare
    // `contains` would blame the roster for any path with the word in it.
    if Path::new(source).file_name().is_some_and(|name| name == "roster") {
        return "roster".to_string();
    }
    pane.to_string()
}

/// The two files, and the memory that keeps each of them short.
///
/// Impure, and the ONLY thing in this crate that writes either. Held by `main` beside the
/// `SessionHost`, because every call site is in the loop or in what the loop calls.
#[derive(Debug)]
pub struct Logger {
    shared_root: PathBuf,
    verbosity: Verbosity,
    max_bytes: u64,
    generations: u32,
    /// Whether anything at all is written. `false` while this view is read-only.
    enabled: bool,
    /// Each armed name's last logged evaluation answer, for `log_evaluation_p`. Memory only, lost
    /// with the process, which costs one redundant line per role after a restart rather than a
    /// wrong one.
    seen: BTreeMap<String, Option<String>>,
    /// Each context's last error message, which is what makes an outage one line rather than 120.
    last_error: BTreeMap<String, String>,
}

impl Logger {
    /// The production logger: `VERBOSITY`, `MAX_BYTES`, `GENERATIONS`, and **disabled**.
    ///
    /// Disabled is the safe start: a view that comes up read-only must have written nothing by its
    /// first frame, and `main::start` calls `set_enabled` from the supervision mode it already
    /// resolved before the terminal guard.
    ///
    /// **The root is passed in and never resolved here.** A logger that found its own root would
    /// make every test in this crate append to the navigator's live log.
    pub fn new(shared_root: &Path) -> Self {
        Self::with_policy(shared_root, VERBOSITY, MAX_BYTES, GENERATIONS)
    }

    /// The same, with the policy as parameters, for the rotation and verbosity cases.
    pub fn with_policy(
        shared_root: &Path,
        verbosity: Verbosity,
        max_bytes: u64,
        generations: u32,
    ) -> Self {
        Self {
            shared_root: shared_root.to_path_buf(),
            verbosity,
            max_bytes,
            generations,
            enabled: false,
            seen: BTreeMap::new(),
            last_error: BTreeMap::new(),
        }
    }

    /// Write when this view may act, and not otherwise.
    ///
    /// Driven from `SupervisionMode::may_end`, which is true for `Supervising` and `Draining` and
    /// false for every `ReadOnly`. A **draining** view still ends the sessions it hosts, so it
    /// still has decisions to record. A read-only one writes nothing at all, not even an error: it
    /// decides nothing, and its reader failures are the same fleet seen through a second window,
    /// which would put two accounts of one fleet in the supervisor's own file.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    /// Append one line for EVENT with FIELDS. Silent, and unable to fail.
    ///
    /// Every failure is swallowed - a directory that cannot be made, a file that cannot be opened,
    /// a write that fails - for the reason `cerebro--log` and `scripts/agent-state` both give
    /// about their own: the fleet must never be brought down by a full disk. It returns nothing,
    /// so a caller cannot accidentally start checking.
    pub fn write(&mut self, event: Event, now: DateTime<Utc>, fields: &[(&str, serde_json::Value)]) {
        if !self.enabled || !log_event_p(event, self.verbosity) {
            return;
        }
        let base = event.basename();
        let path = log_file(&self.shared_root, base, None);
        // `.cerebro/state` is made by whichever agent writes its state first, and a fleet that
        // never started never has one - which is exactly the fleet with something to say.
        if let Some(parent) = path.parent() {
            if std::fs::create_dir_all(parent).is_err() {
                return;
            }
        }
        self.rotate(base, &path);
        // ONE `write_all` of the line and its newline together, to a file opened with
        // `create(true).append(true)`. `O_APPEND` plus one write is what lets this share a file
        // with `scripts/agent-state`'s writer and the elisp one without interleaving.
        let line = format!("{}\n", log_line(event, now, fields));
        if let Ok(mut file) =
            std::fs::OpenOptions::new().create(true).append(true).open(&path)
        {
            use std::io::Write;
            let _ = file.write_all(line.as_bytes());
        }
    }

    /// Shift the generations up and discard the oldest, if the live file has passed its size.
    ///
    /// A `generations` of 0 rotates nothing and lets the file grow, which is elisp's behaviour and
    /// is ported rather than corrected.
    fn rotate(&self, base: &str, path: &Path) {
        let size = std::fs::metadata(path).ok().map(|m| m.len());
        if !log_rotate_p(size, self.max_bytes) {
            return;
        }
        let mut n = self.generations;
        while n > 1 {
            let older = log_file(&self.shared_root, base, Some(n));
            let newer = log_file(&self.shared_root, base, Some(n - 1));
            if newer.exists() {
                let _ = std::fs::rename(&newer, &older);
            }
            n -= 1;
        }
        if self.generations > 0 {
            let _ = std::fs::rename(path, log_file(&self.shared_root, base, Some(1)));
        }
    }

    /// Log one evaluation, subject to `log_evaluation_p`, and remember its answer either way.
    ///
    /// The port of `cerebro--log-evaluation`. **`seen` is updated whether or not the line was
    /// written** - elisp does that outside its own `when`, and it is what makes `Changes` mean
    /// "changed since the last EVALUATION" rather than "since the last line".
    ///
    /// The name and the reason are read back out of FIELDS rather than passed twice: they are
    /// already the first and third of the seventeen, and a second copy is a second thing to get
    /// wrong.
    pub fn evaluation(&mut self, now: DateTime<Utc>, fields: &[(&str, serde_json::Value)]) {
        let field = |key: &str| fields.iter().find(|(k, _)| *k == key).map(|(_, v)| v);
        let name = field("agent").and_then(|v| v.as_str()).unwrap_or_default().to_string();
        let reason = field("reason").and_then(|v| v.as_str()).map(str::to_string);
        if log_evaluation_p(&name, reason.as_deref(), &self.seen, self.verbosity) {
            self.write(Event::Evaluate, now, fields);
        }
        self.seen.insert(name, reason);
    }

    /// Record MESSAGE under CONTEXT in the error log - once per outage, not once per read.
    ///
    /// A message identical to the last one logged under this context is dropped; a DIFFERENT
    /// message is a different fault and is written. The work pane re-reads `bd` every 30 seconds
    /// and the fleet pane every 5, so a database locked for an hour is 120 failed reads and one
    /// line. **A recovery clears the context**, so the next failure after a good read is written
    /// even if it says the same thing - otherwise one flap at breakfast would silence that context
    /// all day.
    pub fn error(&mut self, context: &str, message: &str, now: DateTime<Utc>) {
        if self.last_error.get(context).is_some_and(|last| last == message) {
            return;
        }
        // Remembered whether or not the write reached disk, and whether or not this view is
        // enabled: the dedupe is about the fault, not about the file.
        self.last_error.insert(context.to_string(), message.to_string());
        self.write(
            Event::Error,
            now,
            &[
                ("context", serde_json::Value::from(context)),
                ("message", serde_json::Value::from(message)),
            ],
        );
    }

    /// Forget CONTEXT's last message, because it just succeeded.
    pub fn clear_error(&mut self, context: &str) {
        self.last_error.remove(context);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_error_is_logged_beside_the_decisions_not_among_them() {
        assert_eq!(Event::Error.basename(), "errors");
        assert_eq!(Event::Start.basename(), "decisions");
        assert_eq!(Event::Evaluate.basename(), "decisions");
        assert_eq!(Event::GiveUp.as_str(), "give-up");

        let live = log_file(Path::new("/r"), "errors", None);
        assert!(live.ends_with(".cerebro/state/errors.jsonl"), "{live:?}");
        let rotated = log_file(Path::new("/r"), "errors", Some(2));
        assert!(rotated.ends_with(".cerebro/state/errors.2.jsonl"), "{rotated:?}");
    }

    const EVERY: [Event; 9] = [
        Event::Start,
        Event::End,
        Event::Retire,
        Event::Nudge,
        Event::Arm,
        Event::Exit,
        Event::GiveUp,
        Event::Evaluate,
        Event::Error,
    ];

    #[test]
    fn the_verbosity_decides_which_events_are_written() {
        for event in EVERY {
            assert!(log_event_p(event, Verbosity::Evaluations), "{event:?} at evaluations");
            assert!(log_event_p(event, Verbosity::Changes), "{event:?} at changes");
            assert!(!log_event_p(event, Verbosity::None), "{event:?} at none");
            assert_eq!(
                log_event_p(event, Verbosity::Decisions),
                event != Event::Evaluate,
                "{event:?} at decisions"
            );
        }
    }

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn a_log_line_is_one_json_object_with_the_event_first() {
        let line = log_line(
            Event::Start,
            at("2026-08-25T09:30:00Z"),
            &[
                ("agent", serde_json::json!("Xavier")),
                ("role", serde_json::json!("planner")),
                ("reason", serde_json::json!("buffer 0 of 3")),
            ],
        );
        assert_eq!(
            line,
            r#"{"event":"start","ts":"2026-08-25T09:30:00Z","agent":"Xavier","role":"planner","reason":"buffer 0 of 3"}"#
        );
        assert!(!line.contains('\n'), "one line, and the newline is the writer's");
    }

    #[test]
    fn a_null_field_is_written_not_dropped() {
        let line = log_line(
            Event::Evaluate,
            at("2026-08-25T09:30:00Z"),
            &[("reason", serde_json::Value::Null)],
        );
        assert!(line.contains(r#""reason":null"#), "{line}");
    }

    #[test]
    fn the_fields_keep_the_order_they_were_given() {
        let line = log_line(
            Event::Arm,
            at("2026-08-25T09:30:00Z"),
            &[
                ("zebra", serde_json::json!(1)),
                ("agent", serde_json::json!("Storm")),
                ("by", serde_json::json!("roster")),
            ],
        );
        assert_eq!(
            line,
            r#"{"event":"arm","ts":"2026-08-25T09:30:00Z","zebra":1,"agent":"Storm","by":"roster"}"#
        );
    }

    #[test]
    fn the_timestamp_has_no_offset_and_no_fraction() {
        assert_eq!(timestamp(at("2026-08-25T09:30:00.512Z")), "2026-08-25T09:30:00Z");
    }

    #[test]
    fn the_log_rotates_on_size_and_keeps_generations() {
        assert!(log_rotate_p(Some(5000), 4096));
        assert!(!log_rotate_p(Some(4096), 4096), "strictly greater, not at");
        assert!(!log_rotate_p(None, 4096), "no file is never a rotation");
    }

    #[test]
    fn at_changes_only_a_different_answer_is_written() {
        let mut seen = BTreeMap::new();
        seen.insert("Xavier".to_string(), Some("buffer 0 of 2".to_string()));
        seen.insert("Storm".to_string(), None);

        assert!(!log_evaluation_p("Xavier", Some("buffer 0 of 2"), &seen, Verbosity::Changes));
        assert!(log_evaluation_p("Xavier", Some("buffer 1 of 2"), &seen, Verbosity::Changes));
        assert!(log_evaluation_p("Xavier", None, &seen, Verbosity::Changes));
        assert!(!log_evaluation_p("Storm", None, &seen, Verbosity::Changes));
        assert!(log_evaluation_p("Beast", None, &seen, Verbosity::Changes), "never seen");
        assert!(
            log_evaluation_p("Xavier", Some("buffer 0 of 2"), &seen, Verbosity::Evaluations),
            "every tick, at evaluations"
        );
    }

    /// Every disk case builds its own root. NO test may call `Logger::new` on a path it did not
    /// create: a logger that found the repository's own `.cerebro/state` would append fabricated
    /// starts and exits to the file the navigator reads to answer "why did nothing happen".
    fn enabled(root: &Path, max_bytes: u64, generations: u32) -> Logger {
        let mut logger =
            Logger::with_policy(root, Verbosity::Evaluations, max_bytes, generations);
        logger.set_enabled(true);
        logger
    }

    fn lines(root: &Path, base: &str) -> Vec<String> {
        match std::fs::read_to_string(log_file(root, base, None)) {
            Ok(text) => text.lines().map(str::to_string).collect(),
            Err(_) => Vec::new(),
        }
    }

    fn note(logger: &mut Logger, agent: &str) {
        logger.write(Event::Start, Utc::now(), &[("agent", serde_json::json!(agent))]);
    }

    #[test]
    fn the_log_appends_and_rotates_under_a_real_root() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut logger = enabled(root, 4096, 2);

        note(&mut logger, "Xavier");
        note(&mut logger, "Beast");
        assert_eq!(lines(root, "decisions").len(), 2, "appended, not overwritten");

        // Past the size, by writing straight into the file rather than by writing 4096 bytes of
        // fabricated decisions.
        let live = log_file(root, "decisions", None);
        std::fs::write(&live, "x".repeat(5000)).unwrap();
        note(&mut logger, "Storm");

        assert!(log_file(root, "decisions", Some(1)).exists(), "the old file became generation 1");
        assert_eq!(lines(root, "decisions").len(), 1, "and the live file starts again");
    }

    #[test]
    fn the_first_line_makes_the_directory_it_goes_in() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        assert!(!root.join(".cerebro/state").exists(), "the fixture must not have one");

        let mut logger = enabled(root, MAX_BYTES, GENERATIONS);
        note(&mut logger, "Xavier");

        assert_eq!(lines(root, "decisions").len(), 1);
    }

    #[test]
    fn a_log_that_cannot_be_written_is_not_an_error() {
        // A root that does not exist and cannot be made: every failure is swallowed, and the whole
        // assertion is that the call returns.
        let mut logger = enabled(Path::new("/nonexistent/cb-kcs-4-4"), MAX_BYTES, GENERATIONS);
        note(&mut logger, "Xavier");
        logger.error("work", "bd: database is locked", Utc::now());
        logger.evaluation(Utc::now(), &[("agent", serde_json::json!("Xavier"))]);
    }

    #[test]
    fn a_repeated_error_is_written_once() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut logger = enabled(root, MAX_BYTES, GENERATIONS);

        for _ in 0..3 {
            logger.error("work", "bd: database is locked", Utc::now());
        }
        assert_eq!(lines(root, "errors").len(), 1, "one outage is one line");

        logger.error("work", "bd: no such file", Utc::now());
        assert_eq!(lines(root, "errors").len(), 2, "a different message is a different fault");

        logger.clear_error("work");
        logger.error("work", "bd: database is locked", Utc::now());
        assert_eq!(lines(root, "errors").len(), 3, "a recovery clears the context");
    }

    #[test]
    fn the_error_log_carries_what_went_wrong_and_where() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut logger = enabled(root, MAX_BYTES, GENERATIONS);

        logger.error("work", "bd: database is locked", at("2026-08-25T09:30:00Z"));

        assert_eq!(
            lines(root, "errors"),
            vec![
                r#"{"event":"error","ts":"2026-08-25T09:30:00Z","context":"work","message":"bd: database is locked"}"#
                    .to_string()
            ]
        );
        assert!(
            !log_file(root, "decisions", None).exists(),
            "an error goes beside the decisions, never among them"
        );
    }

    #[test]
    fn a_failed_read_names_the_pane_or_the_roster() {
        let ps = ReadError::Timeout { source: "/usr/bin/ps".into(), seconds: 5 };
        let roster = ReadError::Exit {
            source: "/repos/x/.claude/cerebro/scripts/roster".into(),
            status: Some(2),
            stderr: "roster.conf line 3".into(),
            stdout: String::new(),
        };
        let bd = ReadError::Spawn { source: "bd".into(), message: "no such file".into() };

        assert_eq!(reader_context("fleet", &ps), "fleet");
        assert_eq!(reader_context("fleet", &roster), "roster");
        assert_eq!(reader_context("work", &bd), "work");
    }

    #[test]
    fn a_disabled_logger_writes_neither_file() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut logger = Logger::with_policy(root, Verbosity::Evaluations, MAX_BYTES, GENERATIONS);

        note(&mut logger, "Xavier");
        logger.error("work", "bd: database is locked", Utc::now());
        assert!(lines(root, "decisions").is_empty(), "a fresh logger starts disabled");
        assert!(!log_file(root, "errors", None).exists());

        logger.set_enabled(true);
        note(&mut logger, "Xavier");
        assert_eq!(lines(root, "decisions").len(), 1);

        logger.set_enabled(false);
        note(&mut logger, "Beast");
        logger.evaluation(Utc::now(), &[("agent", serde_json::json!("Beast"))]);
        logger.error("fleet", "ps: timed out", Utc::now());
        assert_eq!(lines(root, "decisions").len(), 1, "read-only writes nothing further");
        assert!(!log_file(root, "errors", None).exists(), "not even an error");
    }

    #[test]
    fn an_evaluation_updates_seen_even_when_it_is_not_written() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut logger = Logger::with_policy(root, Verbosity::Changes, MAX_BYTES, GENERATIONS);
        logger.set_enabled(true);
        let evaluate = |logger: &mut Logger, reason: serde_json::Value| {
            logger.evaluation(
                Utc::now(),
                &[("agent", serde_json::json!("Xavier")), ("reason", reason)],
            );
        };

        evaluate(&mut logger, serde_json::json!("buffer 0 of 2"));
        evaluate(&mut logger, serde_json::json!("buffer 0 of 2"));
        assert_eq!(lines(root, "decisions").len(), 1, "the same answer twice is one line");

        evaluate(&mut logger, serde_json::json!("buffer 1 of 2"));
        assert_eq!(lines(root, "decisions").len(), 2, "and a new answer is written");
    }
}
