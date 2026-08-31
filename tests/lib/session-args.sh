# tests/lib/session-args.sh - the one bash reader of tests/lib/session-args.cases.
#
# SOURCED, NEVER EXECUTED, and never run as a suite: it lives under `tests/lib/` precisely so the
# gate's `for t in tests/*.sh` glob cannot pick it up. That is also why it may assume
# `tests/lib/consumer.sh` has already been sourced - `fail` and `pass` come from there.
#
# Every bash subscriber of the case table parses the same file, and two parsers of one table is the
# same class of duplication the table itself exists to close (cb-akt). Source it after
# consumer.sh:
#
#     source "$repo_root/tests/lib/consumer.sh"
#     source "$repo_root/tests/lib/session-args.sh"
#
# The surface is one function.
#
#   session_args_render <cases-file> <root> <other> <outfile>
#
# Renders every row of <cases-file> into <outfile> as four NUL-terminated fields per row:
#
#   expect ("alive"|"dead"), name, root, field
#
# {root} and {other} are substituted in both the root column and the field, and `\n' in the field
# becomes a newline. It echoes the number of rows it wrote. A malformed row, an unreadable file, a
# table with no rows, or a table with no alive row or no dead row, is a `fail' - the table going
# missing or empty must never pass as "every row held".
#
# Two shapes here are load-bearing, and neither is decoration:
#
#   - NUL-TERMINATED FIELDS, read back with `while IFS= read -r -d '' ...'. A field now carries
#     newlines - the store's rows hold the marker as the first sentence of a whole prompt - so a
#     line-delimited protocol would split one row into several. `scripts/launch' reads
#     `agent-cli --argv' the same way and for the same reason.
#   - IT WRITES A FILE RATHER THAN A STREAM. A generator piped through a process substitution runs
#     in a subshell whose exit status nobody reads, so `fail' there kills the subshell and the
#     caller goes on to read a short file and pass - the `.cerebro/traps.md` family about a status
#     nobody checks. Writing the rows to a file keeps them whole however the function is called.
#
#     Both callers do read its row count through a command substitution, which is a subshell too,
#     so `fail' does not by itself end the suite there. What ends it is that the assignment takes
#     the failed status under `set -e', and that a suite dying before its last line is red rather
#     than green - `suite_passed'. So the row count must always be read into a variable under
#     errexit, never into a `[[ ... ]]' or the left of a `&&', either of which would swallow it.

session_args_render() {
  local cases="$1" root="$2" other="$3" out="$4"
  local expect name row_root field rows=0 alive=0 dead=0

  [[ -r "$cases" ]] || fail "session-args table: cannot read $cases"
  : > "$out" || fail "session-args table: cannot write $out"

  while read -r expect name row_root field; do
    case "$expect" in ''|'#'*) continue ;; esac
    case "$expect" in
      alive) alive=1 ;;
      dead)  dead=1 ;;
      *) fail "session-args table: row $((rows+1)) expects '$expect', not alive or dead" ;;
    esac
    [[ -n "$name" && -n "$row_root" && -n "$field" ]] \
      || fail "session-args table: row $((rows+1)) is malformed: $expect $name $row_root $field"
    case "$row_root" in
      '{root}')  row_root="$root" ;;
      '{other}') row_root="$other" ;;
      *) fail "session-args table: row $((rows+1)) names a root that is not {root} or {other}: $row_root" ;;
    esac
    field="${field//\{root\}/$root}"
    field="${field//\{other\}/$other}"
    # The table's only escape. `printf %b' would also eat every backslash the field carries, so
    # the substitution is written out rather than delegated.
    field="${field//\\n/$'\n'}"
    printf '%s\0%s\0%s\0%s\0' "$expect" "$name" "$row_root" "$field" >> "$out"
    rows=$((rows+1))
  done < "$cases"

  # A table nobody can read, or one that went empty, must not pass as "every row held" - and one
  # that lost every row of one kind proves only half the rule.
  [[ "$rows" -ge 2 ]] || fail "session-args table: only $rows rows read from $cases"
  [[ "$alive" -eq 1 ]] || fail "session-args table: no alive row in $cases"
  [[ "$dead" -eq 1 ]] || fail "session-args table: no dead row in $cases"

  printf '%s' "$rows"
}
