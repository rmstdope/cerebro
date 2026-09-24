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
[{"id":"cb-c","priority":1,"title":"c","labels":["ux:agreed"]},
 {"id":"cb-b","priority":0,"title":"b","labels":["ux:agreed"]},
 {"id":"cb-a","priority":1,"title":"a","labels":["ux:agreed"]}]
JSON
out="$(run)"
[[ "$(jq -c . <<<"$out")" == '[{"id":"cb-b","priority":0},{"id":"cb-a","priority":1},{"id":"cb-c","priority":1}]' ]] \
  || fail "the ready beads come back sorted by priority then id, got $out"
log="$(cat "$stub/bd.log")"
for want in --readonly " ready " "--exclude-label human" \
            "--exclude-label verdict:stale" "--exclude-label bugfix" \
            "--exclude-type epic" "-n 0" "--unassigned"; do
  [[ "$log" == *"$want"* ]] || fail "bd is asked with $want, got: $log"
done
[[ "$log" != *"--exclude-label planned"* ]] \
  || fail "planned is not excluded at bd, since a reopened rework bead carries it: $log"
pass "prints the ready UX-agreed beads sorted by priority then id"
pass "an assigned UX-agreed bead is never assignable (bd ready --unassigned)"

# --- planned means "a producer's own build plan", and only rework carries it unclaimed ------------
#
# `reopen-failed --fault build` keeps `planned` (the design was fine) and clears the claim, so the
# one unclaimed planned bead a producer may take is a reopened one (cb-gc45). Anything else planned
# and unclaimed is a producer that has not released it yet, or a plan somebody else wrote.

cat > "$stub/ready.json" <<'JSON'
[{"id":"cb-rework","priority":0,"labels":["ux:agreed","planned","verification:failed"]},
 {"id":"cb-planned","priority":0,"labels":["ux:agreed","planned"]},
 {"id":"cb-fresh","priority":1,"labels":["ux:agreed"]}]
JSON
out="$(run)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-rework","cb-fresh"]' ]] \
  || fail "a reopened planned bead is rework and assignable; a planned bead without a failed verification is not, got $out"
pass "a bead reopened for a build fault is assignable as rework; other planned beads are not"

# --- ux:none is the other way past the UX stage ---------------------------------------------------
#
# The navigator said at filing that nothing a person sees changes (cb-uump), so there is no
# experience to agree; a producer takes it as it would an agreed bead. A bead with neither label is
# still waiting for a designer, however ready `bd ready` says it is.

cat > "$stub/ready.json" <<'JSON'
[{"id":"cb-none","priority":1,"labels":["ux:none"]},
 {"id":"cb-agreed","priority":1,"labels":["ux:agreed"]},
 {"id":"cb-unagreed","priority":0,"labels":[]},
 {"id":"cb-nolabels","priority":0}]
JSON
out="$(run)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-agreed","cb-none"]' ]] \
  || fail "ux:none and ux:agreed are assignable, a bead with neither is not, got $out"
log="$(cat "$stub/bd.log")"
[[ "$log" != *"--label ux:agreed"* ]] \
  || fail "the stage label is not asked of bd, since either of two labels admits a bead: $log"
pass "a bead filed as touching nothing a person sees is assignable without a UX pass"

# --- an unranked bead reaches no producer ------------------------------------------------------
#
# P4 means the navigator has not ranked it (beads-workflow, *Writing a good bead*), and only Cerebro
# touches a P4 bead. The fleet view hands a producer this list's first entry, so the filter has to be
# here: on 2026-09-24 this repository's own fleet built two P4 beads, one straight onto main.

cat > "$stub/ready.json" <<'JSON'
[{"id":"cb-unranked","priority":4,"labels":["ux:none"]},
 {"id":"cb-nopriority","labels":["ux:agreed"]},
 {"id":"cb-ranked","priority":3,"labels":["ux:agreed"]}]
JSON
out="$(run)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-ranked"]' ]] \
  || fail "a P4 or unprioritised bead is never assignable, got $out"
pass "an unranked bead reaches no producer"

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
