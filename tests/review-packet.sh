#!/usr/bin/env bash
#
# Proves `scripts/review-packet <id> <pr> --gated <sha>` (cb-0x9h): the one prompt a producer hands
# its cold-read review sub-agent. It carries the head sha, the changed files, the diff, the bead's
# plan and acceptance, and the fast gate with its result at that sha; a gate that ran at another sha
# is refused (exit 3), and a failed read is never printed as an empty packet (exit 1).
#
#     bash tests/review-packet.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link review-packet project-conf consumer-root)"
stub="$work_dir/stub"
mkdir -p "$stub"

# Stub `gh': `pr view' from view.json, `pr diff --name-only' from files.txt, `pr diff' from
# diff.txt; each fails when its GH_*_EXIT is set.
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "pr view 7 --json"*)          [ -z "${GH_VIEW_EXIT:-}" ] || exit "$GH_VIEW_EXIT"
                                # view-2.json, when present, answers every call after the first:
                                # a push that landed while the packet was being made.
                                if [ -e "$STUB_DIR/view-2.json" ] && [ -e "$STUB_DIR/viewed" ]; then
                                  cat "$STUB_DIR/view-2.json"
                                else touch "$STUB_DIR/viewed"; cat "$STUB_DIR/view.json"; fi ;;
  "pr diff 7 --name-only")      [ -z "${GH_FILES_EXIT:-}" ] || exit "$GH_FILES_EXIT"; cat "$STUB_DIR/files.txt" ;;
  "pr diff 7")                  [ -z "${GH_DIFF_EXIT:-}" ] || exit "$GH_DIFF_EXIT"; cat "$STUB_DIR/diff.txt" ;;
  *) echo "review-packet stub: unexpected gh $*" >&2; exit 1 ;;
esac
STUB
# Stub `bd': `show <id> --json' from show.json, or fails under BD_SHOW_EXIT.
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
args=()
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -C) skip=1 ;; *) args+=("$a") ;; esac
done
case "${args[0]}" in
  show) [ -z "${BD_SHOW_EXIT:-}" ] || exit "$BD_SHOW_EXIT"; cat "$STUB_DIR/show.json" ;;
  *) echo "review-packet stub: unexpected bd $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/gh" "$stub/bd"
export STUB_DIR="$stub"
export PATH="$stub:$PATH"

head_sha="abc123def4567890abc123def4567890abc12345"

reset() {
  unset GH_VIEW_EXIT GH_FILES_EXIT GH_DIFF_EXIT BD_SHOW_EXIT
  rm -f "$stub/view-2.json" "$stub/viewed" "$consumer/Makefile"
  printf 'gate_fast bash tests/gate\n' > "$consumer/.cerebro/project.conf"
  jq -n --arg h "$head_sha" '{number: 7, title: "feat(cb-x): a thing", headRefOid: $h,
    baseRefName: "main", url: "https://github.com/o/r/pull/7"}' > "$stub/view.json"
  printf 'scripts/thing\ntests/thing.sh\n' > "$stub/files.txt"
  printf 'diff --git a/scripts/thing b/scripts/thing\n+echo hello\n' > "$stub/diff.txt"
  jq -n '[{id: "cb-x", title: "A thing", issue_type: "feature", labels: ["ux:none", "planned"],
    description: "Why a thing.", acceptance_criteria: "A thing is printed.",
    design: "## Context\nThe plan body.", notes: "## Navigator'"'"'s answer\nYes."}]' > "$stub/show.json"
}

packet() { (cd "$consumer" && .cerebro/cerebro/scripts/review-packet "$@"); }

# --- the happy path ---
reset
set +e; out="$(packet cb-x 7 --gated "$head_sha")"; rc=$?; set -e
[[ $rc -eq 0 ]] || fail "a packet at the gated head exited $rc: $out"
grep -qF "$head_sha" <<<"$out" || fail "the packet does not name the head sha: $out"
grep -qF -- "- scripts/thing" <<<"$out" && grep -qF -- "- tests/thing.sh" <<<"$out" \
  || fail "the packet does not list the changed files: $out"
grep -qxF "+echo hello" <<<"$out" || fail "the packet does not carry the diff: $out"
grep -qxF "> The plan body." <<<"$out" || fail "the packet does not carry the plan, quoted: $out"
grep -qxF "> A thing is printed." <<<"$out" || fail "the packet does not carry the acceptance: $out"
grep -qxF "> Why a thing." <<<"$out" || fail "the packet does not carry the description: $out"
grep -qF '`bash tests/gate` passed at '"$head_sha" <<<"$out" \
  || fail "the packet does not say the gate passed at the head: $out"
grep -qxF "> ## Navigator's answer" <<<"$out" || fail "a heading in the notes was not quoted: $out"
! grep -qx "## Context" <<<"$out" || fail "a heading in the plan passed for one of the packet's own: $out"
pass "a packet at the gated head carries the sha, files, diff, plan, acceptance and gate result"

