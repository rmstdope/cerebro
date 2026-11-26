#!/usr/bin/env bash
#
# Proves scripts/transcript-keep keeps a fleet session's Claude Code transcript inside the consumer
# (cb-koio.1), so it outlives Claude Code's own ~30-day cleanup: the `hook' mode mirrors the session
# that ran it, `--backfill' mirrors what Claude Code still holds for this consumer, and the hook
# never prints or fails, being wired as a `Stop' and a `SessionEnd' hook.
#
#     bash tests/transcript-keep.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"
source "$repo_root/scripts/session-marker.sh"

new_fixture() {
  consumer_new "$(fixture_name)" --link consumer-root session-marker.sh transcript-keep
}

# The root exactly as the script resolves it, so the test spells the same marker and project dir.
fixture_root() {
  (cd "$1" && "$1/.cerebro/cerebro/scripts/consumer-root" --shared)
}

# Claude Code's project directory for a root: every non-alphanumeric character becomes `-'.
project_dir() {
  local config="$1" root="$2"
  printf '%s/projects/%s' "$config" "$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')"
}

# A transcript with a fleet marker for <root> in its first prompt, and a sub-agent beside it.
make_session() {
  local dir="$1" id="$2" root="$3"
  mkdir -p "$dir/$id/subagents"
  printf '{"type":"user","message":{"content":"%s"}}\n' "$(cerebro_marker_sentence Cyclops "$root")" > "$dir/$id.jsonl"
  printf '{"type":"assistant","message":{"content":"ok"}}\n' >> "$dir/$id.jsonl"
  printf '{"type":"user","message":{"content":"review this"}}\n' > "$dir/$id/subagents/agent-a1.jsonl"
}

hook_payload() {
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$1" "$2"
}

run_hook() {
  local tmp="$1" config="$2" payload="$3"
  (cd "$tmp" && CEREBRO_AGENT_NAME=Cyclops CLAUDE_CONFIG_DIR="$config" \
    "$tmp/.cerebro/cerebro/scripts/transcript-keep" hook <<<"$payload")
}

kept() { printf '%s/.cerebro/state/transcripts' "$1"; }

# --- hook-keeps-transcript-and-session-dir ---
tmp="$(new_fixture)"; root="$(fixture_root "$tmp")"; config="$work_dir/$(fixture_name cfg)"
pd="$(project_dir "$config" "$root")"; mkdir -p "$pd"
make_session "$pd" s1 "$root"
mkdir -p "$(kept "$tmp")"; : > "$(kept "$tmp")/.backfilled"
out="$(run_hook "$tmp" "$config" "$(hook_payload s1 "$pd/s1.jsonl")")"
[[ -z "$out" ]] || fail "hook-keeps-transcript-and-session-dir: wrote to stdout: $out"
cmp -s "$pd/s1.jsonl" "$(kept "$tmp")/s1.jsonl" \
  || fail "hook-keeps-transcript-and-session-dir: transcript not kept"
cmp -s "$pd/s1/subagents/agent-a1.jsonl" "$(kept "$tmp")/s1/subagents/agent-a1.jsonl" \
  || fail "hook-keeps-transcript-and-session-dir: sub-agent transcript not kept"
pass "hook-keeps-transcript-and-session-dir"

# --- hook-refreshes-a-grown-transcript ---
# Back-date the first copy so the grown source is unambiguously newer on a coarse-mtime filesystem.
touch -t 202001010000 "$(kept "$tmp")/s1.jsonl"
printf '{"type":"assistant","message":{"content":"more"}}\n' >> "$pd/s1.jsonl"
run_hook "$tmp" "$config" "$(hook_payload s1 "$pd/s1.jsonl")" >/dev/null
cmp -s "$pd/s1.jsonl" "$(kept "$tmp")/s1.jsonl" \
  || fail "hook-refreshes-a-grown-transcript: copy not refreshed"
pass "hook-refreshes-a-grown-transcript"

# --- kept-copy-survives-source-deletion ---
# What Claude Code's cleanup does after ~30 days. The copy is the consumer's own and stays.
saved="$(cat "$pd/s1.jsonl")"
rm -rf "$pd/s1.jsonl" "$pd/s1"
[[ "$(cat "$(kept "$tmp")/s1.jsonl")" == "$saved" ]] \
  || fail "kept-copy-survives-source-deletion: copy changed or gone"
[[ -f "$(kept "$tmp")/s1/subagents/agent-a1.jsonl" ]] \
  || fail "kept-copy-survives-source-deletion: sub-agent copy gone"
