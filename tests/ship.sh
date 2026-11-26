#!/usr/bin/env bash
#
# Proves `scripts/ship` (cb-tbrh): a builder hands a reviewed pull request over and ends its pass,
# and `ship --sweep` takes it the rest of the way without a model: waits on its checks, catches the
# branch up, re-runs a failed job once, merges on green, closes the bead and tidies the tree, or sends
# the bead back with the reason noted. Nothing red and no unreviewed commit is ever merged.
#
# git is real: a consumer cloned from a bare origin under `$work_dir`, so the heads, the catch-up
# merges and the worktree are the real thing. `gh` and `bd` are stubs that log every call: `gh` keeps
# one pull request in a file and answers `pr checks` from a file; `bd` keeps the board in a file and
# applies the writes this script makes, guards included.
#
#     bash tests/ship.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

stub="$work_dir/stub"
mkdir -p "$stub"

cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_DIR/gh.log"
pr="$STUB_DIR/pr.json"
edit() { jq "$@" "$pr" > "$pr.tmp" && mv "$pr.tmp" "$pr"; }
case "$1 $2" in
  "pr view")
    [[ -e "$STUB_DIR/view-fails" ]] && { echo "gh: HTTP 502" >&2; exit 1; }
    if [[ "$*" == *"--jq .state"* ]]; then jq -r .state "$pr"; else cat "$pr"; fi ;;
  "pr checks")
    answer="$(cat "$STUB_DIR/checks")"
    if [[ "$answer" == NONE ]]; then echo "no checks reported on the 'x' branch" >&2; exit 1; fi
    if [[ "$answer" == BROKEN ]]; then echo "gh: HTTP 502" >&2; exit 1; fi
    echo "$answer" ;;
  "pr merge")
    case "${MERGE_MODE:-ok}" in
      ok)
        # A squash on origin's main, named as GitHub would name it.
        subject="$(jq -r .title "$pr")"
        while [[ $# -gt 0 ]]; do [[ "$1" == --subject ]] && subject="$2"; shift; done
        printf '%s\n' "$subject" > "$STUB_DIR/merged-subject"
        git="git -C $ORIGIN"
        head="$(jq -r .headRefOid "$pr")"
        sha="$($git commit-tree "$head^{tree}" -p refs/heads/main -m "$subject")"
        $git update-ref refs/heads/main "$sha"
        edit '.state = "MERGED"' ;;
      refused) echo "X Pull request is not mergeable: the base branch policy prohibits the merge." >&2; exit 1 ;;
    esac ;;
  "run rerun")
    [[ -e "$STUB_DIR/rerun-fails" ]] && { echo "gh: run cannot be rerun" >&2; exit 1; }
    : ;;
  "api -X")
    [[ -e "$STUB_DIR/update-branch-fails" ]] && { echo "gh: HTTP 422" >&2; exit 1; }
    : ;;
  *) echo "ship stub: unexpected gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
board="$STUB_DIR/board.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--actor) shift 2 ;;
    --readonly) shift ;;
    *) break ;;
  esac
