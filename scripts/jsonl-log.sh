# scripts/jsonl-log.sh - the one place bash appends a line to an append-only JSONL log.
#
# SOURCED, NEVER EXECUTED. It has no `set -euo pipefail' of its own and defines functions only, so
# sourcing it changes nothing about the caller's shell but the names it can call. Builtins alone
# (`printf', `[[', the `>>' redirection), because `scripts/launch-refused' is on the launch path and
# `tests/launchers.sh' runs that path with a PATH holding `dirname' and `bash' and nothing else.
#
# WHY IT EXISTS, AND THE RULE IT CARRIES (cb-ge0). Both callers append their line from inside a
# `{ ... } || true' group, so that a full disk or an unwritable log can never bring an agent down.
#
#     `|| true' on a group makes that group the left side of an AND-OR list, and errexit is
#     SUSPENDED FOR EVERY COMMAND INSIDE IT. So a `line="$(jq ...)"' in a "cannot fail" block does
#     not abort the block when `jq' fails - it leaves `line' empty and the append after it writes a
#     blank line. That is why this function refuses a line rather than trusting the caller to have
#     checked one.
#
# That sentence was learned twice from scratch, once per bead, because it lived in a comment in one
# copy of the idiom instead of in the shape of the code both copies call. It lives here now, where
# whoever writes the third append-only log in bash will reach it.
#
# THE CALLER CREATES THE DIRECTORY. `mkdir' is not a builtin, and keeping it out is part of what
# keeps this library safe on the narrowed PATH; both callers have made the directory already by the
# time they get here.

# cerebro_jsonl_append <path> <line>
#
# Appends <line> and a newline to <path>. Returns 0 when the line was written.
#
# Returns non-zero WITHOUT WRITING ANYTHING when <path> is empty, when <line> is empty or does not
# begin with `{', or when the append itself fails. It never exits and never writes a diagnostic: a
# refusal is the caller's to notice. Both callers today sit inside `|| true' groups, so a non-zero
# return cannot kill them - a future caller OUTSIDE such a group, under `set -e', would die on a
# refusal, and wants `|| true' or a test of its own.
#
# The `{' test rather than a full parse: both callers write a JSON object, `scripts/fleet-history'
# does `fromjson' on every non-empty line and fails loudly on garbage, and this test is one glob
# comparison with no fork. Validating the JSON properly would mean forking `jq' per transition to
# check the output of a `jq' that may not be installed, which is both circular and a fork on every
# state write.
cerebro_jsonl_append() {
  local path="$1" line="$2"
  [[ -n "$path" ]] || return 1
  [[ -n "$line" && "$line" == \{* ]] || return 1
  printf '%s\n' "$line" >> "$path"
}
