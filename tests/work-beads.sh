#!/usr/bin/env bash
#
# Proves `scripts/work-beads`: the one place the harness asks "which closed beads are real work".
# The three bd quirks it owns - closed-by-default listings, epics as bookkeeping, and bd's own
# `event` audit beads - were each learnt separately by three different readers and fixed three
# times in two days (ah-cg1). These assertions are what stops a fourth reader learning them again.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/work-beads.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A stub `bd` on PATH ahead of the real one. It records its argv to $argv_file and prints whatever
# $stub_stdout holds, exiting with $stub_exit. Never the real `bd`: that would read this machine's
# own backlog and pass or fail by accident.
stub_dir="$(mktemp -d)"

# ah-il8j: the script resolves its root with `consumer-root --shared`, which answers only when this
# copy of cerebro is mounted at <consumer>/.claude/cerebro. Running it from cerebro's own tree - as
# this suite used to - exercises a layout it never runs in. So: a throwaway consumer with this
# submodule copied in, and every case runs the script from there.
cleanup_add "$stub_dir"
consumer="$(consumer_new repo --copy)"
# The library hands back a physical path already - `consumer-root --shared` resolves with `pwd -P`
# and on macOS $TMPDIR is under /var, a symlink to /private/var.
consumer_resolved="$consumer"

argv_file="$stub_dir/argv"
stub_stdout="$stub_dir/stdout"
stub_exit="$stub_dir/exit"

cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
: > "$argv_file"
for a in "\$@"; do printf 'ARG:%s\n' "\$a" >> "$argv_file"; done
cat "$stub_stdout"
exit "\$(cat "$stub_exit")"
STUB
chmod +x "$stub_dir/bd"

set_stub() {
  # $1 = stdout, $2 = exit status (default 0)
  printf '%s' "$1" > "$stub_stdout"
  printf '%s' "${2:-0}" > "$stub_exit"
}

run() {
  PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/work-beads" "$@"
}

argv_has() {
  grep -qxF "ARG:$1" "$argv_file"
}

# A flag and its value, adjacent and in that order.
argv_has_pair() {
  grep -qxF -A1 "ARG:$1" "$argv_file" && \
    [ "$(grep -xF -A1 "ARG:$1" "$argv_file" | tail -1)" = "ARG:$2" ]
}

empty_json='[]'
set_stub "$empty_json"

# --- refuses a call that names no status (cb-45f) -----------------------------------------------
#
# The default was `closed`, and every caller was a bare `work-beads | jq ...` - so the status that
# decides whether a query can match was on no line anyone read, and two beads in a row added an arm
# for an open bead to a closed-beads query. No default: exit 2, one line on stderr, nothing on
# stdout, and bd is never asked.
: > "$argv_file"
set +e
out="$(run 2>"$stub_dir/err")"
status=$?
set -e
[ "$status" -eq 2 ] || fail "a call with no --status: expected exit 2, got $status"
grep -q -- '--status is required' "$stub_dir/err" || fail "a call with no --status: stderr does not say so"
[ -z "$out" ] || fail "a call with no --status still printed '$out' on stdout"
[ ! -s "$argv_file" ] || fail "a call with no --status still reached bd"
pass "refuses a call that names no status, and never asks bd"

# --- passes the status it was given -------------------------------------------------------------
run --status open,closed > /dev/null
argv_has_pair "--status" "open,closed" || fail "--status was not passed through verbatim"
pass "passes the status it was given"

# --- the closed-after window --------------------------------------------------------------------
run --status closed --closed-after 2026-08-01 > /dev/null
argv_has_pair "--closed-after" "2026-08-01" || fail "--closed-after was not passed through"
pass "passes a closed-after window through"

run --status closed > /dev/null
if argv_has "--closed-after"; then fail "--closed-after reached bd when none was given"; fi
pass "omits the closed-after window when absent"

# --- asks bd to exclude epics and events --------------------------------------------------------
run --status closed > /dev/null
argv_has_pair "--exclude-type" "epic,event" || fail "no --exclude-type epic,event on the bd call"
argv_has "--json" || fail "no --json on the bd call"
pass "asks bd to exclude them as well"

# --- the jq guard, under a bd whose --exclude-type does not know event --------------------------
mixed='[{"id":"ah-a","issue_type":"task"},{"id":"ah-b","issue_type":"epic"},
        {"id":"ah-c","issue_type":"event"},{"id":"ah-d","issue_type":"bug"}]'
set_stub "$mixed"
ids="$(run --status closed | jq -r '.[].id' | tr '\n' ' ')"
[ "$ids" = "ah-a ah-d " ] || fail "epics and events survived the guard: got '$ids'"
pass "drops epics and events even when bd returns them"

# --- fails loudly when bd fails -----------------------------------------------------------------
set_stub "$empty_json" 1
if out="$(run --status closed 2>"$stub_dir/err")"; then
  fail "exited 0 when bd failed"
fi
[ -s "$stub_dir/err" ] || fail "bd failure produced nothing on stderr"
[ -z "$out" ] || fail "bd failure still printed '$out' on stdout"
pass "fails loudly when bd fails"

# --- fails loudly when bd prints something that is not JSON -------------------------------------
set_stub 'bd: could not open the database'
if out="$(run --status closed 2>"$stub_dir/err")"; then
  fail "exited 0 when bd printed something that is not JSON"
fi
[ -s "$stub_dir/err" ] || fail "unparseable output produced nothing on stderr"
[ -z "$out" ] || fail "unparseable output still printed '$out' on stdout"
pass "fails loudly when bd prints something that is not JSON"

# --- the excluded types, for the panel to check itself against ----------------------------------
set_stub "$empty_json"
types="$(run --print-excluded-types)"
[ "$types" = "$(printf 'epic\nevent')" ] || fail "--print-excluded-types printed '$types'"
pass "prints the excluded types for the panel to check itself against"

# --- asks bd about the fleet's repository, not the caller's (ah-il8j) ---------------------------
#
# The bug was that no `-C` was passed at all, so `bd` answered about whichever repository the
# caller's working directory happened to be in - well-formed JSON about the wrong database, which
# reads as a quiet day. The stub records its argv, so calling from somewhere else entirely is what
# makes the assertion mean anything.
other="$(consumer_new other)"
set_stub "$empty_json"
( cd "$other" && PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/work-beads" --status closed >/dev/null )
argv_has "-C" || fail "no -C was passed: bd answered about the caller's repository"
argv_has_pair "-C" "$consumer_resolved" || fail "-C did not name the consumer root"
pass "asks bd about the consumer root, not the caller's repository"

# --- --print-excluded-types needs no repository at all ------------------------------------------
outside="$(mktemp -d)"
types="$(cd "$outside" && PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/work-beads" --print-excluded-types)"
[ "$types" = "$(printf 'epic\nevent')" ] || fail "--print-excluded-types outside a repository printed '$types'"
rm -rf "$outside"
pass "prints the excluded types without needing a repository"

suite_passed
