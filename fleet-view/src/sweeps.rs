//! What the six sweeps decide, and every word the view says about a finding.
//!
//! The Rust half of `cerebro--sweeps` and its neighbours (`emacs/cerebro.el:1102-1169`,
//! `2681-3068`). Pure throughout: `readers::read_sweeps` runs the scripts and takes the fleet
//! snapshot, `lifecycle::run_finding` runs the command, and everything in between is here, over
//! plain data.
//!
//! Both implementations answer `tests/lib/sweep-findings.json`, because after the cutover both
//! views still sweep - the bead panel's board writes are outside the supervision lease - and two
//! implementations of one decision, in two languages, is precisely what that table exists for.

use std::path::Path;

use chrono::{DateTime, Utc};

/// One candidate as a sweep script emitted it. Every field of every one of the six shapes, all
/// optional, because a candidate carries only its own sweep's fields.
///
/// One struct rather than six, deliberately: the finders dispatch on the sweep, not on the type,
/// and six structs would need an enum around them whose only job is to be matched back apart.
#[derive(Clone, Debug, Default, PartialEq, serde::Deserialize)]
pub struct Candidate {
    pub id: String,
    #[serde(default)] pub title: Option<String>,
    #[serde(default)] pub assignee: Option<String>,
    #[serde(default)] pub priority: Option<i64>,
    #[serde(default)] pub verification_failed: Option<bool>,
    #[serde(default)] pub on_main: Option<bool>,
    #[serde(default)] pub commit_age_min: Option<i64>,
    #[serde(default)] pub docs_only: Option<bool>,
    #[serde(default)] pub lease_age_min: Option<i64>,
    #[serde(default)] pub minutes_since_last_child_closed: Option<i64>,
    #[serde(default)] pub progress_age_min: Option<i64>,
    #[serde(default)] pub progress_source: Option<String>,
    #[serde(default)] pub age_min: Option<i64>,
    #[serde(default)] pub verified_at: Option<String>,
    #[serde(default)] pub merges_since: Option<i64>,
    #[serde(default)] pub paused_at: Option<String>,
    #[serde(default)] pub ui_decision: Option<bool>,
    #[serde(default)] pub blockers: Vec<Blocker>,
}

/// One bead the paused sweep's candidate is waiting on.
#[derive(Clone, Debug, PartialEq, serde::Deserialize)]
pub struct Blocker {
    pub id: String,
    pub status: String,
    #[serde(default)] pub closed_age_min: Option<i64>,
}

/// What one live session is, for the finders that ask about the fleet.
///
/// The Rust `:live-states`/`:live-beads`/`:live-names` of `cerebro--fleet-snapshot`
/// (`emacs/cerebro.el:2978-2988`), as one list rather than three: they are three projections of
/// one read there, and keeping them apart here would let two of them disagree.
#[derive(Clone, Debug, PartialEq)]
pub struct LiveSession {
    pub name: String,
    /// The state file's own word, or `None` when the file parsed with no `state` key. **A live
    /// session with no state is still live** - `cerebro--stalled-finding` tests membership with
    /// `assoc` rather than by the state being non-nil, and a port that used `Option` truthiness
    /// would silently unclaim a bead from a session that is running.
    pub state: Option<String>,
    pub bead: Option<String>,
}

/// The fleet as it is at the moment the sweeps answered.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub live: Vec<LiveSession>,
    /// The roster's IMPLEMENTER names only - `cerebro--roster`'s own contents.
    /// `readers::read_roster` returns every agent, so the caller filters
    /// `AgentKind::Implementer`. Widening this to the whole roster would make `unassign` refuse
    /// to fire on any bead assigned to an interactive agent's name.
    pub implementers: Vec<String>,
    pub now: DateTime<Utc>,
}

impl Snapshot {
    fn live_named(&self, name: Option<&str>) -> Option<&LiveSession> {
        let name = name?;
        self.live.iter().find(|session| session.name == name)
    }
}

/// The one thing a sweep can offer. Seven shapes, and `finding_command` is the complete list of
/// destructive commands this view can run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Finding {
    Close { id: String, reason: String },
    Reclaim { id: String },
    EpicClose { id: String },
    Unclaim { id: String },
    Unassign { id: String, priority: Option<i64> },
    Recheck { id: String, priority: Option<i64> },
    Unpause { id: String, priority: Option<i64> },
}

