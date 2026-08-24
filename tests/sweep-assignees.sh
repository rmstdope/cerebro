#!/usr/bin/env bash
#
# Proves scripts/sweep-assignees.sh reports every `open` bead that still carries an assignee, and
# writes nothing (ah-kjfm).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/sweep-assignees.sh

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

minutes_ago() {
  # \$1 = minutes; prints an ISO-8601 UTC timestamp that many minutes in the past.
  local secs=$(( $1 * 60 ))
  date -u -d "@$(( $(date -u +%s) - secs ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r $(( $(date -u +%s) - secs )) +%Y-%m-%dT%H:%M:%SZ
}

# --- a throwaway consumer ----------------------------------------------------------------------
#
# The sweep needs no origin and no branch: it reads `bd` and nothing else. A git repository is all
# it wants, so `consumer-root` has a root to answer with.
consumer="$(consumer_new repo --link consumer-root project-conf sweep-assignees.sh)"
git_q -C "$consumer" commit -q --allow-empty -m "init"

cat > "$beads_file" <<JSON
[
  {"id": "ah-aaa", "assignee": "Cyclops", "title": "stranded P0", "priority": 0,
   "status": "open", "updated_at": "$(minutes_ago 32)"},
  {"id": "ah-bbb", "assignee": "", "title": "nobody on it", "priority": 2,
   "status": "open", "updated_at": "$(minutes_ago 90)"},
  {"id": "ah-ccc", "assignee": "Beast", "title": "just touched", "priority": 1,
   "status": "open", "updated_at": "$(minutes_ago 1)"},
  {"id": "ah-ddd", "title": "no assignee key at all", "priority": 3,
   "status": "open", "updated_at": "$(minutes_ago 45)"}
]
JSON

sweep="$consumer/.claude/cerebro/scripts/sweep-assignees.sh"

out="$("$sweep" --json)" || fail "sweep-assignees.sh --json exited non-zero"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "output is not JSON: $out"

field() { jq -r --arg id "$1" '.[] | select(.id == $id) | .'"$2" <<<"$out"; }

# --- an open bead with an assignee is emitted, with all five fields ----------------------------
[[ "$(field ah-aaa assignee)" == "Cyclops" ]] \
  || fail "ah-aaa: assignee was $(field ah-aaa assignee)"
[[ "$(field ah-aaa title)" == "stranded P0" ]] || fail "ah-aaa: title was $(field ah-aaa title)"
[[ "$(field ah-aaa priority)" == "0" ]] || fail "ah-aaa: priority was $(field ah-aaa priority)"
(( $(field ah-aaa age_min) >= 30 && $(field ah-aaa age_min) < 40 )) \
  || fail "ah-aaa: age_min was $(field ah-aaa age_min), expected about 32"
pass "an open bead carrying an assignee is emitted with its five fields"

# --- the priority is a number, so the fleet view can compare it -------------------------------
# A string "0" is truthy in elisp and would never compare less than anything.
[[ "$(jq -r '.[] | select(.id == "ah-aaa") | .priority | type' <<<"$out")" == "number" ]] \
  || fail "priority is not a JSON number"
pass "priority is a JSON number"

# --- a bead with no assignee is not emitted ---------------------------------------------------
[[ -z "$(field ah-bbb id)" ]] || fail "ah-bbb was emitted despite an empty assignee"
[[ -z "$(field ah-ddd id)" ]] || fail "ah-ddd was emitted despite having no assignee key"
pass "a bead with no assignee is not emitted"

# --- a recently touched bead is still emitted; the grace period is the fleet view's -----------
# The script reports facts and judges nothing: `cerebro--assignee-finding' owns the threshold, and
# a script that filtered here would make that guard untestable.
[[ "$(field ah-ccc assignee)" == "Beast" ]] || fail "ah-ccc was filtered out by the script"
pass "a freshly touched bead is reported, and judged elsewhere"

# --- the script asks bd for open beads only ---------------------------------------------------
# An `in_progress` bead is the claims and stalled sweeps' business, and emitting it here would put
# two lines in front of the navigator for one bead.
grep -q -- "--status open" "$args_file" || fail "bd was not asked for open beads: $(cat "$args_file")"
pass "the script asks bd for open beads only"

# --- the script writes nothing ----------------------------------------------------------------
before_status="$(git -C "$consumer" status --porcelain)"
before_head="$(git -C "$consumer" rev-parse HEAD)"
"$sweep" --json >/dev/null
[[ "$(git -C "$consumer" status --porcelain)" == "$before_status" ]] \
  || fail "the sweep changed the working tree"
[[ "$(git -C "$consumer" rev-parse HEAD)" == "$before_head" ]] || fail "the sweep moved HEAD"
pass "the script writes nothing"

# --- and it contains no mutating command at all -----------------------------------------------
# The invariant `sweep-claims.sh's header states, checked the way that header says it should be:
# the only path to a write is the confirmed one in `cerebro.el'.
# Comments are stripped first: the header *describes* the commands it promises never to run, and a
# grep over the whole file would match its own promise.
if grep -vE "^[[:space:]]*#" "$repo_root/scripts/sweep-assignees.sh" \
     | grep -nE "bd (update|close|reclaim|unclaim)|git (commit|push|checkout|add)"; then
  fail "sweep-assignees.sh contains a mutating command"
fi
pass "the script contains no mutating command"

# --- nothing assigned prints an empty array ---------------------------------------------------
echo '[]' > "$beads_file"
[[ "$("$sweep" --json)" == "[]" ]] || fail "expected [] with nothing assigned"
pass "nothing assigned prints an empty array"

# --- the usage guard --------------------------------------------------------------------------
if "$sweep" >/dev/null 2>&1; then fail "exited zero with no --json"; fi
pass "refuses to run without --json"

echo "all sweep-assignees tests passed"
