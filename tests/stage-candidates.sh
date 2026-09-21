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
# Every label rule but the stage label is lifted from `scripts/plan-candidates` and means what it
# means there; the stage label is the whole difference between the two agents. The hold, parent and
# blocker rules have cases of their own below.
labelled='[{"id":"tt-plain","issue_type":"task","priority":2,"labels":[]},
           {"id":"tt-agreed","issue_type":"task","priority":2,"labels":["ux:agreed"]},
           {"id":"tt-planned","issue_type":"task","priority":2,"labels":["planned"]},
           {"id":"tt-human","issue_type":"task","priority":2,"labels":["human"]},
           {"id":"tt-held","issue_type":"task","priority":2,"labels":["planning"]},
           {"id":"tt-held-x","issue_type":"task","priority":2,"labels":["planning:Xavier"]},
           {"id":"tt-ideas","issue_type":"task","priority":2,"labels":["planning-ideas"]},
           {"id":"tt-failed","issue_type":"task","priority":2,"labels":["verification:failed"]},
           {"id":"tt-bugfix","issue_type":"bug","priority":2,"labels":["bugfix"]},
           {"id":"tt-revise","issue_type":"task","priority":2,"labels":["verification:failed","plan:revise"]},
           {"id":"tt-stale","issue_type":"task","priority":2,"labels":["verdict:stale","plan:revise"]},
           {"id":"tt-agreed-planned","issue_type":"task","priority":2,"labels":["ux:agreed","planned"]},
           {"id":"tt-agreed-held","issue_type":"task","priority":2,"labels":["ux:agreed","planning:Beast"]}]'

# --- the ux stage takes what is not yet agreed ---------------------------------------------------
set_stub "$labelled"
set_stub_for children '[]'
ids="$(run ux | ids_of)"
[ "$ids" = "tt-held tt-held-x tt-ideas tt-plain tt-revise " ] \
  || fail "the ux stage listed '$ids', not the five beads still needing a designer (a planning label holds nothing since cb-10d.2.2)"
pass "the ux stage takes what is not yet agreed"

# --- the build-design stage takes only what is agreed and not yet planned ------------------------
set_stub "$labelled"
set_stub_for children '[]'
ids="$(run build-design | ids_of)"
[ "$ids" = "tt-agreed tt-agreed-held " ] || fail "the build-design stage listed '$ids', not the two agreed beads (a planning label holds nothing since cb-10d.2.2)"
pass "the build-design stage takes only what is agreed and not yet planned"

case " $ids " in *" tt-bugfix "*) fail "the build-design stage kept a bugfix-labelled bead: '$ids'";; esac
ids="$(run ux | ids_of)"
case " $ids " in *" tt-bugfix "*) fail "the ux stage kept a bugfix-labelled bead: '$ids'";; esac
pass "both stages drop bugfix-labelled beads"

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

# --- cb-10d.2.1: an assignee holds, an assigned parent holds, an unsatisfied blocker holds --------
#
# The same eight cases as tests/plan-candidates.sh, at each stage: at build-design every fixture
# bead carries the stage label so the stage sees it, at ux none does.
holds_at() {
  local stage="$1" base="$2"
  t() {
    local labels="${2:-}"
    if [ -n "$base" ]; then labels="\"$base\"${labels:+,$labels}"; fi
    printf '{"id":"%s","issue_type":"task","priority":2,"labels":[%s]%s}' "$1" "$labels" "${3:-}"
  }
  blocks() { printf ',"dependencies":[{"issue_id":"x","depends_on_id":"%s","type":"%s"}]' "$1" "${2:-blocks}"; }
  check() { set_stub_for children '[]'; ids="$(run "$stage" | ids_of)"; [ "$ids" = "$1" ] || fail "$stage: $2: got '$ids', wanted '$1'"; }

  set_stub "[$(t tt-mine '' ',"assignee":"Xavier"'),$(t tt-free '' ',"assignee":null'),$(t tt-empty '' ',"assignee":""')]"
  check "tt-empty tt-free " "an assigned bead is still a candidate"
  pass "drops a bead with an assignee at $stage"

  set_stub "[$(t tt-p '' ',"assignee":"Xavier"'),$(t tt-p.1 '' ',"parent":"tt-p"'),$(t tt-q),$(t tt-q.1 '' ',"parent":"tt-q"'),$(t tt-orphan.1 '' ',"parent":"tt-gone"')]"
  check "tt-orphan.1 tt-q tt-q.1 " "a child of an assigned parent"
  pass "drops a child whose parent is assigned at $stage"

  set_stub "[$(t tt-a '' "$(blocks tt-b)"),$(t tt-b)]"
  check "tt-b " "a bead behind an open unplanned blocker"
  pass "drops a bead whose blocker is open and unplanned at $stage"

  set_stub "[$(t tt-a '' "$(blocks tt-b)"),$(t tt-b '"planned"')]"
  check "tt-a " "a bead behind a planned blocker"
  pass "keeps a bead whose blocker is planned at $stage"

  set_stub "[$(t tt-a '' "$(blocks tt-closed)")]"
  check "tt-a " "a bead behind a blocker not in the list"
  pass "keeps a bead whose blocker is not in the list at $stage"

  set_stub "[$(t tt-a '' "$(blocks tt-ep)"),$(t tt-ep.1 '' ',"parent":"tt-ep"')]"
  check "tt-ep.1 " "a split blocker with an unplanned child"
  set_stub "[$(t tt-a '' "$(blocks tt-ep)"),$(t tt-ep.1 '"planned"' ',"parent":"tt-ep"')]"
  check "tt-a " "a split blocker whose children are planned"
  pass "a split blocker with an unplanned child hides its dependant at $stage"

  set_stub "[$(t tt-a),$(t tt-a.1 '' "$(blocks tt-a parent-child)")]"
  check "tt-a tt-a.1 " "a parent-child edge was read as a blocker"
  pass "a parent-child edge is not a blocker at $stage"

  set_stub "[$(t tt-a '' "$(blocks tt-b)"),$(t tt-b '"human"')]"
  check "" "a bead behind a parked blocker"
  pass "a parked blocker hides its dependant at $stage"
}
holds_at build-design ux:agreed
holds_at ux ""

set_stub '[{"id":"tt-a","issue_type":"task","priority":2,"labels":[],"dependencies":[{"issue_id":"tt-a","depends_on_id":"tt-b","type":"blocks"}]},
           {"id":"tt-b","issue_type":"task","priority":2,"labels":["ux:agreed"]}]'
set_stub_for children '[]'
ids="$(run ux | ids_of)"
[ "$ids" = "tt-a " ] || fail "the ux stage did not accept an agreed blocker: got '$ids'"
pass "the ux stage accepts an agreed blocker"

set_stub '[{"id":"tt-a","issue_type":"task","priority":2,"labels":["ux:agreed"],"dependencies":[{"issue_id":"tt-a","depends_on_id":"tt-b","type":"blocks"}]},
           {"id":"tt-b","issue_type":"task","priority":2,"labels":["ux:agreed"]}]'
set_stub_for children '[]'
ids="$(run build-design | ids_of)"
[ "$ids" = "tt-b " ] || fail "the build-design stage accepted an agreed blocker: got '$ids'"
pass "the build-design stage does not accept an agreed blocker"

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
