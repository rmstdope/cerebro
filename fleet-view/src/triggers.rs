//! Whether a role is due to be started, and what to say about it.
//!
//! Pure throughout: it reads no file, runs no program and asks no clock, exactly as `ui` does, so
//! its tests are literals. It is a module of its own rather than part of `lifecycle` because that
//! module's contract is "everything this crate *writes*" and this one writes nothing.


use std::collections::BTreeMap;

use chrono::{DateTime, Utc};

use crate::model::{
    AgentKind, Candidate, FleetRow, GhSnapshot, LinkedBead, RolePolicy, RosterEntry, WorkBuckets,
};

#[cfg(test)]
use crate::model::{GhAuthor, GhIssue, GhPull};

/// `cerebro-wake-interval-default`: seconds a role is left alone between two STARTS of it, when
/// nothing more specific is declared.
pub const WAKE_INTERVAL_DEFAULT: i64 = 600;

/// `cerebro-planner-buffer-floor`. The shell owner of the whole rule is `scripts/planner-buffer`;
/// this is a third copy for the same reason the elisp one exists - the trigger runs once per
/// standby row per five-second tick and may not fork.
pub const PLANNER_BUFFER_FLOOR: usize = 2;

/// The project.conf key that scales the planner buffer (cb-3in). The shell copy is
/// `scripts/planner-buffer --print-multiple-key`; the elisp copy is
/// `cerebro--planner-multiple-key`. ABSENT means 1 - the rule every consumer had before the key
/// existed.
pub const PLANNER_MULTIPLE_KEY: &str = "planner_buffer_multiple";

/// RAW as a buffer multiple: `Ok(None)` for a project that declares none, `Ok(Some(n))` for a
/// whole number above zero, `Err(raw)` for anything else - zero included, since a zero taken at
/// face value would pin `planner_want` to the floor for ever.
pub fn parse_planner_multiple(raw: &str) -> Result<Option<usize>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    match trimmed.parse::<usize>() {
        Ok(n) if n > 0 => Ok(Some(n)),
        _ => Err(trimmed.to_string()),
    }
}

/// `cerebro-parked-labels`: a bead wearing one of these is the navigator's rather than a
/// planner's, and counting it starts a session to find nothing to do.
pub const PARKED_LABELS: [&str; 2] = ["human", "triage:declined"];

/// The label that parks a bead in front of the verifier (`cerebro--stale-verdict-p`).
pub const STALE_VERDICT_LABEL: &str = "verdict:stale";

/// `cerebro-cadence-triggers` (`emacs/cerebro.el:1717`): seconds after which a role on standby is
/// started again whatever else is true, or `None` for a role with no floor.
///
/// Moira and Cypher hourly, because what they watch moves outside this fleet and a floor covers
/// what no timestamp this view reads can show - a RELEASED comment, which follows a git tag rather
/// than an issue or a bead, and a `gh` reader that failed or has never answered. It is a floor and
/// NOT the trigger: both of Moira's conditions answer within a tick. Forge hourly too: its
/// watermark makes a sweep with nothing new in it nearly free, and an hourly floor keeps a day's
/// debt from arriving in one lump.
///
/// The four roles cb-kcs.4.1 armed have no floor, deliberately: their conditions are true whenever
/// there is work, so a floor would only start them with nothing to do.
pub fn cadence(role: &str) -> Option<i64> {
    match role {
        "user-feedback" | "reviewer" | "architect" => Some(3600),
        _ => None,
    }
}

/// SECONDS as the figure a cadence reason names: `"60m"`, `"24h"`.
///
/// Minutes under a day and hours at or over one (`cerebro--cadence-figure`,
/// `emacs/cerebro.el:1739`), which is what makes an hourly cadence read as "60m since its last
/// pass" rather than "1h": the point of the line is how long the role has been down, and an hour
/// of it is still counted in minutes by anyone reading the fleet.
pub fn cadence_figure(seconds: i64) -> String {
    if seconds < 86_400 {
        format!("{}m", seconds / 60)
    } else {
        format!("{}h", seconds / 3600)
    }
}

/// What ROLE calls the thing it does once per cadence: `"sweep"` for `architect`, `"pass"` for
/// everything else (`cerebro--cadence-noun`, `emacs/cerebro.el:1750`).
pub fn cadence_noun(role: &str) -> &'static str {
    if role == "architect" { "sweep" } else { "pass" }
}

/// LEFT seconds as the BEAD cell of a row counting down, verbatim from
/// `docs/ui/cb-kcs.4.3-cadence-rows.html` section 1:
///
///     → 43m        under an hour
///     → 21h04      an hour or more, as hours and zero-padded minutes
///     → due        the moment has passed and the start has not happened yet
///
/// U+2192, **a space**, then the figure. That space is this view's own and is not
/// `cerebro--countdown`'s (`emacs/cerebro.el:760`), which writes `→43m`: the navigator chose one
/// spacing rule for the whole BEAD column, so this cell sits under `→ buffer<4` and reads as the
/// same kind of thing. The two views deliberately differ here.
///
/// `→ due` rather than `→ 0m` for a deadline already past: between falling due and the next tick
/// acting on it there is a real, visible moment, and counting downwards through zero would show a
/// negative or a lie.
pub fn countdown(left: i64) -> String {
    if left <= 0 {
        return "→ due".to_string();
    }
    let minutes = left / 60;
    if minutes < 60 {
        format!("→ {minutes}m")
    } else {
        format!("→ {}h{:02}", minutes / 60, minutes % 60)
    }
}

/// What the `gh` reader has to say, as a trigger sees it.
///
/// Three answers and not two, because the row says something different for the middle one. It is
/// built by `App::gh_answer` from `Pane<GhSnapshot>`, whose four content states map onto these
/// exactly: `Loading` is `Unanswered`, `Fresh` is `Answered`, and BOTH `Stale` (a value, and a
/// newer failure) and `Unavailable` (a failure and no value) are `Failed`. That mapping is the
/// whole of `cerebro--gh-resolver`'s stamp comparison (`emacs/cerebro.el:5843-5862`) - "the last
/// good answer stands until a newer one replaces it, and it is the ORDER of the two that says
/// whether what the trigger has is current" - said by a type this crate already has.
#[derive(Clone, Debug, PartialEq)]
pub enum GhAnswer {
    Unanswered,
    Failed,
    Answered(GhSnapshot),
}

/// The open issues, and the open non-draft pull requests by an author other than `snapshot.me`,
/// whose `updated_at` is after ENDED_AT. Numbers in the order `gh` listed them, so the reason
/// `trigger` names is the first one `gh` would show the navigator.
///
/// The port of `cerebro--gh-moved` (`emacs/cerebro.el:2209`). Two `None`s, each excluding rather
/// than including:
///
/// - **`ended_at` of `None`** - a role this view has no end for - counts nothing. There is no
///   moment to compare against, and "I cannot tell what has changed" is a reason not to start a
///   session rather than a reason to start one on everything. Read the other way round it started
///   Moira every ten minutes for a day off one open issue (cb-b4m).
/// - **`snapshot.me` of `None`** excludes every pull request. Authorship is the whole of what
///   makes one Cypher's, and one that cannot be shown to be somebody else's must not start him on
///   the navigator's own.
///
/// An item whose `updated_at` is `None` is left out: undateable is not moved.
pub fn gh_moved(
    snapshot: &GhSnapshot,
    ended_at: Option<DateTime<Utc>>,
) -> (Vec<u64>, Vec<u64>) {
    let moved = |at: Option<DateTime<Utc>>| match (at, ended_at) {
        (Some(at), Some(ended)) => at > ended,
        _ => false,
    };
    let issues = snapshot
        .issues
        .iter()
        .filter(|issue| moved(issue.updated_at))
        .map(|issue| issue.number)
        .collect();
    let prs = snapshot
        .prs
        .iter()
        .filter(|pr| {
            let Some(me) = snapshot.me.as_deref() else { return false };
            let author = pr.author.as_ref().and_then(|a| a.login.as_deref());
            !pr.is_draft && author != Some(me) && moved(pr.updated_at)
        })
        .map(|pr| pr.number)
        .collect();
    (issues, prs)
}

/// The entries of LINKED whose `updated_at` is after ENDED_AT, in LINKED's order.
///
/// The port of `cerebro--linked-moved` (`emacs/cerebro.el:2266`). `None` ended_at is nothing
/// moved, for the reason `gh_moved` gives.
pub fn linked_moved<'a>(
    linked: &'a [LinkedBead],
    ended_at: Option<DateTime<Utc>>,
) -> Vec<&'a LinkedBead> {
    let Some(ended) = ended_at else { return Vec::new() };
    linked.iter().filter(|entry| entry.updated_at > ended).collect()
}
/// `cerebro-retry-backoff` (`emacs/cerebro.el`): seconds to wait before starting a role again, by
/// consecutive failed starts.
///
/// **The first entry is 0 on purpose.** A session that died once should come back immediately, and
/// a clock there would cost the fleet a pass every time anything went wrong once. What escalates
/// is the second failure and every one after it.
pub const RETRY_BACKOFF: [i64; 4] = [0, 30, 120, 600];

/// `cerebro-give-up-after`: consecutive starts that produced no pass before the view stops
/// retrying a name.
pub const GIVE_UP_AFTER: u32 = 5;

/// `cerebro-wake-intervals`, keyed by ROLE.
///
/// A name-keyed override exists in elisp and is deliberately not ported: no consumer uses one,
/// and a table with one column is clearer than a two-level lookup nothing exercises. The planners
/// and the implementers are at 0 on purpose - a short buffer is the fleet already idle, and a
/// clock there costs ten minutes on every trigger a pass CAN clear.
pub fn wake_interval(role: &str) -> i64 {
    match role {
        "verifier" => 300,
        "planner" | "implementer" | "producer" | "bugfixer" | "ux" | "build-design" => 0,
        _ => WAKE_INTERVAL_DEFAULT,
    }
}

/// `cerebro-role-start-spacing`, the fallback for a role the project declares nothing about.
pub fn default_spacing(role: &str) -> Option<u64> {
    match role {
        "planner" | "implementer" | "producer" | "bugfixer" | "ux" | "build-design" => Some(30),
        _ => None,
    }
}

/// What every role's condition is judged against. The port of `cerebro--trigger-context`, less
/// the `gh` resolver and `linked` ledger, which are cb-kcs.4.3's.
///
/// Built from a `WorkBuckets` this view actually has. **There is no "the board has not answered"
/// value**: Emacs sets `planned` to `most-positive-fixnum` so that no rule can fire, and refusing
/// to build a `TriggerFacts` at all says the same thing without a sentinel.
#[derive(Clone, Debug, PartialEq)]
pub struct TriggerFacts {
    /// Ids of the planning roles' candidates at priority 0 - across every list in
    /// `planning_candidates`, roles in map order, first sighting kept (cb-10d.2.2). On the
    /// evaluation line; the P0 arm itself reads the role's own first candidate.
    pub p0_unplanned: Vec<String>,
    /// `(id, updated_at)` for each `ux` candidate, the revision taken from `unplanned`, so a bead
    /// returned from a later stage breaks the UX unchanged-work guard even when its id is unchanged.
    pub undesigned_revisions: Vec<(String, Option<DateTime<Utc>>)>,
    /// Each planning role's candidates as the work reader listed them, in the scripts' order,
    /// minus every id in `spoken_for`. A role the reader was not asked about is absent. What the
    /// view hands a planning session (`bead_for`) and what its condition reads are this one list,
    /// so a session is never started for a bead it cannot be given (cb-10d.2.2).
    pub planning_candidates: BTreeMap<String, Vec<Candidate>>,
    /// How many unplanned, unparked beads carry `ux:agreed` - the `ux` role's own buffer, and the
    /// Rust copy of `scripts/planner-buffer --ux-agreed`. NO P4 filter, exactly as `planned` has
    /// none: this counts what is waiting for a build-designer, and the shell counts it the same
    /// way.
    pub ux_agreed: usize,
    /// How many planned, unclaimed, unparked beads there are.
    pub planned: usize,
    /// Ids of the planned, unclaimed, unparked beads - what an implementer may actually claim.
    pub planned_ids: Vec<String>,
    /// Planned-bead revisions keyed by id, so a replanned bead under the same id still moves the
    /// implementer fingerprint.
    pub planned_revisions: Vec<(String, Option<DateTime<Utc>>)>,
    /// The beads the next implementer start may be handed: `WorkBuckets::assignable` minus every
    /// bead already spoken for (`spoken_for`), in the script's order. `take` removes one handed out
    /// earlier in the same tick (cb-10d.1).
    pub assignable_ids: Vec<String>,
    /// The legacy implementer queue, kept distinct from producer work.
    pub implementer_assignable_ids: Vec<String>,
    /// The beads the next bugfixer start may be handed: `WorkBuckets::bugfixable` minus every
    /// bead already spoken for (`spoken_for`), in the script's order. `take` removes one handed
    /// out earlier in the same tick.
    pub bugfixable_ids: Vec<String>,
    /// Ids of the unplanned, unparked beads at priority 4, sorted, so the same set in a different
    /// bucket order is the same set.
    pub unranked_ids: Vec<String>,
    /// Beads merged and not yet verified.
    pub merged_unverified: usize,
    /// Beads in any OPEN bucket - paused included - carrying `verdict:stale`. Paused included
    /// because a bead can carry `verdict:stale` and `human` at once, and a stale verdict does not
    /// stop being one because the navigator was asked something about the bead.
    pub stale_verdicts: usize,
    /// Open beads the second-look script says are reachable by no standby role and need Psylocke.
    pub second_look: usize,
    /// Implementers on the roster that have not been told to finish. State is deliberately not
    /// read: a builder between beads has no session (cb-1or.1), so `standby`, `dead`, `idle` and
    /// `working` all count.
    pub implementers: usize,
    /// The buffer multiple this project declares (`PLANNER_MULTIPLE_KEY`), 1 when it declares
    /// none. Read once at startup, never per tick - so it is deliberately absent from
    /// `Fingerprint::Planner`, which compares only what can move under a running view.
    pub planner_multiple: usize,
    /// What the `gh` reader has to say this tick, for the whole fleet. Per-role filtering happens
    /// in `trigger`, because "what moved" is measured against the role's own last pass - which is
    /// why `M-x cerebro` has to pass a closure here (`emacs/cerebro.el:5955`) and this does not.
    pub gh: GhAnswer,
    /// The linked beads as the work reader last saw them (`WorkBuckets::linked`). Filtered per
    /// role by `linked_moved`, for the same reason.
    pub linked: Vec<LinkedBead>,
}

