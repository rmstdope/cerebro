#!/usr/bin/env bash
#
# R13, as a navigator meets it: a producer is started, with a bead claimed for it, when a ranked
# UX-agreed unclaimed bead exists; at most one every 30 seconds. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs it on a pseudo-terminal
# over a throwaway consumer, and asserts what the fleet and the board were left with. The rules
# underneath - the trigger and its spacing (`triggers::start_decision', `role_start_too_soon'),
# the queue (`scripts/assignable-beads') and the claim (`scripts/assign-bead') - are tested on their
# own; this proves the path through them.
#
# Real, and unstubbed: the view, `scripts/launch' (the view's one way to start a session), its
# preflight, `assign-bead', `assignable-beads', `disk-preflight' (the fixture declares no floor),
# `prepare-worktree' (against the fixture's own origin) and `agent-state'. Stubbed, because this
# suite may not touch them: `bd' (one JSON file per bead, every call logged), `gh', and the agent
# CLI `claude', which reads the handover `assign-bead' left it, records when it started and what
# the board said about its bead at that moment, reports `working' through the real `agent-state',
# and waits to be killed.
#
# The fleet is two standby producers, Rogue and Gambit, and the board holds two beads a producer
# may take (cb-b1 at P1, cb-b2 at P2, both `ux:agreed'). Two things are watched, in the order a
# person would see them:
#   1. Rogue is started on cb-b1, which is claimed for Rogue - in progress, Rogue's, with its tree
#      made - before Rogue's session exists;
#   2. Gambit is started on cb-b2, claimed the same way, no sooner than 30 seconds after Rogue: in
#      between, the view logged an evaluation in which Gambit was due and held by the spacing.
# Which beads a producer may NOT take - unranked, un-agreed, held - is `assignable-beads'' own
# decision, proven in tests/assignable-beads.sh and not re-proven here (cb-n895).
#
# Until cb-gkhx the view exempted producers from the spacing (`triggers::role_peers'), so the first
# tick started Rogue and Gambit together, their two launch preflights raced over the same symlinks,
# and one session died before it began. Step 2 is what keeps that from coming back.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child
# (.cerebro/traps.md). Every wait is a bounded poll that fails with what the view saw and did.
# The suite costs about 35 seconds, most of it the 30-second window R13 names.
#
#     bash tests/fleet-producer-start.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_passed - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-producer-start needs $tool on PATH"
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

# An origin, because the real `prepare-worktree' fetches from it to make each producer's tree.
consumer="$(consumer_new prodstart --origin --copy)"
state="$consumer/.cerebro/state"
fixture="$work_dir/fixture"
stubs="$fixture/stubs"
beads="$fixture/beads"
mkdir -p "$stubs" "$beads" "$fixture/started"

cat > "$consumer/.cerebro/project.conf" <<'CONF'
project_name   ProducerStart
default_branch main
audience_noun  navigator
gate_fast      true
gate_full      true
CONF

cat > "$consumer/.cerebro/roster.conf" <<'ROSTER'
Rogue           producer        standby
Gambit          producer        standby
ROSTER

# The fixture's own files stay out of the consumer's status, so a worktree made from it is clean.
printf '.cerebro/worktrees/\n.cerebro/state/\n' >> "$consumer/.git/info/exclude"

bead() {
  # <id> <priority> <labels as a JSON array>
  jq -n --arg id "$1" --argjson p "$2" --argjson labels "$3" '{
    id: $id, title: ("fixture " + $id), status: "open", priority: $p, issue_type: "task",
    labels: $labels, assignee: "", owner: "test",
    design: "## Validation\ndisk-preflight --workload non-rust\n",
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
  }' > "$beads/$1.json"
}
bead cb-b1   1 '["ux:agreed"]'
bead cb-b2   2 '["ux:agreed"]'

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
    # Open and unassigned: what `assignable-beads' asks for with `--unassigned'. The label and type
    # exclusions it passes name nothing this board carries.
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
          [[ -z "$held" ]] || { echo "already claimed by $held" >&2; exit 1; }
          edit "$id" ".assignee = \"$actor\" | .status = \"in_progress\""; shift ;;
        *) shift ;;
      esac
    done ;;
  dolt|heartbeat) ;;
  *) echo '[]' ;;
esac
STUB

cat > "$stubs/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/gh.log"
echo '[]'
STUB

# --- stub claude: a session that reports in with the bead it was handed ---------------------------
#
# `launch' has run `assign-bead' and exec'd this, so the handover file names the bead and the board
# already says who holds it. Both are recorded here, at the session's first moment: a claim made
# after the session existed would show as an unclaimed bead on this line.
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
set -u
root="$CEREBRO_CONSUMER_SHARED_ROOT"
scripts="$root/.cerebro/cerebro/scripts"
name="$BEADS_ACTOR"
bead="$(head -n 1 "$root/.cerebro/state/$name.handover" 2>/dev/null || true)"
held="$(jq -r '"\(.status) \(.assignee)"' "$FIXTURE/beads/$bead.json" 2>/dev/null || echo "unreadable")"
tree=no
[ -d "$root/.cerebro/worktrees/$bead" ] && tree=yes
printf '%s %s %s %s tree=%s\n' "$(date +%s)" "$name" "${bead:-none}" "$held" "$tree" >> "$FIXTURE/sessions"
"$scripts/agent-state" "$name" working --bead "$bead" --phase build --pid $$
while :; do sleep 0.2; done
STUB
chmod +x "$stubs/bd" "$stubs/gh" "$stubs/claude"

