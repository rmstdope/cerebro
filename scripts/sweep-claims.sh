#!/usr/bin/env bash
#
# Prints, as JSON, every fact the fleet view needs to decide whether a live claim is actually a bead
# an implementer delivered and never closed.
#
#     .claude/cerebro/scripts/sweep-claims.sh --json
#
# This script never mutates anything - no `bd close`, no `bd reclaim`, no git write of any kind. It
# only gathers the facts `agents/orchestrator.md`'s "Beads that finished without being closed"
# section already spells out as the guard conditions, so that a pure elisp function
# (`cerebro--claim-finding`) can turn them into a decision, and a human confirms every one of those
# decisions before anything destructive runs. Keeping this script read-only is what makes that
# guarantee checkable at a glance: the only way to reach a `bd close` or `bd reclaim` invocation is
# through the confirmed path in `cerebro.el`, never through this file.
#
# One object per `in_progress` bead:
#
#   id                    the bead id
#   assignee              whatever `bd` has on file - a roster name for a claim made by a launched
#                          session (see ah-rnz), or anything else for a claim made by hand
#   title                 the bead's title, for the confirmation prompt
#   verification_failed   the bead carries `verification:failed` - Psylocke reopened it, and its old
#                          commits are already on main, so `on_main` below proves nothing about
#                          whether the rework has landed. Never sweep-closed.
#   on_main               a commit matching "(<id>): " is on the default branch at origin,
#                          discounting any
#                          `docs(<id>): mockup` commit - that lands while the bead is still being
#                          planned and is not delivery.
#   commit_age_min         minutes since that commit, or null if `on_main` is false
#   docs_only              a `docs(<id>): mockup` commit matched and nothing else did - the bead is
#                          not delivered, only planned.
#   lease_age_min          minutes since `lease_expires_at`, negative while the lease still holds -
#                          the number `bd reclaim --id <id> --older-than 10m` itself would act on.
#                          A bead whose assignee never held a lease (predates leases, or a schema
#                          this script does not recognise) reports null here rather than a guess.
#
# `lease_age_min` exists because `assignee' alone cannot tell a dead implementer from a live claim
# held by hand or by a session this script's roster does not know about: a name that is not on
# `scripts/roster' is not a `pid'-tracked session and never will be, but the bead can be very
# much in flight under it. `agents/orchestrator.md's own rule is "an expired lease with no live
# agent behind it" - not "an unfamiliar name" - and the elisp guard keys on this field, not on
# `assignee' membership, for exactly that reason.

set -uo pipefail

if [[ "${1:-}" != "--json" ]]; then
  echo "usage: .claude/cerebro/scripts/sweep-claims.sh --json" >&2
  exit 2
fi

# The shared checkout every worktree of the repository has in common — see
# scripts/consumer-root's header for the two roots and why a sweep needs the shared one, never the
# enclosing tree a bead worktree's own submodule copy would otherwise answer.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo_root="$("$script_dir/consumer-root" --shared 2>/dev/null)" || {
  echo '{"error": "not in a git repository"}'
  exit 1
}

# The branch is resolved rather than assumed (ah-qled.3) - a consumer whose branch is not called
# `main` used to get "could not reach origin" here, which fails closed but blocks the sweep entirely.
default_branch="$("$script_dir/default-branch" 2>/dev/null)" || default_branch=""
[[ -n "$default_branch" ]] || default_branch="main"

# How a commit subject names the bead it delivers, and which such subjects are not deliveries. Both
# substitute `{id}`; see where they are used below for why substitution rather than a prefix.
commit_ref_pattern="$("$script_dir/project-conf" commit_ref_pattern '({id}):' 2>/dev/null || echo '({id}):')"
[[ -n "$commit_ref_pattern" ]] || commit_ref_pattern='({id}):'
non_delivery_commit_pattern="$("$script_dir/project-conf" non_delivery_commit_pattern 2>/dev/null || true)"

if ! git -C "$repo_root" fetch --quiet origin "$default_branch" 2>/dev/null; then
  echo '{"error": "could not reach origin; refusing to guess whether a claim landed"}'
  exit 1
