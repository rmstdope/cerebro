#!/usr/bin/env bash
#
# Prints, as JSON, every `open` bead that still carries an assignee - so the fleet view can offer to
# clear an assignee no live session backs up, and unstrand a bead every implementer walks past
# (ah-kjfm).
#
#     .claude/cerebro/scripts/sweep-assignees.sh --json
#
# A bead reopened by a failed verification comes back `status=open` - no lease - but still naming its
# old assignee, and `bd ready --claim' then never takes it. Twice on 2026-08-23 that stranded a P0,
# one of them for 32 minutes while the named session finished a different bead and took a P1 below
# it.
#
# This script never mutates anything - no `bd update', no `bd close', no `bd reclaim', no git write
# of any kind. Like its three siblings it only gathers facts, so that a pure elisp function
# (`cerebro--assignee-finding') can turn them into a decision and a human confirms that decision
# before anything runs. Keeping this file read-only is what makes that guarantee checkable at a
# glance: the only path to a `bd update ... --assignee ""' is the confirmed one in `cerebro.el',
# never this script.
#
# One object per `open` bead with a non-empty assignee:
#
#   id          the bead id
#   assignee    whatever `bd' has on file
#   title       for the confirmation prompt
#   priority    the integer, so the fleet view can shout for a 0
#   age_min     minutes since `updated_at', or null when there is no timestamp to measure from
#
# Three things this file deliberately does not do:
#
#   * It never emits an `in_progress` bead. A live claim is `sweep-claims.sh's and
#     `sweep-stalled.sh's business, and emitting it here would put two lines in front of the
#     navigator for one bead.
#   * It judges nothing. Whether the assignee is on the roster, whether that session is alive, and
#     whether the bead is inside its grace period are all `cerebro--assignee-finding's, which is pure
#     and therefore testable; a filter here would move a guard somewhere it cannot be tested.
#   * `age_min` is measured from `updated_at', and an edit resets it. That is right rather than a
#     compromise: a bead somebody has just touched is one somebody is attending to. It is also the
#     only clock available - an open bead has no lease, so there is no `lease_expires_at' to measure
#     from as `sweep-claims.sh' does.

set -uo pipefail

if [[ "${1:-}" != "--json" ]]; then
  echo "usage: .claude/cerebro/scripts/sweep-assignees.sh --json" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo_root="$("$script_dir/consumer-root" --shared 2>/dev/null)" || {
  echo '{"error": "not in a git repository"}'
  exit 1
}

# ISO-8601 UTC ("2026-08-14T23:43:39Z") to a Unix timestamp. GNU date takes `-d`; BSD/macOS date has
# no such flag and wants `-j -f` instead - try GNU first and fall back rather than branching on
# `uname`, which would miss a GNU coreutils install on macOS.
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

if ! bd_output="$(bd -C "$repo_root" list --status open --json 2>/dev/null)" || [[ -z "$bd_output" ]]; then
  bd_output="[]"
fi

now_epoch="$(date -u +%s)"

entries=()
while IFS= read -r bead; do
  [[ -z "$bead" ]] && continue
  assignee="$(jq -r '.assignee // ""' <<<"$bead")"
  # The whole filter: an open bead nobody is named on is exactly what an open bead should look like.
  [[ -z "$assignee" ]] && continue

  id="$(jq -r '.id' <<<"$bead")"
  title="$(jq -r '.title // ""' <<<"$bead")"
  # `// empty` rather than `// 4`: a listing with no priority at all is a shape this does not know,
  # and inventing a number would silence the P0 escalation on the one bead that most needs it.
  priority="$(jq -r 'if (.priority | type) == "number" then .priority else empty end' <<<"$bead")"
  [[ -n "$priority" ]] || priority=null
  updated_at="$(jq -r '.updated_at // empty' <<<"$bead")"

  age_min=null
  if [[ -n "$updated_at" ]]; then
    updated_epoch="$(iso_to_epoch "$updated_at" || true)"
    [[ -n "$updated_epoch" ]] && age_min=$(( (now_epoch - updated_epoch) / 60 ))
  fi

  entry="$(jq -n \
    --arg id "$id" --arg assignee "$assignee" --arg title "$title" \
    --argjson priority "$priority" \
    --argjson age_min "$age_min" \
    '{id: $id, assignee: $assignee, title: $title, priority: $priority, age_min: $age_min}')"
  entries+=("$entry")
done < <(jq -c '.[]' <<<"$bd_output")

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${entries[@]}" | jq -s '.'
fi