fn parked(labels: &[String]) -> bool {
    labels.iter().any(|l| PARKED_LABELS.contains(&l.as_str()))
}

fn stale(labels: &[String]) -> bool {
    labels.iter().any(|l| l == STALE_VERDICT_LABEL)
}

/// The unplanned, unparked beads at priority 4, sorted.
///
/// Sorted so the same set in a different bucket order is the same set
/// (`cerebro--trigger-context`'s own note). Extracted from `TriggerFacts::derive` in cb-kcs.5.2
/// because the triage path needs exactly this set from exactly these buckets and nothing else -
/// and a second copy of the rule is a set the two could disagree about. Since cb-lz5.1 it reads
/// BOTH open unplanned buckets: a P4 carrying `ux:agreed` is still a bead nobody has ranked.
pub fn unranked_ids(buckets: &WorkBuckets) -> Vec<String> {
    let mut ids: Vec<String> = buckets
        .unplanned
        .iter()
        .chain(buckets.ux_agreed.iter())
        .filter(|bead| !parked(&bead.labels) && bead.priority == Some(4))
        .map(|bead| bead.id.clone())
        .collect();
    ids.sort();
    ids
}

impl TriggerFacts {
    /// Derive them. `flagged` answers "is this name's stop flag set" and is the only impure thing
    /// the caller supplies; everything else is the snapshot.
    ///
    /// `bd`'s own `paused` bucket already holds `human` but NOT `triage:declined`, so both parked
    /// labels are filtered here rather than assumed handled by the partition.
    pub fn derive(
        buckets: &WorkBuckets,
        roster: &[RosterEntry],
        spoken_for: &std::collections::BTreeSet<String>,
        flagged: impl Fn(&str) -> bool,
        gh: GhAnswer,
        planner_multiple: usize,
    ) -> Self {
        let agreed: Vec<_> = buckets
            .ux_agreed
            .iter()
            .filter(|bead| !parked(&bead.labels))
            .collect();
        let planned: Vec<_> = buckets
            .planned
            .iter()
            .filter(|bead| !parked(&bead.labels))
            .collect();
        let unranked_ids = unranked_ids(buckets);
        let stale_verdicts = [
            &buckets.claimed,
            &buckets.planned,
            &buckets.being_planned,
            &buckets.ux_agreed,
            &buckets.unplanned,
            &buckets.paused,
        ]
        .into_iter()
        .flatten()
        .filter(|bead| stale(&bead.labels))
        .count();

        let planning_candidates: BTreeMap<String, Vec<Candidate>> = buckets
            .candidates
            .iter()
            .map(|(role, list)| {
                let free = list.iter().filter(|c| !spoken_for.contains(&c.id)).cloned().collect();
                (role.clone(), free)
            })
            .collect();
        let mut p0_unplanned: Vec<String> = Vec::new();
        for candidate in planning_candidates.values().flatten() {
            if candidate.priority == Some(0) && !p0_unplanned.contains(&candidate.id) {
                p0_unplanned.push(candidate.id.clone());
            }
        }
        let undesigned_revisions = planning_candidates
            .get("ux")
            .map(|list| {
                list.iter()
                    .map(|c| {
                        let revision = buckets
                            .unplanned
                            .iter()
                            .find(|bead| bead.id == c.id)
                            .and_then(|bead| bead.updated_at);
                        (c.id.clone(), revision)
                    })
                    .collect()
            })
            .unwrap_or_default();

        Self {
            p0_unplanned,
            undesigned_revisions,
            planning_candidates,
            planned: planned.len(),
            ux_agreed: agreed.len(),
            planned_ids: planned.iter().map(|bead| bead.id.clone()).collect(),
            planned_revisions: planned.iter().map(|bead| (bead.id.clone(), bead.updated_at)).collect(),
            assignable_ids: buckets
                .assignable
                .iter()
                .filter(|id| !spoken_for.contains(*id))
                .cloned()
                .collect(),
            implementer_assignable_ids: buckets
                .implementer_assignable
                .iter()
                .filter(|id| !spoken_for.contains(*id))
                .cloned()
                .collect(),
            bugfixable_ids: buckets
                .bugfixable
                .iter()
                .filter(|id| !spoken_for.contains(*id))
                .cloned()
                .collect(),
            unranked_ids,
            merged_unverified: buckets.merged.len(),
            stale_verdicts,
            second_look: buckets.second_look.len(),
            implementers: roster
                .iter()
                .filter(|entry| entry.kind == AgentKind::Implementer && !flagged(&entry.name))
                .count(),
            planner_multiple,
            gh,
            linked: buckets.linked.clone(),
        }
    }

    /// How many planned, unclaimed beads the fleet wants: `planner_multiple` per implementer,
    /// never fewer than `PLANNER_BUFFER_FLOOR` (`cerebro--planner-want`).
    pub fn planner_want(&self) -> usize {
        // Saturating, so an absurd declaration cannot wrap to a number BELOW the floor - which
        // would silently pin the buffer - where elisp would have grown a bignum.
        self.implementers.saturating_mul(self.planner_multiple).max(PLANNER_BUFFER_FLOOR)
    }
}

/// What is this row's rather than the fleet's. The port of `cerebro--agent-context`, less its
/// `gh` and `linked-moved`.
#[derive(Clone, Copy, Debug)]
pub struct AgentFacts<'a> {
    pub role: &'a str,
    /// When this name's last session ended: the moment the view ended it, or failing that the
    /// last successful fleet read that saw it up. `None` for a name never seen at all.
    pub ended_at: Option<DateTime<Utc>>,
    /// When this view last launched it. `None` if it never has.
    pub started_at: Option<DateTime<Utc>>,
    /// What this role's own last start was triggered by.
    pub last_fingerprint: Option<&'a Fingerprint>,
}

/// Everything a role's condition rules read out of `TriggerFacts`, and nothing else.
///
/// The port of `cerebro--trigger-fingerprint`. It carries IDS and not only counts: a planner that
/// plans one bead while another arrives leaves every count where it was, and "nothing changed"
/// would then be wrong in the one direction that costs the fleet work.
///
/// `None` for a role with no condition rules, and that is load-bearing rather than incidental.
/// cb-kcs.4.3's roles start on a clock, and what they watch moves outside this fleet, so the
/// fleet looking unchanged is evidence of nothing about them and they must never be held here.
///
/// The verifier is `None` for a different reason: an unchanged count is not evidence that its
/// work cannot be done. A pass ends with beads unverified because the sitting ended or the
/// navigator said "later", and either way those beads are reason enough to start again. Its
/// wake interval, not this guard, is what keeps it from starting too often.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fingerprint {
    /// `candidates` is every candidate of the role with its priority, P4s included, so ranking a
    /// bead still moves the fingerprint (cb-zgg, cb-10d.2.2).
    Planner {
        planned: usize,
        implementers: usize,
        candidates: Vec<(String, Option<u8>)>,
    },
    Implementer {
        planned_ids: Vec<String>,
        planned_revisions: Vec<(String, Option<DateTime<Utc>>)>,
    },
    Producer {
        assignable_ids: Vec<String>,
    },
    Bugfixer {
        bugfixable_ids: Vec<String>,
    },
    Orchestrator {
        unranked_ids: Vec<String>,
    },
    Ux {
        ux_agreed: usize,
        implementers: usize,
        candidates: Vec<(String, Option<u8>)>,
        undesigned_revisions: Vec<(String, Option<DateTime<Utc>>)>,
    },
    BuildDesign {
        planned: usize,
        implementers: usize,
        candidates: Vec<(String, Option<u8>)>,
    },
}

/// Every candidate of ROLE with its priority, in the script's order.
fn candidate_pairs(facts: &TriggerFacts, role: &str) -> Vec<(String, Option<u8>)> {
    facts
        .planning_candidates
        .get(role)
        .map(|list| list.iter().map(|c| (c.id.clone(), c.priority)).collect())
        .unwrap_or_default()
}

pub fn fingerprint(role: &str, facts: &TriggerFacts) -> Option<Fingerprint> {
    match role {
        "planner" => Some(Fingerprint::Planner {
            planned: facts.planned,
            implementers: facts.implementers,
            candidates: candidate_pairs(facts, role),
        }),
        "implementer" => Some(Fingerprint::Implementer {
            planned_ids: facts.planned_ids.clone(),
            planned_revisions: facts.planned_revisions.clone(),
        }),
        "producer" => Some(Fingerprint::Producer {
            assignable_ids: facts.assignable_ids.clone(),
        }),
        "bugfixer" => Some(Fingerprint::Bugfixer {
            bugfixable_ids: facts.bugfixable_ids.clone(),
        }),
        "orchestrator" => Some(Fingerprint::Orchestrator {
            unranked_ids: facts.unranked_ids.clone(),
        }),
        "ux" => Some(Fingerprint::Ux {
            ux_agreed: facts.ux_agreed,
            implementers: facts.implementers,
            candidates: candidate_pairs(facts, role),
            undesigned_revisions: facts.undesigned_revisions.clone(),
        }),
        "build-design" => Some(Fingerprint::BuildDesign {
            planned: facts.planned,
            implementers: facts.implementers,
            candidates: candidate_pairs(facts, role),
        }),
        _ => None,
    }
}

/// Why this role should start now - the sentence the header notice carries after the em dash -
/// or `None`. The port of `cerebro--trigger` for the four board-backed roles.
pub fn trigger(
    facts: &TriggerFacts,
    agent: AgentFacts<'_>,
    now: DateTime<Utc>,
) -> Option<String> {
    // The floor, first and for every role. A role this view has never started has none to clear.
    if let Some(started) = agent.started_at {
        if (now - started).num_seconds() < wake_interval(agent.role) {
            return None;
        }
    }
    if let Some(reason) = condition(facts, &agent) {
        if !unchanged(facts, &agent) {
            return Some(reason);
        }
    }
    // The cadence floor is the `else` of the whole guarded expression above
    // (`emacs/cerebro.el:2192-2195`), and its placement is load-bearing twice over. It is
    // OUTSIDE `unchanged`: a clock is not evidence about the fleet, and holding it because
    // nothing on the board changed would disable the floor entirely. It is INSIDE the wake
    // interval, copied rather than reasoned about, because a role a consumer gives a longer wake
    // interval than its cadence must obey the longer one. And it needs an `ended_at`: a role this
    // view has no end for never starts on its floor, which `StartLedger::note_armed` makes a
    // corner rather than the normal case.
    if let (Some(cadence), Some(ended)) = (cadence(agent.role), agent.ended_at) {
        if (now - ended).num_seconds() >= cadence {
            return Some(format!(
                "{} since its last {}",
                cadence_figure(cadence),
                cadence_noun(agent.role)
            ));
        }
    }
    None
}