impl Finding {
    /// The bead this finding is about.
    pub fn id(&self) -> &str {
        match self {
            Self::Close { id, .. }
            | Self::Reclaim { id }
            | Self::EpicClose { id }
            | Self::Unclaim { id }
            | Self::Unassign { id, .. }
            | Self::Recheck { id, .. }
            | Self::Unpause { id, .. } => id,
        }
    }

    /// The action word, for the key below and for a failure message.
    fn action(&self) -> &'static str {
        match self {
            Self::Close { .. } => "close",
            Self::Reclaim { .. } => "reclaim",
            Self::EpicClose { .. } => "epic-close",
            Self::Unclaim { .. } => "unclaim",
            Self::Unassign { .. } => "unassign",
            Self::Recheck { .. } => "recheck",
            Self::Unpause { .. } => "unpause",
        }
    }

    /// This finding's stable identity, `"<action>:<id>"` - what the Work cursor remembers.
    ///
    /// A key, never an index, for exactly `App::selected`'s reason: the findings are replaced
    /// wholesale every ten minutes and after every `x`, and an index would silently come to mean
    /// a different destructive command. The pair is unique: the claims sweep is the only one that
    /// yields two shapes, and it yields at most one per bead.
    pub fn key(&self) -> String {
        format!("{}:{}", self.action(), self.id())
    }

    /// True when this finding shouts - an `Unassign` or a `Recheck` whose bead is P0.
    ///
    /// `cerebro--sweep-line`'s rule (`emacs/cerebro.el:1140-1156`), and the whole of the
    /// escalation: the line is gold and nothing else happens.
    pub fn urgent(&self) -> bool {
        matches!(
            self,
            Self::Unassign { priority: Some(0), .. } | Self::Recheck { priority: Some(0), .. }
        )
    }
}

/// Minutes past which a claim's delivery, or an epic's last child close, is old enough to act on
/// rather than mid-cleanup. `cerebro-sweep-stale-minutes`.
///
/// A constant here and a defcustom there, exactly as `lifecycle::END_GRACE_SECONDS` is: this
/// crate has no customisation layer, and inventing a declaration for one is what `main.rs`
/// forbids in as many words.
const STALE_MINUTES: i64 = 10;

/// Minutes without progress past which a claim a live session holds is offered as stalled.
/// `cerebro-stalled-minutes`.
const STALLED_MINUTES: i64 = 60;

/// How long an open bead may carry an assignee no live session is on. `cerebro-stale-assignee-minutes`.
const STALE_ASSIGNEE_MINUTES: i64 = 10;

/// How many merges must land after a failed verdict's own commit. `cerebro-stale-verdict-merges`.
const STALE_VERDICT_MERGES: i64 = 1;

/// Which sweep a candidate came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sweep {
    Claims,
    Epics,
    Stalled,
    Assignees,
    Verdicts,
    Paused,
}

impl Sweep {
    /// The six, in run order - `cerebro--sweeps`' own order, which is the order findings appear in.
    pub const ALL: [Sweep; 6] = [
        Sweep::Claims,
        Sweep::Epics,
        Sweep::Stalled,
        Sweep::Assignees,
        Sweep::Verdicts,
        Sweep::Paused,
    ];

    /// `"sweep-claims"` - the key the JSON table uses and the name the header prints.
    pub fn key(self) -> &'static str {
        match self {
            Self::Claims => "sweep-claims",
            Self::Epics => "sweep-epics",
            Self::Stalled => "sweep-stalled",
            Self::Assignees => "sweep-assignees",
            Self::Verdicts => "sweep-verdicts",
            Self::Paused => "sweep-paused",
        }
    }

    /// `"sweep-claims.sh"` - the file under `scripts/`.
    pub fn script(self) -> String {
        format!("{}.sh", self.key())
    }

    /// The sweep this key names, or `None`.
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|sweep| sweep.key() == key)
    }

    /// What this sweep offers for CANDIDATE against SNAPSHOT, or `None` to leave it alone.
    pub fn judge(self, candidate: &Candidate, snapshot: &Snapshot) -> Option<Finding> {
        match self {
            Self::Claims => claim_finding(candidate, snapshot),
            Self::Epics => epic_finding(candidate),
            Self::Stalled => stalled_finding(candidate, snapshot),
            Self::Assignees => assignee_finding(candidate, snapshot),
            Self::Verdicts => verdict_finding(candidate),
            Self::Paused => paused_finding(candidate),
        }
    }
}