fi

# ISO-8601 UTC ("2026-08-14T23:43:39Z") to a Unix timestamp. GNU date takes `-d`; BSD/macOS date
# has no such flag and wants `-j -f` with an explicit format instead - try GNU first and fall back
# rather than branching on `uname`, which would miss a GNU coreutils install on macOS.
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

if ! bd_output="$(bd -C "$repo_root" list --status in_progress --json 2>/dev/null)" || [[ -z "$bd_output" ]]; then
  bd_output="[]"
fi

now_epoch="$(date -u +%s)"

entries=()
while IFS= read -r bead; do
  [[ -z "$bead" ]] && continue
  id="$(jq -r '.id' <<<"$bead")"
  assignee="$(jq -r '.assignee // ""' <<<"$bead")"
  title="$(jq -r '.title // ""' <<<"$bead")"
  verification_failed="$(jq -c 'any(.labels[]?; . == "verification:failed")' <<<"$bead")"

  lease_expires_at="$(jq -r '.lease_expires_at // empty' <<<"$bead")"
  lease_age_min=null
  if [[ -n "$lease_expires_at" ]]; then
    lease_epoch="$(iso_to_epoch "$lease_expires_at" || true)"
    if [[ -n "$lease_epoch" ]]; then
      lease_age_min=$(( (now_epoch - lease_epoch) / 60 ))
    fi
  fi

  # How this consumer's commits name the bead they deliver. The default `({id}):` is the
  # Conventional-Commits scope this repository uses, and the colon and parens matter: bare "$id"
  # also matches "$id.8", a child of this bead.
  #
  # `{id}` is SUBSTITUTED, not concatenated as a prefix (ah-qled.4). A consumer whose subjects read
  # `PROJ-9 done:` or put the id anywhere but the front could not be expressed by a prefix, so the
  # sweep read `on_main:false` for every bead and silently did nothing at all.
  match_pattern="${commit_ref_pattern//\{id\}/$id}"
  match_commits="$(git -C "$repo_root" log "origin/$default_branch" --grep "$match_pattern" -F --oneline 2>/dev/null || true)"

  # What in this consumer's history is NOT a delivery — here, `plan-bead`'s mockup commit. It
  # DEFAULTS TO EMPTY, because excluding a subject nobody else writes is this project's convention
  # rather than a fact about sweeping claims; a consumer that wants it declares it.
  if [[ -n "$non_delivery_commit_pattern" ]]; then
    non_mockup="$(printf '%s\n' "$match_commits" | grep -vF "${non_delivery_commit_pattern//\{id\}/$id}" || true)"
  else
    non_mockup="$match_commits"
  fi

  docs_only=false
  on_main=false
  commit_age_min=null

  if [[ -n "$match_commits" && -z "$non_mockup" ]]; then
    docs_only=true
  fi

  if [[ -n "$non_mockup" ]]; then
    on_main=true
    hash="$(printf '%s\n' "$non_mockup" | head -n1 | awk '{print $1}')"
    committed_at="$(git -C "$repo_root" log -1 --format='%ct' "$hash" 2>/dev/null || true)"
    if [[ -n "$committed_at" ]]; then
      commit_age_min=$(( ($(date +%s) - committed_at) / 60 ))
    fi
  fi

  entry="$(jq -n \
    --arg id "$id" --arg assignee "$assignee" --arg title "$title" \
    --argjson verification_failed "$verification_failed" \
    --argjson on_main "$on_main" \
    --argjson docs_only "$docs_only" \
    --argjson commit_age_min "$commit_age_min" \
    --argjson lease_age_min "$lease_age_min" \
    '{id: $id, assignee: $assignee, title: $title,
      verification_failed: $verification_failed, on_main: $on_main,
      commit_age_min: $commit_age_min, docs_only: $docs_only,
      lease_age_min: $lease_age_min}')"
  entries+=("$entry")
done < <(jq -c '.[]' <<<"$bd_output")

if [[ ${#entries[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${entries[@]}" | jq -s '.'
fi
