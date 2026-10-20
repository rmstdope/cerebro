#!/usr/bin/env bash
#
# R16, as a navigator meets it: a producer whose session died mid-bead is retried on a backoff,
# and its row says when and how many starts failed. A SYSTEM suite (.cerebro/test-architecture.md):
# it builds the real `cerebro-tui', runs it on a pseudo-terminal over a throwaway consumer, and
# asserts what the view did and drew. The rules underneath - the backoff table and its indexing
# (`triggers::retry_delay', `retry_wait', `start_decision'), the row's words (`retry_label') and the
# give-back (`give_back', `scripts/release-bead') - are tested on their own; this proves the path
# through them.
#
# Real, and unstubbed: the view, `scripts/launch', its preflight, `assign-bead', `assignable-beads',
# `prepare-worktree' (against the fixture's own origin), `release-bead' and `agent-alive'. Stubbed,
# because this suite may not touch them: `bd' (one JSON file per bead, every call logged), `gh', and
# the agent CLI `claude', which records what it was handed and what the board said about that bead
# at its first moment, then exits 1 without ever reporting - a producer that died on its bead before
# a pass ran, which is what the view counts as a failed start.
#
# The fleet is one standby producer, Rogue, and the board one bead it may take, cb-b1. What is
# watched, in the order a person would see it:
#   1. Rogue is started on cb-b1, claimed for it; the session dies; the view gives cb-b1 back
#      (`give-back', cause `did-not-start') and starts Rogue on it again. The first two failures
#      come straight back (`RETRY_BACKOFF[0]' is 0), so there are three starts in quick succession;
#   2. after the third, Rogue is held: its row reads `↻ retry in <n>s, 2 failed', an evaluation
#      logs it `backed_off' with `failed_starts' 2, and the fourth start comes no sooner than 30
#      seconds after the third;
#   3. after the fourth, the wait has grown: the row reads `↻ retry in 2m, 3 failed'.
# The suite stops there. The two-minute and ten-minute waits and the give-up after five are the
# unit tests' to pin; waiting them out here would cost a quarter of an hour for nothing new.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child
# (.cerebro/traps.md). Every wait is a bounded poll that fails with what the view saw and did.
# The suite costs about a minute, most of it the 30-second backoff R16 names.
#
#     bash tests/fleet-retry.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_passed - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-retry needs $tool on PATH"
done

# --- the binary -----------------------------------------------------------------------------------

build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" --bin cerebro-tui \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui failed: $(tail -20 "$build_log")"
fi
binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "cerebro-tui")
                 | .executable // empty' <<<"$artifacts" | tail -1)"
[ -x "$binary" ] || fail "cargo build named no cerebro-tui executable"

# --- the consumer ---------------------------------------------------------------------------------

# An origin, because the real `prepare-worktree' fetches from it to make the producer's tree.
consumer="$(consumer_new retry --origin --copy)"
state="$consumer/.cerebro/state"
fixture="$work_dir/fixture"
stubs="$fixture/stubs"
beads="$fixture/beads"
mkdir -p "$stubs" "$beads"

cat > "$consumer/.cerebro/project.conf" <<'CONF'
project_name   Retry
default_branch main
audience_noun  navigator
gate_fast      true
gate_full      true
CONF

cat > "$consumer/.cerebro/roster.conf" <<'ROSTER'
Rogue           producer        standby
ROSTER

# The fixture's own files stay out of the consumer's status, so a worktree made from it is clean.
printf '.cerebro/worktrees/\n.cerebro/state/\n' >> "$consumer/.git/info/exclude"

jq -n '{
  id: "cb-b1", title: "fixture cb-b1", status: "open", priority: 1, issue_type: "task",
  labels: ["ux:agreed"], assignee: "", owner: "test",
  design: "## Validation\ndisk-preflight --workload non-rust\n",
  created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
}' > "$beads/cb-b1.json"

# --- stub bd: one JSON file per bead, every call logged -------------------------------------------
cat > "$stubs/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/bd.log"
actor="${BEADS_ACTOR:-}"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly|--quiet|-q) shift ;;
    -C) shift 2 ;;
    --actor) actor="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
