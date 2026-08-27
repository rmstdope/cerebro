#!/usr/bin/env bash
#
# Proves scripts/launch-preflight brings a consumer's checkout current before a session reads its
# instructions from it, and refuses rather than writes when it cannot (ah-puoj). A session started
# on a stale checkout reads CLAUDE.md and skills describing a repository that no longer exists, and
# has no way to discover that.
#
# Every assertion runs against a fabricated consumer under `mktemp -d`, with its own `origin` - never
# the checkout this is run from, which this feature would otherwise fast-forward as a side effect of
# testing it (ah-dy4x is the same lesson from tests/launchers.sh).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/launch-preflight.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"

# launch-preflight refuses before anything else when `claude` is not on PATH, and these cases are
# about the checkout rather than the install. The stub is never executed - the preflight only looks
# it up - but it must exist for any case to get past the first guard.
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_dir/claude"

# --- a throwaway consumer with an origin it can be behind -----------------------------------------
#
# Each case builds its own: reusing one leaks an earlier case's fast-forward into a later one, and
# the failure then reads as a logic bug in the script rather than in the fixture.
#
# make_consumer <name> [branch]  ->  echoes the consumer path; "$work_dir/<name>-up" is a clone of
# the same origin, which a case pushes to when it wants the consumer to be behind.
#
# The branch is a PARAMETER, and that is the point of ah-qled.3: while every fixture said `main` and
# every script said `main`, the two agreed and no test here could catch a consumer whose branch is
# called anything else. Cases that do not care pass nothing and get `main`, so what they assert is
# unchanged; the `trunk` case below is what the parameter exists for.
make_consumer() {
  consumer_new "$1" --branch "${2:-main}" --origin --copy
}

# Runs the preflight the way a launcher does: from the consumer's own copy, so consumer-root resolves
# to the fixture and nothing outside $work_dir is ever looked at.
run_preflight() {
  local consumer="$1"
  local role="${2:-planner}"
  local name="${3:-Xavier}"
  PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/launch-preflight" "$role" "$name"
}

head_of() { git -C "$1" rev-parse HEAD; }
# The remote's real tip, read from the remote itself: the consumer's own origin/main ref is
# exactly what a stale checkout has not fetched, so asserting against it would assert nothing.
origin_head_of() { git -C "$1" ls-remote origin "$(git -C "$1" rev-parse --abbrev-ref HEAD)" | cut -f1; }

# --- a current checkout launches ------------------------------------------------------------------
c="$(make_consumer current)"
before="$(head_of "$c")"
run_preflight "$c" || fail "current: expected exit 0"
[[ "$(head_of "$c")" == "$before" ]] || fail "current: HEAD moved"
pass "a current checkout launches"

# --- a behind but clean checkout is fast-forwarded ------------------------------------------------
c="$(make_consumer behind)"
advance_origin behind 2
run_preflight "$c" || fail "behind: expected exit 0"
[[ "$(head_of "$c")" == "$(origin_head_of "$c")" ]] \
  || fail "behind: expected HEAD to be fast-forwarded to origin/main"
pass "a behind but clean checkout is fast-forwarded"

# --- an untracked file does not stop it -----------------------------------------------------------
#
# The consumer carries untracked files routinely (an unstaged agent definition, a scratch note);
# refusing on them would refuse every launch, which is a worse failure than the one being fixed.
c="$(make_consumer untracked)"
advance_origin untracked 1
echo scratch > "$c/scratch.txt"
run_preflight "$c" || fail "untracked: expected exit 0"
[[ "$(head_of "$c")" == "$(origin_head_of "$c")" ]] || fail "untracked: expected a fast-forward"
[[ -f "$c/scratch.txt" ]] || fail "untracked: the untracked file was removed"
pass "an untracked file does not stop it"

# --- a dirty checkout is refused, and left exactly as it was ---------------------------------------
c="$(make_consumer dirty)"
advance_origin dirty 1
echo "my edit" >> "$c/file.txt"
before="$(head_of "$c")"
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "dirty: expected exit 2, got $status"
grep -q "uncommitted changes" <<<"$out" || fail "dirty: expected a message naming the changes, got: $out"
[[ "$(head_of "$c")" == "$before" ]] || fail "dirty: HEAD moved"
grep -q "my edit" "$c/file.txt" || fail "dirty: the edit was lost"
pass "a dirty checkout is refused, and the edit survives"

