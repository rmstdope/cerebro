# scripts/candidate-label-policy.sh - the labels that route a bead, and the named hand-offs that
# move one between roles.
#
# SOURCED, NEVER EXECUTED, by the scripts that read a queue (`stage-candidates`,
# `assignable-beads`, `bugfix-candidates`, `second-look-beads`), `ship`, the fleet view's sweeps
# (`sweep-paused.sh`, `sweep-verdicts.sh`) and the scripts that write a route (`producer-park`,
# `reopen-failed`, `verifier-pass-epic-family`), and by the skill snippets that hand a bead on by
# hand (produce-bead's parks and hand-backs, the verifier's verdict, Cerebro's unpark and send-back,
# the UX agent's park, `beads-workflow`'s escalation). The fleet view's Rust twins every `*_label`
# here with one const in `fleet-view/src/labels.rs`, and `fleet-view/tests/reader_contracts.rs`
# holds the two sets equal, so a word renamed here is a red test until it is renamed there
# (cb-t51j.3). A writer that hand-coded its own label set and a reader that read another stranded a
# bead in nobody's queue four times in two days (cb-b26a, cb-lcfq, cb-0elv.1, cb-0elv.5). Here a
# writer applies a named transition instead of composing labels, and `tests/label-routes.sh` runs
# every transition and proves the bead lands in exactly the queue meant to take it (cb-q6yb).
#
# NOT YET HERE, and spelling these words for themselves: the snippets that mark a bead without
# handing it on (Cerebro's filing and decline), and Moira's park when the navigator is away
# (`agents/user-feedback.md`). A word renamed here is renamed there by hand.
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
# carrying it, `plan:revise` or `mockup:shipping`.
ui_question_label="needs-ui-decision"
# A failed verification found the agreed experience at fault: the UX queue admits it too.
plan_revise_label="plan:revise"
# The navigator's one queue: every fleet queue excludes it.
human_label="human"
# Cerebro asked the navigator about a parked bead and was told to leave it: not asked again.
kept_pause_label="pause:kept"
# A failed verdict main has moved past: the verifier's to redo, every other queue's to exclude.
stale_verdict_label="verdict:stale"
# A producer's hand-back with nothing to build: the verifier's alone (cb-wf24).
verifier_only_label="second-look"
# A bug: the bugfixer's alone, set at filing and never removed.
bugfix_label="bugfix"
# A reviewed pull request `scripts/ship` is merging: in progress, held by `ship`, nobody's queue.
ship_label="shipping"
# A UX agent's agreed drawing on its way to the default branch (cb-8pdv): open, held by `ship`, or
# parked with the navigator. No stage label until it is merged, so no producer is offered it.
drawing_label="mockup:shipping"

