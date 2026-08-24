#!/usr/bin/env bash
#
# Proves scripts/sweep-verdicts.sh reports how far the default branch has moved since each failed
# verdict's own commit, and writes nothing (ah-e0kf).
#
# The three unknowable cases are the point of this suite. `merges_since` must be null, never 0, when
# the bead has no `verified_at`, when the commit is not in the clone, and when it is not an ancestor
# of the default branch - a distance that is not known is not a small distance, and collapsing them
# into a number would make every verdict recorded before this shipped look stale.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/sweep-verdicts.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A stub `bd` on PATH ahead of the real one: the real one would read this machine's own backlog and
# make the test pass or fail by accident. It records the arguments it was given, so the assertion
# below can pin that the script asked for open beads rather than filtering a full listing itself.
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
beads_file="$work_dir/beads.json"
args_file="$work_dir/bd-args"
cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$args_file"
cat "$beads_file"
STUB
chmod +x "$stub_dir/bd"
export PATH="$stub_dir:$PATH"

# --- a throwaway consumer, with a real branch to measure against --------------------------------
#
# Unlike `sweep-assignees.sh` this one needs git as well as `bd`: the whole of its arithmetic is
# `git log <sha>..origin/<branch>`. So the consumer gets an `origin` of its own - a bare repository
# it can fetch from - rather than a bare `git init`.
origin="$work_dir/origin.git"
git init -q --bare -b main "$origin"

consumer="$(consumer_new repo --link consumer-root project-conf default-branch sweep-verdicts.sh)"
git_q -C "$consumer" commit -q --allow-empty -m "init"
verdict_sha="$(git -C "$consumer" rev-parse HEAD)"
# Three commits after the verdict's own, so the distance is a number this suite can pin exactly.
for n in 1 2 3; do
  git_q -C "$consumer" commit -q --allow-empty -m "later $n"
done
git -C "$consumer" remote add origin "$origin"
git -C "$consumer" push -q origin main

# A commit that exists in the clone but is NOT an ancestor of the branch - the force-push and
# drifted-worktree case, which must read null rather than a count.
git -C "$consumer" checkout -q -b sideline "$verdict_sha"
git_q -C "$consumer" commit -q --allow-empty -m "off the branch"
off_branch_sha="$(git -C "$consumer" rev-parse HEAD)"
git -C "$consumer" checkout -q main

absent_sha="0000000000000000000000000000000000000000"

cat > "$beads_file" <<JSON
[
  {"id": "ah-aaa", "title": "verdict main has moved past", "priority": 0,
   "status": "open", "labels": ["verification:failed"],
   "metadata": {"verified_at": "$verdict_sha"}},
  {"id": "ah-bbb", "title": "no metadata at all", "priority": 2,
   "status": "open", "labels": ["verification:failed"]},
  {"id": "ah-ccc", "title": "commit not in this clone", "priority": 2,
   "status": "open", "labels": ["verification:failed"],
   "metadata": {"verified_at": "$absent_sha"}},
  {"id": "ah-ddd", "title": "commit not on the branch", "priority": 1,
   "status": "open", "labels": ["verification:failed"],
   "metadata": {"verified_at": "$off_branch_sha"}},
  {"id": "ah-eee", "title": "already flagged", "priority": 0,
   "status": "open", "labels": ["verification:failed", "verdict:stale"],
   "metadata": {"verified_at": "$verdict_sha"}},
  {"id": "ah-fff", "title": "passed, not failed", "priority": 0,
   "status": "open", "labels": ["verification:passed"],
   "metadata": {"verified_at": "$verdict_sha"}}
]
JSON

sweep="$consumer/.claude/cerebro/scripts/sweep-verdicts.sh"

out="$(cd "$consumer" && "$sweep" --json)" || fail "sweep-verdicts.sh --json exited non-zero"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "output is not JSON: $out"

field() { jq -r --arg id "$1" '.[] | select(.id == $id) | .'"$2" <<<"$out"; }

# --- a failed verdict is emitted, with all five fields ------------------------------------------
[[ "$(field ah-aaa title)" == "verdict main has moved past" ]] \
  || fail "ah-aaa: title was $(field ah-aaa title)"
