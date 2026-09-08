#!/usr/bin/env bash
#
# Proves `scripts/stage-candidates`: the one place the harness asks "which beads may the agent at
# stage S take at all", for the two-agent variant of planning (cb-lz5). It is the sibling of
# `scripts/plan-candidates`, which answers the same question for the combined `planner` role and is
# untouched - a project runs one variant or the other, so both routes must go on working.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/stage-candidates.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"

# `work-beads`, which this script calls, resolves its root with `consumer-root --shared`, which
# answers only when this copy of cerebro is mounted at <consumer>/.claude/cerebro. So: a throwaway
# consumer with this submodule copied in, and every case runs the script from there.
consumer="$(consumer_new repo --copy)"
consumer_resolved="$consumer"

argv_file="$stub_dir/argv.list"
stub_stdout="$stub_dir/stdout"
stub_exit="$stub_dir/exit"

# The dispatching stub from tests/plan-candidates.sh:39-63, lifted verbatim: it dispatches on the
# SUBCOMMAND, APPENDING its argv to $stub_dir/argv.<subcommand>. A truncating stub would lose the
# first argv of a script that calls `bd` twice, and `work-beads` asks `bd children` once per
# unsettled epic.
cat > "$stub_dir/bd" <<'STUB'
#!/usr/bin/env bash
stub_dir="STUB_DIR"
sub=""
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -C) skip=1 ;;
    -*) ;;
    *) sub="$a"; break ;;
  esac
done
[ -n "$sub" ] || sub="unknown"
argv="$stub_dir/argv.$sub"
for a in "$@"; do printf 'ARG:%s\n' "$a" >> "$argv"; done
if [ -f "$stub_dir/stdout.$sub" ]; then
  cat "$stub_dir/stdout.$sub"
else
  cat "$stub_dir/stdout"
fi
exit "$(cat "$stub_dir/exit")"
STUB
sed -i.bak "s|STUB_DIR|$stub_dir|" "$stub_dir/bd" && rm -f "$stub_dir/bd.bak"
chmod +x "$stub_dir/bd"

set_stub() {
  rm -f "$stub_dir"/stdout.*
  printf '%s' "$1" > "$stub_stdout"
  printf '%s' "${2:-0}" > "$stub_exit"
}

set_stub_for() {
  printf '%s' "$2" > "$stub_dir/stdout.$1"
}

run() {
  rm -f "$stub_dir"/argv.*
  PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/stage-candidates" "$@"
}

argv_has() {
  grep -qxF "ARG:$1" "$argv_file"
}

argv_has_pair() {
  grep -qxF -A1 "ARG:$1" "$argv_file" && \
    [ "$(grep -xF -A1 "ARG:$1" "$argv_file" | tail -1)" = "ARG:$2" ]
}

ids_of() {
  jq -r '.[].id' | tr '\n' ' '
}

# --- prints the stage label the fleet view checks itself against ---------------------------------
#
# Answered before any root is resolved and before `bd` is reached, exactly as planner-buffer's three
# `--print-*` modes are - which is what lets cb-lz5.1.2's Rust contract test run it with no board.
label="$(PATH="/usr/bin:/bin" bash "$consumer/.claude/cerebro/scripts/stage-candidates" --print-stage-label)"
[ "$label" = "ux:agreed" ] || fail "--print-stage-label printed '$label', not ux:agreed"
pass "prints the stage label the fleet view checks itself against"

# --- refuses no argument, two arguments and an unknown stage -------------------------------------
#
# A refusal is exit 2 with NOTHING on stdout and `bd` never reached. The `usage()` helper prints and
# exits with nothing between that could fail: an advisory step that failed would hand the caller 1
# instead of 2 (.cerebro/traps.md, *An advisory step can eat the exit status that follows it*).
set_stub '[]'
# `ux --print-stage-label` is in the list because the label mode is the whole call or nothing: a
# stage word silently ignored beside it would answer a question nobody asked.
for args in "" "ux build-design" "designer" "ux --print-stage-label"; do
  set +e
  # shellcheck disable=SC2086
  out="$(run $args 2>"$stub_dir/err")"
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "'$args': expected exit 2, got $status"
  grep -q 'usage:' "$stub_dir/err" || fail "'$args': stderr does not carry a usage line"
  [ -z "$out" ] || fail "'$args' still printed '$out' on stdout"
  [ ! -f "$argv_file" ] || fail "'$args' still reached bd"
done
pass "refuses no argument, two arguments and an unknown stage"

# --- the label rules, one fixture ----------------------------------------------------------------
#
# Five of the six rules are lifted from `scripts/plan-candidates` and mean what they mean there; the
# sixth - the stage label - is the whole difference between the two agents.
labelled='[{"id":"tt-plain","issue_type":"task","priority":2,"labels":[]},
           {"id":"tt-agreed","issue_type":"task","priority":2,"labels":["ux:agreed"]},
           {"id":"tt-planned","issue_type":"task","priority":2,"labels":["planned"]},
           {"id":"tt-human","issue_type":"task","priority":2,"labels":["human"]},
           {"id":"tt-held","issue_type":"task","priority":2,"labels":["planning"]},
           {"id":"tt-held-x","issue_type":"task","priority":2,"labels":["planning:Xavier"]},
           {"id":"tt-ideas","issue_type":"task","priority":2,"labels":["planning-ideas"]},
           {"id":"tt-failed","issue_type":"task","priority":2,"labels":["verification:failed"]},
           {"id":"tt-revise","issue_type":"task","priority":2,"labels":["verification:failed","plan:revise"]},
           {"id":"tt-stale","issue_type":"task","priority":2,"labels":["verdict:stale","plan:revise"]},
           {"id":"tt-agreed-planned","issue_type":"task","priority":2,"labels":["ux:agreed","planned"]},
           {"id":"tt-agreed-held","issue_type":"task","priority":2,"labels":["ux:agreed","planning:Beast"]}]'