/// `cerebro--claim-finding`. The guards in order: a `verification:failed` label makes `on_main`
/// meaningless; a live session still holds it; the delivering commit is too fresh to be sure the
/// implementer has finished tidying up; or nothing is on main and the lease has not been expired
/// long enough to call the claim dead.
///
/// The last is not a detail: an assignee with no live session is exactly as often a claim held by
/// hand as one a crashed implementer left behind, and the lease is what tells them apart -
/// `bd reclaim --older-than 10m`'s own window, so a confirmed reclaim cannot be refused by `bd`.
fn claim_finding(candidate: &Candidate, snapshot: &Snapshot) -> Option<Finding> {
    if candidate.verification_failed == Some(true) {
        return None;
    }
    if snapshot.live_named(candidate.assignee.as_deref()).is_some() {
        return None;
    }
    if candidate.on_main == Some(true) {
        return match candidate.commit_age_min {
            Some(age) if age > STALE_MINUTES => Some(Finding::Close {
                id: candidate.id.clone(),
                reason: format!(
                    "Delivered in PR; closed by the fleet view, {} did not",
                    candidate.assignee.clone().unwrap_or_default()
                ),
            }),
            _ => None,
        };
    }
    match candidate.lease_age_min {
        Some(age) if age > STALE_MINUTES => Some(Finding::Reclaim { id: candidate.id.clone() }),
        _ => None,
    }
}

/// `cerebro--epic-finding`. The script has already established that every child is closed; the
/// only question left is staleness.
fn epic_finding(candidate: &Candidate) -> Option<Finding> {
    match candidate.minutes_since_last_child_closed {
        Some(minutes) if minutes > STALE_MINUTES => {
            Some(Finding::EpicClose { id: candidate.id.clone() })
        }
        _ => None,
    }
}

/// `cerebro--stalled-finding`. Nobody live holds it (the claims sweep's case), the session is
/// `asking` (already nudged), there is no age to judge, or the age is inside the threshold -
/// which includes every bead sitting in CI.
///
/// MEMBERSHIP decides liveness, not the state's truthiness: a live session whose state file
/// carries no `state` key reaches here with `None` and must still count as live, or a
/// half-written file becomes a finding against a working implementer.
fn stalled_finding(candidate: &Candidate, snapshot: &Snapshot) -> Option<Finding> {
    let session = snapshot.live_named(candidate.assignee.as_deref())?;
    if session.state.as_deref() == Some("asking") {
        return None;
    }
    match candidate.progress_age_min {
        Some(age) if age > STALLED_MINUTES => Some(Finding::Unclaim { id: candidate.id.clone() }),
        _ => None,
    }
}

/// `cerebro--assignee-finding`. The assignee is not a roster implementer, so it was assigned by
/// hand; a live session is on this very bead, so it is about to claim it; the bead was touched
/// inside the grace period; or there is no age to judge.
///
/// Note what is absent: there is no "the session is not alive" arm, because that case falls
/// through to the offer and should. A roster session that is not running cannot be about to
/// claim anything.
fn assignee_finding(candidate: &Candidate, snapshot: &Snapshot) -> Option<Finding> {
    let assignee = candidate.assignee.as_deref()?;
    if !snapshot.implementers.iter().any(|name| name == assignee) {
        return None;
    }
    if let Some(session) = snapshot.live_named(Some(assignee)) {
        if session.bead.as_deref() == Some(candidate.id.as_str()) {
            return None;
        }
    }
    match candidate.age_min {
        Some(age) if age >= STALE_ASSIGNEE_MINUTES => Some(Finding::Unassign {
            id: candidate.id.clone(),
            priority: candidate.priority,
        }),
        _ => None,
    }
}

