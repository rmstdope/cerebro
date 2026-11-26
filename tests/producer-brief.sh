#!/usr/bin/env bash
#
# Proves `scripts/producer-brief <Name> <id>` (cb-pe3y): a builder's startup reads, done once by
# `launch` before the session exists. It pulls and fetches, checks the bead is claimed for the
# agent and prints one brief; it writes no state file, a read that fails says so in the brief and
# never reads as an empty answer, and an advisory step never decides the exit status.
#
#     bash tests/producer-brief.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --origin --link producer-brief consumer-root default-branch project-conf)"
state="$consumer/.cerebro/state"
tree="$consumer/.cerebro/worktrees/cb-a"
mkdir -p "$state"
stub="$work_dir/stub"
mkdir -p "$stub"

# A stub `bd`: one argv line per call in bd.log; `show` answered from show.json; a pull that can
# fail, or hang and leave a marker only if it was allowed to finish.
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
args=()
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -C|--actor) skip=1 ;; *) args+=("$a") ;; esac
done
case "${args[0]}" in
  dolt) if [ -n "${BD_PULL_SLEEP:-}" ]; then sleep "$BD_PULL_SLEEP"; : > "$STUB_DIR/pull-finished"; fi
        exit "${BD_PULL_EXIT:-0}" ;;
  show) [ "${BD_SHOW_EXIT:-0}" = 0 ] || exit "$BD_SHOW_EXIT"
        cat "$STUB_DIR/show.json" ;;
esac
exit 0
STUB
chmod +x "$stub/bd"
# A stub `git' in its own directory, put on PATH only by the case that needs it: the one call named
# by GIT_FAIL fails, every other call is the real one.
gitstub="$work_dir/gitstub"
mkdir -p "$gitstub"
real_git="$(command -v git)"
cat > "$gitstub/git" <<STUB
#!/usr/bin/env bash
case "\$*" in *"\$GIT_FAIL"*) exit 128 ;; esac
exec "$real_git" "\$@"
STUB
chmod +x "$gitstub/git"
export STUB_DIR="$stub"
export PATH="$stub:$PATH"

bead_json() {  # <status> <assignee>
  jq -n --arg st "$1" --arg as "$2" '[{
    id: "cb-a", title: "Brief the builders", status: $st, assignee: $as, priority: 3,
    labels: ["ux:none", "planned"], external_ref: "gh-7",
    description: "Every session starts by reading the same facts.",
    acceptance_criteria: "A builder starts with them. See docs/ui/shared-sheet.html.",
    design: "## Context\nThe design of record.",
    notes: "## Sent back to the UX stage\nSee docs/ui/gone.html."
  }]' > "$stub/show.json"
}

# What shipped, on origin's default branch: a commit naming the bead and one naming another.
up="$work_dir/repo-up"
mkdir -p "$up/docs/ui"
echo sheet > "$up/docs/ui/shared-sheet.html"
echo mock > "$up/docs/ui/cb-a-shape.html"
echo other > "$up/docs/ui/cb-ab-other.html"
git_q -C "$up" add docs
git_q -C "$up" commit -q -m "docs(cb-z): drawings"
echo one >> "$up/file.txt"
git_q -C "$up" commit -q -am "feat(cb-a): the first increment (#3)"
echo two >> "$up/file.txt"
git_q -C "$up" commit -q -am "feat(cb-ab): somebody else's"
git_q -C "$up" push -q origin HEAD

reset() {
  rm -f "${stub:?}/bd.log" "${stub:?}/pull-finished" "${state:?}/Rogue.state.json" "${state:?}/Rogue.handover"
  bead_json in_progress Rogue
  printf 'gate_fast bash tests/fast\ngate_full bash tests/full\nprewarm cargo build\nnavigator_gates plan merge\n' \
    > "$consumer/.cerebro/project.conf"
  printf '# Traps\n\n## A trap paid for\nMind the gap.\n' > "$consumer/.cerebro/traps.md"
}

run_brief() { (cd "$consumer" && .cerebro/cerebro/scripts/producer-brief "$@"); }

has() { grep -qF -- "$1" <<<"$out" || fail "producer-brief: ${2:-the brief} carries '$1', got: $out"; }
hasnt() { if grep -qF -- "$1" <<<"$out"; then fail "producer-brief: ${2:-the brief} does not carry '$1', got: $out"; fi; }

# --- the bead is the agent's ---------------------------------------------------------------------

