#!/usr/bin/env bash
#
# Proves `scripts/agents-conf' is the one place `.cerebro/agents.conf' is answered: given a name and
# a role it prints EXACTLY ONE tab-separated line saying either which line won and what it carries,
# or which of the two ways it missed, or - on a malformed winning line - the refusal sentence the
# navigator agreed, word for word.
#
# The leading kind word (`hit'/`miss'/`refused') is what makes a caller's single
# `IFS=$'\t' read -r kind a b c d' unconditional: four outcomes, two of them needing different
# sentences from the caller, do not fit `model-for's convention of encoding a miss as an empty line.
#
# Every fixture is built under this suite's own `$work_dir' (suites run in parallel, one per
# processor) and no case ever reads the navigator's real `.cerebro/' - the trap tests/launchers.sh
# records, where a suite was red on one machine and green in CI.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the repository root:
#
#     bash tests/agents-conf.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# THE SUITE RUNS INSIDE A POLLUTED SESSION (cb-6fu). An implementer running this is itself a session
# the fleet view - a `cargo run' child - started, so its environment carries cargo's injections. The
# cases below assert stderr is EMPTY on every non-usage path, so a stray advisory from anything the
# script forks would be red here and green in CI, which is the shape ah-dy4x cost.
for _n in $(compgen -e || true); do
  case "$_n" in
    CARGO_HOME|CARGO_TARGET_DIR) ;;
    CARGO|CARGO_*|TS_RS_EXPORT_DIR) unset "$_n" ;;
  esac
done
unset _n
export CARGO_HOME="$work_dir/empty-cargo-home"
mkdir -p "$CARGO_HOME"

script="$repo_root/scripts/agents-conf"
[[ -f "$script" ]] || fail "scripts/agents-conf does not exist"
[[ -x "$script" ]] || fail "scripts/agents-conf is not executable"

# --- the fixtures -------------------------------------------------------------------------------
#
# A consumer per case, each with its own agents.conf. `agents-conf' is run from INSIDE it, at the
# standard mount, so it resolves that consumer's root the way it will in the field.
#
# `link_scripts' places the libraries `agents-conf' sources on its own (place-scripts derives them
# from its `source' lines); the scripts it FORKS - agent-cli, and consumer-root for the root
# fallback - are named here because a fork is not a source line.

new_consumer() {  # new_consumer [<agents.conf line>...]
  local c
  c="$(consumer_new "$(fixture_name c)" --link agents-conf agent-cli consumer-root project-conf)"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$c/.cerebro/agents.conf"
  fi
  echo "$c"
}

out=""
err=""
status=0
# Run `agents-conf' inside <consumer>. The environment is scrubbed of the root hints on purpose:
# they are inherited in the field from `launch', and a hint pointing at THIS checkout would answer
# for the wrong tree - `cerebro_hinted_root' rejects a foreign one, and this suite must exercise
# that path rather than the caller's.
run_in() {
  local c="$1"
  shift
  set +e
  out="$(cd "$c" && env -u CEREBRO_CONSUMER_ROOT -u CEREBRO_CONSUMER_SHARED_ROOT -u CEREBRO_CONSUMER_MOUNT \
           bash "$c/.claude/cerebro/scripts/agents-conf" "$@" 2>"$work_dir/stderr")"
  status=$?
  set -e
  err="$(cat "$work_dir/stderr")"
  return 0
}

expect_out() {  # expect_out <expected stdout> <expected status> <what>
  # `printf %q' rather than `cat -A': BSD cat has no -A, so a failure message must not itself be
  # the thing that fails on the navigator's machine.
  [[ "$out" == "$1" ]] || fail "$3: expected $(printf '%q' "$1"), got $(printf '%q' "$out")"
  [[ "$status" -eq "$2" ]] || fail "$3: expected exit $2, got $status"
  [[ -z "$err" ]] || fail "$3: expected nothing on stderr, got '$err'"
}

