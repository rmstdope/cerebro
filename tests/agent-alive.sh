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

# Fixtures and background processes are cleaned up from one trap, so a failed assertion leaves
# neither a mktemp directory nor a `sleep' behind - `fail' exits, so per-case cleanup would not run.
fixtures=()
strays=()

cleanup() {
  local p
  for p in ${strays+"${strays[@]}"}; do kill "$p" 2>/dev/null || true; done
  local d
  for d in ${fixtures+"${fixtures[@]}"}; do rm -rf "$d"; done
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# The same fixture shape tests/agent-state.sh uses: a git repo with its own scripts/ directory
# symlinked to the real scripts, so consumer-root --shared resolves inside the fixture.
new_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  git init -q "$tmp"
  git -C "$tmp" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
  mkdir -p "$tmp/.claude/cerebro/scripts"
  ln -s "$repo_root/scripts/roster" "$tmp/.claude/cerebro/scripts/roster"
  ln -s "$repo_root/scripts/agent-alive" "$tmp/.claude/cerebro/scripts/agent-alive"
  ln -s "$repo_root/scripts/consumer-root" "$tmp/.claude/cerebro/scripts/consumer-root"
  fixtures+=("$tmp")
  printf '%s' "$tmp"
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
bash "$tmp/fake-session" --name Cyclops &
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
# One agent's live session, named in another agent's state file: alive as Cyclops, dead as Beast.
# This is the everyday form of the identity check - a pid is alive for exactly one name.
write_state "$tmp" Beast "{\"state\":\"working\",\"pid\":$fake_pid}"
if run_alive "$tmp" Beast; then
  fail "dead-for-a-live-pid-whose-name-is-only-a-prefix: matched --name Cyclops as Beast"
fi
pass "dead-for-a-live-pid-whose-name-is-only-a-prefix"

# The case the word boundary itself is about, and the one that fails without it: a live pid whose
# args carry the name with something appended. `Beast' is on the roster; `Beastly' is not a session
# of Beast's, and `--name Beast' must not match inside it.
printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmp/fake-beastly"
chmod +x "$tmp/fake-beastly"
bash "$tmp/fake-beastly" --name Beastly &
beastly_pid=$!
strays+=("$beastly_pid")
for child in $(pgrep -P "$beastly_pid" 2>/dev/null || true); do strays+=("$child"); done
write_state "$tmp" Beast "{\"state\":\"working\",\"pid\":$beastly_pid}"
if run_alive "$tmp" Beast; then
  fail "dead-for-a-live-pid-with-the-name-as-a-prefix-of-its-own: matched --name Beastly as Beast"
fi
pass "dead-for-a-live-pid-with-the-name-as-a-prefix-of-its-own"

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
