#!/usr/bin/env bash
#
# Proves `scripts/fleet-health`: the four-section report over the fleet's own decision and
# transition logs (cb-xhu.4.1). Nothing here is about pretty output for its own sake - each
# assertion guards a way of reading the logs that is silently WRONG rather than merely ugly:
#
#   - every generation of the decision log is read, oldest first; miss one and a name that has
#     been restarting all afternoon reads as quiet.
#   - the window is applied to `ts`, so a start older than `--since` is not counted.
#   - a session is bounded by a NULL `from`, never by its pid: pids are recycled, so two sessions
#     of one name can share a number and would be folded into one pass.
#   - `waiting` is what makes a pass complete. A session that has not reached it is still running
#     and is counted nowhere.
#   - a role that never carries a bead has every pass look like a no-op; it is reported and never
#     counted, or the report is all false positives.
#   - failure is LOUD - non-zero, nothing on stdout. A navigator deciding whether anything is
#     stuck must never read a broken query as "all clear".
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion.
#
#     bash tests/fleet-health.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# Every fixture is built under $work_dir and nowhere else: the suites run in parallel, one per
# processor, and a fixture reaching for a shared path breaks the whole gate rather than one suite.
# It is also what keeps this suite away from the machine's live .cerebro/state logs, which is a
# quarter of what cb-xhu was filed about.
new_fixture() {
  local tmp
  tmp="$(consumer_new "$(fixture_name)" --link consumer-root roster fleet-history fleet-health)"
  mkdir -p "$tmp/.cerebro/state"
  # fleet-history refuses when there is no transition log at all, and this script passes that
  # refusal straight through (increment 8 asserts it). An empty file is a fixture with no
  # transitions rather than a machine that has never run.
  : > "$tmp/.cerebro/state/transitions.jsonl"
  printf '%s' "$tmp"
}

# The fixture clock. Every fabricated timestamp is expressed against it, so an assertion about an
# open interval's length is exact rather than racing the wall clock.
now_epoch="1787335200"   # 2026-08-21T18:00:00Z

# Minutes before the fixture clock, as an ISO timestamp. `date` cannot format an arbitrary epoch
# the same way on macOS and on the CI runner (-r against -d @), so jq does the conversion.
ago() {
  jq -rn --argjson e "$((now_epoch - $1 * 60))" '$e | todate'
}

# One decision-log line: $1 ts, $2 event, $3 agent (empty for null), $4 extra JSON fields.
dec() {
  jq -c -n --arg ts "$1" --arg event "$2" --arg agent "$3" --argjson extra "${4:-{\}}" \
     '{event: $event, ts: $ts, agent: (if $agent == "" then null else $agent end)} + $extra'
}

# One transition-log line: $1 ts, $2 agent, $3 to, $4 phase, $5 bead, $6 pid, $7 from.
tline() {
  jq -c -n --arg ts "$1" --arg agent "$2" --arg to "$3" --arg phase "${4:-}" \
     --arg bead "${5:-}" --argjson pid "${6:-111}" --arg from "${7-working}" \
     '{ts: $ts, agent: $agent,
       from: (if $from == "" then null else $from end),
       to: $to,
       phase: (if $phase == "" then null else $phase end),
       bead: (if $bead == "" then null else $bead end),
       pid: $pid, changed: true}'
}

roster_conf() {
  # $1 fixture, rest "Name role" pairs
  local tmp="$1"; shift
  : > "$tmp/.cerebro/roster.conf"
  local pair
  for pair in "$@"; do
    printf '%s\t%s\n' "${pair%% *}" "${pair##* }" >> "$tmp/.cerebro/roster.conf"
  done
}

run() {
  local tmp="$1"; shift
  FLEET_HEALTH_NOW="$now_epoch" "$tmp/.claude/cerebro/scripts/fleet-health" "$@"
}

# --- starts are counted across every decision generation, inside the window ----------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
printf '%s\n' "$(dec "$(ago 200)" start Cyclops)" > "$tmp/.cerebro/state/decisions.2.jsonl"
printf '%s\n' "$(dec "$(ago 50)" start Cyclops)"  > "$tmp/.cerebro/state/decisions.1.jsonl"
{
  dec "$(ago 30)" start Cyclops
  dec "$(ago 10)" start Cyclops
} > "$tmp/.cerebro/state/decisions.jsonl"

