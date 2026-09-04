//! What `s`, `f` and `k` decide, and every file this crate writes.
//!
//! Split the way the rest of the crate is. The **pure half** - the three decision functions, the
//! refusal sentences, the kill prompt and the quit-refusal body - is a total function of plain
//! data and is tested over literals. The **impure half** is five free functions over a
//! `ReaderPaths` plus `start`, which is the one place `s`'s three steps happen in order.
//!
//! It is its own module rather than part of `readers` because `readers` says of itself that
//! nothing there writes a file, launches, stops or cleans up state, and that sentence is worth
//! keeping true of that file. Every write to the fleet's contracts lives here; the pty writes
//! stay in `session`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

use std::time::Duration;

use crate::model::{AgentKind, FleetRow, RowState};
use crate::readers::{CommandRunner, Programs, ReadError, ReaderPaths};
use crate::sweeps::{finding_command, Finding};
use crate::session::{Ended, SessionHost};
use crate::supervisor::SupervisionMode;

/// `<shared root>/.cerebro/state` - where both contract files live, in the checkout every
/// worktree shares rather than the enclosing one. A stop flag written under `consumer_root` from
/// inside a worktree is a file the fleet view never reads.
fn state_dir(paths: &ReaderPaths) -> PathBuf {
    paths.shared_root.join(".cerebro/state")
}

/// `<shared root>/.cerebro/state/<name>.state.json` - the file the agent itself writes through
/// `scripts/agent-state`, and the fleet view deletes when it ends the session the file describes.
pub fn state_file_path(paths: &ReaderPaths, name: &str) -> PathBuf {
    state_dir(paths).join(format!("{name}.state.json"))
}

/// `<shared root>/.cerebro/state/<name>.stop` - an empty file whose EXISTENCE is the whole signal
/// (`emacs/cerebro.el:3948-3954`). It has no script of its own in either implementation.
pub fn stop_flag_path(paths: &ReaderPaths, name: &str) -> PathBuf {
    state_dir(paths).join(format!("{name}.stop"))
}

/// Does NAME's stop flag exist? A read, not a write, but it belongs beside the writer.
pub fn stop_flag_set(paths: &ReaderPaths, name: &str) -> bool {
    stop_flag_path(paths, name).exists()
}

/// Create NAME's stop flag, empty, creating `.cerebro/state` if it is not there.
///
/// The error is returned rather than swallowed: `f` reporting success over a flag that was not
/// written is the one failure that key can have.
pub fn write_stop_flag(paths: &ReaderPaths, name: &str) -> std::io::Result<()> {
    let path = stop_flag_path(paths, name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, b"")
}

/// Remove NAME's stop flag. A flag that is already gone is success, not an error
/// (`emacs/cerebro.el:6547-6561` catches `file-missing` for the same reason).
pub fn clear_stop_flag(paths: &ReaderPaths, name: &str) -> std::io::Result<()> {
    remove_if_present(&stop_flag_path(paths, name))
}

/// Remove NAME's state file. Absent is success, exactly as above
/// (`emacs/cerebro.el:6527-6545`).
pub fn delete_state_file(paths: &ReaderPaths, name: &str) -> std::io::Result<()> {
    remove_if_present(&state_file_path(paths, name))
}

fn remove_if_present(path: &Path) -> std::io::Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// Seconds an agent must stand in a finished state before its session is ended.
///
/// `cerebro-end-grace`'s default (`emacs/cerebro.el:1569`), as a constant rather than a setting:
/// this view has no customisation layer, and `tests/lib/supervise.cases` names this number in its
/// header so both implementations answer one table. A navigator who has changed the defcustom
/// gets one number from Emacs and this one from here; that is cb-kcs.5's to resolve at cutover.
pub const END_GRACE_SECONDS: i64 = 30;

/// Seconds an `asking` implementer may wait before it is nudged. `cerebro-answer-timeout`'s
/// default (`emacs/cerebro.el:1509`), same reasoning.
pub const ANSWER_TIMEOUT_SECONDS: i64 = 900;

/// Everything the supervision decision reads, and nothing else.
///
/// It does NOT read the bead or the phase. `emacs/cerebro.el`'s own rule, stated in the root
/// `CLAUDE.md`: supervision reads `state` alone, so a typo in the phase vocabulary can mislabel a
/// column and can never break this loop.
#[derive(Clone, Copy, Debug)]
pub struct Supervised<'a> {
    pub kind: AgentKind,
    pub state: &'a RowState,
    /// Does THIS process hold a live session for that agent, one it has not already ended?
    /// `SessionHost::supervisable`. This is Emacs's `external` guard inverted, and it is the whole
    /// of "mine to end": a pid is not an identity, and a view that reached outside its own process
    /// tree would end somebody else's terminal.
    pub ours: bool,
    pub stop_flag: bool,
    /// Is this row's role one whose `idle` means "my pass is over"?
    /// `cerebro-idle-ends-pass-roles` (`emacs/cerebro.el:1593`) is nil by default and no role in
    /// this fleet is on it, so this is `false` for every real row today. It is carried anyway
    /// because the table has rows for it and dropping it would make those rows unanswerable.
    pub idle_ends_pass: bool,
    /// Seconds since the state file's `since`. `None` for a missing or unparseable timestamp, and
    /// `None` is NOT zero: a torn file must never read as an expired grace.
    pub stood: Option<i64>,
}

/// What the poll should do about one agent, or `None` for nothing at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Supervision {
    /// A stop flag says do not start another. End the session now, and clear the flag with it.
    Retire,
    /// The pass is over and the grace has passed. End the session; leave the flag alone.
    End,
    /// A question has gone unanswered too long. Type one line into the session.
    Nudge,
}

/// The port of `cerebro--supervise-action` (`emacs/cerebro.el:1624-1712`) and, folded into it,
/// `cerebro--end-decision` (`:1610-1622`). Held to `tests/lib/supervise.cases`.
pub fn supervise_action(agent: Supervised<'_>) -> Option<Supervision> {
    // The standby arm is decided BEFORE the `ours` guard, and that is not an oversight. `ours` is
    // `SessionHost::supervisable` - "do I host a session I have not already stopped" - and a
    // standby row hosts none by definition, so every standby row arrives with `ours: false` and
    // the guard would swallow the arm entirely. The question a standby row asks is a different
    // one: not "is this session mine to end" but "is this name mine to disarm", and it is, by
    // construction - the only way a row becomes `Standby` is by being in THIS view's armed set.
    // Emacs has the same shape for the same reason: its guard is `external`, which is "up
    // somewhere else", and a standby row is up nowhere.
    //
    // A stop flag written before its session died still says *no further bead*, so a standby
    // implementer under one is disarmed rather than retried (cb-hzs). A standby role's flag is
    // enforced in the start path instead.
    if agent.state == &RowState::Standby {
        return (agent.kind == AgentKind::Implementer && agent.stop_flag)
            .then_some(Supervision::Retire);
    }
    // The guard that wraps everything else: a session this view did not start is somebody else's
    // to end, and a dead one stays dead.
    if !agent.ours {
        return None;
    }
    match agent.state {
        RowState::Idle => match agent.kind {
            AgentKind::Implementer => agent.stop_flag.then_some(Supervision::Retire),
            AgentKind::Interactive => {
                if agent.idle_ends_pass {
                    end_decision(&agent)
                } else {
                    agent.stop_flag.then_some(Supervision::Retire)
                }
            }
        },
        // No kind guard: an implementer between beads has ended its pass in exactly this sense
        // (cb-1or.1).
        RowState::Waiting => end_decision(&agent),
        // The stop flag makes no difference here: the bead is still in flight, so the question
        // still needs an answer or a hand-back.
        RowState::Asking => (agent.kind == AgentKind::Implementer
            && matches!(agent.stood, Some(stood) if stood >= ANSWER_TIMEOUT_SECONDS))
        .then_some(Supervision::Nudge),
        RowState::Working
        | RowState::Up
        // Answered above, ahead of the `ours` guard.
        | RowState::Standby
        | RowState::Dead
        | RowState::Unknown(_)
        // No counterpart in Emacs - a malformed state file is a red diagnostic line here and a
        // different shape there - so it is not in the table and has its own case: a row nobody
        // can parse must never be acted on.
        | RowState::Invalid => None,
    }
}

/// `retire`, `end` or nothing for an agent whose pass is over.
///
/// The flag wins and lands at once: nothing is in flight, so there is nothing for the grace to
/// protect. `>=`, not `>`, which would delay every end by one tick.
fn end_decision(agent: &Supervised<'_>) -> Option<Supervision> {
    if agent.stop_flag {
        return Some(Supervision::Retire);
    }
    matches!(agent.stood, Some(stood) if stood >= END_GRACE_SECONDS).then_some(Supervision::End)
}

/// What is known about a name's last abnormal exit. `None` for every name that has not had one.
///
/// The port of `cerebro--last-exit` (`emacs/cerebro.el:2565-2579`), less its `:line` and
/// `:gave-up`: the sentence lives on the retained screen this crate already keeps, and giving up
/// is cb-kcs.4's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LastExit {
    /// The launcher refused - exit status 2, which is `scripts/launch-preflight`'s status on all
    /// ten of its refusal paths and `scripts/launch`'s for a name already running. Everything
    /// after that is an `exec` of the agent CLI, so no other status can be the launcher's.
    Refused,
    /// Any other non-zero status.
    Code(u32),
    /// The view stopped retrying this name: FAILURES consecutive starts produced no pass. Not
    /// produced by `classify_exit`, which classifies a child that ended; this one is a decision
    /// the loop made about a child that never started, and its only producer is
    /// `SessionHost::note_gave_up`.
    GaveUp { failures: u32 },
}

