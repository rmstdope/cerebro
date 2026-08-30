#!/usr/bin/env bash
#
# Prints, as JSON, every `open` bead parked for the navigator with the `human` label - so the fleet
# view can show them all in its `Waiting on you` section, and offer back the one case it can judge
# from the board alone: a pause whose blockers have every one of them closed (cb-wfb).
#
#     .claude/cerebro/scripts/sweep-paused.sh --json
#
# Four documents park a bead this way - an implementer handing back a plan missing a mandatory
# section, a planner parking a user-facing question, Moira when an issue and its bead disagree, and
# the generic block in `skills/beads-workflow`. Nothing looks again afterwards, so a pause outlives
# its reason: the prerequisite lands, and the bead sits in `bd human list` exactly as it sat the day
# it was parked. This script is what gathers the facts that say which pauses are still real.
#
# It runs no `git` at all, unlike `sweep-verdicts.sh` and `sweep-stalled.sh`: every fact it needs is
# on the bead board, so there is no fetch here and no "could not reach origin" answer.
#
# This script never mutates anything - no `bd update', no `bd close', no `bd reclaim', no
# `bd set-state', no git write of any kind. Like its five siblings it only gathers facts, so that a
# pure elisp function (`cerebro--paused-finding') can turn them into a decision and a human confirms
# that decision before anything runs. Keeping this file read-only is what makes that guarantee
# checkable at a glance: the only path to a `bd update ... --remove-label human' is the confirmed
# one in `cerebro.el', never this script.
#
# One object per candidate - an `open` bead carrying `human`:
#
#   id            the bead id
#   title         for the panel row and the confirmation prompt
#   priority      the integer, or null when the listing carries no numeric priority
#   paused_at     `.metadata.paused_at', or null when the bead has none
#   ui_decision   true when the bead carries `needs-ui-decision', false otherwise
#   blockers      [ {id, status}, ... ] - one per `blocks` dependency, possibly empty
#
# `blockers` comes from `bd show <id> --json' per candidate rather than from the listing: the two
# commands return different dependency shapes, and the wrong one silently finds nothing rather than
# erroring. In `bd show` the field is `dependency_type` and the entry IS the dependency bead, so its
# id is `.id` and its status `.status`.
#
# `select(.dependency_type=="blocks")` is load-bearing: `dependencies` also carries the
# `parent-child` edge, and a child's own parent epic never closes until the child does - so without
# the filter no child of any epic could ever read as unblocked.
#
# It judges nothing. Whether an empty blocker list, or a bead carrying `needs-ui-decision`, is
# actionable is `cerebro--paused-finding's, which is pure and therefore testable; a filter here
# would move a guard somewhere it cannot be tested. The one filtering it does is selecting `human`
# beads, which is what makes this a candidate list rather than the whole board.

set -uo pipefail

if [[ "${1:-}" != "--json" ]]; then
  echo "usage: .claude/cerebro/scripts/sweep-paused.sh --json" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo_root="$("$script_dir/consumer-root" --shared 2>/dev/null)" || {
  echo '{"error": "not in a git repository"}'
  exit 1
}

if ! bd_output="$(bd -C "$repo_root" list --status open --json 2>/dev/null)" || [[ -z "$bd_output" ]]; then
  bd_output="[]"
fi

entries=()
while IFS= read -r bead; do
  [[ -z "$bead" ]] && continue

  id="$(jq -r '.id' <<<"$bead")"
  title="$(jq -r '.title // ""' <<<"$bead")"
  # `// empty` rather than `// 4`: a listing with no priority at all is a shape this does not know,
  # and inventing a number would put a made-up figure on the navigator's own section.
  priority="$(jq -r 'if (.priority | type) == "number" then .priority else empty end' <<<"$bead")"
  [[ -n "$priority" ]] || priority=null

  ui_decision="$(jq -r 'if ((.labels // []) | index("needs-ui-decision")) then "true" else "false" end' <<<"$bead")"

  # `.metadata // {}` because the key is ABSENT, not empty, when a bead carries no metadata at all -
  # `.metadata.paused_at` errors out in jq rather than returning null.
  paused_at="$(jq -r '(.metadata // {}) | .paused_at // empty' <<<"$bead")"
  if [[ -n "$paused_at" ]]; then
    paused_at_json="$(jq -n --arg v "$paused_at" '$v')"
  else
    paused_at_json=null
  fi

  blockers="$(bd -C "$repo_root" show "$id" --json 2>/dev/null \
    | jq -c '(if type=="array" then .[0] else . end) | [ (.dependencies // [])[]
             | select(.dependency_type=="blocks") | {id: .id, status: .status} ]' 2>/dev/null)"
  [[ -n "$blockers" ]] || blockers="[]"

  entry="$(jq -n \
    --arg id "$id" --arg title "$title" \
    --argjson priority "$priority" \
    --argjson paused_at "$paused_at_json" \
    --argjson ui_decision "$ui_decision" \
    --argjson blockers "$blockers" \
    '{id: $id, title: $title, priority: $priority, paused_at: $paused_at,
      ui_decision: $ui_decision, blockers: $blockers}')"
  entries+=("$entry")
done < <(jq -c '.[] | select((.labels // []) | index("human"))' <<<"$bd_output")

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${entries[@]}" | jq -s '.'
fi