expect_hit() {  # expect_hit <key> <tool> <model> <effort> <what>
  expect_out "$(printf 'hit\t%s\t%s\t%s\t%s\tordinary\t\t\t\t' "$1" "$2" "$3" "$4")" 0 "$5"
}

expect_external() {  # expect_external <key> <tool> <model> <effort> <name> <provider> <url> <env> <what>
  expect_out "$(printf 'hit\t%s\t%s\t%s\t%s\texternal\t%s\t%s\t%s\t%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")" 0 "$9"
}

expect_unavailable_external() {  # expect_unavailable_external <key> <tool> <name> <effort> <what>
  expect_out "$(printf 'hit\t%s\t%s\t\t%s\texternal\t%s\t\t\t' \
    "$1" "$2" "$4" "$3")" 0 "$5"
}

# --- 1: usage -----------------------------------------------------------------------------------

c="$(new_consumer "default tool=claude")"
run_in "$c" --name Beast
[[ "$status" -eq 2 ]] || fail "usage: --name without --role is exit 2, got $status"
[[ -z "$out" ]] || fail "usage: --name without --role must print no answer, got '$out'"
[[ "$err" == usage:* ]] || fail "usage: expected a usage: line on stderr, got '$err'"
run_in "$c"
[[ "$status" -eq 2 ]] || fail "usage: missing --role is exit 2, got $status"
[[ -z "$out" ]] || fail "usage: missing --role must print no answer, got '$out'"
run_in "$c" --nonsense x --name Beast --role planner
[[ "$status" -eq 2 ]] || fail "usage: an unknown flag is exit 2, got $status"
[[ -z "$out" ]] || fail "usage: an unknown flag must print no answer, got '$out'"
run_in "$c" --name --role planner
[[ "$status" -eq 2 ]] || fail "usage: a flag with no value is exit 2, got $status"
pass "usage: exit 2 and no answer at all, so a mistake can never be read as a miss"

# --- 2: the two misses --------------------------------------------------------------------------

c="$(new_consumer)"
run_in "$c" --name Beast --role planner
expect_out "$(printf 'miss\tno-file')" 0 "no agents.conf"
pass "no agents.conf at all: miss<TAB>no-file, exit 0 - absence is an answer, not an error"

c="$(new_consumer "# nobody" "" "Wolverine tool=claude")"
run_in "$c" --name Beast --role planner
expect_out "$(printf 'miss\tno-line')" 0 "a file naming nobody"
pass "a file naming nobody: miss<TAB>no-line, told apart from no-file so a caller can say either"

# --- 3: a hit, and the precedence ---------------------------------------------------------------

c="$(new_consumer "default tool=claude model=opus")"
run_in "$c" --name Beast --role planner
expect_hit default claude opus "" "default line"
run_in "$c" --role planner
expect_hit default claude opus "" "role-only default line"
pass "default: answers for an agent named by neither its name nor its role, effort empty"

c="$(new_consumer "default tool=claude" "planner tool=copilot model=gpt-5.5")"
run_in "$c" --name Beast --role planner
expect_hit planner copilot gpt-5.5 "" "role beats default"
run_in "$c" --role planner
expect_hit planner copilot gpt-5.5 "" "role-only role line"
run_in "$c" --name Forge --role architect
expect_hit default claude "" "" "another role falls to default"
pass "a role line beats default, and a role not named falls through to it"

c="$(new_consumer "default tool=claude" "planner tool=claude model=opus" "Beast tool=copilot")"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot "" "" "name beats role"
run_in "$c" --name Xavier --role planner
expect_hit planner claude opus "" "the other planner"
pass "an agent's own name beats its role, so two agents of one role can differ"

c="$(new_consumer "planner tool=claude model=opus effort=high" "Beast tool=copilot")"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot "" "" "the winning line wins outright"
pass "the winning line wins outright: a name line's silence is not the role line's value"