/// The role's own condition, first arm true winning.
fn condition(facts: &TriggerFacts, agent: &AgentFacts<'_>) -> Option<String> {
    match agent.role {
        // The three planning roles share one shape (cb-10d.2.2): nothing to hand is no reason to
        // start, a P0 first in the queue is reason whatever the buffer says, and otherwise a short
        // buffer is. The pick and the condition read the same list, so a blocked or unranked
        // bead never starts a session with nothing to take.
        "planner" | "build-design" => {
            let pick = bead_for(facts, agent.role)?;
            if first_candidate(facts.planning_candidates.get(agent.role)?)?.priority == Some(0) {
                return Some(format!("P0 {pick} unplanned"));
            }
            let want = facts.planner_want();
            (facts.planned < want).then(|| format!("buffer {} of {want}", facts.planned))
        }
        "ux" => {
            let pick = bead_for(facts, agent.role)?;
            if first_candidate(facts.planning_candidates.get(agent.role)?)?.priority == Some(0) {
                return Some(format!("P0 {pick} unplanned"));
            }
            let want = facts.planner_want();
            (facts.ux_agreed < want).then(|| format!("UX {} of {want}", facts.ux_agreed))
        }
        // Stale first: a stale verdict is a bead the fleet cannot act on until she looks again.
        "verifier" => {
            if facts.stale_verdicts > 0 {
                let n = facts.stale_verdicts;
                return Some(format!(
                    "{n} stale verdict{}",
                    if n == 1 { "" } else { "s" }
                ));
            }
            if facts.second_look > 0 {
                let n = facts.second_look;
                return Some(format!(
                    "{n} need{} second look",
                    if n == 1 { "s" } else { "" }
                ));
            }
            (facts.merged_unverified > 0)
                .then(|| format!("{} merged, unverified", facts.merged_unverified))
        }
        "implementer" => (!facts.implementer_assignable_ids.is_empty())
            .then(|| format!("{} planned, unclaimed", facts.implementer_assignable_ids.len())),
        "producer" => (!facts.assignable_ids.is_empty())
            .then(|| format!("{} UX-agreed, unclaimed", facts.assignable_ids.len())),
        "bugfixer" => (!facts.bugfixable_ids.is_empty())
            .then(|| format!("{} bugfix candidate{}", facts.bugfixable_ids.len(), if facts.bugfixable_ids.len() == 1 { "" } else { "s" })),
        "orchestrator" => (!facts.unranked_ids.is_empty())
            .then(|| format!("{} unranked", facts.unranked_ids.len())),
        // First true wins, and the order is who is waiting: an issue is a person, a linked bead
        // is the fleet's own bookkeeping.
        "user-feedback" => {
            if let GhAnswer::Answered(snapshot) = &facts.gh {
                if let Some(number) = gh_moved(snapshot, agent.ended_at).0.first() {
                    return Some(format!("issue #{number} moved"));
                }
            }
            linked_moved(&facts.linked, agent.ended_at)
                .first()
                .map(|entry| format!("bead {} moved (issue #{})", entry.id, entry.issue))
        }
        "reviewer" => {
            let GhAnswer::Answered(snapshot) = &facts.gh else { return None };
            gh_moved(snapshot, agent.ended_at)
                .1
                .first()
                .map(|number| format!("PR #{number} moved"))
        }
        // `architect` has no condition at all: the cadence floor in `trigger` is its whole
        // trigger.
        _ => None,
    }
}

/// The unchanged-work guard (`cerebro--unless-unchanged`): a pass that RAN and changed nothing
/// the role reads holds the next start.
///
/// The `ended_at > started_at` clause is what makes it hold a pass that ran and never a launch
/// that never became one. The fingerprint is recorded when a launch is *attempted*, so without it
/// a launch that died silently would buy this guard's silence for nothing.
fn unchanged(facts: &TriggerFacts, agent: &AgentFacts<'_>) -> bool {
    let (Some(last), Some(now_print)) = (agent.last_fingerprint, fingerprint(agent.role, facts))
    else {
        return false;
    };
    let (Some(started), Some(ended)) = (agent.started_at, agent.ended_at) else {
        return false;
    };
    *last == now_print && ended > started
}

/// Whether ROLE's condition WAS true and the unchanged-work guard is what dropped it.
///
/// The one thing cb-kcs.4.4's evaluation line cannot see from outside: `trigger` answers `None`
/// for a condition that was false and for one the guard held, and those are two different answers
/// to "why did nothing happen". Both halves are this module's own private rules, which is why the
/// question is answered here rather than reconstructed by the caller.
pub fn held_by_unchanged_work(facts: &TriggerFacts, agent: AgentFacts<'_>) -> bool {
    condition(facts, &agent).is_some() && unchanged(facts, &agent)
}

/// The gold header notice for a start the view decided on: `Started Beast — buffer 2 of 4.`
///
/// An em dash (U+2014) with a space either side, and a full stop. The reason is the trigger's own
/// phrase, unchanged, so the two views say one thing and cb-kcs.4.4 logs the same string.
pub fn start_notice(name: &str, reason: &str) -> String {
    format!("Started {name} — {reason}.")
}

/// Did the start at STARTED produce no pass by ENDED? The port of `cerebro--start-failed-p`.
///
/// A pass that ran leaves an end LATER than its start; a launch that never became a session leaves
/// the previous pass's end, or nothing. `None` for STARTED is `false`: a name this view has never
/// started has not failed to start it.
pub fn start_failed(started: Option<DateTime<Utc>>, ended: Option<DateTime<Utc>>) -> bool {
    let Some(started) = started else { return false };
    !matches!(ended, Some(ended) if ended > started)
}

/// Seconds to wait after FAILURES consecutive failed starts (`cerebro--retry-delay`). The indexing
/// is exact and easy to get wrong:
///
///     failures 0 or 1  -> RETRY_BACKOFF[0]     = 0    (comes straight back)
///     failures 2       -> RETRY_BACKOFF[1]     = 30
///     failures 3       -> RETRY_BACKOFF[2]     = 120
///     failures >= 4    -> RETRY_BACKOFF[last]  = 600
///
/// i.e. `RETRY_BACKOFF[failures - 1]`, the first entry at or below 1 and the last at or above its
/// length - a ceiling, so a launch refused all morning is retried at a steady interval rather than
/// at an ever-growing one nobody would see end. **`failures` is the count BEFORE the start being
/// decided**, everywhere in this module.
pub fn retry_delay(failures: u32) -> i64 {
    let index = (failures.max(1) as usize - 1).min(RETRY_BACKOFF.len() - 1);
    RETRY_BACKOFF[index]
}

/// Seconds until a start after FAILURES failed starts is due at NOW, measured from STARTED - the
/// failed start itself, so the wait a row counts down and the wait `start_due` enforces are one
/// calculation (`cerebro--retry-wait`). Never negative; 0 for a `None` STARTED, which is a name
/// this view has never started and so has nothing to wait out.
pub fn retry_wait(failures: u32, started: Option<DateTime<Utc>>, now: DateTime<Utc>) -> i64 {
    let Some(started) = started else { return 0 };
    (retry_delay(failures) - (now - started).num_seconds()).max(0)
}

/// SECONDS as the figure a retry row names: `45s`, `2m` (`cerebro--retry-figure`). Below a minute,
/// whole seconds rounded up; at a minute and above, whole minutes rounded up - so a row never
/// names a smaller figure than the wait actually left. `1m` shown with 61 seconds to go would come
/// due a minute after it said it would.
pub fn retry_figure(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds < 60 {
        format!("{seconds}s")
    } else {
        format!("{}m", (seconds + 59) / 60)
    }
}

/// Would the start being decided be one failed start too many (`cerebro--give-up-p`)? FAILED is
/// whether the LAST start produced no pass, FAILURES the count behind it - so the start under
/// consideration would be number `failures + 1`.
pub fn give_up(failed: bool, failures: u32) -> bool {
    failed && failures + 1 >= GIVE_UP_AFTER
}

/// The BEAD cell of a row that is backing off:
///
///     ↻ retry in 30s, 2 failed
///
/// U+21BB, a space, `retry in `, `retry_figure(left)`, then `, {failures} failed`. The count clause
/// is dropped when FAILURES is 0, which cannot happen while `left > 0` under `retry_delay` but is
/// the shape `cerebro--for-column` has and costs one branch. No plural: the noun is not there to
/// need one.
pub fn retry_label(failures: u32, left: i64) -> String {
    let figure = retry_figure(left);
    match failures {
        0 => format!("\u{21bb} retry in {figure}"),
        n => format!("\u{21bb} retry in {figure}, {n} failed"),
    }
}

/// The BEAD cell of any standby row: the countdown if one is running, else the role's own
/// condition.
///
/// **The countdown comes first for every kind, whether or not the role's trigger is currently
/// true** (the navigator's choice, round 2): a planner backing off in front of a full buffer reads
/// `↻ retry in 2m, 3 failed` and not `→ buffer<4`. While a backoff is running the row says so, and
/// a failure is never invisible. The accepted cost is a countdown that reaches zero and visibly
/// does nothing, because nothing was due anyway.
///
/// LEFT is `retry_wait(...)`. At `left <= 0` this is exactly `standby_label`.
pub fn standby_cell(
    role: &str,
    facts: &TriggerFacts,
    agent: AgentFacts<'_>,
    now: DateTime<Utc>,
    failures: u32,
    left: i64,
) -> Option<String> {
    // A role with no cell of its own gets no countdown either: it is not armed at all, and a cell
    // in a vocabulary its row never speaks would be this view inventing one. Since cb-kcs.4.3
    // that is no role the roster can arm - every one of them has a cell - but the `None` is what
    // says so rather than a comment claiming it.
    let label = standby_label(role, facts, agent, now)?;
    Some(if left > 0 { retry_label(failures, left) } else { label })
}

/// The gold header notice when the view stops retrying a name:
///
///     Xavier: 5 starts produced no pass; the view has stopped trying.
///
/// TOTAL is `failures + 1`, the start that was not made. Beside `start_notice` so the loop cannot
/// spell either sentence twice.
pub fn give_up_notice(name: &str, total: u32) -> String {
    format!("{name}: {total} starts produced no pass; the view has stopped trying.")
}

/// The BEAD column of a standby row: what the agent is waiting for. The vocabulary is closed.
///
/// The arrow is U+2192, and in the `planner` arm there is no space around the `<` - that is what
/// makes `→ buffer<4` exactly ten cells, which is `BEAD_FLOOR`. A ten-implementer fleet wants
/// eleven and the column takes them: the number is the part that changes.
///
/// The two staged planning roles name the pile they fill and how full it is instead (cb-m0c) -
/// `→ agreed n/want` and `→ planned n/want`, both longer than `BEAD_FLOOR` at a realistic
/// fleet, which `ui::natural_bead` sizes the column from. They are deliberately NOT the `<` shape:
/// two adjacent stages said the same idea two different ways and neither said how full the pile
/// was, so a sleeping row with work piling up looked like one with nothing to do. A full pile
/// still gets a note here - `condition` is what answers `None`.
///
///     user-feedback | reviewer | architect
///         -> `countdown(ended_at + cadence - now)`, or `→ hourly` when there is no `ended_at`
///            to count from, plus ` gh?` for the two GitHub-backed roles when `facts.gh` is
///            `GhAnswer::Failed`.
///
/// `→ hourly` is the fallback rather than an empty cell - `M-x cerebro` draws nothing there
/// (`cerebro--countdown`'s nil arm), and the navigator rejected that: a standby row with a blank
/// cell says nothing at all about why it is asleep. It names the floor instead of counting it.
///
/// ` gh?` in the cell's own blue, not red: nothing is broken - both roles still run hourly - so it
/// is part of what the row is waiting for rather than a fault, and red is already this view's
/// colour for a refused launch's verdict. It is absent for `GhAnswer::Unanswered`: a reader that
/// has not answered YET is not a reader that failed. `architect` never carries it - its trigger
/// reads no `gh` at all.
pub fn standby_label(
    role: &str,
    facts: &TriggerFacts,
    agent: AgentFacts<'_>,
    now: DateTime<Utc>,
) -> Option<String> {
    match role {
        "planner" => Some(format!("→ buffer<{}", facts.planner_want())),
        "ux" => Some(format!("→ agreed {}/{}", facts.ux_agreed, facts.planner_want())),
        "build-design" => {
            Some(format!("→ planned {}/{}", facts.planned, facts.planner_want()))
        }
        "implementer" => Some("→ planned".to_string()),
        "producer" => Some("→ agreed build".to_string()),
        "bugfixer" => Some("→ bugs".to_string()),
        "verifier" => Some("→ merged".to_string()),
        "orchestrator" => Some("→ unranked".to_string()),
        _ => {
            let cadence = cadence(role)?;
            let cell = match agent.ended_at {
                Some(ended) => countdown(cadence - (now - ended).num_seconds()),
                None => "→ hourly".to_string(),
            };
            let blind = role != "architect" && facts.gh == GhAnswer::Failed;
            Some(if blind { format!("{cell} gh?") } else { cell })
        }
    }
}

/// The bead the next implementer start is given: the first assignable one, or `None` (cb-10d.1).
pub fn next_bead(facts: &TriggerFacts) -> Option<&str> {
    facts.assignable_ids.first().map(String::as_str)
}

/// The bead the next bugfixer start is given: the first bugfix candidate, or `None`.
pub fn next_bugfix(facts: &TriggerFacts) -> Option<&str> {
    facts.bugfixable_ids.first().map(String::as_str)
}

/// Whether ROLE is started with a bead the view picked: `implementer` (cb-10d.1) and the three
/// planning roles (cb-10d.2.2).
pub fn hands_a_bead(role: &str) -> bool {
    let policy = RolePolicy::for_role(role);
    policy.is_builder() || policy == RolePolicy::Bugfixer || policy.is_planning()
}

/// The first candidate a planning role may be given: not P4 and not unranked (`priority` `None`)
/// - a P4 is a bead nobody has ranked, which is Cerebro's to rank and not a planner's to plan.
pub fn first_candidate(candidates: &[Candidate]) -> Option<&Candidate> {
    candidates.iter().find(|c| !matches!(c.priority, Some(4) | None))
}

/// The bead the next start of ROLE is given: an implementer's first assignable bead, a planning
/// role's `first_candidate`, and `None` for any other role.
pub fn bead_for<'a>(facts: &'a TriggerFacts, role: &str) -> Option<&'a str> {
    match RolePolicy::for_role(role) {
        RolePolicy::Producer => return next_bead(facts),
        RolePolicy::Implementer => return facts.implementer_assignable_ids.first().map(String::as_str),
        RolePolicy::Bugfixer => return next_bugfix(facts),
        _ => {}
    }
    first_candidate(facts.planning_candidates.get(role)?).map(|c| c.id.as_str())
}

