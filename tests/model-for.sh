#!/usr/bin/env bash
#
# Proves `scripts/model-for' is the one place `.cerebro/models.conf' is answered: given a name, a
# role and (optionally) a provider, it prints the matched key, its model and its effort, TAB
# separated, on one line - and NOTHING AT ALL when no key matched.
#
# The first eight cases are `tests/launchers.sh's models.conf cases re-asked directly of the
# resolver. That is what makes this a shared rule rather than a copy: the two suites answer the
# same questions of the same parser, one through the launcher and one at the source, so an
# extraction that changed behaviour goes red in one of them.
#
# The distinction the exact stdout comparisons are protecting is a MISS versus an answer of `-':
# `-' means "pass no --model at all", which is a real answer a caller must be able to tell from
# "the file said nothing". A miss therefore prints no line, not an empty one.
#
# Every fixture is built under this suite's own `$work_dir' (suites run in parallel, one per
# processor) and no case ever reads the navigator's real `.cerebro/models.conf' - the trap
# tests/launchers.sh records, where a suite was red on one machine and green in CI.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/model-for.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/model-for"
[[ -f "$script" ]] || fail "scripts/model-for does not exist"
[[ -x "$script" ]] || fail "scripts/model-for is not executable"

# --- the fixtures -------------------------------------------------------------------------------
#
# A consumer per case, each with its own models.conf. `model-for' is run from INSIDE it, at the
# standard mount, so it resolves that consumer's root the way it will in the field.
#
# `link_scripts' places the libraries `model-for' sources on its own (place-scripts derives them
# from its `source' lines); the scripts it FORKS - agent-cli, and consumer-root for the root
# fallback - are named here because a fork is not a source line.

new_consumer() {  # new_consumer <models.conf line>...
  local c
  c="$(consumer_new "$(fixture_name c)" --link model-for agent-cli consumer-root project-conf)"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$c/.cerebro/models.conf"
  fi
  echo "$c"
}

out=""
err=""
status=0
# Run `model-for' inside <consumer>. The environment is scrubbed of the root hints on purpose: they
# are inherited in the field from `launch', and a hint pointing at THIS checkout would answer for
# the wrong tree - `cerebro_hinted_root' rejects a foreign one, and this suite must exercise that
# path rather than the caller's.
run_in() {
  local c="$1"
  shift
  set +e
  out="$(cd "$c" && env -u CEREBRO_CONSUMER_ROOT -u CEREBRO_CONSUMER_SHARED_ROOT -u CEREBRO_CONSUMER_MOUNT \
           bash "$c/.claude/cerebro/scripts/model-for" "$@" 2>"$work_dir/stderr")"
  status=$?
  set -e
  err="$(cat "$work_dir/stderr")"
  return 0
}

# The three fields as one comparable string, so a case names what it expects rather than counting
# tabs. An empty effort still carries its tab, which is the contract a caller reading three fields
# with one `IFS=$'\t' read -r' depends on.
expect_line() {  # expect_line <key> <model> <effort> <what>
  local want
  want="$(printf '%s\t%s\t%s' "$1" "$2" "$3")"
  [[ "$out" == "$want" ]] || fail "$4: expected '$(printf '%s' "$want" | cat -A)', got '$(printf '%s' "$out" | cat -A)'"
  [[ "$status" -eq 0 ]] || fail "$4: expected exit 0, got $status"
}

expect_miss() {  # expect_miss <what>
  [[ -z "$out" ]] || fail "$1: expected nothing on stdout, got '$out'"
  [[ "$status" -eq 0 ]] || fail "$1: a miss is exit 0, got $status"
}

# --- 1: no models.conf at all -------------------------------------------------------------------

c="$(new_consumer)"
run_in "$c" --name Xavier --role planner
expect_miss "no models.conf"
pass "no models.conf: nothing on stdout, exit 0 - absence is an answer, not an error"

# --- 2: a default line answers for every agent --------------------------------------------------

c="$(new_consumer "default fable")"
run_in "$c" --name Xavier --role planner
expect_line default fable "" "default line"
pass "default: answers for an agent named by neither its name nor its role"

# --- 3: a role line answers that role only ------------------------------------------------------

