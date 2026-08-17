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

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# A stub `bd` on PATH ahead of the real one. It records its argv to $argv_file and prints whatever
# $stub_stdout holds, exiting with $stub_exit. Never the real `bd`: that would read this machine's
# own backlog and pass or fail by accident.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

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
  PATH="$stub_dir:$PATH" bash "$repo_root/scripts/work-beads" "$@"
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

# --- defaults to closed beads -------------------------------------------------------------------
run > /dev/null
argv_has_pair "--status" "closed" || fail "no --status closed on the bd call by default"
pass "defaults to closed beads"

# --- passes the status it was given -------------------------------------------------------------
run --status open,closed > /dev/null
argv_has_pair "--status" "open,closed" || fail "--status was not passed through verbatim"
pass "passes the status it was given"

# --- the closed-after window --------------------------------------------------------------------
run --closed-after 2026-08-01 > /dev/null
argv_has_pair "--closed-after" "2026-08-01" || fail "--closed-after was not passed through"
pass "passes a closed-after window through"

run > /dev/null
if argv_has "--closed-after"; then fail "--closed-after reached bd when none was given"; fi
pass "omits the closed-after window when absent"

# --- asks bd to exclude epics and events --------------------------------------------------------
run > /dev/null
argv_has_pair "--exclude-type" "epic,event" || fail "no --exclude-type epic,event on the bd call"
argv_has "--json" || fail "no --json on the bd call"
pass "asks bd to exclude them as well"

# --- the jq guard, under a bd whose --exclude-type does not know event --------------------------
mixed='[{"id":"ah-a","issue_type":"task"},{"id":"ah-b","issue_type":"epic"},
        {"id":"ah-c","issue_type":"event"},{"id":"ah-d","issue_type":"bug"}]'
set_stub "$mixed"
ids="$(run | jq -r '.[].id' | tr '\n' ' ')"
[ "$ids" = "ah-a ah-d " ] || fail "epics and events survived the guard: got '$ids'"
pass "drops epics and events even when bd returns them"

# --- fails loudly when bd fails -----------------------------------------------------------------
set_stub "$empty_json" 1
if out="$(run 2>"$stub_dir/err")"; then
  fail "exited 0 when bd failed"
fi
[ -s "$stub_dir/err" ] || fail "bd failure produced nothing on stderr"
[ -z "$out" ] || fail "bd failure still printed '$out' on stdout"
pass "fails loudly when bd fails"

# --- fails loudly when bd prints something that is not JSON -------------------------------------
set_stub 'bd: could not open the database'
if out="$(run 2>"$stub_dir/err")"; then
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

echo "all work-beads assertions passed"
