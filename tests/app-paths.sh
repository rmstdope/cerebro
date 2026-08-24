#!/usr/bin/env bash
#
# Proves scripts/app-paths is the ONE place "which paths are this project's application" is
# answered (ah-qled.6), and that its absence is LOUD.
#
# The defect this bead ends is the quietest one in the epic: `^(packages|crates|apps)/` was written
# out seven times across six files, so a consumer whose application lives in `src/` had every bead
# classified as invisible — no error, empty release notes, every verification skipped. Replacing
# that with a default of "matches nothing" would reproduce it exactly, which is why an unset
# `app_paths` must REFUSE TO CLASSIFY rather than answer.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/app-paths.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# --- a throwaway consumer repo, the way tests/project-conf.sh builds one ---
consumer="$(consumer_new repo --link consumer-root project-conf app-paths)"
conf="$consumer/.cerebro/project.conf"
mkdir -p "$consumer/.cerebro"
app_paths="$consumer/.claude/cerebro/scripts/app-paths"

printf 'project_name Atlantis HUD\napp_paths      ^(packages|crates|apps)/\n' > "$conf"

# --- the pattern is read whole, with every metacharacter intact ---
out="$("$app_paths" 2>/dev/null)"
[[ "$out" == '^(packages|crates|apps)/' ]] \
  || fail "the pattern: expected '^(packages|crates|apps)/' intact, got '$out'"
pass "the configured pattern is printed whole, metacharacters intact"

# --- classification: a path under an application directory ---
out="$("$app_paths" --classify packages/shared/src/x.ts 2>/dev/null)"
[[ "$out" == "application" ]] || fail "classify application: got '$out'"
pass "a path under an application directory classifies as application"

# --- classification: everything else is invisible to the audience ---
for p in .claude/agents/planner.md docs/ui/x.html scripts/release.sh .github/workflows/ci.yml; do
  out="$("$app_paths" --classify "$p" 2>/dev/null)"
  [[ "$out" == "invisible" ]] || fail "classify invisible: $p got '$out'"
done
pass "harness, docs, scripts and CI paths classify as invisible"

# --- several paths at once: ONE application path makes the whole change application-touching ---
out="$("$app_paths" --classify docs/x.md crates/core/src/lib.rs 2>/dev/null)"
[[ "$out" == "application" ]] || fail "classify many: one application path must win, got '$out'"
pass "one application path among many makes the change application-touching"

# --- the anchor is honoured: `^` means the path must START there ---
out="$("$app_paths" --classify vendor/packages/x.ts 2>/dev/null)"
[[ "$out" == "invisible" ]] || fail "anchor: expected the ^ to bind, got '$out'"
pass "the pattern is anchored as written, not matched anywhere in the path"

# --- THE POINT OF THE BEAD: an unset app_paths refuses to classify, loudly ---
printf 'project_name Atlantis HUD\n' > "$conf"

set +e
out="$("$app_paths" --classify packages/shared/src/x.ts 2>/dev/null)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "unset key: expected a non-zero exit, got 0 — the silent default is back"
[[ -z "$out" ]] || fail "unset key: expected NOTHING on stdout, got '$out'"
pass "an unset app_paths refuses to classify: non-zero, and nothing on stdout"

err="$("$app_paths" --classify packages/shared/src/x.ts 2>&1 >/dev/null || true)"
echo "$err" | grep -q "app_paths" || fail "unset key: expected app_paths named on stderr, got: $err"
echo "$err" | grep -qi "cannot classify" \
  || fail "unset key: expected it to say it cannot classify, got: $err"
pass "an unset app_paths says on stderr that it cannot classify, and names the key"

set +e
out="$("$app_paths" 2>/dev/null)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "unset key, bare: expected a non-zero exit, got 0"
[[ -z "$out" ]] || fail "unset key, bare: expected nothing on stdout, got '$out'"
pass "an unset app_paths is non-zero when the pattern itself is asked for"

# --- a usage error is distinguishable from "cannot classify" ---
printf 'app_paths ^(packages|crates|apps)/\n' > "$conf"
set +e
out="$("$app_paths" --classify 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "no paths: expected a non-zero exit, got 0"
echo "$out" | grep -q "usage:" || fail "no paths: expected a usage message, got: $out"
pass "--classify with no path is a usage error"

# --- the explanation never reaches stdout, where it would poison a substitution ---
out="$("$app_paths" 2>/dev/null)"
[[ "$out" == '^(packages|crates|apps)/' ]] || fail "stdout purity: got '$out'"
pass "stdout carries the answer alone"

# ---------------------------------------------------------------------------
# The prose that used to carry the copies. These assertions are the sweep: a
# re-introduced literal is exactly how seven copies happened the first time.
# ---------------------------------------------------------------------------

# --- no literal copy of one project's application paths survives anywhere ---
if grep -rn 'packages|crates|apps' "$repo_root/agents" "$repo_root/skills" "$repo_root/CLAUDE.md" \
     >/dev/null 2>&1; then
  grep -rn 'packages|crates|apps' "$repo_root/agents" "$repo_root/skills" "$repo_root/CLAUDE.md" >&2
  fail "a literal ^(packages|crates|apps)/ survives in the prose"
fi
pass "no literal application-path regex remains in agents/, skills/ or CLAUDE.md"

# --- the never-edit rule reads identically in all five places ---
rule="you are editing the project's application paths"
for f in agents/architect.md agents/verifier.md agents/planner.md agents/user-feedback.md CLAUDE.md; do
  tr '\n' ' ' < "$repo_root/$f" | tr -s ' ' | grep -qF "$rule" \
    || fail "the never-edit rule: $f does not read as the one shared rule"
done
pass "the never-edit rule reads identically in all five places"

# --- and every one of them names how to get the answer ---
for f in agents/architect.md agents/verifier.md agents/planner.md agents/user-feedback.md CLAUDE.md; do
  grep -q "app-paths\|app_paths" "$repo_root/$f" \
    || fail "the never-edit rule: $f names no way to find the application paths"
done
pass "each of the five names app-paths, so an agent can find the answer"

# --- emacs/ is cerebro's OWN source, not the consumer's application: it survives as its own
# --- clause in exactly the two files whose rule always covered it, and appears in neither of the
# --- other three. Folding it into app_paths would declare the harness part of every consumer's app.
for f in agents/architect.md CLAUDE.md; do
  grep -q 'emacs/' "$repo_root/$f" || fail "emacs/: $f must still forbid cerebro's own elisp"
done
for f in agents/verifier.md agents/planner.md agents/user-feedback.md; do
  grep -q 'emacs/' "$repo_root/$f" \
    && fail "emacs/: $f must not newly forbid cerebro's own source"
done
pass "emacs/ stays its own clause, in architect.md and CLAUDE.md only"

# --- the verbatim workspace map of one consumer is gone ---
if grep -rn 'core-persistence\|core-wasm\|apps/desktop' "$repo_root/agents" "$repo_root/skills" \
     >/dev/null 2>&1; then
  fail "one consumer's workspace members are still written out in the agent prose"
fi
pass "no consumer's workspace map remains in agents/ or skills/"

# --- the three classification sites now say how to get the answer ---
for f in agents/reviewer.md agents/verifier.md skills/release-notes/SKILL.md; do
  grep -q 'app-paths' "$repo_root/$f" \
    || fail "classification: $f must name scripts/app-paths"
done
pass "the three classification sites name scripts/app-paths"

echo "all app-paths tests passed"