c="$(new_consumer "Beast tool=claude" "Beast tool=copilot")"
run_in "$c" --name Beast --role planner
expect_hit Beast claude "" "" "the same key twice"
pass "two lines carrying the same key: the first in file order wins"

# --- 4: the settings are named, and comments are not fields -------------------------------------

c="$(new_consumer "Beast effort=high model=gpt-5.5 tool=copilot")"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot gpt-5.5 high "settings in any order"
pass "settings in any order: they are named, so the column they sit in means nothing"

c="$(new_consumer "# the whole fleet" "" "   " "default tool=claude   # everything, with a note" \
                  "Beast tool=copilot model=gpt-5.5# why")"
run_in "$c" --name Forge --role architect
expect_hit default claude "" "" "a full-line comment and a blank"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot gpt-5.5 "" "a # immediately after a value"
pass "comments: a full line, a blank line, an inline # and a # touching a value are never fields"

c="$(new_consumer "Beast tool=claude tool=copilot")"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot "" "" "a setting given twice"
pass "a setting given twice on one line: the last one wins, silently"

# --- 5: reusable external models ----------------------------------------------------------------

c="$(new_consumer \
  'external research openai https://api.openai.com/v1 ${OPENAI_API_KEY} gpt-5.4' \
  'Beast tool=copilot model=research')"
run_in "$c" --name Beast --role planner
expect_external Beast copilot gpt-5.4 "" research openai https://api.openai.com/v1 OPENAI_API_KEY \
  "a selected external model"
pass "a Copilot row selecting an external definition returns its underlying model and metadata"

c="$(new_consumer \
  'external research openai https://api.openai.com/v1 ${OPENAI_API_KEY} gpt-5.4' \
  'Beast tool=copilot model=research' \
  'Xavier tool=copilot model=research')"
run_in "$c" --name Beast --role planner
expect_external Beast copilot gpt-5.4 "" research openai https://api.openai.com/v1 OPENAI_API_KEY \
  "the first agent selecting an external model"
run_in "$c" --name Xavier --role planner
expect_external Xavier copilot gpt-5.4 "" research openai https://api.openai.com/v1 OPENAI_API_KEY \
  "a second agent reusing an external model"
pass "one external definition resolves independently for more than one Copilot agent"

c="$(new_consumer \
  'external research openai https://api.openai.com/v1 ${OPENAI_API_KEY} gpt-5.4' \
  'external research openai https://api.openai.com/v1 ${OTHER_KEY} gpt-5.5' \
  'Beast tool=copilot model=research')"
run_in "$c" --name Beast --role planner
expect_external Beast copilot gpt-5.4 "" research openai https://api.openai.com/v1 OPENAI_API_KEY \
  "duplicate external definitions"
pass "the first external definition wins when names are duplicated"

c="$(new_consumer \
  'external research openai https://api.openai.com/v1 ${OPENAI_API_KEY} gpt-5.4' \
  'Beast tool=claude model=research')"
run_in "$c" --name Beast --role planner
expect_hit Beast claude research "" "an external name selected by Claude"
pass "an external definition does not affect a non-Copilot model selection"

c="$(new_consumer \
  'external research openai https://api.openai.com/v1 ${OPENAI_API_KEY} gpt-5.4' \
  'Beast tool=copilot model=researcher')"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot researcher "" "a similarly named ordinary model"
pass "a similarly named non-external model remains ordinary"

c="$(new_consumer \
  'external research openai https://api.openai.com/v1 ${not-a-variable} gpt-5.4' \
  'Beast tool=copilot model=research')"
run_in "$c" --name Beast --role planner
expect_unavailable_external Beast copilot research "" "a malformed selected definition"
pass "a malformed selected external definition is unavailable rather than a refusal"

