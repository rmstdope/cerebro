#!/usr/bin/env bash
#
# Proves scripts/sweep-epics.sh: every epic `bd epic status --eligible-only` calls closable, with
# the minutes since its last child closed, which the fleet view judges against its threshold
# (tests/lib/sweep-findings.json holds that judgement; this suite holds the script's facts).
#
# The fact that has broken is "last child": `bd children` also returns the `event` beads
# `bd set-state` files under an epic, and an event that closed after the last real child made the
# close look fresh and held the offer back. tests/lib/epic-family.json is the rule every
# implementation answers (cb-7iv1); here, `minutes_since_last_child_closed` is measured from the
# row's `last_child_closed_at`, and is null when that is.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/sweep-epics.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A stub `bd` on PATH ahead of the real one, which would read this machine's own backlog. It
# answers `epic status` from one file and `children` from another: one epic per case.
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
epics_file="$work_dir/epics.json"
children_file="$work_dir/children.json"
cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    epic) cat "$epics_file"; exit 0 ;;
    children) cat "$children_file"; exit 0 ;;
  esac
done
echo "stub bd: unexpected call: \$*" >&2
exit 1
STUB
chmod +x "$stub_dir/bd"
export PATH="$stub_dir:$PATH"

consumer="$(consumer_new repo --link consumer-root sweep-epics.sh)"
sweep="$consumer/.cerebro/cerebro/scripts/sweep-epics.sh"

# ISO-8601 UTC to a Unix timestamp, GNU or BSD date.
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s
}

# --- refuses a call without --json ---------------------------------------------------------------
set +e
(cd "$consumer" && "$sweep") >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "a call without --json: expected exit 2, got $status"
pass "refuses a call without --json"

# --- no eligible epic is an empty array ----------------------------------------------------------
echo '[]' > "$epics_file"
echo '[]' > "$children_file"
out="$(cd "$consumer" && "$sweep" --json)" || fail "sweep-epics.sh --json exited non-zero"
[ "$out" = "[]" ] || fail "no eligible epic printed '$out'"
pass "prints an empty array when no epic is eligible"

# --- the shared table: the last child is a real child, never an event ----------------------------
table="$repo_root/tests/lib/epic-family.json"
rows="$(jq -c '.[] | select(has("_") | not)' "$table")" || fail "could not read $table"
[ -n "$rows" ] || fail "$table has no rows"
bad=""
while IFS= read -r row; do
  name="$(jq -r '.name' <<<"$row")"
  epic_id="$(jq -r '.epic.id' <<<"$row")"
  last="$(jq -r '.last_child_closed_at // empty' <<<"$row")"
  jq -c '[{epic: {id: .epic.id, title: .name}}]' <<<"$row" > "$epics_file"
  jq -c '.under' <<<"$row" > "$children_file"
  if ! out="$(cd "$consumer" && "$sweep" --json)"; then
    bad="$bad
  $name: sweep-epics.sh exited non-zero"
    continue
  fi
  got="$(jq -r --arg id "$epic_id" '.[] | select(.id == $id) | .minutes_since_last_child_closed' <<<"$out")"
  if [ -z "$last" ]; then
    if [ "$got" != null ]; then
      bad="$bad
  $name: minutes is '$got', the table has no last child close"
    fi
  else
    # The script reads the clock a moment before this does, so a minute boundary may fall between.
    want=$(( ($(date -u +%s) - $(iso_to_epoch "$last")) / 60 ))
    if ! [[ "$got" =~ ^[0-9]+$ ]] || [ $(( want - got )) -lt 0 ] || [ $(( want - got )) -gt 1 ]; then
      bad="$bad
  $name: minutes is '$got', since $last is $want"
    fi
  fi
done <<<"$rows"
[ -z "$bad" ] || fail "sweep-epics.sh disagrees with tests/lib/epic-family.json:$bad"
pass "answers every row of the epic-family table"

suite_passed