# route_flags_for <transition>... - sets the array `route_flags` to the `bd update` flags of one or
# more named hand-offs, in order (`route_flags_for unpark send_to_ux`). The flags are the whole label
# change; the caller adds its own note, guards and claim. No name, or any unknown one, refuses with
# status 2 and `route_flags` empty, so a typo writes nothing rather than half a change.
#
#   send_to_ux            to the UX queue: a question only a designer may answer. Every past-UX label
#                         off, `needs-ui-decision` on, a pending drawing cancelled
#                         (`mockup:shipping` off, as every newer UX decision does).
#                         `producer-park … ux`; Cerebro's send-back.
#   revise_plan           to the UX queue: a failed verification found the agreed experience at
#                         fault. Every past-UX label off, `plan:revise` on. `reopen-failed --fault plan`.
#   fresh_verdict         a verdict has just been given: `verdict:stale` and `second-look` off. With
#                         nothing else, this is the reopen for a build fault: the bead keeps its stage
#                         label and plan and goes back to a producer, or a bug to the bugfixer.
#                         `reopen-failed` (both faults); `verifier-pass-epic-family`; the verifier's
#                         close of a handed-back bead.
#   park_for_navigator    to the navigator: the work itself is in question. `planned` off, `human` on;
#                         unparked (`human` off) it goes back to a producer. `producer-park … scope`;
#                         `beads-workflow`'s escalation and produce-bead's hand-back, by hand.
#   park_for_merge        to the navigator, at the `merge` gate: `human` on and nothing else, so the
#                         plan stays and, unparked, a producer finishes it. produce-bead.
#   hand_to_verifier      to the verifier: a producer found nothing left to build. `planned` off,
#                         `second-look` on; a fresh verdict takes it back off. produce-bead.
#   park_for_ui_decision  to the navigator, from the UX stage, when nobody answered: `needs-ui-decision`
#                         and `human` on; unparked it goes back to the UX queue. `agree-experience`.
#   agree_experience      from the UX stage to a producer: the experience is recorded. `ux:agreed` on,
#                         `needs-ui-decision`, `plan:revise` and `mockup:shipping` off, so a bead that
#                         came back to UX leaves the UX queue for good. `ux-deliver`; `ship --sweep`
#                         once a drawing is merged.
#   hand_drawing_to_ship  from a UX agent to `scripts/ship`: `mockup:shipping` on; every past-UX label,
#                         `needs-ui-decision` and `plan:revise` off; the caller reassigns the bead to
#                         `ship`. `ship --drawing`.
#   park_drawing          from `ship` to the navigator: `human` on, `mockup:shipping` kept, so merging
#                         the pull request still records the bead; unparked unmerged it goes back to
#                         the UX queue. `ship --sweep`.
#   hand_to_ship          from a builder to `scripts/ship`: `shipping` on and nothing else; the
#                         caller reassigns the claim to `ship`. `ship <Name> <id> …`.
#   return_from_ship      from `ship` back to a builder: `shipping` off, so the labels under it send
#                         a producer or the bugfixer to resume it. `ship --sweep`.
#   park_from_ship        from `ship` to the navigator: `shipping` off, `human` on, the plan kept.
#                         `ship --sweep`.
#   unpark                the navigator's answer to any park: `human` and `pause:kept` off, nothing
#                         else, so the labels the park left decide where it goes. Cerebro's unpark,
#                         and before `send_to_ux` its send-back.
route_flags_for() {
  route_flags=()
  if [[ $# -eq 0 ]]; then
    echo "route_flags_for: no transition named" >&2
    return 2
  fi
  local transition label
  for transition in "$@"; do
    case "$transition" in
      send_to_ux|revise_plan)
        for label in "${past_ux_labels[@]}"; do
          route_flags+=(--remove-label "$label")
        done
        if [[ "$transition" == send_to_ux ]]; then
          route_flags+=(--add-label "$ui_question_label")
        else
          route_flags+=(--add-label "$plan_revise_label")
        fi
        route_flags+=(--remove-label "$drawing_label") ;;
      fresh_verdict)
        route_flags+=(--remove-label "$stale_verdict_label" --remove-label "$verifier_only_label") ;;
      park_for_navigator)
        route_flags+=(--remove-label "$plan_label" --add-label "$human_label") ;;
      park_for_merge)
        route_flags+=(--add-label "$human_label") ;;
      hand_to_verifier)
        route_flags+=(--remove-label "$plan_label" --add-label "$verifier_only_label") ;;
      park_for_ui_decision)
        route_flags+=(--add-label "$ui_question_label" --add-label "$human_label"
                      --remove-label "$drawing_label") ;;
      agree_experience)
        route_flags+=(--add-label "$stage_label" --remove-label "$ui_question_label"
                      --remove-label "$plan_revise_label" --remove-label "$drawing_label") ;;
      hand_drawing_to_ship)
        for label in "${past_ux_labels[@]}"; do
          route_flags+=(--remove-label "$label")
        done
        # The agreement answers any open question, so nothing re-asks it if the drawing is parked.
        route_flags+=(--remove-label "$ui_question_label" --remove-label "$plan_revise_label"
                      --add-label "$drawing_label") ;;
      park_drawing)
        route_flags+=(--add-label "$human_label") ;;
      hand_to_ship)
        route_flags+=(--add-label "$ship_label") ;;
      return_from_ship)
        route_flags+=(--remove-label "$ship_label") ;;
      park_from_ship)
        route_flags+=(--remove-label "$ship_label" --add-label "$human_label") ;;
      unpark)
        route_flags+=(--remove-label "$human_label" --remove-label "$kept_pause_label") ;;
      *)
        route_flags=()
        echo "route_flags_for: unknown transition '$transition'" >&2
        return 2 ;;
    esac
  done
}