reset
git_q -C "$consumer" fetch -q origin
git_q -C "$consumer" worktree add -q --no-track -b cb-a-brief "$tree" origin/main
echo built > "$tree/built.txt"
git_q -C "$tree" add built.txt
git_q -C "$tree" commit -q -m "wip: an earlier attempt"
echo loose > "$tree/loose.txt"
# One more commit on origin after the tree was made: only a fetch sees it.
echo three >> "$up/file.txt"
git_q -C "$up" commit -q -am "fix(cb-a): shipped since the last fetch"
git_q -C "$up" push -q origin HEAD
echo handed > "$state/Rogue.handover"

out="$(run_brief Rogue cb-a)" || fail "producer-brief: the agent's own claim exits 0"
for want in "## Startup brief" "cb-a" "Brief the builders" "ux:none, planned" "gh-7" \
            "> Every session starts by reading the same facts." "> A builder starts with them." \
            "> ## Context" "> The design of record." "> ## Sent back to the UX stage"; do
  has "$want"
done
if grep -q "^## Sent back" <<<"$out"; then
  fail "producer-brief: a heading in the notes is not left as one of the brief's, got: $out"
fi
pass "a claim prints the bead, its design and notes, quoted"

has "feat(cb-a): the first increment (#3)" "what shipped"
has "fix(cb-a): shipped since the last fetch" "what shipped, after a fetch"
hasnt "somebody else's" "what shipped"
pass "what shipped for the bead is listed from the fetched default branch, and nothing else"

has "$tree" "the worktree"
has "cb-a-brief" "the worktree's branch"
has "loose.txt" "the uncommitted changes"
has "wip: an earlier attempt" "the commits ahead"
pass "the worktree is given with its branch, its changes and the commits it is ahead by"

has "- docs/ui/cb-a-shape.html" "the mockups, by the bead's id"
has "- docs/ui/shared-sheet.html" "the mockups, by mention"
has "- docs/ui/gone.html (not in your tree)" "a named mockup that is missing"
hasnt "cb-ab-other" "another bead's drawing"
pass "the mockups are those named by the bead and those named after it, a missing one marked"

has "> ## A trap paid for" "the traps"
has "> Mind the gap." "the traps"
for want in "gate_fast bash tests/fast" "gate_full bash tests/full" "prewarm cargo build" \
            "navigator_gates plan merge"; do
  has "$want" "the project"
done
pass "the traps and the project's gates are carried"

[[ ! -e "$state/Rogue.state.json" ]] || fail "producer-brief: no state file is written"
[[ -e "$state/Rogue.handover" ]] || fail "producer-brief: the handover is left for the agent's first write"
pull_line="$(grep -m1 -n "dolt pull" "$stub/bd.log" | cut -d: -f1)"
show_line="$(grep -m1 -n "show cb-a" "$stub/bd.log" | cut -d: -f1)"
[[ -n "$pull_line" && -n "$show_line" && $pull_line -lt $show_line ]] \
  || fail "producer-brief: the board is pulled before the bead is read, got: $(cat "$stub/bd.log")"
pass "the board is pulled first, and neither the state file nor the handover is touched"

# A tree dirtier than the brief carries is cut, and says so.
reset
for i in $(seq 1 45); do : > "$tree/many-$i.txt"; done
out="$(run_brief Rogue cb-a)" || fail "producer-brief: a very dirty tree exits 0"
[[ "$(grep -c 'many-' <<<"$out")" -le 40 ]] || fail "producer-brief: the changes are cut at 40 lines"
has "more lines" "a cut list"
pass "a long list of changes is cut at 40 lines and says there are more"

# --- not the agent's -----------------------------------------------------------------------------

for case_ in "open Rogue" "in_progress Cyclops" "open x"; do
  reset
  read -r st as <<<"$case_"
  [[ "$as" == x ]] && as=""
  bead_json "$st" "$as"
  status=0
  out="$(run_brief Rogue cb-a)" || status=$?
  [[ $status -eq 3 ]] || fail "producer-brief: a bead that is $st/${as:-nobody} is exit 3, got $status"
  [[ "$(grep -c . <<<"$out")" -eq 1 ]] || fail "producer-brief: a bead not the agent's prints one line, got: $out"
  has "cb-a" "the one line"
done
pass "a bead that is not claimed for the agent is exit 3 and one line"

# --- bd fails --------------------------------------------------------------------------------------

