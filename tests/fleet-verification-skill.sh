#!/usr/bin/env bash
#
# R28, as far as a script can follow it: a project that declares `verification_skill verify-bead'
# gets, for a merged bead, a Psylocke session that runs as the verifier, reads that key, and finds
# that skill where its CLI discovers skills. A SYSTEM suite (.cerebro/test-architecture.md): it
# builds the real `cerebro-tui', runs it on a pseudo-terminal over a throwaway consumer whose board
# holds one merged, unverified bead, and reads what the session it starts found. The pieces are
# Script-level (tests/verification-skill.sh for the lookup, tests/sync-symlinks.sh for the links,
# tests/launchers.sh for the launch); this proves they are joined, so a skill that stops shipping,
# stops being synced, or a key that stops reaching the session turns the gate red.
#
# What the agent then does with the skill - opening the build in Chrome, the evidence, the
# recommended verdict - is the agent following prose, and prose gets no suite (CLAUDE.md).
#
# Real, and unstubbed: the view, `scripts/launch' and its preflight (which syncs the links: the
# fixture deliberately leaves them unsynced, so the launch is what makes the skill discoverable),
# `project-conf', `agent-state'. Stubbed: `bd' (one JSON file per bead, every call logged), `gh'
# (nothing open, and a login), and the agent CLI `claude', which does what Claude Code and an
# agent's first steps do with what `launch' hands it: it resolves its agent file and the declared
# skill from its own working directory, runs `project-conf verification_skill' as agents/verifier.md
# tells the verifier to, records all of it, writes `working', and waits to be killed.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child
# (.cerebro/traps.md). Every wait is a bounded poll that fails with what the view saw and did.
#
#     bash tests/fleet-verification-skill.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_passed - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-verification-skill needs $tool on PATH"
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

consumer="$(consumer_new verifyskill --copy)"
mount="$consumer/.cerebro/cerebro"
state="$consumer/.cerebro/state"
fixture="$work_dir/fixture"
stubs="$fixture/stubs"
beads="$fixture/beads"
mkdir -p "$stubs" "$beads"

cat > "$consumer/.cerebro/project.conf" <<'CONF'
project_name           VerifySkill
default_branch         main
audience_noun          navigator
gate_fast              true
gate_full              true
verification_skill     verify-bead
CONF

printf 'Psylocke  verifier  standby\n' > "$consumer/.cerebro/roster.conf"
printf '.cerebro/worktrees/\n.cerebro/state/\n' >> "$consumer/.git/info/exclude"

# One closed bead with no verification label: merged, and nobody has looked at it.
jq -n '{
  id: "cb-merged", title: "fixture cb-merged", status: "closed", priority: 2, issue_type: "task",
  labels: [], assignee: "", owner: "test",
  created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
  closed_at: "2026-01-01T00:00:00Z"
}' > "$beads/cb-merged.json"

# --- stub bd: one JSON file per bead, every call logged -------------------------------------------
cat > "$stubs/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
printf '%s\n' "$*" >> "$FIXTURE/bd.log"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly|--quiet|-q) shift ;;
    -C|--actor) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
