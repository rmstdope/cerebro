# shellcheck shell=bash
#
# The one place bash answers "did this bead's work reach the default branch" (cb-10d.4).
#
#     source "$script_dir/bead-delivery.sh"
#     cerebro_bead_delivered <repository root> <default branch> <bead id>
#
# Sourced, never executed, and sets no shell options of its own: it works under `set -e` and
# without it. Its caller is `scripts/release-bead --ended`, which sets `script_dir` (the function
# reads `project-conf` beside it) and fetches origin/<default branch> first.
#
# Returns 0 when a commit on origin/<default branch> names the bead and is not a non-delivery
# commit, 1 otherwise - including "only a mockup commit matched".
#
# How a commit names the bead is `commit_ref_pattern`, default `({id}):`. The default is the
# Conventional-Commits scope, and the colon and parens matter: bare "<id>" also matches "<id>.8", a
# child of this bead. `{id}` is SUBSTITUTED, not concatenated as a prefix (ah-qled.4): a consumer
# whose subjects read `PROJ-9 done:` or put the id anywhere but the front could not be expressed by
# a prefix, and would silently read every bead as undelivered. `git log --grep` takes `-F`, or the
# parentheses are a regex group that matches `<id>:` too.
#
# What is NOT a delivery is `non_delivery_commit_pattern` - here, the planner's mockup commit. It
# DEFAULTS TO EMPTY, because excluding a subject nobody else writes is one project's convention
# rather than a fact about delivery; a consumer that wants it declares it.

cerebro_bead_delivered() {
  local root="$1" branch="$2" id="$3"
  local ref_pattern non_delivery matches kept
  ref_pattern="$("$script_dir/project-conf" commit_ref_pattern '({id}):' 2>/dev/null || echo '({id}):')"
  if [[ -z "$ref_pattern" ]]; then
    ref_pattern='({id}):'
  fi
  non_delivery="$("$script_dir/project-conf" non_delivery_commit_pattern 2>/dev/null || true)"

  matches="$(git -C "$root" log "origin/$branch" --grep "${ref_pattern//\{id\}/$id}" -F --oneline 2>/dev/null || true)"
  if [[ -n "$non_delivery" && -n "$matches" ]]; then
    # `grep -v` exits 1 when it filters every line; that is an answer, not a failure.
    kept="$(printf '%s\n' "$matches" | grep -vF "${non_delivery//\{id\}/$id}" || true)"
  else
    kept="$matches"
  fi
  if [[ -n "$kept" ]]; then
    return 0
  fi
  return 1
}
