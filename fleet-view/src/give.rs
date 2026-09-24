//! The Work-pane `a` key (cb-10d.5): who is listed, why each listed agent can or cannot take the
//! bead, where the list cursor goes, and every sentence. Pure throughout, the way `sweeps.rs` is;
//! `app.rs`, `ui.rs` and `main.rs` call it and decide nothing of their own.

use std::collections::BTreeMap;

use unicode_width::UnicodeWidthStr;

use crate::lifecycle::row_is_alive;
use crate::model::{Bead, FleetRow, Releasing, RolePolicy, RowState};

const PLANNED_LABEL: &str = "planned";
const BUGFIX_LABEL: &str = "bugfix";
const UX_AGREED_LABEL: &str = "ux:agreed";

/// Which kind of work a role takes from the board.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    Builder,
    Producer,
    Bugfixer,
    Designer,
}

/// `implementer` -> Builder; `bugfixer` -> Bugfixer; the planning roles -> Designer; anything
/// else -> None.
pub fn stage_of(role: &str) -> Option<Stage> {
    match RolePolicy::for_role(role) {
        RolePolicy::Producer => Some(Stage::Producer),
        RolePolicy::Implementer => Some(Stage::Builder),
        RolePolicy::Bugfixer => Some(Stage::Bugfixer),
        RolePolicy::Planner | RolePolicy::Ux | RolePolicy::BuildDesign => Some(Stage::Designer),
        RolePolicy::None => None,
    }
}

/// Why a listed agent can or cannot take the bead right now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Standing {
    Free,
    /// Running, starting or giving something back. BEAD is what it is busy with, when known.
    Busy { bead: Option<String> },
    /// Not planned for a Builder, not bugfix-labelled for a Bugfixer, or already planned for a
    /// Designer.
    WrongStage(Stage),
}

/// One row of the list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub name: String,
    pub role: String,
    /// `RowState::word()` of its fleet row.
    pub state_word: String,
    pub standing: Standing,
}

fn standing_for(
    bead: &Bead,
    row: &FleetRow,
    stage: Stage,
    starting: &BTreeMap<String, String>,
    releasing: &BTreeMap<String, Releasing>,
) -> Standing {
    if row_is_alive(row) || starting.contains_key(&row.name) || releasing.contains_key(&row.name) {
        let busy = starting
            .get(&row.name)
            .cloned()
            .or_else(|| releasing.get(&row.name).map(|r| r.bead.clone()))
            .or_else(|| row.bead.clone());
        return Standing::Busy { bead: busy };
    }
    let planned = bead.labels.iter().any(|l| l == PLANNED_LABEL);
    let bugfix = bead.labels.iter().any(|l| l == BUGFIX_LABEL);
    let ux_agreed = bead.labels.iter().any(|l| l == UX_AGREED_LABEL);
    match stage {
        Stage::Builder if !planned => Standing::WrongStage(Stage::Builder),
        Stage::Producer if !ux_agreed || planned => Standing::WrongStage(Stage::Producer),
        Stage::Bugfixer if !bugfix => Standing::WrongStage(Stage::Bugfixer),
        Stage::Designer if planned => Standing::WrongStage(Stage::Designer),
        _ => Standing::Free,
    }
}

/// The list for BEAD: every row whose role has a stage, in roster order, skipping `Invalid` rows.
pub fn candidates(
    bead: &Bead,
    rows: &[FleetRow],
    starting: &BTreeMap<String, String>,
    releasing: &BTreeMap<String, Releasing>,
) -> Vec<Candidate> {
    rows.iter()
        .filter(|row| row.state != RowState::Invalid)
        .filter_map(|row| {
            let stage = stage_of(&row.role)?;
            Some(Candidate {
                name: row.name.clone(),
                role: row.role.clone(),
                state_word: row.state.word().to_string(),
                standing: standing_for(bead, row, stage, starting, releasing),
            })
        })
        .collect()
}

