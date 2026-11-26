#!/usr/bin/env bash
#
# Proves `scripts/ux-deliver` (cb-7b1h): the UX stage's whole delivery tail as one call. It commits
# the chosen drawing to `docs/ui/` from the `<id>-mockup` worktree, opens the pull request, waits on
# its checks, merges it, and only once GitHub says MERGED records the acceptance and hands the bead to
# a producer; then it removes the worktree. It refuses, non-zero and naming the step, at the first
# failure, and a re-run continues where the last one stopped.
#
# git is real: a consumer cloned from a bare origin under `$work_dir`, so the commit, the push and
# the worktree are the real thing. `gh` and `bd` are stubs that log every call: `gh` keeps one pull
# request in a file and answers `pr checks` from a queue of answers, one per poll; `bd` keeps one
# bead in a file and applies the `update` flags this script passes, guards included.
#
#     bash tests/ux-deliver.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

stub="$work_dir/stub"
mkdir -p "$stub"

cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_DIR/gh.log"
pr="$STUB_DIR/pr.json"
case "$1 $2" in
  "pr list")
    if [[ -e "$pr" ]]; then jq -c '[.]' "$pr"; else echo '[]'; fi ;;
  "pr create")
    [[ -e "$STUB_DIR/create-fails" ]] && { echo "gh: pull request create failed" >&2; exit 1; }
    jq -n --arg at "${PR_CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
      '{number: 7, state: "OPEN", createdAt: $at, url: "https://github.com/o/r/pull/7", head: "cb-x-mockup"}' > "$pr"
    echo "https://github.com/o/r/pull/7" ;;
  "pr view")
    jq -c . "$pr" ;;
  "pr checks")
    # One answer per poll, the last one repeated: a JSON array, or NONE for "no checks reported".
    queue="$STUB_DIR/checks"
    answer="$(head -1 "$queue")"
    if [[ "$(wc -l < "$queue")" -gt 1 ]]; then tail -n +2 "$queue" > "$queue.tmp"; mv "$queue.tmp" "$queue"; fi
    if [[ "$answer" == NONE ]]; then echo "no checks reported on the '$3' branch" >&2; exit 1; fi
    echo "$answer"
    # gh's own statuses: 8 while anything is pending, 1 when anything failed.
    if jq -e 'any(.[]; .bucket == "pending")' <<<"$answer" >/dev/null; then exit 8; fi
    if jq -e 'any(.[]; .bucket == "fail")' <<<"$answer" >/dev/null; then exit 1; fi ;;
  "pr merge")
    # What the merge would land: the branch as pushed, read from the remote-tracking ref.
    git ls-tree -r --name-only "origin/$(jq -r .head "$pr")" > "$STUB_DIR/merged-files"
    git log -1 --format=%s "origin/$(jq -r .head "$pr")" > "$STUB_DIR/merged-subject"
    case "${MERGE_MODE:-ok}" in
      ok) jq '.state = "MERGED"' "$pr" > "$pr.tmp" && mv "$pr.tmp" "$pr" ;;
      merged-but-fails) jq '.state = "MERGED"' "$pr" > "$pr.tmp" && mv "$pr.tmp" "$pr"
                        echo "failed to delete local branch" >&2; exit 1 ;;
      refused) echo "X Pull request is not mergeable" >&2; exit 1 ;;
    esac ;;
  *) echo "ux-deliver stub: unexpected gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
bead="$STUB_DIR/bead.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--actor) shift 2 ;;
    *) break ;;
  esac
done
sub="$1"; shift
case "$sub" in
  show)
    jq -c '[.]' "$bead"
    if [[ -e "$STUB_DIR/flip-after-show" ]]; then
      rm "$STUB_DIR/flip-after-show"
      jq '.assignee = "Rogue"' "$bead" > "$bead.tmp" && mv "$bead.tmp" "$bead"
    fi ;;
  update)
    [[ -e "$STUB_DIR/update-fails" ]] && { echo "bd: update refused" >&2; exit 1; }
    shift
    filter='.'; if_assignee=""; guarded=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --acceptance) printf '%s' "$2" > "$STUB_DIR/acceptance"; filter="$filter | .acceptance = \$acc"; shift 2 ;;
        --add-label) filter="$filter | .labels = (((.labels // []) - [\"$2\"]) + [\"$2\"])"; shift 2 ;;
        --remove-label) filter="$filter | .labels = ((.labels // []) - [\"$2\"])"; shift 2 ;;
        --assignee) filter="$filter | .assignee = \"$2\""; shift 2 ;;
        --if-assignee) if_assignee="$2"; guarded=true; shift 2 ;;
        *) shift ;;
      esac
    done
    if $guarded && [[ "$(jq -r '.assignee // ""' "$bead")" != "$if_assignee" ]]; then exit 13; fi
    acc="$(cat "$STUB_DIR/acceptance" 2>/dev/null || true)"
    jq --arg acc "$acc" "$filter" "$bead" > "$bead.tmp" && mv "$bead.tmp" "$bead" ;;
  dolt) echo push >> "$STUB_DIR/pushed" ;;
  *) echo "ux-deliver stub: unexpected bd $sub" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/bd"

