#!/usr/bin/env bash
#
# Proves `scripts/ux-brief <Name> <id> --pid <pid>` (cb-9tnf): the UX session's startup, done once
# by `launch` before the session exists. It pulls the board, checks the bead is still the agent's,
# writes the working state and prints one brief; a read that fails says so in the brief and never
# reads as an empty answer, and an advisory step never decides the exit status.
#
#     bash tests/ux-brief.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link ux-brief agent-state roster consumer-root project-conf)"
printf 'Beast ux\nIceman ux\nRogue producer\n' > "$consumer/.cerebro/roster.conf"
state="$consumer/.cerebro/state"
stub="$work_dir/stub"
mkdir -p "$stub"

# A stub `bd`: one argv line per call in bd.log; `show <id>` answered from show-<id>.json, `children`
# from children.json, and `dolt`/`show`/`children` failures from the environment.
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
args=()
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -C|--actor) skip=1 ;; *) args+=("$a") ;; esac
done
case "${args[0]}" in
  dolt)     exit "${BD_PULL_EXIT:-0}" ;;
  show)     [ "${BD_SHOW_EXIT:-0}" = 0 ] || exit "$BD_SHOW_EXIT"
            cat "$STUB_DIR/show-${args[1]}.json" ;;
  children) [ "${BD_CHILDREN_EXIT:-0}" = 0 ] || exit "$BD_CHILDREN_EXIT"
            cat "$STUB_DIR/children.json" ;;
esac
exit 0
STUB
chmod +x "$stub/bd"
export STUB_DIR="$stub"
export PATH="$stub:$PATH"

bead_json() {  # <id> <status> <assignee> [parent]
  jq -n --arg id "$1" --arg st "$2" --arg as "$3" --arg parent "${4:-}" '[{
    id: $id, title: "Show the phone link", status: $st, assignee: $as, priority: 2,
    labels: ["needs-ui-decision", "feature"],
    description: "Today a drawing opens only on the computer.",
    acceptance_criteria: "A drawing opens on a phone.",
    notes: "## Sent back to the UX stage\nWhat closes it?"
  } + (if $parent == "" then {} else {parent: $parent} end)]'
}

