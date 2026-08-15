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

echo "all launcher tests passed"