dir="$FIXTURE/beads"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
all() { cat "$dir"/*.json | jq -s 'sort_by(.id)'; }
edit() {
  # <id> <jq filter>
  local file="$dir/$1.json" tmp
  [[ -f "$file" ]] || { echo "no issue found: $1" >&2; exit 1; }
  tmp="$(mktemp "$dir/.edit-XXXXXX")"
  jq --arg now "$(now)" "$2 | .updated_at = \$now" "$file" > "$tmp"
  mv "$tmp" "$file"
}
cmd="${1:-}"
shift || true
case "$cmd" in
  list)
    statuses=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) statuses="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -n "$statuses" ]]; then
      all | jq --arg s "$statuses" '($s | split(",")) as $want | [ .[] | select(.status as $x | $want | index($x)) ]'
    else
      all | jq '[ .[] | select(.status != "closed") ]'
    fi
    ;;
  ready)
    all | jq '[ .[] | select(.status == "open" and (.assignee // "") == "") ]' ;;
  show)
    [[ -f "$dir/$1.json" ]] || { echo "no issue found: $1" >&2; exit 1; }
    jq -s . "$dir/$1.json" ;;
  update)
    id="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --claim)
          held="$(jq -r '.assignee // ""' "$dir/$id.json")"
          if [[ -n "$held" ]]; then
            echo "already claimed by $held" >&2
            exit 1
          fi
          edit "$id" ".assignee = \"$actor\" | .status = \"in_progress\""; shift ;;
        *) shift ;;
      esac
    done ;;
  unclaim)
    # `release-bead' gives a dead session's bead back with `unclaim <id> --if-assignee <Name>'.
    id="$1"; shift
    want=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --if-assignee) want="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    held="$(jq -r '.assignee // ""' "$dir/$id.json")"
    if [[ -n "$want" && "$held" != "$want" ]]; then
      echo "assignee is $held, not $want" >&2
      exit 13
    fi
    edit "$id" '.assignee = "" | .status = "open"' ;;
  dolt|heartbeat) ;;
  *) echo '[]' ;;
esac
STUB

cat > "$stubs/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/gh.log"
echo '[]'
STUB

# --- stub claude: a producer that dies on its bead before a pass runs -----------------------------
#
# `launch' has run `assign-bead' and exec'd this, so the handover file names the bead and the board
# already says who holds it. Both are recorded, then the session exits 1 without a state file.
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
set -u
root="$CEREBRO_CONSUMER_SHARED_ROOT"
name="$BEADS_ACTOR"
bead="$(head -n 1 "$root/.cerebro/state/$name.handover" 2>/dev/null || true)"
held="$(jq -r '"\(.status) \(.assignee)"' "$FIXTURE/beads/$bead.json" 2>/dev/null || echo "unreadable")"
printf '%s %s %s %s\n' "$(date +%s)" "$name" "${bead:-none}" "$held" >> "$FIXTURE/sessions"
echo "fixture: $name died on ${bead:-nothing}"
exit 1
STUB
chmod +x "$stubs/bd" "$stubs/gh" "$stubs/claude"

# The links a consumer keeps synced, made now, as any consumer that has run a session already has
# them (the reason is in tests/fleet-producer-start.sh).
"$consumer/.cerebro/cerebro/scripts/sync-symlinks.sh" >/dev/null \
  || fail "sync-symlinks.sh could not link the fixture"

hints="$("$consumer/.cerebro/cerebro/scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r mount; } <<<"$hints"
[ -n "$shared" ] || fail "consumer-root --hints gave no shared root for the fixture"

# --- the view, on a pty ---------------------------------------------------------------------------

driver=""
suite_cleanup() {
  [ -n "$driver" ] && kill "$driver" 2>/dev/null || true
  pkill -f "$work_dir" 2>/dev/null || true
  wait 2>/dev/null || true
  return 0
}

evidence() {
  printf '\n--- screen ---\n';            cat "$work_dir/view.screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n';     cat "$work_dir/view.err" 2>/dev/null || true
  printf -- '--- sessions ---\n';        cat "$fixture/sessions" 2>/dev/null || echo "(none)"
  printf -- '--- beads ---\n';           jq -c '{id, status, assignee}' "$beads"/*.json 2>/dev/null || true
  printf -- '--- bd.log (tail) ---\n';   tail -n 20 "$fixture/bd.log" 2>/dev/null || true
  printf -- '--- decisions ---\n';       cat "$state/decisions.jsonl" 2>/dev/null || echo "(none)"
  printf -- '--- evaluations (tail) ---\n'
  tail -n 12 "$state/evaluations.jsonl" 2>/dev/null || echo "(none)"
  # fleet-history, fleet-health and the sweeps log errors against this fixture's empty board and
  # missing transition log, and every dead session logs its exit; expected, and not what is asserted.
  printf -- '--- errors (tail) ---\n'
  tail -n 12 "$state/errors.jsonl" 2>/dev/null || echo "(none)"
}

# wait_until <seconds> <what> <command...>: poll until the command succeeds, or fail naming <what>.
# A ceiling, not a cost. The view exiting fails the wait at once.
wait_until() {
  local bound="$1" what="$2" deadline
  shift 2
  deadline=$((SECONDS + bound))
  until "$@"; do
    ((SECONDS < deadline)) || fail "after ${bound}s, still waiting for: $what$(evidence)"
    kill -0 "$driver" 2>/dev/null || fail "the fleet view exited while waiting for: $what$(evidence)"
    sleep 0.25
  done
}

mkfifo "$work_dir/view.keys"
export FIXTURE="$fixture"
(
  cd "$consumer"
  export CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
         CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$consumer/.cerebro/cerebro/scripts" \
         PATH="$stubs:$PATH" TERM=xterm-256color
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$work_dir/view.keys" "$work_dir/view.screen" \
    50 200 -- "$binary"
) </dev/null >/dev/null 2>"$work_dir/view.err" &
driver=$!
# Held open read-write for the whole suite, so the open never blocks.
exec 7<>"$work_dir/view.keys"

session_count() { [ -f "$fixture/sessions" ] && wc -l < "$fixture/sessions" | tr -d ' ' || echo 0; }
has_sessions() { (( $(session_count) >= $1 )); }
# The `ts' of the view's Nth trigger start of Rogue (1-based), as epoch seconds.
start_at() {
  local ts
  ts="$(jq -rs --argjson n "$1" \
          '[.[] | select(.event == "start" and .agent == "Rogue" and .by == "trigger")] | .[$n - 1].ts // empty' \
          "$state/decisions.jsonl" 2>/dev/null || true)"
  [ -n "$ts" ] || return 0
  python3 -I -c 'import sys, datetime; print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$ts"
}
has_start() { [ -n "$(start_at "$1")" ]; }
give_backs() {
  jq -s '[.[] | select(.event == "give-back" and .agent == "Rogue" and .bead == "cb-b1" and .cause == "did-not-start")] | length' \
    "$state/decisions.jsonl" 2>/dev/null || echo 0
}
has_give_backs() { (( $(give_backs) >= $1 )); }
# The Fleet pane's row for Rogue, as the screen shows it: the cell between the pane's two borders,
# not the header notice or the Session pane beside it, which name Rogue too.
rogue_row() {
  local line
  line="$(grep -m1 'Rogue  *producer' "$work_dir/view.screen" 2>/dev/null || true)"
  line="${line#*┃}"
  line="${line%%┃*}"
  printf '%s' "$line" | sed 's/^ *//; s/ *$//'
}
row_says() { local row; row="$(rogue_row)"; [[ "$row" == *"$1"* && "$row" == *"$2"* ]]; }

