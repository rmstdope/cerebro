#!/usr/bin/env bash
#
# R24, as a navigator meets it: the web console shows the fleet a fleet view supervises, starts and
# kills its agents through that view, and shows and types into the sessions it hosts. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui' and `cerebro-web', runs the view
# on a pseudo-terminal against a throwaway consumer and the service beside it, and drives the
# service's HTTP API the way the page does - the same paths, the same `X-Cerebro-Input' header.
#
# The page itself is the Browser suite's (web-console/ui/tests, against a mocked API) and the
# service's reads and refusals are the Edge tests' (web-console/tests/service.rs, against fake
# commands). Neither meets a real fleet view, which is where cb-gyw0 broke: the console and the
# view that hosted a session disagreed about it. This proves the two halves together.
#
# The fixture is tests/fleet-keys.sh's:
#   - one roster row, `Forge architect standby': an architect is handed no bead, so a start
#     launches without a board.
#   - a stub `claude' that writes `working' through the real `scripts/agent-state', records its
#     pid, and answers every line typed into its terminal with `heard: <line>'.
#   - `bd' and `gh' stubs that refuse: the board is not part of this suite.
#
# Both binaries are built with `cargo build' and run by this suite itself - never as cargo's child
# (.cerebro/traps.md). Every wait is a bounded poll that fails with the evidence; there is no sleep.
#
#     bash tests/web-console.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || fail "web-console needs $tool on PATH"
done

# --- the binaries -----------------------------------------------------------------------------------
#
# Debug, into the target directory the gate's own `cargo test' uses, so the build is incremental.
build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" \
                    --bin cerebro-tui --bin cerebro-web \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui and cerebro-web failed: $(tail -20 "$build_log")"
fi
executable() {
  jq -r --arg n "$1" 'select(.reason == "compiler-artifact" and .target.name == $n)
                      | .executable // empty' <<<"$artifacts" | tail -1
}
view_binary="$(executable cerebro-tui)"
web_binary="$(executable cerebro-web)"
[ -x "$view_binary" ] || fail "cargo build named no cerebro-tui executable"
[ -x "$web_binary" ] || fail "cargo build named no cerebro-web executable"

# --- the consumer -----------------------------------------------------------------------------------

consumer="$(consumer_new console --copy)"
state="$consumer/.cerebro/state"
stub_state="$consumer/.cerebro/stub"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"

stubs="$work_dir/stubs"
mkdir -p "$stubs" "$stub_state"
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
# A session: report in as an agent does, then answer each line typed into it until it is killed.
set -u
scripts="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/cerebro/scripts"
dir="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/stub"
"$scripts/agent-state" "$BEADS_ACTOR" working --pid $$
echo $$ > "$dir/$BEADS_ACTOR.pid"
echo "stub session for $BEADS_ACTOR"
while IFS= read -r line; do
  echo "heard: $line"
done
# The terminal closed under it: wait to be ended rather than end the pass itself.
while :; do sleep 1; done
STUB
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' bd > "$stubs/bd"
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' gh > "$stubs/gh"
chmod +x "$stubs/claude" "$stubs/bd" "$stubs/gh"

hints="$("$consumer/.cerebro/cerebro/scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r mount; } <<<"$hints"
[ -n "$shared" ] || fail "consumer-root --hints gave no shared root for the fixture"

# --- the view, on a pty -----------------------------------------------------------------------------

keys="$work_dir/keys.fifo"
screen="$work_dir/screen.txt"
view_err="$work_dir/view.err"
web_err="$work_dir/web.err"
mkfifo "$keys"

(
  cd "$consumer"
  export CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
         CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$consumer/.cerebro/cerebro/scripts" \
         PATH="$stubs:$PATH" TERM=xterm-256color
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$keys" "$screen" 50 200 -- "$view_binary"
) </dev/null >/dev/null 2>"$view_err" &
view_pid=$!
web_pid=""

suite_cleanup() {
  [ -z "$web_pid" ] || kill "$web_pid" 2>/dev/null || true
  kill "$view_pid" 2>/dev/null || true
  # Whatever the view started and did not get to end: every stub's argv names $work_dir.
  pkill -f "$work_dir" 2>/dev/null || true
  wait 2>/dev/null || true
}

exec 7<>"$keys"
press() { printf '%s' "$1" >&7; }

last_answer="$work_dir/last-answer"

# What a failed wait says: the screen, both programs' stderr and the service's last answer.
evidence() {
  printf '\n--- last API answer ---\n'
  cat "$last_answer" 2>/dev/null || echo "(none)"
  printf '\n--- screen ---\n'
  cat "$screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n'
  cat "$view_err" 2>/dev/null || true
  printf -- '--- service stderr ---\n'
  cat "$web_err" 2>/dev/null || true
}

# wait_until <what> <command...>: poll for up to 20 s, or $polls fifths of a second.
wait_until() {
  local what="$1" i
  shift
  for ((i = 0; i < ${polls:-100}; i++)); do
    if "$@"; then return 0; fi
    kill -0 "$view_pid" 2>/dev/null || [ -n "${view_may_exit:-}" ] \
      || fail "the view exited while waiting for: $what$(evidence)"
    sleep 0.2
  done
  fail "timed out waiting for: $what$(evidence)"
}

