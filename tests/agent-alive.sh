#!/usr/bin/env bash
#
# Proves scripts/agent-alive answers "is this pid still that session" the way
# cerebro--session-alive-p does in elisp: a pid alone is not an identity, so the process's own
# command line must carry cerebro's own marker sentence - "This session is <Name> of the cerebro
# fleet rooted at <root>/." (cb-d59.3).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/agent-alive.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"
# session_args_render - the one bash reader of the shared case table.
source "$repo_root/tests/lib/session-args.sh"

# A newline, for the case pattern below: `$'\n'` inside a case pattern is not portable to bash 3.2.
nl=$'\n'

# The background `sleep's this suite starts to stand in for live sessions. The library's EXIT trap
# calls suite_cleanup first, before it removes anything, so a failed assertion leaves none of them
# running - `fail' exits, so per-case cleanup would not run. The fixtures themselves need no entry
# here: consumer_new builds them under $work_dir, which that same trap removes.
strays=()

suite_cleanup() {
  local p
  for p in ${strays+"${strays[@]}"}; do kill "$p" 2>/dev/null || true; done
}

# The same fixture shape tests/agent-state.sh uses: a git repo with its own scripts/ directory
# symlinked to the real scripts, so consumer-root --shared resolves inside the fixture.
new_fixture() {
  consumer_new "$(fixture_name)" --link roster agent-alive consumer-root
}

write_state() {
  # $1 = fixture root, $2 = name, $3 = file contents
  local dir="$1/.cerebro/state"
  mkdir -p "$dir"
  printf '%s' "$3" > "$dir/$2.state.json"
}

run_alive() {
  # $1 = fixture root, rest = args. Never under `set -e' abort: the exit status is the answer.
  local tmp="$1"
  shift
  set +e
  "$tmp/.claude/cerebro/scripts/agent-alive" "$@" 2>"$tmp/stderr"
  local status=$?
  set -e
  return $status
}

# --- dead-for-a-live-pid-that-is-not-that-session ---
# The pid-recycling case, and the whole reason this script exists: $$ is a live process whose args
# carry no marker for Cyclops.
tmp="$(new_fixture)"
write_state "$tmp" Cyclops "{\"state\":\"working\",\"pid\":$$}"
if run_alive "$tmp" Cyclops; then
  fail "dead-for-a-live-pid-that-is-not-that-session: reported alive for a recycled pid"
fi
pass "dead-for-a-live-pid-that-is-not-that-session"

# --- every row of the shared case table ---
# The rule's cases live in tests/lib/session-args.cases and cerebro-test.el runs the same rows
# against cerebro--session-args-p: a row one side answers differently is the drift this table
# exists to catch. Each row becomes a live process with exactly that command line, a state file
# naming its pid, and one agent-alive call from the row's root.
#
# The rows name Cyclops, Beast and Storm outright rather than asking the roster for a planner the
# way the hand-written cases they replace did: the table is read by the ERT suite too, which has no
# roster to ask, and the fixture here declares none of its own and so runs the built-in fleet.
cases="$repo_root/tests/lib/session-args.cases"
tmp="$(new_fixture)"
other="$(new_fixture)"
# The three consumer roots a row may be rooted at. Rows do not require any of these to exist (the
# rule reads the marker sentence in the command line, not a resolved path) but they are kept so a
# row naming one still finds a real path - and {root}-hud is the sibling-prefix case, a checkout
# beside this one whose path merely starts with this one's.
mkdir -p "$tmp/.claude/cerebro/hooks" "$other/.claude/cerebro/hooks" "$tmp-hud/.claude/cerebro/hooks"
# Lives in $work_dir, ONE level above every fixture root, deliberately - not in $tmp. agent-alive's
# rule asks whether the marker rooted at $repo_root appears ANYWHERE in the process's command line,
# and a process's own invocation path is part of that command line: keeping the fake session out of
# every fixture root is what stops an invocation path from standing in for a marker the row never
# carried, for a reason that has nothing to do with the rule under test.
printf '#!/usr/bin/env bash\nsleep 30\n' > "$work_dir/fake-session"
chmod +x "$work_dir/fake-session"
# One reader of the table, shared with every other bash subscriber - see tests/lib/session-args.sh
# for why it writes a file rather than being piped from a subshell.
expected_rows="$(session_args_render "$cases" "$tmp" "$other" "$work_dir/session-args.rendered")"
rows=0
saw_newline=0
while IFS= read -r -d '' expect \
   && IFS= read -r -d '' name \
   && IFS= read -r -d '' root \
   && IFS= read -r -d '' args; do
  case "$args" in *"$nl"*) saw_newline=1 ;; esac
  # ONE argument, not word-split: that is what keeps a newline in the field. It changes nothing
  # else - `ps -o args=' joins argv with single spaces and quotes nothing, so every row that
  # carried flags reads back byte-identically.
  bash "$work_dir/fake-session" "$args" &
  pid=$!
  strays+=("$pid")
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do strays+=("$child"); done
  write_state "$root" "$name" "{\"state\":\"working\",\"pid\":$pid}"
  case "$expect" in
    alive)
      run_alive "$root" "$name" \
        || fail "session-args row $((rows+1)): expected alive, reported dead ($name at $root: $args)" ;;
    dead)
      if run_alive "$root" "$name"; then
        fail "session-args row $((rows+1)): expected dead, reported alive ($name at $root: $args)"
      fi ;;
  esac
  rows=$((rows+1))
