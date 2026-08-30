#!/usr/bin/env bash
#
# Proves scripts/sweep-paused.sh reports every open bead parked for the navigator with the `human`
# label, carrying the facts a pure elisp function needs to judge it - and writes nothing (cb-wfb).
#
# The two shapes that matter are the ones that must not collapse into each other: a bead whose
# blockers have all closed, which the fleet view may offer to unpause, and a bead parked for a
# question, which it may not. `blockers` is therefore per-bead, from `bd show`, and filtered to the
# `blocks` edge - a `parent-child` edge in that list would make every child of an open epic look
# blocked for ever.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/sweep-paused.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A stub `bd` on PATH ahead of the real one: the real one would read this machine's own backlog and
# make the test pass or fail by accident. It answers `list` from one file and `show <id>` from a
# file per bead, and records its arguments so the assertions can pin which command was asked for
# which fact.
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
beads_file="$work_dir/beads.json"
show_dir="$work_dir/show"
args_file="$work_dir/bd-args"
mkdir -p "$show_dir"
cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$args_file"
mode=""
id=""
for a in "\$@"; do
  case "\$a" in
    list) mode=list ;;
    show) mode=show ;;
    *) if [ "\$mode" = show ] && [ -z "\$id" ] && [ "\${a#--}" = "\$a" ]; then id="\$a"; fi ;;
  esac
done
if [ "\$mode" = show ]; then
  if [ -f "$show_dir/\$id.json" ]; then cat "$show_dir/\$id.json"; else echo '[]'; fi
else
  cat "$beads_file"
fi
STUB
chmod +x "$stub_dir/bd"
export PATH="$stub_dir:$PATH"

consumer="$(consumer_new repo --link consumer-root sweep-paused.sh)"
sweep="$consumer/.claude/cerebro/scripts/sweep-paused.sh"

# --- an empty board prints an empty array --------------------------------------------------------
echo '[]' > "$beads_file"
out="$(cd "$consumer" && "$sweep" --json)" || fail "sweep-paused.sh --json exited non-zero"
[[ "$out" == "[]" ]] || fail "expected [] with no candidates, got: $out"
pass "a consumer with no human beads prints an empty array"

# --- the board the rest of the suite reads --------------------------------------------------------
cat > "$beads_file" <<'JSON'
[
  {"id": "cb-aaa", "title": "waiting on a prerequisite", "priority": 2,
   "status": "open", "labels": ["human"],
   "metadata": {"paused_at": "2026-08-30T21:00:00Z"}},
  {"id": "cb-bbb", "title": "a question only a person answers", "priority": 1,
   "status": "open", "labels": ["human", "needs-ui-decision"],
   "metadata": {"paused_at": "2026-08-30T20:00:00Z"}},
  {"id": "cb-ccc", "title": "parked before paused_at shipped", "priority": 3,
   "status": "open", "labels": ["human"]},
  {"id": "cb-ddd", "title": "a child of an open epic", "priority": 2,
   "status": "open", "labels": ["human"],
   "metadata": {"paused_at": "2026-08-30T19:00:00Z"}},
  {"id": "cb-eee", "title": "ordinary planned work", "priority": 2,
   "status": "open", "labels": ["planned"]}
]
JSON

cat > "$show_dir/cb-aaa.json" <<'JSON'
[{"id": "cb-aaa", "dependencies": [
  {"id": "cb-zzz", "status": "closed", "dependency_type": "blocks"}]}]
JSON
cat > "$show_dir/cb-bbb.json" <<'JSON'
[{"id": "cb-bbb", "dependencies": []}]
JSON
cat > "$show_dir/cb-ccc.json" <<'JSON'
[{"id": "cb-ccc"}]
JSON
cat > "$show_dir/cb-ddd.json" <<'JSON'
[{"id": "cb-ddd", "dependencies": [
  {"id": "cb-epic", "status": "open", "dependency_type": "parent-child"},
  {"id": "cb-yyy", "status": "open", "dependency_type": "blocks"}]}]
JSON

out="$(cd "$consumer" && "$sweep" --json)" || fail "sweep-paused.sh --json exited non-zero"
jq -e . >/dev/null 2>&1 <<<"$out" || fail "output is not JSON: $out"

field() { jq -r --arg id "$1" '.[] | select(.id == $id) | .'"$2" <<<"$out"; }

# --- a parked bead is emitted with all six fields --------------------------------------------------
[[ "$(field cb-aaa title)" == "waiting on a prerequisite" ]] \
  || fail "cb-aaa: title was $(field cb-aaa title)"
