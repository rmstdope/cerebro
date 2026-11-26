//! The labels that route a bead between roles, one const each (cb-t51j.3).
//!
//! `scripts/candidate-label-policy.sh` declares every one of these words; this file is its Rust
//! twin, and nothing else in the crate spells them. Each const is named after the policy's shell
//! variable, and `POLICY` pairs the two so `fleet-view/tests/reader_contracts.rs` can hold the set
//! to the shell in both directions: a renamed word, a new policy label with no twin here, or a twin
//! for a word the policy dropped is a red test rather than a bead stranded in nobody's queue.

/// A designer agreed the experience: a producer takes the bead (`stage_label`).
pub const STAGE_LABEL: &str = "ux:agreed";
/// Nothing a person sees changes, said at filing (cb-uump): a producer's without a UX pass
/// (`skip_label`).
pub const SKIP_LABEL: &str = "ux:none";
/// A producer's plan (`plan_label`).
pub const PLAN_LABEL: &str = "planned";
/// The experience is missing something only a designer may decide (`ui_question_label`).
pub const UI_QUESTION_LABEL: &str = "needs-ui-decision";
/// A failed verification found the agreed experience at fault (`plan_revise_label`).
pub const PLAN_REVISE_LABEL: &str = "plan:revise";
/// The navigator's one queue: every fleet queue excludes it (`human_label`).
pub const HUMAN_LABEL: &str = "human";
/// Cerebro asked the navigator about a parked bead and was told to leave it: not asked again
/// (`kept_pause_label`).
pub const KEPT_PAUSE_LABEL: &str = "pause:kept";
/// A failed verdict main has moved past: the verifier's to redo (`stale_verdict_label`).
pub const STALE_VERDICT_LABEL: &str = "verdict:stale";
/// A producer's hand-back with nothing to build: the verifier's alone, cb-wf24
/// (`verifier_only_label`).
pub const VERIFIER_ONLY_LABEL: &str = "second-look";
/// A bug: the bugfixer's alone (`bugfix_label`).
pub const BUGFIX_LABEL: &str = "bugfix";
/// A reviewed pull request `scripts/ship` is merging (`ship_label`).
pub const SHIP_LABEL: &str = "shipping";
/// A UX agent's agreed drawing on its way to the default branch (`drawing_label`).
pub const DRAWING_LABEL: &str = "mockup:shipping";

/// Each policy variable and the const that twins it, for the contract test.
pub const POLICY: [(&str, &str); 11] = [
    ("stage_label", STAGE_LABEL),
    ("skip_label", SKIP_LABEL),
    ("plan_label", PLAN_LABEL),
    ("ui_question_label", UI_QUESTION_LABEL),
    ("plan_revise_label", PLAN_REVISE_LABEL),
    ("human_label", HUMAN_LABEL),
    ("kept_pause_label", KEPT_PAUSE_LABEL),
    ("stale_verdict_label", STALE_VERDICT_LABEL),
    ("verifier_only_label", VERIFIER_ONLY_LABEL),
    ("bugfix_label", BUGFIX_LABEL),
    ("ship_label", SHIP_LABEL),
    ("drawing_label", DRAWING_LABEL),
];
