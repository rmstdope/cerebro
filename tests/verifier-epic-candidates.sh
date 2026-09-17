#!/usr/bin/env bash
#
# Proves `scripts/verifier-epic-candidates`: epic families ready for one verification sweep.
#
# A family is listed when all children are closed and the epic or any child is still unverified.
# This includes OPEN eligible epics and CLOSED epics alike.
#
#     bash tests/verifier-epic-candidates.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

stub_dir="$work_dir/stub"
consumer="$work_dir/consumer"
mkdir -p "$stub_dir" "$consumer"

git init -q "$consumer"
mkdir -p "$consumer/.claude/cerebro"
for d in scripts agents skills hooks; do
  [ -d "$repo_root/$d" ] && cp -R "$repo_root/$d" "$consumer/.claude/cerebro/"
done

cat > "$stub_dir/bd" <<'STUB'
#!/usr/bin/env bash
stub_dir="STUB_DIR"
sub=""
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -C) skip=1 ;;
    -*) ;;
    *) sub="$a"; break ;;
  esac
done
[ -n "$sub" ] || sub="unknown"
argv="$stub_dir/argv.$sub"
for a in "$@"; do printf 'ARG:%s\n' "$a" >> "$argv"; done
cat "$stub_dir/stdout.$sub"
STUB
sed -i.bak "s|STUB_DIR|$stub_dir|" "$stub_dir/bd" && rm -f "$stub_dir/bd.bak"
chmod +x "$stub_dir/bd"

set_stdout() { printf '%s' "$2" > "$stub_dir/stdout.$1"; }

run() {
  rm -f "$stub_dir"/argv.*
  PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/verifier-epic-candidates"
}

children_for() {
  # $1 epic id, as recorded by the last `bd children` call's argv.
  grep -xF -A2 "ARG:children" "$stub_dir/argv.children" \
    | grep -xF "ARG:$1" >/dev/null
}

# --- includes an OPEN eligible epic and a CLOSED one when family is unverified ------------------
set_stdout list '[
  {"id":"ep-open","issue_type":"epic","status":"open","labels":[]},
  {"id":"ep-closed","issue_type":"epic","status":"closed","labels":["verification:passed"]},
  {"id":"ep-settled","issue_type":"epic","status":"closed","labels":["verification:not-needed"]},
  {"id":"ep-open-child","issue_type":"epic","status":"open","labels":[]}
]'
set_stdout children '[]'
# Dispatch per id by reading argv in order from the script itself.
cat > "$stub_dir/bd" <<'STUB'
#!/usr/bin/env bash
stub_dir="STUB_DIR"
sub=""
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -C) skip=1 ;;
    -*) ;;
    *) sub="$a"; break ;;
  esac
done
[ -n "$sub" ] || sub="unknown"
argv="$stub_dir/argv.$sub"
for a in "$@"; do printf 'ARG:%s\n' "$a" >> "$argv"; done
if [ "$sub" = "children" ]; then
  id=""
  got_children=0
  for a in "$@"; do
    if [ "$got_children" = 1 ]; then id="$a"; break; fi
    [ "$a" = "children" ] && got_children=1
  done
  cat "$stub_dir/stdout.children.$id"
else
  cat "$stub_dir/stdout.$sub"
fi
STUB
sed -i.bak "s|STUB_DIR|$stub_dir|" "$stub_dir/bd" && rm -f "$stub_dir/bd.bak"
chmod +x "$stub_dir/bd"
set_stdout "children.ep-open" '[{"id":"ep-open.1","status":"closed","labels":[]}]'
set_stdout "children.ep-closed" '[{"id":"ep-closed.1","status":"closed","labels":["verification:pending"]}]'
set_stdout "children.ep-settled" '[{"id":"ep-settled.1","status":"closed","labels":["verification:passed"]}]'
set_stdout "children.ep-open-child" '[{"id":"ep-open-child.1","status":"open","labels":[]}]'

ids="$(run)"
grep -qxF "ep-open" <<<"$ids" || fail "open eligible epic with unverified family was not listed"
grep -qxF "ep-closed" <<<"$ids" || fail "closed eligible epic with unverified family was not listed"
if grep -qxF "ep-settled" <<<"$ids"; then fail "fully settled epic family was listed"; fi
if grep -qxF "ep-open-child" <<<"$ids"; then fail "epic with open child was listed"; fi
pass "lists due families across open and closed eligible epics"

# --- a childless epic is never an epic-family candidate -----------------------------------------
set_stdout list '[{"id":"ep-lone","issue_type":"epic","status":"closed","labels":[]}]'
set_stdout "children.ep-lone" '[]'
ids="$(run)"
[ -z "$ids" ] || fail "childless epic was listed: '$ids'"
pass "does not list a childless epic"

# --- it asks bd list for open+closed ------------------------------------------------------------
run >/dev/null
grep -qxF "ARG:open,closed" "$stub_dir/argv.list" || fail "bd list was not asked for open,closed"
pass "asks bd list for open and closed beads"

suite_passed
