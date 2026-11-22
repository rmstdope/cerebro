#!/usr/bin/env bash
#
# Proves `scripts/dependabot-sweep` (cb-hpwc): Cerebro runs it on every turn, and it merges every
# open Dependabot pull request whose CI passed, files exactly one P4 bug bead on the bugfixer's route
# for every one whose CI failed (never re-running CI, never merging it), and moves an existing bead
# onto the pull request Dependabot replaced its pull request with instead of filing a second.
#
# `gh` and `bd` are stubs: `gh` answers from per-case fixtures and logs every call, `bd` keeps the
# board in one JSON file and applies `create` and `update` to it, so a second sweep reads what the
# first one wrote.
#
#     bash tests/dependabot-sweep.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --copy)"
sweep="$consumer/.cerebro/cerebro/scripts/dependabot-sweep"
stub="$work_dir/stub"
mkdir -p "$stub"

cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_DIR/gh.log"
case "$1 $2" in
  "pr list")
    [[ -e "$STUB_DIR/list-fails" ]] && { echo "gh: could not resolve to a repository" >&2; exit 1; }
    cat "$STUB_DIR/prs.json" ;;
  "pr view")
    [[ -e "$STUB_DIR/pr-$3.json" ]] || { echo "gh: no pull requests found" >&2; exit 1; }
    cat "$STUB_DIR/pr-$3.json" ;;
  "pr merge")
    [[ -e "$STUB_DIR/merge-fails-$3" ]] && { echo "X Pull request is not mergeable: the base branch policy prohibits the merge." >&2; exit 1; }
    echo "merged $3" >> "$STUB_DIR/merged" ;;
  *) echo "dependabot-sweep stub: unexpected gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
board="$STUB_DIR/board.json"
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--actor) shift 2 ;;
    --readonly) shift ;;
    *) break ;;
  esac
done
sub="$1"; shift
edit() { local tmp="$board.tmp"; jq "$@" "$board" > "$tmp" && mv "$tmp" "$board"; }
case "$sub" in
  list)
    [[ -e "$STUB_DIR/bd-fails" ]] && { echo "bd: database unreachable" >&2; exit 1; }
    # As bd does: closed beads only with --all, and 50 rows unless -n says otherwise.
    key=""; all=false; limit=50
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --has-metadata-key) key="$2"; shift 2 ;;
        --all) all=true; shift ;;
        -n|--limit) limit="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    jq --arg key "$key" --argjson all "$all" --argjson limit "$limit" '
      [ .[] | select(.metadata[$key] != null) | select($all or .status != "closed") ]
      | if $limit > 0 then .[:$limit] else . end' "$board" ;;
  create)
    [[ -e "$STUB_DIR/create-fails" ]] && { echo "bd: create refused" >&2; exit 1; }
    title="$1"; shift
    type=task; labels=""; priority=2; metadata='{}'; body=""; acceptance=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type|-t) type="$2"; shift 2 ;;
        --labels|-l) labels="$2"; shift 2 ;;
        -p|--priority) priority="$2"; shift 2 ;;
        --metadata) metadata="$2"; shift 2 ;;
        --body-file) body="$(cat "$2")"; shift 2 ;;
        --description|-d) body="$2"; shift 2 ;;
        --acceptance) acceptance="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    id="cb-d$(jq length "$board")"
    edit --arg id "$id" --arg title "$title" --arg type "$type" --arg labels "$labels" \
         --argjson priority "$priority" --argjson metadata "$metadata" --arg body "$body" \
         --arg acceptance "$acceptance" \
      '. + [{id: $id, title: $title, issue_type: $type, status: "open", priority: $priority,
             labels: ($labels | split(",") | map(select(. != ""))), metadata: $metadata,
             description: $body, acceptance_criteria: $acceptance, notes: ""}]'
    echo "$id" ;;
  update)
    [[ -e "$STUB_DIR/update-fails" ]] && { echo "bd: update refused" >&2; exit 1; }
    id="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) edit --arg id "$id" --arg v "$2" 'map(if .id == $id then .title = $v else . end)'; shift 2 ;;
        --description|-d) edit --arg id "$id" --arg v "$2" 'map(if .id == $id then .description = $v else . end)'; shift 2 ;;
        --body-file) edit --arg id "$id" --arg v "$(cat "$2")" 'map(if .id == $id then .description = $v else . end)'; shift 2 ;;
        --append-notes) edit --arg id "$id" --arg v "$2" 'map(if .id == $id then .notes = (.notes + $v) else . end)'; shift 2 ;;
        --set-metadata)
          edit --arg id "$id" --arg k "${2%%=*}" --arg v "${2#*=}" 'map(if .id == $id then .metadata[$k] = $v else . end)'
          shift 2 ;;
        *) shift ;;
      esac
    done ;;
  dolt) echo push >> "$STUB_DIR/pushed" ;;
  *) echo "dependabot-sweep stub: unexpected bd $sub" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/bd"

