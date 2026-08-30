#!/usr/bin/env bash
#
# Proves `scripts/fleet-cost`: the join between what a Copilot session cost and which bead the
# agent held while it spent it (cb-d89). Neither half is captured while a session runs - the
# session store and the transition log both outlive it - so every assertion here is about the
# join itself, and about the three places it can silently lie:
#
#   - SPEND THAT REACHES NO BEAD IS STILL SPEND. An interval with a null bead, and an event
#     inside no interval at all, both land in the `no bead` bucket. Dropped, a third of the
#     fleet's spend vanishes and the rows no longer add up to what was paid.
#   - A SESSION IN ANOTHER ROOT IS NOT THIS FLEET'S. The store holds every Copilot session on
#     the machine, including the probe fixtures under `.cerebro/worktrees/*/probe`. The root in
#     the marker is what separates them, and it carries a trailing slash the consumer root does
#     not - the cb-os4 lesson in a new place.
#   - NOT ALL SPEND IS PRICED. A null `total_nano_aiu` summed as zero makes a real request free,
#     and on cb-ue0 that was the whole of one planner's contribution.
#
# The suite builds its own SQLite store and its own transition log under `$work_dir`, so every
# number below is exact rather than whatever this machine happens to have spent. `sqlite3` is a
# real dependency of both the script and this suite.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion.
#
#     bash tests/fleet-cost.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

command -v sqlite3 >/dev/null 2>&1 \
  || fail "sqlite3 is not on PATH - it is what reads the session store, and this suite fabricates one"

# The fixture clock. Every fabricated timestamp is expressed against it, so an assertion is exact
# rather than racing the wall clock; fleet-history reads the same variable.
now_epoch="1787335200"   # 2026-08-21T18:00:00Z

# Minutes before the fixture clock, as an ISO timestamp. `date` cannot format an arbitrary epoch
# the same way on macOS and on the CI runner, so jq does the conversion.
ago() {
  jq -rn --argjson e "$((now_epoch - $1 * 60))" '$e | todate'
}

# Milliseconds on the end, because that is the shape the store writes and the reader must cope
# with it rather than with a tidied one.
ago_ms() {
  printf '%s.000Z' "$(ago "$1" | sed 's/Z$//')"
}

new_fixture() {
  local tmp
  tmp="$(consumer_new "$(fixture_name)" \
           --link consumer-root fleet-history fleet-cost project-conf agent-cli)"
  mkdir -p "$tmp/.cerebro/state"
  printf 'agent_cli copilot\n' > "$tmp/.cerebro/project.conf"
  printf '%s' "$tmp"
}

# The root as the script itself resolves it - mktemp under /var on macOS is a symlink to
# /private/var, and a marker built from the unresolved spelling would match nothing.
root_of() {
  "$1/.claude/cerebro/scripts/consumer-root" --shared
}

make_store() {
  sqlite3 "$1" '
    CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, created_at TEXT);
    CREATE TABLE turns (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT,
                        turn_index INTEGER, user_message TEXT, timestamp TEXT);
    CREATE TABLE assistant_usage_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT,
                        turn_index INTEGER, model TEXT, total_nano_aiu INTEGER, created_at TEXT);
  '
}

# A session whose turn 0 carries cerebro's marker sentence. $4 is the marker's root EXACTLY as
# `scripts/launch` writes it - with the trailing slash - unless a caller is testing otherwise.
session() {
  # $1 db, $2 session id, $3 agent, $4 marker root
  sqlite3 "$1" "
    INSERT INTO sessions(id) VALUES('$2');
    INSERT INTO turns(session_id, turn_index, user_message)
      VALUES('$2', 0, 'This session is $3 of the cerebro fleet rooted at $4.');
  "
}

event() {
  # $1 db, $2 session id, $3 created_at, $4 total_nano_aiu or NULL, $5 model (optional)
  sqlite3 "$1" "
    INSERT INTO assistant_usage_events(session_id, model, total_nano_aiu, created_at)
      VALUES('$2', '${5:-gpt-5}', $4, '$3');
  "
}

# One transition-log line, the same shape tests/fleet-history.sh fabricates.
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
  FLEET_HISTORY_NOW="$now_epoch" FLEET_COST_STORE="$tmp/store.db" \
    FLEET_COST_COLUMNS=100 PATH="$PATH" \
    "$tmp/.claude/cerebro/scripts/fleet-cost" "$@"
}

