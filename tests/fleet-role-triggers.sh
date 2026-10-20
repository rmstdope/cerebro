#!/usr/bin/env bash
#
# R14, as a navigator meets it: each interactive role starts on its own trigger - UX, Psylocke,
# Cerebro, Moira, Cypher, Forge, Sage - and is ended half a minute after it writes `waiting'. And
# R27: each of the four clock roles - Moira, Cypher, Forge, Sage - starts on the cadence the
# project declares for it (`role_cadence_<role>'), no sooner. A
# SYSTEM suite (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs it on a
# pseudo-terminal over a throwaway consumer, and asserts what the fleet was left with. The rules
# underneath - each role's condition and its cadence (`triggers::trigger'), and the grace
# (`lifecycle::supervise_action', END_GRACE_SECONDS) - are tested on their own; this proves the
# path through them.
#
# Real, and unstubbed: the view, `scripts/launch' (the view's one way to start a session), its
# preflight, `assign-bead', the candidate scripts the work reader runs, `agent-state' and
# `end-pass'. Stubbed, because this suite may not touch them: `bd' (one JSON file per bead, every
# call logged), `gh' (two fixture files and a login), and the agent CLI `claude', a pass that
# reports `working', ends itself through the real `end-pass', records the `since' its `waiting'
# carries, and waits to be killed.
#
# The fleet is the seven interactive rows, all standby. Forge and Sage have no trigger but their
# clock, and Moira and Cypher a clock as well as their conditions: an hour unless the project
# declares one (`role_cadence_<role>', cb-kmxs). Runs declaring ten seconds watch the start rather
# than take it on trust.
#
# Three runs of the view, because `gh' is read on the view's own schedule - at startup, then every
# ten minutes or after a start - and never on `g', so a trigger that lives on GitHub is given at
# startup, and because a role started once is not started again inside its 600 s wake interval:
#   1. the baseline. The board is empty and `gh' lists only what starts nobody - an issue older
#      than the view, the navigator's own pull request and a draft. Once `gh' has answered, every
#      one of the seven rows is evaluated with no reason, and no session starts. Then `q'.
#   2. the clock (R27, cb-3qf2). The same quiet board and `gh', and all four clock roles declared
#      at ten seconds: each starts on its clock, no sooner than ten seconds after it was armed,
#      and nobody else starts. The view refuses `q' over a live session, so the four passes are
#      ended by the view before it quits.
#   3. the triggers, one at a time. Only Forge and Sage are declared at ten seconds, so their clock
#      runs out while the other five are being given their triggers instead of after them
#      (cb-fwt6), and Moira and Cypher are left to their conditions. `gh' now lists a
#      contributor's pull request updated after the view armed, and Cypher starts on it. Then a
#      bead per role is put on the board and `g' refreshes it - an unranked one for Cerebro, a
#      merged unverified one for Psylocke, one with its experience not yet agreed for Xavier (UX,
#      handed that bead), a linked bead that moved for Moira - and after each, exactly that row has
#      started, on its own trigger's reason; every row not yet given its trigger was evaluated with
#      none. Forge and Sage start on their clock, no sooner than ten seconds after they were armed,
#      whichever step that falls in. Their 600 s wake interval keeps either from being started a
#      second time before the run ends.
# Every one of run 3's seven passes then ends itself, and the view ends each session no sooner than
# 30 seconds and no later than 50 after its `waiting', and its process is gone.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child
# (.cerebro/traps.md). Every wait is a bounded poll that fails with what the view saw and did.
# Most of the suite's time is the condition walk and the half minutes passes are given before they
# are ended; in run 3 the clock roles' ten seconds run out inside the walk.
#
#     bash tests/fleet-role-triggers.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_passed - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-role-triggers needs $tool on PATH"
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

consumer="$(consumer_new roletriggers --copy)"
state="$consumer/.cerebro/state"
fixture="$work_dir/fixture"
stubs="$fixture/stubs"
beads="$fixture/beads"
mkdir -p "$stubs" "$beads"

