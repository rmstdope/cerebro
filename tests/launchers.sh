#!/usr/bin/env bash
#
# Proves the fleet's roster and launcher: `scripts/roster` is the one declaration of who is on the
# fleet, `scripts/launch` is the one place a session is started, and every `run-*` shim is a name
# for it. Also proves every launched session stamps its session with a distinct bd actor identity, so
# a second implementer claiming an already-held bead fails instead of silently aliasing into the
# first (see ah-rnz).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/launchers.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# A stub `claude` on PATH ahead of the real one, so a launcher's `exec claude ...` runs this instead
# of starting a real session. It prints the environment and args it was handed, which is exactly what
# these assertions need and nothing a real session would do.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf 'BEADS_ACTOR=%s\n' "${BEADS_ACTOR:-<unset>}"
for a in "$@"; do
  printf 'ARG:%s\n' "$a"
done
STUB
chmod +x "$stub_dir/claude"

run_launcher() {
  # Runs a launcher with the stub claude first on PATH, and never lets a real `claude` be found even
  # if the stub exec somehow failed to intercept it.
  PATH="$stub_dir:$PATH" bash "$repo_root/scripts/$1" "${@:2}"
}

run_launcher_at() {
  # Like run_launcher, but against a launcher living at an arbitrary scripts directory — used to
  # prove a launcher syncs the symlinks of the consumer repo it is actually running from, not this
  # checkout (ah-cuc).
  local scripts_dir="$1"
  local name="$2"
  shift 2
  PATH="$stub_dir:$PATH" bash "$scripts_dir/$name" "$@"
}

model_of() {
  # $1 = role. Same one-liner as `scripts/launch` — this test is allowed to know the contract.
  awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f && $1=="model:"{print $2; exit}' \
    "$repo_root/agents/$1.md"
}

effort_of() {
  awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f && $1=="effort:"{print $2; exit}' \
    "$repo_root/agents/$1.md"
}

# --- roster ---

roster_out="$("$repo_root/scripts/roster")"
row_count="$(printf '%s\n' "$roster_out" | grep -c .)"
[[ $row_count -ge 2 ]] || fail "roster: expected at least 2 rows, got $row_count"
pass "roster prints at least 2 rows"

while IFS=$'\t' read -r name role kind; do
  [[ -n "$name" && -n "$role" && -n "$kind" ]] || fail "roster: row missing a field: $name/$role/$kind"
  if [[ "$role" == "implementer" ]]; then
    [[ "$kind" == "implementer" ]] || fail "roster: $name has role implementer but kind $kind"
  else
    [[ "$kind" == "interactive" ]] || fail "roster: $name has role $role but kind $kind"
  fi
  [[ -f "$repo_root/agents/$role.md" ]] || fail "roster: agents/$role.md missing for role $role"
done <<<"$roster_out"
pass "roster: every row is NAME/ROLE/KIND, KIND derived correctly, and agents/ROLE.md exists"

names_only="$(printf '%s\n' "$roster_out" | awk -F'\t' '{print $1}')"
[[ "$(printf '%s\n' "$names_only" | sort -u | wc -l | tr -d ' ')" == "$(printf '%s\n' "$names_only" | wc -l | tr -d ' ')" ]] \
  || fail "roster: names are not unique"
pass "roster: names are unique"

first_kind="$(printf '%s\n' "$roster_out" | head -1 | awk -F'\t' '{print $3}')"
last_kind="$(printf '%s\n' "$roster_out" | tail -1 | awk -F'\t' '{print $3}')"
[[ "$first_kind" == "interactive" ]] || fail "roster: first row is not interactive"
[[ "$last_kind" == "implementer" ]] || fail "roster: last row is not implementer"
pass "roster: interactive agents first, implementers last"

implementers_out="$("$repo_root/scripts/roster" --implementers)"
expected_implementers="$(printf '%s\n' "$roster_out" | awk -F'\t' '$3 == "implementer" {print $1}')"
[[ "$implementers_out" == "$expected_implementers" ]] \
  || fail "roster --implementers: does not match the implementer-kind rows"
printf '%s\n' "$implementers_out" | grep -qx "Forge" \
  && fail "roster --implementers: contains an interactive name"
pass "roster --implementers matches the implementer rows and excludes interactive names"

# --role exists for the one question a role with more than one agent raises: which of them is it?
# `plan-bead` asks it to decide which planner runs the triage pass, so that two planning sessions do
# not walk the navigator through the same P4 backlog twice.
role_out="$("$repo_root/scripts/roster" --role planner)"
expected_planners="$(printf '%s\n' "$roster_out" | awk -F'\t' '$2 == "planner" {print $1}')"
[[ "$role_out" == "$expected_planners" ]] \
  || fail "roster --role planner: got '$role_out', expected '$expected_planners'"
