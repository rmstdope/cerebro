#!/usr/bin/env bash
#
# Proves scripts/sweep-stalled.sh reports, for every `in_progress` bead, how long it has been since
# the last sign of progress - a commit on the bead's own branch when there is one, and the claim
# itself when there is not (ah-4xm4).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/sweep-stalled.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A stub `bd` on PATH ahead of the real one: the real one would read this machine's own backlog and
# make the test pass or fail by accident.
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
beads_file="$work_dir/beads.json"
cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
cat "$beads_file"
STUB
chmod +x "$stub_dir/bd"
export PATH="$stub_dir:$PATH"

minutes_ago() {
  # $1 = minutes; prints an ISO-8601 UTC timestamp that many minutes in the past.
  local secs=$(( $1 * 60 ))
  date -u -d "@$(( $(date -u +%s) - secs ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r $(( $(date -u +%s) - secs )) +%Y-%m-%dT%H:%M:%SZ
}

# --- a throwaway consumer with an origin, whose default branch is deliberately hours old -------
#
# THE BRANCH IS A PARAMETER, and it is deliberately not `main` (ah-qled.3): while the fixture said
# `main` and the script said `main` the two agreed, and no assertion here could catch a consumer
# whose branch is called anything else - which is precisely the bug this suite failed to see. Every
# case below now runs against a `trunk` consumer, so all of them pin the resolution as well as
# whatever they were pinning before.
#
# It is declared in project.conf rather than left to detection because this fixture builds
# its remote with `git remote add`, which leaves refs/remotes/origin/HEAD unset - ordinary, and
# exactly the case the resolver falls through on.
branch="trunk"

origin="$work_dir/origin.git"
git init -q --bare "$origin"

consumer="$(consumer_new repo --branch "$branch" --link consumer-root project-conf default-branch sweep-stalled.sh)"
mkdir -p "$consumer/.cerebro"
printf 'default_branch %s\n' "$branch" > "$consumer/.cerebro/project.conf"
old_date="$(minutes_ago 300)"
GIT_AUTHOR_DATE="$old_date" GIT_COMMITTER_DATE="$old_date" \
  git_q -C "$consumer" commit -q --allow-empty -m "init"
git_q -C "$consumer" remote add origin "$origin"
git_q -C "$consumer" push -q -u origin "$branch"

# ah-aaa: a branch that committed two minutes ago.
git_q -C "$consumer" worktree add -q "$consumer/.cerebro/worktrees/ah-aaa" -b ah-aaa-recent
recent="$(minutes_ago 2)"
GIT_AUTHOR_DATE="$recent" GIT_COMMITTER_DATE="$recent" \
  git_q -C "$consumer/.cerebro/worktrees/ah-aaa" commit -q --allow-empty -m "feat(ah-aaa): work"

# ah-bbb: a branch whose only commit is three hours old.
git_q -C "$consumer" worktree add -q "$consumer/.cerebro/worktrees/ah-bbb" -b ah-bbb-stale
stale="$(minutes_ago 180)"
GIT_AUTHOR_DATE="$stale" GIT_COMMITTER_DATE="$stale" \
  git_q -C "$consumer/.cerebro/worktrees/ah-bbb" commit -q --allow-empty -m "feat(ah-bbb): work"

# ah-ccc: a fresh branch with no commit of its own - it points at main's five-hour-old commit.
git_q -C "$consumer" worktree add -q "$consumer/.cerebro/worktrees/ah-ccc" -b ah-ccc-fresh

# ah-ddd: claimed, no worktree at all.

cat > "$beads_file" <<JSON
[
  {"id": "ah-aaa", "assignee": "Cyclops", "title": "recent commit",
   "started_at": "$(minutes_ago 240)"},
  {"id": "ah-bbb", "assignee": "Beast", "title": "old commit",
   "started_at": "$(minutes_ago 240)"},
  {"id": "ah-ccc", "assignee": "Storm", "title": "no commit yet",
   "started_at": "$(minutes_ago 4)"},
  {"id": "ah-ddd", "assignee": "Rogue", "title": "no worktree",
   "started_at": "$(minutes_ago 90)"}
]
JSON

sweep="$consumer/.claude/cerebro/scripts/sweep-stalled.sh"

