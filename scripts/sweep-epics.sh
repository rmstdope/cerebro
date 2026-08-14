#!/usr/bin/env bash
#
# Prints, as JSON, every epic eligible for closure - every child closed - so the fleet view can
# offer to close it, with the navigator confirming each one.
#
#     .claude/cerebro/scripts/sweep-epics.sh --json
#
# Read-only, like sweep-claims.sh: no `bd close` here. `bd epic status --eligible-only` has already
# done the counting - every child of the epics this prints is closed - so there is no delivery
# judgement to make the way there is for a claim; the only question left is whether the close is
# stale enough to be safe (see "Epics left open under closed children" in `agents/orchestrator.md`):
# an implementer closes its parent within seconds of its last child, so a fresh close means an agent
# is still mid-cleanup, not that the epic was missed.
#
#   id                                the epic's id
#   title                             the epic's title, for the confirmation prompt
#   minutes_since_last_child_closed   minutes since the most recently closed child's `closed_at`,
#                                     or null if that could not be determined

set -uo pipefail

if [[ "${1:-}" != "--json" ]]; then
  echo "usage: .claude/cerebro/scripts/sweep-epics.sh --json" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

superproject="$(git -C "$script_dir" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
if [[ -n "$superproject" ]]; then
  repo_root="$superproject"
else
  git_common_dir="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo '{"error": "not in a git repository"}'
    exit 1
  }
  repo_root="$(dirname "$git_common_dir")"
fi

# ISO-8601 UTC ("2026-08-14T09:00:17Z") to a Unix timestamp. GNU date takes `-d`; BSD/macOS date
# has no such flag and wants `-j -f` with an explicit format instead - so try GNU first and fall
# back rather than branching on `uname`, which would miss a GNU coreutils install on macOS.
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

if ! epics_output="$(bd -C "$repo_root" epic status --eligible-only --json 2>/dev/null)" || [[ -z "$epics_output" ]]; then
  epics_output="[]"
fi

now_epoch="$(date -u +%s)"

entries=()
while IFS= read -r epic; do
  [[ -z "$epic" ]] && continue
  id="$(jq -r '.epic.id' <<<"$epic")"
  title="$(jq -r '.epic.title // ""' <<<"$epic")"

  children_json="$(bd -C "$repo_root" children "$id" --json 2>/dev/null || echo "[]")"
  # The newest `closed_at` among closed children - eligibility already means every child is closed,
  # so this is "when did the last one land", not "are they all closed".
  last_closed="$(jq -r '[.[] | select(.status == "closed") | .closed_at // empty] | sort | last // empty' <<<"$children_json")"

  minutes=null
  if [[ -n "$last_closed" ]]; then
    closed_epoch="$(iso_to_epoch "$last_closed" || true)"
    if [[ -n "$closed_epoch" ]]; then
      minutes=$(( (now_epoch - closed_epoch) / 60 ))
    fi
  fi

  entry="$(jq -n --arg id "$id" --arg title "$title" --argjson minutes "$minutes" \
    '{id: $id, title: $title, minutes_since_last_child_closed: $minutes}')"
  entries+=("$entry")
done < <(jq -c '.[]' <<<"$epics_output")

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${entries[@]}" | jq -s '.'
fi
