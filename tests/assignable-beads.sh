#!/usr/bin/env bash
#
# Proves `scripts/assignable-beads`: the one place "which UX-agreed beads may a producer be given" is
# answered (cb-10d.1). The fleet view's work reader and `scripts/assign-bead` both call it, so they
# cannot disagree about what a builder may take.
#
#     bash tests/assignable-beads.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link assignable-beads consumer-root)"
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
  STUB_DIR="$stub" PATH="$stub:$PATH" bash "$consumer/.cerebro/cerebro/scripts/assignable-beads" "$@"
}

# --- prints the ready UX-agreed beads sorted by priority then id -------------------------------

cat > "$stub/ready.json" <<'JSON'
[{"id":"cb-c","priority":1,"title":"c"},{"id":"cb-b","priority":0,"title":"b"},{"id":"cb-a","priority":1,"title":"a"}]
JSON
out="$(run)"
[[ "$(jq -c . <<<"$out")" == '[{"id":"cb-b","priority":0},{"id":"cb-a","priority":1},{"id":"cb-c","priority":1}]' ]] \
  || fail "the ready beads come back sorted by priority then id, got $out"
log="$(cat "$stub/bd.log")"
for want in --readonly " ready " "--label ux:agreed" "--exclude-label planned" "--exclude-label human" \
            "--exclude-label verdict:stale" "--exclude-label bugfix" \
            "--exclude-type epic" "-n 0" "--unassigned"; do
  [[ "$log" == *"$want"* ]] || fail "bd is asked with $want, got: $log"
done
pass "prints the ready UX-agreed beads sorted by priority then id"
pass "an assigned UX-agreed bead is never assignable (bd ready --unassigned)"

# --- retired and unknown roles are usage errors --------------------------------------------------

status=0
out="$(run implementer 2>/dev/null)" || status=$?
[[ $status -eq 2 && -z "$out" ]] || fail "the retired implementer role is exit 2 with nothing on stdout, got $status: $out"
pass "the retired implementer role is refused"

status=0
out="$(run --all 2>/dev/null)" || status=$?
[[ $status -eq 2 && -z "$out" ]] || fail "an unknown argument is exit 2 with nothing on stdout, got $status: $out"
pass "an unknown argument is a usage error"

# --- a bd failure is exit 1 with nothing on stdout ----------------------------------------------

status=0
out="$(BD_EXIT=1 run 2>/dev/null)" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "a bd failure is exit 1 with nothing on stdout, got $status: $out"
pass "a bd failure is exit 1 with nothing on stdout"

suite_passed