/// `cerebro--verdict-finding`. No `verified_at`, so no verdict commit is known; `merges_since` is
/// absent, meaning the commit is not on the default branch and the distance is not a number; or
/// a known distance below the threshold.
fn verdict_finding(candidate: &Candidate) -> Option<Finding> {
    candidate.verified_at.as_ref()?;
    match candidate.merges_since {
        Some(merges) if merges >= STALE_VERDICT_MERGES => Some(Finding::Recheck {
            id: candidate.id.clone(),
            priority: candidate.priority,
        }),
        _ => None,
    }
}

/// `cerebro--paused-finding`. The one case the board can judge by itself: the bead was parked
/// behind blockers, and every one of them has closed.
///
/// Each `None` is a pause a person still owns. `needs-ui-decision` is waiting on an answer, not
/// on a dependency; no blockers at all means the reason is prose in the notes, which nothing here
/// reads; a blocker that is not closed is the pause still being true.
fn paused_finding(candidate: &Candidate) -> Option<Finding> {
    if candidate.ui_decision == Some(true) {
        return None;
    }
    if candidate.blockers.is_empty() {
        return None;
    }
    if candidate.blockers.iter().any(|b| b.status != "closed") {
        return None;
    }
    Some(Finding::Unpause { id: candidate.id.clone(), priority: candidate.priority })
}

/// Every finding from OUTPUTS, judged against SNAPSHOT, in `Sweep::ALL` order.
///
/// `cerebro--findings-from-snapshot`'s port. A sweep absent from OUTPUTS contributes nothing.
pub fn findings_from(outputs: &[(Sweep, Vec<Candidate>)], snapshot: &Snapshot) -> Vec<Finding> {
    let mut findings = Vec::new();
    for sweep in Sweep::ALL {
        for (key, candidates) in outputs {
            if *key != sweep {
                continue;
            }
            for candidate in candidates {
                if let Some(finding) = sweep.judge(candidate, snapshot) {
                    findings.push(finding);
                }
            }
        }
    }
    findings
}

/// MINUTES as `12m`, `2h` or `3d`; `recently` when it is unknown. `cerebro--age-in-words`.
fn age_in_words(minutes: Option<i64>) -> String {
    match minutes {
        None => "recently".to_string(),
        Some(m) if m < 60 => format!("{m}m"),
        Some(m) if m < 1440 => format!("{}h", m / 60),
        Some(m) => format!("{}d", m / 1440),
    }
}

/// The Sweeps line for FINDING, built from the CANDIDATE it was judged from and the SNAPSHOT that
/// judged it.
///
/// `cerebro--sweep-label`'s port, including `cerebro--paused-label` and `cerebro--age-in-words`.
/// It takes the candidate because four of the seven arms print evidence the finding does not
/// carry, and the snapshot for the one arm whose evidence the SCRIPT cannot know: what the
/// assignee is actually on, which is `cerebro--assignee-enrich`'s whole job there.
pub fn label(finding: &Finding, candidate: &Candidate, snapshot: &Snapshot) -> String {
    let assignee = candidate.assignee.clone().unwrap_or_default();
    match finding {
        Finding::Close { id, .. } => format!(
            "close {id} — delivered by {assignee}, on main {}m",
            candidate.commit_age_min.map(|m| m.to_string()).unwrap_or_else(|| "?".into())
        ),
        Finding::Reclaim { id } => format!("reclaim {id} — {assignee} gone, not on main"),
        Finding::EpicClose { id } => format!(
            "close {id} — all children closed {}m ago",
            candidate
                .minutes_since_last_child_closed
                .map(|m| m.to_string())
                .unwrap_or_else(|| "nil".into())
        ),
        Finding::Unclaim { id } => format!(
            "unclaim {id} — {assignee} stalled, no {} for {}m",
            if candidate.progress_source.as_deref() == Some("commit") { "commit" } else { "start" },
            candidate.progress_age_min.map(|m| m.to_string()).unwrap_or_else(|| "nil".into())
        ),
        Finding::Unassign { id, .. } => {
            let doing = match snapshot
                .live_named(candidate.assignee.as_deref())
                .and_then(|session| session.bead.clone())
            {
                Some(bead) => format!("on {bead}"),
                None => "not running".to_string(),
            };
            format!("unassign {id} — {assignee} is {doing}")
        }
        // The short sha, as every other line in the fleet view uses - the full one lives in the
        // bead's `verified_at`, where `git merge-base` reads it, and a person reads this.
        Finding::Recheck { id, .. } => {
            let verified = candidate.verified_at.clone().unwrap_or_default();
            let short: String = verified.chars().take(8).collect();
            let merges = candidate.merges_since.unwrap_or_default();
            format!(
                "recheck {id} — verdict at {short}, {merges} merge{} since",
                if merges == 1 { "" } else { "s" }
            )
        }
        Finding::Unpause { id, .. } => paused_label(id, &candidate.blockers),
    }
}