[[ "$(field ah-aaa priority)" == "0" ]] || fail "ah-aaa: priority was $(field ah-aaa priority)"
[[ "$(field ah-aaa verified_at)" == "$verdict_sha" ]] \
  || fail "ah-aaa: verified_at was $(field ah-aaa verified_at)"
[[ "$(field ah-aaa merges_since)" == "3" ]] \
  || fail "ah-aaa: merges_since was $(field ah-aaa merges_since), expected 3"
pass "a failed verdict is emitted with its five fields, and the distance is the commit count"

# --- the numbers are JSON numbers ---------------------------------------------------------------
# A string "0" is truthy in elisp and would never compare less than anything.
[[ "$(jq -r '.[] | select(.id == "ah-aaa") | .priority | type' <<<"$out")" == "number" ]] \
  || fail "priority is not a JSON number"
[[ "$(jq -r '.[] | select(.id == "ah-aaa") | .merges_since | type' <<<"$out")" == "number" ]] \
  || fail "merges_since is not a JSON number"
pass "priority and merges_since are JSON numbers"

# --- the three unknowable cases are null, never 0 -----------------------------------------------
# Unknown is not stale: `cerebro--verdict-finding' returns nil for a null distance, and a 0 here
# would be a *known* distance below the threshold - the same decision by accident rather than by
# the guard the elisp suite pins.
for id in ah-bbb ah-ccc ah-ddd; do
  [[ "$(field "$id" merges_since)" == "null" ]] \
    || fail "$id: merges_since was $(field "$id" merges_since), expected null"
done
[[ "$(field ah-bbb verified_at)" == "null" ]] \
  || fail "ah-bbb: verified_at was $(field ah-bbb verified_at), expected null"
pass "no metadata, a missing commit and a commit off the branch all read null"

# --- a bead already flagged is not emitted again ------------------------------------------------
# Without this the sweep would re-offer the same bead every cycle after the next merge lands.
[[ -z "$(field ah-eee id)" ]] || fail "ah-eee was emitted despite carrying verdict:stale"
pass "a bead already carrying verdict:stale is not emitted"

# --- only a failed verification is a candidate ---------------------------------------------------
[[ -z "$(field ah-fff id)" ]] || fail "ah-fff was emitted despite passing verification"
pass "a bead with no failed verdict is not emitted"

# --- the script asks bd for open beads only -------------------------------------------------------
# A `verdict:stale' bead is open, and so is every bead this sweep judges: a closed one has no verdict
# to have gone stale.
grep -q -- "--status open" "$args_file" || fail "bd was not asked for open beads: $(cat "$args_file")"
pass "the script asks bd for open beads only"

# --- the script writes nothing --------------------------------------------------------------------
before_status="$(git -C "$consumer" status --porcelain)"
before_head="$(git -C "$consumer" rev-parse HEAD)"
(cd "$consumer" && "$sweep" --json >/dev/null)
[[ "$(git -C "$consumer" status --porcelain)" == "$before_status" ]] \
  || fail "the sweep changed the working tree"
[[ "$(git -C "$consumer" rev-parse HEAD)" == "$before_head" ]] || fail "the sweep moved HEAD"
pass "the script writes nothing"

# --- and it contains no mutating command at all -----------------------------------------------------
# The invariant `sweep-claims.sh's header states, checked the way that header says it should be: the
# only path to a write is the confirmed one in `cerebro.el'. Comments are stripped first - the header
# *describes* the commands it promises never to run, and a grep over the whole file would match its
# own promise.
if grep -vE "^[[:space:]]*#" "$repo_root/scripts/sweep-verdicts.sh" \
     | grep -nE "bd (update|close|reclaim|unclaim|set-state)|git (commit|push|checkout|add|reset)"; then
  fail "sweep-verdicts.sh contains a mutating command"
fi
pass "the script contains no mutating command"

# --- no candidates prints an empty array ---------------------------------------------------------
echo '[]' > "$beads_file"
[[ "$(cd "$consumer" && "$sweep" --json)" == "[]" ]] || fail "expected [] with no candidates"
pass "no candidates prints an empty array"

# --- the usage guard -------------------------------------------------------------------------------
if (cd "$consumer" && "$sweep" >/dev/null 2>&1); then fail "exited zero with no --json"; fi
pass "the usage guard refuses anything but --json"

echo "all sweep-verdicts assertions passed"
