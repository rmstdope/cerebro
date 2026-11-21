#!/usr/bin/env bash
#
# Proves `scripts/verifier-pass-epic-family`: recording a full-epic pass across the whole family.
#
# It must close any open family member and mark the epic and all descendants
# `verification=passed` with the verified sha.
#
#     bash tests/verifier-pass-epic-family.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

stub_dir="$work_dir/stub"
mkdir -p "$stub_dir"

consumer="$(consumer_new repo --link verifier-pass-epic-family consumer-root)"

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
out="$stub_dir/stdout.$sub"
if [ "$sub" = "children" ]; then
  # `bd children <id>` answers per id; a bead with no file has no children.
  id=""
  next=0
  for a in "$@"; do
    if [ "$next" = 1 ]; then id="$a"; break; fi
    [ "$a" = "children" ] && next=1
  done
  out="$stub_dir/stdout.children.$id"
  [ -f "$out" ] || { [ -f "$stub_dir/exit.children" ] || echo '[]'; }
fi
if [ -f "$out" ]; then
  cat "$out"
fi
if [ -f "$stub_dir/exit.$sub" ]; then
  exit "$(cat "$stub_dir/exit.$sub")"
fi
exit 0
STUB
sed -i.bak "s|STUB_DIR|$stub_dir|" "$stub_dir/bd" && rm -f "$stub_dir/bd.bak"
chmod +x "$stub_dir/bd"

run() {
  rm -f "$stub_dir"/argv.*
  set +e
  out="$(PATH="$stub_dir:$PATH" bash "$consumer/.cerebro/cerebro/scripts/verifier-pass-epic-family" "$@" 2>"$stub_dir/err")"
  status=$?
  set -e
  err="$(cat "$stub_dir/err")"
}

set_stdout() {
  printf '%s' "$2" > "$stub_dir/stdout.$1"
}

clear_children() {
  rm -f "$stub_dir"/stdout.children.* "$stub_dir/exit.children"
}

# The ids one `bd <sub>` call was made for: the argument after the subcommand word.
ids_for() {
  [ -f "$stub_dir/argv.$1" ] || return 0
  awk -v word="ARG:$1" '$0 == word { if ((getline id) > 0) print substr(id, 5) }' "$stub_dir/argv.$1" | sort
}

sha40="0123456789abcdef0123456789abcdef01234567"

# --- records a passed epic family ---------------------------------------------------------------
set_stdout list '[
  {"id":"ep-1","issue_type":"epic","status":"open","labels":[]},
  {"id":"ep-1.1","issue_type":"task","status":"open","labels":[]},
  {"id":"ep-1.2","issue_type":"task","status":"closed","labels":["verification:pending"]},
  {"id":"ep-2","issue_type":"epic","status":"open","labels":[]}
]'
clear_children
set_stdout children.ep-1 '[
  {"id":"ep-1.1","issue_type":"task","status":"open","labels":[]},
  {"id":"ep-1.2","issue_type":"task","status":"closed","labels":["verification:pending"]},
  {"id":"ep-1.3","issue_type":"event","status":"open","labels":[]}
]'
run ep-1 --sha "$sha40"
[ "$status" -eq 0 ] || fail "records-a-passed-epic-family: expected exit 0, got $status ($err)"

# Closes only open members of the family.
grep -qxF "ARG:ep-1" "$stub_dir/argv.close" || fail "epic itself was not closed when open"
grep -qxF "ARG:ep-1.1" "$stub_dir/argv.close" || fail "open child was not closed"
if grep -qxF "ARG:ep-1.2" "$stub_dir/argv.close"; then
  fail "already-closed child was closed again"
fi
if grep -qxF "ARG:ep-2" "$stub_dir/argv.close"; then
  fail "bead outside the family was closed"
fi

# All family members get verification=passed and verified_at.
[ "$(grep -cxF "ARG:verification=passed" "$stub_dir/argv.set-state")" -eq 3 ] \
  || fail "verification=passed was not written for every family member"
[ "$(grep -c "ARG:verified_at=$sha40" "$stub_dir/argv.update")" -eq 3 ] \
  || fail "verified_at was not written for every family member"
[ "$(grep -cxF "ARG:verdict:stale" "$stub_dir/argv.update")" -eq 3 ] \
  || fail "verdict:stale was not removed for every family member"
