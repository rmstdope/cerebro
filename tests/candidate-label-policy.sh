#!/usr/bin/env bash
#
# Proves the producer, bugfixer and UX queues all apply the shared verifier-only label policy.
#
#     bash tests/candidate-label-policy.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new policy --copy)"
scripts="$consumer/.cerebro/cerebro/scripts"
policy="$scripts/candidate-label-policy.sh"

[[ -f "$policy" ]] || fail "the shared candidate label policy is missing"
sed -i.bak 's/second-look/fixture-verifier-only/g' "$policy"
rm -f "$policy.bak"

stub="$work_dir/stub"
mkdir -p "$stub"
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_LOG"
if [[ " $* " == *" --label bugfix "* ]]; then
  jq '[.[] | select((.labels // []) | index("bugfix"))]' "$CANDIDATES"
else
  cat "$CANDIDATES"
fi
STUB
chmod +x "$stub/bd"

candidates="$work_dir/candidates.json"
cat > "$candidates" <<'JSON'
[
  {"id":"cb-producer","issue_type":"task","priority":1,"labels":["ux:agreed"]},
  {"id":"cb-producer-held","issue_type":"task","priority":0,"labels":["ux:agreed","fixture-verifier-only"]},
  {"id":"cb-bugfixer","issue_type":"bug","priority":1,"labels":["bugfix"]},
  {"id":"cb-bugfixer-held","issue_type":"bug","priority":0,"labels":["bugfix","fixture-verifier-only"]},
  {"id":"cb-ux","issue_type":"task","priority":1,"labels":[]},
  {"id":"cb-ux-held","issue_type":"task","priority":0,"labels":["fixture-verifier-only"]}
]
JSON

run() {
  local script="$1"
  shift
  CANDIDATES="$candidates" BD_LOG="$work_dir/bd.log" PATH="$stub:$PATH" \
    bash "$scripts/$script" "$@"
}

out="$(run assignable-beads)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-producer"]' ]] \
  || fail "the producer queue did not apply the shared verifier-only label policy: $out"
pass "the producer queue applies the shared verifier-only label policy"

out="$(run bugfix-candidates)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-bugfixer"]' ]] \
  || fail "the bugfixer queue did not apply the shared verifier-only label policy: $out"
pass "the bugfixer queue applies the shared verifier-only label policy"

out="$(run stage-candidates ux)"
[[ "$(jq -c '[.[].id]' <<<"$out")" == '["cb-ux"]' ]] \
  || fail "the UX queue did not apply the shared verifier-only label policy: $out"
pass "the UX queue applies the shared verifier-only label policy"

suite_passed
