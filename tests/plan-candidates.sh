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

# --- the five label rules ------------------------------------------------------------------------
#
# One fixture, one case per rule. Every one of these is lifted verbatim from the two `jq` blocks in
# `skills/plan-bead/SKILL.md` that plan-candidates replaces; none is new and none is dropped.
labelled='[{"id":"tt-plain","issue_type":"task","priority":2,"labels":[]},
           {"id":"tt-planned","issue_type":"task","priority":2,"labels":["planned"]},
           {"id":"tt-human","issue_type":"task","priority":2,"labels":["human"]},
           {"id":"tt-held","issue_type":"task","priority":2,"labels":["planning"]},
           {"id":"tt-held-x","issue_type":"task","priority":2,"labels":["planning:Xavier"]},
           {"id":"tt-ideas","issue_type":"task","priority":2,"labels":["planning-ideas"]},
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

case " $ids " in *" tt-held "*) fail "a bead held by a bare planning label is still a candidate: '$ids'";; esac
case " $ids " in *" tt-held-x "*) fail "a bead held by planning:<name> is still a candidate: '$ids'";; esac
pass "drops a bead held by either spelling of the planning label"

# The `:` is required rather than a bare prefix, so a label that merely starts with the same
# letters is not read as a hold.
case " $ids " in *" tt-ideas "*) : ;; *) fail "planning-ideas was read as a hold: '$ids'";; esac
pass "keeps a bead labelled planning-ideas"

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
if printf '%s' "$code" | grep -q 'epic'; then
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
