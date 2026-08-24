#!/usr/bin/env bash
#
# Proves the bead board stays Dolt-only: no JSONL snapshot of it is tracked in git, none can be,
# and the decision is written where the next person will look.
#
# Beads sync here through the Dolt remote and `export.auto` is off (beads' own default; the
# `export:` block in .beads/config.yaml is commented out). The project cerebro was extracted from
# tracks a `.beads/issues.jsonl` anyway, refreshed at push time by a TypeScript gate this
# repository has nothing to hang on — so the question of whether the board should be readable from
# git had to be answered here rather than inherited.
#
# The navigator answered it on 2026-08-24 (bead cb-4yo): it should not. The Dolt remote is the one
# board mechanism — a clone gets the code, `bd sync` gets the work. The rejected alternative was a
# tracked snapshot refreshed by a pre-push hook: `githooks/install.sh` is optional by design, so
# the snapshot silently goes stale for any clone that never installed it — exactly the stale-board
# failure the throttled auto-export caused elsewhere — and every fleet push would rewrite one
# shared file, giving recurring conflicts across parallel worktrees.
#
# This suite is what distinguishes "we decided not to track it" from "nobody ever thought about
# it": enabling an export later turns the gate red instead of quietly re-opening the question.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/bead-board-untracked.sh

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

# --- no JSONL snapshot of the board is tracked ---
hits="$(git ls-files -- '.beads/*.jsonl')"
[ -z "$hits" ] || fail "a JSONL board snapshot is tracked - the board is Dolt-only by decision (cb-4yo):
$hits"
pass "no .beads/*.jsonl is tracked"

# --- and none can be: a stray bd export is ignored before it reaches a commit ---
git check-ignore -q .beads/issues.jsonl \
  || fail ".beads/issues.jsonl is not git-ignored, so a stray 'bd export' could be committed"
git check-ignore -q .beads/events.jsonl \
  || fail ".beads/events.jsonl is not git-ignored, so a stray events export could be committed"
pass "a stray JSONL export cannot land in a commit"

# --- the decision is written where the next person will look ---
grep -qF '.beads/*.jsonl' CLAUDE.md \
  || fail "CLAUDE.md does not state the .beads/*.jsonl decision - the next person re-opens it"
pass "CLAUDE.md states the board is Dolt-only"