reset() {
  rm -f "$stub/bd.log" "$state"/*.state.json "$stub"/show-*.json "$stub/children.json"
  rm -rf "$consumer/docs"
  : > "$consumer/.cerebro/project.conf"
  bead_json cb-a open Beast cb-epic > "$stub/show-cb-a.json"
  jq -n '[{id: "cb-epic", title: "Drawings everywhere", status: "open",
           description: "Every drawing a designer is shown can be opened anywhere."}]' \
    > "$stub/show-cb-epic.json"
  jq -n '[{id: "cb-a", title: "Show the phone link", status: "open"},
          {id: "cb-b", title: "Stack the sketches", status: "closed"}]' > "$stub/children.json"
}

run_brief() { (cd "$consumer" && .cerebro/cerebro/scripts/ux-brief "$@"); }

# --- the bead is the agent's ---------------------------------------------------------------------

reset
printf 'project_name Retro\naudience_noun facilitator\napp_paths ^src/\n' > "$consumer/.cerebro/project.conf"
mkdir -p "$consumer/docs/ui"
for f in old gone new; do
  echo "$f" > "$consumer/docs/ui/cb-$f.html"
  git_q -C "$consumer" add docs/ui
  git_q -C "$consumer" commit -q -m "$f"
done
git_q -C "$consumer" rm -q docs/ui/cb-gone.html
git_q -C "$consumer" commit -q -m "drop gone"

out="$(run_brief Beast cb-a --pid 4242)" || fail "ux-brief: the agent's own bead exits 0"
for want in "## Startup brief" "cb-a" "Show the phone link" "Today a drawing opens only on the computer." \
            "A drawing opens on a phone." "What closes it?" "needs-ui-decision" "Drawings everywhere" \
            "Every drawing a designer is shown can be opened anywhere." "cb-b" "Stack the sketches" \
            "project_name Retro" "audience_noun facilitator" "ux_sketches on" "app_paths ^src/" \
            ".cerebro/cerebro/templates/ux-sketch-sheet.html"; do
  grep -qF -- "$want" <<<"$out" || fail "ux-brief: the brief carries '$want', got: $out"
done
grep -qF -- "- cb-a " <<<"$out" && fail "ux-brief: the bead itself is not listed among its siblings, got: $out"
grep -qF "cb-gone.html" <<<"$out" && fail "ux-brief: a drawing no longer on disk is not listed, got: $out"
new_line="$(grep -n "docs/ui/cb-new.html" <<<"$out" | cut -d: -f1)"
old_line="$(grep -n "docs/ui/cb-old.html" <<<"$out" | cut -d: -f1)"
[[ -n "$new_line" && -n "$old_line" && $new_line -lt $old_line ]] \
  || fail "ux-brief: the drawings are listed newest first, got: $out"
pass "the agent's own bead prints the bead, its family, the project keys, the drawings and the template"

state_json="$(cat "$state/Beast.state.json")" || fail "ux-brief: the state file is written"
[[ "$(jq -r '"\(.state) \(.bead) \(.phase) \(.pid)"' <<<"$state_json")" == "working cb-a ux 4242" ]] \
  || fail "ux-brief: the state is working on the bead in phase ux with the given pid, got: $state_json"
pull_line="$(grep -m1 -n "dolt pull" "$stub/bd.log" | cut -d: -f1)"
show_line="$(grep -m1 -n "show cb-a" "$stub/bd.log" | cut -d: -f1)"
[[ -n "$pull_line" && -n "$show_line" && $pull_line -lt $show_line ]] \
  || fail "ux-brief: the board is pulled before the bead is read, got: $(cat "$stub/bd.log")"
pass "the agent's own bead writes working, phase ux, after pulling the board"

# --- not the agent's -----------------------------------------------------------------------------

for case_ in "open Iceman" "in_progress Beast" "open "; do
  reset
  read -r st as <<<"$case_ x"
  [[ "$as" == x ]] && as=""
  bead_json cb-a "$st" "$as" > "$stub/show-cb-a.json"
  status=0
  out="$(run_brief Beast cb-a --pid 4242)" || status=$?
  [[ $status -eq 3 ]] || fail "ux-brief: a bead that is $st/${as:-nobody} is exit 3, got $status"
  [[ "$(grep -c . <<<"$out")" -eq 1 ]] || fail "ux-brief: a bead not the agent's prints one line, got: $out"
  grep -qF "cb-a" <<<"$out" || fail "ux-brief: the one line names the bead, got: $out"
  [[ ! -e "$state/Beast.state.json" ]] || fail "ux-brief: a bead not the agent's writes no state"
done
pass "a bead that is not the agent's is exit 3, one line, and no state"

# --- bd fails --------------------------------------------------------------------------------------

reset
status=0
out="$(BD_SHOW_EXIT=1 run_brief Beast cb-a --pid 4242 2>/dev/null)" || status=$?
[[ $status -eq 1 ]] || fail "ux-brief: a failed bd show is exit 1, got $status"
[[ -z "$out" ]] || fail "ux-brief: a failed bd show prints nothing on stdout, got: $out"
[[ ! -e "$state/Beast.state.json" ]] || fail "ux-brief: a failed bd show writes no state"

reset
echo 'not json' > "$stub/show-cb-a.json"
status=0
out="$(run_brief Beast cb-a --pid 4242 2>/dev/null)" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "ux-brief: unreadable JSON is exit 1 with nothing printed, got $status: $out"
pass "a bd show that fails or prints no JSON is exit 1, nothing printed, no state"

reset
out="$(BD_PULL_EXIT=1 run_brief Beast cb-a --pid 4242 2>/dev/null)" \
  || fail "ux-brief: a failed pull does not decide the exit status"
grep -qi "pull failed" <<<"$out" || fail "ux-brief: a failed pull is said in the brief, got: $out"
[[ -e "$state/Beast.state.json" ]] || fail "ux-brief: a failed pull still writes the state"
pass "a failed board pull is said in the brief and is still exit 0"

# --- the family and the drawings, degraded -------------------------------------------------------

reset
bead_json cb-a open Beast > "$stub/show-cb-a.json"
out="$(run_brief Beast cb-a --pid 4242)" || fail "ux-brief: a bead with no parent exits 0"
grep -qi "no parent" <<<"$out" || fail "ux-brief: a bead with no parent says so, got: $out"
grep -q "children" "$stub/bd.log" && fail "ux-brief: a bead with no parent reads no children"
grep -qi "none yet" <<<"$out" || fail "ux-brief: no docs/ui says none yet, got: $out"
pass "no parent and no drawings are each said, not left blank"

reset
out="$(BD_CHILDREN_EXIT=1 run_brief Beast cb-a --pid 4242 2>/dev/null)" \
  || fail "ux-brief: a failed family read does not decide the exit status"
grep -qi "could not read" <<<"$out" || fail "ux-brief: a failed family read says so, got: $out"
pass "a failed family read is said in the brief and is still exit 0"

reset
printf 'ux_sketches off\n' > "$consumer/.cerebro/project.conf"
out="$(run_brief Beast cb-a --pid 4242)" || fail "ux-brief: sketches off exits 0"
grep -qF "ux_sketches off" <<<"$out" || fail "ux-brief: ux_sketches off is printed off, got: $out"
printf 'ux_sketches maybe\n' > "$consumer/.cerebro/project.conf"
out="$(run_brief Beast cb-a --pid 4242)" || fail "ux-brief: sketches maybe exits 0"
grep -qF "ux_sketches off" <<<"$out" || fail "ux-brief: anything but on is printed off, got: $out"
pass "ux_sketches is on when absent and off for anything but on"

# --- usage ---------------------------------------------------------------------------------------

for argv in "" "Beast" "Beast cb-a" "Beast cb-a --pid" "Beast cb-a --pid x1"; do
  status=0
  # shellcheck disable=SC2086
  run_brief $argv >/dev/null 2>&1 || status=$?
  [[ $status -eq 2 ]] || fail "ux-brief: usage '$argv' is exit 2, got $status"
done
pass "a missing name, bead or pid is usage, exit 2"

suite_passed
