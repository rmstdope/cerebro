#!/usr/bin/env bash
#
# Proves `scripts/plan-candidates`: the one place the harness asks "which beads may a planner take
# at all". Those rules lived only in `skills/plan-bead/SKILL.md`, as two hand-written `jq` blocks,
# and they drifted from cb-hzl inside a day of it merging - the fleet view started a planner for a
# childless epic that the planner's own query then excluded. These assertions are what stops that
# happening again.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/plan-candidates.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"

# ah-il8j: `work-beads`, which this script calls, resolves its root with `consumer-root --shared`,
# which answers only when this copy of cerebro is mounted at <consumer>/.claude/cerebro. So: a
# throwaway consumer with this submodule copied in, and every case runs the script from there.
consumer="$(consumer_new repo --copy)"
consumer_resolved="$consumer"

argv_file="$stub_dir/argv.list"
stub_stdout="$stub_dir/stdout"
stub_exit="$stub_dir/exit"

# The dispatching stub from tests/work-beads.sh:44-86, lifted verbatim. It dispatches on the
# SUBCOMMAND (`bd -C <root> list ...` -> `list`), APPENDING its argv to $stub_dir/argv.<subcommand>
# and printing $stub_dir/stdout.<subcommand>, falling back to $stub_stdout. A truncating stub -
# tests/second-look-beads.sh's - would lose the first argv of a script that calls `bd` twice, and
# `work-beads` asks `bd children` once per unsettled epic. This fixture has epics.
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
  PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/plan-candidates" "$@"
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

# --- asks work-beads for the open board ---------------------------------------------------------
#
# `--exclude-type event` and `--json` are spelled nowhere in plan-candidates, so their presence on
# the bd call is what proves the question went through `work-beads` rather than through a fresh
# `bd list` of this script's own.
set_stub '[{"id":"tt-a","issue_type":"task","priority":2,"labels":[]}]'
set_stub_for children '[]'
out="$(run)"
[ "$(printf '%s' "$out" | ids_of)" = "tt-a " ] || fail "did not print the one candidate: got '$out'"
argv_has_pair "--status" "open" || fail "did not ask work-beads for the open board"
argv_has_pair "--exclude-type" "event" || fail "the call did not go through work-beads (no --exclude-type event)"
argv_has "--json" || fail "the call did not go through work-beads (no --json)"
argv_has_pair "-C" "$consumer_resolved" || fail "-C did not name the consumer root"
pass "asks work-beads for the open board"

# --- refuses any argument -----------------------------------------------------------------------
#
# One question, and the script's name is the question: there is no mode to select. An advisory step
# before the exit would hand the caller 1 instead of 2 (.cerebro/traps.md).
set_stub '[]'
set +e
out="$(run --status open 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -eq 2 ] || fail "an argument: expected exit 2, got $status"
grep -q 'usage:' "$stub_dir/err" || fail "an argument: stderr does not carry a usage line"
[ -z "$out" ] || fail "an argument still printed '$out' on stdout"
[ ! -f "$argv_file" ] || fail "an argument still reached bd"
pass "refuses any argument"

# --- the label rules (the hold, parent and blocker rules are below) ------------------------------------------------------------------------
#
# One fixture, one case per rule. Every one of these is lifted verbatim from the two `jq` blocks in
# `skills/plan-bead/SKILL.md` that plan-candidates replaces; none is new and none is dropped.
labelled='[{"id":"tt-plain","issue_type":"task","priority":2,"labels":[]},
           {"id":"tt-planned","issue_type":"task","priority":2,"labels":["planned"]},
           {"id":"tt-human","issue_type":"task","priority":2,"labels":["human"]},
           {"id":"tt-held","issue_type":"task","priority":2,"labels":["planning"]},
           {"id":"tt-held-x","issue_type":"task","priority":2,"labels":["planning:Xavier"]},
           {"id":"tt-ideas","issue_type":"task","priority":2,"labels":["planning-ideas"]},
           {"id":"tt-assigned","issue_type":"task","priority":2,"labels":[],"assignee":"Xavier"},
           {"id":"tt-bugfix","issue_type":"bug","priority":2,"labels":["bugfix"]},
           {"id":"tt-failed","issue_type":"task","priority":2,"labels":["verification:failed"]},
           {"id":"tt-revise","issue_type":"task","priority":2,"labels":["verification:failed","plan:revise"]},
           {"id":"tt-stale","issue_type":"task","priority":2,"labels":["verdict:stale","plan:revise"]}]'