# Every session was handed cb-b1, already in progress and Rogue's at its first moment.
all_claimed_at_start() {
  local bad
  bad="$(awk '!($2 == "Rogue" && $3 == "cb-b1" && $4 == "in_progress" && $5 == "Rogue")' \
           "$fixture/sessions" 2>/dev/null || true)"
  [ -z "$bad" ] || fail "a session began without cb-b1 claimed for it: $bad$(evidence)"
}

# --- 1. the dead session's bead is given back, and Rogue is started on it again -------------------

wait_until 90 "Rogue's first session" has_sessions 1
wait_until 30 "the give-back of cb-b1 from Rogue's dead session" has_give_backs 1
wait_until 30 "Rogue's second session" has_sessions 2
wait_until 30 "Rogue's third session" has_sessions 3
wait_until 10 "the view's third start line for Rogue" has_start 3
all_claimed_at_start
first="$(start_at 1)"; third="$(start_at 3)"
((third - first < 30)) \
  || fail "the first three starts took $((third - first))s; the first two failures should come straight back$(evidence)"
pass "Rogue's dead session gives cb-b1 back, and Rogue is started on it again at once, claimed each time"

# --- 2. after two failures, a 30-second backoff the row counts down -------------------------------

wait_until 30 "the give-back after the third session" has_give_backs 3
wait_until 20 "Rogue's row to read '↻ retry in …s, 2 failed'" row_says "↻ retry in " "s, 2 failed"
jq -se 'any(.[]; .agent == "Rogue" and .backed_off == true and .failed_starts == 2)' \
  "$state/evaluations.jsonl" >/dev/null 2>&1 \
  || fail "no evaluation shows Rogue backed off with 2 failed starts$(evidence)"
(( $(session_count) == 3 )) || fail "Rogue was started again while its row said it was waiting$(evidence)"
held_row="$(rogue_row)"
wait_until 60 "Rogue's fourth session" has_sessions 4
wait_until 10 "the view's fourth start line for Rogue" has_start 4
all_claimed_at_start
fourth="$(start_at 4)"
((fourth - third >= 30)) \
  || fail "Rogue's fourth start came $((fourth - third))s after its third; R16's backoff is 30s after two failures$(evidence)"
pass "after two failed starts Rogue waits $((fourth - third))s, its row saying so: '$held_row'"

# --- 3. after three, the wait has grown, and the row says how long and how many -------------------

wait_until 30 "Rogue's row to read '↻ retry in 2m, 3 failed'" row_says "↻ retry in 2m" ", 3 failed"
(( $(session_count) == 4 )) || fail "Rogue was started a fifth time inside its two-minute backoff$(evidence)"
grown_row="$(rogue_row)"
pass "after three failed starts the wait grows to two minutes: '$grown_row'"

suite_passed