/// The record an `Ended` leaves, or `None` when nothing went wrong.
///
/// A silent death still gets its code (the navigator's choice, Q2.1): there is no `standby` row
/// in this view, so a blank would make a crashed agent read exactly like one nobody has ever
/// started - which is the confusion the verdict column exists to end. So this never asks whether
/// the child printed anything.
pub fn classify_exit(ended: Ended) -> Option<LastExit> {
    match ended {
        Ended::Status(0) => None,
        Ended::Status(2) => Some(LastExit::Refused),
        Ended::Status(status) => Some(LastExit::Code(status)),
        // Both are this view's own doing, and neither is a verdict about the agent.
        Ended::Signal(_) | Ended::ByView => None,
    }
}

/// The BEAD column's contents for a row that is not running, or nothing.
///
/// `✗ refused` and `✗ code 137` are within the column's floor of ten cells. `✗ 5 failed starts`
/// is seventeen and is NOT. What gives it the room is `ui::columns`, which sizes the column from
/// the cell each row will actually show - `ui::bead_cell` decides which of the three that is.
///
/// `✗` is one char and one cell, so this is safe for the `char`-counting `pad` the column already
/// uses, and a status above 999 truncates like any other cell.
pub fn verdict(exit: LastExit) -> String {
    match exit {
        LastExit::Refused => "✗ refused".to_string(),
        LastExit::Code(code) => format!("✗ code {code}"),
        // The plural is unconditional: `GIVE_UP_AFTER` is 5, and `failures` is never below it
        // here. The count is what distinguishes this row from every other dead one; the exit code
        // is one `Tab` away on the retained screen (the navigator's choice, Q3).
        LastExit::GaveUp { failures } => format!("✗ {failures} failed starts"),
    }
}

/// The gold header notice for one carried-out action, verbatim from
/// `docs/ui/cb-kcs.3-lifecycle-from-state.html` (the navigator's choice, Q2.3: the view says all
/// three, and the third matters most, being the view putting words into a live agent).
pub fn supervision_notice(action: Supervision, name: &str) -> String {
    match action {
        Supervision::Retire => format!("{name} was retired; its stop flag is cleared."),
        Supervision::End => format!("{name} finished its pass and was ended."),
        Supervision::Nudge => format!("{name} was asked to hand its question back."),
    }
}

/// What the view types into a session whose question nobody answered.
///
/// Byte-identical to `cerebro--nudge-message` (`emacs/cerebro.el:3956-3960`), and it names neither
/// a tracker label nor a skill for that constant's own reason: the words go into a live session,
/// and how a work item is handed back is the agent's own instructions to state.
pub const NUDGE_MESSAGE: &str =
    "[cerebro] Nobody answered within the timeout. Do not keep waiting: put the question and \
     everything you have found into the work item, hand it back for a person to decide, exactly \
     as your own instructions describe, and finish the run.";

/// What the view types into an interactive role's session whose question nobody answered.
///
/// Byte-identical to `cerebro--interactive-nudge-message`. It is its own line rather than the
/// implementer's because an interactive role has no bead to hand back - `agents/verifier.md` in
/// particular forbids adding a `human` label - so it defers entirely to the role's own
/// instructions, for `NUDGE_MESSAGE`'s reason.
pub const INTERACTIVE_NUDGE_MESSAGE: &str =
    "[cerebro] Nobody answered within the timeout. Do not keep waiting: record the question and \
     everything you have found where your own instructions say an unanswered question goes, then \
     finish the run.";

/// The line typed into a session of KIND whose question nobody answered.
pub fn nudge_message(kind: AgentKind) -> &'static str {
    match kind {
        AgentKind::Implementer => NUDGE_MESSAGE,
        AgentKind::Interactive => INTERACTIVE_NUDGE_MESSAGE,
    }
}

/// How many bead ids the triage line names before saying `and N more`.
/// `cerebro--triage-ids-shown` (`emacs/cerebro.el:4067`).
pub const TRIAGE_IDS_SHOWN: usize = 8;

/// Seconds before an idle Cerebro is told again about the same unranked set.
///
/// `cerebro-triage-repeat`'s default (`emacs/cerebro.el:4055`), a constant here for
/// `END_GRACE_SECONDS`' reason: this crate has no place to declare a customisation and must not
/// invent one. `tests/lib/triage.cases` names the number in its header, so both implementations
/// answer one table.
pub const TRIAGE_REPEAT_SECONDS: i64 = 600;

/// What the view types into an idle orchestrator.
///
/// Byte-identical to `cerebro--triage-message` (`emacs/cerebro.el:4078-4088`), which is what
/// Cerebro already reads. Ids and no count, capped at `TRIAGE_IDS_SHOWN` with ` and N more`
/// appended: the panel counts a P4 epic's children one by one where Cerebro folds them into one
/// question, so a count would be a number Cerebro cannot reproduce.
pub fn triage_message(ids: &[String]) -> String {
    let shown = ids.len().min(TRIAGE_IDS_SHOWN);
    let extra = ids.len() - shown;
    let more = if extra > 0 { format!(" and {extra} more") } else { String::new() };
    format!(
        "[cerebro] Unranked beads are waiting for a ranking: {}{more}. Triage them with the \
         navigator.",
        ids[..shown].join(", ")
    )
}

/// Tell, repeat, or leave it alone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Triage {
    /// The set differs from what this name was last told.
    Tell,
    /// The same set, told `TRIAGE_REPEAT_SECONDS` or more ago. A typed line can be lost and
    /// Cerebro writes nothing back to say it heard.
    Repeat,
}

/// Everything the triage decision reads, and nothing else - `Supervised`'s shape.
#[derive(Clone, Copy, Debug)]
pub struct Triaged<'a> {
    pub role: &'a str,
    pub kind: AgentKind,
    pub state: &'a RowState,
    /// `SessionHost::supervisable` - hosted here and not already ending. This is where the
    /// navigator's Q4 decision lives: the view says nothing and records nothing about a session
    /// it cannot type into. Emacs's `external` inverted, the way `Supervised::ours` is.
    pub ours: bool,
    /// The sorted unranked ids (`triggers::unranked_ids`).
    pub ids: &'a [String],
    /// What this name was last told, and when.
    pub told: Option<(&'a [String], DateTime<Utc>)>,
    /// Seconds since the row's `since`. `None` when the state file did not say - never 0, so a
    /// torn file cannot read as a satisfied deadline.
    pub idle_for: Option<i64>,
    /// Seconds since the work read was REQUESTED - not since it answered. Arrival is later, and
    /// an arrival-based age passes the guard below in cases the rule refuses.
    pub panel_age: Option<i64>,
    pub now: DateTime<Utc>,
}

/// The port of `cerebro--triage-action` (`emacs/cerebro.el:4090-4118`). Held to
/// `tests/lib/triage.cases`.
///
/// `None` unless every one of these holds: the role is `orchestrator`, the kind is `Interactive`,
/// `ours`, the state is EXACTLY `Idle`, `ids` is non-empty, `idle_for` and `panel_age` are both
/// known, and `panel_age < idle_for` - the board was read AFTER the agent went idle, so the set
/// was not measured before Cerebro ranked it.
pub fn triage_action(agent: Triaged<'_>) -> Option<Triage> {
    if agent.role != "orchestrator"
        || agent.kind != AgentKind::Interactive
        || !agent.ours
        || agent.state != &RowState::Idle
        || agent.ids.is_empty()
    {
        return None;
    }
    let (idle_for, panel_age) = (agent.idle_for?, agent.panel_age?);
    if panel_age >= idle_for {
        return None;
    }
    match agent.told {
        Some((told, at)) if told == agent.ids => {
            ((agent.now - at).num_seconds() >= TRIAGE_REPEAT_SECONDS).then_some(Triage::Repeat)
        }
        _ => Some(Triage::Tell),
    }
}

/// The gold header notice for a triage line that went into a session.
///
/// Beside `supervision_notice`, whose nudge line this one sits next to. The name comes from the
/// roster and is not always the word `Cerebro`; the ids are deliberately not in it, since the
/// line's width would then depend on the board (the navigator's choice, round two).
pub fn triage_notice(name: &str, count: usize) -> String {
    let beads = if count == 1 { "bead" } else { "beads" };
    format!("{name} was asked to rank {count} unranked {beads}.")
}

/// Each name's last told set and when.
///
/// Memory only, lost with the process - one redundant line after a restart rather than a wrong
/// one, exactly as `Logger::seen` accepts. `cerebro--triage-told`'s counterpart.
#[derive(Debug, Default)]
pub struct TriageLedger {
    told: BTreeMap<String, (Vec<String>, DateTime<Utc>)>,
}

impl TriageLedger {
    pub fn told(&self, name: &str) -> Option<(&[String], DateTime<Utc>)> {
        self.told.get(name).map(|(ids, at)| (ids.as_slice(), *at))
    }

    pub fn note_told(&mut self, name: &str, ids: &[String], now: DateTime<Utc>) {
        self.told.insert(name.to_string(), (ids.to_vec(), now));
    }

    /// Forgotten for a name the moment the set is empty, so a set that comes back is told as a
    /// change and not as a repeat (`cerebro--triage-told`'s own rule).
    pub fn forget(&mut self, name: &str) {
        self.told.remove(name);
    }
}

/// Seconds between one sweep line and the next.
///
/// `cerebro-sweep-interval`'s default, a constant here for `END_GRACE_SECONDS`' reason: this
/// crate has no place to declare a customisation and must not invent one.
/// `tests/lib/sweep-tell.cases` names the number in its header, so both implementations answer
/// one table.
pub const SWEEP_INTERVAL_SECONDS: i64 = 7200;

/// What the view types into an idle orchestrator when its two hours are up.
///
/// Byte-identical to `cerebro--sweep-message` (`emacs/cerebro.el`), which is what Cerebro
/// actually reads; two literal-pinning tests are what keep them so, exactly as
/// `triage_message`'s pair does. It names the pass rather than any ids, because there are none,
/// and "the two sweeps that are yours" is `agents/orchestrator.md`'s own phrase, so the agent
/// finds the section it means.
pub const SWEEP_MESSAGE: &str = "[cerebro] Two hours since your last sweep. Run the two sweeps \
                                 that are yours - the claims, and the worktrees the pruner \
                                 declined - and bring the navigator anything that needs a \
                                 judgement.";

