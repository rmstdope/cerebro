#!/usr/bin/env bash
#
# Proves every launcher stamps its session with a distinct bd actor identity, so a second implementer
# claiming an already-held bead fails instead of silently aliasing into the first (see ah-rnz).
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

# --- run-implementer Cyclops: exports BEADS_ACTOR=Cyclops before exec'ing claude ---
out="$(run_launcher run-implementer Cyclops)"
echo "$out" | grep -q '^BEADS_ACTOR=Cyclops$' \
  || fail "run-implementer Cyclops: expected BEADS_ACTOR=Cyclops, got: $out"
pass "run-implementer Cyclops sets BEADS_ACTOR=Cyclops"

echo "$out" | grep -q '^BEADS_ACTOR=<unset>$' \
  && fail "run-implementer Cyclops: BEADS_ACTOR is unset in the stub's environment"
pass "run-implementer Cyclops does not leave BEADS_ACTOR unset"

# --- run-implementer storm (miscased): still exits 2, still names Storm, never reaches the stub ---
set +e
out="$(run_launcher run-implementer storm 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "run-implementer storm: expected exit 2, got $status"
echo "$out" | grep -q "Storm" || fail "run-implementer storm: expected the message to name Storm, got: $out"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "run-implementer storm: should never have reached the stub"
pass "run-implementer storm still exits 2 and names Storm, without reaching the stub"

# --- run-implementer --roster: prints exactly the thirteen names, never reaches the stub ---
out="$(run_launcher run-implementer --roster)"
expected="Cyclops
Storm
Wolverine
Rogue
Gambit
Nightcrawler
Colossus
Iceman
Beast
Jubilee
Phoenix
Mystique
Magneto"
[[ "$out" == "$expected" ]] || fail "run-implementer --roster: unexpected output: $out"
pass "run-implementer --roster no longer includes Bishop"

# --- run-implementer Bishop: refuses, names run-bishop, never reaches the stub ---
for candidate in Bishop bishop; do
  set +e
  out="$(run_launcher run-implementer "$candidate" 2>&1)"
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "run-implementer $candidate: expected exit 2, got $status"
  echo "$out" | grep -q "run-bishop" \
    || fail "run-implementer $candidate: expected the message to name run-bishop, got: $out"
  echo "$out" | grep -q '^BEADS_ACTOR=' \
    && fail "run-implementer $candidate: should never have reached the stub"
  pass "run-implementer $candidate exits 2 and names run-bishop, without reaching the stub"
done

# --- the five role launchers: each sets its own fixed BEADS_ACTOR ---
# Parallel arrays, not an associative array: the default bash on macOS is 3.2, which has no
# `declare -A`, and this suite must run on any implementer's machine without asking for bash 4+.
ROLE_LAUNCHERS=(run-planner run-orchestrator run-user-feedback run-psylocke run-bishop)
ROLE_ACTORS=(Xavier Cerebro Moira Psylocke Bishop)