# --- ...and the refusal reaches errors.jsonl, which is the file the navigator is sent to (cb-ccl) --
#
# The incident this comes from: this exact refusal, 274 times in a day, with stderr the only place it
# was ever said and vterm never drawing it before the session died.
log="$c/.cerebro/state/errors.jsonl"
[[ -f "$log" ]] || fail "dirty: expected the refusal at $log"
[[ "$(tail -n1 "$log" | jq -r .context)" == "launch Xavier" ]] \
  || fail "dirty: expected context='launch Xavier', got: $(tail -n1 "$log")"
grep -q "uncommitted changes" <<<"$(tail -n1 "$log" | jq -r .message)" \
  || fail "dirty: expected the logged message to name the changes, got: $(tail -n1 "$log")"
pass "a refused launch is recorded in errors.jsonl"

# --- a diverged checkout is refused ----------------------------------------------------------------
c="$(make_consumer diverged)"
advance_origin diverged 1
echo mine > "$c/mine.txt"
git_q -C "$c" add mine.txt
git_q -C "$c" commit -q -m mine
before="$(head_of "$c")"
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "diverged: expected exit 2, got $status"
grep -q "origin/main does not" <<<"$out" || fail "diverged: expected a message naming the commits, got: $out"
[[ "$(head_of "$c")" == "$before" ]] || fail "diverged: HEAD moved"
pass "a diverged checkout is refused, and the commit survives"

# --- a checkout on another branch is refused --------------------------------------------------------
c="$(make_consumer branch)"
advance_origin branch 1
git -C "$c" switch -q -c wip
before="$(head_of "$c")"
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "branch: expected exit 2, got $status"
grep -q "wip" <<<"$out" || fail "branch: expected a message naming the branch, got: $out"
[[ "$(head_of "$c")" == "$before" ]] || fail "branch: HEAD moved"
pass "a checkout on another branch is refused"

# --- a dirty submodule is refused, and its work survives ---------------------------------------------
#
# Somebody editing cerebro in place is exactly how this feature was built, and updating the submodule
# under them would throw that work away.
c="$(make_consumer submodule)"
advance_origin submodule 1
git init -q -b main "$c/.claude/cerebro"
git_q -C "$c/.claude/cerebro" add -A
git_q -C "$c/.claude/cerebro" commit -q -m "cerebro"
echo "# work in progress" >> "$c/.claude/cerebro/scripts/launch-preflight"
before="$(head_of "$c")"
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "submodule: expected exit 2, got $status"
grep -q "uncommitted changes" <<<"$out" || fail "submodule: expected a message naming the changes, got: $out"
[[ "$(head_of "$c")" == "$before" ]] || fail "submodule: HEAD moved"
grep -q "work in progress" "$c/.claude/cerebro/scripts/launch-preflight" \
  || fail "submodule: the in-progress edit was lost"
pass "a dirty submodule is refused, and its work survives"

# --- no remote is not a failure ----------------------------------------------------------------------
#
# Offline, or a fresh clone with no origin, is not a staleness this can fix.
c="$(make_consumer noremote)"
git -C "$c" remote remove origin
before="$(head_of "$c")"
run_preflight "$c" || fail "no remote: expected exit 0"
[[ "$(head_of "$c")" == "$before" ]] || fail "no remote: HEAD moved"
pass "a checkout with no remote launches"

# --- a consumer whose branch is not main is still guarded (ah-qled.3) ----------------------------
#
# The bead itself. On a `trunk` consumer the old `fetch origin main` failed, `|| true` swallowed it,
# $target stayed empty and the WHOLE staleness block was skipped - so the launch succeeded and
# ah-puoj's guarantee had quietly stopped holding, with nothing on stderr to say so.
c="$(make_consumer trunkclean trunk)"
advance_origin trunkclean 2
run_preflight "$c" || fail "trunk: expected exit 0"
[[ "$(head_of "$c")" == "$(origin_head_of "$c")" ]] \
  || fail "trunk: expected HEAD to be fast-forwarded to origin/trunk"
pass "a behind checkout on a trunk consumer is fast-forwarded"