done < "$work_dir/session-args.rendered"
# Assert the count rather than report one: a renderer that silently dropped rows would otherwise
# pass here with a smaller number nobody reads.
[[ "$rows" -eq "$expected_rows" ]] \
  || fail "session-args table: rendered $expected_rows rows, consumed $rows"
pass "every row of tests/lib/session-args.cases holds for agent-alive ($rows rows)"

# The bash half of cerebro-test/session-args-table-renders-the-newline-escape: a row written with
# the escape and read back as the two characters would prove nothing about the store's shape.
[[ "$saw_newline" -eq 1 ]] \
  || fail "session-args table: no rendered field carried a real newline - is the \\n escape unescaped?"
pass "a row's \`\\n' renders as a real newline for the bash subscriber too"

# --- dead-for-a-pid-that-no-longer-exists ---
tmp="$(new_fixture)"
bash -c 'exit 0' --name Cyclops &
gone_pid=$!
wait "$gone_pid" 2>/dev/null || true
# Nothing can guarantee a number is never handed out again, and this suite's whole subject is pid
# reuse - so say so if the assertion is being made about a pid something else has taken since.
if ps -o args= -p "$gone_pid" >/dev/null 2>&1; then
  fail "dead-for-a-pid-that-no-longer-exists: pid $gone_pid was reused before the assertion"
fi
write_state "$tmp" Cyclops "{\"state\":\"working\",\"pid\":$gone_pid}"
if run_alive "$tmp" Cyclops; then
  fail "dead-for-a-pid-that-no-longer-exists: reported alive for a pid that has exited"
fi
pass "dead-for-a-pid-that-no-longer-exists"

# --- dead-when-there-is-no-state-file ---
tmp="$(new_fixture)"
if run_alive "$tmp" Cyclops; then
  fail "dead-when-there-is-no-state-file: reported alive with no file to read"
fi
pass "dead-when-there-is-no-state-file"

# --- dead-when-the-state-file-has-no-pid ---
tmp="$(new_fixture)"
write_state "$tmp" Cyclops '{"state":"idle"}'
if run_alive "$tmp" Cyclops; then
  fail "dead-when-the-state-file-has-no-pid: reported alive with no pid in the file"
fi
pass "dead-when-the-state-file-has-no-pid"

# --- dead-when-the-pid-is-not-a-single-integer ---
# `ps -p' takes a list, so a field carrying two numbers would print two command lines and the match
# could land on the wrong one. The guard is what stops that being a wrong "alive".
tmp="$(new_fixture)"
write_state "$tmp" Cyclops "{\"state\":\"working\",\"pid\":\"$$ 1\"}"
if run_alive "$tmp" Cyclops; then
  fail "dead-when-the-pid-is-not-a-single-integer: accepted a pid list"
fi
pass "dead-when-the-pid-is-not-a-single-integer"

# --- refuses-a-name-that-is-not-on-the-roster ---
# A typo is not a death: exit 2, so a caller cannot read it as "not running".
tmp="$(new_fixture)"
status=0
run_alive "$tmp" Nobody || status=$?
[[ "$status" == 2 ]] || fail "refuses-a-name-that-is-not-on-the-roster: exit $status, expected 2"
grep -q "not on the roster" "$tmp/stderr" \
  || fail "refuses-a-name-that-is-not-on-the-roster: no roster message on stderr"
pass "refuses-a-name-that-is-not-on-the-roster"

# --- usage-without-a-name ---
tmp="$(new_fixture)"
status=0
run_alive "$tmp" || status=$?
[[ "$status" == 2 ]] || fail "usage-without-a-name: exit $status, expected 2"
pass "usage-without-a-name"

# --- usage-with-more-than-a-name ---
# One argument, so a caller cannot pass flags this script does not have and be told "not running".
tmp="$(new_fixture)"
status=0
run_alive "$tmp" Cyclops --json || status=$?
[[ "$status" == 2 ]] || fail "usage-with-more-than-a-name: exit $status, expected 2"
pass "usage-with-more-than-a-name"

suite_passed