/// Who already has BEAD: its assignee, else a running row naming it, else the view's own records.
pub fn holder(
    bead: &Bead,
    rows: &[FleetRow],
    starting: &BTreeMap<String, String>,
    releasing: &BTreeMap<String, Releasing>,
) -> Option<String> {
    if let Some(a) = bead.assignee.as_deref().filter(|a| !a.is_empty()) {
        return Some(a.to_string());
    }
    if let Some(row) =
        rows.iter().find(|r| row_is_alive(r) && r.bead.as_deref() == Some(bead.id.as_str()))
    {
        return Some(row.name.clone());
    }
    if let Some((name, _)) = starting.iter().find(|(_, b)| **b == bead.id) {
        return Some(name.clone());
    }
    releasing.iter().find(|(_, r)| r.bead == bead.id).map(|(name, _)| name.clone())
}

fn is_free(c: &Candidate) -> bool {
    c.standing == Standing::Free
}

/// The cursor moved DELTA free rows from CURSOR, clamped, never wrapping.
pub fn step(candidates: &[Candidate], cursor: &str, delta: isize) -> String {
    let Some(at) = candidates.iter().position(|c| c.name == cursor) else {
        return cursor.to_string();
    };
    let found = if delta > 0 {
        candidates[at + 1..].iter().find(|c| is_free(c))
    } else if delta < 0 {
        candidates[..at].iter().rev().find(|c| is_free(c))
    } else {
        None
    };
    found.map(|c| c.name.clone()).unwrap_or_else(|| cursor.to_string())
}

/// Keep CURSOR if still Free; else the next Free row below, else the nearest above.
pub fn reseat(candidates: &[Candidate], cursor: &str) -> Option<String> {
    match candidates.iter().position(|c| c.name == cursor) {
        Some(at) if is_free(&candidates[at]) => Some(cursor.to_string()),
        Some(at) => candidates[at + 1..]
            .iter()
            .find(|c| is_free(c))
            .or_else(|| candidates[..at].iter().rev().find(|c| is_free(c)))
            .map(|c| c.name.clone()),
        None => candidates.iter().find(|c| is_free(c)).map(|c| c.name.clone()),
    }
}

/// What `a` does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Opening {
    Open { cursor: String },
    Refuse(String),
}

pub fn open(
    bead: Option<&Bead>,
    rows: &[FleetRow],
    starting: &BTreeMap<String, String>,
    releasing: &BTreeMap<String, Releasing>,
) -> Opening {
    let Some(bead) = bead else { return Opening::Refuse(no_work()) };
    if let Some(h) = holder(bead, rows, starting, releasing) {
        return Opening::Refuse(already_with(&bead.id, &h));
    }
    match candidates(bead, rows, starting, releasing).into_iter().find(is_free) {
        Some(c) => Opening::Open { cursor: c.name },
        None => Opening::Refuse(nobody(&bead.id)),
    }
}

/// What the list becomes after something moved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Revalidated {
    Keep { cursor: String },
    Close { notice: Option<String> },
}

pub fn revalidate(
    open_bead: &str,
    cursor: &str,
    bead: Option<&Bead>,
    rows: &[FleetRow],
    starting: &BTreeMap<String, String>,
    releasing: &BTreeMap<String, Releasing>,
) -> Revalidated {
    let Some(bead) = bead else { return Revalidated::Close { notice: None } };
    if let Some(h) = holder(bead, rows, starting, releasing) {
        return Revalidated::Close { notice: Some(already_with(open_bead, &h)) };
    }
    match reseat(&candidates(bead, rows, starting, releasing), cursor) {
        Some(cursor) => Revalidated::Keep { cursor },
        None => Revalidated::Close { notice: Some(nobody(open_bead)) },
    }
}

/// What `Enter` does, rechecked against the state at the keystroke.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Choice {
    Give { name: String, bead: String },
    Refuse(String),
    Revalidate,
}