[[ -n "$role_out" ]] || fail "roster --role planner: no planner on the roster"
pass "roster --role planner lists the planners in file order"

[[ -z "$("$repo_root/scripts/roster" --role nobody)" ]] \
  || fail "roster --role nobody: expected no output"
pass "roster --role of an unheld role prints nothing"

set +e
"$repo_root/scripts/roster" --role >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster --role with no role: expected exit 2, got $status"
pass "roster --role with no role exits 2"

first_name="$(printf '%s\n' "$roster_out" | head -1 | awk -F'\t' '{print $1}')"
entry_out="$("$repo_root/scripts/roster" --entry "$first_name")"
[[ "$entry_out" == "$(printf '%s\n' "$roster_out" | head -1)" ]] \
  || fail "roster --entry $first_name: does not match its row"
pass "roster --entry returns the matching row"

set +e
out="$("$repo_root/scripts/roster" --entry Nobody 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster --entry Nobody: expected exit 2, got $status"
echo "$out" | grep -q "not on the roster" || fail "roster --entry Nobody: wrong message: $out"
pass "roster --entry Nobody exits 2 naming it not on the roster"

set +e
"$repo_root/scripts/roster" --bogus >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster --bogus: expected exit 2, got $status"
pass "roster --bogus exits 2"

# --- launch, generically over every roster row ---

while IFS=$'\t' read -r name role kind; do
  out="$(run_launcher launch "$name")"
  echo "$out" | grep -q "^BEADS_ACTOR=${name}\$" || fail "launch $name: expected BEADS_ACTOR=$name, got: $out"
  echo "$out" | grep -A1 '^ARG:--agent$' | grep -q "^ARG:${role}\$" || fail "launch $name: expected --agent $role, got: $out"
  echo "$out" | grep -A1 '^ARG:--name$' | grep -q "^ARG:${name}\$" || fail "launch $name: expected --name $name, got: $out"
  echo "$out" | grep -A1 '^ARG:--remote-control$' | grep -q "^ARG:${name}\$" || fail "launch $name: expected --remote-control $name, got: $out"

  expected_model="$(model_of "$role")"
  if [[ -n "$expected_model" ]]; then
    echo "$out" | grep -A1 '^ARG:--model$' | grep -q "^ARG:${expected_model}\$" \
      || fail "launch $name: expected --model $expected_model, got: $out"
  fi

  expected_effort="$(effort_of "$role")"
  if [[ -n "$expected_effort" ]]; then
    echo "$out" | grep -A1 '^ARG:--effort$' | grep -q "^ARG:${expected_effort}\$" \
      || fail "launch $name: expected --effort $expected_effort, got: $out"
  fi

  echo "$out" | grep -q '^ARG:--permission-mode$' || fail "launch $name: missing --permission-mode"
  echo "$out" | grep -A1 '^ARG:--permission-mode$' | grep -q '^ARG:auto$' || fail "launch $name: expected auto"

  # The prompt is the last ARG, and it has one embedded newline, so it prints as the last two
  # lines of output (`tac` is not on macOS by default, so this avoids it).
  prompt="$(echo "$out" | tail -2)"
  echo "$prompt" | grep -q "$name" || fail "launch $name: prompt does not name $name"
  echo "$prompt" | grep -q "$role" || fail "launch $name: prompt does not name $role"
  echo "$prompt" | grep -q "fill the buffer" && fail "launch $name: prompt still has the old per-role drift"
done <<<"$roster_out"
pass "launch: every roster row reaches the stub with the right actor, agent, name, remote-control name, model, effort"

# --- launch overrides ---

out="$(run_launcher launch Xavier --model opus)"
before_opus="$(echo "$out" | grep -n '^ARG:opus$' | head -1 | cut -d: -f1)"
before_fable="$(echo "$out" | grep -n '^ARG:fable$' | head -1 | cut -d: -f1)"
[[ -n "$before_fable" && -n "$before_opus" && $before_fable -lt $before_opus ]] \
  || fail "launch Xavier --model opus: expected fable before opus in ARG list, got: $out"
last_arg="$(echo "$out" | tail -1)"
opus_line="$(echo "$out" | grep -n '^ARG:opus$' | head -1 | cut -d: -f1)"
total_lines="$(echo "$out" | wc -l | tr -d ' ')"
[[ $opus_line -lt $total_lines ]] || fail "launch Xavier --model opus: opus should come before the prompt"
pass "launch Xavier --model opus: fable (declared) before opus (override) before the prompt"

