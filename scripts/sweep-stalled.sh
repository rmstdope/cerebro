#!/usr/bin/env bash
#
# Prints, as JSON, how long every `in_progress` bead has gone without a sign of progress - so the
# fleet view can offer a claim held by a live session that has stopped moving (ah-4xm4).
#
#     .claude/cerebro/scripts/sweep-stalled.sh --json
#
# This script never mutates anything - no `bd`, no git write of any kind. Like its two siblings it
# only gathers facts, so that a pure elisp function (`cerebro--stalled-finding') can turn them into
# a decision and a human confirms that decision before anything runs. Keeping this file read-only
# is what makes that guarantee checkable at a glance: the only path to a `bd unclaim' is the
# confirmed one in `cerebro.el', never this script.
#
# `sweep-claims.sh' answers the opposite question and cannot be reused for this one: its
# `commit_age_min' is measured against `origin/main', and only once the work has already landed.
# What a stalled claim needs is progress on a branch that has *not* landed.
#
# One object per `in_progress` bead:
#
#   id, assignee, title   as `sweep-claims.sh'
#   branch                the bead's branch, from a worktree under `.cerebro/worktrees', or null
#                          when no worktree holds one
#   progress_age_min      minutes since the last sign of progress
#   progress_source       "commit" or "claim" - which of the two the age was taken from, so the
#                          fleet view's line can say which and a reader is never left guessing
#
# Two traps this file exists downstream of:
#
#   * Progress is measured with `git log origin/main..HEAD', never bare `HEAD'. A freshly created
#     branch points at the commit it forked from, whose timestamp is main's and may be hours old -
#     bare `HEAD' would report every new claim as stalled the moment main happened to be stale.
#   * The branch is matched on `<id>-', with the trailing hyphen. Without it `ah-t65' also matches
#     `ah-t65.1's branch - the same trap `sweep-claims.sh:95' documents for its commit grep.

set -uo pipefail

if [[ "${1:-}" != "--json" ]]; then
  echo "usage: .claude/cerebro/scripts/sweep-stalled.sh --json" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo_root="$("$script_dir/consumer-root" --shared 2>/dev/null)" || {
  echo '{"error": "not in a git repository"}'
  exit 1
}

if ! git -C "$repo_root" fetch --quiet origin main 2>/dev/null; then
  echo '{"error": "could not reach origin; refusing to guess whether a branch has moved"}'
  exit 1
fi

# ISO-8601 UTC ("2026-08-14T23:43:39Z") to a Unix timestamp. GNU date takes `-d`; BSD/macOS date
# has no such flag and wants `-j -f` instead - try GNU first and fall back rather than branching on
# `uname`, which would miss a GNU coreutils install on macOS.
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

if ! bd_output="$(bd -C "$repo_root" list --status in_progress --json 2>/dev/null)" || [[ -z "$bd_output" ]]; then
  bd_output="[]"
fi

now_epoch="$(date -u +%s)"

# Every worktree of the shared checkout, as "<path>\t<branch>" lines.
worktrees="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{p=substr($0,10)} /^branch /{b=substr($0,8); sub("^refs/heads/","",b); print p "\t" b}')"

entries=()
while IFS= read -r bead; do
  [[ -z "$bead" ]] && continue
  id="$(jq -r '.id' <<<"$bead")"
  assignee="$(jq -r '.assignee // ""' <<<"$bead")"
  title="$(jq -r '.title // ""' <<<"$bead")"
  started_at="$(jq -r '.started_at // empty' <<<"$bead")"

  branch=null
  worktree=""
  while IFS=$'\t' read -r wt_path wt_branch; do
    [[ -z "$wt_branch" ]] && continue
    if [[ "$wt_branch" == "$id-"* ]]; then
      branch="$(jq -n --arg b "$wt_branch" '$b')"
      worktree="$wt_path"
      break
    fi
  done <<<"$worktrees"

  progress_age_min=null
  progress_source=null

  if [[ -n "$worktree" ]]; then
    committed_at="$(git -C "$worktree" log origin/main..HEAD -1 --format='%ct' 2>/dev/null || true)"
    if [[ -n "$committed_at" ]]; then
      progress_age_min=$(( (now_epoch - committed_at) / 60 ))
      progress_source='"commit"'
    fi
  fi

  if [[ "$progress_source" == null && -n "$started_at" ]]; then
    started_epoch="$(iso_to_epoch "$started_at" || true)"
    if [[ -n "$started_epoch" ]]; then
      progress_age_min=$(( (now_epoch - started_epoch) / 60 ))
      progress_source='"claim"'
    fi
  fi

  entry="$(jq -n \
    --arg id "$id" --arg assignee "$assignee" --arg title "$title" \
    --argjson branch "$branch" \
    --argjson progress_age_min "$progress_age_min" \
    --argjson progress_source "$progress_source" \
    '{id: $id, assignee: $assignee, title: $title, branch: $branch,
      progress_age_min: $progress_age_min, progress_source: $progress_source}')"
  entries+=("$entry")
done < <(jq -c '.[]' <<<"$bd_output")

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${entries[@]}" | jq -s '.'
fi