dir="$FIXTURE/beads"
all() { local files=("$dir"/*.json); if ((${#files[@]})); then jq -s 'sort_by(.id)' "${files[@]}"; else echo '[]'; fi; }
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
  ready) echo '[]' ;;
  show)
    [[ -f "$dir/$1.json" ]] || { echo "no issue found: $1" >&2; exit 1; }
    jq -s . "$dir/$1.json" ;;
  dolt|heartbeat) ;;
  *) echo '[]' ;;
esac
STUB

# --- stub gh: nothing open, and the navigator is `navigator' --------------------------------------
cat > "$stubs/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") echo navigator ;;
  *)          echo '[]' ;;
esac
STUB

# --- stub claude: what the session found ----------------------------------------------------------
#
# Into $FIXTURE/session/: `argv' (one per line), `cwd', `agent-file' and `skill-file' (the real path
# each discovery path resolves to from the session's working directory, or `missing'), and
# `verification-skill' (what project-conf answered, or `refused: <stderr>').
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
set -u
out="$FIXTURE/session"
mkdir -p "$out.tmp"
printf '%s\n' "$@" > "$out.tmp/argv"
pwd -P > "$out.tmp/cwd"
role=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --agent ]; then role="$arg"; fi
  prev="$arg"
done
real() {
  # The file a discovery path finally names, links followed - python, since macOS has no readlink -f.
  if [ -e "$1" ]; then python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; else echo missing; fi
}
real ".claude/agents/$role.md" > "$out.tmp/agent-file"
if skill="$(.cerebro/cerebro/scripts/project-conf verification_skill 2>"$out.tmp/conf.err")"; then
  printf '%s\n' "$skill" > "$out.tmp/verification-skill"
  real ".claude/skills/$skill/SKILL.md" > "$out.tmp/skill-file"
else
  printf 'refused: %s\n' "$(cat "$out.tmp/conf.err")" > "$out.tmp/verification-skill"
  echo missing > "$out.tmp/skill-file"
fi
mv "$out.tmp" "$out"
.cerebro/cerebro/scripts/agent-state "$BEADS_ACTOR" working --phase prepare --pid $$
while :; do sleep 0.2; done
STUB
chmod +x "$stubs/bd" "$stubs/gh" "$stubs/claude"

# The links are left to the launch: a consumer that has never started this session has none.
[ ! -e "$consumer/.claude/skills/verify-bead" ] \
  || fail "the fixture already has .claude/skills/verify-bead; the launch must be what links it"

hints="$("$mount/scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r hinted_mount; } <<<"$hints"
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
  printf '\n--- screen ---\n';          cat "$work_dir/view.screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n';     cat "$work_dir/view.err" 2>/dev/null || true
  printf -- '--- session ---\n';         grep -H . "$fixture/session/"* 2>/dev/null || echo "(none)"
  printf -- '--- decisions ---\n';       cat "$state/decisions.jsonl" 2>/dev/null || echo "(none)"
  printf -- '--- evaluations (tail) ---\n'
  tail -n 6 "$state/evaluations.jsonl" 2>/dev/null || echo "(none)"
  printf -- '--- bd.log (tail) ---\n';   tail -n 12 "$fixture/bd.log" 2>/dev/null || true
}

# wait_until <seconds> <what> <command...>: poll until the command succeeds, or fail naming <what>.
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
(
  cd "$consumer"
  export FIXTURE="$fixture" \
         CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
         CEREBRO_CONSUMER_MOUNT="$hinted_mount" CEREBRO_SCRIPTS="$mount/scripts" \
         PATH="$stubs:$PATH" TERM=xterm-256color
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$work_dir/view.keys" "$work_dir/view.screen" \
    50 200 -- "$binary"
) </dev/null >/dev/null 2>>"$work_dir/view.err" &
driver=$!
# Held open read-write for the whole run, so the driver's open never blocks.
exec 7<>"$work_dir/view.keys"

start_line() {
  jq -rs 'map(select(.event == "start" and .agent == "Psylocke")) | .[0] // empty
          | "\(.by)\t\(.reason // "")"' "$state/decisions.jsonl" 2>/dev/null || true
}
has_start() { [ -n "$(start_line)" ]; }
has_session() { [ -d "$fixture/session" ]; }

wait_until 90 "Psylocke's session to start" has_session
wait_until 10 "the view's start line for Psylocke" has_start

line="$(start_line)"
[ "$line" = $'trigger\t1 merged, unverified' ] \
  || fail "Psylocke was started on '$line', expected her trigger with '1 merged, unverified'$(evidence)"
pass "the view starts Psylocke on a merged, unverified bead"

session="$fixture/session"
cwd="$(cat "$session/cwd")"
mount_real="$(cd "$mount" && pwd -P)"

agent="$(awk 'prev == "--agent" { print; exit } { prev = $0 }' "$session/argv")"
[ "$agent" = verifier ] \
  || fail "the session was started with --agent '$agent', not as the verifier$(evidence)"
[ "$(cat "$session/agent-file")" = "$mount_real/agents/verifier.md" ] \
  || fail "from $cwd, .claude/agents/verifier.md is '$(cat "$session/agent-file")', not the mount's agents/verifier.md$(evidence)"
pass "she runs as the verifier, on the mount's own agent file"

[ "$(cat "$session/verification-skill")" = verify-bead ] \
  || fail "inside the session, project-conf verification_skill answered '$(cat "$session/verification-skill")', expected verify-bead$(evidence)"
pass "the declared verification_skill is readable from her session"

[ "$(cat "$session/skill-file")" = "$mount_real/skills/verify-bead/SKILL.md" ] \
  || fail "from $cwd, .claude/skills/verify-bead/SKILL.md is '$(cat "$session/skill-file")', not the mount's skills/verify-bead/SKILL.md$(evidence)"
pass "the skill it names is where her CLI discovers skills, linked by the launch"

suite_passed