# --- the ux stage takes what is not yet agreed ---------------------------------------------------
set_stub "$labelled"
set_stub_for children '[]'
ids="$(run ux | ids_of)"
[ "$ids" = "tt-ideas tt-plain tt-revise " ] \
  || fail "the ux stage listed '$ids', not the three beads still needing a designer"
pass "the ux stage takes what is not yet agreed"

# --- the build-design stage takes only what is agreed and not yet planned ------------------------
set_stub "$labelled"
set_stub_for children '[]'
ids="$(run build-design | ids_of)"
[ "$ids" = "tt-agreed " ] || fail "the build-design stage listed '$ids', not tt-agreed alone"
pass "the build-design stage takes only what is agreed and not yet planned"

# --- a label at position 0 is seen ---------------------------------------------------------------
#
# `index(...)` returns the POSITION, and in jq only null and false are falsy - so a label at index 0
# yields 0, which is TRUTHY. A `has`/`contains` spelling passes every case above and fails this one.
set_stub '[{"id":"tt-first","issue_type":"task","priority":2,"labels":["ux:agreed"]},
           {"id":"tt-second","issue_type":"task","priority":2,"labels":["planned","ux:agreed"]}]'
set_stub_for children '[]'
ids="$(run build-design | ids_of)"
[ "$ids" = "tt-first " ] || fail "a label at position 0 was not seen: got '$ids'"
ids="$(run ux | ids_of)"
[ "$ids" = "" ] || fail "the ux stage kept an agreed bead whose label is at position 0: got '$ids'"
pass "a label at position 0 is seen"

# --- asks work-beads for the open board ----------------------------------------------------------
#
# `--exclude-type event`, `--json` and `-C <root>` are spelled nowhere in stage-candidates, so their
# presence on the bd call is what proves the question went through `work-beads`.
set_stub '[{"id":"tt-a","issue_type":"task","priority":2,"labels":[]}]'
set_stub_for children '[]'
out="$(run ux)"
[ "$(printf '%s' "$out" | ids_of)" = "tt-a " ] || fail "did not print the one candidate: got '$out'"
argv_has_pair "--status" "open" || fail "did not ask work-beads for the open board"
argv_has_pair "--exclude-type" "event" || fail "the call did not go through work-beads (no --exclude-type event)"
argv_has "--json" || fail "the call did not go through work-beads (no --json)"
argv_has_pair "-C" "$consumer_resolved" || fail "-C did not name the consumer root"
pass "asks work-beads for the open board"

# --- sorted by priority, then by id --------------------------------------------------------------
set_stub '[{"id":"tt-zed","issue_type":"task","priority":2,"labels":[]},
           {"id":"tt-mid","issue_type":"task","priority":0,"labels":[]},
           {"id":"tt-abc","issue_type":"task","priority":2,"labels":[]}]'
set_stub_for children '[]'
ids="$(run ux | ids_of)"
[ "$ids" = "tt-mid tt-abc tt-zed " ] || fail "not sorted by priority then id: got '$ids'"
pass "sorted by priority, then by id"

# --- a work-beads failure is loud ----------------------------------------------------------------
#
# An empty array that really means "the query broke" reads as a quiet day, and the agent reading it
# ends its pass.
set_stub '[]' 1
set +e
out="$(run ux 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -eq 1 ] || fail "a work-beads failure: expected exit 1, got $status"
[ -s "$stub_dir/err" ] || fail "a work-beads failure produced nothing on stderr"
[ -z "$out" ] || fail "a work-beads failure still printed '$out' on stdout"
pass "a work-beads failure is loud"

# --- a list that is not JSON is loud too ---------------------------------------------------------
set_stub 'bd: could not open the database'
set +e
out="$(run build-design 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -eq 1 ] || fail "a non-JSON list: expected exit 1, got $status"
[ -s "$stub_dir/err" ] || fail "a non-JSON list produced nothing on stderr"
[ -z "$out" ] || fail "a non-JSON list still printed '$out' on stdout"
pass "a list that is not JSON is loud too"

# --- stage-candidates spells no epic rule of its own ---------------------------------------------
#
# `work-beads` has owned that rule since cb-hzl. The header may explain it; the code may not restate
# it. The assertion is on the code with comment lines stripped.
code="$(grep -v '^[[:space:]]*#' "$consumer/.claude/cerebro/scripts/stage-candidates")"
if printf '%s' "$code" | grep -q 'epic'; then
  fail "stage-candidates spells an epic rule of its own; work-beads owns that since cb-hzl"
fi
pass "stage-candidates spells no epic rule of its own"

suite_passed