cat > "$consumer/.cerebro/project.conf" <<'CONF'
project_name           RoleTriggers
default_branch         main
audience_noun          navigator
gate_fast              true
gate_full              true
CONF

cat > "$consumer/.cerebro/roster.conf" <<'ROSTER'
Xavier          ux              standby
Psylocke        verifier        standby
Cerebro         orchestrator    standby
Moira           user-feedback   standby
Cypher          reviewer        standby
Forge           architect       standby
Sage            qa              standby
ROSTER
roles=(Xavier Psylocke Cerebro Moira Cypher Forge Sage)

printf '.cerebro/worktrees/\n.cerebro/state/\n' >> "$consumer/.git/info/exclude"

iso() {
  # [<offset seconds>]: the time now, plus the offset, as gh and bd print it.
  python3 -I -c 'import sys, datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "${1:-0}"
}
epoch() {
  python3 -I -c 'import sys, datetime; print(int(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$1"
}

bead() {
  # <id> <status> <priority> <labels as a JSON array> [<assignee> <external ref>]
  jq -n --arg id "$1" --arg status "$2" --argjson p "$3" --argjson labels "$4" \
        --arg assignee "${5:-}" --arg ref "${6:-}" --arg now "$(iso)" '{
    id: $id, title: ("fixture " + $id), status: $status, priority: $p, issue_type: "task",
    labels: $labels, assignee: $assignee, owner: "test",
    created_at: "2026-01-01T00:00:00Z", updated_at: $now
  } + (if $ref == "" then {} else {external_ref: $ref} end)' > "$beads/.$1.json"
  mv "$beads/.$1.json" "$beads/$1.json"
}