pub fn choose(
    open_bead: &str,
    cursor: &str,
    bead: Option<&Bead>,
    rows: &[FleetRow],
    starting: &BTreeMap<String, String>,
    releasing: &BTreeMap<String, Releasing>,
) -> Choice {
    let Some(bead) = bead else { return Choice::Revalidate };
    if let Some(h) = holder(bead, rows, starting, releasing) {
        return Choice::Refuse(already_with(open_bead, &h));
    }
    let Some(row) = rows.iter().find(|r| r.name == cursor) else { return Choice::Revalidate };
    let Some(stage) = stage_of(&row.role) else { return Choice::Refuse(never_takes(cursor)) };
    match standing_for(bead, row, stage, starting, releasing) {
        Standing::Busy { bead: Some(b) } => Choice::Refuse(busy(cursor, &b)),
        Standing::Busy { bead: None } => Choice::Revalidate,
        Standing::WrongStage(Stage::Builder) => Choice::Refuse(not_planned(open_bead, cursor)),
        Standing::WrongStage(Stage::Producer) => {
            Choice::Refuse(format!("{open_bead} is not UX-agreed work for {cursor}"))
        }
        Standing::WrongStage(Stage::Bugfixer) => Choice::Refuse(not_a_bugfix(open_bead, cursor)),
        Standing::WrongStage(Stage::Designer) => {
            Choice::Refuse(already_planned(open_bead, cursor))
        }
        Standing::Free => Choice::Give { name: cursor.to_string(), bead: open_bead.to_string() },
    }
}

fn pad(name: &str, width: usize) -> String {
    let w = width + 2;
    format!("{name}{}", " ".repeat(w.saturating_sub(UnicodeWidthStr::width(name))))
}

/// The text of one list row, without its indent and cursor marker.
pub fn row_text(candidate: &Candidate, name_width: usize) -> String {
    let name = pad(&candidate.name, name_width);
    match &candidate.standing {
        Standing::Busy { bead: Some(b) } => format!("{name}busy with {b}"),
        Standing::WrongStage(Stage::Builder) => format!("{name}only builds planned work"),
        Standing::WrongStage(Stage::Producer) => format!("{name}only produces UX-agreed work"),
        Standing::WrongStage(Stage::Bugfixer) => format!("{name}only fixes bugfix-labelled work"),
        Standing::WrongStage(Stage::Designer) => format!("{name}only designs unplanned work"),
        Standing::Free | Standing::Busy { bead: None } => {
            format!("{name}{}  {}", candidate.role, candidate.state_word)
        }
    }
}

