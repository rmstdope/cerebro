# scripts/state-write.sh - the one place bash replaces a polled file with a whole new one.
#
# SOURCED, NEVER EXECUTED. It has no `set -euo pipefail' of its own and defines functions only, so
# sourcing it changes nothing about the caller's shell but the names it can call.
#
# WHY IT EXISTS, AND THE RULE IT CARRIES (ah-za5i). `cerebro--read-state-file' and
# `readers::read_states' poll .cerebro/state/<name>.state.json on a five-second clock and must never
# see a torn file, so a writer builds the whole object elsewhere and renames it over the target.
# TWO PROCESSES WRITE EACH SUCH FILE - `scripts/agent-state' (a session's own transitions) and
# `scripts/agent-turn' (a Stop/UserPromptSubmit hook) - and for a long time only one of them picked
# a scratch name the other could not collide with. Two writers of one FIXED `<file>.tmp' let each
# `mv' the other's half-written object, which is the very atomicity both headers claim, and the
# loser's `mv' fails outright because the file it was about to rename is gone: eleven sessions died
# that way with `mv: rename ... No such file or directory' (docs/retrospectives/ah-hiib.1.md).
#
# The rule lives here, in the shape of the code both writers call, rather than in a comment in one
# copy of the idiom - which is what let it be applied to one of the two places that needed it.
#
# Four properties are load-bearing:
#
#   - THE PRODUCER IS RUN BY THIS FUNCTION, NOT PIPED INTO IT. A `cmd | ...' shape hides the
#     producer's exit status from the reader of this function's own, so it would rename whatever
#     the producer managed to emit before it died - a truncated or empty object over a live state
#     file. Taking the command as arguments keeps that status the thing that decides whether the
#     rename happens at all, which is exactly what both call sites rely on.
#   - THE TEMP NAME CARRIES `$$'. The colliding writers are separate PROCESSES, so a per-process
#     suffix is sufficient. `$$' and not `BASHPID': macOS ships bash 3.2, which has no `BASHPID',
#     and the fleet runs there.
#   - THE TEMP FILE IS REMOVED ON EVERY FAILURE PATH. The redirection creates it before the command
#     runs, and the directory it would be left in is polled every five seconds by both views.
#   - IT ENDS WITH AN EXPLICIT `return 0'. A function's status is its last command's, and a guarded
#     `mv ... || { ... }' at the end is easy to grow a trailing advisory line onto later - see
#     .cerebro/traps.md, "An advisory step can eat the exit status that follows it".

# cerebro_state_write_atomic <target> <command> [<arg>...]
#
# Runs <command> with its stdout redirected to a temp file beside <target> whose name carries this
# process's pid, then renames that file over <target>. Prints nothing of its own.
#
#   0  <target> now holds what <command> wrote
#   1  <command> failed, or the rename failed; the temp file is removed and <target> is left
#      exactly as it was
cerebro_state_write_atomic() {
  local target="$1"; shift
  local tmp="$target.$$.tmp"
  "$@" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
  return 0
}
