#!/usr/bin/env bash
#
# Proves the contract between cerebro and a project that uses it (ah-qled.10.5):
#
#   1. cerebro SHIPS the document it requires. The skills refuse to merge without a section
#      called "Four Eye Principle" in the consumer's root CLAUDE.md, and until this bead offered
#      no template for it — a new consumer discovered the requirement by an agent refusing to
#      merge. templates/consumer-CLAUDE.md is that template, and this test is what says so when
#      the template and the requirement ever disagree.
#
#   2. The prompts say WHOSE CLAUDE.md they mean. From inside a submodule with two files of that
#      name, "CLAUDE.md's Four Eye Principle" is ambiguous, and an agent reading cerebro's own
#      finds no such section.
#
#   3. No consumer's scar tissue is carried in cerebro's prompts. A trap naming a browser engine,
#      a job or a path a consumer need not have belongs in that consumer's own
#      .claude/cerebro-traps.md, which both traps sections point at.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/consumer-contract.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# --- 1. the template exists and carries the exact heading the skills require ---

template="templates/consumer-CLAUDE.md"
[[ -f "$template" ]] || fail "$template does not exist; the skills require a section cerebro does not ship"

grep -q '^## Four Eye Principle$' "$template" \
  || fail "$template has no '## Four Eye Principle' heading — the exact section the skills require"

grep -qi "starting point\|meant to be edited\|expected to be edited" "$template" \
  || fail "$template must say about itself that it is a starting point to be edited, not a fixed policy"

pass "templates/consumer-CLAUDE.md ships the Four Eye Principle section the skills require"

# --- 2. every mention of the required section names whose CLAUDE.md it is in ---

# Line wrapping is prose's business, so the window is the joined text either side of the phrase
# rather than the line it happens to sit on.
bad=0
for f in $(grep -rl "Four Eye Principle" skills/ agents/ CLAUDE.md || true); do
  while IFS= read -r m; do
    echo "$m" | grep -qi "consumer" && continue
    echo "$f: $m" >&2
    bad=1
  done < <(tr '\n' ' ' < "$f" | grep -oE '.{0,200}Four Eye Principle.{0,80}' || true)
done
[[ $bad -eq 0 ]] || fail "every reference must say the CONSUMER's root CLAUDE.md"

pass "every Four Eye Principle reference names the consumer's root CLAUDE.md"

# --- 3. no consumer's traps in cerebro's prompts, and both sections point at the consumer file ---

if grep -rniE "webkit|vite preview|service worker|packages/shared" skills/ agents/ >/dev/null 2>&1; then
  grep -rniE "webkit|vite preview|service worker|packages/shared" skills/ agents/ >&2
  fail "one project's traps are being carried in cerebro's prompts; they belong in that project's .claude/cerebro-traps.md"
fi

pass "no consumer-specific trap remains in skills/ or agents/"

for f in skills/implement-bead/SKILL.md skills/plan-bead/SKILL.md; do
  grep -q "cerebro-traps.md" "$f" \
    || fail "$f never tells the reader to read the consumer's .claude/cerebro-traps.md"
done

pass "both traps sections read the consumer's own traps file"

# --- 4. the universal traps were KEPT, not emptied ---

for phrase in "preview server" "stale lease" "conflicted head"; do
  grep -qi "$phrase" skills/implement-bead/SKILL.md \
    || fail "implement-bead lost the universal trap about the $phrase; this bead is a split, not a deletion"
done

pass "implement-bead keeps every universal trap"

# --- 5. Forge proposes a traps entry and never writes one ---

grep -q "cerebro-traps.md" agents/architect.md \
  || fail "agents/architect.md never mentions the consumer's traps file"

grep -q "138" agents/architect.md \
  || fail "agents/architect.md must name the 138-of-138 figure so the bar for a proposal is calibrated"

pass "Forge proposes traps entries against a calibrated bar"

echo "all consumer-contract assertions passed"