# --- a gate at another sha is refused ---
reset
set +e; out="$(packet cb-x 7 --gated "0000000000000000000000000000000000000000")"; rc=$?; set -e
[[ $rc -eq 3 ]] || fail "a gate at another sha exited $rc, not 3: $out"
[[ "$(wc -l <<<"$out" | tr -d ' ')" -eq 1 ]] || fail "the refusal is not one line: $out"
grep -qF "$head_sha" <<<"$out" || fail "the refusal does not name the head: $out"
! grep -qF "+echo hello" <<<"$out" || fail "a refused packet still printed the diff: $out"
pass "a gate that ran at another sha is refused with one line (exit 3)"

# --- a push while the packet is made is refused, not labelled with the gated head ---
reset
jq '.headRefOid = "ffffffffffffffffffffffffffffffffffffffff"' "$stub/view.json" > "$stub/view-2.json"
set +e; out="$(packet cb-x 7 --gated "$head_sha")"; rc=$?; set -e
[[ $rc -eq 3 ]] || fail "a head that moved during the packet exited $rc, not 3: $out"
[[ "$(wc -l <<<"$out" | tr -d ' ')" -eq 1 ]] || fail "the moved-head refusal is not one line: $out"
! grep -qF "+echo hello" <<<"$out" || fail "a moved head still printed the diff: $out"
pass "a head that moves while the packet is made is refused (exit 3)"

# --- usage ---
reset
for argv in "" "cb-x" "cb-x 7" "cb-x 7 --gated" "cb-x seven --gated $head_sha" "cb-x 7 --sha $head_sha" \
             "cb-x 7 --gated abc123d"; do
  set +e; out="$(packet $argv 2>&1)"; rc=$?; set -e
  [[ $rc -eq 2 ]] || fail "usage '$argv' exited $rc, not 2: $out"
done
pass "a malformed command line, a short sha included, exits 2"

# --- each read that fails is exit 1, nothing on stdout ---
for var in GH_VIEW_EXIT GH_FILES_EXIT GH_DIFF_EXIT BD_SHOW_EXIT; do
  reset
  export "$var=1"
  set +e; out="$(packet cb-x 7 --gated "$head_sha" 2>/dev/null)"; rc=$?; set -e
  [[ $rc -eq 1 ]] || fail "$var: a failed read exited $rc, not 1"
  [[ -z "$out" ]] || fail "$var: a failed read still printed: $out"
done
reset
printf 'not json' > "$stub/show.json"
set +e; out="$(packet cb-x 7 --gated "$head_sha" 2>/dev/null)"; rc=$?; set -e
[[ $rc -eq 1 && -z "$out" ]] || fail "unreadable bd JSON exited $rc with: $out"
reset
printf '{}' > "$stub/view.json"
set +e; out="$(packet cb-x 7 --gated "$head_sha" 2>/dev/null)"; rc=$?; set -e
[[ $rc -eq 1 && -z "$out" ]] || fail "a PR view with no head exited $rc with: $out"
pass "a failed or unreadable read exits 1 and prints nothing"

# --- a bead with no plan says so ---
reset
jq '.[0].design = null | .[0].issue_type = "bug"' "$stub/show.json" > "$stub/show.tmp" && mv "$stub/show.tmp" "$stub/show.json"
out="$(packet cb-x 7 --gated "$head_sha")"
grep -qF "no plan" <<<"$out" || fail "an empty design printed no explanation: $out"
pass "a bead with no design says it has no plan rather than printing nothing"

# --- a diff carrying a fence is fenced whole ---
reset
printf '+```bash\n+echo x\n+````\n' > "$stub/diff.txt"
out="$(packet cb-x 7 --gated "$head_sha")"
grep -qx '`````diff' <<<"$out" || fail "a diff with a four-backtick run was not fenced by five: $out"
pass "a diff that carries backtick runs is fenced by a longer fence"

# --- the gate command: gate_fast as declared, a detected one said so, none said ---
reset
: > "$consumer/.cerebro/project.conf"
printf 'check:\n\ttrue\n' > "$consumer/Makefile"
out="$(packet cb-x 7 --gated "$head_sha")"
grep -qF '`make check`' <<<"$out" || fail "the detected gate was not named: $out"
grep -qF "detected" <<<"$out" || fail "a detected gate was presented as declared: $out"
reset
grep -qF "detected" <<<"$(packet cb-x 7 --gated "$head_sha")" && fail "a declared gate was called detected"
: > "$consumer/.cerebro/project.conf"
out="$(packet cb-x 7 --gated "$head_sha")"
grep -qF "no fast gate" <<<"$out" || fail "an undeclared gate was not said: $out"
pass "the gate is gate_fast, a detected command is said to be detected, and none is said"

suite_passed