# A fresh case: its own consumer cloned from its own origin, the bead assigned to Xavier, no logs.
case_n=0
fresh() {
  case_n=$((case_n + 1))
  rm -f "$stub"/*.log "$stub/pr.json" "$stub/pushed" "$stub/acceptance" "$stub/create-fails" \
        "$stub/update-fails" "$stub/checks" "$stub/flip-after-show" "$stub/merged-files" "$stub/merged-subject"
  consumer="$(consumer_new "c$case_n" --origin --copy)"
  printf '%s' '{"id":"cb-x","status":"open","assignee":"Xavier","labels":["needs-ui-decision"]}' > "$stub/bead.json"
  printf '## The agreed experience\n\nA list beside the fleet.\n\n## The mockup\n\ndocs/ui/cb-x-list.html\n' \
    > "$work_dir/acceptance-$case_n.md"
  printf '<!doctype html><title>Option A</title>\n' > "$work_dir/cb-x-list-a.html"
  printf '<!doctype html><title>Sketches</title>\n' > "$work_dir/cb-x-sketches-2.html"
  checks '[{"name":"What changed","bucket":"pass"},{"name":"Bash suites","bucket":"skipping"}]'
}

# checks <answer>...: the answers `gh pr checks` gives, one per poll.
checks() {
  printf '%s\n' "$@" > "$stub/checks"
}

deliver() {
  (cd "$consumer" && STUB_DIR="$stub" PATH="$stub:$PATH" UX_DELIVER_POLL=0 \
    bash .cerebro/cerebro/scripts/ux-deliver "$@")
}

# run_deliver <args>...: sets `status`, `out` and `err`.
run_deliver() {
  status=0
  out="$(deliver "$@" 2>"$work_dir/err")" || status=$?
  err="$(cat "$work_dir/err")"
}

with_mockups() {
  run_deliver Xavier --bead cb-x --acceptance "$work_dir/acceptance-$case_n.md" \
    --mockup "$work_dir/cb-x-list-a.html=cb-x-list.html" --mockup "$work_dir/cb-x-sketches-2.html=cb-x-sketches.html" "$@"
}

labels() { jq -c '.labels' "$stub/bead.json"; }
recorded() { [[ "$(jq -r '.acceptance // ""' "$stub/bead.json")" == *"A list beside the fleet."* ]]; }
tree="" ; tree_of() { tree="$consumer/.cerebro/worktrees/cb-x-mockup"; }

# --- usage ----------------------------------------------------------------------------------------

fresh
for args in "" "Xavier" "Xavier --bead cb-x" "Xavier --acceptance x.md" "Xavier --bead cb-x --acceptance a.md --bogus"; do
  # shellcheck disable=SC2086 # word-split on purpose
  run_deliver $args
  [[ $status -eq 2 ]] || fail "usage [$args] exits 2, got $status: $err"
done
[[ ! -e "$stub/bd.log" && ! -e "$stub/gh.log" ]] || fail "a usage error reads nothing"
pass "refuses a malformed call with status 2 before touching anything"

# --- invisible work: no drawing, so no pull request, only the record ---------------------------------

fresh
run_deliver Xavier --bead cb-x --acceptance "$work_dir/acceptance-$case_n.md"
[[ $status -eq 0 ]] || fail "invisible work delivers, got $status: $err"
[[ ! -e "$stub/gh.log" ]] || fail "invisible work opens no pull request: $(cat "$stub/gh.log")"
recorded || fail "the acceptance is recorded: $(cat "$stub/bead.json")"
[[ "$(labels)" == '["ux:agreed"]' ]] || fail "the bead carries ux:agreed alone, got $(labels)"
[[ "$(jq -r .assignee "$stub/bead.json")" == "" ]] || fail "the bead is unassigned"
grep -q -- "--if-assignee Xavier" "$stub/bd.log" || fail "the record is guarded on the assignee: $(cat "$stub/bd.log")"
[[ -e "$stub/pushed" ]] || fail "the board is pushed"
pass "records invisible work with no pull request, guarded, and pushes the board"

# --- not yours: refused at check, nothing written ----------------------------------------------------

fresh
printf '%s' '{"id":"cb-x","status":"open","assignee":"Rogue","labels":[]}' > "$stub/bead.json"
with_mockups
[[ $status -eq 1 ]] || fail "another agent's bead is refused with 1, got $status"
[[ "$err" == *"ux-deliver: check:"* ]] || fail "the refusal names the check step: $err"
! grep -q update "$stub/bd.log" || fail "nothing is written to another agent's bead"
[[ ! -e "$stub/gh.log" && ! -d "$consumer/.cerebro/worktrees/cb-x-mockup" ]] || fail "no worktree or pull request for another agent's bead"
pass "refuses a bead assigned to somebody else before any write"

fresh
run_deliver Xavier --bead cb-x --acceptance "$work_dir/acceptance-$case_n.md" --mockup "$work_dir/missing.html"
[[ $status -eq 1 && "$err" == *"ux-deliver: check:"* ]] || fail "a missing drawing is refused at check, got $status: $err"
: > "$work_dir/empty.md"
run_deliver Xavier --bead cb-x --acceptance "$work_dir/empty.md"
[[ $status -eq 1 && "$err" == *"ux-deliver: check:"* ]] || fail "an empty record is refused at check, got $status: $err"
run_deliver Xavier --bead cb-x --acceptance "$work_dir/acceptance-$case_n.md" --mockup "$work_dir/cb-x-list-a.html=ui/x.html"
[[ $status -eq 1 && "$err" == *"ux-deliver: check:"* ]] || fail "a drawing name with a slash is refused at check, got $status: $err"
! grep -q update "$stub/bd.log" 2>/dev/null || fail "nothing is recorded on a refused check"
pass "refuses a missing drawing, an empty record and a pathed name at check"

# --- the whole tail, green -------------------------------------------------------------------------

fresh
with_mockups
[[ $status -eq 0 ]] || fail "a green delivery exits 0, got $status: $err"
origin_files="$(cat "$stub/merged-files")"
grep -qx "docs/ui/cb-x-list.html" <<<"$origin_files" || fail "the drawing reached origin under its name: $origin_files"
grep -qx "docs/ui/cb-x-sketches.html" <<<"$origin_files" || fail "the sheet reached origin under its name: $origin_files"
[[ "$(cat "$stub/merged-subject")" == "docs(cb-x): mockup" ]] \
  || fail "the commit subject is docs(cb-x): mockup"
[[ -z "$(git -C "$work_dir/c$case_n-origin.git" branch --list cb-x-mockup)" ]] \
  || fail "a remote branch the merge left behind is deleted"
grep -q "^pr create" "$stub/gh.log" || fail "a pull request is opened"
grep -q "^pr merge 7 --squash --delete-branch" "$stub/gh.log" || fail "it merges by squash and deletes the branch: $(cat "$stub/gh.log")"
recorded || fail "the acceptance is recorded after the merge"
[[ "$(labels)" == '["ux:agreed"]' ]] || fail "the label change is the agree_experience hand-off, got $(labels)"
tree_of
[[ ! -e "$tree" ]] || fail "the worktree is removed"
! git -C "$consumer" rev-parse --verify -q refs/heads/cb-x-mockup >/dev/null || fail "the local branch is deleted"
pass "commits the drawings, merges the green pull request, records, and removes the worktree"

# --- red: never merged, never recorded --------------------------------------------------------------

fresh
checks '[{"name":"What changed","bucket":"pass"},{"name":"Bash suites","bucket":"fail"}]'
with_mockups
[[ $status -eq 1 ]] || fail "red checks refuse with 1, got $status"
[[ "$err" == *"ux-deliver: ci:"* && "$err" == *"Bash suites"* ]] || fail "the refusal names the ci step and the failing check: $err"
! grep -q "^pr merge" "$stub/gh.log" || fail "a red pull request is never merged"
! recorded || fail "a red pull request records nothing"
[[ "$(labels)" == '["needs-ui-decision"]' ]] || fail "a red pull request changes no label, got $(labels)"
pass "refuses red checks at ci: no merge, no record"

fresh
checks '[{"name":"What changed","bucket":"cancel"}]'
with_mockups
[[ $status -eq 1 && "$err" == *"ux-deliver: ci:"* ]] || fail "cancelled checks refuse at ci, got $status: $err"
! grep -q "^pr merge" "$stub/gh.log" || fail "a cancelled run is never merged"
pass "refuses cancelled checks at ci"

# --- pending past the wait: exit 3, and the re-run picks up the same pull request -------------------

fresh
checks '[{"name":"Bash suites","bucket":"pending"}]'
with_mockups --wait 0
[[ $status -eq 3 ]] || fail "checks still pending when the wait runs out exit 3, got $status: $err"
! grep -q "^pr merge" "$stub/gh.log" || fail "a pending pull request is not merged"
! recorded || fail "a pending pull request records nothing"
tree_of
[[ -d "$tree" ]] || fail "the worktree stays for the re-run"
checks '[{"name":"Bash suites","bucket":"pending"}]' '[{"name":"Bash suites","bucket":"pass"}]'
with_mockups
[[ $status -eq 0 ]] || fail "the re-run delivers once checks pass, got $status: $err"
[[ "$(grep -c "^pr create" "$stub/gh.log")" -eq 1 ]] || fail "the re-run reuses the pull request: $(cat "$stub/gh.log")"
recorded || fail "the re-run records"
pass "exits 3 while checks are pending, and a re-run reuses the pull request and delivers"

# --- no checks reported: pending at first, green once the grace has passed ----------------------------

fresh
checks NONE
with_mockups --wait 0
[[ $status -eq 3 ]] || fail "no checks on a new pull request is still pending, got $status: $err"
jq '.createdAt = "2020-01-01T00:00:00Z"' "$stub/pr.json" > "$stub/pr.tmp" && mv "$stub/pr.tmp" "$stub/pr.json"
with_mockups --wait 0
[[ $status -eq 0 ]] || fail "no checks long after the pull request opened is not red, got $status: $err"
pass "treats no checks as pending until the grace has passed, then as green"

# --- the merge: GitHub's word decides -----------------------------------------------------------------

fresh
MERGE_MODE=merged-but-fails with_mockups
[[ $status -eq 0 ]] || fail "a merge that reports an error after merging still delivers, got $status: $err"
recorded || fail "a merged pull request is recorded"
pass "delivers when the merge call fails after GitHub merged"

fresh
MERGE_MODE=refused with_mockups
[[ $status -eq 1 && "$err" == *"ux-deliver: merge:"* ]] || fail "a refused merge is refused at merge, got $status: $err"
! recorded || fail "an unmerged pull request records nothing"
[[ "$(labels)" == '["needs-ui-decision"]' ]] || fail "an unmerged pull request changes no label"
pass "refuses at merge when GitHub did not merge, recording nothing"

# --- a lost assignment between the merge and the record ---------------------------------------------
#
# The stub hands the bead to Rogue after the first read, so the record's own read finds it gone.

fresh
touch "$stub/flip-after-show"
with_mockups
[[ $status -eq 1 && "$err" == *"ux-deliver: record:"* ]] || fail "a bead lost before the record is refused at record, got $status: $err"
[[ "$(jq -r .assignee "$stub/bead.json")" == Rogue ]] || fail "the other agent's assignment stands"
! recorded || fail "nothing is recorded on a bead somebody else holds"
pass "refuses at record when the bead changed hands, writing nothing"

# --- only docs/ may ride on a drawing's pull request ---------------------------------------------------

fresh
git_q -C "$consumer" worktree add -q -b cb-x-mockup "$consumer/.cerebro/worktrees/cb-x-mockup" origin/main
echo hack > "$consumer/.cerebro/worktrees/cb-x-mockup/script.sh"
git_q -C "$consumer/.cerebro/worktrees/cb-x-mockup" add script.sh
git_q -C "$consumer/.cerebro/worktrees/cb-x-mockup" commit -q -m stray
with_mockups
[[ $status -eq 1 && "$err" == *"ux-deliver: commit:"* && "$err" == *"script.sh"* ]] \
  || fail "a change outside docs/ is refused at commit, naming it, got $status: $err"
! grep -q "^pr create" "$stub/gh.log" 2>/dev/null || fail "no pull request carries a change outside docs/"
[[ -z "$(git -C "$work_dir/c$case_n-origin.git" branch --list cb-x-mockup)" ]] || fail "nothing is pushed"
pass "refuses at commit when the branch carries anything outside docs/"

fresh
git_q -C "$consumer" worktree add -q -b other "$consumer/.cerebro/worktrees/cb-x-mockup" origin/main
with_mockups
[[ $status -eq 1 && "$err" == *"ux-deliver: worktree:"* ]] || fail "a mockup tree on another branch is refused at worktree, got $status: $err"
pass "refuses a mockup worktree that is on another branch"

suite_passed