# --- launch overrides: a caller's own --remote-control comes after the launcher's ---
out="$(run_launcher launch Xavier --remote-control Elsewhere)"
first="$(echo "$out" | grep -n '^ARG:--remote-control$' | head -1 | cut -d: -f1)"
second="$(echo "$out" | grep -n '^ARG:--remote-control$' | tail -1 | cut -d: -f1)"
[[ -n "$first" && -n "$second" && $first -lt $second ]] \
  || fail "launch Xavier --remote-control Elsewhere: expected the launcher's flag before the caller's, got: $out"
echo "$out" | sed -n "$((second+1))p" | grep -q '^ARG:Elsewhere$' \
  || fail "launch Xavier --remote-control Elsewhere: caller's name should follow its flag, got: $out"
pass "launch Xavier --remote-control Elsewhere: launcher's Xavier before the caller's Elsewhere"

# --- launch spelling ---

set +e
out="$(run_launcher launch storm 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch storm: expected exit 2, got $status"
echo "$out" | grep -q "Storm" || fail "launch storm: expected the message to name Storm, got: $out"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "launch storm: should never have reached the stub"
pass "launch storm exits 2, names Storm, never reaches the stub"

set +e
out="$(run_launcher launch Nobody 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch Nobody: expected exit 2, got $status"
echo "$out" | grep -q "not on the roster" || fail "launch Nobody: wrong message, got: $out"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "launch Nobody: should never have reached the stub"
pass "launch Nobody exits 2, names it not on the roster, never reaches the stub"

set +e
out="$(run_launcher launch 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch (no argument): expected exit 2, got $status"
pass "launch with no argument exits 2"

# --- shims ---

SHIMS=(run-planner run-orchestrator run-user-feedback run-psylocke run-forge)
SHIM_NAMES=(Xavier Cerebro Moira Psylocke Forge)

