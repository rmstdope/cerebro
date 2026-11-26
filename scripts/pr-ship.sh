# shellcheck shell=bash
#
# The tail of shipping a pull request, shared by `scripts/ux-deliver` and `scripts/ship` (cb-tbrh):
# what its checks say, and a merge that is believed only when GitHub says MERGED.
#
# SOURCED, NEVER EXECUTED, and sets no shell options of its own. Every `gh` call runs in the current
# directory, so the caller has already `cd`ed to the repository it means.

# pr_checks <n> <errfile> - the pull request's checks as a JSON array of {name, bucket, link,
# completedAt}, read whatever gh's exit status (8 while pending, 1 on a failure). "No checks
# reported" is []. Anything else unreadable returns 1, with gh's own words left in <errfile>.
pr_checks() {
  local answer
  answer="$(gh pr checks "$1" --json name,bucket,link,completedAt 2>"$2" || true)"
  if [[ -z "$answer" ]] && grep -q "no checks reported" "$2"; then
    answer='[]'
  fi
  jq -e 'type == "array"' <<<"$answer" >/dev/null 2>&1 || return 1
  printf '%s' "$answer"
}

# pr_checks_verdict <json> - one word:
#   red          a check failed or was cancelled, and none is still running
#   pending-red  a check failed or was cancelled while another is still running
#   pending      one is still running
#   none         no checks at all
#   green        every check passed or was skipped
# A bucket this function does not know is pending: nothing unrecognised ever reads as green.
pr_checks_verdict() {
  jq -r '
    def red: .bucket == "fail" or .bucket == "cancel";
    def done_ok: .bucket == "pass" or .bucket == "skipping";
    if length == 0 then "none"
    elif any(.[]; red) then (if all(.[]; red or done_ok) then "red" else "pending-red" end)
    elif all(.[]; done_ok) then "green"
    else "pending" end' <<<"$1"
}

# pr_red_names <json> - the failed or cancelled checks' names, comma-separated.
pr_red_names() {
  jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")' <<<"$1"
}

# pr_merge <n> <errfile> [<gh pr merge flag>...] - squash-merge, then ask GitHub. Status 0 only when
# it says MERGED, whatever the merge call returned; 1 when it is not merged, with the merge's own
# words in <errfile>; 2 when GitHub could not be asked.
pr_merge() {
  local number="$1" errfile="$2" state
  shift 2
  gh pr merge "$number" --squash "$@" >/dev/null 2>"$errfile" || true
  state="$(gh pr view "$number" --json state --jq .state)" || return 2
  [[ "$state" == MERGED ]]
}