done
sub="$1"; shift
edit() { jq "$@" "$board" > "$board.tmp" && mv "$board.tmp" "$board"; }
field() { jq -r --arg id "$1" ".[] | select(.id == \$id) | $2" "$board"; }
case "$sub" in
  show) jq --arg id "$1" '[ .[] | select(.id == $id) ]' "$board" ;;
  list)
    [[ -e "$STUB_DIR/list-fails" ]] && { echo "bd: database is locked" >&2; exit 1; }
    status=""; assignee=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) status="$2"; shift 2 ;;
        --assignee) assignee="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # A `bd` that ignores the filters, as another suite's stub does.
    if [[ -e "$STUB_DIR/unfiltered-fails" ]]; then status=""; assignee=""; fi
    jq --arg s "$status" --arg a "$assignee" \
      '[ .[] | select(($s == "" or .status == $s) and ($a == "" or .assignee == $a)) ]' "$board" ;;
  children) jq --arg id "$1" '[ .[] | select(.parent == $id) ]' "$board" ;;
  close)
    [[ -e "$STUB_DIR/close-fails" ]] && { echo "bd: close refused" >&2; exit 1; }
    edit --arg id "$1" 'map(if .id == $id then .status = "closed" else . end)' ;;
  update)
    id="$1"; shift
    filter='.'; if_assignee=""; guarded=false
    args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --add-label) filter="$filter | .labels = (((.labels // []) - [\"$2\"]) + [\"$2\"])"; shift 2 ;;
        --remove-label) filter="$filter | .labels = ((.labels // []) - [\"$2\"])"; shift 2 ;;
        --assignee) filter="$filter | .assignee = \"$2\""; shift 2 ;;
        --set-metadata) filter="$filter | .metadata[\"${2%%=*}\"] = \"${2#*=}\""; shift 2 ;;
        --unset-metadata) filter="$filter | del(.metadata[\"$2\"])"; shift 2 ;;
        --append-notes) args=("$2"); filter="$filter | .notes = ((.notes // \"\") + \"\n\" + \$note)"; shift 2 ;;
        --if-assignee) if_assignee="$2"; guarded=true; shift 2 ;;
        *) shift ;;
      esac
    done
    if $guarded && [[ "$(field "$id" '.assignee // ""')" != "$if_assignee" ]]; then exit 13; fi
    edit --arg id "$id" --arg note "${args[0]:-}" "map(if .id == \$id then ($filter) else . end)" ;;
  unclaim)
    [[ -e "$STUB_DIR/unclaim-fails" ]] && { echo "bd: unclaim refused" >&2; exit 1; }
    id="$1"; shift
    if [[ "${1:-}" == --if-assignee && "$(field "$id" '.assignee // ""')" != "$2" ]]; then exit 13; fi
    edit --arg id "$id" 'map(if .id == $id then .assignee = "" | .status = "open" else . end)' ;;
  dolt)
    [[ -e "$STUB_DIR/push-fails" ]] && { echo "bd: remote unreachable" >&2; exit 1; }
    echo push >> "$STUB_DIR/pushed" ;;
  *) echo "ship stub: unexpected bd $sub" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/bd"

long_ago="2020-01-01T00:00:00Z"
now_epoch="$(date +%s)"
passing='[{"name":"What changed","bucket":"pass","link":"https://github.com/o/r/actions/runs/11/job/1","completedAt":"2020-01-01T00:00:00Z"},{"name":"Docs","bucket":"skipping","link":"","completedAt":"2020-01-01T00:00:00Z"}]'
failing='[{"name":"Bash suites","bucket":"fail","link":"https://github.com/o/r/actions/runs/42/job/7","completedAt":"2020-01-01T00:00:00Z"},{"name":"Rust","bucket":"fail","link":"https://github.com/o/r/actions/runs/42/job/8","completedAt":"2020-01-01T00:00:00Z"}]'

