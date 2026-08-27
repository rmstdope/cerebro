#!/usr/bin/env bash
#
# Proves `scripts/planner-buffer`: the one place the harness answers "how much planned, claimable
# work is there, and how much is wanted" - the wanted number being one bead per implementer on the
# roster, minus any told to finish, never fewer than the floor. That question used to be answered twice, in two languages
# - `cerebro--trigger`'s planner arm in `emacs/cerebro.el` and a hand-written `bd list` in
# `skills/plan-bead/SKILL.md` - and the two drifted, each time costing sessions: a trigger counting
# beads the skill excluded started a planner to find nothing to do (de05dc3), and one rule change
# took five files and missed a sixth (78722b2).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/planner-buffer.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# ------------------------------------------------------------------------------------------------
# The declarations: what the script owns, printed for the elisp contract test to check itself
# against. These modes answer before any root is resolved, so they work with no repository at all.
# ------------------------------------------------------------------------------------------------

decl_consumer="$(consumer_new decl --copy)"

run_decl() {
  bash "$decl_consumer/.claude/cerebro/scripts/planner-buffer" "$@"
}

labels="$(run_decl --print-excluded-labels)"
[ "$labels" = "$(printf 'human\ntriage:declined')" ] \
  || fail "--print-excluded-labels printed '$labels'"
pass "prints the excluded labels for the fleet view to check itself against"

floor="$(run_decl --print-floor)"
[ "$floor" = "2" ] || fail "--print-floor printed '$floor', not 2"
pass "prints the buffer floor"

# --- an unknown flag is a usage error, and prints nothing on stdout ------------------------------
set +e
out="$(run_decl --nonsense 2>"$work_dir/decl-err")"
status=$?
set -e
[ "$status" -eq 2 ] || fail "an unknown flag: expected exit 2, got $status"
[ -z "$out" ] || fail "an unknown flag still printed '$out' on stdout"
[ -s "$work_dir/decl-err" ] || fail "an unknown flag produced nothing on stderr"
pass "refuses an unknown flag with exit 2 and nothing on stdout"

# --- a call with no mode at all is the same refusal ----------------------------------------------
set +e
out="$(run_decl 2>/dev/null)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "no arguments: expected exit 2, got $status"
[ -z "$out" ] || fail "no arguments still printed '$out' on stdout"
pass "refuses a call that names no mode"

# ------------------------------------------------------------------------------------------------
# The count: which beads an implementer could actually claim. The bead query goes through
# `scripts/work-beads', so a stub `bd' on PATH ahead of the real one reaches it - never the real
# `bd', which would read this machine's own backlog and pass or fail by accident.
# ------------------------------------------------------------------------------------------------

stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"
count_consumer="$(consumer_new count --copy)"
# A roster of its own, or the built-in table's twelve implementers would be what `want' is sized
# from since cb-1or.3: one builder on the roster, so `want' is the floor.
mkdir -p "$count_consumer/.cerebro/state"
printf 'Xavier planner\nCyclops implementer\n' > "$count_consumer/.cerebro/roster.conf"

argv_file="$stub_dir/argv"
stub_stdout="$stub_dir/stdout"
stub_exit="$stub_dir/exit"

cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
: > "$argv_file"
for a in "\$@"; do printf 'ARG:%s\n' "\$a" >> "$argv_file"; done
cat "$stub_stdout"
exit "\$(cat "$stub_exit")"
STUB
chmod +x "$stub_dir/bd"

set_stub() {
  printf '%s' "$1" > "$stub_stdout"
  printf '%s' "${2:-0}" > "$stub_exit"
}

run_count() {
  PATH="$stub_dir:$PATH" bash "$count_consumer/.claude/cerebro/scripts/planner-buffer" "$@"
}

argv_has_pair() {
  grep -qxF -A1 "ARG:$1" "$argv_file" && \
    [ "$(grep -xF -A1 "ARG:$1" "$argv_file" | tail -1)" = "ARG:$2" ]
}

# One of each shape an implementer might or might not be able to take. The stub ignores
# `--exclude-type', so the epic here also proves work-beads' own jq guard is still in the path.
beads='[{"id":"a","issue_type":"task","labels":["planned"]},
        {"id":"b","issue_type":"task","labels":["planned","human"]},
        {"id":"c","issue_type":"task","labels":["planned","triage:declined"]},
        {"id":"d","issue_type":"task","labels":["planning:Beast"]},
        {"id":"e","issue_type":"epic","labels":["planned"]}]'
set_stub "$beads"

planned="$(run_count --planned)"
[ "$planned" = "1" ] || fail "--planned counted '$planned', not the one claimable bead"
pass "counts only the planned beads an implementer could claim"

argv_has_pair "--status" "open" || fail "the bead query did not ask for open beads"
pass "asks for open beads, through work-beads"

# --- the exact line the skill reads --------------------------------------------------------------
# One implementer on this fixture's roster, so `want' is the floor.
line="$(run_count --count)"
[ "$line" = "planned=1 want=2" ] || fail "--count printed '$line', not 'planned=1 want=2'"
pass "prints the one line the skill reads"