# --- the wrong-branch refusal names the resolved branch, not main ---------------------------------
#
# The messages are prose a human acts on: a `trunk` consumer told to "switch back to main" is being
# sent to a branch that does not exist.
c="$(make_consumer trunkbranch trunk)"
advance_origin trunkbranch 1
git -C "$c" switch -q -c wip
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "trunk branch: expected exit 2, got $status"
grep -q "trunk" <<<"$out" || fail "trunk branch: expected the message to name trunk, got: $out"
grep -q "not main" <<<"$out" && fail "trunk branch: the message still says main, got: $out"
pass "the wrong-branch refusal names the resolved branch"

# --- fetch succeeded, but there is no such branch: SAY SO ------------------------------------------
#
# The half a rename alone would leave undone. A consumer declaring a `default_branch` its origin does
# not have looks exactly like a current checkout today - which is the silent-guard failure again, one
# layer further in.
c="$(make_consumer missingbranch main)"
echo "default_branch nosuchbranch" > "$c/.cerebro/project.conf"
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "missing branch: expected the launch to proceed, got $status"
grep -q "nosuchbranch" <<<"$out" \
  || fail "missing branch: expected a line on stderr naming the branch, got: $out"
pass "a branch that does not exist on origin is reported rather than skipped in silence"

# --- an unreachable origin stays quiet -------------------------------------------------------------
#
# The other half of that pair, and asserting one without the other proves nothing: OFFLINE IS NOT
# STALENESS, so this must stay as silent as it has always been.
c="$(make_consumer unreachable main)"
git -C "$c" remote set-url origin "$work_dir/no-such-origin.git"
# The one case here that asserts on the WHOLE of stderr, so it is also the one that has to declare
# an agent_cli: without a declaration `agent-cli` says so on every call (cb-d59.2, Q4), which is a
# line about the CLI rather than about staleness and would make this case assert the wrong thing.
printf 'agent_cli claude\n' > "$c/.cerebro/project.conf"
before="$(head_of "$c")"
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "unreachable: expected exit 0, got $status"
[[ -z "$out" ]] || fail "unreachable: expected no output - offline is not staleness - got: $out"
[[ "$(head_of "$c")" == "$before" ]] || fail "unreachable: HEAD moved"
pass "an unreachable origin stays quiet"

# --- a standalone clone is untouched -------------------------------------------------------------------
standalone="$work_dir/x/cerebro"
mkdir -p "$work_dir/x"
copy_cerebro_into "$standalone"
PATH="$stub_dir:$PATH" bash "$standalone/scripts/launch-preflight" planner Xavier \
  || fail "standalone: expected exit 0"
pass "a standalone clone is untouched"

# --- an implementer with no fast gate is refused (ah-qled.7.1) ------------------------------------
#
# The bead: implement-bead names no tool any more, so an implementer with no declared and no
# detectable gate has nothing to run before it opens a PR - and an agent with nothing to run
# improvises. A loud refusal at launch beats a green report nobody earned.
c="$(make_consumer nogate)"
set +e
out="$(run_preflight "$c" implementer Cyclops 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no gate: expected exit 2, got $status"
grep -q "gate_fast" <<<"$out" || fail "no gate: expected the message to name gate_fast, got: $out"
grep -q "submodule is behind" <<<"$out" && fail "no gate: the message blames the submodule, got: $out"
pass "an implementer with no fast gate is refused, and the message names the gate"

# --- a planner with no fast gate still launches ----------------------------------------------------
#
# A planner, a verifier or the orchestrator has no gate to run; refusing them would take the whole
# fleet down over a key that does not concern them.
c="$(make_consumer nogateplanner)"
run_preflight "$c" planner Xavier || fail "no gate, planner: expected exit 0"
pass "a planner with no fast gate still launches"

# --- an implementer with a declared gate launches --------------------------------------------------
c="$(make_consumer withgate)"
echo "gate_fast make check" > "$c/.cerebro/project.conf"
run_preflight "$c" implementer Cyclops || fail "declared gate: expected exit 0"
pass "an implementer whose project declares a gate launches"