[ "$(grep -cxF "ARG:second-look" "$stub_dir/argv.update")" -eq 3 ] \
  || fail "second-look was not removed for every family member (cb-0elv.3)"
grep -qxF "ARG:dolt" "$stub_dir/argv.dolt" || fail "bd dolt push was not called"
if grep -qxF "ARG:ep-1.3" "$stub_dir/argv.close" "$stub_dir/argv.set-state"; then
  fail "an event bead under the epic was treated as family"
fi
pass "records a passed epic family across epic and children"

# --- the family is what bd children says, not what the ids look like ----------------------------
set_stdout list '[
  {"id":"ep-3","issue_type":"epic","status":"closed","labels":[]},
  {"id":"ep-3.7","issue_type":"task","status":"closed","labels":[]}
]'
clear_children
set_stdout children.ep-3 '[{"id":"zz-9","issue_type":"task","status":"closed","labels":[]}]'
set_stdout children.zz-9 '[{"id":"zz-9.1","issue_type":"task","status":"open","labels":[]}]'
run ep-3 --sha "$sha40"
[ "$status" -eq 0 ] || fail "children-not-prefixes: expected exit 0, got $status ($err)"
got="$(ids_for set-state | tr '\n' ' ')"
[ "$got" = "ep-3 zz-9 zz-9.1 " ] \
  || fail "the family marked passed was '$got', not the epic, its child zz-9 and grandchild zz-9.1"
[ "$(ids_for close)" = "zz-9.1" ] || fail "only the open grandchild should have been closed: $(ids_for close)"
pass "marks the children bd reports, at every depth, and not beads that only share the prefix"

# --- a failed bd children is a failure, not an empty family ------------------------------------
clear_children
echo 1 > "$stub_dir/exit.children"
run ep-3 --sha "$sha40"
rm -f "$stub_dir/exit.children"
[ "$status" -eq 1 ] || fail "failed-children: expected exit 1, got $status"
[ ! -f "$stub_dir/argv.set-state" ] || fail "failed-children: marked beads passed without knowing the family"
pass "exits 1 without marking anything when bd children fails"

# --- the shared table: which beads under an epic are its family (cb-nm5p) ----------------------
table="$repo_root/tests/lib/epic-family.json"
rows="$(jq -c '.[] | select(has("_") | not)' "$table")" || fail "could not read $table"
[ -n "$rows" ] || fail "$table has no rows"
bad=""
while IFS= read -r row; do
  name="$(jq -r '.name' <<<"$row")"
  epic_id="$(jq -r '.epic.id' <<<"$row")"
  set_stdout list "$(jq -c '[.epic + {issue_type: "epic", labels: []}]' <<<"$row")"
  clear_children
  set_stdout "children.$epic_id" "$(jq -c '[.under[] + {labels: []}]' <<<"$row")"
  run "$epic_id" --sha "$sha40"
  if [ "$status" -ne 0 ]; then
    bad="$bad
  $name: exited $status ($err)"
    continue
  fi
  want_marked="$(jq -r '[.epic.id] + .family | .[]' <<<"$row" | sort)"
  want_closed="$(jq -r '. as $r | ([$r.epic] + [$r.under[] | select(.id as $i | $r.family | index($i))])
    | .[] | select(.status != "closed") | .id' <<<"$row" | sort)"
  got_marked="$(ids_for set-state)"
  got_closed="$(ids_for close)"
  if [ "$got_marked" != "$want_marked" ]; then
    bad="$bad
  $name: marked passed [$(echo $got_marked)], the epic and its family are [$(echo $want_marked)]"
  fi
  if [ "$got_closed" != "$want_closed" ]; then
    bad="$bad
  $name: closed [$(echo $got_closed)], the open members are [$(echo $want_closed)]"
  fi
done <<<"$rows"
[ -z "$bad" ] || fail "verifier-pass-epic-family disagrees with tests/lib/epic-family.json:$bad"
pass "answers every row of the epic-family table"

# --- refuses non-epics -------------------------------------------------------------------------
set_stdout list '[{"id":"tt-1","issue_type":"task","status":"open","labels":[]}]'
run tt-1 --sha "$sha40"
[ "$status" -eq 2 ] || fail "refuses-non-epics: expected exit 2, got $status"
grep -q "is not an epic" <<<"$err" || fail "refuses-non-epics: stderr did not say so: $err"
pass "refuses a non-epic id"

suite_passed