impl TriggerFacts {
    /// Remove ID from `assignable_ids` and from every planning role's candidates: a bead handed
    /// out earlier in THIS tick is not handed again, to any role.
    pub fn take(&mut self, id: &str) {
        self.assignable_ids.retain(|candidate| candidate != id);
        self.implementer_assignable_ids.retain(|candidate| candidate != id);
        self.bugfixable_ids.retain(|candidate| candidate != id);
        for list in self.planning_candidates.values_mut() {
            list.retain(|candidate| candidate.id != id);
        }
    }
}

/// Every bead a row's state file names, every bead in HANDED, and every bead a give-back is still
/// carrying (RELEASING) - the ids no start may be given. Releasing counts because a bead handed
/// straight back to the same name while its release runs would be unclaimed under a live session.
pub fn spoken_for(
    rows: &[FleetRow],
    handed: &BTreeMap<String, String>,
    releasing: &BTreeMap<String, crate::model::Releasing>,
) -> std::collections::BTreeSet<String> {
    rows.iter()
        .filter_map(|row| row.bead.clone())
        .chain(handed.values().cloned())
        .chain(releasing.values().map(|entry| entry.bead.clone()))
        .collect()
}

/// The other holders of ROLE, excluding NAME itself - who a start could race with
/// (`cerebro--role-peers`). A role with one holder has none, which is what makes this answer "no"
/// for every role but the planners and the implementers without naming any of them.
pub fn role_peers<'a>(name: &str, role: &str, roster: &'a [RosterEntry]) -> Vec<&'a str> {
    roster
        .iter()
        .filter(|entry| entry.role == role && entry.name != name)
        .map(|entry| entry.name.as_str())
        .collect()
}

/// Has a PEER of this role been started within SPACING seconds of NOW?
///
/// **Strictly less than**, so a peer started exactly `spacing` seconds ago is not too soon; and a
/// spacing of 0 is therefore "never space this role", which falls out of the comparison rather
/// than being special-cased. `None` spacing is no spacing at all.
pub fn role_start_too_soon(
    peers: &[&str],
    started_at: &BTreeMap<String, DateTime<Utc>>,
    spacing: Option<u64>,
    now: DateTime<Utc>,
) -> bool {
    let Some(spacing) = spacing else { return false };
    peers.iter().any(|peer| {
        started_at
            .get(*peer)
            .is_some_and(|started| (now - *started).num_seconds() < spacing as i64)
    })
}

/// The spacing in force for ROLE: what the project declared, else `default_spacing(role)`.
///
/// The project wins outright - a number in one navigator's init must not decide whether every
/// clone of a project races (cb-3m0). A declared `0` is a real answer and must not fall through
/// to the default, which is why this is `or_else` over `Option` rather than `unwrap_or` on a 0.
pub fn spacing_for(role: &str, declared: &BTreeMap<String, u64>) -> Option<u64> {
    declared
        .get(role)
        .copied()
        .or_else(|| default_spacing(role))
}

/// RAW as a spacing: `Ok(Some(n))` for a whole number of seconds, `Ok(None)` for an absent or
/// empty declaration, `Err(raw)` for anything else - a negative number, `4.5`, `30s`. Three
/// answers, not two: "declared nothing" and "declared nonsense" get different treatment.
pub fn parse_spacing(raw: &str) -> Result<Option<u64>, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    trimmed
        .parse::<u64>()
        .map(Some)
        .map_err(|_| trimmed.to_string())
}

/// What this view has started and ended, per name. The port of `cerebro--started-at`,
/// `cerebro--start-fingerprints`, and the `ended-at` half of `cerebro--parked`/`cerebro--seen-up`.
/// Wall-clock throughout, because everything it is compared against already is.
#[derive(Debug, Default)]
pub struct StartLedger {
    started_at: BTreeMap<String, DateTime<Utc>>,
    parked_at: BTreeMap<String, DateTime<Utc>>,
    seen_up_at: BTreeMap<String, DateTime<Utc>>,
    fingerprints: BTreeMap<String, Fingerprint>,
    failures: BTreeMap<String, u32>,
}

impl StartLedger {
    /// Record a launch: the moment, and what it was triggered by (`None` for a start the
    /// navigator made by hand, which is never compared against anything).
    pub fn note_started(&mut self, name: &str, at: DateTime<Utc>, fingerprint: Option<Fingerprint>) {
        self.started_at.insert(name.to_string(), at);
        match fingerprint {
            Some(print) => {
                self.fingerprints.insert(name.to_string(), print);
            }
            None => {
                self.fingerprints.remove(name);
            }
        }
    }

    /// Forget the failures behind NAME once a pass has actually run.
    ///
    /// An end later than the start it followed is a start that produced a pass. A name this
    /// view never started is left alone: `start_failed` answers `false` for it, but there is no
    /// start here for a pass to have survived. Without this the count is only
    /// rewritten at the NEXT start decision, so a standby row's `failed_starts` stands in
    /// `evaluations.jsonl` for as long as the row stays asleep - hours, saying a name is backing
    /// off when it is not.
    fn clear_failures_if_a_pass_ran(&mut self, name: &str, at: DateTime<Utc>) {
        if self.started_at.get(name).is_some_and(|started| at > *started) {
            self.failures.remove(name);
        }
    }

    /// Record that the view ended NAME's pass - the authoritative `ended_at`.
    pub fn note_ended(&mut self, name: &str, at: DateTime<Utc>) {
        self.parked_at.insert(name.to_string(), at);
        self.clear_failures_if_a_pass_ran(name, at);
    }

    /// Record that a successful fleet read saw NAME up. The FALLBACK `ended_at`, and it is
    /// needed: a session that simply died, or one this process never ended, has no park at all,
    /// and a `None` there is what let a role read every open item as moved on every tick for a
    /// day (cb-b4m).
    pub fn note_seen_up(&mut self, name: &str, at: DateTime<Utc>) {
        self.seen_up_at.insert(name.to_string(), at);
        self.clear_failures_if_a_pass_ran(name, at);
    }

    /// The park if there is one, else the last tick that saw it up.
    pub fn ended_at(&self, name: &str) -> Option<DateTime<Utc>> {
        self.parked_at
            .get(name)
            .or_else(|| self.seen_up_at.get(name))
            .copied()
    }

    pub fn started_at(&self, name: &str) -> Option<DateTime<Utc>> {
        self.started_at.get(name).copied()
    }

    pub fn started_at_map(&self) -> &BTreeMap<String, DateTime<Utc>> {
        &self.started_at
    }

    pub fn fingerprint(&self, name: &str) -> Option<&Fingerprint> {
        self.fingerprints.get(name)
    }

    /// Arm a name the roster declared `standby` but did not start: give it an `ended_at` of NOW
    /// so a rule measured against an end has a moment to count from, WITHOUT overwriting a real
    /// park. No `started_at`: it has never started.
    pub fn note_armed(&mut self, name: &str, at: DateTime<Utc>) {
        self.parked_at.entry(name.to_string()).or_insert(at);
    }

    /// Consecutive starts of NAME that produced no pass, as counted BEFORE the start being
    /// decided. 0 for a name with no entry (`cerebro--failed-starts`).
    pub fn failures(&self, name: &str) -> u32 {
        self.failures.get(name).copied().unwrap_or(0)
    }

    /// Write the count as `start_due` decided it: `failures + 1` when the last start failed, 0
    /// when a pass has run since. Called immediately before the launch, from what the LAST start
    /// did - not after, and not from this start's outcome, which is not known for five seconds.
    pub fn set_failures(&mut self, name: &str, n: u32) {
        self.failures.insert(name.to_string(), n);
    }

    /// A start with no trigger behind it - `s`, or the roster's `autostart` - clears the backoff.
    /// The navigator asking for a session is what says the last five do not count.
    pub fn clear_failures(&mut self, name: &str) {
        self.failures.remove(name);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{partition_beads, AgentKind, Bead, Candidate, RosterEntry};
    use std::collections::BTreeSet;
    use crate::model::RowState;

    fn row(name: &str, role: &str, state: RowState, bead: Option<&str>) -> FleetRow {
        FleetRow {
            name: name.into(),
            role: role.into(),
            kind: if role == "implementer" {
                AgentKind::Implementer
            } else {
                AgentKind::Interactive
            },
            state,
            phase: None,
            bead: bead.map(str::to_string),
            since: None,
            phase_since: None,
            pid: None,
            sessions: 1,
            diagnostic: None,
            turn_ended: None,
        }
    }

    fn facts_for(beads: Vec<Bead>, candidates: &[(&str, Vec<(&str, u8)>)]) -> TriggerFacts {
        let roster = roster(&[("Xavier", "planner"), ("Cyclops", "implementer")]);
        let mut buckets = partition_beads(beads);
        buckets.candidates = cands(candidates);
        TriggerFacts::derive(&buckets, &roster, &BTreeSet::new(), |_| false, GhAnswer::Unanswered, 1)
    }

    /// Each role's candidates, as its script would list them.
    fn cands(list: &[(&str, Vec<(&str, u8)>)]) -> BTreeMap<String, Vec<Candidate>> {
        list.iter()
            .map(|(role, ids)| {
                let row = |(id, p): &(&str, u8)| Candidate { id: id.to_string(), priority: Some(*p) };
                (role.to_string(), ids.iter().map(row).collect())
            })
            .collect()
    }

    fn agent_of(role: &str) -> AgentFacts<'_> {
        AgentFacts { role, ended_at: None, started_at: None, last_fingerprint: None }
    }

    /// The cb-lz5 split must be invisible to the combined `planner` role, which this repository
    /// itself runs: `plan-candidates` lists an agreed bead too, and the planner is handed it
    /// (cb-10d.2.2).
    #[test]
    fn the_planner_still_sees_an_agreed_bead_as_its_own_work() {
        let facts = facts_for(
            vec![
                bead("cb-a2", "open", &["ux:agreed"], 2),
                bead("cb-a0", "open", &["ux:agreed"], 0),
            ],
            &[("planner", vec![("cb-a0", 0), ("cb-a2", 2)])],
        );
        assert_eq!(facts.p0_unplanned, vec!["cb-a0".to_string()]);
        assert_eq!(
            condition(&facts, &agent_of("planner")),
            Some("P0 cb-a0 unplanned".to_string())
        );
        assert_eq!(bead_for(&facts, "planner"), Some("cb-a0"));
    }

    /// Cerebro's triage arm and Psylocke's stale-verdict arm read the open buckets too, and both
    /// lose a bead the moment `ux:agreed` moves it out of `unplanned`.
    #[test]
    fn an_agreed_bead_still_counts_as_unranked_and_as_a_stale_verdict() {
        let facts = facts_for(
            vec![
                bead("cb-p4", "open", &["ux:agreed"], 4),
                bead("cb-st", "open", &["ux:agreed", "verdict:stale"], 2),
            ],
            &[],
        );
        assert_eq!(facts.unranked_ids, vec!["cb-p4".to_string()]);
        assert_eq!(facts.stale_verdicts, 1);
    }

    /// The `ux` role's own queue is what it has NOT designed yet, and its buffer is how much
    /// agreed work is waiting for a build-designer.
    #[test]
    fn the_ux_role_starts_while_the_agreed_queue_is_short() {
        let facts = facts_for(
            vec![
                bead("cb-u1", "open", &[], 2),
                bead("cb-u2", "open", &[], 2),
                bead("cb-u3", "open", &[], 2),
                bead("cb-a1", "open", &["ux:agreed"], 2),
            ],
            &[("ux", vec![("cb-u1", 2), ("cb-u2", 2), ("cb-u3", 2)])],
        );
        assert_eq!(facts.planner_want(), 2);
        assert_eq!(condition(&facts, &agent_of("ux")), Some("UX 1 of 2".to_string()));
    }

    #[test]
    fn the_ux_role_takes_a_p0_before_the_queue() {
        let facts = facts_for(
            vec![
                bead("cb-p0", "open", &[], 0),
                bead("cb-a1", "open", &["ux:agreed"], 2),
                bead("cb-a2", "open", &["ux:agreed"], 2),
            ],
            &[("ux", vec![("cb-p0", 0)])],
        );
        assert_eq!(
            condition(&facts, &agent_of("ux")),
            Some("P0 cb-p0 unplanned".to_string()),
            "the P0 arm wins over a buffer that is already full"
        );
    }

    #[test]
    fn the_ux_role_is_held_when_nothing_is_undesigned() {
        let facts = facts_for(vec![bead("cb-a1", "open", &["ux:agreed"], 2)], &[("ux", vec![])]);
        assert_eq!(condition(&facts, &agent_of("ux")), None);
        assert_eq!(
            standby_label("ux", &facts, agent_of("ux"), at(0)),
            Some("\u{2192} agreed 1/2".to_string())
        );
    }

    #[test]
    fn the_build_design_role_starts_while_the_planned_buffer_is_short() {
        let queue = || vec![("build-design", vec![("cb-a1", 2)])];
        let short = facts_for(vec![bead("cb-a1", "open", &["ux:agreed"], 2)], &queue());
        assert_eq!(
            condition(&short, &agent_of("build-design")),
            Some("buffer 0 of 2".to_string())
        );

        let full = facts_for(
            vec![
                bead("cb-a1", "open", &["ux:agreed"], 2),
                bead("cb-p1", "open", &["planned"], 2),
                bead("cb-p2", "open", &["planned"], 2),
            ],
            &queue(),
        );
        assert_eq!(condition(&full, &agent_of("build-design")), None);
    }