out="$(run "$tmp" --since 1h --json)"
[ "$(jq -c '.starts' <<<"$out")" = '[{"agent":"Cyclops","count":3,"over":false}]' ] \
  || fail "starts across generations: got $(jq -c '.starts' <<<"$out")"
for key in since until start_ceiling long_minutes starts passes running disarmed; do
  [ "$(jq "has(\"$key\")" <<<"$out")" = true ] || fail "--json is missing the key $key"
done
pass "starts are counted across every decision generation, inside the window"

# --- over the ceiling ---------------------------------------------------------------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer" "Storm implementer"
{
  dec "$(ago 30)" start Cyclops; dec "$(ago 20)" start Cyclops; dec "$(ago 10)" start Cyclops
  dec "$(ago 30)" start Storm;   dec "$(ago 20)" start Storm
} > "$tmp/.cerebro/state/decisions.jsonl"

out="$(FLEET_HEALTH_START_CEILING=2 run "$tmp" --json)"
[ "$(jq -r '.starts[] | select(.agent == "Cyclops") | .over' <<<"$out")" = true ] \
  || fail "three starts against a ceiling of two is not over"
[ "$(jq -r '.starts[] | select(.agent == "Storm") | .over' <<<"$out")" = false ] \
  || fail "two starts against a ceiling of two is over - the ceiling must be strictly greater"
[ "$(jq -r '.start_ceiling' <<<"$out")" = 2 ] || fail "start_ceiling is not echoed"
pass "a name past the start ceiling is flagged, one exactly at it is not"

# --- passes that held no bead -------------------------------------------------------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 60)" Cyclops working build "" 111 ""
  tline "$(ago 50)" Cyclops waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -c '.passes' <<<"$out")" = '[{"agent":"Cyclops","noop":1,"total":1,"holds_beads":true}]' ] \
  || fail "no-op pass: got $(jq -c '.passes' <<<"$out")"
pass "a session that ended waiting with no bead is a no-op pass"

# Two sessions of one agent sharing a pid - pids are recycled, so the boundary is a null `from`.
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 90)" Cyclops working build cb-aaa 111 ""
  tline "$(ago 80)" Cyclops waiting "" "" 111 working
  tline "$(ago 60)" Cyclops working build "" 111 ""
  tline "$(ago 50)" Cyclops waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -r '.passes[0].total' <<<"$out")" = 2 ] || fail "two sessions sharing a pid were folded into one"
[ "$(jq -r '.passes[0].noop' <<<"$out")" = 1 ] || fail "the bead-holding session was counted as a no-op"
pass "a session is bounded by a null from, not by its pid"

tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 60)" Cyclops working build "" 111 ""
  tline "$(ago 50)" Cyclops working review "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -c '.passes' <<<"$out")" = '[]' ] || fail "a session still running was counted as a pass"
pass "a session that has not reached waiting is counted nowhere"

# A pass whose first line is older than the window belongs to neither half of it.
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 200)" Cyclops working build "" 111 ""
  tline "$(ago 20)"  Cyclops waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --since 1h --json)"
[ "$(jq -c '.passes' <<<"$out")" = '[]' ] || fail "a pass that began before the window was counted"
pass "a pass is attributed to the window by its first line"

tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 90)" Cyclops working build "" 111 ""
  tline "$(ago 80)" Cyclops waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.1.jsonl"
{
  tline "$(ago 60)" Cyclops working build "" 111 ""
  tline "$(ago 50)" Cyclops waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -r '.passes[0].total' <<<"$out")" = 2 ] || fail "the rotated transition generation was not read"
pass "both transition generations are read"

# A log rotated mid-session leaves a tail whose first line is not a session start. Counted as a
# whole pass it is a false positive in the one section meant to name agents doing nothing.
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 60)" Cyclops working review "" 111 build
  tline "$(ago 50)" Cyclops waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -c '.passes' <<<"$out")" = '[]' ] \
  || fail "a rotated-away session head was counted as a whole pass: $(jq -c '.passes' <<<"$out")"
pass "a session whose opening line has rotated away is counted nowhere"

