#!/usr/bin/env bash
# Proves `scripts/review-model' picks the review sub-agent's `agents.conf' line by the size of the
# pull request: a declared `reviewer-small' line for at most 200 changed lines, the `reviewer'
# lookup for everything else, and the stronger of the two whenever the size cannot be read.
#
#     bash tests/review-model.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

[[ -x "$repo_root/scripts/review-model" ]] || fail "scripts/review-model is not an executable script"

# A `gh' that records what it was asked and answers from two files: what to print, and how to exit.
bin="$work_dir/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB/argv"
cat "$GH_STUB/answer"
exit "$(cat "$GH_STUB/status")"
STUB
chmod +x "$bin/gh"

c=""
new_consumer() {  # new_consumer [<agents.conf line>...]  -> sets $c
  c="$(consumer_new "$(fixture_name c)" --link review-model agents-conf agent-cli consumer-root project-conf)"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$c/.cerebro/agents.conf"
  fi
}

gh_answers() {  # gh_answers <stdout> [<status>]
  printf '%s\n' "$1" > "$work_dir/answer"
  printf '%s\n' "${2:-0}" > "$work_dir/status"
}

size() { gh_answers "{\"additions\":$1,\"deletions\":$2}"; }

out="" err="" status=0
run_model() {
  rm -f "$work_dir/argv"
  set +e
  out="$(cd "$c" && env -u CEREBRO_CONSUMER_ROOT -u CEREBRO_CONSUMER_SHARED_ROOT -u CEREBRO_CONSUMER_MOUNT \
           PATH="$bin:$PATH" GH_STUB="$work_dir" \
           bash "$c/.cerebro/cerebro/scripts/review-model" "$@" 2>"$work_dir/stderr")"
  status=$?
  set -e
  err="$(cat "$work_dir/stderr")"
}

hit() {  # hit <key> <model> <effort>
  printf 'hit\t%s\tclaude\t%s\t%s\tordinary\t\t\t\t' "$1" "$2" "$3"
}

expect() {  # expect <stdout> <status> <what>
  [[ "$out" == "$1" ]] || fail "$3: expected $(printf '%q' "$1"), got $(printf '%q' "$out") ($err)"
  [[ "$status" -eq "$2" ]] || fail "$3: expected exit $2, got $status ($err)"
}

gh_not_asked() { [[ ! -e "$work_dir/argv" ]] || fail "$1: gh was asked: $(cat "$work_dir/argv")"; }

big="default tool=claude model=opus effort=medium"
small="reviewer-small tool=claude model=sonnet effort=low"

# --- no declaration: today's answer, and nothing read -------------------------------------------

new_consumer "$big" "reviewer tool=claude model=fable"
size 1 0
run_model 12
expect "$(hit reviewer fable '')" 0 "undeclared"
[[ -z "$err" ]] || fail "undeclared: expected nothing on stderr, got '$err'"
gh_not_asked "undeclared"
pass "with no reviewer-small line the reviewer line answers and the size is not read"

new_consumer "$big"
size 1 0
run_model 12
expect "$(hit default opus medium)" 0 "default only"
gh_not_asked "default only"
pass "the default line is no reviewer-small declaration"

new_consumer
run_model 12
expect "$(printf 'miss\tno-file')" 0 "no file"
pass "with no agents.conf the answer is agents-conf's own miss"

# --- the threshold ------------------------------------------------------------------------------

new_consumer "$big" "$small"
size 150 50
run_model 12
expect "$(hit reviewer-small sonnet low)" 0 "200 lines"
grep -qF "pr view 12 --json additions,deletions" "$work_dir/argv" || fail "200 lines: gh was asked $(cat "$work_dir/argv")"
[[ "$err" == *"200 changed lines"*"reviewer-small"* ]] || fail "200 lines: stderr did not say why: '$err'"
pass "200 changed lines take the reviewer-small line"

size 150 51
run_model 12
expect "$(hit default opus medium)" 0 "201 lines"
[[ "$err" == *"201 changed lines"* ]] || fail "201 lines: stderr did not say why: '$err'"
pass "201 changed lines take the reviewer line"

# --- a size that cannot be read is never a small one --------------------------------------------

gh_answers "" 1
run_model 12
expect "$(hit default opus medium)" 0 "gh failed"
[[ "$err" == *"could not read the size"* ]] || fail "gh failed: stderr did not say so: '$err'"
pass "a failed size read takes the reviewer line and says so"

for answer in "" "not json" "{}" '{"additions":3}' '{"additions":"3","deletions":0}'; do
  gh_answers "$answer"
  run_model 12
  expect "$(hit default opus medium)" 0 "answer '$answer'"
  [[ "$err" == *"could not read the size"* ]] || fail "answer '$answer': stderr did not say so: '$err'"
done
pass "an unreadable size takes the reviewer line and says so"

# --- refusals -----------------------------------------------------------------------------------

new_consumer "$big" "reviewer-small model=sonnet"
size 1 1
run_model 12
[[ "$status" -eq 3 ]] || fail "refused small: expected exit 3, got $status"
[[ "$out" == $'refused\tagents.conf ("reviewer-small"): '* ]] || fail "refused small: got '$out'"
pass "a broken reviewer-small line is refused for a small diff"

size 500 0
run_model 12
expect "$(hit default opus medium)" 0 "refused small, large diff"
pass "a broken reviewer-small line says nothing about a large diff"

new_consumer "default model=opus"
run_model 12
[[ "$status" -eq 3 ]] || fail "refused default: expected exit 3, got $status"
[[ "$out" == $'refused\tagents.conf ("default"): '* ]] || fail "refused default: got '$out'"
gh_not_asked "refused default"
pass "a broken default line is refused as before"

# --- usage --------------------------------------------------------------------------------------

for args in "" "abc" "12 13"; do
  read -ra argv <<<"$args"
  run_model ${argv+"${argv[@]}"}
  [[ "$status" -eq 2 ]] || fail "usage '$args': expected exit 2, got $status"
  [[ -z "$out" ]] || fail "usage '$args': expected no answer, got '$out'"
  [[ "$err" == usage:* ]] || fail "usage '$args': expected a usage line, got '$err'"
done
pass "anything but one pull request number is a usage error"

suite_passed