    #[test]
    fn the_build_design_role_is_held_when_nothing_is_agreed() {
        let facts = facts_for(vec![bead("cb-u1", "open", &[], 2)], &[("build-design", vec![])]);
        assert_eq!(condition(&facts, &agent_of("build-design")), None);
        assert_eq!(
            standby_label("build-design", &facts, agent_of("build-design"), at(0)),
            Some("\u{2192} planned 0/2".to_string())
        );
    }

    /// cb-m0c increment 2 — each staged role names the pile it fills and how full it is.
    ///
    /// The two adjacent stages said the same idea two different ways (`\u{2192} UX<4`,
    /// `\u{2192} buffer<4`) and neither said how full the pile actually was, so a sleeping row with
    /// work piling up looked exactly like one with nothing to do.
    #[test]
    fn the_two_stage_roles_name_the_pile_they_fill() {
        // Four implementers, so `planner_want` is 4 and the denominator is worth reading.
        let four = |beads: Vec<Bead>| {
            let roster = roster(&[
                ("Xavier", "ux"),
                ("Beast", "build-design"),
                ("Cyclops", "implementer"),
                ("Rogue", "implementer"),
                ("Storm", "implementer"),
                ("Gambit", "implementer"),
            ]);
            TriggerFacts::derive(
                &partition_beads(beads),
                &roster,
                &std::collections::BTreeSet::new(),
                |_| false,
                GhAnswer::Unanswered,
                1,
            )
        };

        let two = four(vec![
            bead("cb-u1", "open", &[], 2),
            bead("cb-a1", "open", &["ux:agreed"], 2),
            bead("cb-a2", "open", &["ux:agreed"], 2),
            bead("cb-p1", "open", &["planned"], 2),
            bead("cb-p2", "open", &["planned"], 2),
        ]);
        assert_eq!(two.planner_want(), 4);
        assert_eq!(
            standby_label("ux", &two, agent_of("ux"), at(0)),
            Some("\u{2192} agreed 2/4".to_string())
        );
        assert_eq!(
            standby_label("build-design", &two, agent_of("build-design"), at(0)),
            Some("\u{2192} planned 2/4".to_string())
        );

        // A full pile still gets a note: `condition` is what returns `None`, not this.
        let full = four(vec![
            bead("cb-u1", "open", &[], 2),
            bead("cb-a1", "open", &["ux:agreed"], 2),
            bead("cb-a2", "open", &["ux:agreed"], 2),
            bead("cb-a3", "open", &["ux:agreed"], 2),
            bead("cb-a4", "open", &["ux:agreed"], 2),
            bead("cb-p1", "open", &["planned"], 2),
            bead("cb-p2", "open", &["planned"], 2),
            bead("cb-p3", "open", &["planned"], 2),
            bead("cb-p4", "open", &["planned"], 2),
        ]);
        assert_eq!(
            standby_label("ux", &full, agent_of("ux"), at(0)),
            Some("\u{2192} agreed 4/4".to_string())
        );
        assert_eq!(
            standby_label("build-design", &full, agent_of("build-design"), at(0)),
            Some("\u{2192} planned 4/4".to_string())
        );

        // The combined role is untouched: a project runs it or these two, never both.
        assert_eq!(
            standby_label("planner", &two, agent_of("planner"), at(0)),
            Some("\u{2192} buffer<4".to_string())
        );
    }

    /// Cut down by cb-m0c: the two staged cells no longer read like the planner's, so what is
    /// left here is that each role is answered at all, in its own words.
    #[test]
    fn the_two_new_standby_cells_read_like_the_planners() {
        let facts = facts_for(
            vec![
                bead("cb-u1", "open", &[], 2),
                bead("cb-a1", "open", &["ux:agreed"], 2),
            ],
            &[],
        );
        assert_eq!(
            standby_label("ux", &facts, agent_of("ux"), at(0)),
            Some("\u{2192} agreed 1/2".to_string())
        );
        assert_eq!(
            standby_label("build-design", &facts, agent_of("build-design"), at(0)),
            Some("\u{2192} planned 0/2".to_string())
        );
        assert_eq!(
            standby_label("planner", &facts, agent_of("planner"), at(0)),
            Some("\u{2192} buffer<2".to_string())
        );
    }

    #[test]
    fn neither_new_role_waits_out_a_wake_interval() {
        assert_eq!(wake_interval("ux"), 0);
        assert_eq!(wake_interval("build-design"), 0);
        assert_eq!(default_spacing("ux"), Some(30));
        assert_eq!(default_spacing("build-design"), Some(30));
    }

    #[test]
    fn the_new_fingerprints_move_with_their_own_queues() {
        let one = facts_for(
            vec![],
            &[("ux", vec![("cb-u1", 2)]), ("build-design", vec![("cb-a1", 2)])],
        );
        let more_undesigned = facts_for(
            vec![],
            &[("ux", vec![("cb-u1", 2), ("cb-u2", 2)]), ("build-design", vec![("cb-a1", 2)])],
        );
        let more_agreed = facts_for(
            vec![],
            &[("ux", vec![("cb-u1", 2)]), ("build-design", vec![("cb-a1", 2), ("cb-a2", 2)])],
        );
        assert_ne!(fingerprint("ux", &one), fingerprint("ux", &more_undesigned));
        assert_ne!(
            fingerprint("build-design", &one),
            fingerprint("build-design", &more_agreed)
        );
        assert!(fingerprint("ux", &one).is_some());
        assert!(fingerprint("build-design", &one).is_some());
    }

    #[test]
    fn a_returned_ux_bead_breaks_the_unchanged_work_guard() {
        let queue = || vec![("ux", vec![("cb-u1", 2), ("cb-u2", 2)])];
        let mut first_bead = bead("cb-u1", "open", &[], 2);
        first_bead.updated_at = Some(at(0));
        let mut second_bead = bead("cb-u2", "open", &[], 2);
        second_bead.updated_at = Some(at(0));
        let first = facts_for(vec![first_bead, second_bead], &queue());
        let first_print = fingerprint("ux", &first).expect("the UX fingerprint exists");
        let completed_pass = AgentFacts {
            role: "ux",
            started_at: Some(at(0)),
            ended_at: Some(at(1)),
            last_fingerprint: Some(&first_print),
        };

        assert_eq!(
            trigger(&first, completed_pass, at(2)),
            None,
            "the unchanged candidate revisions retain the no-repeat guard"
        );

        let mut returned_bead = bead("cb-u2", "open", &[], 2);
        returned_bead.updated_at = Some(at(2));
        let returned = facts_for(
            vec![
                {
                    let mut bead = bead("cb-u1", "open", &[], 2);
                    bead.updated_at = Some(at(0));
                    bead
                },
                returned_bead,
            ],
            &queue(),
        );
        assert_eq!(
            trigger(&returned, completed_pass, at(3)),
            Some("UX 0 of 2".to_string()),
            "a newer revision makes the returned UX queue eligible again"
        );
    }

    fn assignable_facts(assignable: &[&str], spoken: &[&str]) -> TriggerFacts {
        let buckets = WorkBuckets {
            assignable: assignable.iter().map(|id| id.to_string()).collect(),
            implementer_assignable: assignable.iter().map(|id| id.to_string()).collect(),
            ..WorkBuckets::default()
        };
        TriggerFacts::derive(
            &buckets,
            &roster(&[("Cyclops", "implementer")]),
            &spoken.iter().map(|id| id.to_string()).collect(),
            |_| false,
            GhAnswer::Unanswered,
            1,
        )
    }

    #[test]
    fn an_implementer_starts_only_for_a_bead_nobody_holds() {
        let one = assignable_facts(&["cb-a", "cb-b"], &["cb-a"]);
        assert_eq!(
            condition(&one, &agent_of("implementer")),
            Some("1 planned, unclaimed".to_string())
        );
        assert_eq!(next_bead(&one), Some("cb-b"));

        let none = assignable_facts(&["cb-a", "cb-b"], &["cb-a", "cb-b"]);
        assert_eq!(condition(&none, &agent_of("implementer")), None);
        assert_eq!(next_bead(&none), None);
        assert_eq!(
            standby_label("implementer", &none, agent_of("implementer"), at(0)).as_deref(),
            Some("\u{2192} planned")
        );
    }

    #[test]
    fn taking_a_bead_removes_it_for_the_rest_of_the_tick() {
        let mut facts = assignable_facts(&["cb-a", "cb-b"], &[]);
        facts.take("cb-a");
        assert_eq!(next_bead(&facts), Some("cb-b"));
        facts.take("cb-b");
        assert_eq!(next_bead(&facts), None);
        assert_eq!(condition(&facts, &agent_of("implementer")), None);
    }

    #[test]
    fn a_planning_role_is_given_its_first_ranked_candidate() {
        let list = || vec![("cb-4", 4), ("cb-2", 2), ("cb-3", 3)];
        let facts = facts_for(vec![], &[("build-design", list())]);
        assert_eq!(bead_for(&facts, "build-design"), Some("cb-2"));

        let mut buckets = WorkBuckets::default();
        buckets.candidates = cands(&[("build-design", list())]);
        let spoken: BTreeSet<String> = ["cb-2".to_string()].into_iter().collect();
        let roster = roster(&[("Iceman", "build-design")]);
        let without =
            TriggerFacts::derive(&buckets, &roster, &spoken, |_| false, GhAnswer::Unanswered, 1);
        assert_eq!(bead_for(&without, "build-design"), Some("cb-3"));

        let only_p4 = facts_for(vec![], &[("build-design", vec![("cb-4", 4)])]);
        assert_eq!(bead_for(&only_p4, "build-design"), None);
        assert_eq!(condition(&only_p4, &agent_of("build-design")), None);

        let mut unranked = facts_for(vec![], &[("build-design", vec![("cb-n", 2), ("cb-m", 2)])]);
        unranked.planning_candidates.get_mut("build-design").unwrap()[0].priority = None;
        assert_eq!(bead_for(&unranked, "build-design"), Some("cb-m"), "an unranked candidate is skipped");

        assert_eq!(bead_for(&facts, "verifier"), None);
        for role in ["planner", "ux", "build-design", "implementer"] {
            assert!(hands_a_bead(role), "{role} is handed a bead");
        }
        assert!(!hands_a_bead("verifier"));
    }

    #[test]
    fn a_p0_candidate_fires_whatever_the_buffer() {
        let mut facts =
            facts_for(vec![], &[("planner", vec![("cb-z", 0)]), ("ux", vec![("cb-z", 0)])]);
        facts.planned = facts.planner_want();
        facts.ux_agreed = facts.planner_want();
        assert_eq!(condition(&facts, &agent_of("planner")), Some("P0 cb-z unplanned".to_string()));
        assert_eq!(condition(&facts, &agent_of("ux")), Some("P0 cb-z unplanned".to_string()));
        assert_eq!(facts.p0_unplanned, vec!["cb-z".to_string()], "one id, seen in two queues");
    }

    #[test]
    fn the_buffer_arm_needs_a_candidate() {
        let none = facts_for(vec![], &[("build-design", vec![])]);
        assert_eq!(none.planned, 0);
        assert_eq!(condition(&none, &agent_of("build-design")), None);

        let one = facts_for(vec![], &[("build-design", vec![("cb-b", 2)]), ("ux", vec![("cb-u", 2)])]);
        assert_eq!(condition(&one, &agent_of("build-design")), Some("buffer 0 of 2".to_string()));
        assert_eq!(condition(&one, &agent_of("ux")), Some("UX 0 of 2".to_string()));

        // A role the reader was not asked about has nothing to hand and starts nothing.
        assert_eq!(condition(&facts_for(vec![], &[]), &agent_of("planner")), None);
    }

    #[test]
    fn taking_a_bead_removes_it_from_every_queue() {
        let mut facts = facts_for(
            vec![],
            &[("planner", vec![("cb-a", 2), ("cb-b", 2)]), ("ux", vec![("cb-a", 2)])],
        );
        facts.take("cb-a");
        assert_eq!(bead_for(&facts, "planner"), Some("cb-b"));
        assert_eq!(bead_for(&facts, "ux"), None);
    }

    #[test]
    fn standby_cells_no_longer_read_zero_free() {
        let facts = facts_for(vec![], &[]);
        let cell = |role: &'static str| standby_label(role, &facts, agent_of(role), at(0));
        assert_eq!(cell("planner").as_deref(), Some("\u{2192} buffer<2"));
        assert_eq!(cell("ux").as_deref(), Some("\u{2192} agreed 0/2"));
        assert_eq!(cell("build-design").as_deref(), Some("\u{2192} planned 0/2"));
    }

    #[test]
    fn spoken_for_is_row_beads_handed_and_releasing() {
        let rows = vec![
            row("Cyclops", "implementer", RowState::Working, Some("cb-1")),
            row("Storm", "implementer", RowState::Standby, None),
        ];
        let handed: BTreeMap<String, String> =
            [("Storm".to_string(), "cb-2".to_string())].into_iter().collect();
        let releasing: BTreeMap<String, crate::model::Releasing> = [(
            "Rogue".to_string(),
            crate::model::Releasing {
                bead: "cb-3".to_string(),
                failed_at: None,
                cause: crate::lifecycle::GiveBack::DidNotStart,
            },
        )]
        .into_iter()
        .collect();
        let spoken: Vec<String> = spoken_for(&rows, &handed, &releasing).into_iter().collect();
        assert_eq!(spoken, ["cb-1", "cb-2", "cb-3"]);
    }