# --- stub bd: one JSON file per bead, every call logged -------------------------------------------
cat > "$stubs/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
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
set -- "${args[@]+"${args[@]}"}"
dir="$FIXTURE/beads"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
all() { local files=("$dir"/*.json); if ((${#files[@]})); then jq -s 'sort_by(.id)' "${files[@]}"; else echo '[]'; fi; }
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
    # Open and unassigned, carrying every `--label' and none of the `--exclude-label's: the
    # builder queues ask for `ux:agreed', `ux:none' and `bugfix', and this board has none of them.
    want='[]'; avoid='[]'
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) want="$(jq -c --arg l "$2" '. + ($l | split(","))' <<<"$want")"; shift 2 ;;
        --exclude-label) avoid="$(jq -c --arg l "$2" '. + ($l | split(","))' <<<"$avoid")"; shift 2 ;;
        *) shift ;;
      esac
    done
    all | jq --argjson want "$want" --argjson avoid "$avoid" '[ .[]
      | select(.status == "open" and (.assignee // "") == "")
      | select(.labels as $have | ($want | all(. as $l | $have | index($l)))
                              and ($avoid | all(. as $l | ($have | index($l)) | not))) ]' ;;
  show)
    [[ -f "$dir/$1.json" ]] || { echo "no issue found: $1" >&2; exit 1; }
    jq -s . "$dir/$1.json" ;;
  update)
    id="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --assignee) edit "$id" ".assignee = \"$2\""; shift 2 ;;
        --add-label) edit "$id" ".labels = ((.labels // []) + [\"$2\"] | unique)"; shift 2 ;;
        --if-assignee) shift 2 ;;
        *) shift ;;
      esac
    done ;;
  children) echo '[]' ;;
  dolt|heartbeat) ;;
  *) echo '[]' ;;
esac
STUB

# --- stub gh: what is open on GitHub is two fixture files, and the navigator is `navigator' --------
cat > "$stubs/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(date +%s)" "$*" >> "$FIXTURE/gh.log"
case "$1 $2" in
  "issue list") cat "$FIXTURE/gh-issues.json" ;;
  "pr list")    cat "$FIXTURE/gh-prs.json" ;;
  "api user")   echo navigator ;;
  *)            echo '[]' ;;
esac
STUB

# --- stub claude: a pass that ends itself ----------------------------------------------------------
#
# `<epoch> <Name> <bead or none> <pid>' when it starts, to `sessions'; a bead it was handed, agreed;
# the `since' its `waiting' carries, to `waited/<Name>'. Then it waits to be killed: the view's end
# is what is watched.
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
set -u
root="$CEREBRO_CONSUMER_SHARED_ROOT"
scripts="$root/.cerebro/cerebro/scripts"
name="$BEADS_ACTOR"
bead="$(head -n 1 "$root/.cerebro/state/$name.handover" 2>/dev/null || true)"
printf '%s %s %s %s\n' "$(date +%s)" "$name" "${bead:-none}" "$$" >> "$FIXTURE/sessions"
if [ -n "$bead" ]; then
  "$scripts/agent-state" "$name" working --bead "$bead" --phase pass --pid $$
else
  "$scripts/agent-state" "$name" working --phase pass --pid $$
fi
sleep 1
# What a UX pass does with the bead it was handed: agrees it, so it leaves the UX queue. A pass that
# left it untouched would be given it back when it ends, and started on it again (cb-kmxs's notes).
if [ -n "$bead" ]; then
  bd --actor "$name" update "$bead" --add-label ux:agreed
fi
"$scripts/end-pass" "$name" --pid $$
jq -r .since "$root/.cerebro/state/$name.state.json" > "$FIXTURE/waited/$name"
while :; do sleep 0.2; done
STUB
chmod +x "$stubs/bd" "$stubs/gh" "$stubs/claude"
mkdir -p "$fixture/waited"

# The links a consumer keeps synced, made now, as any consumer that has run a session already has
# them: left to the first launch, two launches in one tick race over them (cb-gkhx's retrospective).
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
  printf '\n--- load ---\n';              uptime 2>/dev/null || true
  printf -- '--- lease ---\n'
  local endpoint
  for endpoint in "$(cd "$consumer" && .cerebro/cerebro/scripts/fleet-supervisor --endpoint 2>&1)" \
                  "$(cd "$consumer" && .cerebro/cerebro/scripts/fleet-supervisor --legacy-endpoint 2>&1)"; do
    printf '%s held by: %s\n' "$endpoint" \
      "$(lsof -nP -iTCP:"${endpoint##*:}" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1, $2 }' | tr '\n' ' ')"
  done
  cat "$state/supervisor.json" 2>/dev/null || echo "(no supervisor.json)"
  printf -- '--- screen ---\n';          cat "$work_dir/view.screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n';     cat "$work_dir/view.err" 2>/dev/null || true
  printf -- '--- sessions ---\n';        cat "$fixture/sessions" 2>/dev/null || echo "(none)"
  printf -- '--- waited ---\n';          grep -H . "$fixture/waited/"* 2>/dev/null || echo "(none)"
  printf -- '--- beads ---\n';           jq -c '{id, status, priority, assignee}' "$beads"/*.json 2>/dev/null || true
  printf -- '--- gh.log ---\n';          cat "$fixture/gh.log" 2>/dev/null || true
  printf -- '--- decisions ---\n';       cat "$state/decisions.jsonl" 2>/dev/null || echo "(none)"
  printf -- '--- evaluations (tail) ---\n'
  tail -n 14 "$state/evaluations.jsonl" 2>/dev/null || echo "(none)"
  # fleet-history, fleet-health and the sweeps log errors against this fixture's board and missing
  # transition log; expected, and no part of what is asserted.
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

start_view() {
  rm -f "$work_dir/view.keys" "$work_dir/view.screen"
  mkfifo "$work_dir/view.keys"
  (
    cd "$consumer"
    export FIXTURE="$fixture" \
           CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
           CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$consumer/.cerebro/cerebro/scripts" \
           PATH="$stubs:$PATH" TERM=xterm-256color
    exec python3 -I "$repo_root/tests/lib/pty-drive" "$work_dir/view.keys" "$work_dir/view.screen" \
      50 200 -- "$binary"
  ) </dev/null >/dev/null 2>>"$work_dir/view.err" &
  driver=$!
  # Held open read-write for the whole run, so the open never blocks: a key is one printf.
  exec 7<>"$work_dir/view.keys"
}
press() { printf '%s' "$1" >&7; }

# The decisions line of EVENT for NAME, its `ts' and its reason, as `<ts>\t<reason>'.
decision() {
  jq -rs --arg e "$1" --arg a "$2" \
    'map(select(.event == $e and .agent == $a)) | .[0] // empty | "\(.ts)\t\(.reason // "")"' \
    "$state/decisions.jsonl" 2>/dev/null || true
}
has_decision() { [ -n "$(decision "$1" "$2")" ]; }
session_of() { awk -v n="$1" '$2 == n { print; exit }' "$fixture/sessions" 2>/dev/null || true; }
has_session() { [ -n "$(session_of "$1")" ]; }
# The names with sessions, sorted. With `--conditions', only the five roles a condition starts:
# Forge's and Sage's clock runs while the others are given theirs, and is held to its own declared cadence.
started_names() {
  awk -v all="${1:-}" 'all != "--conditions" || ($2 != "Forge" && $2 != "Sage") { print $2 }' \
    "$fixture/sessions" 2>/dev/null | sort | tr '\n' ' '
}
expect_started() {
  # [--conditions] <the names that should have sessions by now>
  local scope="" want
  if [ "$1" = --conditions ]; then scope=--conditions; shift; fi
  want="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
  [ "$(started_names $scope)" = "$want" ] \
    || fail "expected sessions for exactly: $want; have: $(started_names $scope)$(evidence)"
}

# evaluated_free_since <epoch> <name...>: each NAME's evaluations since EPOCH exist, and every one
# of them found no reason to start it.
evaluated_free_since() {
  local since="$1" name
  shift
  for name in "$@"; do
    jq -se --arg a "$name" --argjson t "$since" '
      [.[] | select(.agent == $a and (.ts | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) >= $t)]
      | length > 0 and all(.reason == null)' "$state/evaluations.jsonl" >/dev/null 2>&1 \
      || return 1
  done
}

# started_on <Name> <reason>: the view started NAME by its trigger, with REASON.
started_on() {
  local line
  line="$(decision start "$1")"
  jq -se --arg a "$1" 'map(select(.event == "start" and .agent == $a)) | .[0].by == "trigger"' \
    "$state/decisions.jsonl" >/dev/null 2>&1 \
    || fail "$1 was started, but not by its trigger: $line$(evidence)"
  [ "${line#*$'\t'}" = "$2" ] || fail "$1 was started on '${line#*$'\t'}', expected '$2'$(evidence)"
}

# give <Name> <reason> <others still without a trigger...>: NAME, whose trigger was just put on the
# board, starts on REASON; the rest were evaluated with nothing to start them on, before and after.
give() {
  local name="$1" reason="$2" since
  shift 2
  since="$(date +%s)"
  press g
  wait_until 60 "$name's session to start" has_session "$name"
  wait_until 10 "the view's start line for $name" has_decision start "$name"
  started_on "$name" "$reason"
  if (($#)); then
    wait_until 20 "an evaluation of $* with no reason after $name's start" evaluated_free_since "$since" "$@"
  fi
}

# quit_view <run>: `q' and the view gone - which it refuses while it hosts a session, so a run
# that started any waits for the view to end them first. Its logs are kept under $work_dir/<run>,
# and the fleet is left as a fresh consumer's, so the next run starts from nothing.
quit_view() {
  local quit_deadline=$((SECONDS + 20))
  press q
  while kill -0 "$driver" 2>/dev/null; do
    ((SECONDS < quit_deadline)) || fail "the view did not quit on q$(evidence)"
    sleep 0.2
  done
  wait "$driver" 2>/dev/null || true
  exec 7>&-
  mkdir -p "$work_dir/$1"
  mv "$state"/*.jsonl "$work_dir/$1/" 2>/dev/null || true
  mv "$fixture/sessions" "$work_dir/$1/" 2>/dev/null || true
  rm -f "$fixture/waited/"* "$state"/*.state.json "$state"/*.handover
  : > "$fixture/gh.log"
}

# --- run 1: nothing anybody's trigger is ----------------------------------------------------------

jq -n --arg old "$(iso -3600)" '[{number: 7, updatedAt: $old}]' > "$fixture/gh-issues.json"
jq -n --arg old "$(iso -3600)" --arg soon "$(iso 600)" '[
  {number: 11, author: {login: "navigator"},   isDraft: false, updatedAt: $soon},
  {number: 12, author: {login: "contributor"}, isDraft: true,  updatedAt: $soon},
  {number: 13, author: {login: "contributor"}, isDraft: false, updatedAt: $old}
]' > "$fixture/gh-prs.json"

start_view
# Run 1 declares no cadence, so the four clock roles keep the built-in hour, which no baseline
# outlasts.
# The arm lines are written only by a view that took charge: a read-only one starts nothing, and
# would pass the baseline for the wrong reason.
wait_until 60 "the view to take charge and arm the roster" has_decision arm Sage
gh_answered() { grep -q ' pr list ' "$fixture/gh.log" 2>/dev/null; }
wait_until 90 "the view to read gh" gh_answered
asked_at="$(awk '/ pr list / { print $1; exit }' "$fixture/gh.log")"
wait_until 30 "an evaluation of all seven rows, after gh answered, with no reason" \
  evaluated_free_since "$((asked_at + 6))" "${roles[@]}"
[ ! -s "$fixture/sessions" ] || fail "a row was started with nothing to start it on$(evidence)"
pass "with no trigger anywhere, none of the seven rows starts"

quit_view run1

# --- run 2: R27, each clock role on the cadence the project declares -----------------------------

# All four clock roles declared at ten seconds, on the quiet board and the quiet `gh' of run 1, so
# nothing but the clock can start any of them. Moira and Cypher are what this run is for: run 3
# gives them their conditions, which a ten-second clock there would pre-empt (cb-3qf2).
cadence=10
cp "$consumer/.cerebro/project.conf" "$fixture/project.conf.base"
declare_cadence() {
  # <role...>: the base declarations, plus a ten-second cadence for each ROLE.
  cp "$fixture/project.conf.base" "$consumer/.cerebro/project.conf"
  local role
  for role in "$@"; do
    printf 'role_cadence_%s %s\n' "$role" "$cadence" >> "$consumer/.cerebro/project.conf"
  done
}
declare_cadence user-feedback reviewer architect qa

start_view
for name in Moira Cypher Forge Sage; do
  wait_until 30 "the view to arm $name" has_decision arm "$name"
done
for name in Moira Cypher Forge Sage; do
  wait_until 90 "$name's session to start on its clock" has_session "$name"
  wait_until 10 "the view's start line for $name" has_decision start "$name"
done
# Whole minutes are what a cadence reason names (`triggers::cadence_figure'), so ten seconds is
# `0m'; `triggers::cadence_noun' calls a pass of the two GitHub roles a pass, and of the two
# filing roles a sweep.
started_on Moira "0m since its last pass"
started_on Cypher "0m since its last pass"
started_on Forge "0m since its last sweep"
started_on Sage "0m since its last sweep"
for name in Moira Cypher Forge Sage; do
  armed="$(epoch "$(decision arm "$name" | cut -f1)")"
  at="$(epoch "$(decision start "$name" | cut -f1)")"
  ((at - armed >= cadence)) \
    || fail "$name was started $((at - armed))s after it was armed; its declared cadence is ${cadence}s$(evidence)"
done
clock_since="$(date +%s)"
wait_until 20 "an evaluation of Xavier, Psylocke and Cerebro with no reason" \
  evaluated_free_since "$clock_since" Xavier Psylocke Cerebro
expect_started Moira Cypher Forge Sage
pass "Moira, Cypher, Forge and Sage are started on their declared cadence, no sooner than ${cadence}s after arming"

# The view refuses `q' over a live session, so each pass, which ended itself, is left for the view
# to end before it quits: the half minute run 3 measures, here only waited out.
for name in Moira Cypher Forge Sage; do
  wait_until 70 "the view to end $name's pass" has_decision end "$name"
done
quit_view run2

# --- run 3: each trigger in turn ------------------------------------------------------------------

# Forge's and Sage's clock only, so it runs out while the condition roles are being given theirs,
# rather than after them; Moira and Cypher keep their hour and start on their conditions.
declare_cadence architect qa

# A contributor's pull request, updated after the view arms Cypher, however slowly it starts: two
# minutes ahead, which a second start of Cypher could only read as moved after his 600 s wake
# interval, long after this run ends.
jq --arg moved "$(iso 120)" '. + [{number: 14, author: {login: "contributor"}, isDraft: false, updatedAt: $moved}]' \
  "$fixture/gh-prs.json" > "$fixture/gh-prs.next" && mv "$fixture/gh-prs.next" "$fixture/gh-prs.json"

start_view
wait_until 30 "the view to arm Forge" has_decision arm Forge
armed_at="$(epoch "$(decision arm Forge | cut -f1)")"

wait_until 60 "Cypher's session to start" has_session Cypher
wait_until 10 "the view's start line for Cypher" has_decision start Cypher
started_on Cypher "PR #14 moved"
expect_started --conditions Cypher
pass "Cypher is started on a contributor's pull request that moved"

bead cb-rank open 4 '[]'
give Cerebro "1 unranked" Xavier Psylocke Moira
expect_started --conditions Cypher Cerebro
pass "Cerebro is started on an unranked bead, and nobody else is"

bead cb-done closed 2 '[]'
give Psylocke "1 merged, unverified" Xavier Moira
expect_started --conditions Cypher Cerebro Psylocke
pass "Psylocke is started on a merged, unverified bead, and nobody else is"

bead cb-ux open 2 '[]'
give Xavier "UX 0 of 2" Moira
expect_started --conditions Cypher Cerebro Psylocke Xavier
[ "$(session_of Xavier | awk '{ print $3 }')" = cb-ux ] \
  || fail "Xavier was not handed cb-ux: $(session_of Xavier)$(evidence)"
pass "Xavier is started on a bead whose experience is not agreed, and handed it"

bead cb-linked in_progress 2 '[]' Other gh-7
give Moira "bead cb-linked moved (issue #7)"
expect_started --conditions Cypher Cerebro Psylocke Xavier Moira
pass "Moira is started on a linked bead that moved, and nobody else is"

wait_until 90 "Forge's session to start" has_session Forge
wait_until 30 "Sage's session to start" has_session Sage
wait_until 10 "the view's start line for Forge" has_decision start Forge
wait_until 10 "the view's start line for Sage" has_decision start Sage
# Whole minutes are what a cadence reason names (`triggers::cadence_figure'), so ten seconds is `0m'.
started_on Forge "0m since its last sweep"
started_on Sage "0m since its last sweep"
for name in Forge Sage; do
  at="$(epoch "$(decision start "$name" | cut -f1)")"
  ((at - armed_at >= cadence)) \
    || fail "$name was started $((at - armed_at))s after it was armed; its declared cadence is ${cadence}s$(evidence)"
done
expect_started Cypher Cerebro Psylocke Xavier Moira Forge Sage
pass "Forge and Sage are started on their declared cadence, no sooner than ${cadence}s after arming"

# --- every pass, ended half a minute after its waiting --------------------------------------------

for name in "${roles[@]}"; do
  wait_until 70 "the view to end $name's pass" has_decision end "$name"
  [ -s "$fixture/waited/$name" ] || fail "$name's pass recorded no waiting$(evidence)"
  waited="$(epoch "$(cat "$fixture/waited/$name")")"
  ended="$(epoch "$(decision end "$name" | cut -f1)")"
  ((ended - waited >= 30 && ended - waited <= 50)) \
    || fail "$name was ended $((ended - waited))s after it wrote waiting; R14 says half a minute$(evidence)"
  pid="$(session_of "$name" | awk '{ print $4 }')"
  gone() { ! kill -0 "$pid" 2>/dev/null; }
  wait_until 10 "$name's session process to be gone" gone
done
expect_started "${roles[@]}"
pass "each of the seven is ended 30 to 50 seconds after it wrote waiting, and its session is gone"

suite_passed
