//! Pure parsing and derivation, ported from `emacs/cerebro.el` behavior rather than its
//! representation:
//!
//! - roster order and kinds: `cerebro--parse-fleet` (`emacs/cerebro.el:117-129`)
//! - marker name/root matching, GNU/Linux escaped spaces, consumer isolation, wrapper
//!   collapse: `emacs/cerebro.el:153-319`
//! - tri-state pid liveness and state mapping: `emacs/cerebro.el:414-560`,
//!   `emacs/cerebro.el:3191-3253`
//! - bead buckets and their precedence/exclusions: `emacs/cerebro.el:4652-4764`
//!
//! Reader I/O lives in `crate::readers`; nothing here touches a file or a subprocess.
//!
//! Marker parser contract: subscribed to `tests/lib/session-args.cases` via
//! `scripts/marker-readers`, and pinned by the `session_marker_cases_match_all_rows` test below.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::Deserialize;

// --- Roster -----------------------------------------------------------------------------------

/// Whether a roster row is a role held by one interactive session, or an implementer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentKind {
    Interactive,
    Implementer,
}

/// One row of `scripts/roster`, in file order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RosterEntry {
    pub name: String,
    pub role: String,
    pub kind: AgentKind,
}

/// A failure to parse a whole roster or process-scan source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModelError {
    MalformedRoster { line: usize, message: String },
    MalformedProcess { line: usize, message: String },
}

impl std::fmt::Display for ModelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ModelError::MalformedRoster { line, message } => {
                write!(f, "malformed roster row at line {line}: {message}")
            }
            ModelError::MalformedProcess { line, message } => {
                write!(f, "malformed process row at line {line}: {message}")
            }
        }
    }
}

impl std::error::Error for ModelError {}

/// Parse `scripts/roster`'s output into roster entries, preserving order.
///
/// Blank lines are skipped. Any other row must be exactly `NAME<TAB>ROLE<TAB>KIND`, with KIND
/// one of `interactive`/`implementer` — a malformed row is an error, never a silent drop, so a
/// torn read or a roster typo cannot quietly shrink the fleet.
pub fn parse_roster(output: &str) -> Result<Vec<RosterEntry>, ModelError> {
    let mut rows = Vec::new();
    for (idx, line) in output.split('\n').enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() != 3 {
            return Err(ModelError::MalformedRoster {
                line: idx + 1,
                message: format!("expected NAME<TAB>ROLE<TAB>KIND, got: {line:?}"),
            });
        }
        let kind = match fields[2] {
            "interactive" => AgentKind::Interactive,
            "implementer" => AgentKind::Implementer,
            other => {
                return Err(ModelError::MalformedRoster {
                    line: idx + 1,
                    message: format!("unknown kind {other:?}, expected interactive or implementer"),
                })
            }
        };
        rows.push(RosterEntry {
            name: fields[0].to_string(),
            role: fields[1].to_string(),
            kind,
        });
    }
    Ok(rows)
}

// --- Process scan -------------------------------------------------------------------------------

/// One row of `ps -axo pid=,ppid=,args=`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessRow {
    pub pid: u32,
    pub ppid: Option<u32>,
    pub args: String,
}

/// Parse padded, headerless `ps -axo pid=,ppid=,args=` output.
///
/// Every field is right-justified and column-padded to the widest value across all rows, so a
/// naive single-space split rejects ordinary rows once any pid or ppid needs fewer digits than
/// its neighbour. This walks past the leading padding, the pid's digits, the whitespace run that
/// follows, and the ppid's digits (absent is possible - not every platform reports a ppid, and
/// `ProcessRow::ppid` reflects that), then takes the remainder verbatim as the command line -
/// preserving any internal padding it may itself contain, since that padding belongs to the
/// process's own argv rather than to the table.
pub fn parse_processes(output: &str) -> Result<Vec<ProcessRow>, ModelError> {
    let mut rows = Vec::new();
    for (idx, line) in output.split('\n').enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        match parse_process_line(line) {
            Some(row) => rows.push(row),
            None => {
                return Err(ModelError::MalformedProcess {
                    line: idx + 1,
                    message: format!("expected a leading pid, got: {line:?}"),
                })
            }
        }
    }
    Ok(rows)
}

fn parse_process_line(line: &str) -> Option<ProcessRow> {
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }
    let pid_start = i;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i == pid_start {
        return None;
    }
    let pid: u32 = line[pid_start..i].parse().ok()?;

    let sep_start = i;
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }
    if i == sep_start {
        // A pid with nothing after it at all - no ppid column, no args column.
        return Some(ProcessRow {
            pid,
            ppid: None,
            args: String::new(),
        });
    }

    let ppid_start = i;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    let ppid = if i > ppid_start {
        line[ppid_start..i].parse().ok()
    } else {
        None
    };

    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }

    Some(ProcessRow {
        pid,
        ppid,
        args: line[i..].to_string(),
    })
}

// --- Session marker -----------------------------------------------------------------------------

/// The tri-state answer to "is this one process cerebro's own marked session of NAME at ROOT?"
///
/// `emacs/cerebro.el:3191-3253` (`cerebro--session-liveness`) builds all three from the same
/// two-part test - does the field name this agent, and does it root the marker at this consumer:
///
/// - `Dead` — the field does not carry the marker naming this agent at all. Not proof of death,
///   only absence of evidence; a bare pid number is never trusted alone (a recycled pid can land
///   on someone else's process).
/// - `Unverified` — the field names this agent, but does not root the marker at this consumer's
///   own root (a wrapper can rewrite the discriminator away while leaving the agent's name
///   intact). There is no evidence against this being the session in question, only an absence of
///   proof beyond the name.
/// - `Proven` — the field names this agent AND roots the marker at this consumer. Exactly what
///   "alive" meant before the tri-state distinction existed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionLiveness {
    Proven,
    Unverified,
    Dead,
}

/// Display-only backslash-escaped spaces, folded back to plain spaces before any comparison.
///
/// GNU/Linux's `process-attributes` (and the `ps` output this crate reads instead) escape-quotes
/// the whitespace inside a single argv entry, so the very same session's marker reads
/// `This\ session\ is\ ...` there and `This session is ...` on macOS
/// (`emacs/cerebro.el:153-166`). Folding first means every needle below is spelled once, in its
/// plain form, rather than as a regex that has to know about the escape.
fn normalize_marker_spelling(field: &str) -> String {
    field.replace("\\ ", " ")
}

/// The needle naming NAME as this marker's agent: the sentence's opening, through the space after
/// "rooted at". Ending there (rather than at NAME alone) is what makes a name that is a prefix of
/// another (Cyclops / Cyclopsly) fail to match, the same guarantee the elisp reader's regexp
/// bought with the text that follows the name.
fn name_needle(name: &str) -> String {
    format!("This session is {name} of the cerebro fleet rooted at ")
}

/// The needle rooting the marker at ROOT: "cerebro fleet rooted at ROOT/", with ROOT normalized
/// to an absolute path carrying exactly one trailing slash, so `/repos/x` cannot match a sibling
/// checkout `/repos/x-hud` (`emacs/cerebro.el:220-260`).
fn root_needle(root: &Path) -> String {
    let canonical = root.to_string_lossy();
    let trimmed = canonical.trim_end_matches('/');
    format!("cerebro fleet rooted at {trimmed}/")
}

