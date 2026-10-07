# scripts/candidate-label-policy.sh - the labels that route a bead, and the named hand-offs that
# move one between roles.
#
# SOURCED, NEVER EXECUTED, by the scripts that read a queue (`stage-candidates`,
# `assignable-beads`, `bugfix-candidates`, `second-look-beads`) and the scripts that write a route
# (`producer-park`, `reopen-failed`, `verifier-pass-epic-family`), and by the skill snippets that
# hand a bead on by hand (Cerebro's send-back, the UX agent's park). A writer that hand-coded its own
# label set and a reader that read another stranded a bead in nobody's queue four times in two days
# (cb-b26a, cb-lcfq, cb-0elv.1, cb-0elv.5). Here a writer applies a named transition instead of
# composing labels, and `tests/label-routes.sh` runs every transition and proves the bead lands in
# exactly the queue meant to take it (cb-q6yb).
#
# NOT YET HERE, and spelling these words for themselves: the fleet view's sweeps
# (`sweep-paused.sh`, `sweep-verdicts.sh`), its Rust consts (`fleet-view/src/model.rs`, `give.rs`,
# `triggers.rs`), and the other `bd update` snippets in `agents/` and `skills/`. A word renamed here
# is renamed there by hand.
#
# The routing table these words implement is `skills/beads-workflow`, *The lifecycle a bead moves
# through*; change a word there and here together. Its jq twin is `candidate-label-policy.jq`.

# A designer agreed the experience: `agree-experience` adds it, a producer takes the bead.
stage_label="ux:agreed"
# Nothing a person sees changes, said at filing (cb-uump): the UX stage never takes it, a producer
# does.
skip_label="ux:none"
# A producer's plan, added under its claim and kept on a bead it gives back as rework.
plan_label="planned"
# Every label that carries a bead past the UX stage. The UX queue refuses a bead with any of them,
# a producer is offered one with the first two, and sending a bead back to UX removes all three.
past_ux_labels=("$stage_label" "$skip_label" "$plan_label")

# The experience is missing something only a designer may decide: the UX queue admits a failed bead
# carrying it.
ui_question_label="needs-ui-decision"
# A failed verification found the agreed experience at fault: the UX queue admits it too.
plan_revise_label="plan:revise"
# The navigator's one queue: every fleet queue excludes it.
human_label="human"
# A failed verdict main has moved past: the verifier's to redo, every other queue's to exclude.
stale_verdict_label="verdict:stale"
# A producer's hand-back with nothing to build: the verifier's alone (cb-wf24).
verifier_only_label="second-look"
# A bug: the bugfixer's alone, set at filing and never removed.
bugfix_label="bugfix"

# route_flags_for <transition> - sets the array `route_flags` to the `bd update` flags of one named
# hand-off. The flags are the whole label change; the caller adds its own note, guards and claim.
#
#   send_to_ux            to the UX queue: a question only a designer may answer. Every past-UX label
#                         off, `needs-ui-decision` on. `producer-park … ux`; Cerebro's send-back.
#   revise_plan           to the UX queue: a failed verification found the agreed experience at
#                         fault. Every past-UX label off, `plan:revise` on. `reopen-failed --fault plan`.
#   fresh_verdict         a verdict has just been given: `verdict:stale` and `second-look` off. With
#                         nothing else, this is the reopen for a build fault: the bead keeps its stage
#                         label and plan and goes back to a producer, or a bug to the bugfixer.
#                         `reopen-failed` (both faults); `verifier-pass-epic-family`.
#   park_for_navigator    to the navigator: the work itself is in question. `planned` off, `human` on;
#                         unparked (`human` off) it goes back to a producer. `producer-park … scope`.
#   park_for_ui_decision  to the navigator, from the UX stage, when nobody answered: `needs-ui-decision`
#                         and `human` on; unparked it goes back to the UX queue. `agree-experience`.
route_flags_for() {
  route_flags=()
  local label
  case "${1:-}" in
    send_to_ux|revise_plan)
      for label in "${past_ux_labels[@]}"; do
        route_flags+=(--remove-label "$label")
      done
      if [[ "$1" == send_to_ux ]]; then
        route_flags+=(--add-label "$ui_question_label")
      else
        route_flags+=(--add-label "$plan_revise_label")
      fi ;;
    fresh_verdict)
      route_flags+=(--remove-label "$stale_verdict_label" --remove-label "$verifier_only_label") ;;
    park_for_navigator)
      route_flags+=(--remove-label "$plan_label" --add-label "$human_label") ;;
    park_for_ui_decision)
      route_flags+=(--add-label "$ui_question_label" --add-label "$human_label") ;;
    *)
      echo "route_flags_for: unknown transition '${1:-}'" >&2
      return 2 ;;
  esac
}
