//! Whether a role is due to be started, and what to say about it.
//!
//! Pure throughout: it reads no file, runs no program and asks no clock, exactly as `ui` does, so
//! its tests are literals. It is a module of its own rather than part of `lifecycle` because that
//! module's contract is "everything this crate *writes*" and this one writes nothing.


use std::collections::BTreeMap;

use chrono::{DateTime, Utc};

use crate::model::{AgentKind, RosterEntry, WorkBuckets};

/// `cerebro-wake-interval-default`: seconds a role is left alone between two STARTS of it, when
/// nothing more specific is declared.
pub const WAKE_INTERVAL_DEFAULT: i64 = 600;

/// `cerebro-planner-buffer-floor`. The shell owner of the whole rule is `scripts/planner-buffer`;
/// this is a third copy for the same reason the elisp one exists - the trigger runs once per
/// standby row per five-second tick and may not fork.
pub const PLANNER_BUFFER_FLOOR: usize = 2;

/// `cerebro-parked-labels`: a bead wearing one of these is the navigator's rather than a
/// planner's, and counting it starts a session to find nothing to do.
pub const PARKED_LABELS: [&str; 2] = ["human", "triage:declined"];

/// The label that parks a bead in front of the verifier (`cerebro--stale-verdict-p`).
pub const STALE_VERDICT_LABEL: &str = "verdict:stale";

/// `cerebro-wake-intervals`, keyed by ROLE.
///
/// A name-keyed override exists in elisp and is deliberately not ported: no consumer uses one,
/// and a table with one column is clearer than a two-level lookup nothing exercises. The planners
/// and the implementers are at 0 on purpose - a short buffer is the fleet already idle, and a
/// clock there costs ten minutes on every trigger a pass CAN clear.
pub fn wake_interval(role: &str) -> i64 {
    match role {
        "verifier" => 300,
        "planner" | "implementer" => 0,
        _ => WAKE_INTERVAL_DEFAULT,
    }
}

/// `cerebro-role-start-spacing`, the fallback for a role the project declares nothing about.
pub fn default_spacing(role: &str) -> Option<u64> {
    match role {
        "planner" | "implementer" => Some(30),
        _ => None,
    }
}

/// What every role's condition is judged against. The port of `cerebro--trigger-context`, less
/// the `gh` resolver and `linked` ledger, which are cb-kcs.4.3's.
///
/// Built from a `WorkBuckets` this view actually has. **There is no "the board has not answered"
/// value**: Emacs sets `planned` to `most-positive-fixnum` so that no rule can fire, and refusing
/// to build a `TriggerFacts` at all says the same thing without a sentinel.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TriggerFacts {
    /// Ids of unplanned, unparked beads at priority 0, in bucket order.
    pub p0_unplanned: Vec<String>,
    /// How many planned, unclaimed, unparked beads there are.
    pub planned: usize,
    /// Ids of every unplanned, unparked bead - what a planner may actually take.
    pub actionable_ids: Vec<String>,
    /// Ids of the planned, unclaimed, unparked beads - what an implementer may actually claim.
    pub planned_ids: Vec<String>,
    /// Ids of the unplanned, unparked beads at priority 4, sorted, so the same set in a different
    /// bucket order is the same set.
    pub unranked_ids: Vec<String>,
    /// Beads merged and not yet verified.
    pub merged_unverified: usize,
    /// Beads in any OPEN bucket - paused included - carrying `verdict:stale`. Paused included
    /// because a bead can carry `verdict:stale` and `human` at once, and a stale verdict does not
    /// stop being one because the navigator was asked something about the bead.
    pub stale_verdicts: usize,
    /// Implementers on the roster that have not been told to finish. State is deliberately not
    /// read: a builder between beads has no session (cb-1or.1), so `standby`, `dead`, `idle` and
    /// `working` all count.
    pub implementers: usize,
}