# --- holds_beads comes from the roster ----------------------------------------------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Cerebro orchestrator"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 60)" Cerebro working sweep "" 111 ""
  tline "$(ago 50)" Cerebro waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -r '.passes[0].holds_beads' <<<"$out")" = false ] || fail "an orchestrator was counted as holding beads"
[ "$(jq -r '.passes[0].noop' <<<"$out")" = 1 ] || fail "the pass itself is still reported"
printf '%s\n' "$(run "$tmp")" | grep -q 'not counted (these roles hold no bead): Cerebro' \
  || fail "the report does not name the roles it did not count"
pass "a role that never holds a bead is reported and never counted"

tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 60)" Nightcrawler working build "" 111 ""
  tline "$(ago 50)" Nightcrawler waiting "" "" 111 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -r '.passes[0].holds_beads' <<<"$out")" = true ] \
  || fail "an agent missing from the roster was silently dropped rather than reported"
pass "an agent missing from the roster is reported as holding beads"

# --- running now --------------------------------------------------------------------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer" "Psylocke verifier"
: > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 120)" Psylocke asking verify cb-5kk 111 ""
  tline "$(ago 30)"  Cyclops working "" "" 222 ""
  tline "$(ago 90)"  Storm working build cb-zzz 333 ""
  tline "$(ago 85)"  Storm waiting "" "" 333 working
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(FLEET_HEALTH_LONG_MINUTES=60 run "$tmp" --json)"
[ "$(jq -r '[.running[].agent] | join(",")' <<<"$out")" = "Psylocke,Cyclops" ] \
  || fail "running now is not the open intervals, longest first: $(jq -c '.running' <<<"$out")"
[ "$(jq -r '.running[0].long' <<<"$out")" = true ]  || fail "a 120m interval is not long"
[ "$(jq -r '.running[1].long' <<<"$out")" = false ] || fail "a 30m interval is long"
[ "$(jq -r '.running[1].phase' <<<"$out")" = null ] || fail "a missing phase did not come through null"
[ "$(jq -r '.running[1].bead' <<<"$out")" = null ]  || fail "a missing bead did not come through null"
pass "running now is fleet-history's open intervals, longest first"

# --- disarmed or given up on --------------------------------------------------------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Xavier planner"
{
  dec "$(ago 30)" give-up Xavier '{"role":"planner","failed_starts":5}'
  dec "$(ago 20)" retire Xavier  '{"role":"planner","state":"waiting","bead":null,"stop_flag":"set"}'
  dec "$(ago 10)" disarm-all ""  '{"mode":"kill","reason":"navigator asked","agents":["Xavier","Beast"]}'
} > "$tmp/.cerebro/state/decisions.jsonl"

out="$(run "$tmp" --json)"
[ "$(jq -r '[.disarmed[].event] | join(",")' <<<"$out")" = "give-up,retire,disarm-all" ] \
  || fail "disarmed events are not ascending by ts"
[ "$(jq -r '.disarmed[0].detail' <<<"$out")" = "5 starts produced no pass" ] || fail "give-up detail"
[ "$(jq -r '.disarmed[1].detail' <<<"$out")" = "retired from waiting, stop flag set" ] || fail "retire detail"
[ "$(jq -r '.disarmed[2].detail' <<<"$out")" = "2 names disarmed: navigator asked" ] || fail "disarm-all detail"
[ "$(jq -r '.disarmed[2].agent' <<<"$out")" = null ] || fail "disarm-all names an agent"
pass "give-up, retire and disarm-all each render their own detail"

tmp="$(new_fixture)"
roster_conf "$tmp" "Xavier planner"
dec "$(ago 30)" give-up Xavier '{"role":"planner"}' > "$tmp/.cerebro/state/decisions.jsonl"
out="$(run "$tmp" --json)"
[ "$(jq -r '.disarmed[0].detail' <<<"$out")" = "? starts produced no pass" ] \
  || fail "a missing field did not render as ?: $(jq -r '.disarmed[0].detail' <<<"$out")"
pass "a missing field renders as ? rather than as nothing"

