#!/usr/bin/env bash
#
# Proves `scripts/bugfix-candidates`: the one place "which beads may a bugfixer be given" is
# answered.
#
#     bash tests/bugfix-candidates.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link bugfix-candidates consumer-root)"
stub="$work_dir/stub"
mkdir -p "$stub"
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
[ -f "$STUB_DIR/ready.json" ] && cat "$STUB_DIR/ready.json"
exit "${BD_EXIT:-0}"
STUB
chmod +x "$stub/bd"

run() {
  rm -f "$stub/bd.log"
  STUB_DIR="$stub" PATH="$stub:$PATH" bash "$consumer/.cerebro/cerebro/scripts/bugfix-candidates" "$@"
}

# --- prints the ready bugfix beads sorted by priority then id -----------------------------------

cat > "$stub/ready.json" <<'JSON'
[{"id":"cb-c","priority":1,"title":"c"},{"id":"cb-b","priority":0,"title":"b"},{"id":"cb-a","priority":1,"title":"a"}]
JSON
out="$(run)"
[[ "$(jq -c . <<<"$out")" == '[{"id":"cb-b","priority":0},{"id":"cb-a","priority":1},{"id":"cb-c","priority":1}]' ]] \
  || fail "the bugfix candidates come back sorted by priority then id, got $out"
log="$(cat "$stub/bd.log")"
for want in --readonly " ready " "--label bugfix" "--exclude-label human" \
            "--exclude-label verdict:stale" "--exclude-type epic" "-n 0" "--unassigned"; do
  [[ "$log" == *"$want"* ]] || fail "bd is asked with $want, got: $log"
done
pass "prints the ready bugfix beads sorted by priority then id"

# --- an unranked bug reaches no bugfixer --------------------------------------------------------
#
# A bug is filed at P4 like everything else and ranked by Cerebro with the navigator; the bugfixer
# is handed this list's first entry, so P4 (and a missing priority) is dropped here.

cat > "$stub/ready.json" <<'JSON'
[{"id":"cb-unranked","priority":4,"labels":["bugfix"]},
 {"id":"cb-nopriority","labels":["bugfix"]},
 {"id":"cb-ranked","priority":2,"labels":["bugfix"]}]
JSON
out="$(run)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-ranked"]' ]] \
  || fail "a P4 or unprioritised bug is never a bugfix candidate, got $out"
pass "an unranked bug reaches no bugfixer"

# --- a bug handed back to the verifier is hers until she looks (cb-wf24) ------------------------
cat > "$stub/ready.json" <<'JSON'
[{"id":"cb-handed","priority":0,"labels":["bugfix","verification:failed","second-look"]},
 {"id":"cb-fresh","priority":1,"labels":["bugfix"]}]
JSON
out="$(run)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-fresh"]' ]] \
  || fail "a second-look bug is never a bugfix candidate, got $out"
log="$(cat "$stub/bd.log")"
[[ "$log" == *"--exclude-label second-look"* ]] || fail "bd is asked to exclude second-look: $log"
pass "a bug handed back to the verifier is not a bugfix candidate"

# --- any argument is a usage error ---------------------------------------------------------------

status=0
out="$(run --all 2>/dev/null)" || status=$?
[[ $status -eq 2 && -z "$out" ]] || fail "an argument is exit 2 with nothing on stdout, got $status: $out"
pass "any argument is a usage error"

# --- a bd failure is exit 1 with nothing on stdout -----------------------------------------------

status=0
out="$(BD_EXIT=1 run 2>/dev/null)" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "a bd failure is exit 1 with nothing on stdout, got $status: $out"
pass "a bd failure is exit 1 with nothing on stdout"

suite_passed