set_stub "$labelled"
set_stub_for children '[]'
ids="$(run | ids_of)"

case " $ids " in *" tt-planned "*) fail "a bead already planned is still a candidate: '$ids'";; esac
pass "drops a bead that is already planned"

case " $ids " in *" tt-human "*) fail "a bead parked on the navigator is still a candidate: '$ids'";; esac
pass "drops a bead parked on the navigator"

# cb-10d.2.2: the fleet view hands a planning session its bead by assignee, so a planning label
# no longer holds anything - only an assignee does.
case " $ids " in *" tt-held "*) : ;; *) fail "a bare planning label still holds a bead: '$ids'";; esac
case " $ids " in *" tt-held-x "*) : ;; *) fail "planning:<name> still holds a bead: '$ids'";; esac
case " $ids " in *" tt-ideas "*) : ;; *) fail "planning-ideas was read as a hold: '$ids'";; esac
case " $ids " in *" tt-assigned "*) fail "an assigned bead is still a candidate: '$ids'";; esac
pass "a planning label no longer holds a bead"

case " $ids " in *" tt-bugfix "*) fail "a bugfix-labelled bead is still a planning candidate: '$ids'";; esac
pass "never a bead carrying bugfix"

case " $ids " in *" tt-failed "*) fail "a failed verification with no plan:revise is a candidate: '$ids'";; esac
case " $ids " in *" tt-revise "*) : ;; *) fail "a failed verification with plan:revise was dropped: '$ids'";; esac
pass "a failed verification is a candidate only with plan:revise"

case " $ids " in *" tt-stale "*) fail "a verdict:stale bead is a candidate: '$ids'";; esac
pass "never a bead carrying verdict:stale"

# --- handles a label at position 0 ---------------------------------------------------------------
#
# `index(...)` returns the POSITION, and in jq only null and false are falsy - so a label at index 0
# yields 0, which is TRUTHY. `index(x) | not` is the correct negation; a `has`/`contains` spelling
# gets exactly this case wrong and lists a bead an implementer is about to build.
set_stub '[{"id":"tt-first","issue_type":"task","priority":2,"labels":["planned","urgent"]},
           {"id":"tt-keep","issue_type":"task","priority":2,"labels":["urgent"]}]'
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-keep " ] || fail "a label at position 0 was not seen: got '$ids'"
pass "handles a label at position 0"

# --- cb-10d.2.1: an assignee holds, an assigned parent holds, an unsatisfied blocker holds --------
#
# The fleet view hands a planning role its bead by assignee, and an agent handed a bead can no
# longer walk to its blocker - so the queue itself must not offer either.
t() { printf '{"id":"%s","issue_type":"task","priority":2,"labels":%s%s}' "$1" "${2:-[]}" "${3:-}"; }

set_stub "[$(t tt-mine '[]' ',"assignee":"Xavier"'),$(t tt-free '[]' ',"assignee":null'),$(t tt-empty '[]' ',"assignee":""')]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-empty tt-free " ] || fail "an assigned bead is still a candidate: got '$ids'"
pass "drops a bead with an assignee"

set_stub "[$(t tt-p '[]' ',"assignee":"Xavier"'),$(t tt-p.1 '[]' ',"parent":"tt-p"'),$(t tt-q),$(t tt-q.1 '[]' ',"parent":"tt-q"'),$(t tt-orphan.1 '[]' ',"parent":"tt-gone"')]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-orphan.1 tt-q tt-q.1 " ] || fail "a child of an assigned parent: got '$ids'"
pass "drops a child whose parent is assigned"

blocks() { printf ',"dependencies":[{"issue_id":"x","depends_on_id":"%s","type":"%s"}]' "$1" "${2:-blocks}"; }

set_stub "[$(t tt-a '[]' "$(blocks tt-b)"),$(t tt-b)]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-b " ] || fail "a bead behind an open unplanned blocker: got '$ids'"
pass "drops a bead whose blocker is open and unplanned"

