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

# THE PROTECTED DIRECTORY (cb-xhu.1). The gate's suites must build every fixture under their own
# $work_dir; one that resolves the real shared root and appends there writes into the FLEET'S LIVE
# LOGS - 249 of the 437 lines of this checkout's errors.jsonl were one fixture, in a file the
# navigator is sent to by name. So a write into the directory named by $CEREBRO_PROTECTED_STATE_DIR
# is refused here, at the one place bash appends such a line, and recorded so
# `scripts/suite-runner' - the only thing that sets the variable - can name the suite and be red.
#
# Three properties are load-bearing:
#
#   - THE COMPARISON IS TEXTUAL, and that is enough because both callers build the same string:
#     `scripts/agent-state' and `scripts/launch-refused' each resolve `consumer-root --shared' and
#     append `/.cerebro/state', byte for byte what suite-runner exports. A relative path, or the
#     same directory reached through a different symlink, is NOT caught - this library may not fork
#     a resolver, and this is a backstop for a suite that resolves the root the ordinary way, which
#     is the failure that actually happened.
#   - A REFUSAL IS SILENT on stderr, exactly like the other three. The report file is not a
#     diagnostic; it is a record the runner reads afterwards.
#   - THE REPORT APPEND CANNOT CREATE A DIRECTORY (no `mkdir' on this PATH), so
#     $CEREBRO_PROTECTED_STATE_REPORT must name a file in a directory its setter has already made.
#     When it is unset the write is still refused; only the record is skipped.
#
# cerebro_jsonl_protected_path <path>
#
# Returns 0 when <path> is, or lies under, the directory named by $CEREBRO_PROTECTED_STATE_DIR; 1
# otherwise - including whenever that variable is unset or empty, which is every production caller.
cerebro_jsonl_protected_path() {
  local path="$1" guard="${CEREBRO_PROTECTED_STATE_DIR:-}"
  [[ -n "$guard" ]] || return 1
  guard="${guard%/}"
  [[ -n "$guard" ]] || return 1
  [[ -n "$path" ]] || return 1
  [[ "$path" == "$guard" || "$path" == "$guard"/* ]]
}

# cerebro_jsonl_append <path> <line>
#
# Appends <line> and a newline to <path>. Returns 0 when the line was written.
#
# Returns non-zero WITHOUT WRITING ANYTHING when <path> is empty, when <line> is empty or does not
# begin with `{', when <path> is protected (see above), or when the append itself fails. It never
# exits and never writes a diagnostic: a refusal is the caller's to notice. Both callers today sit
# inside `|| true' groups, so a non-zero return cannot kill them - a future caller OUTSIDE such a
# group, under `set -e', would die on a refusal, and wants `|| true' or a test of its own.
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
  if cerebro_jsonl_protected_path "$path"; then
    if [[ -n "${CEREBRO_PROTECTED_STATE_REPORT:-}" ]]; then
      printf '%s\t%s\n' "${CEREBRO_SUITE_NAME:-unknown}" "$path" \
        >> "$CEREBRO_PROTECTED_STATE_REPORT"
    fi
    return 1
  fi
  printf '%s\n' "$line" >> "$path"
}