/// The whole marker sentence for NAME at ROOT, composed from the two needles above.
///
/// Test-only, and deliberately built rather than typed: `scripts/marker-readers` holds every file
/// that spells the sentence to being a declared reader, and this crate's one declared spelling is
/// the needles in this file. A fixture elsewhere in the crate asks for the sentence here instead
/// of writing a fourth copy of it.
#[cfg(test)]
pub(crate) fn marker_sentence(name: &str, root: &Path) -> String {
    format!(
        "{}{}/.",
        name_needle(name),
        root.to_string_lossy().trim_end_matches('/')
    )
}

/// Tri-state liveness for one process's command-line field as NAME's session of the fleet at
/// ROOT. `--name` alone is never evidence (a Claude Code flag, still passed, proves nothing); the
/// marker sentence `scripts/launch` opens every session's prompt with is the only proof.
pub fn session_liveness(args: &str, name: &str, root: &Path) -> SessionLiveness {
    let normalized = normalize_marker_spelling(args);
    if !normalized.contains(&name_needle(name)) {
        return SessionLiveness::Dead;
    }
    if normalized.contains(&root_needle(root)) {
        SessionLiveness::Proven
    } else {
        SessionLiveness::Unverified
    }
}

/// Every process in PROCESSES whose field is a `Proven` session of NAME at ROOT, collapsed to
/// leaves: a session is a process tree rather than a process (a launcher shim spawning the real
/// binary as its own child passes the whole argv down to both), so a process that is the parent
/// of another matched process is dropped, retaining only the leaf pid
/// (`cerebro--drop-wrappers`, `emacs/cerebro.el:270-300`).
fn live_leaf_pids(name: &str, root: &Path, processes: &[ProcessRow]) -> Vec<u32> {
    let matched: Vec<&ProcessRow> = processes
        .iter()
        .filter(|p| session_liveness(&p.args, name, root) == SessionLiveness::Proven)
        .collect();
    matched
        .iter()
        .filter(|p| !matched.iter().any(|q| q.ppid == Some(p.pid)))
        .map(|p| p.pid)
        .collect()
}

/// `pub` for `readers::read_sweep_snapshot`, which needs the answer for a row whose state file
/// did NOT parse: `derive_fleet` reports such a row as `Invalid` with no pid, and a sweep that
/// read that as "not running" would offer an `unclaim` against a working implementer - the exact
/// failure `cerebro--stalled-finding`'s membership test exists to prevent.
pub fn any_live(name: &str, root: &Path, processes: &[ProcessRow]) -> bool {
    processes
        .iter()
        .any(|p| session_liveness(&p.args, name, root) == SessionLiveness::Proven)
}

// --- State files ----------------------------------------------------------------------------

/// One agent's own `.cerebro/state/<name>.state.json`, deserialized.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct StateRecord {
    pub state: String,
    pub phase: Option<String>,
    pub bead: Option<String>,
    pub since: DateTime<Utc>,
    pub phase_since: Option<DateTime<Utc>>,
    pub pid: u32,
}

/// What was found reading one agent's state file.
///
/// `Missing` (no file — `NotFound`) is kept apart from `Invalid` (a file that exists but could
/// not be read or parsed) so that one bad state file produces one explicit invalid row rather
/// than being indistinguishable from an agent that has simply never run.
#[derive(Clone, Debug, PartialEq)]
pub enum StateObservation {
    Missing,
    Parsed(StateRecord),
    Invalid(String),
}

/// Per-agent state observations, keyed by name.
pub type StateInputs = BTreeMap<String, StateObservation>;

// --- Fleet rows -------------------------------------------------------------------------------

/// The state a fleet row is shown in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RowState {
    Working,
    Asking,
    Waiting,
    Idle,
    Up,
    Dead,
    /// No session, and a trigger will start one. Never a state file's word -
    /// `scripts/agent-state` refuses `standby` like any unknown word, and `row_state_for` must
    /// NOT learn it. The only producer is `apply_standby`, exactly as `cerebro--apply-standby`
    /// (`emacs/cerebro.el`) is the only producer in elisp and `cerebro--derive` never is: the
    /// state file was deleted when the view ended the session, so a name with no file and no
    /// process is what a derivation calls `Dead`, and only the armed set can say otherwise.
    Standby,
    Unknown(String),
    Invalid,
}

impl RowState {
    /// The state word itself. What the row shows, and what cb-kcs.4.4 logs.
    ///
    /// NOT `ui::state_label`, which substitutes an implementer's phase for `working`: this is the
    /// STATE, and the phase is a different fact with a column of its own. An `Unknown` contributes
    /// the raw word the file carried, which is the whole point of keeping it.
    pub fn word(&self) -> &str {
        match self {
            Self::Working => "working",
            Self::Asking => "asking",
            Self::Waiting => "waiting",
            Self::Idle => "idle",
            Self::Up => "up",
            Self::Dead => "dead",
            Self::Standby => "standby",
            Self::Invalid => "invalid",
            Self::Unknown(raw) => raw,
        }
    }
}

/// ROWS with every armed, dead row restated as `RowState::Standby`.
///
/// The port of `cerebro--apply-standby`. Pure, and run on the rows a successful fleet read
/// produced, before they reach the pane.
///
/// `armed` is `App::armed`. `failed` is `App::parked_names` - the names whose recorded exit has
/// something to say about the future: a refusal, and a give-up. A silent crash is NOT one of
/// them, and its row goes back to standby to be retried on the backoff (cb-ccl).
///
/// **It answers in both directions**, which is what makes it safe to run again over rows it has
/// already transformed: a `Standby` row whose name has left the armed set, or has since been
/// parked, is restated as `Dead`. `App::reapply_standby` needs exactly that - the fleet reader
/// never produces a `Standby` row, so this function is the only thing that can take one away
/// again, and a row promising a retry the view has just decided against is the one thing this
/// must never leave on the screen.
///
/// Emacs additionally excludes an `external` agent here. There is no counterpart and none is
/// needed: this only touches `RowState::Dead`, which already means no live process anywhere under
/// any name, so nothing external can reach it.
pub fn apply_standby(
    rows: Vec<FleetRow>,
    armed: &BTreeSet<String>,
    failed: &BTreeSet<String>,
) -> Vec<FleetRow> {
    rows.into_iter()
        .map(|mut row| {
            let standing_by = armed.contains(&row.name) && !failed.contains(&row.name);
            match row.state {
                RowState::Dead if standing_by => row.state = RowState::Standby,
                RowState::Standby if !standing_by => row.state = RowState::Dead,
                _ => {}
            }
            row
        })
        .collect()
}

/// One row of the fleet view.
#[derive(Clone, Debug, PartialEq)]
pub struct FleetRow {
    pub name: String,
    pub role: String,
    pub kind: AgentKind,
    pub state: RowState,
    pub phase: Option<String>,
    pub bead: Option<String>,
    pub since: Option<DateTime<Utc>>,
    pub phase_since: Option<DateTime<Utc>>,
    pub pid: Option<u32>,
    pub sessions: usize,
    pub diagnostic: Option<String>,
}