/// `cerebro--paused-label`. One blocker is the ordinary case and gets the line the navigator
/// chose; more than one names the count and the most recent close, rather than a list that would
/// not fit the column.
fn paused_label(id: &str, blockers: &[Blocker]) -> String {
    let last_close = blockers.iter().filter_map(|b| b.closed_age_min).min();
    if blockers.len() == 1 {
        format!(
            "unpause {id} — waiting on {}, closed {} ago",
            blockers[0].id,
            age_in_words(last_close)
        )
    } else {
        format!(
            "unpause {id} — waiting on {} beads, all closed, last {} ago",
            blockers.len(),
            age_in_words(last_close)
        )
    }
}

/// The label the paused sweep's `unpause` command does not say on its face: where the bead goes.
/// `cerebro--finding-explanation`, whose other six arms are `None` for the reason it gives -
/// `bd close`, `bd unclaim` and `bd reclaim` each say their own consequence.
fn explanation(finding: &Finding) -> Option<String> {
    match finding {
        Finding::Unpause { id, .. } => {
            Some(format!("unpause {id} — it goes back to the planners for a re-read."))
        }
        _ => None,
    }
}

/// The exact argv for FINDING, with PROGRAM as argv[0].
///
/// `cerebro--finding-command`'s port and, like it, **the complete list of destructive commands
/// this view can run**. A total function over the seven shapes: there is no fallthrough arm and
/// there must never be one.
pub fn finding_command(finding: &Finding, program: &Path) -> Vec<String> {
    let bd = program.display().to_string();
    match finding {
        Finding::Close { id, reason } => {
            vec![bd, "close".into(), id.clone(), "--reason".into(), reason.clone()]
        }
        Finding::Reclaim { id } => vec![
            bd,
            "reclaim".into(),
            "--id".into(),
            id.clone(),
            "--older-than".into(),
            "10m".into(),
        ],
        Finding::EpicClose { id } => vec![bd, "close".into(), id.clone()],
        // `bd unclaim`, not `bd reclaim --older-than`: reclaim is for a claim whose session is
        // gone, and its window would refuse a bead whose lease is still being heartbeated. This
        // finding is about a session alive and not moving.
        Finding::Unclaim { id } => vec![bd, "unclaim".into(), id.clone()],
        // Clearing the field, not touching the status: the bead is already `open` and holds no
        // lease, so there is nothing to unclaim or reclaim.
        Finding::Unassign { id, .. } => {
            vec![bd, "update".into(), id.clone(), "--assignee".into(), String::new()]
        }
        // `verdict` is a dimension of its own, deliberately: `verification` is a bd state
        // dimension and `bd set-state` replaces the whole of it, so `verification=stale` would
        // erase the verdict this line exists to preserve.
        Finding::Recheck { id, .. } => vec![
            bd,
            "set-state".into(),
            id.clone(),
            "verdict=stale".into(),
            "--reason".into(),
            "verdict formed against a commit main has moved past".into(),
        ],
        // One label removed, and nothing else. Deliberately not `--add-label planned` with it:
        // that puts the bead straight in front of an implementer, which loops when the pause was
        // not really about the blocker.
        Finding::Unpause { id, .. } => {
            vec![bd, "update".into(), id.clone(), "--remove-label".into(), "human".into()]
        }
    }
}