# A fresh case: its own consumer and origin, a worktree for cb-x holding one reviewed commit pushed as
# pull request 7, the bead handed to `ship` long enough ago to merge, and green checks.
case_n=0
fresh() {
  case_n=$((case_n + 1))
  rm -f "$stub"/*.log "$stub/pushed" "$stub/merged-subject" "$stub"/*-fails
  consumer="$(consumer_new "s$case_n" --origin --copy)"
  origin="$(git -C "$consumer" remote get-url origin)"
  tree="$consumer/.cerebro/worktrees/cb-x"
  printf '.cerebro/worktrees/\n.cerebro/state/\n' >> "$consumer/.git/info/exclude"
  git -C "$consumer" worktree add -q --no-track -b cb-x-thing "$tree" origin/main
  echo work > "$tree/work.txt"
  git -C "$tree" add work.txt
  GIT_COMMITTER_DATE="$long_ago" git -C "$tree" commit -q -m "feat(cb-x): the thing"
  git -C "$tree" push -q origin HEAD
  head="$(git -C "$tree" rev-parse HEAD)"
  git -C "$origin" update-ref refs/pull/7/head "$head"
  pr_is "{\"state\":\"OPEN\",\"headRefOid\":\"$head\",\"headRefName\":\"cb-x-thing\",\"title\":\"feat(cb-x): the thing\",\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"reviewDecision\":\"\"}"
  board_is "[$(shipping_bead)]"
  checks "$passing"
}
shipping_bead() {
  printf '{"id":"cb-x","status":"in_progress","assignee":"ship","issue_type":"task","labels":["ux:agreed","planned","shipping"],"metadata":{"ship_pr":7,"ship_head":"%s","ship_at":%s}}' "$head" "$((now_epoch - 600))"
}
pr_is() { printf '%s' "$1" > "$stub/pr.json"; }
pr_set() { jq "$1" "$stub/pr.json" > "$stub/pr.tmp" && mv "$stub/pr.tmp" "$stub/pr.json"; }
board_is() { printf '%s' "$1" > "$stub/board.json"; }
board_set() { jq "$1" "$stub/board.json" > "$stub/board.tmp" && mv "$stub/board.tmp" "$stub/board.json"; }
checks() { printf '%s' "$1" > "$stub/checks"; }
bead() { jq -r ".[] | select(.id == \"cb-x\") | $1" "$stub/board.json"; }
gh_called() { grep -q "$1" "$stub/gh.log" 2>/dev/null; }

ship() {
  (cd "$consumer" && STUB_DIR="$stub" ORIGIN="$origin" PATH="$stub:$PATH" bash .cerebro/cerebro/scripts/ship "$@")
}
# run_ship <args>...: sets `status`, `out` and `err`.
run_ship() {
  status=0
  out="$(ship "$@" 2>"$work_dir/err")" || status=$?
  err="$(cat "$work_dir/err")"
}
sweep() {
  run_ship --sweep
  [[ $status -eq 0 ]] || fail "the sweep exited $status: $out / $err"
}

# A head a GitHub "update branch" would make: main moved, merged into the PR's branch.
advance_main() {
  local g="git -C $origin" blob tree_sha
  blob="$(echo moved | $g hash-object -w --stdin)"
  tree_sha="$( { $g ls-tree refs/heads/main; printf '100644 blob %s\tmoved-%s.txt\n' "$blob" "$1"; } | $g mktree)"
  $g update-ref refs/heads/main "$($g commit-tree "$tree_sha" -p refs/heads/main -m "main moved $1")"
}
# catch_up <head>: the merge commit of main into <head>, as GitHub makes it.
catch_up() {
  local g="git -C $origin" merged
  merged="$($g merge-tree --write-tree "$1" refs/heads/main)"
  $g commit-tree "$merged" -p "$1" -p refs/heads/main -m "Merge branch 'main' into cb-x-thing"
}
move_head() {
  git -C "$origin" update-ref refs/pull/7/head "$1"
  pr_set ".headRefOid = \"$1\""
}

# --- usage ----------------------------------------------------------------------------------------

fresh
for args in "" "--sweep extra" "Rogue cb-x 7" "Rogue cb-x seven $head" "Rogue cb-x 7 abc"; do
  # shellcheck disable=SC2086 # the arguments are word-split on purpose
  run_ship $args
  [[ $status -eq 2 ]] || fail "ship $args exited $status, not 2"
done
pass "a malformed call exits 2"

# --- the hand-over --------------------------------------------------------------------------------

handed_board() {
  board_is '[{"id":"cb-x","status":"in_progress","assignee":"Rogue","issue_type":"task","labels":["ux:agreed","planned"],"metadata":{"ship_rerun_at":"x"}}]'
}
swept_now() { mkdir -p "$consumer/.cerebro/state"; date +%s > "$consumer/.cerebro/state/ship-swept"; }

fresh; handed_board; swept_now
run_ship Rogue cb-x 7 "$head"
[[ $status -eq 0 ]] || fail "the hand-over exited $status: $err"
[[ "$(bead .assignee)" == ship && "$(bead .status)" == in_progress ]] || fail "the bead is not held by ship: $(cat "$stub/board.json")"
[[ "$(bead '.labels | index("shipping") != null')" == true ]] || fail "no shipping label"
[[ "$(bead .metadata.ship_pr)" == 7 && "$(bead .metadata.ship_head)" == "$head" ]] || fail "the pull request and head are not recorded"
[[ "$(bead .metadata.ship_at)" =~ ^[0-9]+$ && "$(bead '.metadata.ship_rerun_at // "gone"')" == gone ]] || fail "ship_at unset, or an old re-run kept"
[[ -e "$stub/pushed" ]] || fail "the board was not pushed"
rm "$stub/pushed"
run_ship Rogue cb-x 7 "$head"
[[ $status -eq 0 && -e "$stub/pushed" ]] || fail "a repeated hand-over did not just push: $status $err"
pass "the hand-over records the pull request and reviewed head, gives the claim to ship and pushes; again, it only pushes"

for stale in none old; do
  fresh; handed_board
  if [[ $stale == old ]]; then mkdir -p "$consumer/.cerebro/state"; echo 1600000000 > "$consumer/.cerebro/state/ship-swept"; fi
  run_ship Rogue cb-x 7 "$head"
  [[ $status -eq 3 && "$(bead .assignee)" == Rogue ]] || fail "with a $stale heartbeat the hand-over exited $status"
done
pass "the hand-over exits 3, writing nothing, when no sweep has run lately"

refused() {
  run_ship Rogue cb-x 7 "$head"
  [[ $status -eq 1 && "$(bead '.labels | index("shipping")')" == null ]] || fail "$1: exited $status, $err"
  [[ "$err" == *"$2"* ]] || fail "$1: the refusal does not say '$2': $err"
}
fresh; handed_board; swept_now; board_set '.[0].assignee = "Storm"'; refused "somebody else's bead" "not in progress for Rogue"
fresh; handed_board; swept_now; pr_set '.headRefOid = "0000000000000000000000000000000000000000"'; refused "a head nobody reviewed" "head is"
fresh; handed_board; swept_now; pr_set '.state = "CLOSED"'; refused "a closed pull request" "CLOSED"
fresh; handed_board; swept_now; pr_set '.isDraft = true'; refused "a draft pull request" "draft"
fresh; handed_board; swept_now; echo "navigator_gates merge" >> "$consumer/.cerebro/project.conf"; refused "a merge gate" "merge gate"
pass "the hand-over refuses another's bead, an unreviewed head, a closed pull request and a declared merge gate"

# --- the green path -------------------------------------------------------------------------------

fresh
board_set '. + [{"id":"cb-p","status":"open","issue_type":"epic","labels":[]}] | .[0].parent = "cb-p"'
sweep
[[ "$out" == "merged cb-x #7" ]] || fail "the green sweep said: $out / $err"
[[ "$(bead .status)" == closed ]] || fail "the bead was not closed"
[[ "$(jq -r '.[] | select(.id == "cb-p") | .status' "$stub/board.json")" == closed ]] || fail "the parent of the last child stayed open"
gh_called "pr merge 7 --squash --match-head-commit $head" || fail "the merge was not held to the reviewed head: $(cat "$stub/gh.log")"
[[ ! -e "$tree" ]] || fail "the worktree was left behind"
[[ -z "$(git -C "$consumer" branch --list cb-x-thing)" ]] || fail "the local branch was left behind"
[[ -z "$(git -C "$origin" branch --list cb-x-thing)" ]] || fail "the remote branch was left behind"
[[ -e "$stub/pushed" ]] || fail "the board was not pushed"
[[ -s "$consumer/.cerebro/state/ship-swept" ]] || fail "the sweep left no heartbeat"
pass "green: merged at the reviewed head, bead and parent closed, branch and tree gone, board pushed"

fresh; echo dirt > "$tree/uncommitted"; sweep
[[ -e "$tree/uncommitted" ]] || fail "a tree with uncommitted work was removed"
fresh; mkdir -p "$consumer/.cerebro/state/worktrees"; echo Rogue > "$consumer/.cerebro/state/worktrees/cb-x"; sweep
[[ -e "$tree" ]] || fail "a tree the fleet view still records was removed"
pass "a tree holding uncommitted work, or still recorded for its owner, is left"

fresh; board_set '.[0].metadata.dependabot_pr = "7"'; pr_set '.title = "Bump serde from 1 to 2"'; sweep
[[ "$(cat "$stub/merged-subject")" == "fix(cb-x): Bump serde from 1 to 2 (#7)" ]] || fail "a Dependabot merge does not name the bead: $(cat "$stub/merged-subject")"
pass "a Dependabot pull request is merged under a subject naming the bead"

fresh; pr_set '.state = "MERGED"'; sweep
[[ "$out" == "merged cb-x #7" && "$(bead .status)" == closed ]] || fail "an already merged pull request: $out"
gh_called "pr merge" && fail "it was merged again"
pass "a pull request already merged only has its bead closed"

fresh; : > "$stub/push-fails"; sweep
[[ "$out" == *"failed board push"* ]] || fail "a failed push is not said: $out"
rm "$stub/push-fails" "$stub/pushed" 2>/dev/null || true; sweep
[[ -e "$stub/pushed" ]] || fail "the next sweep did not push again"
pass "a failed board push is said and pushed by the next sweep"

overdue() { board_set '.[0].metadata.ship_at = 1600000000'; }

# --- waiting --------------------------------------------------------------------------------------

waits() {
  sweep
  [[ -z "$out" ]] || fail "$1 should wait quietly, said: $out"
  [[ "$(bead .assignee)" == ship && "$(bead .status)" == in_progress ]] || fail "$1: the bead moved"
  if gh_called "pr merge"; then fail "$1: it was merged"; fi
}
fresh; checks '[{"name":"Bash","bucket":"pending","link":"","completedAt":"0001-01-01T00:00:00Z"}]'; waits "a pending check"
fresh; checks "$(jq -c '. + [{"name":"Slow","bucket":"pending","link":"","completedAt":""}]' <<<"$failing")"; waits "a failure beside a pending check"
fresh; board_set ".[0].metadata.ship_at = $now_epoch"; waits "a head handed over a moment ago"
fresh; pr_set '.mergeable = "UNKNOWN"'; waits "unknown mergeability"
pass "pending checks, a fresh head and unknown mergeability wait"

fresh; checks NONE; sweep
[[ "$out" == "merged cb-x #7" ]] || fail "no checks after the grace should merge: $out"
pass "a repository reporting no checks merges after the grace"

fresh; checks BROKEN; sweep
[[ "$out" == "failed cb-x #7 "* ]] || fail "unreadable checks: $out"
fresh; : > "$stub/view-fails"; sweep
[[ "$out" == "failed cb-x #7 "* && "$(bead .assignee)" == ship ]] || fail "an unreadable pull request: $out"
fresh; MERGE_MODE=refused; export MERGE_MODE; sweep; unset MERGE_MODE
[[ "$out" == "failed cb-x #7 merge refused"* && "$(bead .status)" == in_progress ]] || fail "a refused merge: $out"
pass "unreadable checks or pull request, and a refused merge, are said and retried"

fresh; : > "$stub/list-fails"; run_ship --sweep
[[ $status -eq 1 ]] || fail "an unreadable board exited $status"
pass "an unreadable board fails the sweep"

# --- a fault that never clears ends with the navigator ---------------------------------------------

forever() {
  sweep
  [[ "$out" == "parked cb-x #7 "*"$2"* ]] || fail "$1, six hours on: said $out / $err"
  [[ "$(bead .assignee)" == "" && "$(bead '.labels | index("human") != null')" == true ]] || fail "$1: not the navigator's"
}
fresh; overdue; : > "$stub/view-fails"; forever "an unreadable pull request" "gh pr view"
fresh; overdue; checks BROKEN; forever "unreadable checks" "gh pr checks"
fresh; overdue; git -C "$origin" update-ref -d refs/pull/7/head; forever "a head git cannot fetch" "git fetch"
fresh; overdue; pr_set '.mergeStateStatus = "BEHIND"'; : > "$stub/update-branch-fails"; forever "a catch-up refused" "behind"
fresh; overdue; pr_set '.state = "MERGED"'; : > "$stub/close-fails"; forever "a close refused" "bd close"
fresh; board_set 'del(.[0].metadata.ship_pr)'; sweep
[[ "$(bead '.labels | index("human") != null')" == true && "$(bead .assignee)" == "" ]] || fail "a bead naming no pull request: $out"
pass "six hours of the same fault, or a bead naming no pull request, goes to the navigator"

# --- one bead's trouble leaves the others to be swept ----------------------------------------------

fresh
board_set '(.[0] | .id = "cb-a" | .metadata.ship_pr = "9" | .metadata.ship_at = "soon") as $bad | [$bad] + .'
sweep
[[ "$out" == *"cb-a #9"*$'\n'"merged cb-x #7"* ]] || fail "the second bead was not swept after the first failed: $out"
pass "every held bead is swept, whatever became of the one before it"

# --- catching up, and the covered head ------------------------------------------------------------

fresh; advance_main 1; pr_set '.mergeStateStatus = "BEHIND"'; sweep
[[ "$out" == "updated cb-x #7" ]] || fail "a branch behind main: $out / $err"
gh_called "api -X PUT repos/{owner}/{repo}/pulls/7/update-branch -f expected_head_sha=$head" || fail "update-branch not asked: $(cat "$stub/gh.log")"
gh_called "pr merge" && fail "merged while behind"
pass "a branch behind main is caught up at the head just read"

fresh; advance_main 1; move_head "$(catch_up "$head")"; sweep
[[ -z "$out" ]] || fail "a catch-up head made a moment ago was acted on: $out / $err"

fresh; advance_main 1
g="git -C $origin"
export GIT_COMMITTER_DATE="$long_ago"
first="$(catch_up "$head")"
advance_main 2
second="$(catch_up "$first")"
unset GIT_COMMITTER_DATE
move_head "$second"; sweep
[[ "$out" == "merged cb-x #7" ]] || fail "two clean catch-ups over the reviewed head are covered: $out / $err"
gh_called "match-head-commit $second" || fail "not held to the caught-up head"
pass "clean merges of the default branch over the reviewed head are still covered"

returned() {
  sweep
  [[ "$out" == "returned cb-x #7 "*"$2"* ]] || fail "$1: said $out / $err"
  [[ "$(bead .status)" == open && "$(bead .assignee)" == "" ]] || fail "$1: the claim was not given back"
  [[ "$(bead '.labels | index("shipping")')" == null && "$(bead '.labels | index("human")')" == null ]] || fail "$1: labels $(bead .labels)"
  [[ "$(bead .notes)" == *"## Sent back from shipping"*"#7"*"cb-x-thing"*"$2"* ]] || fail "$1: the note is $(bead .notes)"
  if gh_called "pr merge"; then fail "$1: merged"; fi
}

fresh; echo extra > "$tree/extra"; git -C "$tree" add extra; git -C "$tree" commit -q -m "feat(cb-x): unreviewed"
git -C "$tree" push -q origin HEAD; move_head "$(git -C "$tree" rev-parse HEAD)"
returned "a commit nobody reviewed" "not covered by the review"
fresh; advance_main 1; g="git -C $origin"
# A merge of main whose tree carries something neither parent does.
smuggled="$($g commit-tree "$($g rev-parse "refs/heads/main^{tree}")" -p "$head" -p refs/heads/main -m "Merge main")"
move_head "$smuggled"; returned "a hand-edited merge" "not covered by the review"
pass "an added commit, or a merge that changes more than main did, is sent back unmerged"

fresh; pr_set '.mergeable = "CONFLICTING"'; returned "a conflict" "conflicts"
fresh; pr_set '.reviewDecision = "CHANGES_REQUESTED"'; returned "changes requested" "changes requested"
pass "a conflict or a request for changes sends the bead back"

# --- red ------------------------------------------------------------------------------------------

fresh; checks "$failing"; sweep
[[ "$out" == "reran cb-x #7 Bash suites, Rust" ]] || fail "the first red: $out / $err"
[[ "$(grep -c '^run rerun 42 --failed$' "$stub/gh.log")" == 1 ]] || fail "run 42 not re-run once: $(cat "$stub/gh.log")"
[[ "$(bead .metadata.ship_rerun_at)" == 20*Z ]] || fail "the re-run is not recorded"
waits "the old failure still showing after the re-run"
[[ "$(grep -c '^run rerun' "$stub/gh.log")" == 1 ]] || fail "re-run twice"
checks "$(jq -c 'map(.completedAt = "2999-01-01T00:00:00Z")' <<<"$failing")"
returned "red again after the re-run" "Bash suites, Rust"
pass "a red check is re-run once; failing again, the bead goes back to a builder naming it"

fresh; checks '[{"name":"external","bucket":"fail","link":"https://ci.example/1","completedAt":"2020-01-01T00:00:00Z"}]'
returned "a check that is no Actions run" "external"
fresh; checks "$failing"; : > "$stub/rerun-fails"; returned "a run that cannot be re-run" "Bash suites"
pass "a red that cannot be re-run goes straight back"

parked() {
  sweep
  [[ "$out" == "parked cb-x #7 "*"$2"* ]] || fail "$1: said $out / $err"
  [[ "$(bead .status)" == open && "$(bead .assignee)" == "" ]] || fail "$1: the claim was not given back"
  [[ "$(bead '.labels | index("human") != null')" == true && "$(bead '.labels | index("shipping")')" == null ]] || fail "$1: labels $(bead .labels)"
  [[ "$(bead '.labels | index("planned") != null')" == true && "$(bead .metadata.paused_at)" == 20*Z ]] || fail "$1: plan or pause date lost"
  [[ "$(bead .notes)" == *"## Parked by shipping"*"$2"* ]] || fail "$1: the note is $(bead .notes)"
  if gh_called "pr merge 7 .*" && [[ "${3:-}" != merge-tried ]]; then fail "$1: merged"; fi
}
fresh; pr_set '.state = "CLOSED"'; parked "a closed pull request" "closed without merging"
fresh; echo "navigator_gates merge" >> "$consumer/.cerebro/project.conf"; parked "a merge gate" "merge gate"
fresh; overdue; checks '[{"name":"Bash","bucket":"pending","link":"","completedAt":""}]'; parked "a check pending for six hours" "6 hours"
fresh; overdue; MERGE_MODE=refused; export MERGE_MODE; parked "a merge refused for six hours" "6 hours" merge-tried; unset MERGE_MODE
fresh; checks "$failing"; board_set '.[0].notes = "## Sent back from shipping\na\n## Sent back from shipping\nb\n## Sent back from shipping\nc" | .[0].metadata.ship_rerun_at = "2000-01-01T00:00:00Z"'
parked "a fourth return" "fourth"
pass "a closed pull request, a merge gate, six hours of waiting and a fourth return go to the navigator"

fresh; pr_set '.mergeable = "CONFLICTING"'
board_set '.[0].notes = "## Sent back from shipping\na\n## Sent back from shipping\nb\n## Sent back from shipping\nc\n## Parked by shipping\nd"'
returned "the first return after the navigator unparked it" "conflicts"
pass "a park by shipping starts the three-attempt budget again"

for held in BLOCKED DRAFT; do
  fresh; pr_set ".mergeStateStatus = \"$held\""; waits "a pull request GitHub reports $held"
  overdue; sweep
  [[ "$out" == "parked cb-x #7 "*"$held"* ]] || fail "$held for six hours: $out"
done
pass "a blocked or draft pull request waits quietly, then goes to the navigator"

fresh; checks "$failing"; board_set '.[0].metadata.ship_rerun_at = "2020-06-01T00:00:00Z"'
returned "a re-run that never started" "never showed"
pass "a re-run that shows nothing for half an hour sends the bead back"

# --- a hand-back whose unclaim failed is finished by the next sweep -------------------------------

fresh; pr_set '.mergeable = "CONFLICTING"'; : > "$stub/unclaim-fails"; sweep
[[ "$out" == "failed cb-x #7 "* ]] || fail "a failed unclaim: $out"
rm "$stub/unclaim-fails"; sweep
[[ "$(bead .status)" == open && "$(bead .assignee)" == "" ]] || fail "the next sweep left it held by ship: $out"
pass "a hand-back whose unclaim failed is finished by the next sweep"

# --- beads ship does not hold are not touched -----------------------------------------------------

fresh; board_set '.[0].assignee = "Storm"'; sweep
[[ -z "$out" && ! -e "$stub/gh.log" ]] || fail "a bead a builder holds was touched: $out"
fresh; board_set '.[0] |= (.assignee = "Storm" | del(.labels[2]))'; : > "$stub/unfiltered-fails"; sweep
[[ -z "$out" && "$(bead .assignee)" == Storm ]] || fail "a listing that ignored the filter moved a builder's bead: $out"
! grep -q '^-C .* unclaim\|unclaim' "$stub/bd.log" || fail "it tried to unclaim another's bead"
pass "only beads held by ship are swept, whatever the listing returns"

suite_passed