# AIC for one bead, out of a --json answer. `no bead` is the row whose bead is null.
aic_of() {
  jq -r --arg b "$1" 'map(select((.bead // "null") == $b))
                      | if length == 0 then "missing" else .[0].aic end'
}

# --- the base fixture ---------------------------------------------------------------------------
#
# Cyclops holds cb-aaa for half an hour, then holds nothing for half an hour, then ends its pass.
# Three priced events: one inside the bead's interval, one inside the null-bead interval, one
# after the pass ended and so inside no interval at all.

base="$(new_fixture)"
base_root="$(root_of "$base")"
make_store "$base/store.db"
session "$base/store.db" s1 Cyclops "$base_root/"
event "$base/store.db" s1 "$(ago_ms 110)" 1000000000
event "$base/store.db" s1 "$(ago_ms 80)"  2000000000
event "$base/store.db" s1 "$(ago_ms 30)"  4000000000
{
  line "$(ago 120)" Cyclops working build cb-aaa
  line "$(ago 90)"  Cyclops working build ""
  line "$(ago 60)"  Cyclops waiting "" ""
} > "$base/.cerebro/state/transitions.jsonl"

out="$(run "$base" --by-bead --json)"

[[ "$(aic_of cb-aaa <<<"$out")" == "1" ]] \
  || fail "an event inside an interval carrying a bead is attributed to it, got $(aic_of cb-aaa <<<"$out")"
pass "an event inside an interval carrying a bead is attributed to that bead"

[[ "$(aic_of null <<<"$out")" == "6" ]] \
  || fail "the null-bead interval (2.0) and the event outside every interval (4.0) both land in \`no bead'; got $(aic_of null <<<"$out")"
pass "spend with no bead - a null-bead interval, and an event in no interval at all - lands in \`no bead'"

total="$(jq -r '[.[].aic] | add' <<<"$out")"
[[ "$total" == "7" ]] \
  || fail "the rows must add to everything that was spent (7.0), got $total"
pass "the rows sum to the total - nothing is dropped between the store and the table"

# --- a session in another root is not this fleet's -----------------------------------------------

session "$base/store.db" s2 Cyclops "$base_root/.cerebro/worktrees/cb-xxx/probe/"
event "$base/store.db" s2 "$(ago_ms 110)" 900000000000

out="$(run "$base" --by-bead --json)"
[[ "$(jq -r '[.[].aic] | add' <<<"$out")" == "7" ]] \
  || fail "a probe session under another root must be excluded; total went to $(jq -r '[.[].aic] | add' <<<"$out")"
pass "a marker naming a different root - the probe fixtures - is excluded from the join"

# The marker root above carried a trailing slash and the consumer root does not: the base
# assertions all passed through that normalisation, so state it as its own line.
pass "a marker root with a trailing slash matches a consumer root without one"

# --- the marker is the first sentence of a prompt, not the whole of it -----------------------------
#
# Every real marker is followed by the rest of the seed prompt in the same field. A capture
# anchored at the end of the message swallows all of it and matches no root, which reads as a
# fleet that has never run - which is exactly what the first real run of this script did.