/// Type it, queue it, drop the clock, or start it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sweep {
    /// The mark has passed (or a line is queued) and this Cerebro is idle: type it now.
    Tell,
    /// The mark has passed while Cerebro was not idle. A flag, not a count: a second and third
    /// mark passing while it is set change nothing, so six hours of work is followed by ONE
    /// sweep.
    Queue,
    /// No session this view hosts. Drop the mark and any queued line - a mark that passed while
    /// Cerebro was down is not delivered when it comes back, since Cerebro sweeps at startup.
    Forget,
    /// A hosted session this view holds no mark for: start the clock, silently. So a Cerebro the
    /// view has just started is told two hours after it came up rather than at once, which is
    /// right, because a Cerebro that has just started has just swept.
    Mark,
}

/// Everything the sweep decision reads, and nothing else - `Triaged`'s shape.
#[derive(Clone, Copy, Debug)]
pub struct Sweeping<'a> {
    pub role: &'a str,
    pub kind: AgentKind,
    pub state: &'a RowState,
    /// `SessionHost::supervisable` - hosted here and not already ending. Emacs's
    /// `cerebro--session' answering a live buffer, and NOT the weaker `external' test its triage
    /// teller uses.
    pub ours: bool,
    /// Seconds since this name's mark: the last sweep line typed into it, or the first tick this
    /// view saw a session for it. `None` when this view holds no mark for it.
    pub since_mark: Option<i64>,
    /// A mark has already passed while this name was not idle.
    pub pending: bool,
}

/// The port of `cerebro--sweep-action`. Held to `tests/lib/sweep-tell.cases`.
///
/// `Tell` fires on `pending` REGARDLESS of how recently the mark moved: a queued line waits for
/// idle however long that takes. Writing the rule as `since_mark >= INTERVAL && (idle ||
/// pending)` passes most of the table and drops exactly the case the navigator asked for.
pub fn sweep_action(agent: Sweeping<'_>) -> Option<Sweep> {
    if agent.role != "orchestrator" || agent.kind != AgentKind::Interactive {
        return None;
    }
    if !agent.ours {
        return Some(Sweep::Forget);
    }
    let Some(since_mark) = agent.since_mark else {
        return Some(Sweep::Mark);
    };
    if !agent.pending && since_mark < SWEEP_INTERVAL_SECONDS {
        return None;
    }
    Some(if agent.state == &RowState::Idle { Sweep::Tell } else { Sweep::Queue })
}

/// The gold header notice for a sweep line that went into a session.
///
/// Beside `triage_notice`, whose line this one sits next to. The name comes from the roster and
/// is not always the word `Cerebro`.
pub fn sweep_notice(name: &str) -> String {
    format!("{name} was asked to sweep.")
}

/// Each name's mark and pending flag.
///
/// Memory only, lost with the process - one silent restart of the clock rather than a line typed
/// into a Cerebro that has just swept, exactly as `TriageLedger` accepts its own loss.
#[derive(Debug, Default)]
pub struct SweepLedger {
    marks: BTreeMap<String, (DateTime<Utc>, bool)>,
}

impl SweepLedger {
    pub fn mark(&self, name: &str) -> Option<DateTime<Utc>> {
        self.marks.get(name).map(|(at, _)| *at)
    }

    pub fn pending(&self, name: &str) -> bool {
        self.marks.get(name).is_some_and(|(_, pending)| *pending)
    }

    /// Sets the mark to NOW and clears the pending flag. Both "the clock starts" and "a line was
    /// typed" are this one call - see `Sweep::Mark` and `Sweep::Tell`.
    pub fn note_marked(&mut self, name: &str, now: DateTime<Utc>) {
        self.marks.insert(name.to_string(), (now, false));
    }

    /// Sets the pending flag without moving the mark. A name with no mark cannot queue a line:
    /// `Sweep::Mark` is what the decision answers there.
    pub fn note_pending(&mut self, name: &str) {
        if let Some(entry) = self.marks.get_mut(name) {
            entry.1 = true;
        }
    }

    pub fn forget(&mut self, name: &str) {
        self.marks.remove(name);
    }
}

/// Everything the three decisions read, and nothing else.
#[derive(Clone, Copy, Debug)]
pub struct Situation<'a> {
    pub mode: &'a SupervisionMode,
    /// The selected fleet row. `None` when nothing is selected.
    pub row: Option<&'a FleetRow>,
    /// Does THIS view hold a live session for that agent (`SessionHost::is_live`)? This is the
    /// whole of "hosted here": a pid is not an identity, and neither a `FleetRow::pid` nor a
    /// marker-sentence process scan is authority to kill anything.
    pub hosted: bool,
    /// Does the agent's stop flag exist?
    pub stop_flag: bool,
}

/// What `s` does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartOutcome {
    /// Spawn. `clears_flag` is true whenever a stop flag exists, for EVERY kind - the rule
    /// `cerebro--flag-start-action` answers in Emacs for `s`, autostart and the trigger alike.
    /// A name started under its own stop flag would be held or retired again at once.
    Launch { clears_flag: bool },
    /// Do nothing, and put TEXT in the header's notice slot, in gold.
    Refuse(String),
    /// Do nothing and say nothing.
    Ignore,
}

/// What `f` does. `f` is a TOGGLE (the navigator's choice, Q9): it sets the flag, and pressed
/// again it clears the one it set.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FinishOutcome {
    Write,
    Clear,
    Refuse(String),
    Ignore,
}

/// What `k` does. Killing is the one key that asks first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KillOutcome {
    /// Put PROMPT in the notice slot in gold and wait for a keystroke. `disarm` says WHICH
    /// question was asked - a standby row is disarmed, anything else is killed - so the sentence
    /// and the action it confirms are decided in one place and cannot drift apart.
    Confirm { prompt: String, disarm: bool },
    Refuse(String),
    Ignore,
}

/// Is this row's agent running at all, as far as the fleet read can tell?
///
/// `Standby` is not: it is `apply_standby`'s restatement of a `Dead` row this view has armed, so
/// there is no process anywhere under that name. Without it here, `s` on a backing-off row -
/// which is the row a navigator most wants to start by hand, the backoff being the whole reason
/// it is not starting itself - refuses with `is running outside this view`.
fn row_is_alive(row: &FleetRow) -> bool {
    !matches!(row.state, RowState::Dead | RowState::Invalid | RowState::Standby)
}

/// What `s` decides, in this order.
pub fn start_outcome(situation: Situation<'_>) -> StartOutcome {
    // No row means no agent to name, and the Session pane already says `No agent selected.`
    let Some(row) = situation.row else { return StartOutcome::Ignore };
    if !situation.mode.may_supervise() {
        return StartOutcome::Refuse(refusal_for(situation.mode));
    }
    if situation.hosted {
        return StartOutcome::Refuse(format!("{} is already up", row.name));
    }
    if row_is_alive(row) {
        return StartOutcome::Refuse(format!("{} is running outside this view", row.name));
    }
    StartOutcome::Launch {
        clears_flag: situation.stop_flag,
    }
}

/// What `f` decides, in this order.
pub fn finish_outcome(situation: Situation<'_>) -> FinishOutcome {
    let Some(row) = situation.row else { return FinishOutcome::Ignore };
    if !situation.mode.may_end() {
        return FinishOutcome::Refuse(refusal_for(situation.mode));
    }
    // Before every liveness test on purpose: clearing a flag somebody left set must work whether
    // or not the agent is up, since a flag outlives a session and is what strands a name.
    if situation.stop_flag {
        return FinishOutcome::Clear;
    }
    // `f` means what it always means. Rule 3 above already clears a flag it set, so pressing `f`
    // twice on a standby row is the same toggle as anywhere else.
    if row.state == RowState::Standby {
        return FinishOutcome::Write;
    }
    if !situation.hosted {
        return FinishOutcome::Refuse(elsewhere_or_absent(row));
    }
    FinishOutcome::Write
}

/// What `k` decides, in this order.
pub fn kill_outcome(situation: Situation<'_>) -> KillOutcome {
    let Some(row) = situation.row else { return KillOutcome::Ignore };
    if !situation.mode.may_end() {
        return KillOutcome::Refuse(refusal_for(situation.mode));
    }
    // Ahead of the two rules that refuse a name that is not running: a standby row hosts no
    // session by construction, and `k` on one means disarm rather than kill.
    if row.state == RowState::Standby {
        return KillOutcome::Confirm { prompt: disarm_prompt(&row.name), disarm: true };
    }
    if !situation.hosted {
        return KillOutcome::Refuse(elsewhere_or_absent(row));
    }
    KillOutcome::Confirm { prompt: kill_prompt(row), disarm: false }
}

/// The two sentences `f` and `k` share for an agent this view is not hosting.
fn elsewhere_or_absent(row: &FleetRow) -> String {
    if row_is_alive(row) {
        format!("{} is running outside this view - stop it from its own terminal", row.name)
    } else {
        format!("{} is not running", row.name)
    }
}

/// The gold prompt `k` puts in the notice slot, verbatim and chosen by the navigator. Two spaces
/// before `y / n` in both. The bead comes from the fleet row and nowhere else, so the prompt and
/// the row two panes away cannot disagree.
fn kill_prompt(row: &FleetRow) -> String {
    match &row.bead {
        Some(bead) => format!("Kill {}? Its bead {bead} stays claimed.  y / n", row.name),
        None => format!("Kill {}?  y / n", row.name),
    }
}

/// The gold prompt `k` puts in the notice slot for a standby row. Two spaces before `y / n`, the
/// shape `kill_prompt` already has, where the second sentence is the consequence the navigator
/// might not have in mind. No bead is named: a standby row has none.
fn disarm_prompt(name: &str) -> String {
    format!("Disarm {name}? The view will stop bringing it back.  y / n")
}