# A hook call naming a transcript that no longer exists leaves the copy alone.
run_hook "$tmp" "$config" "$(hook_payload s1 "$pd/s1.jsonl")" >/dev/null
[[ "$(cat "$(kept "$tmp")/s1.jsonl")" == "$saved" ]] \
  || fail "kept-copy-survives-source-deletion: a later hook call damaged the copy"
pass "kept-copy-survives-source-deletion"

# --- hook-without-fleet-name-keeps-nothing ---
tmp="$(new_fixture)"; root="$(fixture_root "$tmp")"; config="$work_dir/$(fixture_name cfg)"
pd="$(project_dir "$config" "$root")"; mkdir -p "$pd"; make_session "$pd" s2 "$root"
set +e
out="$(cd "$tmp" && env -u CEREBRO_AGENT_NAME CLAUDE_CONFIG_DIR="$config" \
  "$tmp/.cerebro/cerebro/scripts/transcript-keep" hook <<<"$(hook_payload s2 "$pd/s2.jsonl")")"
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "hook-without-fleet-name-keeps-nothing: exit $rc"
[[ -z "$out" ]] || fail "hook-without-fleet-name-keeps-nothing: wrote to stdout: $out"
[[ ! -e "$(kept "$tmp")" ]] || fail "hook-without-fleet-name-keeps-nothing: wrote $(kept "$tmp")"
pass "hook-without-fleet-name-keeps-nothing"

# --- hook-on-garbage-stdin-is-silent-and-zero ---
# Backfill already done, so anything kept here could only have come from the bad payload.
mkdir -p "$(kept "$tmp")"; : > "$(kept "$tmp")/.backfilled"
for payload in "" "not json" '{"session_id":"s3"}' '{"session_id":"../x","transcript_path":"/etc/hosts"}'; do
  set +e
  out="$(run_hook "$tmp" "$config" "$payload" 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || fail "hook-on-garbage-stdin-is-silent-and-zero: exit $rc for [$payload]"
  [[ -z "$out" ]] || fail "hook-on-garbage-stdin-is-silent-and-zero: stdout for [$payload]: $out"
  if [[ -d "$(kept "$tmp")" && -n "$(find "$(kept "$tmp")" -name '*.jsonl')" ]]; then
    fail "hook-on-garbage-stdin-is-silent-and-zero: kept a transcript for [$payload]"
  fi
done
[[ ! -e "$tmp/.cerebro/state/x.jsonl" ]] || fail "hook-on-garbage-stdin-is-silent-and-zero: escaped the dir"
pass "hook-on-garbage-stdin-is-silent-and-zero"

# --- backfill-keeps-only-this-roots-fleet-sessions ---
tmp="$(new_fixture)"; root="$(fixture_root "$tmp")"; config="$work_dir/$(fixture_name cfg)"
pd="$(project_dir "$config" "$root")"; mkdir -p "$pd"
make_session "$pd" mine "$root"
make_session "$pd" sibling "$root-hud"
printf '{"type":"user","message":{"content":"an ordinary session"}}\n' > "$pd/plain.jsonl"
out="$(cd "$tmp" && CLAUDE_CONFIG_DIR="$config" "$tmp/.cerebro/cerebro/scripts/transcript-keep" --backfill)"
cmp -s "$pd/mine.jsonl" "$(kept "$tmp")/mine.jsonl" || fail "backfill: this root's session not kept"
[[ -f "$(kept "$tmp")/mine/subagents/agent-a1.jsonl" ]] || fail "backfill: session dir not kept"
[[ ! -e "$(kept "$tmp")/sibling.jsonl" ]] || fail "backfill: kept a sibling root's session"
[[ ! -e "$(kept "$tmp")/plain.jsonl" ]] || fail "backfill: kept a non-fleet session"
[[ -f "$(kept "$tmp")/.backfilled" ]] || fail "backfill: .backfilled not written"
grep -q "transcript-keep: 1 fleet transcripts kept in .*, 0 could not be copied" <<<"$out" || fail "backfill: count line missing: $out"
pass "backfill-keeps-only-this-roots-fleet-sessions"

# --- hook-backfills-once ---
tmp="$(new_fixture)"; root="$(fixture_root "$tmp")"; config="$work_dir/$(fixture_name cfg)"
pd="$(project_dir "$config" "$root")"; mkdir -p "$pd"
make_session "$pd" older "$root"
make_session "$pd" now "$root"
out="$(run_hook "$tmp" "$config" "$(hook_payload now "$pd/now.jsonl")")"
[[ -z "$out" ]] || fail "hook-backfills-once: wrote to stdout: $out"
[[ -f "$(kept "$tmp")/older.jsonl" ]] || fail "hook-backfills-once: first hook call did not backfill"
[[ -f "$(kept "$tmp")/.backfilled" ]] || fail "hook-backfills-once: .backfilled not written"
make_session "$pd" later "$root"
run_hook "$tmp" "$config" "$(hook_payload now "$pd/now.jsonl")" >/dev/null
[[ ! -e "$(kept "$tmp")/later.jsonl" ]] || fail "hook-backfills-once: backfilled a second time"
pass "hook-backfills-once"

