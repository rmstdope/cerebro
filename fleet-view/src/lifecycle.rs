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

use std::path::{Path, PathBuf};

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};

use crate::model::{AgentKind, FleetRow, RowState};
use crate::readers::{ReadError, ReaderPaths};
use crate::session::SessionHost;
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
    /// Spawn. `clears_flag` is true when a stale stop flag must be removed first, which is
    /// implementers only (`cerebro--start-clears-flag-p`): an implementer started under its own
    /// stop flag would be retired again at once.
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
    /// Put PROMPT in the notice slot in gold and wait for a keystroke.
    Confirm { prompt: String },
    Refuse(String),
    Ignore,
}

/// Is this row's agent running at all, as far as the fleet read can tell?
fn row_is_alive(row: &FleetRow) -> bool {
    !matches!(row.state, RowState::Dead | RowState::Invalid)
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
        clears_flag: situation.stop_flag && row.kind == AgentKind::Implementer,
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
    if !situation.hosted {
        return KillOutcome::Refuse(elsewhere_or_absent(row));
    }
    KillOutcome::Confirm { prompt: kill_prompt(row) }
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
    use crate::supervisor::ReadOnlyReason;

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

        // s: a dead implementer starts, and clears a stale flag only for an implementer.
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
            StartOutcome::Launch { clears_flag: false }
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
            KillOutcome::Confirm { prompt: "Kill Cyclops?  y / n".to_string() }
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
            KillOutcome::Confirm { prompt: "Kill Cyclops?  y / n".to_string() }
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
            KillOutcome::Confirm { prompt: "Kill Cyclops?  y / n".to_string() }
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
}