c="$(new_consumer "# a comment" "" "planner fable low")"
run_in "$c" --name Xavier --role planner
expect_line planner fable low "role line"
run_in "$c" --name Forge --role architect
expect_miss "role line, another role"
pass "role: model and effort, past comments and blanks; a role not named is a miss"

# --- 4: an inline comment is not the effort column ----------------------------------------------

c="$(new_consumer "default opus # everything, with a note about why" "planner fable high  # and this role lower")"
run_in "$c" --name Xavier --role planner
expect_line planner fable high "inline comment, role"
run_in "$c" --name Forge --role architect
expect_line default opus "" "inline comment, default"
pass "comments: everything from a # on is stripped wherever it starts, so it is never the effort"

# --- 5: a name beats its role -------------------------------------------------------------------

c="$(new_consumer "planner fable" "Beast sonnet")"
run_in "$c" --name Beast --role planner
expect_line Beast sonnet "" "name beats role"
run_in "$c" --name Xavier --role planner
expect_line planner fable "" "name absent, role answers"
pass "precedence: the agent's own name beats its role"

# --- 6: `-' is an answer, not a miss ------------------------------------------------------------

c="$(new_consumer "Xavier -")"
run_in "$c" --name Xavier --role planner
expect_line Xavier - "" "a dash"
pass "a dash: 'pass no --model' is a real answer, and prints as one"

# --- 7: a provider-scoped key beats the plain one -----------------------------------------------

c="$(new_consumer "planner fable" "planner@claude sonnet")"
run_in "$c" --provider claude --name Xavier --role planner
expect_line "planner@claude" sonnet "" "provider-scoped key"
pass "provider: within one specificity, the @provider key wins"

# --- 8: a key scoped to another provider never matches ------------------------------------------

c="$(new_consumer "planner@copilot gpt-5.5")"
run_in "$c" --provider claude --name Xavier --role planner
expect_miss "another provider's key"
pass "provider: a key scoped to a provider this fleet is not on is never matched"

# --- 9: an unknown provider is warned about ONCE and ignored ------------------------------------

c="$(new_consumer "planner@copilo gpt-5.5")"
run_in "$c" --provider claude --name Xavier --role planner
expect_miss "unknown provider key"
warnings="$(printf '%s\n' "$err" | grep -c 'planner@copilo' || true)"
[[ "$warnings" -eq 1 ]] \
  || fail "unknown provider: expected exactly one warning naming the key, got $warnings in: $err"
pass "unknown provider: one warning per offending row per invocation, and the row ignored"

# --- 10: a key with an empty model column says nothing ------------------------------------------

c="$(new_consumer "planner" "default fable")"
run_in "$c" --name Xavier --role planner
expect_line default fable "" "empty model column"
pass "an empty model column says nothing, and the probes continue past it"

# --- 11: --provider omitted resolves the consumer's own agent_cli -------------------------------

c="$(new_consumer "planner@copilot gpt-5.5" "planner opus")"
printf 'agent_cli copilot\n' > "$c/.cerebro/project.conf"
run_in "$c" --name Xavier --role planner
expect_line "planner@copilot" gpt-5.5 "" "provider resolved"
pass "--provider omitted: the provider comes from the consumer's own agent_cli"

# --- 12: usage --------------------------------------------------------------------------------

c="$(new_consumer "default fable")"
run_in "$c" --nonsense x --name Xavier
[[ "$status" -eq 2 ]] || fail "usage: an unknown flag is exit 2, got $status"
[[ -z "$out" ]] || fail "usage: an unknown flag must print no answer, got '$out'"
run_in "$c" --provider claude
[[ "$status" -eq 2 ]] || fail "usage: neither --name nor --role is exit 2, got $status"
[[ -z "$out" ]] || fail "usage: expected no answer, got '$out'"
run_in "$c" --name
[[ "$status" -eq 2 ]] || fail "usage: a flag with no value is exit 2, got $status"
pass "usage: exit 2 and no answer at all, so a mistake can never be read as a miss"

# --- 13: a name containing an @ splits on the LAST one ------------------------------------------

c="$(new_consumer "a@b@claude fable")"
run_in "$c" --provider claude --name "a@b" --role planner
expect_line "a@b@claude" fable "" "last-@ split"
pass "the @ split is on the last @, so a name containing one keeps it"

suite_passed