c="$(new_consumer 'external research' 'Beast tool=copilot model=research')"
run_in "$c" --name Beast --role planner
expect_unavailable_external Beast copilot research "" "a missing selected definition"
pass "an external definition missing its fields is unavailable rather than a refusal"

c="$(new_consumer \
  'external research openai https://api.openai.com/v1 ${not-a-variable} gpt-5.4' \
  'Beast tool=claude model=research')"
run_in "$c" --name Beast --role planner
expect_hit Beast claude research "" "an invalid unselected definition"
pass "an invalid unselected external definition does not disrupt another selection"

# --- 6: the three refusals ----------------------------------------------------------------------
#
# The sentences are the ones the navigator agreed at the design stage, asserted byte for byte. The
# tool list inside them is derived below (case 6); here it is written out, so a change to either
# the sentence or the derivation goes red rather than agreeing with itself.

expect_refusal() {  # expect_refusal <sentence> <what>
  expect_out "$(printf 'refused\t%s' "$1")" 3 "$2"
}

c="$(new_consumer "Beast tool=copilo")"
run_in "$c" --name Beast --role planner
expect_refusal 'agents.conf ("Beast"): tool=copilo is not a tool I know. Try: claude, copilot.' "an unknown tool"
pass "an unknown tool refuses that one agent, in the agreed sentence"

c="$(new_consumer "Beast model=opus")"
run_in "$c" --name Beast --role planner
expect_refusal 'agents.conf ("Beast"): no tool. Every line must say one. Try: claude, copilot.' "no tool"
pass "a line with no tool refuses: every line must say one"

c="$(new_consumer "Beast tool=claude modle=high")"
run_in "$c" --name Beast --role planner
expect_refusal 'agents.conf ("Beast"): modle is not a setting I know. Try: tool, model, effort.' "a misspelt setting"
pass "a misspelt setting name is named, which is usually the cause of a missing tool"

c="$(new_consumer "Beast claude")"
run_in "$c" --name Beast --role planner
expect_refusal 'agents.conf ("Beast"): claude is not a setting I know. Try: tool, model, effort.' "a field with no ="
pass "a field with no = is entirely a setting name, and named whole"

c="$(new_consumer "Beast tool=")"
run_in "$c" --name Beast --role planner
expect_refusal 'agents.conf ("Beast"): no tool. Every line must say one. Try: claude, copilot.' "tool= with an empty value"
pass "tool= with an empty value is the setting being absent, not a tool called nothing"

c="$(new_consumer "default tool=claude" "planner tool=claude" "Beast tool=copilo")"
run_in "$c" --name Beast --role planner
expect_refusal 'agents.conf ("Beast"): tool=copilo is not a tool I know. Try: claude, copilot.' "no fallback"
pass "a refusal does not fall back to a less specific line: nothing runs on a setting nobody wrote"

c="$(new_consumer "Wolverine tol=x" "Beast tool=copilot")"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot "" "" "another agent's malformed line"
pass "a malformed line naming an agent this fleet does not run is never read at all"

# --- 7: the Try: lists are real -----------------------------------------------------------------
#
# Built by running `agent-cli --known' rather than written down, so adding a tool cannot leave the
# sentence above stale while this case stays green.

known_clause=""
while IFS= read -r kt || [[ -n "$kt" ]]; do
  [[ -n "$kt" ]] || continue
  if [[ -z "$known_clause" ]]; then known_clause="$kt"; else known_clause="$known_clause, $kt"; fi
done < <(bash "$repo_root/scripts/agent-cli" --known)
[[ -n "$known_clause" ]] || fail "agent-cli --known named no tool at all"

c="$(new_consumer "Beast tool=nonesuch")"
run_in "$c" --name Beast --role planner
expect_refusal "agents.conf (\"Beast\"): tool=nonesuch is not a tool I know. Try: $known_clause." \
  "the derived tool list"
pass "the tool list in a refusal is agent-cli --known's own answer, not a literal"