"$sweep" >/dev/null 2>&1 || true   # usage guard below covers the no-argument case
out="$("$sweep" --json)" || fail "sweep-stalled.sh --json exited non-zero"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "output is not JSON: $out"

field() { jq -r --arg id "$1" '.[] | select(.id == $id) | .'"$2" <<<"$out"; }

# --- a bead whose branch committed recently is not stalled ------------------------------------
[[ "$(field ah-aaa progress_source)" == "commit" ]] \
  || fail "ah-aaa: progress_source was $(field ah-aaa progress_source), not commit"
[[ "$(field ah-aaa branch)" == "ah-aaa-recent" ]] \
  || fail "ah-aaa: branch was $(field ah-aaa branch)"
(( $(field ah-aaa progress_age_min) < 10 )) \
  || fail "ah-aaa: progress_age_min was $(field ah-aaa progress_age_min), expected under 10"
pass "a bead whose branch committed recently is not stalled"

# --- an old commit on the branch is measured from that commit ---------------------------------
[[ "$(field ah-bbb progress_source)" == "commit" ]] || fail "ah-bbb: not measured from the commit"
(( $(field ah-bbb progress_age_min) > 120 )) \
  || fail "ah-bbb: progress_age_min was $(field ah-bbb progress_age_min), expected over 120"
pass "a branch whose last commit is hours old reports that age"

# --- a branch with no commit measures from the claim ------------------------------------------
[[ "$(field ah-ccc progress_source)" == "claim" ]] \
  || fail "ah-ccc: progress_source was $(field ah-ccc progress_source), not claim"
[[ "$(field ah-ccc branch)" == "ah-ccc-fresh" ]] \
  || fail "ah-ccc: branch was $(field ah-ccc branch)"
pass "a branch with no commit measures from the claim"

# --- a fresh branch is not stalled by main's commit date --------------------------------------
# main's only commit is five hours old and ah-ccc-fresh points straight at it. Measuring bare HEAD
# rather than origin/$branch..HEAD would report this just-claimed bead as 300 minutes stale.
(( $(field ah-ccc progress_age_min) < 30 )) \
  || fail "ah-ccc: progress_age_min was $(field ah-ccc progress_age_min) - main's date leaked in"
pass "a fresh branch is not stalled by main's commit date"

# --- a bead with no worktree reports a null branch --------------------------------------------
[[ "$(field ah-ddd branch)" == "null" ]] || fail "ah-ddd: branch was $(field ah-ddd branch)"
[[ "$(field ah-ddd progress_source)" == "claim" ]] || fail "ah-ddd: not measured from the claim"
(( $(field ah-ddd progress_age_min) > 60 )) \
  || fail "ah-ddd: progress_age_min was $(field ah-ddd progress_age_min), expected over 60"
pass "a bead with no worktree reports a null branch"

# --- the branch match needs its trailing hyphen -----------------------------------------------
# ah-aaa must not pick up a branch belonging to a child of itself.
git_q -C "$consumer" worktree add -q "$consumer/.cerebro/worktrees/ah-aaa.1" -b ah-aaa.1-child
after="$("$sweep" --json)"
[[ "$(jq -r '.[] | select(.id == "ah-aaa") | .branch' <<<"$after")" == "ah-aaa-recent" ]] \
  || fail "ah-aaa matched a child's branch"
pass "the branch match does not reach a child bead's branch"

# --- the script writes nothing ----------------------------------------------------------------
before_status="$(git -C "$consumer" status --porcelain)"
before_head="$(git -C "$consumer" rev-parse HEAD)"
"$sweep" --json >/dev/null
[[ "$(git -C "$consumer" status --porcelain)" == "$before_status" ]] \
  || fail "the sweep changed the working tree"
[[ "$(git -C "$consumer" rev-parse HEAD)" == "$before_head" ]] || fail "the sweep moved HEAD"
pass "the script writes nothing"

# --- nothing claimed prints an empty array ----------------------------------------------------
echo '[]' > "$beads_file"
[[ "$("$sweep" --json)" == "[]" ]] || fail "expected [] with nothing claimed"
pass "nothing claimed prints an empty array"

# --- the usage guard --------------------------------------------------------------------------
if "$sweep" >/dev/null 2>&1; then fail "exited zero with no --json"; fi
pass "refuses to run without --json"

echo "all sweep-stalled tests passed"
