#!/usr/bin/env bash
#
# Proves `scripts/fleet-history`: the reading side of the transition log ah-hiib.1 writes
# (ah-hiib.2). The log is transitions; every question anyone asks of it is about durations, so
# pairing transitions into intervals is the script's whole job and these assertions are about the
# edges of that pairing - the ones that, got wrong, make a stall disappear rather than merely
# report a wrong number:
#
#   - the LAST interval has no successor, and it is the one that answers "is anything stalled
#     right now"; dropped, the tool built to measure absence cannot see the absence in progress.
#   - a `changed:false` line is a heartbeat, not a transition. Treated as one, a single long
#     interval becomes a run of tiny ones and every stall vanishes.
#   - a null `from` is a fresh session. Carried across, it invents time an agent never spent.
#   - `--since` filters AFTER pairing, so an interval that started before the window keeps its
#     true length instead of being truncated into looking short.
#   - both log generations are read, oldest first: miss `transitions.1.jsonl` and a window
#     reaching past a rotation silently loses its older half.
#   - failure is loud. A caller deciding whether anything stalled must never read a broken query
#     as "all clear".
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/fleet-history.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A fixture tree with its own scripts/ directory symlinked to the real scripts, exactly as
# tests/agent-state.sh builds one, so fleet-history's own root-derivation (via
# `scripts/consumer-root --shared`) resolves inside the fixture rather than against this machine's
# real log - which would make these assertions pass or fail by accident.
new_fixture() {
  local tmp
  tmp="$(consumer_new "$(fixture_name)" --link consumer-root fleet-history)"
  mkdir -p "$tmp/.cerebro/state"
  printf '%s' "$tmp"
}

# The fixture clock. Every fabricated timestamp below is expressed against it, so an assertion
# about an open interval's length is exact rather than racing the wall clock.
now_epoch="1787335200"   # 2026-08-21T18:00:00Z

# Minutes before the fixture clock, as an ISO timestamp.
# `date` cannot format an arbitrary epoch the same way on macOS and on the CI runner (-r against
# -d @), so jq - which everything here needs anyway - does the conversion instead.
ago() {
  jq -rn --argjson e "$((now_epoch - $1 * 60))" '$e | todate'
}

# One log line. Defaults are the common case: a real transition, from `working`.
line() {
  # $1 ts, $2 agent, $3 to, $4 phase, $5 bead, $6 changed, $7 from
  jq -c -n --arg ts "$1" --arg agent "$2" --arg to "$3" --arg phase "${4:-}" \
     --arg bead "${5:-}" --argjson changed "${6:-true}" --arg from "${7-working}" \
     '{ts: $ts, agent: $agent,
       from: (if $from == "" then null else $from end),
       to: $to,
       phase: (if $phase == "" then null else $phase end),
       bead: (if $bead == "" then null else $bead end),
       pid: 111, changed: $changed}'
}

run() {
  # $1 = fixture root, rest = args
  local tmp="$1"
  shift
  FLEET_HISTORY_NOW="$now_epoch" "$tmp/.claude/cerebro/scripts/fleet-history" "$@"
}