/// The raw `state` word, mapped to `RowState` — every string this fleet has ever written, and
/// `Unknown` for anything else, which must never read as `Idle` (`emacs/cerebro.el:414-449`: a
/// live process the view does not understand is worth the navigator's attention, not a green
/// "free, give it a bead").
fn row_state_for(raw: &str) -> RowState {
    match raw {
        "working" => RowState::Working,
        "asking" => RowState::Asking,
        "waiting" => RowState::Waiting,
        "idle" => RowState::Idle,
        other => RowState::Unknown(other.to_string()),
    }
}

/// Derive every roster entry's fleet row from its state observation and the process scan.
///
/// - `Invalid` state stays `RowState::Invalid` with its diagnostic kept, whether or not a live
///   process exists — malformed input must never look healthy.
/// - A `Parsed` record is trusted only while its own pid is `Proven` or `Unverified` (the latter
///   noted in `diagnostic`); a record whose pid reads `Dead` is stale: `Up` (dropping the stale
///   bead/phase) if a current same-name session exists, `Dead` otherwise.
/// - `Missing` state falls back to the process scan alone: `Up` if a current marker process
///   exists, `Dead` otherwise — for either `AgentKind`.
///
/// `sessions` is always the wrapper-collapsed leaf count for this name at this root, independent
/// of which branch above produced the row's state.
pub fn derive_fleet(
    roster: &[RosterEntry],
    states: &StateInputs,
    processes: &[ProcessRow],
    root: &Path,
) -> Vec<FleetRow> {
    roster
        .iter()
        .map(|entry| {
            let sessions = live_leaf_pids(&entry.name, root, processes).len();
            let live_here = any_live(&entry.name, root, processes);

            let (state, phase, bead, since, phase_since, pid, diagnostic) =
                match states.get(&entry.name) {
                    Some(StateObservation::Invalid(message)) => (
                        RowState::Invalid,
                        None,
                        None,
                        None,
                        None,
                        None,
                        Some(message.clone()),
                    ),
                    Some(StateObservation::Parsed(record)) => {
                        let liveness = pid_liveness(record.pid, &entry.name, root, processes);
                        match liveness {
                            SessionLiveness::Dead => {
                                if live_here {
                                    (RowState::Up, None, None, None, None, None, None)
                                } else {
                                    (RowState::Dead, None, None, None, None, None, None)
                                }
                            }
                            SessionLiveness::Proven => (
                                row_state_for(&record.state),
                                record.phase.clone(),
                                record.bead.clone(),
                                Some(record.since),
                                record.phase_since,
                                Some(record.pid),
                                None,
                            ),
                            SessionLiveness::Unverified => (
                                row_state_for(&record.state),
                                record.phase.clone(),
                                record.bead.clone(),
                                Some(record.since),
                                record.phase_since,
                                Some(record.pid),
                                Some(format!(
                                    "pid {} names {} but not this consumer's root; trusting the state file",
                                    record.pid, entry.name
                                )),
                            ),
                        }
                    }
                    Some(StateObservation::Missing) | None => {
                        if live_here {
                            (RowState::Up, None, None, None, None, None, None)
                        } else {
                            (RowState::Dead, None, None, None, None, None, None)
                        }
                    }
                };

            FleetRow {
                name: entry.name.clone(),
                role: entry.role.clone(),
                kind: entry.kind,
                state,
                phase,
                bead,
                since,
                phase_since,
                pid,
                sessions,
                diagnostic,
            }
        })
        .collect()
}

/// `session_liveness` for the process PID names, looked up in PROCESSES; `Dead` when no process
/// carries that pid at all (`emacs/cerebro.el:3191-3253`: no args to read is the same "no
/// evidence" answer as args that fail the marker test).
fn pid_liveness(pid: u32, name: &str, root: &Path, processes: &[ProcessRow]) -> SessionLiveness {
    match processes.iter().find(|p| p.pid == pid) {
        Some(process) => session_liveness(&process.args, name, root),
        None => SessionLiveness::Dead,
    }
}

// --- Beads ------------------------------------------------------------------------------------

/// One `bd` issue, as read by `readers::read_beads` (`--brief --json`,
/// `emacs/cerebro.el:4708-4764`). The JSON field is `issue_type`, not `type` — the live `bd`
/// shape, not the retired preserved-branch renaming.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Bead {
    pub id: String,
    pub title: String,
    pub status: String,
    pub issue_type: String,
    #[serde(default)]
    pub labels: Vec<String>,
    pub priority: Option<u8>,
    pub updated_at: Option<DateTime<Utc>>,
    pub assignee: Option<String>,
    #[serde(default)]
    pub metadata: serde_json::Value,
    /// `gh-<n>` for a bead filed from a GitHub issue, absent otherwise. `bd list --brief --json`
    /// OMITS the key rather than printing a null, so it defaults — without that, the whole work
    /// read fails on the first unlinked bead, which is every board
    /// (`emacs/cerebro.el:2253-2256`).
    #[serde(default)]
    pub external_ref: Option<String>,
}

impl Bead {
    /// This bead's `metadata.paused_at`, or `None`.
    ///
    /// Nil-safe both ways, exactly as `cerebro--paused-at` is: the key is absent rather than null
    /// on a bead parked before the pause sites started writing it, and a value that is not an
    /// RFC 3339 time is no time at all rather than a guess. The renderer shows the absence as an
    /// em dash, never as a small age.
    pub fn paused_at(&self) -> Option<DateTime<Utc>> {
        let raw = self.metadata.get("paused_at")?.as_str()?;
        DateTime::parse_from_rfc3339(raw)
            .ok()
            .map(|t| t.with_timezone(&Utc))
    }
}

/// The two long fields `bd list --brief` does not carry. Everything else the pane draws comes
/// from the `Bead` row the Work pane already holds, which is why the pane is never blank while
/// this is in flight.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct BeadDetailFields {
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub design: Option<String>,
}

/// `bd show <id> --json` answers with a ONE-ELEMENT ARRAY, never a bare object. Parsing it as an
/// object fails on every bead, which would read as "bd is broken" rather than as a mistake.
/// An empty array is an id `bd` does not know, and is an error rather than an empty detail.
pub fn parse_bead_detail(json: &[u8]) -> Result<BeadDetailFields, String> {
    let rows: Vec<BeadDetailFields> = serde_json::from_slice(json).map_err(|e| e.to_string())?;
    rows.into_iter()
        .next()
        .ok_or_else(|| "bd show answered with an empty array".to_string())
}

// --- GitHub, and the beads linked to it -------------------------------------------------------

/// A `serde` deserializer for an instant that may be absent, null or unreadable, all of which
/// are `None`.
///
/// Lenient on purpose: one undateable item must leave the other ninety-nine usable, which is what
/// `cerebro--gh-instant` (`emacs/cerebro.el:2197`) achieves by returning nil per item. A plain
/// `Option<DateTime<Utc>>` would fail the WHOLE parse on one bad string, which reads as a `gh`
/// that is down.
fn lenient_instant<'de, D>(d: D) -> Result<Option<DateTime<Utc>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    // Through `Value`, not through `Option<String>`: a failed `deserialize_string` has only
    // PEEKED the offending token, so swallowing its error leaves the parser sitting on a `{` and
    // the enclosing array fails - which is the whole-read failure this function exists to
    // prevent. A `Value` consumes whatever is there, and anything that is not a readable instant
    // is `None`.
    let value = serde_json::Value::deserialize(d)?;
    Ok(value.as_str().and_then(|raw| {
        DateTime::parse_from_rfc3339(raw)
            .ok()
            .map(|t| t.with_timezone(&Utc))
    }))
}