reset
status=0
out="$(BD_SHOW_EXIT=1 run_brief Rogue cb-a 2>/dev/null)" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "producer-brief: a failed bd show is exit 1, nothing printed, got $status: $out"
echo 'not json' > "$stub/show.json"
status=0
out="$(run_brief Rogue cb-a 2>/dev/null)" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "producer-brief: unreadable JSON is exit 1, nothing printed, got $status: $out"
pass "a bd show that fails or prints no JSON is exit 1, nothing printed"

reset
out="$(BD_PULL_EXIT=1 run_brief Rogue cb-a 2>/dev/null)" || fail "producer-brief: a failed pull does not decide the status"
has "The board pull failed" "a failed pull"
reset
out="$(PATH="$gitstub:$PATH" GIT_FAIL="fetch" run_brief Rogue cb-a 2>/dev/null)" \
  || fail "producer-brief: a failed fetch does not decide the status"
has "The git fetch failed" "a failed fetch"
pass "a failed pull or fetch is said in the brief and is still exit 0"

reset
out="$(BD_PULL_SLEEP=60 CEREBRO_BRIEF_PULL_SECONDS=1 run_brief Rogue cb-a 2>/dev/null)" \
  || fail "producer-brief: a hung pull does not decide the status"
has "The board pull failed" "a hung pull"
[[ ! -e "$stub/pull-finished" ]] || fail "producer-brief: a hung pull is cut off, not waited out"
pass "a hung board pull is cut off at its bound and said as a failed pull"

# --- degraded reads ------------------------------------------------------------------------------

reset
out="$(PATH="$gitstub:$PATH" GIT_FAIL="--grep" run_brief Rogue cb-a 2>/dev/null)" \
  || fail "producer-brief: a failed log does not decide the status"
has "Could not read origin/main's log" "a failed log"
hasnt "Nothing on origin/main names" "a failed log"
out="$(PATH="$gitstub:$PATH" GIT_FAIL="status --porcelain" run_brief Rogue cb-a 2>/dev/null)" \
  || fail "producer-brief: a failed status does not decide the status"
has "Uncommitted: could not read" "a failed status"
out="$(PATH="$gitstub:$PATH" GIT_FAIL="ls-files" run_brief Rogue cb-a 2>/dev/null)" \
  || fail "producer-brief: a failed drawings read does not decide the status"
has "Could not read the tracked drawings" "a failed drawings read"
pass "a failed git read is said, never printed as an empty answer"

reset
mv "$consumer/.cerebro/project.conf" "$consumer/.cerebro/cerebro-project.conf"
out="$(run_brief Rogue cb-a 2>/dev/null)" || fail "producer-brief: a project.conf refusal does not decide the status"
has "navigator_gates (could not read" "a failed project-conf"
hasnt "navigator_gates (none" "a failed project-conf"
mv "$consumer/.cerebro/cerebro-project.conf" "$consumer/.cerebro/project.conf"
: > "$consumer/.cerebro/project.conf"
printf 'test:\n\ttrue\n' > "$consumer/Makefile"
out="$(run_brief Rogue cb-a 2>/dev/null)" || fail "producer-brief: an empty declaration exits 0"
has "gate_fast make test (detected, not declared" "a detected gate"
has "prewarm (not declared)" "an undeclared prewarm"
has "navigator_gates (none declared)" "undeclared gates"
pass "gates are declared, detected, absent or unreadable, and each is said"

reset
rm -f "${consumer:?}/.cerebro/traps.md"
jq -n '[{id: "cb-b", title: "Nothing yet", status: "in_progress", assignee: "Rogue"}]' > "$stub/show.json"
out="$(run_brief Rogue cb-b)" || fail "producer-brief: a bare bead exits 0"
has "Nothing on origin/main names cb-b" "nothing shipped"
has "No worktree at" "a missing tree"
has "No drawing" "no mockup"
has "No .cerebro/traps.md" "no traps"
mkdir -p "$consumer/.cerebro/worktrees/cb-b"
out="$(run_brief Rogue cb-b)" || fail "producer-brief: a plain directory exits 0"
has "No worktree at" "a plain directory at the tree's path"
pass "nothing shipped, no tree, no mockup and no traps are each said"

# --- usage ---------------------------------------------------------------------------------------

for argv in "" "Rogue" "Rogue cb-a extra" "Rogue ../x"; do
  status=0
  # shellcheck disable=SC2086
  run_brief $argv >/dev/null 2>&1 || status=$?
  [[ $status -eq 2 ]] || fail "producer-brief: usage '$argv' is exit 2, got $status"
done
pass "a missing or extra argument, or an id that is a path, is usage, exit 2"

suite_passed
