#!/usr/bin/env bash
#
# Proves the fleet's own prose no longer assumes its reader is a player of a game
# (ah-qled.10.3, cerebro#58 §4).
#
# Two treatments, on the navigator's decision of 2026-08-22:
#
#   * every agent, doc, script and skill - and README.md, the front door - EXCEPT
#     skills/release-notes/SKILL.md uses neutral
#     prose - "the audience" - and reads no key and substitutes nothing;
#   * skills/release-notes/SKILL.md alone reads `project-conf audience_noun` once, at the top,
#     and then uses the literal word throughout, because it produces the navigator's public
#     output and "what a player would say where they were" does work that "what the audience
#     would say" loses.
#
# The word itself is spelled by concatenation below so this file never matches its own grep.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion.
# Run from the submodule root:
#
#     bash tests/audience-noun.sh

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

noun="play""er"
verb="play""ing"
self="tests/$(basename "${BASH_SOURCE[0]}")"

# --- the noun survives only where the navigator decided it should ---
hits="$(grep -rniI --exclude="$(basename "$self")" --exclude-dir=release-notes \
          -e "$noun" agents/ docs/ scripts/ tests/ skills/ README.md || true)"
[[ -z "$hits" ]] || fail "neutral prose still names a $noun:
$hits"
pass "no file outside release-notes names the audience as a $noun"

# --- the verb belongs to nobody by default, so this bead removed it entirely ---
hits="$(grep -rniI --exclude="$(basename "$self")" \
          -e "$verb" agents/ docs/ scripts/ tests/ skills/ README.md || true)"
[[ -z "$hits" ]] || fail "the verb '$verb' survives:
$hits"
pass "the verb '$verb' occurs nowhere"

# --- release-notes keeps the literal word, and says where it comes from ---
rn="skills/release-notes/SKILL.md"
grep -q "project-conf audience_noun" "$rn" \
  || fail "$rn does not tell its reader to read the key"
pass "release-notes reads audience_noun, once, where the notes begin"

grep -qi -- "$noun" "$rn" || fail "$rn no longer uses this project's literal word"
pass "release-notes uses the literal word"

grep -q '"user"' "$rn" || fail "$rn does not state the default when the key is unset"
pass "release-notes states the 'user' default"

grep -qi "irregular" "$rn" \
  || fail "$rn does not state the irregular-plural limitation of forming +s from a singular key"
pass "release-notes states the +s / +'s rule and its irregular-plural limitation"

# --- the key resolves, and defaults, through the existing reader ---
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
consumer="$work_dir/repo"
mkdir -p "$consumer/.claude/cerebro/scripts"
git init -q "$consumer"
git -C "$consumer" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
done
project_conf="$consumer/.claude/cerebro/scripts/project-conf"
conf="$consumer/.cerebro/project.conf"
mkdir -p "$consumer/.cerebro"

printf 'audience_noun  operator\n' > "$conf"
out="$("$project_conf" audience_noun user 2>/dev/null)"
[[ "$out" == "operator" ]] || fail "declared key: expected 'operator', got '$out'"
pass "a declared audience_noun wins"

: > "$conf"
out="$("$project_conf" audience_noun user 2>/dev/null)"
[[ "$out" == "user" ]] || fail "absent key: expected the 'user' default, got '$out'"
pass "an absent audience_noun falls back to 'user'"

echo "all audience-noun assertions passed"