/// One open GitHub issue, as `gh issue list --json number,updatedAt` prints it.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct GhIssue {
    pub number: u64,
    #[serde(rename = "updatedAt", default, deserialize_with = "lenient_instant")]
    pub updated_at: Option<DateTime<Utc>>,
}

/// One open GitHub pull request, as `gh pr list --json number,author,isDraft,updatedAt` prints it.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct GhPull {
    pub number: u64,
    #[serde(rename = "updatedAt", default, deserialize_with = "lenient_instant")]
    pub updated_at: Option<DateTime<Utc>>,
    /// `gh` prints `isDraft`. A draft is nobody's to review yet.
    #[serde(rename = "isDraft", default)]
    pub is_draft: bool,
    /// `{"login": "..."}`, and `None` for a deleted account - `gh` prints the key with a null or
    /// an empty login there. Authorship is the whole of what makes a pull request Cypher's, so an
    /// author this crate cannot name is one it must not act on.
    #[serde(default)]
    pub author: Option<GhAuthor>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct GhAuthor {
    #[serde(default)]
    pub login: Option<String>,
}

/// One whole answer from `gh`: what is open, and who the navigator is.
///
/// The three `gh` calls are one snapshot rather than three, because every rule that reads it reads
/// at least two of them: `me` is what makes a pull request somebody else's.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GhSnapshot {
    pub issues: Vec<GhIssue>,
    pub prs: Vec<GhPull>,
    /// The navigator's own login, or `None` while `gh api user` has never answered. `None`
    /// excludes every pull request (see `triggers::gh_moved`), which is the safe direction.
    pub me: Option<String>,
}

/// A bead filed from a GitHub issue, with the moment the bead itself last moved.
///
/// The port of `cerebro--linked-beads` (`emacs/cerebro.el:2240`). What Moira is started for
/// besides an issue that moved: her other job is keeping each linked issue's status comments in
/// step with its bead - CREATED, PLANNED, CLAIMED, MERGED, VERIFIED - and every one of those
/// happens on the board, so the issue's own `updatedAt` does not move for it. Without this the
/// hourly floor was the only thing covering them, an hour late (cb-b4m).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkedBead {
    pub id: String,
    pub issue: u64,
    pub updated_at: DateTime<Utc>,
}

/// Every bead in BEADS carrying an `external_ref` of exactly `gh-<digits>` and a readable
/// `updated_at`, in the order BEADS came.
///
/// A bead whose `updated_at` does not parse is left out rather than guessed at, the same way
/// `gh_moved` leaves out an item it cannot date. The match is anchored at both ends
/// (`emacs/cerebro.el:2260` uses `\`gh-\([0-9]+\)\'`): `gh-12` is linked, `gh-12b` and
/// `jira-12` are not.
pub fn linked_beads(beads: &[Bead]) -> Vec<LinkedBead> {
    beads
        .iter()
        .filter_map(|bead| {
            let digits = bead.external_ref.as_deref()?.strip_prefix("gh-")?;
            if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            Some(LinkedBead {
                id: bead.id.clone(),
                issue: digits.parse().ok()?,
                updated_at: bead.updated_at?,
            })
        })
        .collect()
}

/// The panel's six sections, in the order `emacs/cerebro.el:4652-4764`
/// (`cerebro--partition-beads`) builds them; a bead's input order is preserved within its bucket.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WorkBuckets {
    pub claimed: Vec<Bead>,
    pub planned: Vec<Bead>,
    pub being_planned: Vec<Bead>,
    pub unplanned: Vec<Bead>,
    pub paused: Vec<Bead>,
    pub merged: Vec<Bead>,
    /// The beads linked to a GitHub issue, off the RAW list rather than out of the partition.
    ///
    /// Deliberately not a seventh bucket - nothing renders it. It travels with the buckets because
    /// it is derived from the same `bd` answer at the same moment, and Moira's trigger compares it
    /// against her own last pass. It must come off the raw list: a bead whose verification has
    /// settled appears in NO bucket, and a RELEASED comment is still owed on its issue.
    pub linked: Vec<LinkedBead>,
}

const SKIPPED_ISSUE_TYPES: [&str; 2] = ["epic", "event"];
const PAUSED_LABEL: &str = "human";
const PLANNED_LABEL: &str = "planned";
const PLANNING_LABEL: &str = "planning";
const SETTLED_LABELS: [&str; 2] = ["verification:passed", "verification:not-needed"];

fn is_holding_label(labels: &[String]) -> bool {
    let held_prefix = format!("{PLANNING_LABEL}:");
    labels.iter().any(|label| {
        label == PLANNING_LABEL
            || label
                .strip_prefix(&held_prefix)
                .is_some_and(|name| !name.is_empty() && !name.contains(':'))
    })
}

/// Split BEADS into the fleet panel's six buckets.
///
/// Exact precedence, matching `emacs/cerebro.el:4652-4764`: `epic` and `event` are skipped
/// outright; `in_progress` is always claimed; for `open`, `human` wins over exact `planned`,
/// exact `planned` wins over a hold (`planning` or `planning:<name>`), and anything else open is
/// unplanned; `closed` is merged unless it carries a settled verification label; every other
/// status (blocked, deferred, an unknown future status) appears in no bucket.
pub fn partition_beads(beads: Vec<Bead>) -> WorkBuckets {
    let mut buckets = WorkBuckets::default();
    buckets.linked = linked_beads(&beads);
    for bead in beads {
        if SKIPPED_ISSUE_TYPES.contains(&bead.issue_type.as_str()) {
            continue;
        }
        match bead.status.as_str() {
            "in_progress" => buckets.claimed.push(bead),
            "open" => {
                if bead.labels.iter().any(|l| l == PAUSED_LABEL) {
                    buckets.paused.push(bead);
                } else if bead.labels.iter().any(|l| l == PLANNED_LABEL) {
                    buckets.planned.push(bead);
                } else if is_holding_label(&bead.labels) {
                    buckets.being_planned.push(bead);
                } else {
                    buckets.unplanned.push(bead);
                }
            }
            "closed" => {
                if !bead
                    .labels
                    .iter()
                    .any(|l| SETTLED_LABELS.contains(&l.as_str()))
                {
                    buckets.merged.push(bead);
                }
            }
            _ => {}
        }
    }
    buckets
}

// --- History ----------------------------------------------------------------------------------

/// One `(agent, state)` row of `scripts/fleet-history --summary`. The four aggregates describe
/// FINISHED intervals; `open_min` is the interval running right now, or `None` when this agent is
/// not in this state at the moment.
///
/// Every numeric field is optional because the script emits `null` for a state nothing has
/// finished in — `median_min` and `max_min` especially, which is why neither may be a plain
/// `f64`. `PartialEq` and never `Eq`: `f64` is neither `Eq` nor `Ord`, so nothing here may be
/// sorted or put in a `BTreeSet`.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
pub struct HistoryRow {
    pub agent: String,
    pub state: String,
    #[serde(default)]
    pub count: i64,
    #[serde(default)]
    pub total_min: Option<f64>,
    #[serde(default)]
    pub median_min: Option<f64>,
    #[serde(default)]
    pub max_min: Option<f64>,
    #[serde(default)]
    pub open_min: Option<f64>,
}