# --- hook-refreshes-another-kept-session ---
# A session killed mid-turn gets no Stop of its own; another session's turn end catches it up.
tmp="$(new_fixture)"; root="$(fixture_root "$tmp")"; config="$work_dir/$(fixture_name cfg)"
pd="$(project_dir "$config" "$root")"; mkdir -p "$pd"
make_session "$pd" killed "$root"; make_session "$pd" alive "$root"
run_hook "$tmp" "$config" "$(hook_payload killed "$pd/killed.jsonl")" >/dev/null
touch -t 202001010000 "$(kept "$tmp")/killed.jsonl"
printf '{"type":"assistant","message":{"content":"the turn that never ended"}}\n' >> "$pd/killed.jsonl"
run_hook "$tmp" "$config" "$(hook_payload alive "$pd/alive.jsonl")" >/dev/null
cmp -s "$pd/killed.jsonl" "$(kept "$tmp")/killed.jsonl" \
  || fail "hook-refreshes-another-kept-session: killed session's copy not refreshed"
pass "hook-refreshes-another-kept-session"

# --- hook-sweeps-old-temp-files ---
mkdir -p "$(kept "$tmp")/killed"
: > "$(kept "$tmp")/.keep.old1"; : > "$(kept "$tmp")/killed/.keep.old2"; : > "$(kept "$tmp")/.keep.new"
touch -t 202001010000 "$(kept "$tmp")/.keep.old1" "$(kept "$tmp")/killed/.keep.old2"
run_hook "$tmp" "$config" "$(hook_payload alive "$pd/alive.jsonl")" >/dev/null
[[ ! -e "$(kept "$tmp")/.keep.old1" && ! -e "$(kept "$tmp")/killed/.keep.old2" ]] \
  || fail "hook-sweeps-old-temp-files: an old temp file survived"
[[ -e "$(kept "$tmp")/.keep.new" ]] || fail "hook-sweeps-old-temp-files: swept a fresh temp file"
pass "hook-sweeps-old-temp-files"

# --- hook-whose-copy-fails-is-silent-and-zero ---
# Root ignores the mode bits, so the case means nothing there.
if [[ "$(id -u)" != 0 ]]; then
  make_session "$pd" blocked "$root"
  chmod 555 "$(kept "$tmp")"
  set +e
  out="$(run_hook "$tmp" "$config" "$(hook_payload blocked "$pd/blocked.jsonl")")"
  rc=$?
  set -e
  chmod 755 "$(kept "$tmp")"
  [[ $rc -eq 0 ]] || fail "hook-whose-copy-fails-is-silent-and-zero: exit $rc"
  [[ -z "$out" ]] || fail "hook-whose-copy-fails-is-silent-and-zero: wrote to stdout: $out"
  pass "hook-whose-copy-fails-is-silent-and-zero"
fi

# --- backfill-ignores-a-marker-quoted-after-the-first-prompt ---
tmp="$(new_fixture)"; root="$(fixture_root "$tmp")"; config="$work_dir/$(fixture_name cfg)"
pd="$(project_dir "$config" "$root")"; mkdir -p "$pd"
printf '{"type":"user","isMeta":true,"message":{"content":"caveat"}}\n' > "$pd/fleet.jsonl"
printf '{"type":"user","message":{"content":"%s"}}\n' "$(cerebro_marker_sentence Cyclops "$root")" >> "$pd/fleet.jsonl"
printf '{"type":"user","message":{"content":"/clear"}}\n' > "$pd/quoting.jsonl"
printf '{"type":"user","message":{"content":"%s"}}\n' "$(cerebro_marker_sentence Cyclops "$root")" >> "$pd/quoting.jsonl"
(cd "$tmp" && CLAUDE_CONFIG_DIR="$config" "$tmp/.cerebro/cerebro/scripts/transcript-keep" --backfill) >/dev/null
[[ -f "$(kept "$tmp")/fleet.jsonl" ]] || fail "backfill-ignores-quoted: a fleet session behind a meta line was not kept"
[[ ! -e "$(kept "$tmp")/quoting.jsonl" ]] || fail "backfill-ignores-quoted: kept a session that only quotes the marker"
pass "backfill-ignores-a-marker-quoted-after-the-first-prompt"

suite_passed