# --- a broken query is never an empty buffer -----------------------------------------------------
# An empty answer that really means "the query broke" would start a planner every five seconds.
set_stub "$beads" 1
set +e
out="$(run_count --planned 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -ne 0 ] || fail "exited 0 when the bead query failed"
[ -z "$out" ] || fail "a failed bead query still printed '$out' on stdout"
grep -q 'planner-buffer' "$stub_dir/err" || fail "a failed bead query does not name planner-buffer on stderr"
pass "fails loudly when the bead query fails"

# --- and the same for the mode the skill actually calls -------------------------------------------
# `--count' builds its line from both counts, so a failing count must abort the script before
# anything is printed rather than leaving `planned= want=2' on stdout and exiting 0.
set +e
out="$(run_count --count 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -ne 0 ] || fail "--count exited 0 when the bead query failed"
[ -z "$out" ] || fail "--count printed '$out' on stdout when the bead query failed"
grep -q 'planner-buffer' "$stub_dir/err" || fail "--count does not name planner-buffer on stderr"
pass "fails loudly on --count too, which is the mode the skill calls"

set_stub "$beads"

# ------------------------------------------------------------------------------------------------
# The wanted number: one per implementer on the ROSTER, never fewer than the floor - and an
# implementer told to finish is left out, since it takes no further bead. Sessions are not counted
# at all since cb-1or.3: since cb-1or.1 a builder between beads has no session and is started *by* a
# planned bead, so counting sessions sized the buffer at the floor on every quiet board and woke two
# builders of four.
#
# The stop flag is still the one disagreement this script exists to end: the skill's own loop
# skipped a stop-flagged implementer and the fleet view's count did not, so with four on the roster
# and one told to finish the skill wanted three and the view wanted four, and the view started a
# planner whose pass found a full buffer.
# ------------------------------------------------------------------------------------------------

# A fixture whose roster declares exactly the implementers named, plus one planner so the file has
# the shape a real one has. Nothing runs: since cb-1or.3 the wanted number is read off the roster
# and the stop flags, never off a session.
want_fixture() {
  local tmp name
  tmp="$(consumer_new "$(fixture_name pb)" --link roster consumer-root work-beads planner-buffer)"
  mkdir -p "$tmp/.cerebro/state"
  printf 'Xavier planner\n' > "$tmp/.cerebro/roster.conf"
  for name in "$@"; do printf '%s implementer\n' "$name" >> "$tmp/.cerebro/roster.conf"; done
  echo "$tmp"
}

run_want() {
  local tmp="$1"
  shift
  bash "$tmp/.claude/cerebro/scripts/planner-buffer" "$@"
}

# --- one bead per implementer on the roster, running or not --------------------------------------
tmp="$(want_fixture Cyclops Storm Wolverine)"
want="$(run_want "$tmp" --want)"
[ "$want" = "3" ] || fail "--want with three implementers on the roster printed '$want'"
pass "wants one bead per implementer on the roster, running or not"

# --- an implementer told to finish takes no further bead -----------------------------------------
touch "$tmp/.cerebro/state/Storm.stop"
want="$(run_want "$tmp" --want)"
[ "$want" = "2" ] || fail "--want with one of three told to finish printed '$want'"
pass "skips an implementer told to finish"

# --- the floor holds however many are told to finish ---------------------------------------------
touch "$tmp/.cerebro/state/Cyclops.stop"
want="$(run_want "$tmp" --want)"
[ "$want" = "2" ] || fail "--want with two of three told to finish printed '$want', not the floor"
pass "never fewer than the floor, however many are told to finish"

# --- a roster of one still wants the floor -------------------------------------------------------
tmp="$(want_fixture Cyclops)"
want="$(run_want "$tmp" --want)"
[ "$want" = "2" ] || fail "--want with one implementer on the roster printed '$want', not the floor"
pass "wants the floor with a roster of one"

# --- a session is not what is counted ------------------------------------------------------------
# The pid check moved out of this script with the rule that needed it: `--want' no longer asks
# whether anything is up, so neither a state file for a name off the roster nor one for a name on it
# can move the number.
tmp="$(want_fixture Cyclops Storm)"
printf '%s' "{\"state\":\"working\",\"pid\":$$}" > "$tmp/.cerebro/state/Rogue.state.json"
printf '%s' "{\"state\":\"working\",\"pid\":$$}" > "$tmp/.cerebro/state/Storm.state.json"
want="$(run_want "$tmp" --want)"
[ "$want" = "2" ] || fail "--want counted a session: printed '$want'"
pass "a session, live or not, is not what is counted"

# --- the count line reads the same wanted number --------------------------------------------------
tmp="$(want_fixture Cyclops Storm Wolverine)"
line="$(PATH="$stub_dir:$PATH" bash "$tmp/.claude/cerebro/scripts/planner-buffer" --count)"
[ "$line" = "planned=1 want=3" ] || fail "--count printed '$line' with three implementers on the roster"
pass "the count line reads the same wanted number as --want"