# --- a declaration left at the retired .claude/ path is refused, before anything else (cb-epr) ----
#
# The declarations moved to `.cerebro/`. This is the earliest and friendliest place to catch a
# consumer that bumped the submodule past that move: it is also the ONLY place that can catch a
# stray `cerebro-traps.md`, which no script reads at all - a planner and an implementer read it as
# prose, so a file left behind would simply go unread, in silence, for ever.
#
# It refuses even when the new file exists too: two copies of a declaration is exactly the ambiguity
# worth one `rm` before anything starts.
for pair in "cerebro-project.conf:project.conf" "cerebro-roster:roster.conf" "cerebro-traps.md:traps.md"; do
  old_name="${pair%%:*}"
  new_name="${pair#*:}"
  c="$(make_consumer "old-${new_name%%.*}")"
  echo "gate_fast make check" > "$c/.cerebro/project.conf"
  : > "$c/.claude/$old_name"
  set +e
  out="$(run_preflight "$c" implementer Cyclops 2>&1)"
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "old path $old_name: expected exit 2, got $status"
  grep -q "mv .claude/$old_name .cerebro/$new_name" <<<"$out" \
    || fail "old path $old_name: expected the mv line naming both paths, got: $out"
  pass "a $old_name left at the retired .claude/ path is refused at launch"
done

# --- implement-bead names no tool -------------------------------------------------------------------
#
# The bead's own acceptance: the skill an implementer reads in a Python project must not tell it to
# run pnpm or cargo. The disk preflight was the last of them and became a cerebro script of its own
# in ah-qled.7.2, so there is nothing left to exempt.
hits="$(grep -nE "pnpm|cargo" "$repo_root/skills/implement-bead/SKILL.md" || true)"
[[ -z "$hits" ]] || fail "implement-bead still names a tool: $hits"
pass "implement-bead names no build tool at all"

# --- cerebro's own checkout, mounted in itself, launches (cb-i3l.1) -------------------------------
#
# The self-consumer is not a variant of make_consumer: there is no submodule under .claude, because
# the harness IS the checkout. What .claude/cerebro holds is a committed symlink back up to the
# repository root, and the whole point of this case is that a launcher run through that symlink
# reaches the end of the preflight - consumer-root answers, the role's agent file is found through
# the mount, and the sync writes links that resolve.
self_origin="$work_dir/self-origin.git"
self_consumer="$work_dir/self"
git init -q --bare -b main "$self_origin"
git init -q -b main "$work_dir/self-seed"
copy_cerebro_into "$work_dir/self-seed"
mkdir -p "$work_dir/self-seed/.claude"
ln -s ".." "$work_dir/self-seed/.claude/cerebro"
git_q -C "$work_dir/self-seed" add -A
git_q -C "$work_dir/self-seed" commit -q -m "cerebro, mounted in itself"
git_q -C "$work_dir/self-seed" push -q "$self_origin" main
git clone -q "$self_origin" "$self_consumer"

run_preflight "$self_consumer" planner Xavier || fail "self-consumer: expected exit 0"
[[ -L "$self_consumer/.claude/agents/planner.md" ]] \
  || fail "self-consumer: expected .claude/agents/planner.md to be a link"
[[ -f "$self_consumer/.claude/agents/planner.md" ]] \
  || fail "self-consumer: the agent link does not resolve"
[[ -f "$self_consumer/.claude/skills/plan-bead/SKILL.md" ]] \
  || fail "self-consumer: the skill link does not resolve to a SKILL.md"
pass "cerebro mounted in its own checkout passes the preflight and gets working links"

# --- an agent CLI this cerebro cannot run is refused, by agent-cli rather than by this script -----
#
# The provider is `scripts/agent-cli`'s answer since cb-d59.2, and the preflight asks rather than
# spelling `claude` itself. A declaration it cannot run must therefore stop a launch here, where the
# `claude`-missing refusal already does.
c="$(make_consumer wrong-cli)"
printf 'agent_cli emacs-doctor\n' > "$c/.cerebro/project.conf"
set +e
out="$(run_preflight "$c" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "wrong-cli: expected exit 2, got $status"
grep -q "is not an agent CLI cerebro knows" <<<"$out" \
  || fail "wrong-cli: expected agent-cli's own sentence, got: $out"
pass "launch-preflight refuses when the consumer declares an agent CLI cerebro cannot run"

suite_passed