/// How many times its own median an open interval must reach to be called long.
///
/// `cerebro-history-long-multiple`, a `const` here for `lifecycle::END_GRACE_SECONDS`' reason:
/// this crate has no place to declare a customisation and must not invent one.
///
/// Not one. An interval is past the median half the time by construction, so a mark that fired on
/// the median would fire on half of every ordinary day and stop meaning anything.
pub const HISTORY_LONG_MULTIPLE: f64 = 2.0;

/// This row's History line, and whether it is long — or `None` when the agent is not in this state
/// right now. The Rust `cerebro--history-row-line` (`emacs/cerebro.el:1181-1201`), and
/// byte-identical to it:
///
/// ```text
///   Cyclops working 2m
///   Psylocke asking 537m - long, median 2m
/// ```
///
/// A hyphen, not an em dash, and no leading `+`: the panel's own spelling.
///
/// A state nothing has finished in has no median and is never called long, however far it runs —
/// there is nothing to judge it against, and a first interval judged against itself would be
/// marked always or never depending on the arithmetic rather than on the fleet. A median of zero
/// is the same case: it is not a scale anything can be twice of.
///
/// The text and the flag rather than a styled line, because `ui.rs` owns colour and `model.rs`
/// owns words.
pub fn history_line(row: &HistoryRow) -> Option<(String, bool)> {
    let open = row.open_min?;
    let median = row.median_min.filter(|m| *m > 0.0);
    let long = median.is_some_and(|m| open >= HISTORY_LONG_MULTIPLE * m);
    let tail = if long {
        // `long` is only ever true when `median` is `Some`.
        format!(" - long, median {}m", median.unwrap_or(0.0).round() as i64)
    } else {
        String::new()
    };
    let text = format!(
        "  {} {} {}m{}",
        row.agent,
        row.state,
        open.round() as i64,
        tail
    );
    Some((text, long))
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::PathBuf;

    // --- roster --------------------------------------------------------------------------------

    #[test]
    fn parse_roster_preserves_order_and_kinds() {
        let out = "Cerebro\torchestrator\tinteractive\nCyclops\timplementer\timplementer\n";
        let rows = parse_roster(out).unwrap();
        assert_eq!(
            rows,
            vec![
                RosterEntry {
                    name: "Cerebro".into(),
                    role: "orchestrator".into(),
                    kind: AgentKind::Interactive,
                },
                RosterEntry {
                    name: "Cyclops".into(),
                    role: "implementer".into(),
                    kind: AgentKind::Implementer,
                },
            ]
        );
    }

    #[test]
    fn parse_roster_skips_blank_lines() {
        let out = "Cerebro\torchestrator\tinteractive\n\n\nXavier\tplanner\tinteractive\n";
        let rows = parse_roster(out).unwrap();
        assert_eq!(rows.len(), 2);
    }

    #[test]
    fn parse_roster_rejects_a_row_with_too_few_fields() {
        let err = parse_roster("Cerebro\torchestrator\n").unwrap_err();
        assert!(matches!(err, ModelError::MalformedRoster { line: 1, .. }));
    }

    #[test]
    fn parse_roster_rejects_an_unknown_kind() {
        let err = parse_roster("Cerebro\torchestrator\trobot\n").unwrap_err();
        assert!(matches!(err, ModelError::MalformedRoster { line: 1, .. }));
    }

    // --- session marker --------------------------------------------------------------------------

    struct SessionCase {
        alive: bool,
        name: String,
        root_token: String,
        field: String,
    }

    fn parse_session_args_cases() -> Vec<SessionCase> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/lib/session-args.cases");
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
            panic!("cannot read {path}: {e}");
        });
        let mut cases = Vec::new();
        for line in text.lines() {
            let trimmed = line.trim_start();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let fields = split_leading_fields(line, 4)
                .unwrap_or_else(|| panic!("session-args.cases: malformed row: {line}"));
            let alive = match fields[0] {
                "alive" => true,
                "dead" => false,
                other => panic!("session-args.cases: expected alive or dead, got {other}"),
            };
            cases.push(SessionCase {
                alive,
                name: fields[1].to_string(),
                root_token: fields[2].to_string(),
                field: fields[3].to_string(),
            });
        }
        cases
    }

    fn split_leading_fields(line: &str, n: usize) -> Option<Vec<&str>> {
        let mut rest = line;
        let mut fields = Vec::new();
        for _ in 0..n - 1 {
            rest = rest.trim_start_matches(|c: char| c.is_whitespace());
            let end = rest.find(|c: char| c.is_whitespace())?;
            fields.push(&rest[..end]);
            rest = &rest[end..];
        }
        rest = rest.trim_start_matches(|c: char| c.is_whitespace());
        fields.push(rest);
        Some(fields)
    }

    fn substitute(field: &str, root: &str, other: &str) -> String {
        field.replace("{root}", root).replace("{other}", other).replace("\\n", "\n")
    }

    // The table pins the strict, two-part `cerebro--session-args-p` (alive requires BOTH the name
    // and the root to match); `session_liveness` answers a tri-state instead, so this compares
    // `alive` against "proven" rather than against the enum directly - `Unverified` (name matches,
    // root does not) and `Dead` (name does not match) both count as "not alive" for this table's
    // purposes, and neither is asserted separately here.
    #[test]
    fn session_marker_cases_match_all_rows() {
        let root = PathBuf::from("/Users/x/repos/cerebro");
        let other = "/Users/x/repos/elsewhere";
        let cases = parse_session_args_cases();
        assert!(cases.iter().any(|c| c.alive), "table has no alive row");
        assert!(cases.iter().any(|c| !c.alive), "table has no dead row");
        for case in &cases {
            let root_str = root.to_string_lossy();
            let chosen_root = substitute(&case.root_token, &root_str, other);
            let field = substitute(&case.field, &root_str, other);
            let proven = session_liveness(&field, &case.name, Path::new(&chosen_root))
                == SessionLiveness::Proven;
            assert_eq!(
                proven, case.alive,
                "row expected {} for name={} root={} field={field:?}",
                if case.alive { "alive" } else { "dead" },
                case.name,
                chosen_root
            );
        }
    }

    #[test]
    fn session_marker_reads_gnu_linux_escaped_whitespace() {
        // process-attributes on GNU/Linux escape-quotes the whitespace inside one argv entry;
        // the very same session reads with backslash-spaces there and plain spaces on macOS
        // (emacs/cerebro.el:153-166). Both spellings must answer the same way.
        let escaped = concat!(
            "bash\\ /tmp/s.sh --name Rogue",
            " This\\ session\\ is\\ Rogue\\ of\\ the\\ cerebro\\",
            " fleet\\ rooted\\ at\\ /Users/x/repos/cerebro/.\\ This\\",
            " sentence\\ is\\ how\\ the\\ fleet\\ view\\ proves\\ it.",
        );
        let root = Path::new("/Users/x/repos/cerebro");
        assert_eq!(session_liveness(escaped, "Rogue", root), SessionLiveness::Proven);
        assert_eq!(session_liveness(escaped, "Beast", root), SessionLiveness::Dead);
        // A sibling root is never proof of THIS consumer's session - the escaping buys the name
        // needle nothing a plain reading would not also refuse for the root needle. It still
        // names "Rogue", so the tri-state correctly reads it as unverified rather than proven;
        // what must never happen is Proven.
        assert_ne!(
            session_liveness(escaped, "Rogue", Path::new("/Users/x/repos/cerebro-hud")),
            SessionLiveness::Proven
        );
    }

    #[test]
    fn session_marker_name_only_is_unverified_not_dead() {
        // A wrapper can rewrite the root discriminator away (--settings inlined) while leaving
        // the agent's own name intact - unverified rather than dead, so a caller trusts the
        // state file rather than discarding it outright (ah-ybsr).
        let args = "This session is Xavier of the cerebro fleet rooted at /elsewhere/.";
        assert_eq!(
            session_liveness(args, "Xavier", Path::new("/Users/x/repos/cerebro")),
            SessionLiveness::Unverified
        );
    }

    #[test]
    fn wrapper_processes_collapse_to_the_leaf() {
        let root = Path::new("/r");
        let field = "This session is A of the cerebro fleet rooted at /r/.";
        let processes = vec![
            ProcessRow { pid: 1, ppid: Some(0), args: field.to_string() },
            ProcessRow { pid: 2, ppid: Some(1), args: field.to_string() },
        ];
        assert_eq!(live_leaf_pids("A", root, &processes), vec![2]);
    }

    // --- process parsing -------------------------------------------------------------------------

    #[test]
    fn parse_processes_handles_padded_columns() {
        let out = "    1     0 /sbin/launchd\n  123     1 some prog --flag a  b\n";
        let rows = parse_processes(out).unwrap();
        assert_eq!(
            rows,
            vec![
                ProcessRow { pid: 1, ppid: Some(0), args: "/sbin/launchd".into() },
                ProcessRow { pid: 123, ppid: Some(1), args: "some prog --flag a  b".into() },
            ]
        );
    }

    #[test]
    fn parse_processes_rejects_a_line_with_no_leading_pid() {
        let err = parse_processes("not a process row\n").unwrap_err();
        assert!(matches!(err, ModelError::MalformedProcess { line: 1, .. }));
    }

    #[test]
    fn parse_processes_skips_blank_lines() {
        let out = "  1   0 a\n\n  2   1 b\n";
        assert_eq!(parse_processes(out).unwrap().len(), 2);
    }

    // --- state derivation ------------------------------------------------------------------------

    fn entry(name: &str, kind: AgentKind) -> RosterEntry {
        RosterEntry { name: name.into(), role: "role".into(), kind }
    }

    fn proven_field(name: &str, root: &str) -> String {
        format!("This session is {name} of the cerebro fleet rooted at {root}/.")
    }

    fn record(state: &str, pid: u32) -> StateRecord {
        StateRecord {
            state: state.into(),
            phase: Some("build".into()),
            bead: Some("cb-1".into()),
            since: "2026-01-01T00:00:00Z".parse().unwrap(),
            phase_since: Some("2026-01-01T00:00:00Z".parse().unwrap()),
            pid,
        }
    }

    #[test]
    fn derive_fleet_distinguishes_missing_invalid_stale_and_live_state() {
        let root = Path::new("/r");
        let roster = vec![
            entry("Proven", AgentKind::Interactive),
            entry("Unverified", AgentKind::Interactive),
            entry("StaleWithNewProcess", AgentKind::Implementer),
            entry("MissingWithLiveProcess", AgentKind::Implementer),
            entry("MissingDead", AgentKind::Interactive),
            entry("Invalid", AgentKind::Interactive),
            entry("UnknownState", AgentKind::Interactive),
        ];

        let mut states = StateInputs::new();
        states.insert("Proven".into(), StateObservation::Parsed(record("working", 10)));
        states.insert("Unverified".into(), StateObservation::Parsed(record("asking", 20)));
        // pid 30 is dead (not in the process list at all); a *different*, new pid (31) is live.
        states.insert(
            "StaleWithNewProcess".into(),
            StateObservation::Parsed(record("working", 30)),
        );
        states.insert("Invalid".into(), StateObservation::Invalid("torn JSON".into()));
        states.insert("UnknownState".into(), StateObservation::Parsed(record("confused", 60)));
        // MissingWithLiveProcess and MissingDead have no entry at all.

        let processes = vec![
            ProcessRow { pid: 10, ppid: None, args: proven_field("Proven", "/r") },
            // Unverified: names the agent, but roots the marker somewhere else entirely.
            ProcessRow {
                pid: 20,
                ppid: None,
                args: "This session is Unverified of the cerebro fleet rooted at /elsewhere/."
                    .into(),
            },
            ProcessRow { pid: 31, ppid: None, args: proven_field("StaleWithNewProcess", "/r") },
            ProcessRow {
                pid: 40,
                ppid: None,
                args: proven_field("MissingWithLiveProcess", "/r"),
            },
            ProcessRow { pid: 60, ppid: None, args: proven_field("UnknownState", "/r") },
        ];

        let rows = derive_fleet(&roster, &states, &processes, root);
        assert_eq!(rows.len(), roster.len(), "roster order must be preserved");
        assert_eq!(rows.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), vec![
            "Proven", "Unverified", "StaleWithNewProcess", "MissingWithLiveProcess",
            "MissingDead", "Invalid", "UnknownState",
        ]);

        let proven = &rows[0];
        assert_eq!(proven.state, RowState::Working);
        assert_eq!(proven.bead.as_deref(), Some("cb-1"));
        assert_eq!(proven.pid, Some(10));
        assert_eq!(proven.diagnostic, None);

        let unverified = &rows[1];
        assert_eq!(unverified.state, RowState::Asking);
        assert_eq!(unverified.bead.as_deref(), Some("cb-1"));
        assert!(unverified.diagnostic.is_some());

        let stale = &rows[2];
        assert_eq!(stale.state, RowState::Up);
        assert_eq!(stale.bead, None, "stale bead must not carry over");
        assert_eq!(stale.phase, None);

        let missing_live = &rows[3];
        assert_eq!(missing_live.state, RowState::Up);
        assert_eq!(missing_live.bead, None);

        let missing_dead = &rows[4];
        assert_eq!(missing_dead.state, RowState::Dead);

        let invalid = &rows[5];
        assert_eq!(invalid.state, RowState::Invalid);
        assert_eq!(invalid.diagnostic.as_deref(), Some("torn JSON"));

        let unknown = &rows[6];
        assert_eq!(unknown.state, RowState::Unknown("confused".into()));
    }

    #[test]
    fn derive_fleet_keeps_invalid_state_even_with_a_live_process() {
        // Malformed input must never look healthy, even when a live marker process exists.
        let root = Path::new("/r");
        let roster = vec![entry("Ghost", AgentKind::Interactive)];
        let mut states = StateInputs::new();
        states.insert("Ghost".into(), StateObservation::Invalid("bad json".into()));
        let processes = vec![ProcessRow { pid: 5, ppid: None, args: proven_field("Ghost", "/r") }];
        let rows = derive_fleet(&roster, &states, &processes, root);
        assert_eq!(rows[0].state, RowState::Invalid);
        assert_eq!(rows[0].diagnostic.as_deref(), Some("bad json"));
    }

    #[test]
    fn derive_fleet_counts_sessions_after_dropping_wrappers() {
        let root = Path::new("/r");
        let roster = vec![entry("A", AgentKind::Implementer)];
        let field = proven_field("A", "/r");
        let processes = vec![
            ProcessRow { pid: 1, ppid: Some(0), args: field.clone() },
            ProcessRow { pid: 2, ppid: Some(1), args: field.clone() },
            ProcessRow { pid: 3, ppid: Some(0), args: field },
        ];
        let rows = derive_fleet(&roster, &StateInputs::new(), &processes, root);
        assert_eq!(rows[0].sessions, 2, "one wrapped session plus one standalone session");
    }

    // --- bead partition --------------------------------------------------------------------------

    fn bead(id: &str, status: &str, issue_type: &str, labels: &[&str]) -> Bead {
        Bead {
            id: id.into(),
            title: format!("{id} title"),
            status: status.into(),
            issue_type: issue_type.into(),
            labels: labels.iter().map(|l| l.to_string()).collect(),
            priority: Some(1),
            updated_at: None,
            assignee: None,
            metadata: serde_json::Value::Null,
            external_ref: None,
        }
    }

    #[test]
    fn partition_beads_matches_every_existing_bucket_shape() {
        let beads = vec![
            bead("claimed-1", "in_progress", "feature", &["planned"]),
            bead("planned-1", "open", "feature", &["planned"]),
            bead("planning-bare", "open", "feature", &["planning"]),
            bead("planning-named", "open", "feature", &["planning:Xavier"]),
            bead("planning-empty", "open", "feature", &["planning:"]),
            bead("planning-double", "open", "feature", &["planning::Xavier"]),
            bead("near-miss-planner", "open", "feature", &["planner:Xavier"]),
            bead("unplanned-1", "open", "feature", &[]),
            bead("paused-over-planned", "open", "feature", &["human", "planned"]),
            bead("paused-over-planning", "open", "feature", &["human", "planning"]),
            bead("planned-over-planning", "open", "feature", &["planned", "planning"]),
            bead("merged-1", "closed", "feature", &[]),
            bead("settled-passed", "closed", "feature", &["verification:passed"]),
            bead("settled-not-needed", "closed", "feature", &["verification:not-needed"]),
            bead("skipped-epic", "open", "epic", &[]),
            bead("skipped-event", "closed", "event", &[]),
            bead("blocked-1", "blocked", "feature", &[]),
            bead("deferred-1", "deferred", "feature", &[]),
            bead("future-status", "on-hold-in-2030", "feature", &[]),
        ];
        let buckets = partition_beads(beads);

        assert_eq!(
            buckets.claimed.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["claimed-1"]
        );
        assert_eq!(
            buckets.planned.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["planned-1", "planned-over-planning"]
        );
        assert_eq!(
            buckets.being_planned.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["planning-bare", "planning-named"]
        );
        assert_eq!(
            buckets.unplanned.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec![
                "planning-empty",
                "planning-double",
                "near-miss-planner",
                "unplanned-1",
            ]
        );
        assert_eq!(
            buckets.paused.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["paused-over-planned", "paused-over-planning"]
        );
        assert_eq!(
            buckets.merged.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["merged-1"]
        );
    }

    #[test]
    fn partition_beads_preserves_order_within_a_bucket() {
        let beads = vec![
            bead("b", "open", "feature", &[]),
            bead("a", "open", "feature", &[]),
        ];
        let buckets = partition_beads(beads);
        assert_eq!(
            buckets.unplanned.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
            vec!["b", "a"]
        );
    }

    /// The paused section's age column comes from `metadata.paused_at`, and from nothing else. A
    /// bead parked before the pause sites wrote one has no age at all, which the panel shows as
    /// an em dash rather than as "just now".
    #[test]
    fn paused_at_is_read_from_metadata_or_absent() {
        let dated = Bead {
            metadata: serde_json::json!({ "paused_at": "2026-01-01T00:00:00Z" }),
            ..bead("dated", "open", "feature", &["human"])
        };
        assert_eq!(
            dated.paused_at(),
            Some(DateTime::parse_from_rfc3339("2026-01-01T00:00:00Z").unwrap().with_timezone(&Utc))
        );

        assert_eq!(bead("no-metadata", "open", "feature", &["human"]).paused_at(), None);
        for metadata in [
            serde_json::json!({}),
            serde_json::json!({ "paused_at": null }),
            serde_json::json!({ "paused_at": "yesterday" }),
            serde_json::json!({ "paused_at": 1767225600 }),
        ] {
            let bead = Bead { metadata, ..bead("odd", "open", "feature", &["human"]) };
            assert_eq!(bead.paused_at(), None, "an unusable value is no time at all");
        }
    }

    // --- standby -------------------------------------------------------------------------------

    fn standby_row(name: &str, state: RowState) -> FleetRow {
        FleetRow {
            name: name.into(),
            role: "planner".into(),
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

    #[test]
    fn a_standby_row_goes_back_to_dead_when_its_promise_is_withdrawn() {
        let rows = vec![
            standby_row("Xavier", RowState::Standby),
            standby_row("Beast", RowState::Standby),
            standby_row("Rogue", RowState::Standby),
        ];
        let armed: BTreeSet<String> = ["Beast", "Rogue"].into_iter().map(String::from).collect();
        let failed: BTreeSet<String> = ["Rogue"].into_iter().map(String::from).collect();
        let out = apply_standby(rows, &armed, &failed);
        let states: Vec<RowState> = out.iter().map(|r| r.state.clone()).collect();
        assert_eq!(
            states,
            vec![RowState::Dead, RowState::Standby, RowState::Dead],
            "disarmed and parked both take the promise away; the armed one keeps it"
        );
    }

    #[test]
    fn an_armed_dead_row_is_restated_as_standby() {
        let rows = vec![
            standby_row("Xavier", RowState::Dead),
            standby_row("Beast", RowState::Dead),
            standby_row("Rogue", RowState::Working),
            standby_row("Cerebro", RowState::Dead),
        ];
        let armed: BTreeSet<String> = ["Xavier", "Beast", "Rogue"]
            .into_iter()
            .map(String::from)
            .collect();
        // Beast's launch was refused: a row promising a trigger is coming would be untrue.
        let failed: BTreeSet<String> = ["Beast"].into_iter().map(String::from).collect();

        let out = apply_standby(rows, &armed, &failed);
        assert_eq!(out[0].state, RowState::Standby);
        assert_eq!(out[1].state, RowState::Dead);
        assert_eq!(out[2].state, RowState::Working);
        // Unarmed and dead stays dead.
        assert_eq!(out[3].state, RowState::Dead);
    }

    #[test]
    fn a_state_file_can_never_produce_standby() {
        assert_eq!(
            row_state_for("standby"),
            RowState::Unknown("standby".to_string())
        );
    }

    // --- linked beads and the `gh` shapes -------------------------------------------------------

    fn linkable(id: &str, external_ref: Option<&str>, updated_at: Option<&str>) -> Bead {
        Bead {
            id: id.into(),
            title: id.into(),
            status: "open".into(),
            issue_type: "task".into(),
            labels: Vec::new(),
            priority: Some(2),
            updated_at: updated_at
                .map(|raw| DateTime::parse_from_rfc3339(raw).unwrap().with_timezone(&Utc)),
            assignee: None,
            metadata: serde_json::Value::Null,
            external_ref: external_ref.map(str::to_string),
        }
    }

    #[test]
    fn a_bead_filed_from_an_issue_carries_its_number() {
        let beads = vec![
            linkable("cb-3qh", Some("gh-58"), Some("2026-09-01T10:00:00Z")),
            linkable("cb-und", Some("gh-58"), None),
            linkable("cb-suf", Some("gh-12b"), Some("2026-09-01T10:00:00Z")),
            linkable("cb-jra", Some("jira-9"), Some("2026-09-01T10:00:00Z")),
            linkable("cb-non", None, Some("2026-09-01T10:00:00Z")),
        ];
        let linked = linked_beads(&beads);
        assert_eq!(linked.len(), 1, "only an anchored gh-<digits> with a time counts");
        assert_eq!(linked[0].id, "cb-3qh");
        assert_eq!(linked[0].issue, 58);
    }

    #[test]
    fn an_unlinked_bead_parses_without_the_key() {
        let beads: Vec<Bead> = serde_json::from_str(
            r#"[{"id":"cb-1","title":"t","status":"open","issue_type":"task",
                 "priority":2,"updated_at":null,"assignee":null}]"#,
        )
        .expect("a null external_ref is omitted by bd, so the key must default");
        assert_eq!(beads[0].external_ref, None);
    }

    #[test]
    fn a_settled_bead_is_in_no_bucket_and_still_linked() {
        let mut settled = linkable("cb-3qh", Some("gh-58"), Some("2026-09-01T10:00:00Z"));
        settled.status = "closed".into();
        settled.labels = vec!["verification:passed".into()];
        let buckets = partition_beads(vec![settled]);
        assert!(buckets.merged.is_empty(), "a settled bead is in no bucket");
        assert_eq!(buckets.linked.len(), 1, "and a RELEASED comment is still owed on its issue");
    }

    #[test]
    fn an_item_gh_cannot_date_is_dropped_and_the_rest_survive() {
        let issues: Vec<GhIssue> = serde_json::from_str(
            r#"[{"number":212,"updatedAt":"2026-09-01T10:00:00Z"},
                {"number":213,"updatedAt":null},
                {"number":214,"updatedAt":"tomorrow"}]"#,
        )
        .expect("one undateable item must not fail the whole parse");
        assert_eq!(issues.len(), 3);
        assert!(issues[0].updated_at.is_some());
        assert_eq!(issues[1].updated_at, None);
        assert_eq!(issues[2].updated_at, None);

        // And a non-scalar, which is what a peeked-not-consumed token would have failed on.
        let issues: Vec<GhIssue> = serde_json::from_str(
            r#"[{"number":215,"updatedAt":{"at":"2026-09-01T10:00:00Z"}},
                {"number":216,"updatedAt":"2026-09-01T10:00:00Z"}]"#,
        )
        .expect("an updatedAt that is an object leaves the rest of the list usable");
        assert_eq!(issues[0].updated_at, None);
        assert!(issues[1].updated_at.is_some());
    }

    #[test]
    fn a_pull_request_by_a_deleted_account_has_no_login() {
        let prs: Vec<GhPull> = serde_json::from_str(
            r#"[{"number":244,"updatedAt":"2026-09-01T10:00:00Z","isDraft":false,
                 "author":{"login":"navigator"}},
                {"number":245,"updatedAt":"2026-09-01T10:00:00Z","isDraft":true,
                 "author":{"login":null}},
                {"number":246,"updatedAt":"2026-09-01T10:00:00Z","isDraft":false,"author":null}]"#,
        )
        .expect("a deleted account is a pull request gh still lists");
        assert_eq!(prs[0].author.as_ref().unwrap().login.as_deref(), Some("navigator"));
        assert!(prs[1].is_draft);
        assert_eq!(prs[1].author.as_ref().unwrap().login, None);
        assert_eq!(prs[2].author, None);
    }

    // --- history -------------------------------------------------------------------------------

    fn history_row(agent: &str, state: &str) -> HistoryRow {
        HistoryRow {
            agent: agent.to_string(),
            state: state.to_string(),
            ..HistoryRow::default()
        }
    }

    #[test]
    fn a_history_row_renders_only_when_something_is_running() {
        // Nothing running in this state: no line at all.
        let idle = HistoryRow {
            count: 4,
            total_min: Some(88.0),
            median_min: Some(21.9),
            max_min: Some(40.0),
            open_min: None,
            ..history_row("Cyclops", "working")
        };
        assert_eq!(history_line(&idle), None);

        // Running, and well inside its own median.
        let running = HistoryRow {
            median_min: Some(21.9),
            open_min: Some(2.4),
            ..history_row("Cyclops", "working")
        };
        assert_eq!(
            history_line(&running),
            Some(("  Cyclops working 2m".to_string(), false))
        );

        // Running far past twice its median: long, and the median is named.
        let long = HistoryRow {
            median_min: Some(2.2),
            open_min: Some(536.6),
            ..history_row("Psylocke", "asking")
        };
        assert_eq!(
            history_line(&long),
            Some((
                "  Psylocke asking 537m - long, median 2m".to_string(),
                true
            ))
        );

        // Exactly twice the median is long: the boundary is inclusive, as elisp's `>=` is.
        let boundary = HistoryRow {
            median_min: Some(10.0),
            open_min: Some(20.0),
            ..history_row("Beast", "plan")
        };
        assert_eq!(
            history_line(&boundary),
            Some(("  Beast plan 20m - long, median 10m".to_string(), true))
        );

        // A state nothing has finished in has no median, and is never long however far it runs.
        let no_median = HistoryRow {
            median_min: None,
            open_min: Some(9_000.0),
            ..history_row("Forge", "sweep")
        };
        assert_eq!(
            history_line(&no_median),
            Some(("  Forge sweep 9000m".to_string(), false))
        );

        // A zero median is not a scale anything can be twice of, and is the same case.
        let zero_median = HistoryRow {
            median_min: Some(0.0),
            open_min: Some(9_000.0),
            ..history_row("Forge", "sweep")
        };
        assert_eq!(
            history_line(&zero_median),
            Some(("  Forge sweep 9000m".to_string(), false))
        );
    }

    #[test]
    fn a_history_summary_row_parses_with_every_aggregate_null() {
        let rows: Vec<HistoryRow> = serde_json::from_str(
            r#"[{"agent":"Cyclops","state":"working","count":0,"total_min":null,
                 "median_min":null,"max_min":null,"open_min":3.5}]"#,
        )
        .unwrap();
        assert_eq!(
            rows,
            vec![HistoryRow {
                agent: "Cyclops".to_string(),
                state: "working".to_string(),
                count: 0,
                total_min: None,
                median_min: None,
                max_min: None,
                open_min: Some(3.5),
            }]
        );
    }

    #[test]
    fn a_bead_detail_is_parsed_from_a_one_element_array() {
        let parsed = parse_bead_detail(br#"[{"id":"cb-1","description":"d","design":"g"}]"#)
            .expect("a one-element array parses");
        assert_eq!(
            parsed,
            BeadDetailFields {
                description: Some("d".into()),
                design: Some("g".into()),
            }
        );
    }

    #[test]
    fn a_bead_detail_with_neither_field_parses() {
        let parsed = parse_bead_detail(br#"[{"id":"cb-1"}]"#).expect("omitted keys are None");
        assert_eq!(parsed, BeadDetailFields::default());
    }

    #[test]
    fn an_empty_array_is_an_error() {
        assert!(parse_bead_detail(b"[]").is_err());
    }
}