# --- the report ---------------------------------------------------------------------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer" "Storm implementer" "Cerebro orchestrator"
{
  dec "$(ago 30)" start Cyclops; dec "$(ago 25)" start Cyclops; dec "$(ago 20)" start Cyclops
  dec "$(ago 15)" start Storm
  dec "$(ago 10)" retire Storm '{"role":"implementer","state":"waiting","stop_flag":"set"}'
} > "$tmp/.cerebro/state/decisions.jsonl"
{
  tline "$(ago 40)" Storm working build "" 111 ""
  tline "$(ago 35)" Storm waiting "" "" 111 working
  tline "$(ago 30)" Cerebro working sweep "" 222 ""
  tline "$(ago 28)" Cerebro waiting "" "" 222 working
  tline "$(ago 90)" Cyclops working build cb-aaa 333 ""
} > "$tmp/.cerebro/state/transitions.jsonl"

expected="$(cat <<'REPORT'
Fleet health — last 2h (2026-08-21T16:00:00Z → 2026-08-21T18:00:00Z)

Starts per name            ceiling 2
  Cyclops    3         Storm      1

Passes that held no bead
  Storm      1 of 1
  not counted (these roles hold no bead): Cerebro

Running now                long > 60m
  Cyclops    working/build     90m  cb-aaa

Disarmed or given up on
  2026-08-21T17:50:00Z  Storm      retired from waiting, stop flag set

1 name over the start ceiling, 1 running past 60m.
REPORT
)"
got="$(FLEET_HEALTH_START_CEILING=2 FLEET_HEALTH_LONG_MINUTES=60 run "$tmp" --since 2h)"
[ "$got" = "$expected" ] || fail "the report is not the agreed text:
--- got ---
$got
--- want ---
$expected"
pass "the report is the agreed text, section for section"

tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
dec "$(ago 30)" start Cyclops > "$tmp/.cerebro/state/decisions.jsonl"
got="$(run "$tmp")"
[ "$(grep -c 'nothing in the window' <<<"$got")" = 3 ] \
  || fail "an empty section is omitted rather than saying nothing in the window"
pass "an empty section says nothing in the window"

[ "$(tail -1 <<<"$got")" = "Nothing over a threshold in the window." ] \
  || fail "the last line names a threshold nothing crossed: $(tail -1 <<<"$got")"
got="$(FLEET_HEALTH_START_CEILING=0 run "$tmp")"
[ "$(tail -1 <<<"$got")" = "1 name over the start ceiling." ] \
  || fail "one name over the ceiling is not singular: $(tail -1 <<<"$got")"
pass "the last line names only the thresholds that were crossed"

# --- loud failure -------------------------------------------------------------------------------
tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
if out="$(run "$tmp" 2>/dev/null)"; then fail "a missing decision log exited 0"; fi
[ -z "$out" ] || fail "a missing decision log printed to stdout"
pass "a missing decision log is a non-zero exit with nothing on stdout"

tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
printf 'not json at all\n' > "$tmp/.cerebro/state/decisions.jsonl"
if out="$(run "$tmp" 2>/dev/null)"; then fail "an unparsable log line exited 0"; fi
[ -z "$out" ] || fail "an unparsable log line printed to stdout"
pass "an unparsable log line is a non-zero exit with nothing on stdout"

tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
dec "$(ago 30)" start Cyclops > "$tmp/.cerebro/state/decisions.jsonl"
rm "$tmp/.cerebro/state/transitions.jsonl"
if out="$(run "$tmp" 2>/dev/null)"; then fail "a failing fleet-history exited 0"; fi
[ -z "$out" ] || fail "a failing fleet-history printed to stdout"
pass "a failing fleet-history is a non-zero exit with nothing on stdout"

tmp="$(new_fixture)"
roster_conf "$tmp" "Cyclops implementer"
dec "$(ago 30)" start Cyclops > "$tmp/.cerebro/state/decisions.jsonl"
set +e
out="$(run "$tmp" --nonsense 2>"$work_dir/err1")"; status1=$?
out2="$(run "$tmp" --since 2026-08-20T00:00:00Z 2>"$work_dir/err2")"; status2=$?
set -e
[ "$status1" = 2 ] || fail "an unknown argument did not exit 2"
[ "$status2" = 2 ] || fail "an ISO --since did not exit 2"
[ -z "$out$out2" ] || fail "a usage error printed to stdout"
grep -q 'fleet-history' "$work_dir/err2" || fail "an ISO --since does not name fleet-history"
pass "an unknown argument and an ISO --since are usage errors"

suite_passed
