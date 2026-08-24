#!/usr/bin/env bash
#
# Prints, as JSON, every `open` bead carrying a failed verification whose verdict may have been
# overtaken by main - so the fleet view can offer the bead back to Psylocke for a second look,
# instead of to an implementer who would build a no-op or a planner who would rewrite a sound plan
# (ah-e0kf).
#
#     .claude/cerebro/scripts/sweep-verdicts.sh --json
#
# A verdict is formed against one specific commit. On a fast day the fleet merges several beads
# while the verification is happening, so by the time the verdict reaches anybody a sibling may
# already have delivered the very thing it found missing. Three beads on 2026-08-23 - `ah-t2pn.3`
# (4 merges), `ah-vocw` (2) and `ah-fjty` (6) - cost two sessions, a planner pass and a bead closed
# unbuilt between them. The commit now lives in the bead's `verified_at` metadata field, written by
# Psylocke at the verdict, and this script is what compares it to main.
#
# This script never mutates anything - no `bd update', no `bd close', no `bd reclaim', no
# `bd set-state', no git write of any kind. Like its four siblings it only gathers facts, so that a
# pure elisp function (`cerebro--verdict-finding') can turn them into a decision and a human confirms
# that decision before anything runs. Keeping this file read-only is what makes that guarantee
# checkable at a glance: the only path to a `bd set-state ... verdict=stale' is the confirmed one in
# `cerebro.el', never this script.
#
# One object per candidate - an `open` bead carrying `verification:failed` and not already carrying
# `verdict:stale`:
#
#   id             the bead id
#   title          for the confirmation prompt
#   priority       the integer, so the fleet view can shout for a 0
#   verified_at    `.metadata.verified_at', or null when the bead has none
#   merges_since   commits on the default branch after `verified_at', or null
#
# `merges_since` is NULL, never 0, in all three unknowable cases, and they must not collapse into a
# number - a distance that is not known is not a small distance:
#
#   * the bead has no `verified_at`. Every verdict recorded before ah-e0kf shipped is in this state,
#     and so is any recorded by a session running an older `verifier.md'. UNKNOWN IS NOT STALE, and
#     `cerebro--verdict-finding' returns nil for it.
#   * the commit is not in this clone at all (`git cat-file -e` fails). The object is checked
#     without a `^{...}` peel, deliberately: `merge-base --is-ancestor` rejects a non-commit on the
#     next line anyway, and the peel syntax would trip this family's own read-only grep.
#   * the commit is not an ancestor of the default branch - a worktree that had drifted, a
#     force-push. Counting `<sha>..origin/<branch>` there gives a number that means nothing.
#
# This consumer squash-merges every PR, so ONE COMMIT ON MAIN IS ONE MERGED PR and the count is
# directly the number the fleet view's line shows.
#
# `non_delivery_commit_pattern` is deliberately NOT applied here, and this is not an oversight:
# that setting exists to answer "did this bead get delivered", which is `sweep-claims.sh's question.
# This sweep asks a different one - "has main moved at all since anybody looked" - for which a
# `docs(<id>): mockup` commit counts exactly like any other.
#
# It judges nothing. Whether an unknown distance is stale, and how many merges are enough, are both
# `cerebro--verdict-finding's, which is pure and therefore testable; a filter here would move a
# guard somewhere it cannot be tested.

set -uo pipefail

if [[ "${1:-}" != "--json" ]]; then
  echo "usage: .claude/cerebro/scripts/sweep-verdicts.sh --json" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo_root="$("$script_dir/consumer-root" --shared 2>/dev/null)" || {
  echo '{"error": "not in a git repository"}'
  exit 1
}

# The branch is resolved rather than assumed (ah-qled.3) - a consumer whose branch is not called
# `main` would otherwise get a distance measured against a branch it does not use.
default_branch="$("$script_dir/default-branch" 2>/dev/null)" || default_branch=""
[[ -n "$default_branch" ]] || default_branch="main"

if ! git -C "$repo_root" fetch --quiet origin "$default_branch" 2>/dev/null; then
  echo '{"error": "could not reach origin; refusing to guess how far main has moved"}'
  exit 1
fi

if ! bd_output="$(bd -C "$repo_root" list --status open --json 2>/dev/null)" || [[ -z "$bd_output" ]]; then
  bd_output="[]"
fi

entries=()
while IFS= read -r bead; do
  [[ -z "$bead" ]] && continue

  id="$(jq -r '.id' <<<"$bead")"
  title="$(jq -r '.title // ""' <<<"$bead")"
  # `// empty` rather than `// 4`: a listing with no priority at all is a shape this does not know,
  # and inventing a number would silence the P0 escalation on the one bead that most needs it.
  priority="$(jq -r 'if (.priority | type) == "number" then .priority else empty end' <<<"$bead")"
  [[ -n "$priority" ]] || priority=null

  # `.metadata // {}` because the key is ABSENT, not empty, when a bead carries no metadata at all -
  # `.metadata.verified_at` errors out in jq rather than returning null.
  verified_at="$(jq -r '(.metadata // {}) | .verified_at // empty' <<<"$bead")"

  merges_since=null
  if [[ -n "$verified_at" ]] \
     && git -C "$repo_root" cat-file -e "$verified_at" 2>/dev/null \
     && git -C "$repo_root" merge-base --is-ancestor "$verified_at" "origin/$default_branch" 2>/dev/null; then
    count="$(git -C "$repo_root" log --oneline "${verified_at}..origin/$default_branch" 2>/dev/null | wc -l | tr -d ' ')"
    [[ -n "$count" ]] && merges_since="$count"
  fi

  if [[ -n "$verified_at" ]]; then
    verified_at_json="$(jq -n --arg v "$verified_at" '$v')"
  else
    verified_at_json=null
  fi

  entry="$(jq -n \
    --arg id "$id" --arg title "$title" \
    --argjson priority "$priority" \
    --argjson verified_at "$verified_at_json" \
    --argjson merges_since "$merges_since" \
    '{id: $id, title: $title, priority: $priority, verified_at: $verified_at, merges_since: $merges_since}')"
  entries+=("$entry")
done < <(jq -c '.[]
  | select((.labels // []) | index("verification:failed"))
  | select(((.labels // []) | index("verdict:stale")) | not)' <<<"$bd_output")

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${entries[@]}" | jq -s '.'
fi