    fn bead(id: &str, status: &str, labels: &[&str], priority: u8) -> Bead {
        Bead {
            id: id.into(),
            title: id.into(),
            status: status.into(),
            issue_type: "task".into(),
            labels: labels.iter().map(|l| (*l).to_string()).collect(),
            priority: Some(priority),
            updated_at: None,
            assignee: None,
            metadata: serde_json::Value::Null,
            external_ref: None,
        }
    }

    fn typed_bead(
        id: &str,
        status: &str,
        issue_type: &str,
        labels: &[&str],
        priority: u8,
    ) -> Bead {
        Bead {
            issue_type: issue_type.into(),
            ..bead(id, status, labels, priority)
        }
    }

    fn roster(names: &[(&str, &str)]) -> Vec<RosterEntry> {
        names
            .iter()
            .map(|(name, role)| RosterEntry {
                name: (*name).to_string(),
                role: (*role).to_string(),
                kind: if *role == "implementer" {
                    AgentKind::Implementer
                } else {
                    AgentKind::Interactive
                },
            })
            .collect()
    }

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_767_225_600 + seconds, 0).expect("a valid timestamp")
    }

    #[test]
    fn facts_are_derived_from_the_buckets_the_work_reader_gives() {
        let mut buckets = crate::model::partition_beads(vec![
            bead("cb-9zz", "open", &[], 0),
            bead("cb-decl", "open", &["triage:declined"], 4),
            bead("cb-rank", "open", &[], 4),
            bead("cb-park", "open", &["human"], 2),
            bead("cb-stale", "open", &["human", "verdict:stale"], 0),
            bead("cb-p1", "open", &["planned"], 2),
            bead("cb-p2", "open", &["planned"], 2),
            bead("cb-done", "closed", &[], 2),
        ]);
        let roster = roster(&[
            ("Xavier", "planner"),
            ("Cyclops", "implementer"),
            ("Rogue", "implementer"),
            ("Storm", "implementer"),
        ]);
        buckets.candidates = cands(&[("planner", vec![("cb-9zz", 0)])]);
        // Storm has been told to finish: it takes no further bead, so it is not counted.
        let facts = TriggerFacts::derive(&buckets, &roster, &std::collections::BTreeSet::new(), |name| name == "Storm", GhAnswer::Unanswered, 1);

        assert_eq!(facts.p0_unplanned, vec!["cb-9zz".to_string()]);
        assert_eq!(facts.planned, 2);
        // What a planner may take is the candidate script's list, carried as it came.
        assert_eq!(
            facts.planning_candidates["planner"],
            vec![Candidate { id: "cb-9zz".into(), priority: Some(0) }]
        );
        assert_eq!(
            facts.planned_ids,
            vec!["cb-p1".to_string(), "cb-p2".to_string()]
        );
        assert_eq!(facts.unranked_ids, vec!["cb-rank".to_string()]);
        assert_eq!(facts.merged_unverified, 1);
        // A paused bead carrying `verdict:stale` is still a stale verdict.
        assert_eq!(facts.stale_verdicts, 1);
        assert_eq!(facts.second_look, 0);
        assert_eq!(facts.implementers, 2);
        assert_eq!(facts.planner_want(), 2);
    }

    #[test]
    fn an_eligible_closed_epic_counts_as_merged_unverified() {
        let buckets = crate::model::partition_beads(vec![
            typed_bead("cb-ep", "closed", "epic", &[], 2),
            typed_bead("cb-ep.1", "closed", "feature", &["verification:passed"], 2),
        ]);
        let facts = TriggerFacts::derive(
            &buckets,
            &roster(&[("Psylocke", "verifier")]),
            &std::collections::BTreeSet::new(),
            |_| false,
            GhAnswer::Unanswered,
            1,
        );
        assert_eq!(facts.merged_unverified, 1);
        assert_eq!(
            trigger(&facts, agent_of("verifier"), at(0)),
            Some("1 merged, unverified".to_string())
        );
    }

    /// Ranking a bead is what Cerebro does when the fleet view wakes it, and it has to be able to
    /// wake a planner. Before cb-zgg the fingerprint carried every unplanned bead's id alone, so a P4 -> P2
    /// ranking left the whole planner fingerprint identical and the unchanged-work guard held the
    /// start - observed holding for 45 minutes over one ranked bead.
    #[test]
    fn ranking_a_bead_moves_the_planner_fingerprint() {
        let unranked = facts_for(vec![], &[("planner", vec![("cb-agg", 4)])]);
        let ranked = facts_for(vec![], &[("planner", vec![("cb-agg", 2)])]);

        // Unranked: nothing a planner may be given, so the buffer rule does not fire at all.
        assert_eq!(bead_for(&unranked, "planner"), None);
        assert_eq!(bead_for(&ranked, "planner"), Some("cb-agg"));
        assert_ne!(
            fingerprint("planner", &unranked),
            fingerprint("planner", &ranked)
        );
    }

    /// The unranked rule, extracted so the triage path and `TriggerFacts::derive` cannot drift
    /// (cb-kcs.5.2): one set, one sort, one definition of "parked".
    #[test]
    fn unranked_ids_are_the_unplanned_p4s_sorted() {
        let buckets = partition_beads(vec![
            bead("cb-z4", "open", &[], 4),
            bead("cb-a4", "open", &[], 4),
            bead("cb-parked", "open", &["triage:declined"], 4),
            bead("cb-human", "open", &["human"], 4),
            bead("cb-p1", "open", &[], 1),
            bead("cb-planned4", "open", &["planned"], 4),
        ]);
        assert_eq!(unranked_ids(&buckets), vec!["cb-a4".to_string(), "cb-z4".to_string()]);
    }

    #[test]
    fn the_buffer_is_one_per_implementer_and_never_fewer_than_the_floor() {
        let mut facts = empty_facts();
        facts.implementers = 0;
        assert_eq!(facts.planner_want(), PLANNER_BUFFER_FLOOR);
        facts.implementers = 4;
        assert_eq!(facts.planner_want(), 4);
    }

    #[test]
    fn a_declared_multiple_scales_the_buffer() {
        let mut facts = empty_facts();
        facts.planner_multiple = 2;
        facts.implementers = 4;
        assert_eq!(facts.planner_want(), 8);
        facts.implementers = 0;
        assert_eq!(facts.planner_want(), PLANNER_BUFFER_FLOOR);
        facts.planner_multiple = 1;
        facts.implementers = 4;
        assert_eq!(facts.planner_want(), 4);
        // An absurd declaration saturates rather than wrapping below the floor.
        facts.planner_multiple = usize::MAX;
        facts.implementers = 2;
        assert_eq!(facts.planner_want(), usize::MAX);
    }

    #[test]
    fn a_planner_multiple_is_a_whole_number_above_zero() {
        assert_eq!(parse_planner_multiple("1"), Ok(Some(1)));
        assert_eq!(parse_planner_multiple("  3  "), Ok(Some(3)));
        assert_eq!(parse_planner_multiple("01"), Ok(Some(1)));
        assert_eq!(parse_planner_multiple(""), Ok(None));
        assert_eq!(parse_planner_multiple("   "), Ok(None));
        // Zero is refused rather than taken at face value: it would pin the
        // wanted number to the floor for ever.
        assert_eq!(parse_planner_multiple("0"), Err("0".to_string()));
        assert_eq!(parse_planner_multiple("-1"), Err("-1".to_string()));
        assert_eq!(parse_planner_multiple("1.5"), Err("1.5".to_string()));
        assert_eq!(parse_planner_multiple("2x"), Err("2x".to_string()));
    }

    fn empty_facts() -> TriggerFacts {
        TriggerFacts {
            p0_unplanned: Vec::new(),
            undesigned_revisions: Vec::new(),
            planning_candidates: BTreeMap::new(),
            ux_agreed: 0,
            planned: 0,
            planned_ids: Vec::new(),
            planned_revisions: Vec::new(),
            assignable_ids: Vec::new(),
            implementer_assignable_ids: Vec::new(),
            bugfixable_ids: Vec::new(),
            unranked_ids: Vec::new(),
            merged_unverified: 0,
            stale_verdicts: 0,
            second_look: 0,
            implementers: 4,
            planner_multiple: 1,
            gh: GhAnswer::Unanswered,
            linked: Vec::new(),
        }
    }

    fn agent(role: &'static str) -> AgentFacts<'static> {
        AgentFacts { role, ended_at: None, started_at: None, last_fingerprint: None }
    }

    #[test]
    fn every_role_answers_its_own_condition() {
        let mut p0 = empty_facts();
        p0.p0_unplanned = vec!["cb-9zz".into()];
        p0.planning_candidates = cands(&[("planner", vec![("cb-9zz", 0)])]);
        assert_eq!(
            trigger(&p0, agent("planner"), at(0)),
            Some("P0 cb-9zz unplanned".to_string())
        );

        let mut buffer = empty_facts();
        buffer.planned = 2;
        buffer.planning_candidates = cands(&[("planner", vec![("cb-a", 2)])]);
        assert_eq!(
            trigger(&buffer, agent("planner"), at(0)),
            Some("buffer 2 of 4".to_string())
        );

        // A short buffer is a reason to plan only while there is something to plan.
        let mut nothing_to_plan = buffer.clone();
        nothing_to_plan.planning_candidates.clear();
        assert_eq!(trigger(&nothing_to_plan, agent("planner"), at(0)), None);

        let mut stale = empty_facts();
        stale.stale_verdicts = 1;
        stale.merged_unverified = 2;
        assert_eq!(
            trigger(&stale, agent("verifier"), at(0)),
            Some("1 stale verdict".to_string())
        );
        stale.stale_verdicts = 2;
        assert_eq!(
            trigger(&stale, agent("verifier"), at(0)),
            Some("2 stale verdicts".to_string())
        );
        stale.stale_verdicts = 0;
        stale.second_look = 1;
        assert_eq!(
            trigger(&stale, agent("verifier"), at(0)),
            Some("1 needs second look".to_string())
        );
        stale.second_look = 2;
        assert_eq!(
            trigger(&stale, agent("verifier"), at(0)),
            Some("2 need second look".to_string())
        );
        stale.second_look = 0;
        assert_eq!(
            trigger(&stale, agent("verifier"), at(0)),
            Some("2 merged, unverified".to_string())
        );

        let mut planned = empty_facts();
        planned.assignable_ids = vec!["cb-a".into(), "cb-b".into(), "cb-c".into()];
        planned.implementer_assignable_ids = vec!["cb-p".into()];
        assert_eq!(
            trigger(&planned, agent("implementer"), at(0)),
            Some("1 planned, unclaimed".to_string())
        );
        assert_eq!(
            trigger(&planned, agent("producer"), at(0)),
            Some("3 UX-agreed, unclaimed".to_string())
        );

        let mut unranked = empty_facts();
        unranked.unranked_ids = vec!["cb-a".into(), "cb-b".into(), "cb-c".into(), "cb-d".into()];
        assert_eq!(
            trigger(&unranked, agent("orchestrator"), at(0)),
            Some("4 unranked".to_string())
        );

        // The three GitHub-backed roles are cb-kcs.4.3's, and are not armed at all until then.
        for role in ["user-feedback", "reviewer", "architect"] {
            assert_eq!(trigger(&unranked, agent(role), at(0)), None, "{role}");
        }

        // The floor, first and for every role.
        let verifier_just_started = AgentFacts { started_at: Some(at(0)), ..agent("verifier") };
        stale.stale_verdicts = 1;
        assert_eq!(
            trigger(&stale, AgentFacts { started_at: Some(at(0)), ..verifier_just_started }, at(299)),
            None
        );
        assert_eq!(
            trigger(&stale, verifier_just_started, at(300)),
            Some("1 stale verdict".to_string())
        );
        // The planners and the implementers have no floor: a short buffer is the fleet idle.
        assert_eq!(
            trigger(&planned, AgentFacts { started_at: Some(at(0)), ..agent("implementer") }, at(1)),
            Some("1 planned, unclaimed".to_string())
        );
    }

    #[test]
    fn the_start_notice_is_the_triggers_own_phrase() {
        assert_eq!(
            start_notice("Beast", "buffer 2 of 4"),
            "Started Beast — buffer 2 of 4."
        );
    }

    #[test]
    fn a_pass_that_changed_nothing_does_not_start_another() {
        let mut facts = empty_facts();
        facts.planned_ids = vec!["cb-a".into()];
        facts.assignable_ids = vec!["cb-a".into()];
        facts.implementer_assignable_ids = vec!["cb-a".into()];
        let print = fingerprint("implementer", &facts).expect("an implementer has one");
        let held = AgentFacts {
            role: "implementer",
            started_at: Some(at(0)),
            ended_at: Some(at(60)),
            last_fingerprint: Some(&print),
        };
        assert_eq!(trigger(&facts, held, at(120)), None);

        // One more planned bead is work the last pass did not see.
        let mut moved = facts.clone();
        moved.planned_ids.push("cb-b".into());
        moved.implementer_assignable_ids.push("cb-b".into());
        assert_eq!(
            trigger(&moved, held, at(120)),
            Some("2 planned, unclaimed".to_string())
        );
    }

    #[test]
    fn a_launch_that_never_became_a_pass_is_not_held() {
        let mut facts = empty_facts();
        facts.planned_ids = vec!["cb-a".into()];
        facts.assignable_ids = vec!["cb-a".into()];
        facts.implementer_assignable_ids = vec!["cb-a".into()];
        let print = fingerprint("implementer", &facts).expect("an implementer has one");
        // Started, and no end recorded after it: the launch died before it became a pass.
        let never_ran = AgentFacts {
            role: "implementer",
            started_at: Some(at(60)),
            ended_at: Some(at(10)),
            last_fingerprint: Some(&print),
        };
        assert_eq!(
            trigger(&facts, never_ran, at(120)),
            Some("1 planned, unclaimed".to_string())
        );
        // And a role this view has never started has no fingerprint to be held by.
        assert_eq!(
            trigger(&facts, agent("implementer"), at(120)),
            Some("1 planned, unclaimed".to_string())
        );
    }

    #[test]
    fn a_replanned_bead_under_the_same_id_breaks_the_implementer_guard() {
        let mut before = empty_facts();
        before.planned_ids = vec!["cb-a".into()];
        before.assignable_ids = vec!["cb-a".into()];
        before.implementer_assignable_ids = vec!["cb-a".into()];
        before.planned_revisions = vec![("cb-a".into(), Some(at(10)))];
        let print = fingerprint("implementer", &before).expect("an implementer has one");
        let held = AgentFacts {
            role: "implementer",
            started_at: Some(at(0)),
            ended_at: Some(at(60)),
            last_fingerprint: Some(&print),
        };

        let mut after = before.clone();
        after.planned_revisions = vec![("cb-a".into(), Some(at(120)))];
        assert_eq!(
            trigger(&after, held, at(180)),
            Some("1 planned, unclaimed".to_string())
        );
    }

    #[test]
    fn a_newly_agreed_bead_breaks_the_producer_guard() {
        let mut before = empty_facts();
        before.assignable_ids = vec!["cb-a".into()];
        let print = fingerprint("producer", &before).expect("a producer has one");
        let held = AgentFacts {
            role: "producer",
            started_at: Some(at(0)),
            ended_at: Some(at(60)),
            last_fingerprint: Some(&print),
        };

        let mut after = before.clone();
        after.assignable_ids.push("cb-b".into());
        assert_eq!(
            trigger(&after, held, at(120)),
            Some("2 UX-agreed, unclaimed".to_string())
        );
    }

    #[test]
    fn the_cadence_roles_have_no_fingerprint_to_be_held_by() {
        let facts = empty_facts();
        for role in ["user-feedback", "reviewer", "architect"] {
            assert_eq!(fingerprint(role, &facts), None, "{role}");
        }
        assert!(fingerprint("planner", &facts).is_some());
        // Not a cadence role: its unverified beads are reason enough on their own (cb-6ey's reason, in the doc on Fingerprint).
        assert_eq!(fingerprint("verifier", &facts), None);
        assert!(fingerprint("orchestrator", &facts).is_some());
    }

    fn verifier_after_pass<'a>(ledger: &'a StartLedger) -> AgentFacts<'a> {
        AgentFacts {
            role: "verifier",
            started_at: ledger.started_at("Psylocke"),
            ended_at: ledger.ended_at("Psylocke"),
            last_fingerprint: ledger.fingerprint("Psylocke"),
        }
    }

    #[test]
    fn a_verifier_pass_that_left_beads_unverified_starts_another() {
        let mut facts = empty_facts();
        facts.merged_unverified = 24;
        let mut ledger = StartLedger::default();
        ledger.note_started("Psylocke", at(0), fingerprint("verifier", &facts));
        ledger.note_ended("Psylocke", at(2_280));
        let after = verifier_after_pass(&ledger);
        assert_eq!(trigger(&facts, after, at(2_310)), Some("24 merged, unverified".to_string()));
        assert!(!held_by_unchanged_work(&facts, after));
    }

    #[test]
    fn a_verifier_pass_that_left_stale_verdicts_starts_another() {
        let mut facts = empty_facts();
        facts.stale_verdicts = 1;
        let mut ledger = StartLedger::default();
        ledger.note_started("Psylocke", at(0), fingerprint("verifier", &facts));
        ledger.note_ended("Psylocke", at(2_280));
        let after = verifier_after_pass(&ledger);
        assert_eq!(trigger(&facts, after, at(2_310)), Some("1 stale verdict".to_string()));
    }

    #[test]
    fn a_verifier_pass_that_left_second_look_beads_starts_another() {
        let mut facts = empty_facts();
        facts.second_look = 1;
        let mut ledger = StartLedger::default();
        ledger.note_started("Psylocke", at(0), fingerprint("verifier", &facts));
        ledger.note_ended("Psylocke", at(2_280));
        let after = verifier_after_pass(&ledger);
        assert_eq!(trigger(&facts, after, at(2_310)), Some("1 needs second look".to_string()));
    }

    #[test]
    fn the_verifier_still_waits_out_its_wake_interval_after_a_short_pass() {
        let mut facts = empty_facts();
        facts.merged_unverified = 3;
        let mut ledger = StartLedger::default();
        ledger.note_started("Psylocke", at(0), fingerprint("verifier", &facts));
        ledger.note_ended("Psylocke", at(60));
        let after = verifier_after_pass(&ledger);
        assert_eq!(trigger(&facts, after, at(299)), None);
        assert_eq!(trigger(&facts, after, at(300)), Some("3 merged, unverified".to_string()));
    }

    #[test]
    fn the_standby_label_is_a_closed_vocabulary() {
        let mut facts = empty_facts();
        facts.planned_ids = vec!["cb-p".to_string()];
        let facts = facts;
        assert_eq!(standby_label("planner", &facts, agent("planner"), at(0)).as_deref(), Some("→ buffer<4"));
        assert_eq!(standby_label("implementer", &facts, agent("implementer"), at(0)).as_deref(), Some("→ planned"));
        assert_eq!(standby_label("verifier", &facts, agent("verifier"), at(0)).as_deref(), Some("→ merged"));
        assert_eq!(standby_label("orchestrator", &facts, agent("orchestrator"), at(0)).as_deref(), Some("→ unranked"));
        // A role this view has no rule for - a consumer's own word - has no cell at all, and
        // that arm is now the catch-all every role in existence falls through (review finding 4).
        assert_eq!(standby_label("stargazer", &facts, agent("stargazer"), at(0)), None);
        // Exactly `BEAD_FLOOR` cells at a four-implementer fleet.
        assert_eq!(
            unicode_width::UnicodeWidthStr::width(
                standby_label("planner", &facts, agent("planner"), at(0)).unwrap().as_str()
            ),
            10
        );
    }

    #[test]
    fn a_peer_started_inside_the_window_holds_the_second_start() {
        let fleet = roster(&[("Xavier", "planner"), ("Beast", "planner"), ("Rogue", "implementer")]);
        let peers = role_peers("Beast", "planner", &fleet);
        assert_eq!(peers, vec!["Xavier"]);
        // A role with one holder has no peers, which is what makes this answer "no" for every
        // role but the planners and the implementers without naming any of them.
        assert!(role_peers("Rogue", "implementer", &fleet).is_empty());

        let mut started = BTreeMap::new();
        started.insert("Xavier".to_string(), at(0));
        assert!(role_start_too_soon(&peers, &started, Some(30), at(10)));
        // Strictly less than: a peer started exactly `spacing` seconds ago is not too soon.
        assert!(!role_start_too_soon(&peers, &started, Some(30), at(30)));
        // A spacing of 0 is "never space this role", which falls out of the comparison.
        assert!(!role_start_too_soon(&peers, &started, Some(0), at(0)));
        assert!(!role_start_too_soon(&peers, &started, None, at(0)));
    }

    #[test]
    fn a_declared_spacing_beats_the_default_including_zero() {
        let mut declared = BTreeMap::new();
        assert_eq!(spacing_for("planner", &declared), Some(30));
        assert_eq!(spacing_for("implementer", &declared), Some(30));
        assert_eq!(spacing_for("verifier", &declared), None);
        declared.insert("planner".to_string(), 0);
        assert_eq!(spacing_for("planner", &declared), Some(0));
        declared.insert("verifier".to_string(), 90);
        assert_eq!(spacing_for("verifier", &declared), Some(90));
    }

    #[test]
    fn a_spacing_that_is_not_a_whole_number_of_seconds_is_a_third_answer() {
        assert_eq!(parse_spacing("30"), Ok(Some(30)));
        assert_eq!(parse_spacing("  30  "), Ok(Some(30)));
        assert_eq!(parse_spacing(""), Ok(None));
        assert_eq!(parse_spacing("   "), Ok(None));
        assert_eq!(parse_spacing("30s"), Err("30s".to_string()));
        assert_eq!(parse_spacing("4.5"), Err("4.5".to_string()));
        assert_eq!(parse_spacing("-1"), Err("-1".to_string()));
    }

    #[test]
    fn the_end_of_a_pass_is_the_park_or_the_last_sighting() {
        let mut ledger = StartLedger::default();
        assert_eq!(ledger.ended_at("Rogue"), None);
        ledger.note_seen_up("Rogue", at(100));
        assert_eq!(ledger.ended_at("Rogue"), Some(at(100)));
        ledger.note_ended("Rogue", at(200));
        ledger.note_seen_up("Rogue", at(300));
        // The park wins: it is the moment the view actually ended the pass.
        assert_eq!(ledger.ended_at("Rogue"), Some(at(200)));
    }

    #[test]
    fn arming_a_name_does_not_overwrite_a_real_park() {
        let mut ledger = StartLedger::default();
        ledger.note_ended("Xavier", at(100));
        ledger.note_armed("Xavier", at(500));
        assert_eq!(ledger.ended_at("Xavier"), Some(at(100)));

        let mut fresh = StartLedger::default();
        fresh.note_armed("Beast", at(500));
        assert_eq!(fresh.ended_at("Beast"), Some(at(500)));
        // Armed is not started.
        assert_eq!(fresh.started_at("Beast"), None);
    }

    #[test]
    fn the_failure_ledger_forgets_a_start_a_pass_has_survived() {
        // A pass that ran: the end is later than the start it followed.
        let mut ledger = StartLedger::default();
        ledger.set_failures("Xavier", 3);
        ledger.note_started("Xavier", at(100), None);
        ledger.note_ended("Xavier", at(160));
        assert_eq!(ledger.failures("Xavier"), 0);

        // A launch that never became a session leaves the PREVIOUS pass's end behind it.
        let mut stale = StartLedger::default();
        stale.set_failures("Xavier", 3);
        stale.note_started("Xavier", at(100), None);
        stale.note_ended("Xavier", at(40));
        assert_eq!(stale.failures("Xavier"), 3);

        // A name this view never started keeps whatever count it was given.
        let mut unstarted = StartLedger::default();
        unstarted.set_failures("Xavier", 3);
        unstarted.note_ended("Xavier", at(160));
        assert_eq!(unstarted.failures("Xavier"), 3);

        // `note_seen_up` is the fallback end, and clears the same way.
        let mut seen = StartLedger::default();
        seen.set_failures("Storm", 2);
        seen.note_started("Storm", at(100), None);
        seen.note_seen_up("Storm", at(160));
        assert_eq!(seen.failures("Storm"), 0);
    }

    #[test]
    fn a_start_is_recorded_with_what_triggered_it() {
        let mut facts = empty_facts();
        facts.planned_ids = vec!["cb-a".into()];
        let mut ledger = StartLedger::default();
        ledger.note_started("Rogue", at(10), fingerprint("implementer", &facts));
        assert_eq!(ledger.started_at("Rogue"), Some(at(10)));
        assert_eq!(ledger.fingerprint("Rogue"), fingerprint("implementer", &facts).as_ref());
        assert_eq!(ledger.started_at_map().get("Rogue"), Some(&at(10)));
    }

    // --- cb-kcs.4.3: the outside roles ---------------------------------------------------------

    fn at_iso(iso: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(iso).unwrap().with_timezone(&Utc)
    }

    fn issue(number: u64, updated: Option<&str>) -> GhIssue {
        GhIssue { number, updated_at: updated.map(at_iso) }
    }

    fn pull(number: u64, updated: Option<&str>, draft: bool, login: Option<&str>) -> GhPull {
        GhPull {
            number,
            updated_at: updated.map(at_iso),
            is_draft: draft,
            author: Some(GhAuthor { login: login.map(str::to_string) }),
        }
    }

    fn snapshot() -> GhSnapshot {
        GhSnapshot {
            issues: vec![
                issue(212, Some("2026-09-01T11:00:00Z")),
                issue(213, Some("2026-09-01T09:00:00Z")),
                issue(214, None),
            ],
            prs: vec![
                pull(244, Some("2026-09-01T11:00:00Z"), false, Some("someone")),
                pull(245, Some("2026-09-01T11:00:00Z"), true, Some("someone")),
                pull(246, Some("2026-09-01T11:00:00Z"), false, Some("navigator")),
                pull(247, Some("2026-09-01T09:00:00Z"), false, Some("someone")),
            ],
            me: Some("navigator".into()),
        }
    }

    fn planner_facts(planned: usize, implementers: usize) -> TriggerFacts {
        TriggerFacts {
            planned,
            planning_candidates: cands(&[("planner", vec![("cb-1", 2)])]),
            planned_ids: vec!["cb-2".to_string()],
            implementers,
            ..empty_facts()
        }
    }

    #[test]
    fn what_moved_is_measured_against_this_roles_own_pass() {
        let snap = snapshot();
        let ended = Some(at_iso("2026-09-01T10:00:00Z"));
        assert_eq!(gh_moved(&snap, ended), (vec![212], vec![244]));
        assert_eq!(
            gh_moved(&snap, None),
            (Vec::new(), Vec::new()),
            "no end to measure against is nothing moved, in both lists (cb-b4m)"
        );
        let anonymous = GhSnapshot { me: None, ..snapshot() };
        assert_eq!(
            gh_moved(&anonymous, ended),
            (vec![212], Vec::new()),
            "an unknown login excludes every pull request and no issue"
        );
    }

    #[test]
    fn a_linked_bead_that_moved_is_moira_s_too() {
        let linked = vec![
            LinkedBead { id: "cb-3qh".into(), issue: 58, updated_at: at_iso("2026-09-01T11:00:00Z") },
            LinkedBead { id: "cb-old".into(), issue: 59, updated_at: at_iso("2026-09-01T09:00:00Z") },
        ];
        let moved = linked_moved(&linked, Some(at_iso("2026-09-01T10:00:00Z")));
        assert_eq!(moved.len(), 1);
        assert_eq!(moved[0].id, "cb-3qh");
        assert!(linked_moved(&linked, None).is_empty());
    }

    #[test]
    fn the_cadence_figure_counts_in_minutes_under_a_day() {
        assert_eq!(cadence_figure(3600), "60m");
        assert_eq!(cadence_figure(86399), "1439m");
        assert_eq!(cadence_figure(86400), "24h");
        assert_eq!(cadence("user-feedback"), Some(3600));
        assert_eq!(cadence("reviewer"), Some(3600));
        assert_eq!(cadence("architect"), Some(3600));
        assert_eq!(cadence("planner"), None);
        assert_eq!(cadence_noun("architect"), "sweep");
        assert_eq!(cadence_noun("user-feedback"), "pass");
    }

    #[test]
    fn the_countdown_is_spaced_like_the_conditions() {
        assert_eq!(countdown(2580), "→ 43m");
        assert_eq!(countdown(75840), "→ 21h04");
        assert_eq!(countdown(0), "→ due");
        assert_eq!(countdown(-5), "→ due");
    }

    fn cadence_facts(gh: GhAnswer) -> TriggerFacts {
        let mut facts = TriggerFacts::derive(&WorkBuckets::default(), &[], &std::collections::BTreeSet::new(), |_| false, gh, 1);
        facts.linked = Vec::new();
        facts
    }

    #[test]
    fn a_cadence_row_counts_down_and_says_when_gh_is_down() {
        let now = at_iso("2026-09-01T12:00:00Z");
        let ended = at_iso("2026-09-01T11:43:00Z"); // 17 minutes ago: 43 to the hourly floor
        for role in ["user-feedback", "reviewer", "architect"] {
            let gh_role = role != "architect";
            for (answer, suffix) in [
                (GhAnswer::Answered(snapshot()), ""),
                (GhAnswer::Unanswered, ""),
                (GhAnswer::Failed, if gh_role { " gh?" } else { "" }),
            ] {
                let facts = cadence_facts(answer);
                let agent = AgentFacts {
                    role,
                    ended_at: Some(ended),
                    started_at: None,
                    last_fingerprint: None,
                };
                assert_eq!(
                    standby_label(role, &facts, agent, now).as_deref(),
                    Some(format!("→ 43m{suffix}").as_str()),
                    "{role} with an end counts down"
                );
                let unknown = AgentFacts { ended_at: None, ..agent };
                assert_eq!(
                    standby_label(role, &facts, unknown, now).as_deref(),
                    Some(format!("→ hourly{suffix}").as_str()),
                    "{role} with no end names its floor"
                );
            }
        }
    }

    fn outside_facts(gh: GhAnswer, linked: Vec<LinkedBead>) -> TriggerFacts {
        let mut facts = cadence_facts(gh);
        facts.linked = linked;
        facts
    }

    #[test]
    fn the_widest_cadence_cell_is_wider_than_the_bead_floor() {
        // The plan's one thing to check rather than assume: the widest cadence cell is wider
        // than a `BEAD_FLOOR` of ten, and it is the COLUMN that grows (review finding 5). The
        // plan and the review both said thirteen cells; it is twelve - `→`, a space, six, a
        // space, three - which is why this is a measurement rather than a sentence.
        let facts = cadence_facts(GhAnswer::Failed);
        let agent = AgentFacts {
            role: "user-feedback",
            ended_at: None,
            started_at: None,
            last_fingerprint: None,
        };
        let cell = standby_label("user-feedback", &facts, agent, at_iso("2026-09-01T12:00:00Z"))
            .expect("a cadence role always has a cell");
        assert_eq!(cell, "→ hourly gh?");
        assert_eq!(unicode_width::UnicodeWidthStr::width(cell.as_str()), 12);
    }

    #[test]
    fn the_outside_roles_answer_their_own_condition() {
        let now = at_iso("2026-09-01T12:00:00Z");
        let ended = at_iso("2026-09-01T10:30:00Z");
        let linked = vec![LinkedBead {
            id: "cb-3qh".into(),
            issue: 58,
            updated_at: at_iso("2026-09-01T11:45:00Z"),
        }];
        let row = |role| AgentFacts {
            role,
            ended_at: Some(ended),
            started_at: None,
            last_fingerprint: None,
        };

        let facts = outside_facts(GhAnswer::Answered(snapshot()), linked.clone());
        assert_eq!(
            trigger(&facts, row("user-feedback"), now).as_deref(),
            Some("issue #212 moved"),
            "an issue is a person waiting, and comes first"
        );
        assert_eq!(
            trigger(&facts, row("reviewer"), now).as_deref(),
            Some("PR #244 moved")
        );
        let fresh_forge = AgentFacts {
            role: "architect",
            ended_at: Some(at_iso("2026-09-01T11:30:00Z")),
            started_at: None,
            last_fingerprint: None,
        };
        assert_eq!(
            trigger(&facts, fresh_forge, now),
            None,
            "Forge has no condition: an issue and a pull request are nothing to it"
        );

        // gh down, so only the linked ledger is left of Moira's trigger.
        let blind = outside_facts(GhAnswer::Failed, linked);
        assert_eq!(
            trigger(&blind, row("user-feedback"), now).as_deref(),
            Some("bead cb-3qh moved (issue #58)")
        );
        let fresh_cypher = AgentFacts {
            role: "reviewer",
            ended_at: Some(at_iso("2026-09-01T11:30:00Z")),
            started_at: None,
            last_fingerprint: None,
        };
        assert_eq!(
            trigger(&blind, fresh_cypher, now),
            None,
            "a gh that failed leaves Cypher nothing but his floor"
        );

        // Nothing moved at all, and the floor not yet due: no start.
        let quiet = outside_facts(GhAnswer::Failed, Vec::new());
        let recent = AgentFacts {
            role: "user-feedback",
            ended_at: Some(at_iso("2026-09-01T11:30:00Z")),
            started_at: None,
            last_fingerprint: None,
        };
        assert_eq!(trigger(&quiet, recent, now), None);
        let due = |role| AgentFacts {
            role,
            ended_at: Some(at_iso("2026-09-01T11:00:00Z")),
            started_at: None,
            last_fingerprint: None,
        };
        assert_eq!(
            trigger(&quiet, due("architect"), now).as_deref(),
            Some("60m since its last sweep")
        );
        assert_eq!(
            trigger(&quiet, due("user-feedback"), now).as_deref(),
            Some("60m since its last pass")
        );
        assert_eq!(
            trigger(&quiet, due("reviewer"), now).as_deref(),
            Some("60m since its last pass")
        );
    }

    #[test]
    fn the_backoff_schedule_indexes_by_failures_before_the_start() {
        for (failures, wait) in [(0, 0), (1, 0), (2, 30), (3, 120), (4, 600), (9, 600)] {
            assert_eq!(retry_delay(failures), wait, "failures {failures}");
        }
    }

    #[test]
    fn a_wait_is_measured_from_the_failed_start() {
        // Never started: nothing to wait out.
        assert_eq!(retry_wait(3, None, at(0)), 0);
        // 120s owed from the start at 0, 30s gone.
        assert_eq!(retry_wait(3, Some(at(0)), at(30)), 90);
        // Already elapsed, and never negative.
        assert_eq!(retry_wait(3, Some(at(0)), at(600)), 0);
        // One failure waits nothing at all.
        assert_eq!(retry_wait(1, Some(at(0)), at(0)), 0);
    }

    #[test]
    fn a_retry_figure_never_names_a_smaller_wait_than_is_left() {
        for (seconds, figure) in [
            (0, "0s"),
            (45, "45s"),
            (59, "59s"),
            (60, "1m"),
            (61, "2m"),
            (600, "10m"),
        ] {
            assert_eq!(retry_figure(seconds), figure, "{seconds} seconds");
        }
    }

    #[test]
    fn a_start_that_left_no_end_after_it_failed() {
        // A pass that ran leaves an end later than its start.
        assert!(!start_failed(Some(at(0)), Some(at(10))));
        // An end at the same moment is the PREVIOUS pass's end: the start produced nothing.
        assert!(start_failed(Some(at(10)), Some(at(10))));
        assert!(start_failed(Some(at(10)), Some(at(5))));
        assert!(start_failed(Some(at(10)), None));
        // Never started here: not a failure of this view's.
        assert!(!start_failed(None, Some(at(5))));
        assert!(!start_failed(None, None));
    }

    #[test]
    fn five_in_a_row_is_where_it_stops() {
        assert!(!give_up(false, 9));
        assert!(!give_up(true, 3));
        assert!(give_up(true, 4));
        assert!(give_up(true, 7));
    }

    #[test]
    fn the_retry_cell_is_the_arrow_the_figure_and_the_count() {
        assert_eq!(retry_label(2, 30), "\u{21bb} retry in 30s, 2 failed");
        assert_eq!(retry_label(3, 120), "\u{21bb} retry in 2m, 3 failed");
        assert_eq!(retry_label(0, 30), "\u{21bb} retry in 30s");
    }

    #[test]
    fn a_backing_off_row_counts_down_ahead_of_its_condition() {
        // A full buffer: the condition is false, and the countdown wins anyway.
        let facts = planner_facts(4, 4);
        assert_eq!(
            standby_cell("planner", &facts, agent("planner"), at(0), 3, 120).as_deref(),
            Some("\u{21bb} retry in 2m, 3 failed")
        );
        assert_eq!(
            standby_cell("planner", &facts, agent("planner"), at(0), 0, 0).as_deref(),
            standby_label("planner", &facts, agent("planner"), at(0)).as_deref()
        );
        assert_eq!(
            standby_cell("implementer", &facts, agent("implementer"), at(0), 0, 0).as_deref(),
            Some("\u{2192} planned")
        );
        // A cadence role backs off the same way, and its own cell is what the countdown replaces
        // (cb-kcs.4.3 gave every armable role a cell; a role this view has no rule for still has
        // none, and none is invented for it).
        assert_eq!(
            standby_cell("user-feedback", &facts, agent("user-feedback"), at(0), 3, 120).as_deref(),
            Some("\u{21bb} retry in 2m, 3 failed")
        );
        assert_eq!(
            standby_cell("user-feedback", &facts, agent("user-feedback"), at(0), 0, 0).as_deref(),
            Some("\u{2192} hourly")
        );
        assert_eq!(standby_cell("stargazer", &facts, agent("stargazer"), at(0), 3, 120), None);
    }

    #[test]
    fn the_give_up_notice_is_the_sentence_the_navigator_approved() {
        assert_eq!(
            give_up_notice("Xavier", 5),
            "Xavier: 5 starts produced no pass; the view has stopped trying."
        );
    }

    #[test]
    fn the_cadence_floor_is_not_held_by_the_unchanged_work_guard() {
        let now = at_iso("2026-09-01T12:00:00Z");
        let facts = outside_facts(GhAnswer::Failed, Vec::new());
        assert_eq!(fingerprint("architect", &facts), None, "and stays None");
        let agent = AgentFacts {
            role: "architect",
            ended_at: Some(at_iso("2026-09-01T11:00:00Z")),
            started_at: Some(at_iso("2026-09-01T10:00:00Z")),
            last_fingerprint: None,
        };
        assert_eq!(
            trigger(&facts, agent, now).as_deref(),
            Some("60m since its last sweep"),
            "a clock is not evidence about the fleet, so nothing holds it"
        );
    }

    #[test]
    fn the_cadence_floor_still_obeys_the_wake_interval() {
        let now = at_iso("2026-09-01T12:00:00Z");
        let facts = outside_facts(GhAnswer::Failed, Vec::new());
        let agent = AgentFacts {
            role: "architect",
            ended_at: Some(at_iso("2026-09-01T11:00:00Z")),
            started_at: Some(at_iso("2026-09-01T11:59:50Z")),
            last_fingerprint: None,
        };
        assert_eq!(trigger(&facts, agent, now), None, "started ten seconds ago");
    }

    #[test]
    fn the_ledger_counts_consecutive_failed_starts() {
        let mut ledger = StartLedger::default();
        assert_eq!(ledger.failures("Rogue"), 0);
        ledger.set_failures("Rogue", 3);
        assert_eq!(ledger.failures("Rogue"), 3);
        ledger.clear_failures("Rogue");
        assert_eq!(ledger.failures("Rogue"), 0);
    }

    #[test]
    fn clearing_a_count_leaves_the_start_and_end_alone() {
        let mut ledger = StartLedger::default();
        ledger.note_started("Rogue", at(10), None);
        ledger.note_ended("Rogue", at(20));
        ledger.set_failures("Rogue", 2);
        ledger.clear_failures("Rogue");
        assert_eq!(ledger.started_at("Rogue"), Some(at(10)));
        assert_eq!(ledger.ended_at("Rogue"), Some(at(20)));
    }
}