/// What the header says once `y` is pressed. It restates the consequence the prompt named, so the
/// question and the outcome match.
pub fn disarm_notice(name: &str) -> String {
    format!("{name} is disarmed; the view will not bring it back.")
}

/// What the header says when a handover empties the armed set (cb-nc8).
///
/// A second function rather than a parameter on `disarm_notice`, which names one agent for the
/// disarm prompt and is a different sentence.
pub fn disarm_all_notice(count: usize) -> String {
    let names = if count == 1 { "name" } else { "names" };
    format!("Handing supervision over; {count} {names} disarmed.")
}

/// The one read-only sentence, naming no owner: the header's own title already names which of the
/// six reasons applies, immediately to the left of this (Q12).
const READ_ONLY_REFUSAL: &str = "This view is read-only; it starts and stops nothing";

/// Why a key did nothing, given the mode that refused it.
///
/// `Supervising` is unreachable - nothing calls this with a mode that may act - and returns the
/// read-only sentence rather than panicking, because a screen is not the place to abort.
fn refusal_for(mode: &SupervisionMode) -> String {
    match mode {
        SupervisionMode::Draining { live_sessions, .. } => format!(
            "Handoff pending: {live_sessions} session{} still hosted; only f and k act now",
            if *live_sessions == 1 { "" } else { "s" }
        ),
        SupervisionMode::ReadOnly(_) | SupervisionMode::Supervising => {
            READ_ONLY_REFUSAL.to_string()
        }
    }
}

/// `["Xavier"]` -> `Xavier`; `["Xavier","Beast"]` -> `Xavier and Beast`;
/// `["Xavier","Beast","Cyclops"]` -> `Xavier, Beast and Cyclops`. No serial comma - the approved
/// mockup's own spelling.
pub fn join_names(names: &[String]) -> String {
    match names {
        [] => String::new(),
        [only] => only.clone(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

/// The quit-refusal pane's title: `3 live agents prevent exit`, singular for one.
pub fn quit_refusal_title(count: usize) -> String {
    if count == 1 {
        "1 live agent prevents exit".to_string()
    } else {
        format!("{count} live agents prevent exit")
    }
}

/// The whole body of the quit-refusal pane, for LIVE agents named in fleet order. Pure over the
/// names alone, so a test is a literal.
pub fn quit_refusal_lines(live: &[String]) -> Vec<Line<'static>> {
    vec![
        Line::from(Span::styled(
            format!("Cerebro is supervising {}.", join_names(live)),
            Style::default().fg(Color::Red),
        )),
        Line::from(""),
        Line::from("Finish or kill every live agent before quitting."),
        Line::from("  f  finish the selected agent after its pass"),
        Line::from("  k  kill the selected agent now"),
        Line::from(""),
        Line::from(Span::styled(
            "No agent was stopped. Any key returns.".to_string(),
            Style::default().add_modifier(Modifier::DIM),
        )),
    ]
}

/// What `x` did, in the three lines the header shows for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FindingOutcome {
    /// `ran <command>`, in gold.
    Ran { text: String },
    /// `ran, but bd dolt push failed — other machines will not see this yet`, in gold.
    ///
    /// The command is deliberately NOT repeated: it has just been on screen in the confirmation,
    /// and the news in this line is the push. With it the line runs to 106 cells, which is cut on
    /// every terminal this view is used on (approved 2026-09-02).
    Pushed { text: String },
    /// `<command> failed`, in red.
    Failed { text: String },
}

/// The least urgent priority `bd` takes. `cerebro-priority-floor` - this project's backlog floor;
/// a consumer whose tracker ranks differently would set its own.
pub const PRIORITY_FLOOR: u8 = 4;

/// PRIORITY moved by DELTA, clamped to the range `bd` accepts.
///
/// Clamped rather than wrapped: holding `+` stops at P0 and holding `-` stops at the backlog
/// floor, and neither rolls round. `cerebro--nudged-priority`.
pub fn nudged_priority(priority: u8, delta: i8) -> u8 {
    (i16::from(priority) + i16::from(delta)).clamp(0, i16::from(PRIORITY_FLOOR)) as u8
}

/// What a priority keystroke asked for: an exact number, or a step.
///
/// `+` is more urgent and `-` is less, which means `+` LOWERS the number
/// (`cerebro-beads-raise`/`lower`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Requested {
    Exactly(u8),
    Nudge(i8),
}

/// What a priority keystroke means before anything is run. Pure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PriorityAction {
    /// Ask `bd` for this.
    Write { to: u8 },
    /// `cb-x is already P0` - a keystroke that does nothing must not leave an undo entry claiming
    /// it did.
    AlreadyThere { text: String },
    /// `+`/`-` on a bead `bd` gave no priority. Nothing is written and nothing is said: the board
    /// always sets one, so this is unreachable in practice, and a refusal sentence for it would be
    /// a string nobody can produce.
    Nothing,
}

/// The digit keys and the two nudges, over one decision.
pub fn priority_action(id: &str, current: Option<u8>, requested: Requested) -> PriorityAction {
    let to = match requested {
        Requested::Exactly(to) => to,
        Requested::Nudge(delta) => match current {
            Some(current) => nudged_priority(current, delta),
            None => return PriorityAction::Nothing,
        },
    };
    if current == Some(to) {
        return PriorityAction::AlreadyThere { text: format!("{id} is already P{to}") };
    }
    PriorityAction::Write { to }
}

/// What a priority write did, and the exact sentence for it. The gold/red split is the
/// renderer's: `Ran` and `Pushed` are gold, `Failed` is red.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PriorityOutcome {
    /// `cb-kcs.4.2: P1 → P0`, or `cb-kcs.4.2: back to P1` for an undo.
    Ran { text: String },
    /// `cb-kcs.4.2: P1 → P0, but bd dolt push failed — other machines will not see this yet`
    Pushed { text: String },
    /// `bd would not set cb-kcs.4.2 to P0`
    Failed { text: String },
}

/// Run `bd update <id> --priority <to>` in the shared root, then `bd dolt push` on the same
/// keystroke - no confirmation, because reranking twenty beads would otherwise be forty
/// keystrokes and `u` already covers the mis-key.
///
/// **One of the two `bd` calls in this crate that do not pass `--readonly`** - `run_finding`
/// below is the other - and it lives here beside
/// `run_finding` for that reason. Deliberately OUTSIDE the supervision lease, exactly as
/// `run_finding` is: the board is shared, so a view that may start nothing may still rank a bead.
///
/// FROM is what the row said before, and is only ever used to build the sentence - `bd` is given
/// the new number alone, so a stale FROM cannot write the wrong priority. UNDO picks the sentence
/// and nothing else.
pub fn set_priority(
    paths: &ReaderPaths,
    programs: &Programs,
    commands: &dyn CommandRunner,
    id: &str,
    from: Option<u8>,
    to: u8,
    undo: bool,
) -> PriorityOutcome {
    let argv = priority_command(id, to, &programs.bd);
    // Through `readers::CommandRunner` like every other command this crate runs (cb-i1w): the
    // draining, the bound and the kill-and-reap live there, and `run_finding` beside this is the
    // only other board write.
    let run = |args: &[String]| {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        commands
            .run(&programs.bd, &args, Some(&paths.shared_root), WRITE_TIMEOUT)
            .is_ok()
    };
    if !run(&argv[1..]) {
        return PriorityOutcome::Failed { text: format!("bd would not set {id} to P{to}") };
    }
    // `?` for a bead that carried no priority - `cerebro--set-priority`'s own spelling.
    let text = if undo {
        format!("{id}: back to P{to}")
    } else {
        let from = from.map(|p| p.to_string()).unwrap_or_else(|| "?".to_string());
        format!("{id}: P{from} → P{to}")
    };
    if run(&["dolt".to_string(), "push".to_string()]) {
        PriorityOutcome::Ran { text }
    } else {
        PriorityOutcome::Pushed {
            text: format!(
                "{text}, but bd dolt push failed — other machines will not see this yet"
            ),
        }
    }
}

/// The one place the priority write's argv is spelled.
pub fn priority_command(id: &str, to: u8, bd: &Path) -> Vec<String> {
    vec![
        bd.display().to_string(),
        "update".into(),
        id.to_string(),
        "--priority".into(),
        to.to_string(),
    ]
}

/// How long a board write may take. Thirty seconds, chosen for the PUSH rather than inherited:
/// the `bd` itself is a local write and answers in well under a second, while `bd dolt push`
/// talks to the Dolt remote with the navigator's finger still on the key. `readers::GH_TIMEOUT`
/// is the same number for the same reason - a network call somebody is waiting on - and it is far
/// short of a sweep's two minutes, where nobody is.
///
/// A push that outruns it is killed and reported as `ran, but bd dolt push failed`, which is
/// honest: the write happened and the other machines cannot see it yet. The recovery is the next
/// `bd dolt push` anybody makes, so erring short costs a line the navigator can ignore, where
/// erring long costs a frozen screen.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

/// Run FINDING's command, then `bd dolt push`, and say which of the three happened.
///
/// The push rides the same keypress and is not confirmed separately: a close or a reclaim the
/// other machines cannot see is half done, and asking twice for one keystroke's worth of intent
/// is its own kind of noise (`emacs/cerebro.el:1473-1479`).
///
/// **One of the two `bd` calls in this crate that do not pass `--readonly`** - `set_priority`
/// above is the other - and this module is the only place a board write may live. `readers::read_beads` passes it deliberately; copying that neighbouring
/// call here would produce a command that appears to succeed and changes nothing.
///
/// Both commands go through `readers::CommandRunner`, like every other command this crate runs
/// (cb-i1w): the draining, the bound and the kill-and-reap live there, so `readers` remains the
/// one place a command is spawned. They run in `paths.shared_root`, where every `bd` this crate
/// runs already points.
pub fn run_finding(
    paths: &ReaderPaths,
    programs: &Programs,
    commands: &dyn CommandRunner,
    finding: &Finding,
) -> FindingOutcome {
    let argv = finding_command(finding, &programs.bd);
    let text = argv.join(" ");
    let run = |args: &[String]| {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        commands
            .run(&programs.bd, &args, Some(&paths.shared_root), WRITE_TIMEOUT)
            .is_ok()
    };
    if !run(&argv[1..]) {
        return FindingOutcome::Failed { text: format!("{text} failed") };
    }
    if run(&["dolt".to_string(), "push".to_string()]) {
        FindingOutcome::Ran { text: format!("ran {text}") }
    } else {
        FindingOutcome::Pushed {
            text: "ran, but bd dolt push failed — other machines will not see this yet".into(),
        }
    }
}