# The links a consumer keeps synced, made now, as any consumer that has run a session already has
# them. Left to the first launch, two launch preflights both find them missing and both run
# `sync-symlinks.sh', and one loses with `ln: File exists' - a separate defect, and not R13's: on a
# loaded machine a launch can take longer than the 30-second spacing.
"$consumer/.cerebro/cerebro/scripts/sync-symlinks.sh" >/dev/null \
  || fail "sync-symlinks.sh could not link the fixture"

hints="$("$consumer/.cerebro/cerebro/scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r mount; } <<<"$hints"
[ -n "$shared" ] || fail "consumer-root --hints gave no shared root for the fixture"

# --- the view, on a pty ---------------------------------------------------------------------------

driver=""
suite_cleanup() {
  [ -n "$driver" ] && kill "$driver" 2>/dev/null || true
  # Whatever the view started and did not get to end: every stub's path names $work_dir.
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
  # missing transition log; expected, and no part of what is asserted.
  printf -- '--- errors (tail; history, health and sweep errors are expected) ---\n'
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
    sleep 0.5
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
# Held open read-write for the whole suite, so the open never blocks: a key is one printf.
exec 7<>"$work_dir/view.keys"

# `<epoch> <Name> <bead> <status> <assignee> tree=<yes|no>' for NAME's session, if it started.
session_of() { awk -v n="$1" '$2 == n { print; exit }' "$fixture/sessions" 2>/dev/null || true; }
has_session() { [ -n "$(session_of "$1")" ]; }
session_count() { [ -f "$fixture/sessions" ] && wc -l < "$fixture/sessions" | tr -d ' ' || echo 0; }
# The `ts' of the view's start line for NAME, as epoch seconds.
start_ts() {
  jq -rs --arg a "$1" 'map(select(.event == "start" and .agent == $a)) | .[0].ts // empty' \
    "$state/decisions.jsonl" 2>/dev/null || true
}
epoch() {
  python3 -I -c 'import sys, datetime; print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$1"
}
has_start_line() { [ -n "$(start_ts "$1")" ]; }

# claimed_at_start <Name> <bead>: NAME's session was handed BEAD, which was already in progress,
# NAME's, and had its tree when the session began.
claimed_at_start() {
  local line
  line="$(session_of "$1")"
  [ "${line#* }" = "$1 $2 in_progress $1 tree=yes" ] \
    || fail "$1's session began with: '${line#* }', expected '$1 $2 in_progress $1 tree=yes'$(evidence)"
  jq -e --arg a "$1" --arg b "$2" \
    'select(.event == "start" and .agent == $a and .bead == $b and .by == "trigger")' \
    "$state/decisions.jsonl" >/dev/null 2>&1 \
    || fail "the view logged no trigger start of $1 on $2$(evidence)"
}

# --- 1. the first producer, on the first ready bead ------------------------------------------------

wait_until 90 "Rogue's session to start" has_session Rogue
wait_until 10 "the view's start line for Rogue" has_start_line Rogue
claimed_at_start Rogue cb-b1
pass "Rogue is started on cb-b1, claimed for Rogue and its tree made before the session began"

# --- 2. the second producer, no sooner than 30 seconds later --------------------------------------

rogue_at="$(epoch "$(start_ts Rogue)")"
wait_until 120 "Gambit's session to start" has_session Gambit
wait_until 10 "the view's start line for Gambit" has_start_line Gambit
claimed_at_start Gambit cb-b2
gambit_at="$(epoch "$(start_ts Gambit)")"
((gambit_at - rogue_at >= 30)) \
  || fail "Gambit was started $((gambit_at - rogue_at))s after Rogue; R13 says at most one every 30s$(evidence)"
jq -se --arg from "$(start_ts Rogue)" --arg to "$(start_ts Gambit)" \
  'any(.[]; .agent == "Gambit" and .spaced_out == true and .spacing == 30 and .ts >= $from and .ts <= $to)' \
  "$state/evaluations.jsonl" >/dev/null 2>&1 \
  || fail "no evaluation between the two starts shows Gambit held by the 30s spacing$(evidence)"
pass "Gambit is started on cb-b2, claimed the same way, $((gambit_at - rogue_at))s after Rogue and held by the spacing in between"

[ "$(session_count)" = 2 ] || fail "expected exactly two sessions, got $(session_count)$(evidence)"

suite_passed