set_stub "[$(t tt-a '[]' "$(blocks tt-b)"),$(t tt-b '["planned"]')]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-a " ] || fail "a bead behind a planned blocker: got '$ids'"
pass "keeps a bead whose blocker is planned"

set_stub "[$(t tt-a '[]' "$(blocks tt-closed)")]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-a " ] || fail "a bead behind a blocker not in the list: got '$ids'"
pass "keeps a bead whose blocker is not in the list"

set_stub "[$(t tt-a '[]' "$(blocks tt-ep)"),$(t tt-ep.1 '[]' ',"parent":"tt-ep"')]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-ep.1 " ] || fail "a split blocker with an unplanned child: got '$ids'"
set_stub "[$(t tt-a '[]' "$(blocks tt-ep)"),$(t tt-ep.1 '["planned"]' ',"parent":"tt-ep"')]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-a " ] || fail "a split blocker whose children are planned: got '$ids'"
pass "a split blocker with an unplanned child hides its dependant"

set_stub "[$(t tt-a),$(t tt-a.1 '[]' "$(blocks tt-a parent-child)")]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-a tt-a.1 " ] || fail "a parent-child edge was read as a blocker: got '$ids'"
pass "a parent-child edge is not a blocker"

set_stub "[$(t tt-a '[]' "$(blocks tt-b)"),$(t tt-b '["human"]')]"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "" ] || fail "a bead behind a parked blocker: got '$ids'"
pass "a parked blocker hides its dependant"

# --- the epic rule comes from work-beads, not from here (cb-hzl) --------------------------------
epics='[{"id":"tt-lone","issue_type":"epic","priority":2,"labels":[]},
        {"id":"tt-ord","issue_type":"task","priority":2,"labels":[]}]'
set_stub "$epics"
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-lone tt-ord " ] || fail "a childless epic is not a candidate: got '$ids'"
pass "a childless epic is a candidate"

set_stub "$epics"
set_stub_for children '[{"id":"tt-lone.1"}]'
ids="$(run | ids_of)"
[ "$ids" = "tt-ord " ] || fail "an epic with children survived: got '$ids'"
pass "an epic with children is not a candidate"

# --- plan-candidates spells no epic rule of its own ----------------------------------------------
#
# The header may explain the rule; the code may not restate it. A second copy of the epic rule is
# what this script exists to end, so the assertion is on the code with comment lines stripped.
code="$(grep -v '^[[:space:]]*#' "$consumer/.claude/cerebro/scripts/plan-candidates")"
if grep -q 'epic' <<<"$code"; then
  fail "plan-candidates spells an epic rule of its own; work-beads owns that since cb-hzl"
fi
pass "plan-candidates spells no epic rule of its own"

# --- sorted by priority, then by id --------------------------------------------------------------
#
# The old `--sort priority` gave no tie-break, so two beads at one priority came back in whatever
# order bd chose. A deterministic order is one less thing that can make a suite flaky.
set_stub '[{"id":"tt-zed","issue_type":"task","priority":2,"labels":[]},
           {"id":"tt-mid","issue_type":"task","priority":0,"labels":[]},
           {"id":"tt-abc","issue_type":"task","priority":2,"labels":[]}]'
set_stub_for children '[]'
ids="$(run | ids_of)"
[ "$ids" = "tt-mid tt-abc tt-zed " ] || fail "not sorted by priority then id: got '$ids'"
pass "sorted by priority, then by id"

# --- fails loudly when work-beads fails ----------------------------------------------------------
set_stub '[]' 1
set +e
out="$(run 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -ne 0 ] || fail "exited 0 when work-beads failed"
[ -s "$stub_dir/err" ] || fail "a work-beads failure produced nothing on stderr"
[ -z "$out" ] || fail "a work-beads failure still printed '$out' on stdout"
pass "fails loudly when work-beads fails"

# --- fails loudly when the list is not JSON ------------------------------------------------------
set_stub 'bd: could not open the database'
set +e
out="$(run 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -ne 0 ] || fail "exited 0 when the list was not JSON"
[ -s "$stub_dir/err" ] || fail "a non-JSON list produced nothing on stderr"
[ -z "$out" ] || fail "a non-JSON list still printed '$out' on stdout"
pass "fails loudly when the list is not JSON"

suite_passed