real="$(new_fixture)"
real_root="$(root_of "$real")"
make_store "$real/store.db"
sqlite3 "$real/store.db" "
  INSERT INTO sessions(id) VALUES('s1');
  INSERT INTO turns(session_id, turn_index, user_message)
    VALUES('s1', 0, 'This session is Cyclops of the cerebro fleet rooted at $real_root/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.

You are Cyclops. Your agent definition (implementer) is the whole of your instructions.');
"
event "$real/store.db" s1 "$(ago_ms 110)" 3000000000
{
  line "$(ago 120)" Cyclops working build cb-aaa
  line "$(ago 60)"  Cyclops waiting "" ""
} > "$real/.cerebro/state/transitions.jsonl"

[[ "$(run "$real" --by-bead --json | aic_of cb-aaa)" == "3" ]] \
  || fail "a marker followed by the rest of the prompt must still yield its agent and its root"
pass "the marker is read as the first sentence of a prompt, not as the whole message"

# --- a store bigger than one argument -------------------------------------------------------------
#
# The store's rows once reached jq as an argv value, and on this fleet they crossed ARG_MAX: every
# mode refused with `jq: Argument list too long`, and no window helped, because the window is
# applied inside jq rather than in the SELECT. The suite could not see it - everything it
# fabricates is three orders of magnitude below the limit - so the fixture here deliberately
# exceeds the real limit of whichever machine is running it.
#
# The padding is built inside SQLite: a shell-built pad big enough to matter would make the
# fixture's own `sqlite3 "$db" "<statement>"` hit the very limit under test.

big="$(new_fixture)"
big_root="$(root_of "$big")"
make_store "$big/store.db"

big_events=12
big_arg_max="$(getconf ARG_MAX)"
big_pad=$(( big_arg_max / big_events ))   # hex(zeroblob(n)) is 2n chars, so 12 rows ~ 2x ARG_MAX
sqlite3 "$big/store.db" "
  INSERT INTO sessions(id) VALUES('s1');
  INSERT INTO turns(session_id, turn_index, user_message)
    VALUES('s1', 0, 'This session is Cyclops of the cerebro fleet rooted at $big_root/. '
                    || replace(hex(zeroblob($big_pad)), '0', 'x'));
"
for _ in $(seq "$big_events"); do
  event "$big/store.db" s1 "$(ago_ms 110)" 1000000000
done
{
  line "$(ago 120)" Cyclops working build cb-aaa
  line "$(ago 60)"  Cyclops waiting "" ""
} > "$big/.cerebro/state/transitions.jsonl"

big_out="$(run "$big" --by-bead --json)" \
  || fail "a session store larger than one argument must be answered, not refused"
[[ "$(aic_of cb-aaa <<<"$big_out")" == "12" ]] \
  || fail "a store larger than one argument must report its 12.0 AIC, got $(aic_of cb-aaa <<<"$big_out")"
pass "a session store larger than one argument is answered rather than refused"

# The temporary file the rows are read into must not outlive the run. TMPDIR is the suite's own
# empty directory, so this is exact rather than a scan of the machine's /tmp. Asserted on the
# answer path only - the four documented refusals all return before the file is created - but the
# trap covers every exit either way.
big_tmp="$work_dir/fleet-cost-tmp"
mkdir -p "$big_tmp"
TMPDIR="$big_tmp" run "$big" --by-bead --json >/dev/null
[[ -z "$(ls -A "$big_tmp")" ]] \
  || fail "the temporary file holding the store's rows must not outlive the run; TMPDIR still holds $(ls -A "$big_tmp")"
pass "the temporary file holding the store's rows does not outlive the run"

# --- unpriced requests ---------------------------------------------------------------------------

unp="$(new_fixture)"
unp_root="$(root_of "$unp")"
make_store "$unp/store.db"
session "$unp/store.db" s1 Cyclops "$unp_root/"
event "$unp/store.db" s1 "$(ago_ms 110)" 1000000000
event "$unp/store.db" s1 "$(ago_ms 105)" NULL gpt-5.3-codex
{
  line "$(ago 120)" Cyclops working build cb-aaa
  line "$(ago 60)"  Cyclops waiting "" ""
} > "$unp/.cerebro/state/transitions.jsonl"

out="$(run "$unp" --by-bead --json)"
row="$(jq -c '.[0]' <<<"$out")"
[[ "$(jq -r '.aic' <<<"$row")" == "1" ]] \
  || fail "an unpriced request must not be summed as zero-and-counted; aic is $(jq -r '.aic' <<<"$row")"
[[ "$(jq -r '.unpriced' <<<"$row")" == "1" ]] \
  || fail "an unpriced request is counted in UNPRICED, got $(jq -r '.unpriced' <<<"$row")"
pass "a null total_nano_aiu is counted in UNPRICED and never summed as zero"

table="$(run "$unp" --by-bead)"
grep -q 'record no cost' <<<"$table" \
  || fail "the table's footer must say how many requests recorded no cost; got: $table"
pass "the footer states the unpriced requests rather than leaving them invisible"

# --- two sessions under one name -----------------------------------------------------------------

dup="$(new_fixture)"
dup_root="$(root_of "$dup")"
make_store "$dup/store.db"
session "$dup/store.db" s1 Storm "$dup_root/"
session "$dup/store.db" s2 Storm "$dup_root/"
event "$dup/store.db" s1 "$(ago_ms 110)" 1000000000
event "$dup/store.db" s1 "$(ago_ms 70)"  1000000000
event "$dup/store.db" s2 "$(ago_ms 100)" 1000000000
{
  line "$(ago 120)" Storm working build cb-aaa
  line "$(ago 60)"  Storm waiting "" ""
} > "$dup/.cerebro/state/transitions.jsonl"

out="$(run "$dup" --by-agent --json)"
[[ "$(jq -r '.[0].merged_sessions' <<<"$out")" == "true" ]] \
  || fail "two sessions of one name overlapping in time must be reported as merged, got: $out"
grep -q 'sessions overlapped' <<<"$(run "$dup" --by-agent)" \
  || fail "the by-agent table says on the row that two sessions were merged"
pass "two sessions of one name overlapping in time are reported as merged, not silently attributed"

# --- the horizon line ------------------------------------------------------------------------------

# A window that starts exactly where the record does is inside it: nothing has been lost, so
# there is nothing to say. The same fixture answered for 30d has lost nothing either - it simply
# asked for more than exists - and the two answers must be the same bytes.
inside="$(run "$base" --by-bead --since "$(ago 110)" 2>"$work_dir/err-inside")"
[[ -s "$work_dir/err-inside" ]] \
  && fail "a window inside the record says nothing on stderr, got: $(cat "$work_dir/err-inside")"
pass "a window inside the record prints no horizon line"

outside="$(run "$base" --by-bead --since 30d 2>"$work_dir/err-outside")"
grep -q 'so this answers for' "$work_dir/err-outside" \
  || fail "a window wider than the record says so on stderr, got: $(cat "$work_dir/err-outside")"
[[ "$inside" == "$outside" ]] \
  || fail "the horizon line belongs on stderr; stdout must be byte-identical either way"
pass "the horizon line appears on stderr only when the window predates the record, and stdout is unchanged"

# --- the table and the JSON are the same answer ----------------------------------------------------

table="$(run "$base" --by-bead)"
grep -qE '^cb-aaa 1\.0 ' <<<"$(sed 's/  */ /g' <<<"$table")" \
  || fail "the table must print the same 1.0 the JSON does; got: $table"
grep -qE '^no bead 6\.0 ' <<<"$(sed 's/  */ /g' <<<"$table")" \
  || fail "the table must print the same 6.0 for \`no bead'; got: $table"
pass "--json and the table report the same numbers"

# --- ordering, and the rule -------------------------------------------------------------------------

ord="$(new_fixture)"
ord_root="$(root_of "$ord")"
make_store "$ord/store.db"
session "$ord/store.db" s1 Cyclops "$ord_root/"
event "$ord/store.db" s1 "$(ago_ms 110)" 1000000000     # cb-aaa, the cheaper bead
event "$ord/store.db" s1 "$(ago_ms 80)"  5000000000     # cb-bbb, the dearer one
event "$ord/store.db" s1 "$(ago_ms 50)"  9000000000     # no bead, dearer than either
{
  line "$(ago 120)" Cyclops working build cb-aaa
  line "$(ago 90)"  Cyclops working build cb-bbb
  line "$(ago 60)"  Cyclops working build ""
  line "$(ago 40)"  Cyclops waiting "" ""
} > "$ord/.cerebro/state/transitions.jsonl"

table="$(run "$ord" --by-bead)"
beads="$(grep -oE '^cb-[a-z]+' <<<"$table" | tr '\n' ' ')"
[[ "$beads" == "cb-bbb cb-aaa " ]] \
  || fail "rows are most-expensive-first, got: $beads"
rule_line="$(grep -n '^--$' <<<"$table" | cut -d: -f1)"
nobead_line="$(grep -n '^no bead' <<<"$table" | cut -d: -f1)"
[[ -n "$rule_line" && "$nobead_line" -gt "$rule_line" ]] \
  || fail "\`no bead' sits below a -- rule rather than being sorted among the beads; got: $table"
pass "rows are most-expensive-first and \`no bead' sits below the rule, never sorted in"

# --- one bead, and where its cost went ---------------------------------------------------------------

one="$(run "$ord" --bead cb-bbb)"
grep -q '^cb-bbb — 5.0 AIC over 1 request' <<<"$one" \
  || fail "--bead <id> opens with the bead, its AIC and its request count; got: $one"
grep -qE '^Cyclops +build +5\.0 ' <<<"$one" \
  || fail "--bead <id> breaks the bead down by agent and phase; got: $one"
pass "--bead <id> reports one bead, broken down by agent and phase"

# An agent whose every request on a bead was unpriced spent real credits and shows 0.0 AIC. That
# is the measured cb-ue0 case, where the bead read as though planning had cost nothing, so the
# breakdown carries the count rather than leaving the row looking free.
one="$(run "$unp" --bead cb-aaa)"
grep -qE '^Cyclops +build +1\.0 +1$' <<<"$one" \
  || fail "--bead <id> carries the unpriced count beside the AIC; got: $one"
grep -q 'record no cost' <<<"$one" \
  || fail "--bead <id> says in its footer how many requests recorded no cost; got: $one"
pass "--bead <id> shows unpriced requests rather than letting a row read as free"

missing="$(run "$ord" --bead cb-zzz)"; status=$?
[[ $status -eq 0 ]] || fail "a bead nobody spent anything on is an answer, not a failure"
grep -q 'no cost recorded' <<<"$missing" \
  || fail "a bead with no cost says so; got: $missing"
pass "a bead nobody spent anything on is exit 0 with a sentence"

# --- --agent narrows the answer ------------------------------------------------------------------------

[[ "$(run "$ord" --by-bead --json --agent Cyclops | jq -r '[.[].aic] | add')" == "15" ]] \
  || fail "--agent Cyclops must still see all of Cyclops's spend"
[[ "$(run "$ord" --by-bead --json --agent Nobody | jq -r 'length')" == "0" ]] \
  || fail "--agent naming nobody answers about nobody"
pass "--agent narrows the answer to one agent"

# --- an empty window is an answer -------------------------------------------------------------------

set +e
empty="$(run "$base" --by-bead --since 5m 2>"$work_dir/err-empty")"; status=$?
set -e
[[ $status -eq 0 ]] || fail "a window with nothing in it is exit 0, got $status"
grep -q 'No cerebro sessions' <<<"$empty" \
  || fail "an empty window says nothing ran; got: $empty"
pass "a window with no activity in it is exit 0 with a sentence"

# --- the refusals: non-zero, and nothing on stdout ------------------------------------------------------

refuses() {
  # $1 fixture, $2 what it is, rest = args
  local tmp="$1" what="$2"; shift 2
  local out status
  set +e
  out="$(run "$tmp" "$@" 2>"$work_dir/err-refuse")"; status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$what must refuse with a non-zero status"
  [[ -z "$out" ]] || fail "$what must put nothing on stdout, got: $out"
  grep -q 'fleet-cost:' "$work_dir/err-refuse" \
    || fail "$what must say why on stderr, got: $(cat "$work_dir/err-refuse")"
}

nostore="$(new_fixture)"
refuses "$nostore" "a missing session store" --by-bead
grep -q 'no session store at' "$work_dir/err-refuse" \
  || fail "a missing store names the path it looked in"
pass "a missing session store refuses, loudly, with nothing on stdout"

nolog="$(new_fixture)"
make_store "$nolog/store.db"
session "$nolog/store.db" s1 Cyclops "$(root_of "$nolog")/"
event "$nolog/store.db" s1 "$(ago_ms 110)" 1000000000
refuses "$nolog" "a missing transition log" --by-bead
grep -q 'no transition log' "$work_dir/err-refuse" \
  || fail "a missing transition log says cost cannot be attributed"
pass "a missing transition log refuses rather than reporting cost it cannot attribute"

notcopilot="$(new_fixture)"
printf 'agent_cli claude\n' > "$notcopilot/.cerebro/project.conf"
make_store "$notcopilot/store.db"
refuses "$notcopilot" "a project that is not on copilot" --by-bead
grep -q "agent_cli claude" "$work_dir/err-refuse" \
  || fail "a non-copilot project is told which provider it declared"
pass "a project declaring a provider other than copilot refuses loudly"

set +e
run "$base" >/dev/null 2>"$work_dir/err-usage"; status=$?
set -e
[[ $status -eq 2 ]] || fail "no mode at all is a usage error (exit 2), got $status"
grep -q '^usage: fleet-cost' "$work_dir/err-usage" \
  || fail "a usage error prints the usage line, got: $(cat "$work_dir/err-usage")"
pass "no mode at all is a usage error"

suite_passed
