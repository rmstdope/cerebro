#!/usr/bin/env bash
#
# Proves the agent prompts and skills carry no citation a consumer cannot resolve (<bead-id>).
#
# The prompts used to teach with this project's examples: real bead ids as parenthetical
# citations, real bead titles in worked examples, and one game's vocabulary in the rules
# themselves. A consumer's agent reads all of that in every session and can check none of it.
#
# What this suite does NOT assert, deliberately:
#   * the ~475 ids in emacs/ and tests/ - load-bearing reasons in code comments, read by whoever
#     is editing that line rather than carried into a session.
#   * skills/release-notes/SKILL.md - exempt in full by the navigator's decision: its job is
#     teaching someone to write good notes, and a concrete worked example teaches better than an
#     abstract one.
#
# It also forbids the literal name of the project cerebro was extracted from, in that same
# prose set plus README.md - the front door, which no other suite scans.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/prose-decoupling.sh

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

# --- what the prompts carry: every file an agent session reads, minus the exempt one ---
prose_files() {
  # every file an agent session is given, and only those. `docs/cerebro-jobs.md` and
  # `docs/decisions.md` are cerebro-side records of which bead decided what: they exist precisely
  # so the provenance has somewhere to live that no session carries.
  { find agents skills -name '*.md' ! -path 'skills/release-notes/*'
    echo docs/agent-workflow.md
  } | sort
}

# --- no bead id survives in prose an agent is given ---
hits="$(prose_files | xargs grep -noE '\bah-[a-z0-9]{3,}(\.[0-9]+)*\b' || true)"
[ -z "$hits" ] || fail "bead ids remain in agent prose - a consumer cannot resolve these:
$hits"
pass "no bead id remains in the prompts or skills"

# --- the provenance still exists, cerebro-side ---
[ -f docs/decisions.md ] || fail "docs/decisions.md is missing - the ids moved but the evidence went with them"
grep -qE '\bah-[a-z0-9]{3,}' docs/decisions.md \
  || fail "docs/decisions.md records no bead id, so nothing was preserved"
pass "docs/decisions.md records which bead established which rule"

# --- and it is carried by nothing: a prompt that loads it undoes the whole point ---
loaders="$(prose_files | xargs grep -nl 'decisions\.md' || true)"
[ -z "$loaders" ] || fail "docs/decisions.md is referenced by prose an agent reads:
$loaders"
pass "docs/decisions.md is loaded by nothing"

# --- one project's vocabulary is not the rules' vocabulary ---
domain="$(prose_files | xargs grep -noEi '\bhexe?s?\b|\bwasm\b|\.rep\b|\bfaction\b|\bhexMapModel\b' || true)"
[ -z "$domain" ] || fail "one game's vocabulary is still teaching the rules:
$domain"
pass "domain vocabulary appears only in the exempt release-notes skill"

# --- the project cerebro grew up in is named nowhere a session reads, nor on the front door ---
# README.md gets its own entry: it is not prose an agent is given, so prose_files rightly
# excludes it, but it is the repository's front door and the audit (cerebro#58) found the
# name there too. docs/decisions.md deliberately keeps the name: it is the provenance file
# nothing loads, and prose_files already excludes it.
hits="$({ prose_files; echo README.md; } | xargs grep -noi 'atlantis-hud' || true)"
[ -z "$hits" ] || fail "the project cerebro was extracted from is still named in prose:
$hits"
pass "no prose an agent reads, and not README.md, names atlantis-hud"

echo "all prose-decoupling assertions passed"