[[ "$(field cb-aaa priority)" == "2" ]] || fail "cb-aaa: priority was $(field cb-aaa priority)"
[[ "$(field cb-aaa paused_at)" == "2026-08-30T21:00:00Z" ]] \
  || fail "cb-aaa: paused_at was $(field cb-aaa paused_at)"
[[ "$(field cb-aaa ui_decision)" == "false" ]] \
  || fail "cb-aaa: ui_decision was $(field cb-aaa ui_decision)"
[[ "$(field cb-aaa 'blockers[0].id')" == "cb-zzz" ]] \
  || fail "cb-aaa: blocker id was $(field cb-aaa 'blockers[0].id')"
[[ "$(field cb-aaa 'blockers[0].status')" == "closed" ]] \
  || fail "cb-aaa: blocker status was $(field cb-aaa 'blockers[0].status')"
[[ "$(jq -r '.[] | select(.id == "cb-aaa") | .priority | type' <<<"$out")" == "number" ]] \
  || fail "priority is not a JSON number"
pass "a human bead with a closed blocker is emitted with its six fields"

# --- a user-facing question says so ---------------------------------------------------------------
[[ "$(field cb-bbb ui_decision)" == "true" ]] \
  || fail "cb-bbb: ui_decision was $(field cb-bbb ui_decision), expected true"
[[ "$(field cb-bbb 'blockers | length')" == "0" ]] \
  || fail "cb-bbb: blockers was $(field cb-bbb blockers)"
pass "a bead carrying needs-ui-decision reads ui_decision true, with no blockers"

# --- an unknown pause time is null, never a number --------------------------------------------------
# Unknown is not recent: every bead parked before `paused_at` shipped is in this state, and the
# panel renders it as an em dash rather than inventing an age.
[[ "$(field cb-ccc paused_at)" == "null" ]] \
  || fail "cb-ccc: paused_at was $(field cb-ccc paused_at), expected null"
[[ "$(field cb-ccc 'blockers | length')" == "0" ]] \
  || fail "cb-ccc: a bead with no dependencies field must read as no blockers"
pass "a bead with no metadata reads paused_at null, and no dependencies reads blockers []"

# --- only a `blocks` edge is a blocker --------------------------------------------------------------
# Without the filter a child's own parent epic - which never closes until the child does - would sit
# in `blockers` for ever, and the sweep would never fire on any child of any epic.
[[ "$(field cb-ddd 'blockers | length')" == "1" ]] \
  || fail "cb-ddd: blockers was $(field cb-ddd blockers), expected the blocks edge alone"
[[ "$(field cb-ddd 'blockers[0].id')" == "cb-yyy" ]] \
  || fail "cb-ddd: blocker id was $(field cb-ddd 'blockers[0].id')"
pass "a parent-child dependency is not a blocker"

# --- a bead nobody parked is not a candidate --------------------------------------------------------
[[ -z "$(field cb-eee id)" ]] || fail "cb-eee was emitted despite carrying no human label"
pass "a bead without the human label is not emitted"

# --- the script asks bd for open beads only ---------------------------------------------------------
grep -q -- "--status open" "$args_file" || fail "bd was not asked for open beads: $(cat "$args_file")"
pass "the script asks bd for open beads only"

# --- the script writes nothing ------------------------------------------------------------------------
before_status="$(git -C "$consumer" status --porcelain)"
before_head="$(git -C "$consumer" rev-parse HEAD)"
(cd "$consumer" && "$sweep" --json >/dev/null)
[[ "$(git -C "$consumer" status --porcelain)" == "$before_status" ]] \
  || fail "the sweep changed the working tree"
[[ "$(git -C "$consumer" rev-parse HEAD)" == "$before_head" ]] || fail "the sweep moved HEAD"
pass "the script writes nothing"

# --- and it contains no mutating command at all ---------------------------------------------------------
# The invariant the header states, checked the way its siblings check theirs. Comments are stripped
# first - the header *describes* the commands it promises never to run.
if grep -vE "^[[:space:]]*#" "$repo_root/scripts/sweep-paused.sh" \
     | grep -nE "bd (update|close|reclaim|unclaim|set-state)|git (commit|push|checkout|add|reset)"; then
  fail "sweep-paused.sh contains a mutating command"
fi
pass "the script contains no mutating command"

# --- the usage guard ---------------------------------------------------------------------------------
if (cd "$consumer" && "$sweep" >/dev/null 2>&1); then fail "exited zero with no --json"; fi
if (cd "$consumer" && "$sweep" --all >/dev/null 2>&1); then fail "exited zero with --all"; fi
usage="$( (cd "$consumer" && "$sweep" --all 2>&1 >/dev/null) || true)"
[[ "$usage" == *"--json"* ]] || fail "the usage line does not name --json: $usage"
pass "the usage guard refuses anything but --json, naming it on stderr"

suite_passed
