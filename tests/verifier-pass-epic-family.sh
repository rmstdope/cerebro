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
if [ -f "$stub_dir/stdout.$sub" ]; then
  cat "$stub_dir/stdout.$sub"
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

sha40="0123456789abcdef0123456789abcdef01234567"

# --- records a passed epic family ---------------------------------------------------------------
set_stdout list '[
  {"id":"ep-1","issue_type":"epic","status":"open","labels":[]},
  {"id":"ep-1.1","issue_type":"task","status":"open","labels":[]},
  {"id":"ep-1.2","issue_type":"task","status":"closed","labels":["verification:pending"]},
  {"id":"ep-2","issue_type":"epic","status":"open","labels":[]}
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
pass "records a passed epic family across epic and children"

# --- refuses non-epics -------------------------------------------------------------------------
set_stdout list '[{"id":"tt-1","issue_type":"task","status":"open","labels":[]}]'
run tt-1 --sha "$sha40"
[ "$status" -eq 2 ] || fail "refuses-non-epics: expected exit 2, got $status"
grep -q "is not an epic" <<<"$err" || fail "refuses-non-epics: stderr did not say so: $err"
pass "refuses a non-epic id"

suite_passed