# --- two transitions become one interval --------------------------------------------------------
tmp="$(new_fixture)"
{
  line "$(ago 120)" Cyclops working build ah-aaa
  line "$(ago 90)"  Cyclops working review ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[[ "$(jq -r 'length' <<<"$out")" == 2 ]] || fail "two transitions and an open tail are three... two intervals expected, got $(jq -r 'length' <<<"$out")"
first="$(jq -c '.[0]' <<<"$out")"
[[ "$(jq -r '.agent' <<<"$first")" == "Cyclops" ]] || fail "the interval carries its agent"
[[ "$(jq -r '.state' <<<"$first")" == "working" ]] || fail "the interval's state is the state it was IN, not the one it moved to"
[[ "$(jq -r '.phase' <<<"$first")" == "build" ]] || fail "the interval carries the phase it was in"
[[ "$(jq -r '.bead' <<<"$first")" == "ah-aaa" ]] || fail "the interval carries its bead"
[[ "$(jq -r '.minutes' <<<"$first")" == "30" ]] || fail "30 minutes between the two transitions, got $(jq -r '.minutes' <<<"$first")"
[[ "$(jq -r '.open' <<<"$first")" == "false" ]] || fail "a closed interval is not open"
[[ "$(jq -r '.to_ts' <<<"$first")" == "$(ago 90)" ]] || fail "the interval ends where the next transition begins"
rm -rf "$tmp"
pass "two transitions become one interval"

# --- the last interval is open ------------------------------------------------------------------
tmp="$(new_fixture)"
{
  line "$(ago 120)" Cyclops working build ah-aaa
  line "$(ago 90)"  Cyclops working review ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

last="$(run "$tmp" --json | jq -c '.[-1]')"
[[ "$(jq -r '.open' <<<"$last")" == "true" ]] || fail "the last interval of an agent is still running"
[[ "$(jq -r '.to_ts' <<<"$last")" == "null" ]] || fail "an open interval has no end"
[[ "$(jq -r '.minutes' <<<"$last")" == "90" ]] || fail "an open interval is measured to now, got $(jq -r '.minutes' <<<"$last")"
[[ "$(jq -r '.phase' <<<"$last")" == "review" ]] || fail "the open interval carries the phase it is in"
rm -rf "$tmp"
pass "the last interval is open"

# --- a changed-false line does not end an interval ----------------------------------------------
tmp="$(new_fixture)"
{
  line "$(ago 120)" Cyclops working build ah-aaa
  line "$(ago 100)" Cyclops working build ah-aaa false
  line "$(ago 80)"  Cyclops working build ah-aaa false
  line "$(ago 60)"  Cyclops waiting ""    ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
# One interval, not three: the two heartbeats extend it, and the closing `waiting` is terminal.
[[ "$(jq -r 'length' <<<"$out")" == 1 ]] || fail "two heartbeats extend one interval; expected 1 interval, got $(jq -r 'length' <<<"$out")"
[[ "$(jq -r '.[0].minutes' <<<"$out")" == "60" ]] || fail "the interval spans the heartbeats, got $(jq -r '.[0].minutes' <<<"$out")"
rm -rf "$tmp"
pass "a changed-false line does not end an interval"

# --- a null from ends the previous interval -----------------------------------------------------
# A fresh session's first write. The time before it belongs to the session that ended, so the
# previous interval closes here rather than being carried across the restart.
tmp="$(new_fixture)"
{
  line "$(ago 120)" Cyclops working build ah-aaa
  line "$(ago 70)"  Cyclops working build ah-aaa false ""
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[[ "$(jq -r 'length' <<<"$out")" == 2 ]] || fail "a null from starts a new interval even when changed is false, got $(jq -r 'length' <<<"$out")"
[[ "$(jq -r '.[0].minutes' <<<"$out")" == "50" ]] || fail "the previous interval ends at the restart, got $(jq -r '.[0].minutes' <<<"$out")"
rm -rf "$tmp"
pass "a null from ends the previous interval"

# --- an interval starting before the window keeps its true length -------------------------------
tmp="$(new_fixture)"
{
  line "$(ago 600)" Cyclops asking review ah-aaa
  line "$(ago 30)"  Cyclops working review ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json --since 60m)"
[[ "$(jq -r 'length' <<<"$out")" == 2 ]] || fail "an interval overlapping the window is reported, got $(jq -r 'length' <<<"$out")"
[[ "$(jq -r '.[0].minutes' <<<"$out")" == "570" ]] || fail "its true length survives the filter, got $(jq -r '.[0].minutes' <<<"$out")"

# And one wholly before the window is gone.
out="$(run "$tmp" --json --since 20m)"
[[ "$(jq -r 'length' <<<"$out")" == 1 ]] || fail "an interval ending before the window is dropped, got $(jq -r 'length' <<<"$out")"
rm -rf "$tmp"
pass "an interval starting before the window keeps its true length"

# --- a rotated log is read oldest first ---------------------------------------------------------
tmp="$(new_fixture)"
line "$(ago 300)" Cyclops working build ah-aaa > "$tmp/.cerebro/state/transitions.1.jsonl"
line "$(ago 200)" Cyclops working review ah-aaa > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[[ "$(jq -r 'length' <<<"$out")" == 2 ]] || fail "the rotated generation is read too, got $(jq -r 'length' <<<"$out")"
[[ "$(jq -r '.[0].phase' <<<"$out")" == "build" ]] || fail "oldest first: the rotated generation's line comes first"
[[ "$(jq -r '.[0].minutes' <<<"$out")" == "100" ]] || fail "the interval spans the rotation, got $(jq -r '.[0].minutes' <<<"$out")"
rm -rf "$tmp"
pass "a rotated log is read oldest first"

# --- --agent filters to one agent ---------------------------------------------------------------
tmp="$(new_fixture)"
{
  line "$(ago 120)" Cyclops working build ah-aaa
  line "$(ago 110)" Storm   working build ah-bbb
  line "$(ago 90)"  Cyclops working review ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json --agent Storm)"
[[ "$(jq -r 'length' <<<"$out")" == 1 ]] || fail "only Storm's intervals, got $(jq -r 'length' <<<"$out")"
[[ "$(jq -r '.[0].agent' <<<"$out")" == "Storm" ]] || fail "and they are Storm's"
rm -rf "$tmp"
pass "--agent filters to one agent"

# --- --summary counts, totals and takes a median ------------------------------------------------
# Median rather than mean, and this is the assertion that pins it: one long park among short waits
# must not move the typical case, because the typical case is what a threshold gets set from.
tmp="$(new_fixture)"
{
  line "$(ago 500)" Cyclops asking  review ah-aaa
  line "$(ago 490)" Cyclops working review ah-aaa   # asking: 10m
  line "$(ago 480)" Cyclops asking  review ah-aaa
  line "$(ago 460)" Cyclops working review ah-aaa   # asking: 20m
  line "$(ago 450)" Cyclops asking  review ah-aaa
  line "$(ago 150)" Cyclops working review ah-aaa   # asking: 300m
  line "$(ago 140)" Cyclops waiting ""     ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

row="$(run "$tmp" --summary --agent Cyclops | jq -c '.[] | select(.state == "asking")')"
[[ "$(jq -r '.count' <<<"$row")" == "3" ]] || fail "three asking intervals, got $(jq -r '.count' <<<"$row")"
[[ "$(jq -r '.total_min' <<<"$row")" == "330" ]] || fail "totalling 330 minutes, got $(jq -r '.total_min' <<<"$row")"
[[ "$(jq -r '.median_min' <<<"$row")" == "20" ]] || fail "the median is 20, not the mean of 110, got $(jq -r '.median_min' <<<"$row")"
[[ "$(jq -r '.max_min' <<<"$row")" == "300" ]] || fail "the longest was 300, got $(jq -r '.max_min' <<<"$row")"
rm -rf "$tmp"
pass "--summary counts, totals and takes a median"

# --- a summary row carries the open interval ----------------------------------------------------
# The panel asks one question of one call: how long has this agent been where it is, and is that
# long by its own standards? So the row that answers the second carries the first.
tmp="$(new_fixture)"
{
  line "$(ago 400)" Storm working ci ah-bbb
  line "$(ago 390)" Storm asking  ci ah-bbb
  line "$(ago 200)" Storm working ci ah-bbb
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --summary)"
[[ "$(jq -r '.[] | select(.state == "working") | .open_min' <<<"$out")" == "200" ]] || fail "the open interval's length rides on its row, got $(jq -r '.[] | select(.state == "working") | .open_min' <<<"$out")"
[[ "$(jq -r '.[] | select(.state == "asking") | .open_min' <<<"$out")" == "null" ]] || fail "a state with nothing open says so"
rm -rf "$tmp"
pass "a summary row carries the open interval"

# --- a corrupt line exits non-zero with nothing on stdout ---------------------------------------
tmp="$(new_fixture)"
{
  line "$(ago 120)" Cyclops working build ah-aaa
  echo '{this is not json'
} > "$tmp/.cerebro/state/transitions.jsonl"

set +e
err="$(run "$tmp" --json 2>&1 >/dev/null)"
status=$?
out="$(run "$tmp" --json 2>/dev/null)"
set -e
[[ "$status" -ne 0 ]] || fail "a corrupt line must exit non-zero"
[[ -z "$out" ]] || fail "and print nothing on stdout: an empty array that really means 'the query broke' is the worst possible answer"
# The message, not merely the status: without this the assertion passes on any unrelated crash.
grep -q "could not read the transition log" <<<"$err" || fail "and say what is wrong, got: $err"
rm -rf "$tmp"
pass "a corrupt line exits non-zero with nothing on stdout"

# --- a missing log exits non-zero ---------------------------------------------------------------
tmp="$(new_fixture)"
set +e
err="$(run "$tmp" --json 2>&1 >/dev/null)"
status=$?
out="$(run "$tmp" --json 2>/dev/null)"
set -e
[[ "$status" -ne 0 ]] || fail "no log at all must exit non-zero, not read as a quiet fleet"
[[ -z "$out" ]] || fail "and print nothing on stdout"
grep -q "no transition log" <<<"$err" || fail "and say the record is missing, got: $err"
rm -rf "$tmp"
pass "a missing log exits non-zero"

# --- an unknown argument is refused -------------------------------------------------------------
tmp="$(new_fixture)"
line "$(ago 10)" Cyclops working build ah-aaa > "$tmp/.cerebro/state/transitions.jsonl"
set +e
run "$tmp" --nonsense >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "an unknown argument exits 2, as every other script here does"
set +e
run "$tmp" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "a mode is required: --json or --summary"
rm -rf "$tmp"
pass "an unknown argument is refused"

# --- the aggregates describe finished intervals only -------------------------------------------
# The whole point of the summary is to say whether what is happening NOW is unusual. Aggregate the
# open interval into the very median it is about to be compared against and it cannot be: a stall
# raises its own baseline until it clears the bar it set. With one interval it is worse than
# useless - median equals open by construction, so no duration on earth could ever be called long.
tmp="$(new_fixture)"
{
  line "$(ago 700)" Cyclops working review ah-aaa
  line "$(ago 695)" Cyclops asking  review ah-aaa
  line "$(ago 690)" Cyclops working review ah-aaa
  line "$(ago 685)" Cyclops asking  review ah-aaa    # and there it stays: 685m, against a 5m norm
} > "$tmp/.cerebro/state/transitions.jsonl"

row="$(run "$tmp" --summary | jq -c '.[] | select(.state == "asking")')"
[[ "$(jq -r '.count' <<<"$row")" == "1" ]] || fail "one FINISHED asking interval, got $(jq -r '.count' <<<"$row")"
[[ "$(jq -r '.median_min' <<<"$row")" == "5" ]] || fail "the median is of what finished - 5m, not 345m, got $(jq -r '.median_min' <<<"$row")"
[[ "$(jq -r '.max_min' <<<"$row")" == "5" ]] || fail "and so is the longest, got $(jq -r '.max_min' <<<"$row")"
[[ "$(jq -r '.open_min' <<<"$row")" == "685" ]] || fail "the open interval is reported beside them, not inside them"
rm -rf "$tmp"
pass "the aggregates describe finished intervals only"

# --- a state seen only once has no median to judge it by ----------------------------------------
tmp="$(new_fixture)"
line "$(ago 300)" Storm asking review ah-bbb > "$tmp/.cerebro/state/transitions.jsonl"
row="$(run "$tmp" --summary | jq -c '.[0]')"
[[ "$(jq -r '.count' <<<"$row")" == "0" ]] || fail "nothing has finished yet, got count $(jq -r '.count' <<<"$row")"
[[ "$(jq -r '.median_min' <<<"$row")" == "null" ]] || fail "so there is no median - saying otherwise would let the open interval judge itself"
[[ "$(jq -r '.open_min' <<<"$row")" == "300" ]] || fail "and it is still reported as running"
rm -rf "$tmp"
pass "a state seen only once has no median to judge it by"

# --- an agent that finished is not still running ------------------------------------------------
# `waiting` is the end of a pass, not a state an agent sits in: the fleet view ends the session
# half a minute after it is written. Left open, every agent between passes is reported as waiting
# for up to a day, until the staleness bound drops it.
tmp="$(new_fixture)"
{
  line "$(ago 200)" Cyclops working merge ah-aaa
  line "$(ago 190)" Cyclops waiting ""    ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json)"
[[ "$(jq -r 'length' <<<"$out")" == "1" ]] || fail "the finished session leaves one interval, not two, got $(jq -r 'length' <<<"$out")"
[[ "$(jq -r '.[0].state' <<<"$out")" == "working" ]] || fail "and it is the work, not the ending"
[[ "$(jq -r '[.[] | select(.open)] | length' <<<"$out")" == "0" ]] || fail "nothing of a finished session is still running"
rm -rf "$tmp"
pass "an agent that finished is not still running"

# --- an abandoned interval is a dead session, not a stall ---------------------------------------
# Silence is not evidence of death - an agent writes only when something changes, and a three-hour
# build is exactly the stretch this exists to measure, so a long open interval must survive. But
# nothing sits in one state for a day, and a session killed at the terminal leaves an interval
# nobody will ever close: unbounded, one run a year ago is reported for ever as running and the
# panel fills with the dead.
tmp="$(new_fixture)"
{
  line "$(ago 20000)" Beast   idle    ""     ""
  line "$(ago 200)"   Cyclops working build  ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json --since 30d)"
[[ "$(jq -r '[.[] | select(.agent == "Beast")] | length' <<<"$out")" == "0" ]] || fail "an agent open for a fortnight is a dead session, got $(jq -c '.' <<<"$out")"
[[ "$(jq -r '[.[] | select(.agent == "Cyclops")] | length' <<<"$out")" == "1" ]] || fail "and a genuinely long stretch is NOT dropped - it is the stall this tool is for"
[[ "$(jq -r '.[0].minutes' <<<"$out")" == "200" ]] || fail "with its full length"
rm -rf "$tmp"
pass "an abandoned interval is a dead session, not a stall"

# --- --since takes an ISO timestamp as well as a span -------------------------------------------
tmp="$(new_fixture)"
{
  line "$(ago 600)" Cyclops working build ah-aaa
  line "$(ago 30)"  Cyclops working ci    ah-aaa
} > "$tmp/.cerebro/state/transitions.jsonl"

out="$(run "$tmp" --json --since "$(ago 45)")"
[[ "$(jq -r 'length' <<<"$out")" == "2" ]] || fail "an ISO --since is understood, got $(jq -r 'length' <<<"$out")"
set +e
err="$(run "$tmp" --json --since "next tuesday" 2>&1 >/dev/null)"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "and something that is neither is refused"
grep -q "ISO-8601" <<<"$err" || fail "naming what it wanted, got: $err"
rm -rf "$tmp"
pass "--since takes an ISO timestamp as well as a span"

# --- a flag swallowing the next flag is refused -------------------------------------------------
tmp="$(new_fixture)"
line "$(ago 10)" Cyclops working build ah-aaa > "$tmp/.cerebro/state/transitions.jsonl"
set +e
run "$tmp" --agent --json >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "--agent --json is a typo, not an agent called '--json'"
rm -rf "$tmp"
pass "a flag swallowing the next flag is refused"

echo "all fleet-history assertions passed"