i=0
while [[ $i -lt ${#ROLE_LAUNCHERS[@]} ]]; do
  launcher="${ROLE_LAUNCHERS[$i]}"
  actor="${ROLE_ACTORS[$i]}"
  out="$(run_launcher "$launcher")"
  echo "$out" | grep -q "^BEADS_ACTOR=${actor}\$" \
    || fail "$launcher: expected BEADS_ACTOR=$actor, got: $out"
  pass "$launcher sets BEADS_ACTOR=$actor"
  i=$((i + 1))
done

# --- run-bishop: --agent architect, --name Bishop, --effort xhigh ---
out="$(run_launcher run-bishop)"
echo "$out" | grep -A1 '^ARG:--agent$' | grep -q '^ARG:architect$' \
  || fail "run-bishop: expected --agent architect, got: $out"
echo "$out" | grep -A1 '^ARG:--name$' | grep -q '^ARG:Bishop$' \
  || fail "run-bishop: expected --name Bishop, got: $out"
echo "$out" | grep -A1 '^ARG:--effort$' | grep -q '^ARG:xhigh$' \
  || fail "run-bishop: expected --effort xhigh, got: $out"
pass "run-bishop passes --agent architect --name Bishop --effort xhigh"

# --- agents/architect.md exists with the right frontmatter ---
[[ -f "$repo_root/agents/architect.md" ]] || fail "agents/architect.md does not exist"
grep -qx 'model: fable' "$repo_root/agents/architect.md" \
  || fail "agents/architect.md: expected a line 'model: fable'"
grep -qx 'effort: xhigh' "$repo_root/agents/architect.md" \
  || fail "agents/architect.md: expected a line 'effort: xhigh'"
pass "agents/architect.md exists with model: fable and effort: xhigh"

# --- a launcher syncs the consumer repo's links before starting a session (ah-cuc) ---
consumer_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$consumer_dir"' EXIT
git init -q "$consumer_dir"
mkdir -p "$consumer_dir/.claude"
cp -R "$repo_root" "$consumer_dir/.claude/cerebro"
rm -rf "$consumer_dir/.claude/cerebro/.git"

out="$(run_launcher_at "$consumer_dir/.claude/cerebro/scripts" run-bishop)"
echo "$out" | grep -q '^ARG:--agent$' || fail "run-bishop (consumer): stub was not reached: $out"
[[ -L "$consumer_dir/.claude/agents/architect.md" ]] \
  || fail "run-bishop (consumer): expected .claude/agents/architect.md to be linked"
[[ "$(readlink "$consumer_dir/.claude/agents/architect.md")" == "../cerebro/agents/architect.md" ]] \
  || fail "run-bishop (consumer): expected a relative link to ../cerebro/agents/architect.md"
pass "run-bishop links the consumer's agents before starting the session"

# --- a sync failure aborts the launch: the stub is never reached ---
# The first run above already symlinked .claude/skills/plan-bead; remove that link before
# replacing it with a real directory, or `mkdir -p` on an existing symlink-to-directory is a
# silent no-op and never creates the blocking condition this assertion needs.
rm -f "$consumer_dir/.claude/skills/plan-bead"
mkdir -p "$consumer_dir/.claude/skills/plan-bead"   # a real directory, not a symlink — the sync refuses
set +e
out="$(run_launcher_at "$consumer_dir/.claude/cerebro/scripts" run-bishop 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "run-bishop (consumer, blocked sync): expected a non-zero exit"
echo "$out" | grep -q "Refusing to link over the directory" \
  || fail "run-bishop (consumer, blocked sync): expected the sync's own refusal message, got: $out"
echo "$out" | grep -q '^ARG:--agent$' \
  && fail "run-bishop (consumer, blocked sync): should never have reached the stub"
pass "a blocked sync aborts the launch before the stub is reached"

# --- claude missing: the launcher refuses with one line naming it, never exec's (ah-bri) ---
set +e
out="$(PATH=/usr/bin:/bin bash "$repo_root/scripts/run-bishop" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "run-bishop (claude missing): expected exit 2, got $status"
echo "$out" | grep -q "claude is not on PATH" \
  || fail "run-bishop (claude missing): expected the message to name claude is not on PATH, got: $out"
pass "run-bishop refuses with one line when claude is not on PATH"

# --- submodule behind: the role's agent file never arrived, refused before any sync (ah-bri) ---
consumer_dir2="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$consumer_dir" "$consumer_dir2"' EXIT
git init -q "$consumer_dir2"
mkdir -p "$consumer_dir2/.claude"
cp -R "$repo_root" "$consumer_dir2/.claude/cerebro"
rm -rf "$consumer_dir2/.claude/cerebro/.git"
rm -f "$consumer_dir2/.claude/cerebro/agents/architect.md"
set +e
out="$(run_launcher_at "$consumer_dir2/.claude/cerebro/scripts" run-bishop 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "run-bishop (submodule behind): expected exit 2, got $status"
echo "$out" | grep -q "the submodule is behind" \
  || fail "run-bishop (submodule behind): expected the message to name the submodule as behind, got: $out"
[[ ! -L "$consumer_dir2/.claude/agents/architect.md" ]] \
  || fail "run-bishop (submodule behind): the sync should not have run before this check"
echo "$out" | grep -q '^ARG:--agent$' \
  && fail "run-bishop (submodule behind): should never have reached the stub"
pass "run-bishop refuses when the submodule never brought its agent file in"

echo "all launcher tests passed"
