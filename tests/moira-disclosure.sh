#!/usr/bin/env bash
#
# Proves Moira's public disclosure line takes the project's name from `project-conf project_name`
# rather than carrying one consumer's name in a shared submodule (ah-qled.10.2, cerebro#58 §3).
#
# This is the ONE place cerebro's coupling reaches people outside the fleet: the line opens every
# comment Moira posts to a PUBLIC GitHub issue. So two things are asserted here, and they pull in
# opposite directions:
#
#   - the NAME comes from the consumer, and no consumer's name is written into this repository;
#   - the DISCLOSURE ITSELF is product and survives untouched, including when no name is declared.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/moira-disclosure.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
moira="$repo_root/agents/user-feedback.md"

# The prose in this file is wrapped for reading, so a sentence assertion is made against a
# whitespace-flattened copy: a rule that only holds while a sentence stays on one line is a rule
# that breaks the next time somebody reflows a paragraph.
flat() { tr '\n' ' ' < "$moira" | tr -s ' '; }

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# --- the reader really does answer with the consumer's name, and never fails without one ---
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

consumer="$work_dir/repo"
mkdir -p "$consumer/.claude/cerebro/scripts"
git init -q "$consumer"
git -C "$consumer" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
done
conf="$consumer/.claude/cerebro-project.conf"
project_conf="$consumer/.claude/cerebro/scripts/project-conf"

printf 'project_name   Some Other Project\n' > "$conf"
out="$(cd "$consumer" && "$project_conf" project_name 2>/dev/null)"
[[ "$out" == "Some Other Project" ]] || fail "project_name: expected 'Some Other Project', got '$out'"
pass "project_name resolves to the consumer's own name"

printf 'default_branch main\n' > "$conf"
set +e
out="$(cd "$consumer" && "$project_conf" project_name "this project" 2>/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "absent project_name: the reader must never fail its caller"
[[ "$out" == "this project" ]] || fail "absent project_name: expected the fallback, got '$out'"
pass "an absent project_name falls back to the default rather than failing the caller"

# ---------------------------------------------------------------------------
# The prose. There is no renderer here: Moira is an agent reading an
# instruction, so the assertions are on what the instruction tells her.
# ---------------------------------------------------------------------------

# --- no consumer's name survives in the file at all ---
if grep -n 'Atlantis HUD' "$moira" >/dev/null 2>&1; then
  grep -n 'Atlantis HUD' "$moira" >&2
  fail "one consumer's project name still stands in Moira's prose"
fi
pass "no consumer's project name remains in agents/user-feedback.md"

# --- the disclosure sentence itself is untouched: it is product, not coupling ---
disclosure_count="$(grep -cF '_Written by **Moira**, an AI agent that triages issues for' "$moira")"
[[ "$disclosure_count" -ge 3 ]] \
  || fail "the disclosure: expected it at all three comment sites, found $disclosure_count"
grep -qF 'Replying here reaches a human maintainer.' "$moira" \
  || fail "the disclosure: the promise that a reply reaches a person is gone"
pass "the disclosure sentence survives at every comment site"

# --- every disclosure site carries the SAME placeholder, so the two comment kinds cannot
# --- disagree about the consumer's own name ---
placeholder='_Written by **Moira**, an AI agent that triages issues for {project name}. Replying here reaches a human maintainer._'
placeholder_count="$(grep -cF "$placeholder" "$moira")"
[[ "$placeholder_count" -eq "$disclosure_count" ]] \
  || fail "the name: $placeholder_count of $disclosure_count disclosure sites read the placeholder"
pass "the acknowledgement and the status comment name the project identically"

# --- and the file says where that value comes from: a placeholder with no instruction to
# --- resolve it is worse than the hardcoded word it replaced ---
grep -q 'project-conf project_name\|project_conf project_name' "$moira" \
  || fail "the name: nothing tells Moira to read project-conf project_name"
pass "Moira is told to read the name from project-conf project_name"

# --- with no name declared the line is still a whole, natural sentence, and still discloses ---
flat | grep -qF 'triages issues for this project' \
  || fail "the fallback: 'this project' must be spelled out as it will read to a reporter"
pass "the fallback reads as a sentence, and still discloses"

# --- the navigator chose the SILENT fallback on 2026-08-22: no warning, no log, no escalation ---
fallback_block="$(flat | grep -o 'If no name is declared.\{0,250\}')"
if grep -qi 'warn\|flag it\|tell the navigator\|log it' <<<"$fallback_block"; then
  fail "the fallback: a warning was added; the navigator chose the silent fallback deliberately"
fi
pass "nothing is warned when the key is absent"

# --- the long-line rule is about the HEREDOCS, so it holds for a name of any length ---
grep -qi 'hard-wrap' "$moira" || fail "the wrap rule: the never-hard-wrap rule is gone"
if grep -n '"Atlantis" on one line' "$moira" >/dev/null 2>&1; then
  fail "the wrap rule: the Atlantis/HUD example re-couples the rule to one project"
fi
pass "the long-line rule is stated about the heredocs, not about a name"

# --- what must not change ---
grep -qF '<!-- moira-ack -->' "$moira" || fail "the ack marker is gone"
grep -qi 'once, ever' "$moira" || fail "the ack marker's once-ever rule is gone"
grep -qF '<!-- beads-state:' "$moira" || fail "the beads-state markers are gone"
grep -q 'Adapt the wording' "$moira" || fail "the instruction to adapt the wording is gone"
pass "the ack marker, its once-ever rule, the beads-state markers and adapt-the-wording all stand"

# --- ah-qled.10.3's half of :138 is left alone: that bead takes the verb, this one the name ---
grep -q 'actually playing' "$moira" \
  || fail "the shared sentence: 'playing' belongs to ah-qled.10.3 and must be left untouched"
pass "the audience verb at :138 is left for ah-qled.10.3"

echo "all moira-disclosure tests passed"