/// Everything `s` does once `start_outcome` said `Launch`, in this order:
///
/// 1. clear the stale stop flag, when the decision asked for it;
/// 2. delete NAME's state file - one present now is a previous session's, since a name with a
///    live session was refused at step 3 of `start_outcome`, and a file that outlives its session
///    outlives its pid (cb-hzs);
/// 3. spawn.
///
/// Returns the line for the notice slot on success, and the launcher's own error on failure -
/// which the caller turns into a refused-launch pane rather than into a notice.
pub fn start(
    host: &mut SessionHost,
    paths: &ReaderPaths,
    name: &str,
    clears_flag: bool,
) -> Result<String, ReadError> {
    if clears_flag {
        clear_stop_flag(paths, name).map_err(|error| ReadError::Spawn {
            source: format!("the stop flag for {name}"),
            message: error.to_string(),
        })?;
    }
    // A state file that could not be removed is not a reason to refuse a start: the agent's own
    // first transition overwrites it, and refusing here would leave a name unstartable.
    let _ = delete_state_file(paths, name);
    host.spawn(name, paths)?;
    Ok(if clears_flag {
        format!("Started {name}, and cleared a stale stop flag.")
    } else {
        format!("Started {name}.")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::readers::testing::FakeCommands;
    use crate::supervisor::ReadOnlyReason;

    #[test]
    fn a_verdict_names_a_refusal_a_code_or_nothing() {
        assert_eq!(classify_exit(Ended::Status(0)), None);
        assert_eq!(classify_exit(Ended::Status(2)), Some(LastExit::Refused));
        assert_eq!(classify_exit(Ended::Status(137)), Some(LastExit::Code(137)));
        // This view's own doing, both of them, and neither is a verdict about the agent.
        assert_eq!(classify_exit(Ended::Signal(9)), None);
        assert_eq!(classify_exit(Ended::ByView), None);

        assert_eq!(verdict(LastExit::Refused), "✗ refused");
        assert_eq!(verdict(LastExit::Code(137)), "✗ code 137");
        // Exactly the column's floor, in chars and in cells: it must never need truncating.
        assert_eq!(verdict(LastExit::Code(137)).chars().count(), 10);
    }

    #[test]
    fn a_name_the_view_gave_up_on_says_how_many_starts_failed() {
        // Not `classify_exit`'s: this is a decision the loop made about a child that never
        // started, and its only producer is `SessionHost::note_gave_up`.
        assert_eq!(verdict(LastExit::GaveUp { failures: 5 }), "\u{2717} 5 failed starts");
    }

    /// The three sentences the header says, and the one the view types into a live session.
    /// The nudge is pinned against a literal on purpose: a test that rebuilt it from the constant
    /// would prove nothing, and this one is byte-identical to `cerebro--nudge-message`.
    #[test]
    fn the_view_says_what_it_did_and_types_one_line() {
        assert_eq!(
            supervision_notice(Supervision::Retire, "Storm"),
            "Storm was retired; its stop flag is cleared."
        );
        assert_eq!(
            supervision_notice(Supervision::End, "Cyclops"),
            "Cyclops finished its pass and was ended."
        );
        assert_eq!(
            supervision_notice(Supervision::Nudge, "Cyclops"),
            "Cyclops was asked to hand its question back."
        );
        assert_eq!(
            NUDGE_MESSAGE,
            "[cerebro] Nobody answered within the timeout. Do not keep waiting: put the question \
             and everything you have found into the work item, hand it back for a person to \
             decide, exactly as your own instructions describe, and finish the run."
        );
    }

    /// The interactive roles are nudged in their own words, and the implementer's line is
    /// untouched. Both pinned against literals, for the reason above.
    #[test]
    fn the_interactive_nudge_is_the_words_emacs_types() {
        assert_eq!(
            nudge_message(AgentKind::Interactive),
            "[cerebro] Nobody answered within the timeout. Do not keep waiting: record the \
             question and everything you have found where your own instructions say an \
             unanswered question goes, then finish the run."
        );
        assert_eq!(nudge_message(AgentKind::Implementer), NUDGE_MESSAGE);
        assert_ne!(
            nudge_message(AgentKind::Interactive),
            nudge_message(AgentKind::Implementer)
        );
    }

    // --- the shared supervision table -----------------------------------------------------------

    fn table_kind(word: &str) -> AgentKind {
        match word {
            "implementer" => AgentKind::Implementer,
            "interactive" => AgentKind::Interactive,
            other => panic!("supervise.cases: unknown kind {other}"),
        }
    }

    fn table_state(word: &str) -> RowState {
        match word {
            "working" => RowState::Working,
            "idle" => RowState::Idle,
            "waiting" => RowState::Waiting,
            "asking" => RowState::Asking,
            "dead" => RowState::Dead,
            "up" => RowState::Up,
            "unknown" => RowState::Unknown("something".to_string()),
            "standby" => RowState::Standby,
            other => panic!("supervise.cases: unknown state {other}"),
        }
    }

    fn table_flag(word: &str) -> bool {
        match word {
            "yes" => true,
            "no" => false,
            other => panic!("supervise.cases: expected yes or no, got {other}"),
        }
    }

    fn table_action(word: &str) -> Option<Supervision> {
        match word {
            "retire" => Some(Supervision::Retire),
            "end" => Some(Supervision::End),
            "nudge" => Some(Supervision::Nudge),
            "none" => None,
            other => panic!("supervise.cases: unknown action {other}"),
        }
    }

    /// Every row of `tests/lib/supervise.cases`, which `cerebro--supervise-action` answers too.
    /// A row the two answer differently is a session ended twice or never.
    #[test]
    fn the_supervision_table_is_answered_here() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/lib/supervise.cases");
        let text =
            std::fs::read_to_string(path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"));
        let mut rows = 0;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = trimmed.split_whitespace().collect();
            assert_eq!(fields.len(), 7, "supervise.cases: malformed row: {line}");
            let state = table_state(fields[1]);
            let stood = match fields[5] {
                "none" => None,
                number => Some(
                    number
                        .parse::<i64>()
                        .unwrap_or_else(|_| panic!("supervise.cases: bad stood: {line}")),
                ),
            };
            let agent = Supervised {
                kind: table_kind(fields[0]),
                state: &state,
                ours: table_flag(fields[2]),
                stop_flag: table_flag(fields[3]),
                idle_ends_pass: table_flag(fields[4]),
                stood,
            };
            assert_eq!(supervise_action(agent), table_action(fields[6]), "row: {line}");
            rows += 1;
        }
        assert!(rows >= 34, "supervise.cases: only {rows} rows ran");
    }

    /// The two things the table cannot carry, both of which end a session that should be left
    /// alone if they are got wrong.
    #[test]
    fn an_unparseable_state_file_is_never_acted_on() {
        for (kind, state, idle_ends_pass) in [
            (AgentKind::Implementer, RowState::Waiting, false),
            (AgentKind::Interactive, RowState::Idle, true),
            (AgentKind::Implementer, RowState::Asking, false),
        ] {
            let agent = Supervised {
                kind,
                state: &state,
                ours: true,
                stop_flag: false,
                idle_ends_pass,
                stood: None,
            };
            assert_eq!(supervise_action(agent), None, "for {state:?}");
        }
    }

    #[test]
    fn an_invalid_row_is_never_acted_on() {
        let state = RowState::Invalid;
        for stop_flag in [false, true] {
            let agent = Supervised {
                kind: AgentKind::Implementer,
                state: &state,
                ours: true,
                stop_flag,
                idle_ends_pass: false,
                stood: Some(5_000),
            };
            assert_eq!(supervise_action(agent), None);
        }
    }

    fn paths(root: &Path) -> ReaderPaths {
        ReaderPaths {
            consumer_root: root.join("worktree"),
            shared_root: root.to_path_buf(),
            scripts_dir: root.join("scripts"),
        }
    }

    fn row(name: &str, kind: AgentKind, state: RowState) -> FleetRow {
        FleetRow {
            name: name.to_string(),
            role: "implementer".to_string(),
            kind,
            state,
            phase: None,
            bead: None,
            since: None,
            phase_since: None,
            pid: None,
            sessions: 1,
            diagnostic: None,
        }
    }

    fn situation<'a>(
        mode: &'a SupervisionMode,
        row: Option<&'a FleetRow>,
        hosted: bool,
        stop_flag: bool,
    ) -> Situation<'a> {
        Situation { mode, row, hosted, stop_flag }
    }

    #[test]
    fn a_quit_refusal_names_every_live_agent() {
        assert_eq!(join_names(&["Xavier".to_string()]), "Xavier");
        assert_eq!(
            join_names(&["Xavier".to_string(), "Beast".to_string()]),
            "Xavier and Beast"
        );
        assert_eq!(
            join_names(&[
                "Xavier".to_string(),
                "Beast".to_string(),
                "Cyclops".to_string()
            ]),
            "Xavier, Beast and Cyclops"
        );
        assert_eq!(join_names(&[]), "");

        assert_eq!(quit_refusal_title(1), "1 live agent prevents exit");
        assert_eq!(quit_refusal_title(3), "3 live agents prevent exit");

        let lines = quit_refusal_lines(&[
            "Xavier".to_string(),
            "Beast".to_string(),
            "Cyclops".to_string(),
        ]);
        let text: Vec<String> =
            lines.iter().map(|line| line.spans.iter().map(|s| s.content.as_ref()).collect()).collect();
        assert_eq!(text.first().unwrap(), "Cerebro is supervising Xavier, Beast and Cyclops.");
        assert_eq!(text.last().unwrap(), "No agent was stopped. Any key returns.");
        assert!(text.contains(&"Finish or kill every live agent before quitting.".to_string()));
        assert!(text.contains(&"  f  finish the selected agent after its pass".to_string()));
        assert!(text.contains(&"  k  kill the selected agent now".to_string()));

        let one = quit_refusal_lines(&["Cyclops".to_string()]);
        let first: String = one[0].spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(first, "Cerebro is supervising Cyclops.");
        assert_eq!(one[0].spans[0].style.fg, Some(Color::Red));
        let last = one.last().unwrap();
        assert!(last.spans[0].style.add_modifier.contains(Modifier::DIM));
    }

    #[test]
    fn the_three_keys_decide_the_way_emacs_does() {
        let up = SupervisionMode::Supervising;
        let dead = row("Cyclops", AgentKind::Implementer, RowState::Dead);
        let alive = row("Storm", AgentKind::Implementer, RowState::Working);
        let interactive = row("Xavier", AgentKind::Interactive, RowState::Dead);

        // s: a dead agent starts, and clears a stale flag for EVERY kind - the rule
        // `cerebro--flag-start-action` answers in Emacs, widened to `s` by cb-sxf.
        assert_eq!(
            start_outcome(situation(&up, Some(&dead), false, false)),
            StartOutcome::Launch { clears_flag: false }
        );
        assert_eq!(
            // Not hosted: an agent this view hosts is refused at step 3, so the clears-flag
            // case is a dead implementer with a flag left behind.
            start_outcome(situation(&up, Some(&dead), false, true)),
            StartOutcome::Launch { clears_flag: true }
        );
        assert_eq!(
            start_outcome(situation(&up, Some(&interactive), false, true)),
            StartOutcome::Launch { clears_flag: true }
        );
        assert_eq!(
            start_outcome(situation(&up, Some(&dead), true, false)),
            StartOutcome::Refuse("Cyclops is already up".to_string())
        );
        assert_eq!(
            start_outcome(situation(&up, Some(&alive), false, false)),
            StartOutcome::Refuse("Storm is running outside this view".to_string())
        );
        assert_eq!(start_outcome(situation(&up, None, false, false)), StartOutcome::Ignore);
        // A standby row hosts no process anywhere under that name - it is a `Dead` row this view
        // has armed - so `s` starts it. It is the row a navigator most wants to start by hand,
        // the backoff being the whole reason it is not starting itself.
        let waiting = row("Beast", AgentKind::Interactive, RowState::Standby);
        assert_eq!(
            start_outcome(situation(&up, Some(&waiting), false, false)),
            StartOutcome::Launch { clears_flag: false }
        );

        // f: the flag wins over every liveness test, so a flag somebody left set can be cleared.
        assert_eq!(finish_outcome(situation(&up, Some(&dead), false, true)), FinishOutcome::Clear);
        assert_eq!(finish_outcome(situation(&up, Some(&dead), true, true)), FinishOutcome::Clear);
        assert_eq!(finish_outcome(situation(&up, Some(&dead), true, false)), FinishOutcome::Write);
        assert_eq!(
            finish_outcome(situation(&up, Some(&alive), false, false)),
            FinishOutcome::Refuse(
                "Storm is running outside this view - stop it from its own terminal".to_string()
            )
        );
        assert_eq!(
            finish_outcome(situation(&up, Some(&dead), false, false)),
            FinishOutcome::Refuse("Cyclops is not running".to_string())
        );
        assert_eq!(finish_outcome(situation(&up, None, false, false)), FinishOutcome::Ignore);

        // k: only a session this view hosts, and it asks first.
        assert_eq!(
            kill_outcome(situation(&up, Some(&dead), true, false)),
            KillOutcome::Confirm { prompt: "Kill Cyclops?  y / n".to_string(), disarm: false }
        );
        assert_eq!(
            kill_outcome(situation(&up, Some(&alive), false, false)),
            KillOutcome::Refuse(
                "Storm is running outside this view - stop it from its own terminal".to_string()
            )
        );
        assert_eq!(
            kill_outcome(situation(&up, Some(&dead), false, false)),
            KillOutcome::Refuse("Cyclops is not running".to_string())
        );
        // A flag set does not turn a kill into a clear: only `f` reads it.
        assert_eq!(
            kill_outcome(situation(&up, Some(&dead), true, true)),
            KillOutcome::Confirm { prompt: "Kill Cyclops?  y / n".to_string(), disarm: false }
        );
        assert_eq!(kill_outcome(situation(&up, None, false, false)), KillOutcome::Ignore);
    }

    #[test]
    fn only_the_modes_that_may_act_get_past_the_gate() {
        let dead = row("Cyclops", AgentKind::Implementer, RowState::Dead);
        let read_only = SupervisionMode::ReadOnly(ReadOnlyReason::NotOwned);
        let sentence = "This view is read-only; it starts and stops nothing".to_string();

        assert_eq!(
            start_outcome(situation(&read_only, Some(&dead), false, false)),
            StartOutcome::Refuse(sentence.clone())
        );
        assert_eq!(
            finish_outcome(situation(&read_only, Some(&dead), true, false)),
            FinishOutcome::Refuse(sentence.clone())
        );
        assert_eq!(
            kill_outcome(situation(&read_only, Some(&dead), true, false)),
            KillOutcome::Refuse(sentence)
        );

        let draining =
            SupervisionMode::Draining { configured_for: None, live_sessions: 2 };
        assert_eq!(
            start_outcome(situation(&draining, Some(&dead), false, false)),
            StartOutcome::Refuse(
                "Handoff pending: 2 sessions still hosted; only f and k act now".to_string()
            )
        );
        assert_eq!(
            finish_outcome(situation(&draining, Some(&dead), true, false)),
            FinishOutcome::Write
        );
        assert_eq!(
            kill_outcome(situation(&draining, Some(&dead), true, false)),
            KillOutcome::Confirm { prompt: "Kill Cyclops?  y / n".to_string(), disarm: false }
        );
    }

    #[test]
    fn refusal_sentences_read_as_agreed() {
        for reason in [
            ReadOnlyReason::ConfiguredFor(crate::supervisor::SupervisorKind::Emacs),
            ReadOnlyReason::OwnedBy(crate::supervisor::SupervisorKind::Emacs),
            ReadOnlyReason::InvalidDeclaration("rat".to_string()),
            ReadOnlyReason::LockError("boom".to_string()),
            ReadOnlyReason::DeclarationUnreadable("boom".to_string()),
            ReadOnlyReason::NotOwned,
        ] {
            assert_eq!(
                refusal_for(&SupervisionMode::ReadOnly(reason.clone())),
                "This view is read-only; it starts and stops nothing",
                "sentence for {reason:?}"
            );
        }

        assert_eq!(
            refusal_for(&SupervisionMode::Draining { configured_for: None, live_sessions: 1 }),
            "Handoff pending: 1 session still hosted; only f and k act now"
        );
        assert_eq!(
            refusal_for(&SupervisionMode::Draining { configured_for: None, live_sessions: 3 }),
            "Handoff pending: 3 sessions still hosted; only f and k act now"
        );
        // Unreachable in practice, and a screen is not the place to abort.
        assert_eq!(
            refusal_for(&SupervisionMode::Supervising),
            "This view is read-only; it starts and stops nothing"
        );
    }

    #[test]
    fn a_kill_prompt_names_the_bead_when_there_is_one() {
        let mut with_bead = row("Cyclops", AgentKind::Implementer, RowState::Working);
        with_bead.bead = Some("cb-42k".to_string());
        assert_eq!(
            kill_prompt(&with_bead),
            "Kill Cyclops? Its bead cb-42k stays claimed.  y / n"
        );

        let without = row("Cerebro", AgentKind::Interactive, RowState::Working);
        assert_eq!(kill_prompt(&without), "Kill Cerebro?  y / n");
    }

    #[test]
    fn a_stop_flag_is_an_empty_file_under_the_shared_root() {
        let dir = tempfile::tempdir().unwrap();
        let paths = paths(dir.path());

        let path = stop_flag_path(&paths, "Cyclops");
        assert!(path.ends_with(".cerebro/state/Cyclops.stop"), "{}", path.display());
        assert!(path.starts_with(dir.path()));

        assert!(!stop_flag_set(&paths, "Cyclops"));
        write_stop_flag(&paths, "Cyclops").unwrap();
        assert!(stop_flag_set(&paths, "Cyclops"));
        assert_eq!(std::fs::read(&path).unwrap(), Vec::<u8>::new());

        clear_stop_flag(&paths, "Cyclops").unwrap();
        assert!(!stop_flag_set(&paths, "Cyclops"));
    }

    #[test]
    fn clearing_a_flag_that_is_not_there_is_success() {
        let dir = tempfile::tempdir().unwrap();
        clear_stop_flag(&paths(dir.path()), "Nobody").unwrap();
    }

    #[test]
    fn deleting_a_state_file_that_is_not_there_is_success() {
        let dir = tempfile::tempdir().unwrap();
        delete_state_file(&paths(dir.path()), "Nobody").unwrap();
    }

    #[test]
    fn a_state_file_is_deleted_when_it_is_there() {
        let dir = tempfile::tempdir().unwrap();
        let paths = paths(dir.path());
        std::fs::create_dir_all(state_dir(&paths)).unwrap();
        let path = state_file_path(&paths, "Cyclops");
        std::fs::write(&path, "{}").unwrap();
        delete_state_file(&paths, "Cyclops").unwrap();
        assert!(!path.exists());
    }

    /// `readers::read_states` must open the path THIS module builds, not a second spelling of it.
    ///
    /// Asserted by writing a file at `state_file_path` and checking the reader parsed it: a
    /// re-inlined path in `readers.rs` would read nothing and answer `Missing`, which is what a
    /// test that only re-derived the literal here could never see.
    #[test]
    fn the_state_file_path_is_the_one_the_readers_use() {
        use crate::model::{RosterEntry, StateObservation};

        let dir = tempfile::tempdir().unwrap();
        let paths = paths(dir.path());
        let path = state_file_path(&paths, "Xavier");
        assert_eq!(path, paths.shared_root.join(".cerebro/state").join("Xavier.state.json"));

        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, r#"{"state":"working","bead":"cb-1","since":"2026-01-01T00:00:00Z","pid":1}"#).unwrap();

        let roster = vec![RosterEntry {
            name: "Xavier".to_string(),
            role: "planner".to_string(),
            kind: AgentKind::Interactive,
        }];
        match crate::readers::read_states(&paths, &roster).get("Xavier") {
            Some(StateObservation::Parsed(record)) => {
                assert_eq!(record.bead.as_deref(), Some("cb-1"));
            }
            other => panic!("the reader did not open the path this module builds: {other:?}"),
        }
    }

    // --- standby rows (cb-kcs.4.1) ---------------------------------------------------------

    #[test]
    fn k_on_a_standby_row_offers_to_disarm_it() {
        let mode = SupervisionMode::Supervising;
        let row = row("Xavier", AgentKind::Interactive, RowState::Standby);
        // A standby row hosts no session, which is exactly what rules 3 and 4 refuse - so the
        // arm sits ahead of them.
        assert_eq!(
            kill_outcome(situation(&mode, Some(&row), false, false)),
            KillOutcome::Confirm {
                prompt: "Disarm Xavier? The view will stop bringing it back.  y / n".to_string(),
                disarm: true,
            }
        );
        assert_eq!(
            disarm_notice("Xavier"),
            "Xavier is disarmed; the view will not bring it back."
        );
    }

    #[test]
    fn f_on_a_standby_row_writes_the_flag_and_the_second_press_clears_it() {
        let mode = SupervisionMode::Supervising;
        let row = row("Cyclops", AgentKind::Implementer, RowState::Standby);
        assert_eq!(
            finish_outcome(situation(&mode, Some(&row), false, false)),
            FinishOutcome::Write
        );
        // Rule 3 already precedes it, so a second press clears the flag it set.
        assert_eq!(
            finish_outcome(situation(&mode, Some(&row), false, true)),
            FinishOutcome::Clear
        );
    }
    // --- the first board write (cb-kcs.5.1) --------------------------------------------------

    /// What ran, as the argv the recorder used to append: the program and the bound are asserted
    /// on their own in `the_board_write_goes_through_the_one_seam`.
    fn argv(fake: &FakeCommands) -> Vec<String> {
        fake.calls().iter().map(|c| c.args.join(" ")).collect()
    }

    /// A `bd` that exited non-zero - the only kind of failure these cases care to distinguish.
    fn failed_bd() -> ReadError {
        ReadError::Exit {
            source: "bd".into(),
            status: Some(1),
            stderr: String::new(),
            stdout: String::new(),
        }
    }

    fn paths_in(root: &Path) -> ReaderPaths {
        ReaderPaths {
            consumer_root: root.to_path_buf(),
            shared_root: root.to_path_buf(),
            scripts_dir: root.join("scripts"),
        }
    }

    /// The board writes spawn through the same seam every other command in this crate goes
    /// through - the bound and the directory included, neither of which a fixture script could
    /// see. There are two of them since cb-kcs.5.4; `set_priority` has its own case below.
    #[test]
    fn the_board_write_goes_through_the_one_seam() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let paths = paths_in(dir.path());
        let programs = Programs::default();
        let fake = FakeCommands::always("");

        let outcome =
            run_finding(&paths, &programs, &fake, &Finding::Unclaim { id: "cb-a".into() });

        let calls = fake.calls();
        assert_eq!(calls.len(), 2, "the write and the push");
        for call in &calls {
            assert_eq!(call.program, programs.bd);
            assert_eq!(call.cwd.as_deref(), Some(paths.shared_root.as_path()));
            assert_eq!(call.timeout, WRITE_TIMEOUT);
        }
        assert_eq!(calls[0].args, vec!["unclaim", "cb-a"]);
        assert_eq!(calls[1].args, vec!["dolt", "push"]);
        assert!(matches!(outcome, FindingOutcome::Ran { .. }));
    }

    /// And so does the second one. Its own case rather than a line in the one above, because what
    /// is worth pinning is the same three things per call - and the CWD above all: `consumer_root`
    /// in a bead worktree is a DIFFERENT board, and an edit that passed it here would be green
    /// against an argv-only assertion.
    #[test]
    fn the_priority_write_goes_through_the_one_seam() {
        let dir = tempfile::tempdir().expect("a temp dir");
        // DISTINCT roots, unlike `paths_in`'s: in a bead worktree the enclosing root is a
        // different board from the shared one, so a cwd assertion made where the two are equal
        // cannot tell them apart - which is exactly the edit this case exists to catch.
        let paths = ReaderPaths {
            consumer_root: dir.path().join("worktree"),
            shared_root: dir.path().join("shared"),
            scripts_dir: dir.path().join("scripts"),
        };
        let programs = Programs::default();
        let fake = FakeCommands::always("");

        let outcome = set_priority(&paths, &programs, &fake, "cb-x", Some(1), 0, false);

        let calls = fake.calls();
        assert_eq!(calls.len(), 2, "the write and the push");
        for call in &calls {
            assert_eq!(call.program, programs.bd);
            assert_eq!(call.cwd.as_deref(), Some(paths.shared_root.as_path()));
            assert_eq!(call.timeout, WRITE_TIMEOUT);
        }
        assert_eq!(calls[0].args, vec!["update", "cb-x", "--priority", "0"]);
        assert_eq!(calls[1].args, vec!["dolt", "push"]);
        assert!(matches!(outcome, PriorityOutcome::Ran { .. }));
    }

    /// The push rides the same keypress: a close the other machines cannot see is half done.
    #[test]
    fn running_a_finding_pushes_after_it_succeeds() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let programs = Programs::default();
        let fake = FakeCommands::always("");
        let outcome = run_finding(
            &paths_in(dir.path()),
            &programs,
            &fake,
            &Finding::Unclaim { id: "cb-a".into() },
        );
        assert_eq!(argv(&fake), vec!["unclaim cb-a", "dolt push"]);
        assert_eq!(
            outcome,
            FindingOutcome::Ran { text: format!("ran {} unclaim cb-a", programs.bd.display()) }
        );
    }

    /// The write succeeded and only the push failed, so this is not "nothing happened" - and the
    /// command is deliberately not repeated in the line: it has just been on screen in the
    /// confirmation, and with it the line runs to 106 cells.
    #[test]
    fn a_failed_push_is_said_and_the_write_is_not_undone() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let fake = FakeCommands::new(|call| {
            if call.args.first().map(String::as_str) == Some("dolt") {
                Err(failed_bd())
            } else {
                Ok(Vec::new())
            }
        });
        let outcome = run_finding(
            &paths_in(dir.path()),
            &Programs::default(),
            &fake,
            &Finding::Reclaim { id: "cb-a".into() },
        );
        assert_eq!(argv(&fake), vec!["reclaim --id cb-a --older-than 10m", "dolt push"]);
        assert_eq!(
            outcome,
            FindingOutcome::Pushed {
                text: "ran, but bd dolt push failed — other machines will not see this yet".into()
            }
        );
    }

    /// A command that failed is not pushed: there is nothing to publish, and a push would say the
    /// write happened.
    #[test]
    fn a_failed_command_does_not_push() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let programs = Programs::default();
        let fake = FakeCommands::failing(failed_bd);
        let outcome = run_finding(
            &paths_in(dir.path()),
            &programs,
            &fake,
            &Finding::EpicClose { id: "cb-e".into() },
        );
        assert_eq!(argv(&fake), vec!["close cb-e"], "the push never ran");
        assert_eq!(
            outcome,
            FindingOutcome::Failed {
                text: format!("{} close cb-e failed", programs.bd.display())
            }
        );
    }

    // --- the shared triage table ---------------------------------------------------------------

    fn triage_ids(field: &str) -> Vec<String> {
        if field == "-" {
            Vec::new()
        } else {
            field.split(',').map(str::to_string).collect()
        }
    }

    fn triage_number(field: &str, line: &str) -> Option<i64> {
        match field {
            "-" => None,
            number => Some(
                number
                    .parse::<i64>()
                    .unwrap_or_else(|_| panic!("triage.cases: bad number: {line}")),
            ),
        }
    }

    fn triage_expect(word: &str) -> Option<Triage> {
        match word {
            "tell" => Some(Triage::Tell),
            "repeat" => Some(Triage::Repeat),
            "none" => None,
            other => panic!("triage.cases: unknown expectation {other}"),
        }
    }

    /// Every row of `tests/lib/triage.cases`, which `cerebro--triage-action` answers too. A row
    /// the two answer differently is an idle Cerebro told twice or never told at all.
    #[test]
    fn the_shared_triage_table_is_answered_here() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/lib/triage.cases");
        let text =
            std::fs::read_to_string(path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"));
        let now = Utc::now();
        let mut rows = 0;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = trimmed.split_whitespace().collect();
            assert_eq!(fields.len(), 10, "triage.cases: malformed row: {line}");
            let state = table_state(fields[2]);
            let ids = triage_ids(fields[4]);
            let told_ids = triage_ids(fields[5]);
            let told = (!told_ids.is_empty()).then(|| {
                let age = triage_number(fields[6], line)
                    .unwrap_or_else(|| panic!("triage.cases: told without an age: {line}"));
                (told_ids.as_slice(), now - chrono::Duration::seconds(age))
            });
            let agent = Triaged {
                role: fields[0],
                kind: table_kind(fields[1]),
                state: &state,
                ours: table_flag(fields[3]),
                ids: &ids,
                told,
                idle_for: triage_number(fields[7], line),
                panel_age: triage_number(fields[8], line),
                now,
            };
            assert_eq!(triage_action(agent), triage_expect(fields[9]), "row: {line}");
            rows += 1;
        }
        assert!(rows >= 15, "triage.cases: only {rows} rows ran");
    }

    fn sweep_expect(word: &str) -> Option<Sweep> {
        match word {
            "tell" => Some(Sweep::Tell),
            "queue" => Some(Sweep::Queue),
            "forget" => Some(Sweep::Forget),
            "mark" => Some(Sweep::Mark),
            "none" => None,
            other => panic!("sweep-tell.cases: unknown expectation {other}"),
        }
    }

    /// Every row of `tests/lib/sweep-tell.cases`, which `cerebro--sweep-action` answers too. A row
    /// the two answer differently is a Cerebro told to sweep twice in one window, or never told.
    #[test]
    fn the_shared_sweep_table_is_answered_here() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/lib/sweep-tell.cases");
        let text =
            std::fs::read_to_string(path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"));
        let mut rows = 0;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = trimmed.split_whitespace().collect();
            assert_eq!(fields.len(), 7, "sweep-tell.cases: malformed row: {line}");
            let state = table_state(fields[2]);
            let agent = Sweeping {
                role: fields[0],
                kind: table_kind(fields[1]),
                state: &state,
                ours: table_flag(fields[3]),
                since_mark: triage_number(fields[4], line),
                pending: table_flag(fields[5]),
            };
            assert_eq!(sweep_action(agent), sweep_expect(fields[6]), "row: {line}");
            rows += 1;
        }
        assert!(rows >= 20, "sweep-tell.cases: only {rows} rows ran");
    }

    #[test]
    fn the_sweep_ledger_marks_queues_and_forgets() {
        let now = Utc::now();
        let mut ledger = SweepLedger::default();
        assert_eq!(ledger.mark("Cerebro"), None, "an unknown name holds no mark");
        assert!(!ledger.pending("Cerebro"), "an unknown name has nothing queued");

        // A name with no mark cannot queue: `Sweep::Mark` is what the decision answers there.
        ledger.note_pending("Cerebro");
        assert!(!ledger.pending("Cerebro"));

        ledger.note_marked("Cerebro", now);
        assert_eq!(ledger.mark("Cerebro"), Some(now));
        assert!(!ledger.pending("Cerebro"));

        ledger.note_pending("Cerebro");
        assert!(ledger.pending("Cerebro"));
        assert_eq!(ledger.mark("Cerebro"), Some(now), "queueing does not move the mark");

        let later = now + chrono::Duration::seconds(30);
        ledger.note_marked("Cerebro", later);
        assert_eq!(ledger.mark("Cerebro"), Some(later));
        assert!(!ledger.pending("Cerebro"), "typing the line clears the queued flag");

        ledger.note_pending("Cerebro");
        ledger.forget("Cerebro");
        assert_eq!(ledger.mark("Cerebro"), None);
        assert!(!ledger.pending("Cerebro"));
    }

    /// The exact bytes Cerebro reads. `cerebro--sweep-message` is pinned against the same
    /// literal in `emacs/cerebro-test.el`; there is no cross-language check of the two, exactly
    /// as `triage_message` has none.
    #[test]
    fn the_sweep_line_says_what_cerebro_reads() {
        assert_eq!(
            SWEEP_MESSAGE,
            "[cerebro] Two hours since your last sweep. Run the two sweeps that are yours - the \
             claims, and the worktrees the pruner declined - and bring the navigator anything \
             that needs a judgement."
        );
    }

    #[test]
    fn the_sweep_notice_names_the_agent() {
        assert_eq!(sweep_notice("Cerebro"), "Cerebro was asked to sweep.");
        assert_eq!(sweep_notice("Xavier"), "Xavier was asked to sweep.");
    }

    #[test]
    fn the_triage_line_names_up_to_eight_beads() {
        let ids = |n: usize| -> Vec<String> {
            (1..=n).map(|i| format!("cb-{i:02}")).collect()
        };
        assert_eq!(
            triage_message(&ids(1)),
            "[cerebro] Unranked beads are waiting for a ranking: cb-01. Triage them with the \
             navigator."
        );
        assert_eq!(
            triage_message(&ids(2)),
            "[cerebro] Unranked beads are waiting for a ranking: cb-01, cb-02. Triage them with \
             the navigator."
        );
        assert_eq!(
            triage_message(&ids(8)),
            "[cerebro] Unranked beads are waiting for a ranking: cb-01, cb-02, cb-03, cb-04, \
             cb-05, cb-06, cb-07, cb-08. Triage them with the navigator."
        );
        assert_eq!(
            triage_message(&ids(9)),
            "[cerebro] Unranked beads are waiting for a ranking: cb-01, cb-02, cb-03, cb-04, \
             cb-05, cb-06, cb-07, cb-08 and 1 more. Triage them with the navigator."
        );
        assert_eq!(
            triage_message(&ids(10)),
            "[cerebro] Unranked beads are waiting for a ranking: cb-01, cb-02, cb-03, cb-04, \
             cb-05, cb-06, cb-07, cb-08 and 2 more. Triage them with the navigator."
        );
    }

    #[test]
    fn the_triage_notice_counts_in_the_singular() {
        assert_eq!(triage_notice("Cerebro", 1), "Cerebro was asked to rank 1 unranked bead.");
        assert_eq!(triage_notice("Cerebro", 3), "Cerebro was asked to rank 3 unranked beads.");
        // The name comes from the roster and is not always the word Cerebro.
        assert_eq!(triage_notice("Xavier", 2), "Xavier was asked to rank 2 unranked beads.");
    }

    /// The handover sentence, singular for one name (cb-nc8).
    #[test]
    fn disarm_all_notice_is_singular_for_one_name() {
        assert_eq!(disarm_all_notice(1), "Handing supervision over; 1 name disarmed.");
        assert_eq!(disarm_all_notice(4), "Handing supervision over; 4 names disarmed.");
    }

    /// An empty set is FORGOTTEN and not remembered as an empty telling, so a set that comes back
    /// - the navigator removing a `triage:declined` - is told as a change and not as a repeat.
    #[test]
    fn an_empty_set_is_forgotten_not_remembered() {
        let now = Utc::now();
        let mut ledger = TriageLedger::default();
        let ids = vec!["cb-1".to_string()];
        ledger.note_told("Cerebro", &ids, now);
        assert_eq!(ledger.told("Cerebro").map(|(ids, _)| ids.to_vec()), Some(ids.clone()));
        ledger.forget("Cerebro");
        assert!(ledger.told("Cerebro").is_none());
        // Forgetting a name that was never told is not an error.
        ledger.forget("Nobody");
    }

    /// `--readonly` is on every other `bd` this crate runs and must not be on this one: copying
    /// the neighbouring call would produce a command that appears to succeed and changes nothing.
    #[test]
    fn the_one_bd_that_writes_passes_no_readonly() {
        let dir = tempfile::tempdir().expect("a temp dir");
        let programs = Programs::default();
        let fake = FakeCommands::always("");
        run_finding(
            &paths_in(dir.path()),
            &programs,
            &fake,
            &Finding::Unassign { id: "cb-a".into(), priority: Some(0) },
        );
        assert_eq!(argv(&fake), vec!["update cb-a --assignee ", "dolt push"]);
        for call in fake.calls() {
            assert!(!call.program.display().to_string().contains("--readonly"), "{call:?}");
            for arg in &call.args {
                assert!(!arg.contains("--readonly"), "{call:?}");
            }
        }
    }


    // --- the priority keys (cb-kcs.5.4) --------------------------------------------------------

    /// `+` raises urgency by LOWERING the number, and `-` the reverse: `cerebro-beads-raise` is
    /// `nudged-priority current -1`. Both directions are named here because getting the sign
    /// backwards is a silent inversion every test written from the same misreading would agree
    /// with.
    #[test]
    fn a_priority_keystroke_decides_before_it_writes() {
        assert_eq!(nudged_priority(2, -1), 1, "+ is more urgent");
        assert_eq!(nudged_priority(2, 1), 3, "- is less urgent");
        assert_eq!(nudged_priority(0, -1), 0, "clamped at P0, never wrapped");
        assert_eq!(nudged_priority(PRIORITY_FLOOR, 1), PRIORITY_FLOOR, "and at the backlog floor");

        // A digit on a bead somewhere else writes.
        assert_eq!(
            priority_action("cb-x", Some(1), Requested::Exactly(0)),
            PriorityAction::Write { to: 0 }
        );
        // A digit on a bead already there does nothing, and must leave no undo entry claiming it
        // did.
        assert_eq!(
            priority_action("cb-x", Some(0), Requested::Exactly(0)),
            PriorityAction::AlreadyThere { text: "cb-x is already P0".into() }
        );
        // A digit on a bead `bd` gave no priority for is still a write: the number is absolute.
        assert_eq!(
            priority_action("cb-x", None, Requested::Exactly(3)),
            PriorityAction::Write { to: 3 }
        );

        // The two nudges, in both directions.
        assert_eq!(
            priority_action("cb-x", Some(2), Requested::Nudge(-1)),
            PriorityAction::Write { to: 1 }
        );
        assert_eq!(
            priority_action("cb-x", Some(2), Requested::Nudge(1)),
            PriorityAction::Write { to: 3 }
        );
        // `+` on a P0 and `-` on a P4 are already there.
        assert_eq!(
            priority_action("cb-x", Some(0), Requested::Nudge(-1)),
            PriorityAction::AlreadyThere { text: "cb-x is already P0".into() }
        );
        assert_eq!(
            priority_action("cb-x", Some(PRIORITY_FLOOR), Requested::Nudge(1)),
            PriorityAction::AlreadyThere { text: "cb-x is already P4".into() }
        );
        // A nudge on a bead with no priority has nothing to move, and says nothing: the board
        // always sets one, so this is unreachable in practice.
        assert_eq!(priority_action("cb-x", None, Requested::Nudge(-1)), PriorityAction::Nothing);
    }
}