# --- the service, beside it ---------------------------------------------------------------------------
#
# On a port found free a moment ago, which is not reserved (.cerebro/traps.md): a start that loses
# the port to somebody else is retried on a fresh one; any other exit fails at once.
free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
for ((attempt = 0; attempt < 10; attempt++)); do
  port="$(free_port)"
  (
    cd "$consumer"
    export CEREBRO_SHARED_ROOT="$shared" CEREBRO_WEB_ADDRESS="127.0.0.1:$port" PATH="$stubs:$PATH"
    exec "$web_binary"
  ) </dev/null >/dev/null 2>"$web_err" &
  web_pid=$!
  for ((i = 0; i < 100; i++)); do
    curl -s -o /dev/null "http://127.0.0.1:$port/api/control" && break
    kill -0 "$web_pid" 2>/dev/null || break
    sleep 0.2
  done
  kill -0 "$web_pid" 2>/dev/null && break
  wait "$web_pid" 2>/dev/null || true
  web_pid=""
  grep -qi 'address already in use' "$web_err" \
    || fail "cerebro-web exited on starting$(evidence)"
done
[ -n "$web_pid" ] || fail "cerebro-web found no port it could bind in 10 attempts$(evidence)"
base="http://127.0.0.1:$port"

# get <path>: the service's JSON answer, kept as the evidence of a failed wait.
get() { curl -sS --max-time 10 "$base$1" | tee "$last_answer"; }
# post <path> [body]: as the page posts, with the console's header; prints the status, then the body.
post() {
  curl -sS --max-time 10 -o "$last_answer" -w '%{http_code}' \
       -H 'X-Cerebro-Input: 1' -X POST --data-binary "${2-}" "$base$1"
}

supervised() { get /api/control | jq -e '.supervised == true' >/dev/null 2>&1; }
read_only() { get /api/control | jq -e '.supervised == false and (has("error") | not)' >/dev/null 2>&1; }
# row <jq predicate on Forge's row>
row() { get /api/fleet | jq -e "[.value[] | select(.name == \"Forge\")] | first | $1" >/dev/null 2>&1; }
alive() { kill -0 "$1" 2>/dev/null; }
gone() { ! kill -0 "$1" 2>/dev/null; }
started() { [ -s "$stub_state/Forge.pid" ]; }
# The whole of Forge's session log as the page reads it, chunk by chunk from offset 0.
session_text() {
  local log="" from="" answer
  while :; do
    answer="$(curl -sS --max-time 10 "$base/api/sessions/Forge${log:+?log=$log&from=$from}")" || return 1
    printf '%s' "$answer" > "$last_answer"
    [ "$(jq -r .state <<<"$answer")" = live ] || return 1
    jq -j .data <<<"$answer"
    [ "$(jq -r .more <<<"$answer")" = true ] || return 0
    log="$(jq -r .log <<<"$answer")"
    from="$(jq -r .offset <<<"$answer")"
  done
}
session_says() { session_text 2>/dev/null | grep -q "$1"; }
session_absent() { get /api/sessions/Forge | jq -e '.state == "absent"' >/dev/null 2>&1; }

# --- the fleet, as the console reads it ---------------------------------------------------------------

wait_until "the console to see the view supervising" supervised
wait_until "Forge's row in the console's fleet, on standby" row '.state == "Standby"'
pass "the console sees the supervising view and Forge's row on standby"

# --- start, through the view --------------------------------------------------------------------------

status="$(post /api/agents/Forge/start)"
[ "$status" = 200 ] || fail "start: answered $status$(evidence)"
jq -e '.done == true' "$last_answer" >/dev/null || fail "start: the view refused it$(evidence)"
wait_until "the stub agent to start" started
agent="$(cat "$stub_state/Forge.pid")"
alive "$agent" || fail "start: the stub agent is not running"
wait_until "Forge's row to read hosted and working" row '.hosted == true and .state == "Working"'
pass "Start asks the view, which starts Forge in a session it hosts; the console shows it working"

# --- the session: watched and typed into --------------------------------------------------------------

wait_until "Forge's session output in the console" session_says 'stub session for Forge'
status="$(post /api/sessions/Forge/input $'hello\r')"
[ "$status" = 204 ] || fail "input: answered $status$(evidence)"
wait_until "the typed line to reach the agent and its answer the console" session_says 'heard: hello'
pass "the console shows Forge's session, and what it types reaches the agent"

# --- kill, through the view ---------------------------------------------------------------------------

status="$(post /api/agents/Forge/kill)"
[ "$status" = 200 ] || fail "kill: answered $status$(evidence)"
jq -e '.done == true' "$last_answer" >/dev/null || fail "kill: the view refused it$(evidence)"
wait_until "the stub agent to be killed" gone "$agent"
wait_until "the console to show no session" session_absent
wait_until "Forge's row to read dead and unhosted" row '(.hosted // false) == false and .state == "Dead"'
pass "Kill asks the view, which ends Forge's session; the console shows it dead with no session"

# --- no view, read-only --------------------------------------------------------------------------------

rm -f "$stub_state/Forge.pid"
view_may_exit=1
press q
for ((i = 0; i < 100; i++)); do
  alive "$view_pid" || break
  sleep 0.2
done
alive "$view_pid" && fail "q: the view did not exit$(evidence)"
# The view leaves its last publication behind; it reads as no view once it is 15 s old
# (SCREEN_STALE_SECONDS) and its control socket no longer answers. So this wait is 30 s.
polls=150 wait_until "the console to read the checkout as unsupervised" read_only
status="$(post /api/agents/Forge/start)"
[ "$status" = 503 ] || fail "start with no view: answered $status$(evidence)"
jq -e '.done == false' "$last_answer" >/dev/null || fail "start with no view: not refused$(evidence)"
started && fail "start with no view: an agent started anyway"
pass "with no fleet view supervising, the console reads the checkout as read-only and starts nothing"

suite_passed