# --- fixtures -------------------------------------------------------------------------------------

# A fresh case: an empty board, no logs, no failure switches, the given open pull requests, and no
# dependabot_merge declared (merge_mode sets one).
reset_case() {
  rm -f "$consumer/.cerebro/project.conf"
  rm -f "$stub"/*.json "$stub"/*.log "$stub/merged" "$stub/pushed" "$stub"/*-fails*
  echo '[]' > "$stub/board.json"
  printf '%s' "${1:-[]}" > "$stub/prs.json"
}

# pr <number> <rollup JSON> [branch] - one open Dependabot pull request, as `gh pr list` prints it.
pr() {
  jq -cn --argjson n "$1" --argjson rollup "$2" --arg branch "${3:-dependabot/npm_and_yarn/dep-$1}" \
    '{number: $n, title: "Bump dep-\($n) from 1.0.0 to 2.0.0", url: "https://github.com/o/r/pull/\($n)",
      headRefName: $branch, headRefOid: "head-\($n)", statusCheckRollup: $rollup}'
}
prs() { jq -cs . <<<"$(printf '%s\n' "$@")"; }

run() { STUB_DIR="$stub" PATH="$stub:$PATH" bash "$sweep" "$@"; }

success='{"__typename":"CheckRun","name":"Tests","status":"COMPLETED","conclusion":"SUCCESS"}'
skipped='{"__typename":"CheckRun","name":"Docs","status":"COMPLETED","conclusion":"SKIPPED"}'
neutral='{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"NEUTRAL"}'
failure='{"__typename":"CheckRun","name":"Tests","status":"COMPLETED","conclusion":"FAILURE"}'
cancelled='{"__typename":"CheckRun","name":"Tests","status":"COMPLETED","conclusion":"CANCELLED"}'
running='{"__typename":"CheckRun","name":"E2E","status":"IN_PROGRESS","conclusion":""}'
ctx_pending='{"__typename":"StatusContext","context":"ci/legacy","state":"PENDING"}'
ctx_error='{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}'

board() { cat "$stub/board.json"; }
merge_mode() { mkdir -p "$consumer/.cerebro"; printf 'dependabot_merge %s\n' "$1" > "$consumer/.cerebro/project.conf"; }
merged() { cat "$stub/merged" 2>/dev/null || true; }

# --- a green pull request is merged, majors included, with no review --------------------------------

reset_case "$(prs "$(pr 1 "[$success,$skipped,$neutral]")")"
out="$(run)" || fail "a sweep over one green pull request exited non-zero"
[[ "$(merged)" == "merged 1" ]] || fail "the green pull request was not merged: [$(merged)]"
grep -qx 'pr merge 1 --squash --delete-branch' "$stub/gh.log" || fail "the merge was not a squash: $(cat "$stub/gh.log")"
grep -q 'merged #1' <<<"$out" || fail "the sweep did not report the merge: $out"
[[ "$(board)" == "[]" ]] || fail "a green pull request filed a bead"
[[ ! -e "$stub/pushed" ]] || fail "a sweep that wrote nothing pushed the board"
pass "a green pull request is merged with --squash, and nothing is filed"

# --- a pull request whose CI has not finished waits -------------------------------------------------

for rollup in "[]" "[$success,$running]" "[$ctx_pending]"; do
  reset_case "$(prs "$(pr 3 "$rollup")")"
  out="$(run)" || fail "a sweep over a pending pull request ($rollup) exited non-zero"
  [[ -z "$(merged)" ]] || fail "a pull request with CI unfinished ($rollup) was merged"
  [[ "$(board)" == "[]" ]] || fail "a pull request with CI unfinished ($rollup) filed a bead"
  grep -q 'waiting #3' <<<"$out" || fail "the sweep did not say #3 waits ($rollup): $out"
done
pass "no checks, a running check, or a pending status: the pull request waits"

# --- a red pull request gets exactly one P4 bug bead, and stays open ----------------------------------

for rollup in "[$failure]" "[$cancelled]" "[$ctx_error]" "[$failure,$running]"; do
  reset_case "$(prs "$(pr 2 "$rollup")")"
  out="$(run)" || fail "a sweep over a red pull request ($rollup) exited non-zero"
  [[ -z "$(merged)" ]] || fail "a red pull request ($rollup) was merged"
  [[ "$(jq length <<<"$(board)")" == 1 ]] || fail "a red pull request ($rollup) did not file exactly one bead: $(board)"
  bead="$(jq -c '.[0]' <<<"$(board)")"
  [[ "$(jq -r .issue_type <<<"$bead")" == bug ]] || fail "the bead is not a bug: $bead"
  jq -e '.labels | index("bugfix")' <<<"$bead" >/dev/null || fail "the bead is not on the bugfixer's route: $bead"
  [[ "$(jq -r .priority <<<"$bead")" == 4 ]] || fail "the bead was not filed unranked at P4: $bead"
  [[ "$(jq -r '.metadata.dependabot_pr | tostring' <<<"$bead")" == 2 ]] || fail "the bead does not record its pull request: $bead"
  grep -q '#2' <<<"$(jq -r .title <<<"$bead")" || fail "the bead's title does not name #2: $bead"
  grep -qF 'https://github.com/o/r/pull/2' <<<"$(jq -r .description <<<"$bead")" || fail "the bead's description does not link the pull request: $bead"
  grep -qF 'dependabot/npm_and_yarn/dep-2' <<<"$(jq -r .description <<<"$bead")" || fail "the bead's description does not name the branch: $bead"
  ! grep -q 'rerun\|merge' "$stub/gh.log" || fail "the sweep re-ran or merged a red pull request: $(cat "$stub/gh.log")"
  grep -q "filed cb-d0 for #2" <<<"$out" || fail "the sweep did not report the bead it filed: $out"
  [[ "$(wc -l < "$stub/pushed")" -eq 1 ]] || fail "the board was not pushed exactly once after filing"
done
grep -qF 'Tests' <<<"$(jq -r '.[0].description' <<<"$(board)")" || fail "the bead does not name the failing check"
pass "a failed, cancelled or errored check files one P4 bugfix bug naming the pull request, with no re-run"

# --- a later sweep files no second bead ---------------------------------------------------------------

reset_case "$(prs "$(pr 2 "[$failure]")")"
run >/dev/null || fail "the first sweep exited non-zero"
out="$(run)" || fail "the second sweep exited non-zero"
[[ "$(jq length <<<"$(board)")" == 1 ]] || fail "a second sweep filed a second bead: $(board)"
grep -q 'held by cb-d0' <<<"$out" || fail "the second sweep did not say the bead holds #2: $out"

# Nor once that bead is closed while its pull request is still open.
jq 'map(.status = "closed")' "$stub/board.json" > "$stub/b.tmp" && mv "$stub/b.tmp" "$stub/board.json"
run >/dev/null || fail "a sweep over a closed bead's open pull request exited non-zero"
[[ "$(jq length <<<"$(board)")" == 1 ]] || fail "a closed bead's open pull request was filed again"
pass "a pull request that already has a bead is never filed twice"

# --- a pull request a bead holds is the bead's, even once green ----------------------------------------

reset_case "$(prs "$(pr 2 "[$success]")")"
echo '[{"id":"cb-h","status":"in_progress","title":"t","metadata":{"dependabot_pr":"2"},"notes":""}]' > "$stub/board.json"
out="$(run)" || fail "a sweep over a held green pull request exited non-zero"
[[ -z "$(merged)" ]] || fail "the sweep merged a pull request a bead holds"
grep -q 'held by cb-h' <<<"$out" || fail "the sweep did not say cb-h holds #2: $out"
pass "a green pull request a bead holds is left to whoever takes the bead"

# --- a replaced pull request: the bead follows it ------------------------------------------------------

follow_case() {
  # $1: the replacement's branch; $2: the old pull request's view
  reset_case "$(prs "$(pr 5 "[$failure]" "$1")")"
  echo '[{"id":"cb-f","status":"open","issue_type":"bug","title":"Dependabot update fails CI: #2","description":"old","metadata":{"dependabot_pr":"2"},"notes":""}]' \
    > "$stub/board.json"
  printf '%s' "$2" > "$stub/pr-2.json"
}

superseded='{"state":"CLOSED","headRefName":"dependabot/npm_and_yarn/dep-2","comments":[
  {"author":{"login":"dependabot"},"body":"Looks like this is being regrouped."},
  {"author":{"login":"dependabot"},"body":"Superseded by #5."}]}'
same_branch='{"state":"CLOSED","headRefName":"dependabot/npm_and_yarn/group-x","comments":[]}'

for shape in superseded same_branch; do
  if [[ "$shape" == superseded ]]; then
    follow_case dependabot/npm_and_yarn/group-y "$superseded"
  else
    follow_case dependabot/npm_and_yarn/group-x "$same_branch"
  fi
  out="$(run)" || fail "a sweep following a replaced pull request ($shape) exited non-zero"
  [[ "$(jq length <<<"$(board)")" == 1 ]] || fail "the replacement ($shape) got a second bead: $(board)"
  bead="$(jq -c '.[0]' <<<"$(board)")"
  [[ "$(jq -r '.metadata.dependabot_pr | tostring' <<<"$bead")" == 5 ]] || fail "the bead ($shape) does not name the replacement: $bead"
  grep -q '#5' <<<"$(jq -r .title <<<"$bead")" || fail "the bead's title ($shape) does not name #5: $bead"
  grep -qF 'https://github.com/o/r/pull/5' <<<"$(jq -r .description <<<"$bead")" || fail "the bead's description ($shape) does not link #5: $bead"
  grep -q '#2' <<<"$(jq -r .notes <<<"$bead")" && grep -q '#5' <<<"$(jq -r .notes <<<"$bead")" \
    || fail "the bead's notes ($shape) do not record the replacement: $bead"
  grep -q 'followed cb-f from #2 to #5' <<<"$out" || fail "the sweep did not report the follow ($shape): $out"
  [[ -e "$stub/pushed" ]] || fail "the follow ($shape) was not pushed"
done
pass "a bead follows the pull request Dependabot replaced its own with, by comment or by branch"

# --- an old pull request merged, or closed with no replacement ------------------------------------------

follow_case dependabot/npm_and_yarn/other '{"state":"MERGED","headRefName":"dependabot/npm_and_yarn/dep-2","comments":[]}'
out="$(run)" || fail "a sweep over a bead whose pull request merged exited non-zero"
[[ "$(jq -r '.[0].metadata.dependabot_pr' <<<"$(board)")" == 2 ]] || fail "a merged pull request's bead was moved"

follow_case dependabot/npm_and_yarn/other '{"state":"CLOSED","headRefName":"dependabot/npm_and_yarn/dep-2","comments":[]}'
out="$(run)" || fail "a sweep over an orphaned bead exited non-zero"
[[ "$(jq -r '.[0].metadata.dependabot_pr' <<<"$(board)")" == 2 ]] || fail "an orphaned bead was moved"
grep -q 'orphaned cb-f' <<<"$out" || fail "the sweep did not report the orphaned bead: $out"
[[ "$(jq length <<<"$(board)")" == 2 ]] || fail "the unrelated red #5 was not filed on its own: $(board)"
follow_case dependabot/npm_and_yarn/dep-2 '{"state":"CLOSED","headRefName":"dependabot/npm_and_yarn/dep-2","comments":[]}'
jq '. + [{"id":"cb-g","status":"open","title":"t","metadata":{"dependabot_pr":"5"},"notes":""}]' "$stub/board.json" > "$stub/b.tmp"
mv "$stub/b.tmp" "$stub/board.json"
out="$(run)" || fail "a sweep over a bead whose replacement has its own bead exited non-zero"
[[ "$(jq -r '.[0].metadata.dependabot_pr' <<<"$(board)")" == 2 ]] || fail "a bead was moved onto a pull request another bead names"
grep -q 'orphaned cb-f: #2 was replaced by #5, which cb-g already names' <<<"$out" \
  || fail "the sweep did not say the replacement has its own bead: $out"
pass "a bead whose pull request merged stays; one closed with no replacement, or replaced by one another bead names, is reported, not moved"

# --- failed reads act on nothing -----------------------------------------------------------------------

reset_case "$(prs "$(pr 1 "[$success]")" "$(pr 2 "[$failure]")")"
touch "$stub/list-fails"
set +e; out="$(run 2>&1)"; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "a failed gh pr list exited $status, not 1"
[[ -z "$(merged)" && "$(board)" == "[]" ]] || fail "a failed gh pr list still acted"
grep -q 'dependabot-sweep' <<<"$out" || fail "a failed gh pr list said nothing on stderr: $out"

reset_case "$(prs "$(pr 1 "[$success]")" "$(pr 2 "[$failure]")")"
touch "$stub/bd-fails"
set +e; run >/dev/null 2>&1; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "a failed bd list exited $status, not 1"
[[ -z "$(merged)" && "$(board)" == "[]" ]] || fail "a failed bd list still acted"

follow_case dependabot/npm_and_yarn/other '{}'
rm -f "$stub/pr-2.json"
set +e; out="$(run 2>/dev/null)"; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "an unreadable old pull request exited $status, not 1"
[[ "$(jq length <<<"$(board)")" == 2 ]] || fail "an unreadable old pull request stopped the rest of the sweep"
pass "an unreadable list exits 1 having acted on nothing; an unreadable old pull request exits 1 after the rest"

# --- a refused merge is reported and the sweep goes on -----------------------------------------------------

reset_case "$(prs "$(pr 1 "[$success]")" "$(pr 4 "[$success]")")"
touch "$stub/merge-fails-1"
out="$(run 2>/dev/null)" || fail "a refused merge made the sweep exit non-zero"
grep -q 'merge refused #1' <<<"$out" || fail "the refused merge was not reported: $out"
grep -qF 'base branch policy' <<<"$out" || fail "the refusal does not say why: $out"
[[ "$(merged)" == "merged 4" ]] || fail "a refused merge stopped the next one: [$(merged)]"
pass "a refused merge is reported with gh's reason, and the next pull request is still merged"

# --- a failed write is a line and a status, and the sweep goes on ------------------------------------------

reset_case "$(prs "$(pr 2 "[$failure]")" "$(pr 1 "[$success]")")"
touch "$stub/create-fails"
set +e; out="$(run 2>"$stub/err")"; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "a refused bd create exited $status, not 1"
[[ "$(merged)" == "merged 1" ]] || fail "a refused bd create stopped the green merge: [$(merged)]"
grep -q 'bd create' "$stub/err" || fail "a refused bd create said nothing on stderr: $(cat "$stub/err")"

follow_case dependabot/npm_and_yarn/other "$superseded"
jq '. + [{"number": 1, "title": "Bump dep-1", "url": "u", "headRefName": "b1", "statusCheckRollup": ['"$success"']}]' \
  "$stub/prs.json" > "$stub/p.tmp" && mv "$stub/p.tmp" "$stub/prs.json"
touch "$stub/update-fails"
set +e; out="$(run 2>/dev/null)"; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "a refused bd update exited $status, not 1"
[[ "$(merged)" == "merged 1" ]] || fail "a refused bd update stopped the green merge: [$(merged)]"
[[ -e "$stub/pushed" ]] || fail "the bead filed after a refused update was not pushed"
pass "a refused bd write exits 1 after the rest of the sweep, and what was written is pushed"

# --- a merge that fails after merging is a merge -------------------------------------------------------------

reset_case "$(prs "$(pr 1 "[$success]")")"
touch "$stub/merge-fails-1"
echo '{"state":"MERGED"}' > "$stub/pr-1.json"
out="$(run 2>/dev/null)" || fail "a merge that failed after merging made the sweep exit non-zero"
grep -q 'merged #1' <<<"$out" || fail "a pull request merged before gh failed was not reported merged: $out"
pass "a pull request gh merged before failing (the branch delete) is reported merged"

# --- dependabot_merge review: a green pull request is never merged by the sweep (cb-au3o) -----------

reset_case "$(prs "$(pr 1 "[$success]")" "$(pr 2 "[$failure]")")"
merge_mode review
out="$(run)" || fail "a review-mode sweep exited non-zero"
[[ -z "$(merged)" ]] || fail "a review-mode sweep merged: [$(merged)]"
! grep -q '^pr merge' "$stub/gh.log" || fail "a review-mode sweep called gh pr merge: $(cat "$stub/gh.log")"
grep -qx 'awaiting review #1 Bump dep-1 from 1.0.0 to 2.0.0' <<<"$out" || fail "the green pull request was not reported awaiting review: $out"
[[ "$(jq length <<<"$(board)")" == 1 ]] || fail "review mode filed other than the one red bead: $(board)"
jq -e '.[0].labels | index("bugfix")' <<<"$(board)" >/dev/null || fail "the red pull request's bead is not a bugfix bead: $(board)"
grep -q 'filed cb-d0 for #2' <<<"$out" || fail "review mode did not file the red pull request: $out"
pass "under dependabot_merge review a green pull request awaits review and a red one is still filed"

reset_case "$(prs "$(pr 1 "[$success]")")"
merge_mode revew
out="$(run 2>"$stub/err")" || fail "a sweep with an unknown dependabot_merge exited non-zero"
[[ -z "$(merged)" ]] || fail "an unknown dependabot_merge value merged unreviewed"
grep -q 'awaiting review #1' <<<"$out" || fail "an unknown value did not fall back to review: $out"
grep -q 'revew' "$stub/err" || fail "an unknown value was not announced on stderr: $(cat "$stub/err")"
pass "an unknown dependabot_merge value is announced and treated as review"

reset_case "$(prs "$(pr 1 "[$success]")")"
merge_mode auto
out="$(run)" || fail "an auto-mode sweep exited non-zero"
[[ "$(merged)" == "merged 1" ]] || fail "dependabot_merge auto did not merge: [$(merged)]"
pass "dependabot_merge auto merges as an absent key does"

# --- --merge: the one merge after a review, at the reviewed head ---------------------------------------

reset_case "$(prs "$(pr 1 "[$success]")")"
merge_mode review
out="$(run --merge 1 head-1)" || fail "--merge at the reviewed head exited non-zero"
[[ "$(merged)" == "merged 1" ]] || fail "--merge at the reviewed head did not merge: [$(merged)]"
grep -qx 'pr merge 1 --squash --delete-branch --match-head-commit head-1' "$stub/gh.log" \
  || fail "--merge did not squash with GitHub holding it to the reviewed head: $(cat "$stub/gh.log")"
grep -q 'merged #1' <<<"$out" || fail "--merge did not report the merge: $out"
pass "--merge merges a green pull request at the head that was reviewed, held there by GitHub"

reset_case "$(prs "$(pr 1 "[$success]")")"
merge_mode review
touch "$stub/merge-fails-1"
set +e; out="$(run --merge 1 head-1 2>/dev/null)"; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "--merge that GitHub refused exited $status, not 1"
grep -q 'merge refused #1' <<<"$out" || fail "--merge did not report GitHub's refusal: $out"
grep -qF 'base branch policy' <<<"$out" || fail "--merge's refusal does not say why: $out"
pass "--merge that GitHub refuses says why and exits 1"

# A pull request gh lists with no head still reads its title right, and is never merged.
reset_case "$(prs "$(pr 1 "[$success]" | jq -c 'del(.headRefOid)')")"
merge_mode review
out="$(run)" || fail "a sweep over a pull request with no head exited non-zero"
grep -qx 'awaiting review #1 Bump dep-1 from 1.0.0 to 2.0.0' <<<"$out" || fail "a missing head shifted the title: $out"
pass "a pull request listed with no head keeps its title"

refuse_merge() {  # <why> <args...>
  local why="$1"; shift
  set +e; out="$(run "$@" 2>"$stub/err")"; status=$?; set -e
  [[ "$status" -eq 1 ]] || fail "--merge $why exited $status, not 1"
  [[ -z "$(merged)" ]] || fail "--merge $why merged"
  [[ -s "$stub/err" ]] || fail "--merge $why said nothing on stderr"
}
reset_case "$(prs "$(pr 1 "[$success]")")"; merge_mode review
refuse_merge "with a head that moved since the review" --merge 1 head-old
reset_case "$(prs "$(pr 1 "[$running]")")"; merge_mode review
refuse_merge "with CI unfinished" --merge 1 head-1
reset_case "$(prs "$(pr 1 "[$failure]")")"; merge_mode review
refuse_merge "with CI red" --merge 1 head-1
reset_case "$(prs "$(pr 1 "[$success]")")"; merge_mode review
refuse_merge "of a pull request that is not an open Dependabot one" --merge 7 head-7
reset_case "$(prs "$(pr 1 "[$success]")")"; merge_mode review
echo '[{"id":"cb-h","status":"open","title":"t","metadata":{"dependabot_pr":"1"},"notes":""}]' > "$stub/board.json"
refuse_merge "of a pull request a bead holds" --merge 1 head-1
pass "--merge refuses a moved head, unfinished or red CI, a stranger, and a held pull request"

# --- --hand-back: a review with findings goes to the navigator as a bead -------------------------------

reset_case "$(prs "$(pr 1 "[$success]")")"
merge_mode review
printf '%s\n' '**Review (cold read)**' '' '1. The lockfile pulls in a second copy of dep-1.' > "$stub/review.md"
out="$(run --hand-back 1 "$stub/review.md")" || fail "--hand-back exited non-zero"
[[ -z "$(merged)" ]] || fail "--hand-back merged"
[[ "$(jq length <<<"$(board)")" == 1 ]] || fail "--hand-back did not file exactly one bead: $(board)"
bead="$(jq -c '.[0]' <<<"$(board)")"
jq -e '.labels | index("human")' <<<"$bead" >/dev/null || fail "the hand-back bead is not in the navigator's queue: $bead"
! jq -e '.labels | index("bugfix")' <<<"$bead" >/dev/null || fail "the hand-back bead went to the bugfixer: $bead"
[[ "$(jq -r .priority <<<"$bead")" == 4 ]] || fail "the hand-back bead was not filed at P4: $bead"
[[ "$(jq -r '.metadata.dependabot_pr | tostring' <<<"$bead")" == 1 ]] || fail "the hand-back bead does not record its pull request: $bead"
grep -qF 'https://github.com/o/r/pull/1' <<<"$(jq -r .description <<<"$bead")" || fail "the hand-back bead does not link the pull request: $bead"
grep -qF 'second copy of dep-1' <<<"$(jq -r .description <<<"$bead")" || fail "the hand-back bead does not carry the review: $bead"
! grep -qF 'head-1' <<<"$(jq -r .description <<<"$bead")" || fail "the hand-back bead names a head the sweep never saw reviewed: $bead"
grep -q 'handed back cb-d0 for #1' <<<"$out" || fail "--hand-back did not report the bead: $out"
[[ "$(wc -l < "$stub/pushed")" -eq 1 ]] || fail "the hand-back was not pushed exactly once"
out="$(run)" || fail "a sweep after a hand-back exited non-zero"
grep -q 'held by cb-d0 #1' <<<"$out" || fail "a later sweep did not leave the handed-back pull request held: $out"
! grep -q 'awaiting review' <<<"$out" || fail "a handed-back pull request was offered for review again: $out"
set +e; run --hand-back 1 "$stub/review.md" >/dev/null 2>&1; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "a second --hand-back of a held pull request exited $status, not 1"
[[ "$(jq length <<<"$(board)")" == 1 ]] || fail "a second --hand-back filed a second bead"
set +e; run --hand-back 9 "$stub/review.md" >/dev/null 2>&1; status=$?; set -e
[[ "$status" -eq 1 ]] || fail "--hand-back of a stranger exited $status, not 1"
pass "--hand-back files one P4 human bead naming the pull request and its review, which then holds it"

# A replaced pull request moves a hand-back bead without rewriting its review into a CI failure.
follow_case dependabot/npm_and_yarn/group-y "$superseded"
jq 'map(.issue_type = "task" | .title = "Dependabot update has review findings: #2" | .description = "the review")' \
  "$stub/board.json" > "$stub/b.tmp" && mv "$stub/b.tmp" "$stub/board.json"
out="$(run)" || fail "a sweep following a hand-back bead exited non-zero"
bead="$(jq -c '.[0]' <<<"$(board)")"
[[ "$(jq -r '.metadata.dependabot_pr | tostring' <<<"$bead")" == 5 ]] || fail "the hand-back bead was not moved: $bead"
[[ "$(jq -r .description <<<"$bead")" == "the review" ]] || fail "following rewrote a hand-back bead's description: $bead"
grep -q 'review findings' <<<"$(jq -r .title <<<"$bead")" || fail "following rewrote a hand-back bead's title: $bead"
pass "a replaced pull request moves a hand-back bead and keeps its review"

# --- bad arguments ---------------------------------------------------------------------------------------

for args in "extra" "--merge 1" "--merge" "--hand-back 1" "--merge one head-1"; do
  set +e; run $args >/dev/null 2>&1; status=$?; set -e
  [[ "$status" -eq 2 ]] || fail "dependabot-sweep $args exited $status, not 2"
done
pass "bad arguments exit 2"

# --- nothing open -----------------------------------------------------------------------------------------

reset_case
out="$(run)" || fail "a sweep with nothing open exited non-zero"
[[ "$out" == "no open Dependabot pull requests" ]] || fail "a sweep with nothing open said: $out"
[[ ! -e "$stub/pushed" ]] || fail "a sweep with nothing open pushed"
pass "nothing open says so in one line"

suite_passed