i=0
while [[ $i -lt ${#SHIMS[@]} ]]; do
  shim="${SHIMS[$i]}"
  actor="${SHIM_NAMES[$i]}"
  out="$(run_launcher "$shim")"
  echo "$out" | grep -q "^BEADS_ACTOR=${actor}\$" || fail "$shim: expected BEADS_ACTOR=$actor, got: $out"
  echo "$out" | grep -A1 '^ARG:--name$' | grep -q "^ARG:${actor}\$" || fail "$shim: expected --name $actor, got: $out"
  pass "$shim sets BEADS_ACTOR=$actor and --name $actor"
  i=$((i + 1))
done

out="$(run_launcher run-implementer Cyclops)"
echo "$out" | grep -q '^BEADS_ACTOR=Cyclops$' || fail "run-implementer Cyclops: expected BEADS_ACTOR=Cyclops, got: $out"
pass "run-implementer Cyclops sets BEADS_ACTOR=Cyclops"

roster_implementers="$("$repo_root/scripts/roster" --implementers)"
run_implementer_roster="$(run_launcher run-implementer --roster)"
[[ -n "$run_implementer_roster" ]] || fail "run-implementer --roster: empty output"
[[ "$run_implementer_roster" == "$roster_implementers" ]] \
  || fail "run-implementer --roster: does not match scripts/roster --implementers"
pass "run-implementer --roster matches scripts/roster --implementers"

set +e
out="$(run_launcher run-implementer storm 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "run-implementer storm: expected exit 2, got $status"
echo "$out" | grep -q "Storm" || fail "run-implementer storm: expected the message to name Storm, got: $out"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "run-implementer storm: should never have reached the stub"
pass "run-implementer storm still exits 2 and names Storm, without reaching the stub"

set +e
out="$(run_launcher run-implementer Forge 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "run-implementer Forge: expected exit 2, got $status"
echo "$out" | grep -q "not an implementer" || fail "run-implementer Forge: wrong message, got: $out"
echo "$out" | grep -q "launch Forge" || fail "run-implementer Forge: expected the message to name launch Forge, got: $out"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "run-implementer Forge: should never have reached the stub"
pass "run-implementer Forge exits 2, names launch Forge, without reaching the stub"

set +e
out="$(run_launcher run-implementer bishop 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "run-implementer bishop: expected exit 2, got $status"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "run-implementer bishop: should never have reached the stub"
pass "run-implementer bishop exits 2, never reaches the stub"

# --- a launcher syncs the consumer repo's links before starting a session (ah-cuc) ---
consumer_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$consumer_dir"' EXIT
git init -q "$consumer_dir"
mkdir -p "$consumer_dir/.claude"
cp -R "$repo_root" "$consumer_dir/.claude/cerebro"
rm -rf "$consumer_dir/.claude/cerebro/.git"

out="$(run_launcher_at "$consumer_dir/.claude/cerebro/scripts" launch Forge)"
echo "$out" | grep -q '^ARG:--agent$' || fail "launch Forge (consumer): stub was not reached: $out"
[[ -L "$consumer_dir/.claude/agents/architect.md" ]] \
  || fail "launch Forge (consumer): expected .claude/agents/architect.md to be linked"
[[ "$(readlink "$consumer_dir/.claude/agents/architect.md")" == "../cerebro/agents/architect.md" ]] \
  || fail "launch Forge (consumer): expected a relative link to ../cerebro/agents/architect.md"
pass "launch Forge links the consumer's agents before starting the session"

# --- a sync failure aborts the launch: the stub is never reached ---
# The first run above already symlinked .claude/skills/plan-bead; remove that link before
# replacing it with a real directory, or `mkdir -p` on an existing symlink-to-directory is a
# silent no-op and never creates the blocking condition this assertion needs.
rm -f "$consumer_dir/.claude/skills/plan-bead"
mkdir -p "$consumer_dir/.claude/skills/plan-bead"   # a real directory, not a symlink — the sync refuses
set +e
out="$(run_launcher_at "$consumer_dir/.claude/cerebro/scripts" launch Forge 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "launch Forge (consumer, blocked sync): expected a non-zero exit"
echo "$out" | grep -q "Refusing to link over the directory" \
  || fail "launch Forge (consumer, blocked sync): expected the sync's own refusal message, got: $out"
echo "$out" | grep -q '^ARG:--agent$' \
  && fail "launch Forge (consumer, blocked sync): should never have reached the stub"
pass "a blocked sync aborts the launch before the stub is reached"

# --- claude missing: the launcher refuses with one line naming it, never exec's (ah-bri) ---
# A PATH of only `dirname` - the one external command a launcher needs before it even
# reaches launch-preflight's own `claude` check - so this cannot pass on a machine that
# happens to have `claude` installed under /usr/bin or /bin.
no_claude_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$consumer_dir" "$no_claude_dir"' EXIT
ln -s "$(command -v dirname)" "$no_claude_dir/dirname"
# launch-preflight is exec'd directly (its own `#!/usr/bin/env bash' shebang), so `env'
# needs to find `bash' under this PATH too, not only the shell invoking launch below.
ln -s "$(command -v bash)" "$no_claude_dir/bash"
set +e
out="$(PATH="$no_claude_dir" "$(command -v bash)" "$repo_root/scripts/launch" Forge 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch Forge (claude missing): expected exit 2, got $status"
echo "$out" | grep -q "claude is not on PATH" \
  || fail "launch Forge (claude missing): expected the message to name claude is not on PATH, got: $out"
pass "launch Forge refuses with one line when claude is not on PATH"

# --- submodule behind: the role's agent file never arrived, refused before any sync (ah-bri) ---
consumer_dir2="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$no_claude_dir" "$consumer_dir" "$consumer_dir2"' EXIT
git init -q "$consumer_dir2"
mkdir -p "$consumer_dir2/.claude"
cp -R "$repo_root" "$consumer_dir2/.claude/cerebro"
rm -rf "$consumer_dir2/.claude/cerebro/.git"
rm -f "$consumer_dir2/.claude/cerebro/agents/architect.md"
set +e
out="$(run_launcher_at "$consumer_dir2/.claude/cerebro/scripts" launch Forge 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch Forge (submodule behind): expected exit 2, got $status"
echo "$out" | grep -q "the submodule is behind" \
  || fail "launch Forge (submodule behind): expected the message to name the submodule as behind, got: $out"
[[ ! -L "$consumer_dir2/.claude/agents/architect.md" ]] \
  || fail "launch Forge (submodule behind): the sync should not have run before this check"
echo "$out" | grep -q '^ARG:--agent$' \
  && fail "launch Forge (submodule behind): should never have reached the stub"
pass "launch Forge refuses when the submodule never brought its agent file in"

# --- agents/architect.md exists with the right frontmatter ---
[[ -f "$repo_root/agents/architect.md" ]] || fail "agents/architect.md does not exist"
grep -qx 'model: fable' "$repo_root/agents/architect.md" \
  || fail "agents/architect.md: expected a line 'model: fable'"
grep -qx 'effort: xhigh' "$repo_root/agents/architect.md" \
  || fail "agents/architect.md: expected a line 'effort: xhigh'"
pass "agents/architect.md exists with model: fable and effort: xhigh"

echo "all launcher tests passed"