pub fn header(bead: &str) -> String {
    format!("Give {bead} to\u{2026}  \u{2191}\u{2193} Enter \u{b7} Esc")
}
pub fn pending(bead: &str, name: &str) -> String {
    format!("Giving {bead} to {name}\u{2026}")
}
pub fn gave(bead: &str, name: &str) -> String {
    format!("Gave {bead} to {name}")
}
pub fn no_work() -> String {
    "Put the cursor on a piece of work first".to_string()
}
pub fn nobody(bead: &str) -> String {
    format!("Nobody can take {bead} right now")
}
pub fn already_with(bead: &str, holder: &str) -> String {
    format!("{bead} is already with {holder}")
}
pub fn never_takes(name: &str) -> String {
    format!("{name} doesn't take work from the board")
}
pub fn busy(name: &str, bead: &str) -> String {
    format!("{name} is busy with {bead}")
}
pub fn not_planned(bead: &str, name: &str) -> String {
    format!("{bead} isn't planned yet \u{2014} {name} only builds planned work")
}
pub fn already_planned(bead: &str, name: &str) -> String {
    format!("{bead} is already planned \u{2014} {name} only designs unplanned work")
}
pub fn not_a_bugfix(bead: &str, name: &str) -> String {
    format!("{bead} is not labelled bugfix \u{2014} {name} only fixes bugfix-labelled work")
}
pub fn refused(bead: &str, name: &str) -> String {
    format!("bd would not give {bead} to {name}")
}
pub fn unpushed(bead: &str, name: &str) -> String {
    format!(
        "Gave {bead} to {name}, but bd dolt push failed \u{2014} other machines will not see this yet"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lifecycle::GiveBack;
    use crate::model::AgentKind;

    fn row(name: &str, role: &str, state: RowState, bead: Option<&str>) -> FleetRow {
        FleetRow {
            name: name.into(),
            role: role.into(),
            kind: AgentKind::Interactive,
            state,
            phase: None,
            bead: bead.map(Into::into),
            since: None,
            phase_since: None,
            pid: None,
            turn_ended: None,
            sessions: 0,
            diagnostic: None,
        }
    }

    fn bead(id: &str, labels: &[&str], assignee: Option<&str>) -> Bead {
        Bead {
            id: id.into(),
            title: "t".into(),
            status: "open".into(),
            issue_type: "task".into(),
            labels: labels.iter().map(|l| l.to_string()).collect(),
            priority: Some(1),
            updated_at: None,
            assignee: assignee.map(Into::into),
            metadata: serde_json::Value::Null,
            external_ref: None,
        }
    }

    fn none() -> (BTreeMap<String, String>, BTreeMap<String, Releasing>) {
        (BTreeMap::new(), BTreeMap::new())
    }

    fn cand(name: &str, standing: Standing) -> Candidate {
        Candidate {
            name: name.into(),
            role: "implementer".into(),
            state_word: "standby".into(),
            standing,
        }
    }

    #[test]
    fn the_sentences_are_exact() {
        assert_eq!(header("cb-44b"), "Give cb-44b to…  ↑↓ Enter · Esc");
        assert_eq!(pending("cb-44b", "Rogue"), "Giving cb-44b to Rogue…");
        assert_eq!(gave("cb-44b", "Rogue"), "Gave cb-44b to Rogue");
        assert_eq!(no_work(), "Put the cursor on a piece of work first");
        assert_eq!(nobody("cb-44b"), "Nobody can take cb-44b right now");
        assert_eq!(already_with("cb-44b", "Storm"), "cb-44b is already with Storm");
        assert_eq!(never_takes("Moira"), "Moira doesn't take work from the board");
        assert_eq!(busy("Cyclops", "cb-9su"), "Cyclops is busy with cb-9su");
        assert_eq!(
            not_planned("cb-44b", "Rogue"),
            "cb-44b isn't planned yet — Rogue only builds planned work"
        );
        assert_eq!(
            already_planned("cb-44b", "Xavier"),
            "cb-44b is already planned — Xavier only designs unplanned work"
        );
        assert_eq!(refused("cb-44b", "Rogue"), "bd would not give cb-44b to Rogue");
        assert_eq!(
            unpushed("cb-44b", "Rogue"),
            "Gave cb-44b to Rogue, but bd dolt push failed — other machines will not see this yet"
        );
    }

    #[test]
    fn only_the_roles_that_take_work_are_listed_in_roster_order() {
        let rows = vec![
            row("Cerebro", "orchestrator", RowState::Standby, None),
            row("Xavier", "ux", RowState::Standby, None),
            row("Gambit", "build-design", RowState::Standby, None),
            row("Moira", "user-feedback", RowState::Standby, None),
            row("Cyclops", "implementer", RowState::Standby, None),
            row("Rogue", "implementer", RowState::Standby, None),
            row("Bad", "implementer", RowState::Invalid, None),
        ];
        let (s, r) = none();
        let names: Vec<_> =
            candidates(&bead("cb-x", &[], None), &rows, &s, &r).into_iter().map(|c| c.name).collect();
        assert_eq!(names, ["Xavier", "Gambit", "Cyclops", "Rogue"]);
    }

    #[test]
    fn a_running_starting_or_releasing_agent_is_busy_with_its_bead() {
        let b = bead("cb-x", &["planned"], None);
        let rows = vec![
            row("A", "implementer", RowState::Working, Some("cb-9su")),
            row("B", "implementer", RowState::Standby, None),
            row("C", "implementer", RowState::Dead, None),
            row("D", "implementer", RowState::Up, None),
        ];
        let mut s = BTreeMap::new();
        s.insert("B".to_string(), "cb-s".to_string());
        let mut r = BTreeMap::new();
        r.insert(
            "C".to_string(),
            Releasing { bead: "cb-r".into(), failed_at: None, cause: GiveBack::Stopped },
        );
        let c = candidates(&b, &rows, &s, &r);
        assert_eq!(c[0].standing, Standing::Busy { bead: Some("cb-9su".into()) });
        assert_eq!(c[1].standing, Standing::Busy { bead: Some("cb-s".into()) });
        assert_eq!(c[2].standing, Standing::Busy { bead: Some("cb-r".into()) });
        assert_eq!(c[3].standing, Standing::Busy { bead: None });
    }

    #[test]
    fn the_stage_decides_the_rest() {
        let rows = vec![
            row("I", "implementer", RowState::Standby, None),
            row("P", "producer", RowState::Standby, None),
            row("U", "ux", RowState::Standby, None),
            row("G", "build-design", RowState::Standby, None),
        ];
        let (s, r) = none();
        let planned = candidates(&bead("cb-x", &["planned"], None), &rows, &s, &r);
        assert_eq!(planned[0].standing, Standing::Free);
        assert_eq!(planned[1].standing, Standing::WrongStage(Stage::Producer));
        let unplanned = candidates(&bead("cb-x", &[], None), &rows, &s, &r);
        assert_eq!(unplanned[0].standing, Standing::WrongStage(Stage::Builder));
        assert_eq!(unplanned[1].standing, Standing::WrongStage(Stage::Producer));
        let agreed = candidates(&bead("cb-x", &["ux:agreed"], None), &rows, &s, &r);
        assert_eq!(agreed[1].standing, Standing::Free);
        assert_eq!(unplanned[2].standing, Standing::Free);
    }

    #[test]
    fn the_holder_is_the_assignee_then_a_running_row_then_the_records() {
        let (s, r) = none();
        let rows = vec![row("Run", "implementer", RowState::Working, Some("cb-x"))];
        assert_eq!(holder(&bead("cb-x", &[], Some("Storm")), &rows, &s, &r), Some("Storm".into()));
        assert_eq!(holder(&bead("cb-x", &[], Some("")), &rows, &s, &r), Some("Run".into()));
        let mut st = BTreeMap::new();
        st.insert("Sta".to_string(), "cb-x".to_string());
        assert_eq!(holder(&bead("cb-x", &[], None), &[], &st, &r), Some("Sta".into()));
        let mut rel = BTreeMap::new();
        rel.insert(
            "Rel".to_string(),
            Releasing { bead: "cb-x".into(), failed_at: None, cause: GiveBack::Stopped },
        );
        assert_eq!(holder(&bead("cb-x", &[], None), &[], &s, &rel), Some("Rel".into()));
        assert_eq!(holder(&bead("cb-x", &[], None), &[], &s, &r), None);
    }

    #[test]
    fn the_cursor_skips_rows_that_cannot_take_it() {
        let c = vec![
            cand("A", Standing::Free),
            cand("B", Standing::Busy { bead: None }),
            cand("C", Standing::Free),
            cand("D", Standing::WrongStage(Stage::Builder)),
        ];
        assert_eq!(step(&c, "A", 1), "C");
        assert_eq!(step(&c, "C", 1), "C");
        assert_eq!(step(&c, "C", -1), "A");
        assert_eq!(step(&c, "A", -1), "A");
    }

    #[test]
    fn a_row_that_turns_busy_moves_the_cursor_below_else_above() {
        let busy = || Standing::Busy { bead: None };
        let c = vec![cand("A", Standing::Free), cand("B", busy()), cand("C", Standing::Free)];
        assert_eq!(reseat(&c, "B"), Some("C".into()));
        let c = vec![cand("A", Standing::Free), cand("B", busy()), cand("C", busy())];
        assert_eq!(reseat(&c, "B"), Some("A".into()));
        let c = vec![cand("A", busy()), cand("B", busy())];
        assert_eq!(reseat(&c, "B"), None);
    }

    #[test]
    fn a_opens_or_refuses_in_the_agreed_order() {
        let (s, r) = none();
        let rows = vec![
            row("Cyclops", "implementer", RowState::Working, Some("cb-9su")),
            row("Rogue", "implementer", RowState::Standby, None),
        ];
        assert_eq!(open(None, &rows, &s, &r), Opening::Refuse(no_work()));
        let held = bead("cb-44b", &["planned"], Some("Storm"));
        assert_eq!(open(Some(&held), &rows, &s, &r), Opening::Refuse(already_with("cb-44b", "Storm")));
        let unplanned = bead("cb-44b", &[], None);
        assert_eq!(open(Some(&unplanned), &rows, &s, &r), Opening::Refuse(nobody("cb-44b")));
        let planned = bead("cb-44b", &["planned"], None);
        assert_eq!(open(Some(&planned), &rows, &s, &r), Opening::Open { cursor: "Rogue".into() });
    }

    #[test]
    fn revalidating_closes_on_a_holder_or_nobody_and_silently_when_the_bead_is_gone() {
        let (s, r) = none();
        let rows = vec![
            row("Rogue", "implementer", RowState::Standby, None),
            row("Storm", "implementer", RowState::Standby, None),
        ];
        assert_eq!(
            revalidate("cb-44b", "Rogue", None, &rows, &s, &r),
            Revalidated::Close { notice: None }
        );
        let held = bead("cb-44b", &["planned"], Some("Storm"));
        assert_eq!(
            revalidate("cb-44b", "Rogue", Some(&held), &rows, &s, &r),
            Revalidated::Close { notice: Some(already_with("cb-44b", "Storm")) }
        );
        let unplanned = bead("cb-44b", &[], None);
        assert_eq!(
            revalidate("cb-44b", "Rogue", Some(&unplanned), &rows, &s, &r),
            Revalidated::Close { notice: Some(nobody("cb-44b")) }
        );
        let planned = bead("cb-44b", &["planned"], None);
        let busy_rows = vec![
            row("Rogue", "implementer", RowState::Working, Some("cb-1")),
            row("Storm", "implementer", RowState::Standby, None),
        ];
        assert_eq!(
            revalidate("cb-44b", "Rogue", Some(&planned), &busy_rows, &s, &r),
            Revalidated::Keep { cursor: "Storm".into() }
        );
    }

    #[test]
    fn enter_rechecks_and_refuses_with_the_round_one_lines() {
        let (s, r) = none();
        let planned = bead("cb-44b", &["planned"], None);
        let unplanned = bead("cb-44b", &[], None);
        let rows = vec![
            row("Rogue", "implementer", RowState::Standby, None),
            row("Moira", "user-feedback", RowState::Standby, None),
            row("Cyclops", "implementer", RowState::Working, Some("cb-9su")),
            row("Up", "implementer", RowState::Up, None),
            row("Xavier", "ux", RowState::Standby, None),
        ];
        let c = |cursor: &str, b: Option<&Bead>| choose("cb-44b", cursor, b, &rows, &s, &r);
        assert_eq!(c("Rogue", None), Choice::Revalidate);
        let held = bead("cb-44b", &["planned"], Some("Storm"));
        assert_eq!(c("Rogue", Some(&held)), Choice::Refuse(already_with("cb-44b", "Storm")));
        assert_eq!(c("Gone", Some(&planned)), Choice::Revalidate);
        assert_eq!(c("Moira", Some(&planned)), Choice::Refuse(never_takes("Moira")));
        assert_eq!(c("Cyclops", Some(&planned)), Choice::Refuse(busy("Cyclops", "cb-9su")));
        assert_eq!(c("Up", Some(&planned)), Choice::Revalidate);
        assert_eq!(c("Rogue", Some(&unplanned)), Choice::Refuse(not_planned("cb-44b", "Rogue")));
        assert_eq!(c("Xavier", Some(&planned)), Choice::Refuse(already_planned("cb-44b", "Xavier")));
        assert_eq!(
            c("Rogue", Some(&planned)),
            Choice::Give { name: "Rogue".into(), bead: "cb-44b".into() }
        );
    }

    #[test]
    fn list_rows_read_as_agreed() {
        let mk = |name: &str, role: &str, standing| Candidate {
            name: name.into(),
            role: role.into(),
            state_word: "standby".into(),
            standing,
        };
        assert_eq!(
            row_text(&mk("Rogue", "implementer", Standing::Free), 7),
            "Rogue    implementer  standby"
        );
        assert_eq!(
            row_text(&mk("Cyclops", "implementer", Standing::Busy { bead: Some("cb-9su".into()) }), 7),
            "Cyclops  busy with cb-9su"
        );
        assert_eq!(
            row_text(&mk("Xavier", "ux", Standing::WrongStage(Stage::Designer)), 7),
            "Xavier   only designs unplanned work"
        );
        assert_eq!(
            row_text(&mk("Rogue", "implementer", Standing::WrongStage(Stage::Builder)), 7),
            "Rogue    only builds planned work"
        );
    }
}