fn parked(labels: &[String]) -> bool {
    labels.iter().any(|l| PARKED_LABELS.contains(&l.as_str()))
}

fn stale(labels: &[String]) -> bool {
    labels.iter().any(|l| l == STALE_VERDICT_LABEL)
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
        flagged: impl Fn(&str) -> bool,
    ) -> Self {
        let unplanned: Vec<_> = buckets
            .unplanned
            .iter()
            .filter(|bead| !parked(&bead.labels))
            .collect();
        let planned: Vec<_> = buckets
            .planned
            .iter()
            .filter(|bead| !parked(&bead.labels))
            .collect();
        let mut unranked_ids: Vec<String> = unplanned
            .iter()
            .filter(|bead| bead.priority == Some(4))
            .map(|bead| bead.id.clone())
            .collect();
        unranked_ids.sort();
        let stale_verdicts = [
            &buckets.claimed,
            &buckets.planned,
            &buckets.being_planned,
            &buckets.unplanned,
            &buckets.paused,
        ]
        .into_iter()
        .flatten()
        .filter(|bead| stale(&bead.labels))
        .count();

        Self {
            p0_unplanned: unplanned
                .iter()
                .filter(|bead| bead.priority == Some(0))
                .map(|bead| bead.id.clone())
                .collect(),
            planned: planned.len(),
            actionable_ids: unplanned.iter().map(|bead| bead.id.clone()).collect(),
            planned_ids: planned.iter().map(|bead| bead.id.clone()).collect(),
            unranked_ids,
            merged_unverified: buckets.merged.len(),
            stale_verdicts,
            implementers: roster
                .iter()
                .filter(|entry| entry.kind == AgentKind::Implementer && !flagged(&entry.name))
                .count(),
        }
    }

    /// How many planned, unclaimed beads the fleet wants: one per implementer, never fewer than
    /// `PLANNER_BUFFER_FLOOR` (`cerebro--planner-want`).
    pub fn planner_want(&self) -> usize {
        self.implementers.max(PLANNER_BUFFER_FLOOR)
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
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fingerprint {
    Planner {
        p0_unplanned: Vec<String>,
        planned: usize,
        implementers: usize,
        actionable_ids: Vec<String>,
    },
    Verifier {
        stale_verdicts: usize,
        merged_unverified: usize,
    },
    Implementer {
        planned_ids: Vec<String>,
    },
    Orchestrator {
        unranked_ids: Vec<String>,
    },
}

pub fn fingerprint(role: &str, facts: &TriggerFacts) -> Option<Fingerprint> {
    match role {
        "planner" => Some(Fingerprint::Planner {
            p0_unplanned: facts.p0_unplanned.clone(),
            planned: facts.planned,
            implementers: facts.implementers,
            actionable_ids: facts.actionable_ids.clone(),
        }),
        "verifier" => Some(Fingerprint::Verifier {
            stale_verdicts: facts.stale_verdicts,
            merged_unverified: facts.merged_unverified,
        }),
        "implementer" => Some(Fingerprint::Implementer {
            planned_ids: facts.planned_ids.clone(),
        }),
        "orchestrator" => Some(Fingerprint::Orchestrator {
            unranked_ids: facts.unranked_ids.clone(),
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
    let reason = condition(facts, agent.role)?;
    if unchanged(facts, &agent) {
        return None;
    }
    Some(reason)
}

/// The role's own condition, first arm true winning.
fn condition(facts: &TriggerFacts, role: &str) -> Option<String> {
    match role {
        "planner" => {
            if let Some(first) = facts.p0_unplanned.first() {
                return Some(format!("P0 {first} unplanned"));
            }
            let want = facts.planner_want();
            // The `actionable_ids` test is not decoration: a short buffer is a reason to plan
            // only while there is something to plan, and without it the second planner is started
            // to find an empty queue every time the first one takes the last bead.
            (facts.planned < want && !facts.actionable_ids.is_empty())
                .then(|| format!("buffer {} of {want}", facts.planned))
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
            (facts.merged_unverified > 0)
                .then(|| format!("{} merged, unverified", facts.merged_unverified))
        }
        "implementer" => (!facts.planned_ids.is_empty())
            .then(|| format!("{} planned, unclaimed", facts.planned_ids.len())),
        "orchestrator" => (!facts.unranked_ids.is_empty())
            .then(|| format!("{} unranked", facts.unranked_ids.len())),
        // `user-feedback`, `reviewer` and `architect` fall here on purpose: they get their rules
        // in cb-kcs.4.3 and are not armed at all until then.
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

/// The gold header notice for a start the view decided on: `Started Beast — buffer 2 of 4.`
///
/// An em dash (U+2014) with a space either side, and a full stop. The reason is the trigger's own
/// phrase, unchanged, so the two views say one thing and cb-kcs.4.4 logs the same string.
pub fn start_notice(name: &str, reason: &str) -> String {
    format!("Started {name} — {reason}.")
}

/// The BEAD column of a standby row: what the agent is waiting for. The vocabulary is closed.
///
/// The arrow is U+2192, and there is no space around the `<` - that is what makes `→ buffer<4`
/// exactly ten cells, which is `BEAD_FLOOR`. A ten-implementer fleet wants eleven and the column
/// takes them: the number is the part that changes.
pub fn standby_label(role: &str, facts: &TriggerFacts) -> Option<String> {
    match role {
        "planner" => Some(format!("→ buffer<{}", facts.planner_want())),
        "implementer" => Some("→ planned".to_string()),
        "verifier" => Some("→ merged".to_string()),
        "orchestrator" => Some("→ unranked".to_string()),
        _ => None,
    }
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

    /// Record that the view ended NAME's pass - the authoritative `ended_at`.
    pub fn note_ended(&mut self, name: &str, at: DateTime<Utc>) {
        self.parked_at.insert(name.to_string(), at);
    }

    /// Record that a successful fleet read saw NAME up. The FALLBACK `ended_at`, and it is
    /// needed: a session that simply died, or one this process never ended, has no park at all,
    /// and a `None` there is what let a role read every open item as moved on every tick for a
    /// day (cb-b4m).
    pub fn note_seen_up(&mut self, name: &str, at: DateTime<Utc>) {
        self.seen_up_at.insert(name.to_string(), at);
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AgentKind, Bead, RosterEntry};

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
        let buckets = crate::model::partition_beads(vec![
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
        // Storm has been told to finish: it takes no further bead, so it is not counted.
        let facts = TriggerFacts::derive(&buckets, &roster, |name| name == "Storm");

        assert_eq!(facts.p0_unplanned, vec!["cb-9zz".to_string()]);
        assert_eq!(facts.planned, 2);
        // `triage:declined` and `human` are the navigator's, and never a planner's.
        assert_eq!(
            facts.actionable_ids,
            vec!["cb-9zz".to_string(), "cb-rank".to_string()]
        );
        assert_eq!(
            facts.planned_ids,
            vec!["cb-p1".to_string(), "cb-p2".to_string()]
        );
        assert_eq!(facts.unranked_ids, vec!["cb-rank".to_string()]);
        assert_eq!(facts.merged_unverified, 1);
        // A paused bead carrying `verdict:stale` is still a stale verdict.
        assert_eq!(facts.stale_verdicts, 1);
        assert_eq!(facts.implementers, 2);
        assert_eq!(facts.planner_want(), 2);
    }

    #[test]
    fn the_buffer_is_one_per_implementer_and_never_fewer_than_the_floor() {
        let mut facts = empty_facts();
        facts.implementers = 0;
        assert_eq!(facts.planner_want(), PLANNER_BUFFER_FLOOR);
        facts.implementers = 4;
        assert_eq!(facts.planner_want(), 4);
    }

    fn empty_facts() -> TriggerFacts {
        TriggerFacts {
            p0_unplanned: Vec::new(),
            planned: 0,
            actionable_ids: Vec::new(),
            planned_ids: Vec::new(),
            unranked_ids: Vec::new(),
            merged_unverified: 0,
            stale_verdicts: 0,
            implementers: 4,
        }
    }

    fn agent(role: &'static str) -> AgentFacts<'static> {
        AgentFacts { role, ended_at: None, started_at: None, last_fingerprint: None }
    }

    #[test]
    fn every_role_answers_its_own_condition() {
        let mut p0 = empty_facts();
        p0.p0_unplanned = vec!["cb-9zz".into()];
        p0.actionable_ids = vec!["cb-9zz".into()];
        assert_eq!(
            trigger(&p0, agent("planner"), at(0)),
            Some("P0 cb-9zz unplanned".to_string())
        );

        let mut buffer = empty_facts();
        buffer.planned = 2;
        buffer.actionable_ids = vec!["cb-a".into()];
        assert_eq!(
            trigger(&buffer, agent("planner"), at(0)),
            Some("buffer 2 of 4".to_string())
        );

        // A short buffer is a reason to plan only while there is something to plan.
        let mut nothing_to_plan = buffer.clone();
        nothing_to_plan.actionable_ids.clear();
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
        assert_eq!(
            trigger(&stale, agent("verifier"), at(0)),
            Some("2 merged, unverified".to_string())
        );

        let mut planned = empty_facts();
        planned.planned_ids = vec!["cb-a".into(), "cb-b".into(), "cb-c".into()];
        assert_eq!(
            trigger(&planned, agent("implementer"), at(0)),
            Some("3 planned, unclaimed".to_string())
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
            Some("3 planned, unclaimed".to_string())
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
        assert_eq!(
            trigger(&moved, held, at(120)),
            Some("2 planned, unclaimed".to_string())
        );
    }

    #[test]
    fn a_launch_that_never_became_a_pass_is_not_held() {
        let mut facts = empty_facts();
        facts.planned_ids = vec!["cb-a".into()];
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
    fn the_cadence_roles_have_no_fingerprint_to_be_held_by() {
        let facts = empty_facts();
        for role in ["user-feedback", "reviewer", "architect"] {
            assert_eq!(fingerprint(role, &facts), None, "{role}");
        }
        assert!(fingerprint("planner", &facts).is_some());
        assert!(fingerprint("verifier", &facts).is_some());
        assert!(fingerprint("orchestrator", &facts).is_some());
    }

    #[test]
    fn the_standby_label_is_a_closed_vocabulary() {
        let facts = empty_facts();
        assert_eq!(standby_label("planner", &facts).as_deref(), Some("→ buffer<4"));
        assert_eq!(standby_label("implementer", &facts).as_deref(), Some("→ planned"));
        assert_eq!(standby_label("verifier", &facts).as_deref(), Some("→ merged"));
        assert_eq!(standby_label("orchestrator", &facts).as_deref(), Some("→ unranked"));
        for role in ["user-feedback", "reviewer", "architect"] {
            assert_eq!(standby_label(role, &facts), None, "{role}");
        }
        // Exactly `BEAD_FLOOR` cells at a four-implementer fleet.
        assert_eq!(
            unicode_width::UnicodeWidthStr::width(
                standby_label("planner", &facts).unwrap().as_str()
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
    fn a_start_is_recorded_with_what_triggered_it() {
        let mut facts = empty_facts();
        facts.planned_ids = vec!["cb-a".into()];
        let mut ledger = StartLedger::default();
        ledger.note_started("Rogue", at(10), fingerprint("implementer", &facts));
        assert_eq!(ledger.started_at("Rogue"), Some(at(10)));
        assert_eq!(ledger.fingerprint("Rogue"), fingerprint("implementer", &facts).as_ref());
        assert_eq!(ledger.started_at_map().get("Rogue"), Some(&at(10)));
    }
}
