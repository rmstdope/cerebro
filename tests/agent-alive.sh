#!/usr/bin/env bash
#
# Proves scripts/agent-alive answers "is this pid still that session" the way
# cerebro--session-alive-p does in elisp: a pid alone is not an identity, so the process's own
# command line must carry `--name <Name>'.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/agent-alive.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

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
# carry no `--name Cyclops'.
tmp="$(new_fixture)"
write_state "$tmp" Cyclops "{\"state\":\"working\",\"pid\":$$}"
if run_alive "$tmp" Cyclops; then
  fail "dead-for-a-live-pid-that-is-not-that-session: reported alive for a recycled pid"
fi
pass "dead-for-a-live-pid-that-is-not-that-session"

# --- alive-for-a-live-pid-that-names-the-agent ---
tmp="$(new_fixture)"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmp/fake-session"
chmod +x "$tmp/fake-session"
# Every session `scripts/launch' starts carries `--settings <root>/.../hooks/...' (cb-lzi), and
# that path is the proof of which consumer's fleet it belongs to. `scripts/' already exists;
# `hooks/' must, because agent-alive resolves the directory physically before comparing.
mkdir -p "$tmp/.claude/cerebro/hooks"
bash "$tmp/fake-session" --name Cyclops \
  --settings "$tmp/.claude/cerebro/scripts/../hooks/question-state.settings.json" &
fake_pid=$!
# The `sleep' inside the script is a child of that bash, not the bash itself (the implicit-exec
# optimisation applies to `-c', not to a script file - which is what keeps `--name' in the args),
# so killing the wrapper alone orphans it for the rest of its 30 seconds.
strays+=("$fake_pid")
for child in $(pgrep -P "$fake_pid" 2>/dev/null || true); do strays+=("$child"); done
write_state "$tmp" Cyclops "{\"state\":\"working\",\"pid\":$fake_pid}"
run_alive "$tmp" Cyclops \
  || fail "alive-for-a-live-pid-that-names-the-agent: reported dead for its own session"
pass "alive-for-a-live-pid-that-names-the-agent"

# --- dead-for-a-live-pid-whose-name-is-only-a-prefix ---
# One agent's live session, named in another agent's state file: alive as Cyclops, dead as the
# planner below. This is the everyday form of the identity check - a pid is alive for exactly one
# name. Both the present name and the absent one are taken from the roster rather than spelled out,
# so a consumer with its own fleet still runs these cases (ah-qled.5.1).
# `sed -n 1p' rather than `head -n 1': head closes the pipe on its first line, and under
# `set -o pipefail' roster's EPIPE would then kill this suite rather than name a planner.
prefix_name="$("$repo_root/scripts/roster" --role planner | sed -n 1p)"
[[ -n "$prefix_name" ]] || fail "prefix-name: the roster names no planner"
suffixed_name="${prefix_name}ly"
write_state "$tmp" "$prefix_name" "{\"state\":\"working\",\"pid\":$fake_pid}"
if run_alive "$tmp" "$prefix_name"; then
  fail "dead-for-a-live-pid-whose-name-is-only-a-prefix: matched --name Cyclops as $prefix_name"
fi
pass "dead-for-a-live-pid-whose-name-is-only-a-prefix"

# The case the word boundary itself is about, and the one that fails without it: a live pid whose
# args carry the name with something appended. The name is taken from the roster rather than spelled
# out, so a consumer with its own fleet still runs this case (ah-qled.5.1): `$prefix_name' is on the
# roster, `$prefix_name'ly is not a session of its, and `--name $prefix_name' must not match inside
# it.
printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmp/fake-suffixed"
chmod +x "$tmp/fake-suffixed"
bash "$tmp/fake-suffixed" --name "$suffixed_name" \
  --settings "$tmp/.claude/cerebro/scripts/../hooks/question-state.settings.json" &
suffixed_pid=$!
strays+=("$suffixed_pid")
for child in $(pgrep -P "$suffixed_pid" 2>/dev/null || true); do strays+=("$child"); done
write_state "$tmp" "$prefix_name" "{\"state\":\"working\",\"pid\":$suffixed_pid}"
if run_alive "$tmp" "$prefix_name"; then
  fail "dead-for-a-live-pid-with-the-name-as-a-prefix-of-its-own: matched --name $suffixed_name as $prefix_name"
fi
pass "dead-for-a-live-pid-with-the-name-as-a-prefix-of-its-own"

# --- dead-for-the-same-name-in-another-consumer ---
# The cross product the two earlier fixes each left open (cb-lzi): a live pid whose command line
# names this agent - but as another checkout's fleet. Every consumer on the built-in roster has a
# Cyclops; pid plus name alone would call this one ours and let a planner free a label it holds.
other="$(new_fixture)"
mkdir -p "$other/.claude/cerebro/hooks"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$other/fake-session"
chmod +x "$other/fake-session"
bash "$other/fake-session" --name Cyclops \
  --settings "$other/.claude/cerebro/scripts/../hooks/question-state.settings.json" &
other_pid=$!
strays+=("$other_pid")
for child in $(pgrep -P "$other_pid" 2>/dev/null || true); do strays+=("$child"); done
write_state "$tmp" Cyclops "{\"state\":\"working\",\"pid\":$other_pid}"
if run_alive "$tmp" Cyclops; then
  fail "dead-for-the-same-name-in-another-consumer: another checkout's Cyclops read as ours"
fi
pass "dead-for-the-same-name-in-another-consumer"

# And alive when asked from the consumer it does belong to - the root is a discriminator, not a
# second way of saying dead.
write_state "$other" Cyclops "{\"state\":\"working\",\"pid\":$other_pid}"
run_alive "$other" Cyclops \
  || fail "alive-in-its-own-consumer: its own fleet's check reported it dead"
pass "alive-in-its-own-consumer"

# --- dead-for-a-session-that-names-no-root ---
# A hand-typed `claude --name Cyclops' with no --settings: nothing can prove whose fleet it is,
# and reading it as ours is the defect. The same trade cerebro--consumer-args made (9420ff2).
printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmp/fake-rootless"
chmod +x "$tmp/fake-rootless"
bash "$tmp/fake-rootless" --name Cyclops &
rootless_pid=$!
strays+=("$rootless_pid")
for child in $(pgrep -P "$rootless_pid" 2>/dev/null || true); do strays+=("$child"); done
write_state "$tmp" Cyclops "{\"state\":\"working\",\"pid\":$rootless_pid}"
if run_alive "$tmp" Cyclops; then
  fail "dead-for-a-session-that-names-no-root: a session naming no root read as ours"
fi
pass "dead-for-a-session-that-names-no-root"

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

echo "all agent-alive tests passed"