/// The gold header line that asks for FINDING.
///
/// Six of the seven echo the command, which says its own consequence; `unpause` says the
/// consequence instead, because removing a label does not say where the bead then goes and the
/// command would be cut on the terminal where it is needed (round three of the interview).
pub fn prompt(finding: &Finding, program: &Path) -> String {
    match explanation(finding) {
        Some(text) => format!("{text}  y / n"),
        None => format!("run {} ?  y / n", finding_command(finding, program).join(" ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[derive(serde::Deserialize)]
    struct Row {
        #[serde(default)] name: String,
        #[serde(default)] sweep: String,
        #[serde(default)] candidate: Candidate,
        #[serde(default)] snapshot: RowSnapshot,
        #[serde(default)] finding: Option<Vec<serde_json::Value>>,
        #[serde(default)] label: Option<String>,
        #[serde(default)] command: Option<Vec<String>>,
        #[serde(default)] prompt: Option<String>,
    }

    #[derive(Default, serde::Deserialize)]
    struct RowSnapshot {
        #[serde(default)] live: Vec<(String, Option<String>, Option<String>)>,
        #[serde(default)] implementers: Vec<String>,
        #[serde(default)] now: Option<DateTime<Utc>>,
    }

    fn rows() -> Vec<Row> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/lib/sweep-findings.json");
        let text = std::fs::read_to_string(path)
            .unwrap_or_else(|e| panic!("sweep-findings.json: {e}"));
        let values: Vec<serde_json::Value> =
            serde_json::from_str(&text).expect("sweep-findings.json is a JSON array");
        values
            .into_iter()
            // An element carrying `_` is the file's own comment - JSON has none.
            .filter(|value| value.get("_").is_none())
            .map(|value| serde_json::from_value(value).expect("a well-formed row"))
            .collect()
    }

    /// The table's `finding` array as a `Finding`, or `None` for "leave it alone".
    fn expected_finding(finding: &Option<Vec<serde_json::Value>>) -> Option<Finding> {
        let parts = finding.as_ref()?;
        let head = parts[0].as_str().expect("an action word");
        let id = parts[1].as_str().expect("a bead id").to_string();
        let priority = parts.get(2).and_then(serde_json::Value::as_i64);
        Some(match head {
            "close" => Finding::Close {
                id,
                reason: parts[2].as_str().expect("a reason").to_string(),
            },
            "reclaim" => Finding::Reclaim { id },
            "epic-close" => Finding::EpicClose { id },
            "unclaim" => Finding::Unclaim { id },
            "unassign" => Finding::Unassign { id, priority },
            "recheck" => Finding::Recheck { id, priority },
            "unpause" => Finding::Unpause { id, priority },
            other => panic!("sweep-findings.json: unknown finding head {other}"),
        })
    }

    /// The shared table, row by row: the finding each sweep offers, the line the Sweeps section
    /// shows for it, the exact argv behind it, and the header's own question.
    ///
    /// `emacs/cerebro-test.el`'s `the-sweep-table-is-answered-by-the-finders` answers the same
    /// rows, minus `prompt` - the header wording is this view's alone.
    #[test]
    fn the_shared_table_is_answered() {
        let rows = rows();
        assert!(rows.len() > 30, "the table lost its rows: {}", rows.len());
        let mut heads = BTreeSet::new();
        for row in &rows {
            let sweep = Sweep::from_key(&row.sweep)
                .unwrap_or_else(|| panic!("{}: unknown sweep {}", row.name, row.sweep));
            let snapshot = Snapshot {
                live: row
                    .snapshot
                    .live
                    .iter()
                    .map(|(name, state, bead)| LiveSession {
                        name: name.clone(),
                        state: state.clone(),
                        bead: bead.clone(),
                    })
                    .collect(),
                implementers: row.snapshot.implementers.clone(),
                now: row.snapshot.now.expect("every row carries a clock"),
            };
            let expected = expected_finding(&row.finding);
            let found = sweep.judge(&row.candidate, &snapshot);
            assert_eq!(found, expected, "{}", row.name);
            let Some(finding) = found else {
                assert!(row.label.is_none(), "{}: a nil row carries no label", row.name);
                continue;
            };
            heads.insert(finding.key().split(':').next().unwrap().to_string());
            assert_eq!(
                label(&finding, &row.candidate, &snapshot),
                row.label.clone().expect("a label"),
                "{}",
                row.name
            );
            assert_eq!(
                finding_command(&finding, Path::new("bd")),
                row.command.clone().expect("a command"),
                "{}",
                row.name
            );
            assert_eq!(
                prompt(&finding, Path::new("bd")),
                row.prompt.clone().expect("a prompt"),
                "{}",
                row.name
            );
        }
        assert_eq!(heads.len(), 7, "every finding head is exercised: {heads:?}");
    }

    /// This function is the complete list of destructive commands this view can run, so its whole
    /// range is pinned rather than its happy path. There is no fallthrough arm to test, which is
    /// the point: a new variant will not compile until it has a command.
    #[test]
    fn finding_command_is_total_over_the_seven_shapes() {
        let bd = Path::new("/usr/local/bin/bd");
        let all = [
            Finding::Close { id: "a".into(), reason: "r".into() },
            Finding::Reclaim { id: "a".into() },
            Finding::EpicClose { id: "a".into() },
            Finding::Unclaim { id: "a".into() },
            Finding::Unassign { id: "a".into(), priority: Some(0) },
            Finding::Recheck { id: "a".into(), priority: Some(0) },
            Finding::Unpause { id: "a".into(), priority: Some(0) },
        ];
        for finding in &all {
            let argv = finding_command(finding, bd);
            // The program is the caller's, never the literal `bd`: `Programs::bd` is injectable
            // precisely so a test never touches the developer's own board.
            assert_eq!(argv[0], "/usr/local/bin/bd");
            assert!(argv.len() >= 2, "{finding:?}");
        }
    }

    #[test]
    fn a_finding_key_is_the_action_and_the_bead() {
        assert_eq!(Finding::Reclaim { id: "cb-a".into() }.key(), "reclaim:cb-a");
        assert_eq!(
            Finding::Close { id: "cb-a".into(), reason: "r".into() }.key(),
            "close:cb-a"
        );
        // The claims sweep is the only one that yields two shapes for one bead, and it yields at
        // most one - so the pair is unique across a whole findings list.
        assert_ne!(
            Finding::Close { id: "cb-a".into(), reason: "r".into() }.key(),
            Finding::Reclaim { id: "cb-a".into() }.key()
        );
    }

    /// Only a P0 `unassign` or `recheck` shouts. Everything else - including a P0 close - is an
    /// ordinary line.
    #[test]
    fn a_stranded_p0_is_the_whole_of_the_escalation() {
        assert!(Finding::Unassign { id: "a".into(), priority: Some(0) }.urgent());
        assert!(Finding::Recheck { id: "a".into(), priority: Some(0) }.urgent());
        assert!(!Finding::Unassign { id: "a".into(), priority: Some(2) }.urgent());
        assert!(!Finding::Unassign { id: "a".into(), priority: None }.urgent());
        assert!(!Finding::Unclaim { id: "a".into() }.urgent());
        assert!(!Finding::Close { id: "a".into(), reason: "r".into() }.urgent());
    }

    /// Run order is `Sweep::ALL`'s, whatever order the outputs arrive in, and a sweep absent from
    /// the outputs contributes nothing.
    #[test]
    fn findings_are_returned_in_sweep_order() {
        let now = DateTime::from_timestamp(1_767_225_600, 0).expect("a valid timestamp");
        let snapshot = Snapshot { live: Vec::new(), implementers: Vec::new(), now };
        let epic = Candidate {
            id: "cb-e".into(),
            minutes_since_last_child_closed: Some(30),
            ..Candidate::default()
        };
        let claim = Candidate {
            id: "cb-c".into(),
            assignee: Some("Storm".into()),
            on_main: Some(false),
            lease_age_min: Some(30),
            ..Candidate::default()
        };
        let findings = findings_from(
            &[(Sweep::Epics, vec![epic]), (Sweep::Claims, vec![claim])],
            &snapshot,
        );
        assert_eq!(
            findings,
            vec![
                Finding::Reclaim { id: "cb-c".into() },
                Finding::EpicClose { id: "cb-e".into() },
            ]
        );
    }
}
