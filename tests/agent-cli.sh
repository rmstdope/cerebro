#!/usr/bin/env bash
#
# Proves scripts/agent-cli is the ONE place "which agent CLI does this fleet run on" is answered
# (cb-d59.2). The defect it ends: the answer was spelt `claude` in argv, in two scripts -
# `scripts/launch` and `scripts/launch-preflight` - declared nowhere and askable of nothing, so
# running the fleet on any other agent CLI meant rewriting both launchers.
#
# The seam is what is asserted here: the verbs, the sentences, and the argv the claude arm emits,
# token for token and in order. `tests/launchers.sh` proves the other half - that `launch` spells
# none of it itself, by driving a launch through a fake provider.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/agent-cli.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new agent-cli-repo --link consumer-root project-conf agent-cli launch-refused)"
conf="$consumer/.cerebro/project.conf"
mkdir -p "$consumer/.cerebro"
agent_cli="$consumer/.claude/cerebro/scripts/agent-cli"

# Every case declares what it needs; this one declares nothing at all.
: > "$conf"

# --- an absent declaration answers claude, and says so ------------------------------------------
out="$("$agent_cli" 2>"$work_dir/err")"
err="$(cat "$work_dir/err")"
[[ "$out" == "claude" ]] || fail "absent agent_cli: expected stdout 'claude', got '$out'"
echo "$err" | grep -q 'agent-cli: no agent_cli declared; running on claude' \
  || fail "absent agent_cli: expected the fallback line on stderr, got: $err"
echo "$err" | grep -q 'project-conf:' \
  && fail "absent agent_cli: project-conf's own stderr must be swallowed, got: $err"
pass "an absent agent_cli answers claude, and says so once on stderr"

# --- a declared claude answers claude, and says nothing ------------------------------------------
printf 'agent_cli claude\n' > "$conf"
out="$("$agent_cli" 2>"$work_dir/err")"
err="$(cat "$work_dir/err")"
[[ "$out" == "claude" ]] || fail "agent_cli claude: expected stdout 'claude', got '$out'"
[[ -z "$err" ]] || fail "agent_cli claude: expected nothing on stderr, got: $err"
pass "a declared agent_cli claude answers claude and says nothing"

# --- --binary, --known, and an unknown verb ------------------------------------------------------
out="$("$agent_cli" --binary 2>/dev/null)"
[[ "$out" == "claude" ]] || fail "--binary: expected 'claude', got '$out'"
pass "--binary is the executable the claude arm execs"