# --- 8: it runs where the launcher runs ---------------------------------------------------------
#
# The narrowed-PATH shape from tests/launchers.sh: `dirname' and `bash' and nothing else, which is
# what pins the no-external-commands rule as behaviour rather than as a comment in the header.

narrow_path_dir="$work_dir/narrow-path"
mkdir -p "$narrow_path_dir"
ln -s "$(command -v dirname)" "$narrow_path_dir/dirname"
ln -s "$(command -v bash)" "$narrow_path_dir/bash"

# The root hints are PASSED here rather than scrubbed, because that is the field: `scripts/launch'
# resolves them once with a whole PATH and exports them, and every reader below it prefers the hint
# - `cerebro_hinted_root' still checks this one physically resolves to the fixture's own checkout
# before believing it. What this case is about is `agents-conf' itself running no external command.
c="$(new_consumer "default tool=claude" "Beast tool=copilot model=gpt-5.5 effort=high")"
set +e
out="$(cd "$c" && env CEREBRO_CONSUMER_ROOT="$c" CEREBRO_CONSUMER_SHARED_ROOT="$c" \
         CEREBRO_CONSUMER_MOUNT=".claude/cerebro" \
         PATH="$narrow_path_dir" "$(command -v bash)" "$c/.claude/cerebro/scripts/agents-conf" \
         --name Beast --role planner 2>"$work_dir/stderr")"
status=$?
set -e
err="$(cat "$work_dir/stderr")"
expect_hit Beast copilot gpt-5.5 high "a narrowed PATH"
pass "agents-conf answers on a PATH holding only dirname and bash, as the launch path has"

# --- 9: a failing agent-cli --known aborts rather than emptying the tool list --------------------
#
# The decision the plan records, and the one this case exists to pin as behaviour: the `--known'
# read is NOT guarded, so a failure ends the script under errexit. Swallowing it would leave the
# list empty and refuse every line in the fleet with `Try: .' - a launch refusal naming the
# navigator's own correct config as the fault. `--known' cannot fail short of a broken checkout,
# which is why aborting is the right answer and a sentence would not help.

stub_agent_cli() {  # stub_agent_cli <consumer> <body>
  rm -f "$1/.claude/cerebro/scripts/agent-cli"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/.claude/cerebro/scripts/agent-cli"
  chmod +x "$1/.claude/cerebro/scripts/agent-cli"
}

c="$(new_consumer "Beast tool=claude")"
stub_agent_cli "$c" 'exit 1'
run_in "$c" --name Beast --role planner
[[ "$status" -ne 0 && "$status" -ne 3 ]] \
  || fail "a failing --known: expected an abort, got exit $status and '$out'"
[[ -z "$out" ]] || fail "a failing --known: expected no answer at all, got $(printf '%q' "$out")"
pass "a failing agent-cli --known aborts: no line in the fleet is refused for a broken checkout"

c="$(new_consumer "Beast tool=claude")"
stub_agent_cli "$c" 'echo claude; exit 1'
run_in "$c" --name Beast --role planner
[[ "$status" -ne 0 ]] \
  || fail "a half-written --known: a partial tool list must not be trusted, got '$out'"
pass "a --known that prints and then fails is a failure, not a shorter list of tools"

# --- 10: a file saved with CRLF line endings ----------------------------------------------------
#
# agents.conf is hand-written, so a stray carriage return is a navigator's editor rather than a
# mistake in the file's content. Without stripping it, `tool=claude<CR>' refuses with the CR inside
# the sentence - a refusal that reads as though a correct value is wrong.

c="$(new_consumer)"
printf 'default tool=claude\r\nBeast tool=copilot model=gpt-5.5\r\n' > "$c/.cerebro/agents.conf"
run_in "$c" --name Beast --role planner
expect_hit Beast copilot gpt-5.5 "" "a CRLF file"
pass "a file saved with CRLF endings answers as written, with no carriage return in the answer"

suite_passed
