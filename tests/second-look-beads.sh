#!/usr/bin/env bash
#
# Proves `scripts/second-look-beads`: the open beads that need the verifier's second look.
#
# Two states reach her there, and neither can arrive on a closed-bead list. `verdict:stale` was
# learnt by ah-e0kf; the handed-back state - `verification:failed` with neither `planned` nor
# `plan:revise` - was learnt by ah-zuhs, after a bead sat eleven hours reachable by no role at all.
#
# The `bd` behind `work-beads` is stubbed, so this suite never reads this machine's own backlog:
# it must pass or fail on the fixture, not by accident.
#
#     bash tests/second-look-beads.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

stub_dir="$(mktemp -d)"
consumer="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$consumer"' EXIT

# The script resolves its root through `work-beads`, which uses `consumer-root --shared` and so
# answers only when this copy of cerebro is mounted at <consumer>/.claude/cerebro (ah-il8j).
git init -q "$consumer"
mkdir -p "$consumer/.claude/cerebro"
for d in scripts agents skills hooks; do
  [ -d "$repo_root/$d" ] && cp -R "$repo_root/$d" "$consumer/.claude/cerebro/"
done

stub_stdout="$stub_dir/stdout"
argv_file="$stub_dir/argv"

cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
: > "$argv_file"
for a in "\$@"; do printf 'ARG:%s\n' "\$a" >> "$argv_file"; done
cat "$stub_stdout"
STUB
chmod +x "$stub_dir/bd"

run() {
  PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/second-look-beads" "$@"
}

# Six states, one fixture. Each bead is open - `bd` is asked for open beads and answers with these.
cat > "$stub_stdout" <<'JSON'
[
  {"id":"ah-stale",       "issue_type":"bug",  "labels":["verdict:stale"]},
  {"id":"ah-handed-back", "issue_type":"bug",  "labels":["verification:failed"]},
  {"id":"ah-implementer", "issue_type":"bug",  "labels":["verification:failed","planned"]},
  {"id":"ah-planner",     "issue_type":"bug",  "labels":["verification:failed","plan:revise"]},
  {"id":"ah-both",        "issue_type":"bug",  "labels":["verdict:stale","verification:failed","planned"]},
  {"id":"ah-planned-0th", "issue_type":"bug",  "labels":["planned","verification:failed"]},
  {"id":"ah-ordinary",    "issue_type":"task", "labels":["planned"]},
  {"id":"ah-nolabels",    "issue_type":"task"}
]
JSON

ids="$(run)"

listed() {
  printf '%s\n' "$ids" | grep -qxF "$1"
}

# --- the two states that must be listed ---------------------------------------------------------
listed ah-stale        || fail "an open verdict:stale bead was not listed"
pass "lists an open verdict:stale bead"

listed ah-handed-back  || fail "an open verification:failed bead with neither other label was not listed"
pass "lists a bead handed back as nothing-to-build"

# --- the states somebody else already owns ------------------------------------------------------
if listed ah-implementer; then fail "a verification:failed bead carrying 'planned' was listed - an implementer has it"; fi
pass "does not list a bead an implementer has"

if listed ah-planner; then fail "a verification:failed bead carrying 'plan:revise' was listed - a planner has it"; fi
pass "does not list a bead a planner has"

# --- the index(...) trap: a label at position 0 -------------------------------------------------
#
# jq's `index` returns the POSITION, and 0 is truthy... but `0 | not` is false. A query spelt with
# `has`/`contains`, or one that tests truthiness of the index directly, lists this bead and sends
# the verifier to work an implementer is about to build.
if listed ah-planned-0th; then fail "a bead whose FIRST label is 'planned' was listed - the index(...) | not trap"; fi
pass "handles a label at position 0"

# --- the two arms overlapping ------------------------------------------------------------------
count="$(printf '%s\n' "$ids" | grep -cxF ah-both || true)"
[ "$count" = "1" ] || fail "a bead matching both arms was listed $count times, not once"
pass "lists a bead matching both arms exactly once"

# --- everything else stays out ------------------------------------------------------------------
if listed ah-ordinary || listed ah-nolabels; then fail "a bead in neither state was listed"; fi
pass "lists nothing else"

# --- it asks for OPEN beads, which is the whole point -------------------------------------------
grep -qxF "ARG:open" "$argv_file" || fail "bd was not asked for open beads"
pass "asks for open beads"

echo "all second-look-beads assertions passed"