out="$("$agent_cli" --known 2>/dev/null)"
[[ "$out" == "claude
copilot" ]] || fail "--known: expected 'claude' then 'copilot', got '$out'"
pass "--known lists both providers this cerebro can run"

set +e
out="$("$agent_cli" --wat 2>&1)"; status=$?
set -e
[[ $status -eq 2 ]] || fail "--wat: expected exit 2, got $status"
pass "an unknown verb exits 2"

# --- a declared copilot runs, since cb-d59.6 moved it out of PLANNED --------------------------
#
# PLANNED is empty now, and its `resolve' branch and `refusal_sentence' arm survive untested
# BECAUSE it is empty: they are the only thing that tells a consumer on an older cerebro,
# declaring a provider a newer cerebro has, to bump the submodule rather than fix a declaration
# that is perfectly correct. Deleting them would give that consumer the opposite advice.
printf 'agent_cli copilot\n' > "$conf"
out="$("$agent_cli" 2>"$work_dir/err")"
err="$(cat "$work_dir/err")"
[[ "$out" == "copilot" ]] || fail "agent_cli copilot: expected stdout 'copilot', got '$out'"
[[ -z "$err" ]] || fail "agent_cli copilot: expected nothing on stderr, got: $err"
pass "a declared agent_cli copilot resolves and says nothing"

out="$("$agent_cli" --binary 2>/dev/null)"
[[ "$out" == "copilot" ]] || fail "--binary (copilot): expected 'copilot', got '$out'"
pass "--binary is the executable the copilot arm execs"

# --- an unknown declaration is still a refusal ---------------------------------------------------
printf 'agent_cli emacs-doctor\n' > "$conf"
set +e
out="$("$agent_cli" --binary 2>"$work_dir/err")"; status=$?
set -e
err="$(cat "$work_dir/err")"
[[ $status -eq 3 ]] || fail "an unknown agent_cli: expected exit 3, got $status"
echo "$err" | grep -q 'is not an agent CLI cerebro knows' \
  || fail "an unknown agent_cli: expected the unknown-provider sentence, got: $err"
echo "$err" | grep -q 'emacs-doctor' \
  || fail "an unknown agent_cli: the sentence should name the declared value, got: $err"
pass "an unknown agent_cli exits 3 saying it is not an agent CLI cerebro knows"

# --- --check refuses through launch-refused, and records it --------------------------------------
set +e
out="$("$agent_cli" --check Storm 2>"$work_dir/err")"; status=$?
set -e
err="$(cat "$work_dir/err")"
[[ $status -eq 3 ]] || fail "--check on an unknown agent_cli: expected exit 3, got $status"
echo "$err" | grep -q '^cerebro: ' \
  || fail "--check: the refusal must come from launch-refused, got: $err"
echo "$err" | grep -q 'before starting Storm$' \
  || fail "--check: the sentence should end by naming the agent, got: $err"
pass "--check on an unknown agent_cli refuses and names the agent"

errors="$consumer/.cerebro/state/errors.jsonl"
[[ -f "$errors" ]] || fail "--check: expected a line in $errors"
[[ "$(jq -r 'select(.event == "error") | .context' "$errors" | tail -1)" == "launch Storm" ]] \
  || fail "--check: expected the errors.jsonl context to be 'launch Storm'"
pass "--check writes the refusal to errors.jsonl"

# --- --check, with claude declared and the binary missing ----------------------------------------
printf 'agent_cli claude\n' > "$conf"
bare_dir="$(mktemp -d)"
cleanup_add "$bare_dir"
ln -s "$(command -v dirname)" "$bare_dir/dirname"
ln -s "$(command -v bash)" "$bare_dir/bash"
set +e
out="$(PATH="$bare_dir" "$(command -v bash)" "$agent_cli" --check Storm 2>&1)"; status=$?
set -e
[[ $status -eq 3 ]] || fail "--check (claude missing): expected exit 3, got $status"
echo "$out" | grep -q 'claude is not on PATH - install Claude Code' \
  || fail "--check (claude missing): expected launch-preflight's own sentence, got: $out"
pass "--check refuses when the arm's binary is not on PATH"

stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_dir/claude"
chmod +x "$stub_dir/claude"
out="$(PATH="$stub_dir:$PATH" "$agent_cli" --check Storm 2>&1)"
[[ -z "$out" ]] || fail "--check (claude present): expected silence, got: $out"
pass "--check exits 0 and says nothing when claude is declared and present"

# --- --argv, token for token and in order --------------------------------------------------------
#
# The whole array, compared in order, rather than a grep per token: order is the property a second
# arm could silently break, and a grep would not see it.
read_argv() {
  argv=()
  local tok
  while IFS= read -r -d '' tok; do argv+=("$tok"); done < <("$@")
}

read_argv "$agent_cli" --argv --role implementer --name Storm \
  --model opus --effort high --settings /tmp/s.json
expected=(--agent implementer --name Storm --remote-control Storm
          --model opus --effort high
          --settings /tmp/s.json --permission-mode auto)
[[ "${#argv[@]}" -eq "${#expected[@]}" ]] \
  || fail "--argv: expected ${#expected[@]} tokens, got ${#argv[@]}: ${argv[*]}"
for ((i = 0; i < ${#expected[@]}; i++)); do
  [[ "${argv[$i]}" == "${expected[$i]}" ]] \
    || fail "--argv token $i: expected '${expected[$i]}', got '${argv[$i]}'"
done
pass "--argv emits the claude arm's flags in launch order"

# cb-d59.3: the marker moved into the prompt, which is the one argv slot every agent CLI accepts,
# so no arm of --argv emits it - and composing it is `launch`'s job, not this table's.
printf '%s' "${argv[*]}" | grep -q -- '--append-system-prompt' \
  && fail "--argv still emits --append-system-prompt: ${argv[*]}"
pass "--argv emits no --append-system-prompt, the marker having moved into the prompt"

read_argv "$agent_cli" --argv --role planner --name Xavier
expected=(--agent planner --name Xavier --remote-control Xavier --permission-mode auto)
[[ "${argv[*]}" == "${expected[*]}" ]] \
  || fail "--argv (nothing optional): expected '${expected[*]}', got '${argv[*]}'"
pass "--argv omits --model, --effort and --settings when not given"

prompt="You are Storm. Your agent definition (implementer) is the whole of your instructions: follow it from
the top, and start now rather than waiting to be spoken to."
read_argv "$agent_cli" --prompt-argv "$prompt"
[[ "${#argv[@]}" -eq 1 ]] || fail "--prompt-argv: expected one token, got ${#argv[@]}"
[[ "${argv[0]}" == "$prompt" ]] || fail "--prompt-argv: the prompt should arrive whole, got '${argv[0]}'"
pass "--prompt-argv carries a prompt containing a newline as one token"

set +e
"$agent_cli" --argv --name Storm >/dev/null 2>&1; no_role=$?
"$agent_cli" --argv --role implementer >/dev/null 2>&1; no_name=$?
set -e
[[ $no_role -eq 2 ]] || fail "--argv without --role: expected exit 2, got $no_role"
[[ $no_name -eq 2 ]] || fail "--argv without --name: expected exit 2, got $no_name"
pass "--argv without --role or without --name exits 2"

# --- --layouts: where each provider discovers agents and skills ----------------------------------
#
# The one place a provider's discovery paths are written down (cb-d59.4). It answers for EVERY
# provider whatever this consumer declared, so it runs before `resolve': a sync must be able to
# write both layouts in a consumer that declares nothing, and in one declaring a provider this
# cerebro cannot run yet.
printf 'agent_cli claude\n' > "$conf"
out="$("$agent_cli" --layouts 2>"$work_dir/err")"
err="$(cat "$work_dir/err")"
rows=()
while IFS= read -r row; do rows+=("$row"); done <<<"$out"
[[ "${#rows[@]}" -eq 2 ]] || fail "--layouts: expected two rows, got ${#rows[@]}: $out"
IFS=$'\t' read -r p ad sd sx <<<"${rows[0]}"
[[ "$p" == "claude" && "$ad" == ".claude/agents" && "$sd" == ".claude/skills" && "$sx" == ".md" ]] \
  || fail "--layouts row 1: expected the claude layout, got '${rows[0]}'"
IFS=$'\t' read -r p ad sd sx <<<"${rows[1]}"
[[ "$p" == "copilot" && "$ad" == ".github/agents" && "$sd" == ".github/skills" && "$sx" == ".agent.md" ]] \
  || fail "--layouts row 2: expected the copilot layout, got '${rows[1]}'"
pass "--layouts prints one tab-separated row per provider, claude first"

# Empty declaration: no `no agent_cli declared' line, because resolve never runs. And a declaration
# this cerebro cannot run still gets both rows - that consumer is exactly the one needing them.
: > "$conf"
out="$("$agent_cli" --layouts 2>"$work_dir/err")"
err="$(cat "$work_dir/err")"
[[ -z "$err" ]] || fail "--layouts with no declaration: expected nothing on stderr, got: $err"
printf 'agent_cli wat\n' > "$conf"
set +e
out="$("$agent_cli" --layouts 2>"$work_dir/err")"; status=$?
set -e
[[ $status -eq 0 ]] || fail "--layouts with an unrunnable declaration: expected exit 0, got $status"
echo "$out" | grep -q '^copilot' \
  || fail "--layouts must list copilot though it is not runnable, got: $out"
pass "--layouts says nothing on stderr and lists copilot though it is not runnable"

set +e
"$agent_cli" --layouts x >/dev/null 2>&1; status=$?
set -e
[[ $status -eq 2 ]] || fail "--layouts with an argument: expected exit 2, got $status"
pass "--layouts takes no arguments"

# --- --agent-file-models: whose words are the agent files' model: and effort: ---------------------
#
# Unlike --layouts, this one answers about THIS fleet, so it belongs after `resolve'.
printf 'agent_cli claude\n' > "$conf"
out="$("$agent_cli" --agent-file-models 2>/dev/null)"
[[ "$out" == "yes" ]] || fail "--agent-file-models (claude): expected 'yes', got '$out'"
printf 'agent_cli copilot\n' > "$conf"
out="$("$agent_cli" --agent-file-models 2>/dev/null)"
[[ "$out" == "no" ]] || fail "--agent-file-models (copilot): expected 'no', got '$out'"
pass "--agent-file-models says the agent files' words are claude's"

set +e
"$agent_cli" --agent-file-models x >/dev/null 2>&1; status=$?
set -e
[[ $status -eq 2 ]] || fail "--agent-file-models with an argument: expected exit 2, got $status"
pass "--agent-file-models takes no arguments"

# --- the copilot arm's argv, token for token and in order ----------------------------------------
printf 'agent_cli copilot\n' > "$conf"
read_argv "$agent_cli" --argv --role implementer --name Storm \
  --model gpt-5-mini --effort medium --settings /tmp/s.json
expected=(--agent implementer --name Storm
          --model gpt-5-mini --effort medium
          --allow-all-tools)
[[ "${#argv[@]}" -eq "${#expected[@]}" ]] \
  || fail "--argv (copilot): expected ${#expected[@]} tokens, got ${#argv[@]}: ${argv[*]}"
for ((i = 0; i < ${#expected[@]}; i++)); do
  [[ "${argv[$i]}" == "${expected[$i]}" ]] \
    || fail "--argv (copilot) token $i: expected '${expected[$i]}', got '${argv[$i]}'"
done
pass "--argv emits the copilot arm's flags in launch order"

for flag in --remote-control --settings --permission-mode; do
  printf '%s' "${argv[*]}" | grep -q -- "$flag" \
    && fail "--argv (copilot) emits $flag, which is the claude arm's to spell: ${argv[*]}"
done
printf '%s' "${argv[*]}" | grep -q -- '/tmp/s.json' \
  && fail "--argv (copilot): the settings path must not appear: ${argv[*]}"
pass "the copilot arm emits no --remote-control, no --settings and no --permission-mode"

read_argv "$agent_cli" --argv --role planner --name Xavier
expected=(--agent planner --name Xavier --allow-all-tools)
[[ "${argv[*]}" == "${expected[*]}" ]] \
  || fail "--argv (copilot, nothing optional): expected '${expected[*]}', got '${argv[*]}'"
pass "--argv omits --model and --effort for copilot when not given"

read_argv "$agent_cli" --prompt-argv "$prompt"
[[ "${#argv[@]}" -eq 2 ]] || fail "--prompt-argv (copilot): expected two tokens, got ${#argv[@]}"
[[ "${argv[0]}" == "-i" ]] || fail "--prompt-argv (copilot): expected -i, got '${argv[0]}'"
[[ "${argv[1]}" == "$prompt" ]] \
  || fail "--prompt-argv (copilot): the prompt should arrive whole, got '${argv[1]}'"
pass "--prompt-argv carries the prompt as -i and one token"

# --- --check, with copilot declared --------------------------------------------------------------
#
# A PATH of its own rather than $bare_dir: this case needs project-conf to actually READ the
# declaration (so it needs grep and tail), and needs `copilot' to be absent from it. $bare_dir is
# too bare - project-conf fails there, the declaration reads as absent, and the case would assert
# about the claude arm.
nocopilot_dir="$(mktemp -d)"
cleanup_add "$nocopilot_dir"
for t in dirname bash grep tail mkdir date git; do
  [[ -x "$nocopilot_dir/$t" ]] || ln -s "$(command -v "$t")" "$nocopilot_dir/$t"
done
set +e
out="$(PATH="$nocopilot_dir" "$(command -v bash)" "$agent_cli" --check Storm 2>&1)"; status=$?
set -e
[[ $status -eq 3 ]] || fail "--check (copilot missing): expected exit 3, got $status"
echo "$out" | grep -q 'copilot is not on PATH - install GitHub Copilot CLI' \
  || fail "--check (copilot missing): expected the copilot arm's sentence, got: $out"
echo "$out" | grep -q '^cerebro: ' \
  || fail "--check (copilot missing): the refusal must come from launch-refused, got: $out"
pass "--check refuses when copilot is not on PATH"

printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_dir/copilot"
chmod +x "$stub_dir/copilot"
out="$(PATH="$stub_dir:$PATH" "$agent_cli" --check Storm 2>&1)"
[[ -z "$out" ]] || fail "--check (copilot present): expected silence, got: $out"
pass "--check exits 0 and says nothing when copilot is declared and present"

printf 'agent_cli claude\n' > "$conf"

# --- --hooks: where each provider's repository-discovered hooks live -----------------------------
#
# The one place a provider's hook directories are written down (cb-d59.5). Like --layouts it
# answers before `resolve', for every provider whatever this consumer declared: sync-symlinks.sh
# runs from launch-preflight before every session, and one stderr line there is one line above
# every agent's first prompt for ever. `claude' has no row - its hook settings file is passed on
# the command line and is installed nowhere.
printf 'agent_cli claude\n' > "$conf"
out="$("$agent_cli" --hooks 2>"$work_dir/err")"
err="$(cat "$work_dir/err")"
rows=()
while IFS= read -r row; do [[ -n "$row" ]] && rows+=("$row"); done <<<"$out"
[[ "${#rows[@]}" -eq 1 ]] || fail "--hooks: expected one row, got ${#rows[@]}: $out"
IFS=$'\t' read -r p src dest <<<"${rows[0]}"
[[ "$p" == "copilot" && "$src" == "hooks/copilot" && "$dest" == ".github/hooks" ]] \
  || fail "--hooks row 1: expected the copilot hook row, got '${rows[0]}'"
echo "$out" | grep -q '^claude' \
  && fail "--hooks must not list claude: its settings file is passed on the command line"
pass "--hooks prints one tab-separated row per provider whose hooks live in the repository"

: > "$conf"
out="$("$agent_cli" --hooks 2>"$work_dir/err")"
err="$(cat "$work_dir/err")"
[[ -z "$err" ]] || fail "--hooks with no declaration: expected nothing on stderr, got: $err"
printf 'agent_cli wat\n' > "$conf"
set +e
out="$("$agent_cli" --hooks 2>"$work_dir/err")"; status=$?
set -e
[[ $status -eq 0 ]] || fail "--hooks with an unrunnable declaration: expected exit 0, got $status"
echo "$out" | grep -q '^copilot' \
  || fail "--hooks must answer for copilot though it is not runnable, got: $out"
pass "--hooks says nothing on stderr and answers for an unrunnable declaration"

set +e
"$agent_cli" --hooks x >/dev/null 2>&1; status=$?
set -e
[[ $status -eq 2 ]] || fail "--hooks with an argument: expected exit 2, got $status"
pass "--hooks takes no arguments"

printf 'agent_cli claude\n' > "$conf"
