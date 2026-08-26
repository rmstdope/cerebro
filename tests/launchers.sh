#!/usr/bin/env bash
#
# Proves the fleet's roster and launcher: `scripts/roster` is the one declaration of who is on the
# fleet and `scripts/launch` is the one place - and, since ah-qled.5.3, the only way - a session is
# started. Also proves every launched session stamps its session with a distinct bd actor identity, so
# a second implementer claiming an already-held bead fails instead of silently aliasing into the
# first (see ah-rnz).
#
# Every assertion runs against a fabricated consumer under `mktemp -d`, never the checkout this is
# run from: the suite used to read that machine's uncommitted `.cerebro/models.conf` and write
# symlinks into its `.claude/` (ah-dy4x). Nothing here should ever touch the enclosing tree.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/launchers.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# The fake sessions the duplicate-refusal cases start, killed by the EXIT trap the library
# installs - it calls `suite_cleanup' first, before removing anything, so a failed assertion
# leaves none of them running (`fail' exits, so per-case cleanup would not run). Never a second
# `trap ... EXIT': bash keeps one per signal, and a later one would silently replace the library's.
strays=()

suite_cleanup() {
  local p
  for p in ${strays+"${strays[@]}"}; do kill "$p" 2>/dev/null || true; done
}

# A stub `claude` on PATH ahead of the real one, so a launcher's `exec claude ...` runs this instead
# of starting a real session. It prints the environment and args it was handed, which is exactly what
# these assertions need and nothing a real session would do.
stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"

cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf 'BEADS_ACTOR=%s\n' "${BEADS_ACTOR:-<unset>}"
for a in "$@"; do
  printf 'ARG:%s\n' "$a"
done
STUB
chmod +x "$stub_dir/claude"

# --- the one consumer any assertion ever sees ---------------------------------------------------
#
# Every launcher case used to run `$repo_root/scripts/...` - the real submodule inside the real
# enclosing checkout - so the suite asserted against that machine's uncommitted
# `.cerebro/models.conf`, was red on the navigator's machine and green in CI, and *wrote symlinks
# into their `.claude/`* as a side effect of running (ah-dy4x). A throwaway consumer removes all
# three at once: no models.conf unless a case writes one, no dependence on where the suite is run
# from, and every write lands in a temp directory.
#
# `git init` matters: launch-preflight compares `git rev-parse --show-toplevel` against the consumer
# and skips its checks entirely when they differ, so a fixture that is not a working tree would make
# these cases silently assert nothing.
fixture_dir="$(consumer_new fixture --copy)"
fixture_scripts="$fixture_dir/.claude/cerebro/scripts"
# A consumer that runs implementers must declare a fast gate, or launch-preflight refuses them
# (ah-qled.7.1). The fixture declares one for the same reason a real consumer does: nothing here
# ever runs it - the stub `claude` is what these cases assert against - but without it every
# implementer case below would be refused before reaching the stub.
printf 'gate_fast make check\ngate_full make check-all\n' \
  > "$fixture_dir/.cerebro/project.conf"

run_launcher_at() {
  # Runs a launcher living at an arbitrary scripts directory, with the stub claude first on PATH and
  # never letting a real `claude` be found even if the stub exec somehow failed to intercept it.
  # `consumer-root` resolves from the launcher's own location, so the scripts directory is what
  # decides which consumer is written to - which is why this is the only way a launcher is run here.
  local scripts_dir="$1"
  local name="$2"
  shift 2
  PATH="$stub_dir:$PATH" bash "$scripts_dir/$name" "$@"
}

run_launcher() {
  # Against the fabricated consumer, never the enclosing one. `run_launcher_at` already existed for
  # exactly this (ah-cuc); this makes it the only way in.
  run_launcher_at "$fixture_scripts" "$@"
}

model_of() {
  # $1 = role. Same one-liner as `scripts/launch` — this test is allowed to know the contract.
  awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f && $1=="model:"{print $2; exit}' \
    "$repo_root/agents/$1.md"
}

effort_of() {
  awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f && $1=="effort:"{print $2; exit}' \
    "$repo_root/agents/$1.md"
}

# --- roster ---

# The BUILT-IN table, read from a copy that sits inside no consumer. `$repo_root/scripts/roster`
# stopped being that copy when this checkout mounted itself (cb-i3l.1) and declared a fleet of its
# own (cb-i3l.3): it now answers with cerebro's OWN fleet, which is a fact about this repository
# rather than about the harness it ships. The cases below compare a consumer against the shipped
# table, so they have to hold the shipped table.
builtin_dir="$(mktemp -d)"
cp "$repo_root/scripts/roster" "$builtin_dir/roster"
roster_out="$("$builtin_dir/roster")"
row_count="$(printf '%s\n' "$roster_out" | grep -c .)"
[[ $row_count -ge 2 ]] || fail "roster: expected at least 2 rows, got $row_count"
pass "roster prints at least 2 rows"

while IFS=$'\t' read -r name role kind; do
  [[ -n "$name" && -n "$role" && -n "$kind" ]] || fail "roster: row missing a field: $name/$role/$kind"
  if [[ "$role" == "implementer" ]]; then
    [[ "$kind" == "implementer" ]] || fail "roster: $name has role implementer but kind $kind"
  else
    [[ "$kind" == "interactive" ]] || fail "roster: $name has role $role but kind $kind"
  fi
  [[ -f "$repo_root/agents/$role.md" ]] || fail "roster: agents/$role.md missing for role $role"
done <<<"$roster_out"
pass "roster: every row is NAME/ROLE/KIND, KIND derived correctly, and agents/ROLE.md exists"

names_only="$(printf '%s\n' "$roster_out" | awk -F'\t' '{print $1}')"
[[ "$(printf '%s\n' "$names_only" | sort -u | wc -l | tr -d ' ')" == "$(printf '%s\n' "$names_only" | wc -l | tr -d ' ')" ]] \
  || fail "roster: names are not unique"
pass "roster: names are unique"

first_kind="$(printf '%s\n' "$roster_out" | head -1 | awk -F'\t' '{print $3}')"
last_kind="$(printf '%s\n' "$roster_out" | tail -1 | awk -F'\t' '{print $3}')"
[[ "$first_kind" == "interactive" ]] || fail "roster: first row is not interactive"
[[ "$last_kind" == "implementer" ]] || fail "roster: last row is not implementer"
pass "roster: interactive agents first, implementers last"

implementers_out="$("$builtin_dir/roster" --implementers)"
expected_implementers="$(printf '%s\n' "$roster_out" | awk -F'\t' '$3 == "implementer" {print $1}')"
[[ "$implementers_out" == "$expected_implementers" ]] \
  || fail "roster --implementers: does not match the implementer-kind rows"
while IFS=$'\t' read -r name _ kind; do
  if [[ "$kind" != "implementer" ]]; then
    printf '%s\n' "$implementers_out" | grep -qx "$name" \
      && fail "roster --implementers: contains $name, whose kind is $kind"
  fi
done <<<"$roster_out"
pass "roster --implementers matches the implementer rows and excludes interactive names"

# --role exists for the one question a role with more than one agent raises: which of them is it?
# `plan-bead` asks it to decide which planner runs the triage pass, so that two planning sessions do
# not walk the navigator through the same P4 backlog twice.
role_out="$("$builtin_dir/roster" --role planner)"
expected_planners="$(printf '%s\n' "$roster_out" | awk -F'\t' '$2 == "planner" {print $1}')"
[[ "$role_out" == "$expected_planners" ]] \
  || fail "roster --role planner: got '$role_out', expected '$expected_planners'"
[[ -n "$role_out" ]] || fail "roster --role planner: no planner on the roster"
pass "roster --role planner lists the planners in file order"

[[ -z "$("$builtin_dir/roster" --role nobody)" ]] \
  || fail "roster --role nobody: expected no output"
pass "roster --role of an unheld role prints nothing"

set +e
"$builtin_dir/roster" --role >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster --role with no role: expected exit 2, got $status"
pass "roster --role with no role exits 2"

first_name="$(printf '%s\n' "$roster_out" | head -1 | awk -F'\t' '{print $1}')"
entry_out="$("$builtin_dir/roster" --entry "$first_name")"
[[ "$entry_out" == "$(printf '%s\n' "$roster_out" | head -1)" ]] \
  || fail "roster --entry $first_name: does not match its row"
pass "roster --entry returns the matching row"

set +e
out="$("$builtin_dir/roster" --entry Nobody 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster --entry Nobody: expected exit 2, got $status"
echo "$out" | grep -q "not on the roster" || fail "roster --entry Nobody: wrong message: $out"
pass "roster --entry Nobody exits 2 naming it not on the roster"

set +e
"$builtin_dir/roster" --bogus >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster --bogus: expected exit 2, got $status"
pass "roster --bogus exits 2"

# --- a consumer declares its own fleet (ah-qled.5.1) --------------------------------------------
#
# `scripts/roster` is the one declaration of the fleet, but the X-Men in its `TABLE=` heredoc are
# cerebro's branding rather than any consumer's. A consumer that wants other names, more
# implementers, or a role cerebro does not ship writes them to a *tracked* file of its own -
# `<consumer>/.cerebro/roster.conf` - and roster reads that instead of the built-in table.
#
# Tracked, by a `.gitignore` negation inside the otherwise-ignored `.cerebro/` (cb-epr), beside
# `.cerebro/project.conf`: which agents exist is a fact every clone needs, and an ignored file would
# vanish on a fresh clone with the fleet silently reverting to the X-Men.
roster_consumer="$(consumer_new roster-consumer --copy)"
roster_at="$roster_consumer/.claude/cerebro/scripts/roster"
consumer_roster_file="$roster_consumer/.cerebro/roster.conf"

# With no file of its own, a consumer gets cerebro's own fleet, byte for byte.
[[ "$("$roster_at")" == "$roster_out" ]] \
  || fail "consumer roster: absent file should leave the built-in table alone"
pass "consumer roster: a missing consumer file falls back to the built-in table"

cat > "$consumer_roster_file" <<'ROSTER'
# a consumer's own fleet: comments and blank lines are ignored

Ada           planner
Grace         planner
Hopper        orchestrator

Turing        implementer
Lovelace      implementer
ROSTER

expected_rows="$(printf 'Ada\tplanner\tinteractive\nGrace\tplanner\tinteractive\nHopper\torchestrator\tinteractive\nTuring\timplementer\timplementer\nLovelace\timplementer\timplementer')"
[[ "$("$roster_at")" == "$expected_rows" ]] \
  || fail "consumer roster: expected the consumer's rows in file order, got: $("$roster_at")"
pass "consumer roster: replaces the built-in table, in file order, past comments and blanks"

# It replaces rather than merges: a name from the built-in table must not survive alongside it, or
# file order - which decides which planner triages and which implementer name Cerebro takes next -
# would be nobody's decision.
"$roster_at" | grep -q "Xavier" && fail "consumer roster: the built-in table was merged in, not replaced"
pass "consumer roster: the built-in table is replaced, not merged"

[[ "$("$roster_at" --implementers)" == "$(printf 'Turing\nLovelace')" ]] \
  || fail "consumer roster --implementers: got $("$roster_at" --implementers)"
# The same rule the built-in table is held to, asserted against a fleet that shares no name with
# it: --implementers is exactly the implementer-kind rows and nothing else. This is the assertion
# ah-qled.5.3 exists for - it used to be a grep for the literal name Forge, which says nothing
# about any consumer's fleet.
while IFS=$'\t' read -r c_name _ c_kind; do
  if [[ "$c_kind" != "implementer" ]]; then
    "$roster_at" --implementers | grep -qx "$c_name" \
      && fail "consumer roster --implementers: contains $c_name, whose kind is $c_kind"
  fi
done <<<"$("$roster_at")"
[[ "$("$roster_at" --role planner)" == "$(printf 'Ada\nGrace')" ]] \
  || fail "consumer roster --role planner: got $("$roster_at" --role planner)"
[[ "$("$roster_at" --role planner | sed -n 1p)" == "Ada" ]] \
  || fail "consumer roster --role planner: file order not preserved"
[[ "$("$roster_at" --entry Grace)" == "$(printf 'Grace\tplanner\tinteractive')" ]] \
  || fail "consumer roster --entry Grace: got $("$roster_at" --entry Grace)"
set +e
"$roster_at" --entry Xavier >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "consumer roster --entry Xavier: expected exit 2, got $status"
pass "consumer roster: all four modes read it, and KIND is still derived"

# --- the optional third column: `autostart` (cb-0r6) --------------------------------------------
#
# A roster row may carry a third word, `autostart`, saying the fleet view starts that agent as it
# comes up. Omitted means no, so every roster written before this and the built-in table below are
# unaffected. Any OTHER third word - a typo of this one, most likely - refuses with exit 2 naming
# the file, the line and the word: a typo that read as "no" would be a fleet that quietly does not
# start, which is the failure the navigator chose against.
#
# The word is exposed through `--autostart` alone. The default output stays NAME<TAB>ROLE<TAB>KIND
# because `launch`, `agent-state` and `cerebro--parse-fleet` all assume exactly three fields.
cat > "$consumer_roster_file" <<'ROSTER'
Ada           planner        autostart
Grace         planner        standby
Hopper        reviewer       standby
Turing        implementer    autostart
ROSTER
expected_rows="$(printf 'Ada\tplanner\tinteractive\nGrace\tplanner\tinteractive\nHopper\treviewer\tinteractive\nTuring\timplementer\timplementer')"
[[ "$("$roster_at")" == "$expected_rows" ]] \
  || fail "roster autostart: default output should still be three columns, got: $("$roster_at")"
pass "roster: the autostart column leaves the default three-column output alone"

[[ "$("$roster_at" --autostart)" == "$(printf 'Ada\nTuring')" ]] \
  || fail "roster --autostart: expected Ada and Turing in file order, got: $("$roster_at" --autostart)"
pass "roster --autostart lists the declared names, in file order"

# `standby` is the second third-column word (cb-98u): arm this agent, do not start it. It reads
# through its own mode for the same reason `autostart` does - the default output stays three
# columns - and the two words are mutually exclusive by the fourth-word refusal alone.
[[ "$("$roster_at" --standby)" == "$(printf 'Grace\nHopper')" ]] \
  || fail "roster --standby: expected Grace and Hopper in file order, got: $("$roster_at" --standby)"
pass "roster --standby lists the declared names, in file order"

[[ "$("$roster_at" --implementers)" == "Turing" ]] \
  || fail "roster --implementers with the column: got $("$roster_at" --implementers)"
[[ "$("$roster_at" --entry Ada)" == "$(printf 'Ada\tplanner\tinteractive')" ]] \
  || fail "roster --entry with the column: got $("$roster_at" --entry Ada)"
[[ "$("$roster_at" --role planner)" == "$(printf 'Ada\nGrace')" ]] \
  || fail "roster --role with the column: got $("$roster_at" --role planner)"
pass "roster: the other modes read a row that carries the word"

# The built-in table declares no autostart: a consumer that has not adopted the column sees nothing.
out="$("$builtin_dir/roster" --autostart)"
status=$?
[[ $status -eq 0 ]] || fail "built-in roster --autostart: expected exit 0, got $status"
[[ -z "$out" ]] || fail "built-in roster --autostart: expected nothing, got: $out"
pass "roster --autostart is silent, and exits 0, when no row declares it"

out="$("$builtin_dir/roster" --standby)"
status=$?
[[ $status -eq 0 ]] || fail "built-in roster --standby: expected exit 0, got $status"
[[ -z "$out" ]] || fail "built-in roster --standby: expected nothing, got: $out"
pass "roster --standby is silent, and exits 0, when no row declares it"

# A third word that is not `autostart` refuses - and the refusal is the parser's, so every mode
# refuses, not only the one that reads the column. `exit` inside a `$( )` ends the subshell alone,
# which is what this asserts is propagated.
printf 'Ada  planner  autostrat\n' > "$consumer_roster_file"
for mode in "" "--autostart" "--standby" "--entry Ada" "--implementers"; do
  set +e
  # shellcheck disable=SC2086
  out="$("$roster_at" $mode 2>/dev/null)"
  status=$?
  # shellcheck disable=SC2086
  err="$("$roster_at" $mode 2>&1 >/dev/null)"
  set -e
  [[ $status -eq 2 ]] || fail "roster ${mode:-(bare)} with a bad third word: expected exit 2, got $status"
  [[ -z "$out" ]] || fail "roster ${mode:-(bare)} with a bad third word: expected nothing on stdout, got: $out"
  echo "$err" | grep -q "autostrat" \
    || fail "roster ${mode:-(bare)}: the refusal should name the word, got: $err"
  echo "$err" | grep -q "line 1" \
    || fail "roster ${mode:-(bare)}: the refusal should name the line, got: $err"
  echo "$err" | grep -q "roster.conf" \
    || fail "roster ${mode:-(bare)}: the refusal should name the file, got: $err"
  echo "$err" | grep -q "standby" \
    || fail "roster ${mode:-(bare)}: the refusal should name every accepted word, got: $err"
done
pass "roster: a third word that is neither autostart nor standby refuses, naming the file, line and word"

printf 'Ada  planner  autostart  extra\n' > "$consumer_roster_file"
set +e
out="$("$roster_at" 2>/dev/null)"
status=$?
err="$("$roster_at" 2>&1 >/dev/null)"
set -e
[[ $status -eq 2 ]] || fail "roster with a fourth word: expected exit 2, got $status"
[[ -z "$out" ]] || fail "roster with a fourth word: expected nothing on stdout, got: $out"
echo "$err" | grep -q "one word too many" \
  || fail "roster with a fourth word: expected the 'one word too many' line, got: $err"
pass "roster: a fourth word refuses"

# The two words are mutually exclusive, and need no rule of their own: `autostart standby` on one
# row is a fourth word, which already refuses.
printf 'Ada  planner  autostart  standby\n' > "$consumer_roster_file"
set +e
out="$("$roster_at" 2>/dev/null)"
status=$?
err="$("$roster_at" 2>&1 >/dev/null)"
set -e
[[ $status -eq 2 ]] || fail "roster with both words: expected exit 2, got $status"
[[ -z "$out" ]] || fail "roster with both words: expected nothing on stdout, got: $out"
echo "$err" | grep -q "one word too many" \
  || fail "roster with both words: expected the 'one word too many' line, got: $err"
pass "roster: autostart and standby on one row refuse as a fourth word"

# `standby` on an implementer row is refused until cb-1or gives implementers a wake condition: the
# implementer trigger starts a standby implementer unconditionally, so the word there would be
# `autostart` with a five-second delay and a retry line for a session that never ran. The refusal is
# the parser's, so every mode refuses.
printf 'Ada  planner\nTuring  implementer  standby\n' > "$consumer_roster_file"
for mode in "" "--autostart" "--standby" "--entry Ada" "--implementers"; do
  set +e
  # shellcheck disable=SC2086
  out="$("$roster_at" $mode 2>/dev/null)"
  status=$?
  # shellcheck disable=SC2086
  err="$("$roster_at" $mode 2>&1 >/dev/null)"
  set -e
  [[ $status -eq 2 ]] || fail "roster ${mode:-(bare)} with a standby implementer: expected exit 2, got $status"
  [[ -z "$out" ]] || fail "roster ${mode:-(bare)} with a standby implementer: expected nothing on stdout, got: $out"
  echo "$err" | grep -q "line 2" \
    || fail "roster ${mode:-(bare)}: the refusal should name the line, got: $err"
  echo "$err" | grep -q "standby" \
    || fail "roster ${mode:-(bare)}: the refusal should name the word, got: $err"
  echo "$err" | grep -q "implementer" \
    || fail "roster ${mode:-(bare)}: the refusal should say it is about implementers, got: $err"
done
pass "roster: standby on an implementer row refuses, naming the file, line and word"
rm -f "$consumer_roster_file"

# An empty file says nothing, so the built-in table answers - and so does a file of nothing but
# comments, which has as much to say about the fleet as an absent one. Taking that at its word would
# leave the fleet empty everywhere, with the file looking like a fleet to whoever wrote it.
: > "$consumer_roster_file"
[[ "$("$roster_at")" == "$roster_out" ]] \
  || fail "consumer roster: an empty file should fall back to the built-in table"
printf '# a fleet I have not written yet\n\n' > "$consumer_roster_file"
[[ "$("$roster_at")" == "$roster_out" ]] \
  || fail "consumer roster: a comments-only file should fall back, got: $("$roster_at")"
rm -f "$consumer_roster_file"
pass "consumer roster: an empty or comments-only consumer file falls back to the built-in table"

# The dependency guarantee: `roster` must find the consumer by path arithmetic, never by calling
# `consumer-root`, which shells out to git. tests/launchers.sh already runs a launcher with a PATH
# of `dirname` and `bash` alone; roster has to survive the same.
bare_path_dir="$(mktemp -d)"
ln -s "$(command -v dirname)" "$bare_path_dir/dirname"
ln -s "$(command -v bash)" "$bare_path_dir/bash"
out="$(PATH="$bare_path_dir" "$(command -v bash)" "$roster_at")"
[[ "$out" == "$roster_out" ]] || fail "roster under a narrowed PATH: got: $out"
printf 'Ada  planner\n' > "$consumer_roster_file"
out="$(PATH="$bare_path_dir" "$(command -v bash)" "$roster_at")"
[[ "$out" == "$(printf 'Ada\tplanner\tinteractive')" ]] \
  || fail "roster under a narrowed PATH with a consumer file: got: $out"
rm -f "$consumer_roster_file"
pass "roster reads the consumer file with PATH narrowed to dirname and bash - no git crept in"

# `--autostart` is the same parser and the same builtins, so it survives the narrowed PATH too.
printf 'Ada  planner  autostart\n' > "$consumer_roster_file"
out="$(PATH="$bare_path_dir" "$(command -v bash)" "$roster_at" --autostart)"
[[ "$out" == "Ada" ]] || fail "roster --autostart under a narrowed PATH: got: $out"
rm -f "$consumer_roster_file"
pass "roster --autostart needs nothing but bash"

printf 'Ada  planner  standby\n' > "$consumer_roster_file"
out="$(PATH="$bare_path_dir" "$(command -v bash)" "$roster_at" --standby)"
[[ "$out" == "Ada" ]] || fail "roster --standby under a narrowed PATH: got: $out"
rm -f "$consumer_roster_file"
pass "roster --standby needs nothing but bash"

# --- a roster left at the retired .claude/ path refuses, loudly (cb-epr) ------------------------
#
# The declarations moved to `.cerebro/'. A consumer that bumps the submodule past that move and
# still has its fleet at `.claude/cerebro-roster' must NOT silently fall back to the built-in table:
# absence is the documented "run the X-Men" signal, and a stale path would borrow it - nineteen
# names, most of which the project does not run, with nothing said anywhere.
printf 'Ada  planner\n' > "$roster_consumer/.claude/cerebro-roster"
set +e
out="$("$roster_at" 2>/dev/null)"
status=$?
err="$("$roster_at" 2>&1 >/dev/null)"
set -e
[[ $status -eq 2 ]] || fail "roster at the old path: expected exit 2, got $status"
[[ -z "$out" ]] || fail "roster at the old path: expected nothing on stdout, got: $out"
echo "$err" | grep -q "mv .claude/cerebro-roster .cerebro/roster.conf" \
  || fail "roster at the old path: expected the mv line on stderr, got: $err"
pass "a roster left at the retired .claude/ path refuses instead of falling back"

# And it refuses under the narrowed PATH too - the refusal is `[[ -f ]]' and nothing else, so the
# dirname-and-bash guarantee above survives it.
set +e
PATH="$bare_path_dir" "$(command -v bash)" "$roster_at" >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster at the old path under a narrowed PATH: expected exit 2, got $status"
pass "the old-path refusal needs no external command"

# The new path wins outright when both exist: only the absence of the new one is a migration error.
printf 'Turing  implementer\n' > "$consumer_roster_file"
[[ "$("$roster_at")" == "$(printf 'Turing\timplementer\timplementer')" ]] \
  || fail "roster with both paths: expected the new one to win, got: $("$roster_at")"
rm -f "$roster_consumer/.claude/cerebro-roster" "$consumer_roster_file"
pass "roster: the new path wins when both exist"

# --- a consumer roster at a mount other than .claude/cerebro (ah-ohc2) ---------------------------
#
# `roster' finds a consumer's file by path arithmetic (`../../../.cerebro/roster.conf'), which answers only
# for the standard mount. A consumer that vendors cerebro as a submodule elsewhere gets its own
# roster too, from a SECOND candidate: `<superproject>/.cerebro/roster.conf', tried only when git
# is on PATH and skipped silently when it is not - which is what keeps the narrowed-PATH guarantee
# above true. Candidate order matters: the arithmetic first, so the standard mount never needs git.
alt_consumer="$(consumer_with_submodule alt vendor/cerebro)"
alt_roster_at="$alt_consumer/vendor/cerebro/scripts/roster"

[[ "$("$alt_roster_at")" == "$roster_out" ]] \
  || fail "alternative mount with no consumer file: expected the built-in table"
mkdir -p "$alt_consumer/.cerebro"
printf 'Ada  planner\nTuring  implementer\n' > "$alt_consumer/.cerebro/roster.conf"
[[ "$("$alt_roster_at")" == "$(printf 'Ada\tplanner\tinteractive\nTuring\timplementer\timplementer')" ]] \
  || fail "alternative mount: expected the consumer's roster, got: $("$alt_roster_at")"
pass "roster finds a consumer file from a submodule mounted at vendor/cerebro"

# --- a consumer-only role launches, and a role with no file anywhere is refused by its right name -
mkdir -p "$roster_consumer/.claude/agents"
cat > "$roster_consumer/.claude/agents/archivist.md" <<'AGENT'
---
model: sonnet
---
The consumer's own role, shipped by nobody but this repository.
AGENT
cat > "$consumer_roster_file" <<'ROSTER'
Ada           archivist      autostart
Turing        implementer
ROSTER
out="$(run_launcher_at "$roster_consumer/.claude/cerebro/scripts" launch Ada)"
echo "$out" | grep -A1 '^ARG:--agent$' | grep -q '^ARG:archivist$' \
  || fail "launch Ada (consumer-only role): expected --agent archivist, got: $out"
echo "$out" | grep -A1 '^ARG:--model$' | grep -q '^ARG:sonnet$' \
  || fail "launch Ada (consumer-only role): expected the consumer agent file's model, got: $out"
pass "a consumer-only role resolves its agent file from the consumer and launches"

cat > "$consumer_roster_file" <<'ROSTER'
Ada           archivist
Grace         librarian
ROSTER
set +e
out="$(run_launcher_at "$roster_consumer/.claude/cerebro/scripts" launch Grace 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch Grace (no agent file anywhere): expected exit 2, got $status"
echo "$out" | grep -q "librarian" \
  || fail "launch Grace: the message should name the role, got: $out"
echo "$out" | grep -q "roster.conf" \
  || fail "launch Grace: the message should name the consumer roster as the cause, got: $out"
echo "$out" | grep -q "the submodule is behind" \
  && fail "launch Grace: a consumer-declared role is not a stale submodule, got: $out"
pass "a consumer-declared role with no agent file anywhere is refused by its right cause"
rm -rf "$bare_path_dir"

# --- launch, generically over every roster row ---

while IFS=$'\t' read -r name role kind; do
  out="$(run_launcher launch "$name")"
  echo "$out" | grep -q "^BEADS_ACTOR=${name}\$" || fail "launch $name: expected BEADS_ACTOR=$name, got: $out"
  echo "$out" | grep -A1 '^ARG:--agent$' | grep -q "^ARG:${role}\$" || fail "launch $name: expected --agent $role, got: $out"
  echo "$out" | grep -A1 '^ARG:--name$' | grep -q "^ARG:${name}\$" || fail "launch $name: expected --name $name, got: $out"
  echo "$out" | grep -A1 '^ARG:--remote-control$' | grep -q "^ARG:${name}\$" || fail "launch $name: expected --remote-control $name, got: $out"

  expected_model="$(model_of "$role")"
  if [[ -n "$expected_model" ]]; then
    echo "$out" | grep -A1 '^ARG:--model$' | grep -q "^ARG:${expected_model}\$" \
      || fail "launch $name: expected --model $expected_model, got: $out"
  fi

  expected_effort="$(effort_of "$role")"
  if [[ -n "$expected_effort" ]]; then
    echo "$out" | grep -A1 '^ARG:--effort$' | grep -q "^ARG:${expected_effort}\$" \
      || fail "launch $name: expected --effort $expected_effort, got: $out"
  fi

  echo "$out" | grep -q '^ARG:--permission-mode$' || fail "launch $name: missing --permission-mode"
  echo "$out" | grep -A1 '^ARG:--permission-mode$' | grep -q '^ARG:auto$' || fail "launch $name: expected auto"

  # The consumer root, carried where a wrapper that rewrites --settings (cmux) cannot touch it
  # (ah-ybsr): scripts/agent-alive and cerebro--root-in-args-p both look for a path under this
  # consumer anywhere in the command line, and --settings can no longer be trusted to carry one.
  echo "$out" | grep -q '^ARG:--append-system-prompt$' \
    || fail "launch $name: missing --append-system-prompt, so the fleet view cannot prove the session"
  echo "$out" | grep -A1 '^ARG:--append-system-prompt$' | grep -qF "${fixture_dir%/}/" \
    || fail "launch $name: --append-system-prompt carries no path under the consumer, got: $out"

  # The prompt is the last ARG, and it has one embedded newline, so it prints as the last two
  # lines of output (`tac` is not on macOS by default, so this avoids it).
  prompt="$(echo "$out" | tail -2)"
  echo "$prompt" | grep -q "$name" || fail "launch $name: prompt does not name $name"
  echo "$prompt" | grep -q "$role" || fail "launch $name: prompt does not name $role"
  echo "$prompt" | grep -q "fill the buffer" && fail "launch $name: prompt still has the old per-role drift"
done <<<"$roster_out"
pass "launch: every roster row reaches the stub with the right actor, agent, name, remote-control name, model, effort"

# --- launch overrides ---

# The override model is deliberately not the declared one: the assertion is that the caller's
# --model lands *after* the launcher's and so wins, which says nothing if both are the same word.
out="$(run_launcher launch Xavier --model sonnet)"
before_sonnet="$(echo "$out" | grep -n '^ARG:sonnet$' | head -1 | cut -d: -f1)"
before_declared="$(echo "$out" | grep -n '^ARG:opus$' | head -1 | cut -d: -f1)"
[[ -n "$before_declared" && -n "$before_sonnet" && $before_declared -lt $before_sonnet ]] \
  || fail "launch Xavier --model sonnet: expected opus before sonnet in ARG list, got: $out"
last_arg="$(echo "$out" | tail -1)"
sonnet_line="$(echo "$out" | grep -n '^ARG:sonnet$' | head -1 | cut -d: -f1)"
total_lines="$(echo "$out" | wc -l | tr -d ' ')"
[[ $sonnet_line -lt $total_lines ]] || fail "launch Xavier --model sonnet: sonnet should come before the prompt"
pass "launch Xavier --model sonnet: opus (declared) before sonnet (override) before the prompt"

# --- launch overrides: a caller's own --remote-control comes after the launcher's ---
out="$(run_launcher launch Xavier --remote-control Elsewhere)"
first="$(echo "$out" | grep -n '^ARG:--remote-control$' | head -1 | cut -d: -f1)"
second="$(echo "$out" | grep -n '^ARG:--remote-control$' | tail -1 | cut -d: -f1)"
[[ -n "$first" && -n "$second" && $first -lt $second ]] \
  || fail "launch Xavier --remote-control Elsewhere: expected the launcher's flag before the caller's, got: $out"
echo "$out" | sed -n "$((second+1))p" | grep -q '^ARG:Elsewhere$' \
  || fail "launch Xavier --remote-control Elsewhere: caller's name should follow its flag, got: $out"
pass "launch Xavier --remote-control Elsewhere: launcher's Xavier before the caller's Elsewhere"

# --- launch spelling ---

set +e
out="$(run_launcher launch storm 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch storm: expected exit 2, got $status"
echo "$out" | grep -q "Storm" || fail "launch storm: expected the message to name Storm, got: $out"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "launch storm: should never have reached the stub"
pass "launch storm exits 2, names Storm, never reaches the stub"

set +e
out="$(run_launcher launch Nobody 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch Nobody: expected exit 2, got $status"
echo "$out" | grep -q "not on the roster" || fail "launch Nobody: wrong message, got: $out"
# ...and the roster's own names, so the reader learns what they may type without opening a file.
# This is also the whole answer for a name the fleet has *retired*: a renamed agent gets no courtesy
# redirect, because the roster is the one answer to who exists (ah-qled.5.3).
while IFS=$'\t' read -r roster_name _ _; do
  echo "$out" | grep -qx "$roster_name" \
    || fail "launch Nobody: the refusal should list the roster name $roster_name, got: $out"
done <<<"$roster_out"
echo "$out" | grep -q '^BEADS_ACTOR=' && fail "launch Nobody: should never have reached the stub"
pass "launch Nobody exits 2, names it not on the roster, lists every roster name, never reaches the stub"

set +e
out="$(run_launcher launch 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch (no argument): expected exit 2, got $status"
pass "launch with no argument exits 2"

# --- no launcher shim survives -------------------------------------------------------------------
#
# `launch <Name>` is the only way a session is started. The seven `run-*` shims existed "because the
# docs and the navigator's fingers know them" - and the docs had drifted off them a rename ago
# (CLAUDE.md still named a shim for the architect's retired name, gone since that rename). The fleet
# view has called `launch` directly since ah-qled.5.1, so nothing but a hand-typed command was left.
shim_found="$(find "$repo_root/scripts" -maxdepth 1 -name 'run-*' -print)"
[[ -z "$shim_found" ]] || fail "scripts/: a run-* shim survives: $shim_found"
pass "no run-* launcher shim survives; launch <Name> is the only entry point"

# BEADS_ACTOR through `launch` for an implementer. The generic roster loop above covers every row,
# but this was previously the only place the implementer case was named, and it is the guarantee
# that a second claim on a held bead fails instead of aliasing into the first (ah-rnz).
first_implementer="$("$builtin_dir/roster" --implementers | sed -n 1p)"
[[ -n "$first_implementer" ]] || fail "roster --implementers: the roster names no implementer"
out="$(run_launcher launch "$first_implementer")"
echo "$out" | grep -q "^BEADS_ACTOR=${first_implementer}\$" \
  || fail "launch $first_implementer: expected BEADS_ACTOR=$first_implementer, got: $out"
pass "launch $first_implementer sets BEADS_ACTOR=$first_implementer"

# --- a launcher syncs the consumer repo's links before starting a session (ah-cuc) ---
#
# A consumer of its own, deliberately: this case asserts a link that did *not* exist beforehand, and
# the cases below it write `.cerebro/models.conf`, which the fixture above must never have. Two temp
# directories is the test being honest, not duplication - what had to go is the *enclosing* checkout.
consumer_dir="$(consumer_new own-consumer --copy)"
# A gate, for the same reason the fixture above declares one: the implementer cases below would
# otherwise be refused at launch (ah-qled.7.1).
printf 'gate_fast make check\n' > "$consumer_dir/.cerebro/project.conf"

out="$(run_launcher_at "$consumer_dir/.claude/cerebro/scripts" launch Forge)"
echo "$out" | grep -q '^ARG:--agent$' || fail "launch Forge (consumer): stub was not reached: $out"
[[ -L "$consumer_dir/.claude/agents/architect.md" ]] \
  || fail "launch Forge (consumer): expected .claude/agents/architect.md to be linked"
[[ "$(readlink "$consumer_dir/.claude/agents/architect.md")" == "../cerebro/agents/architect.md" ]] \
  || fail "launch Forge (consumer): expected a relative link to ../cerebro/agents/architect.md"
pass "launch Forge links the consumer's agents before starting the session"

# --- .cerebro/models.conf: switching models without editing an agent definition ---
#
# The config lives in the consumer, not here, so a fabricated consumer is the only place these can
# run. `models_conf` writes one and `launched_flag` reports the value a flag reached the stub with.
models_conf() {
  mkdir -p "$consumer_dir/.cerebro"
  printf '%s\n' "$@" > "$consumer_dir/.cerebro/models.conf"
}
no_models_conf() { rm -f "$consumer_dir/.cerebro/models.conf"; }
launched_flag() {
  # $1 = agent name, $2 = flag (--model/--effort). Prints the value, or nothing if the flag is
  # absent - which is an answer here ("Xavier -" passes no --model), not a failure. `|| true`
  # because the grep in the pipeline exits non-zero on no match and this suite runs under
  # `set -euo pipefail`: without it, asking about an absent flag would kill the run rather than
  # return the empty string the assertion is looking for.
  run_launcher_at "$consumer_dir/.claude/cerebro/scripts" launch "$1" \
    | grep -A1 "^ARG:$2\$" | grep '^ARG:' | grep -v -- "^ARG:$2\$" | head -1 | sed 's/^ARG://' \
    || true
}

no_models_conf
[[ "$(launched_flag Xavier --model)" == "$(model_of planner)" ]] \
  || fail "no models.conf: expected the declared model $(model_of planner)"
pass "no models.conf leaves the agent definition's model alone"

models_conf "default fable"
[[ "$(launched_flag Xavier --model)" == "fable" ]] || fail "models.conf default: expected fable"
[[ "$(launched_flag Xavier --effort)" == "$(effort_of planner)" ]] \
  || fail "models.conf default: a model-only line must leave the declared effort alone"
[[ "$(launched_flag Cyclops --model)" == "fable" ]] \
  || fail "models.conf default: applies to an agent whose definition declares no model"
pass "models.conf: a default line switches every agent's model, keeping declared efforts"

models_conf "# a comment" "" "planner fable low"
[[ "$(launched_flag Xavier --model)" == "fable" ]] || fail "models.conf role: expected fable"
[[ "$(launched_flag Xavier --effort)" == "low" ]] || fail "models.conf role: expected effort low"
[[ "$(launched_flag Forge --model)" == "$(model_of architect)" ]] \
  || fail "models.conf role: a role not named must keep its declared model"
pass "models.conf: a role line switches that role only, model and effort, past comments and blanks"

models_conf "default opus # everything, with a note about why" "planner fable high  # and this role lower"
[[ "$(launched_flag Xavier --model)" == "fable" ]] || fail "models.conf inline comment: expected fable"
[[ "$(launched_flag Xavier --effort)" == "high" ]] \
  || fail "models.conf inline comment: expected effort high, not the comment"
[[ "$(launched_flag Cerebro --model)" == "opus" ]] \
  || fail "models.conf inline comment: a model-only line must not read '#' as its effort"
[[ "$(launched_flag Cerebro --effort)" == "$(effort_of orchestrator)" ]] \
  || fail "models.conf inline comment: expected the declared effort, got the comment"
pass "models.conf: an inline # comment is not the effort column"

models_conf "planner fable" "Beast sonnet"
[[ "$(launched_flag Beast --model)" == "sonnet" ]] || fail "models.conf name: expected sonnet for Beast"
[[ "$(launched_flag Xavier --model)" == "fable" ]] || fail "models.conf name: Xavier keeps the role line"
pass "models.conf: an agent name beats its role, so two planners can differ"

models_conf "Xavier -"
[[ -z "$(launched_flag Xavier --model)" ]] \
  || fail "models.conf '-': expected no --model at all, got $(launched_flag Xavier --model)"
pass "models.conf: '-' passes no --model, leaving the session on claude's own default"

no_models_conf

# --- a sync failure aborts the launch: the stub is never reached ---
# The first run above already symlinked .claude/skills/plan-bead; remove that link before
# replacing it with a real directory, or `mkdir -p` on an existing symlink-to-directory is a
# silent no-op and never creates the blocking condition this assertion needs.
rm -f "$consumer_dir/.claude/skills/plan-bead"
mkdir -p "$consumer_dir/.claude/skills/plan-bead"   # a real directory, not a symlink — the sync refuses
set +e
out="$(run_launcher_at "$consumer_dir/.claude/cerebro/scripts" launch Forge 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "launch Forge (consumer, blocked sync): expected a non-zero exit"
echo "$out" | grep -q "Refusing to link over the directory" \
  || fail "launch Forge (consumer, blocked sync): expected the sync's own refusal message, got: $out"
echo "$out" | grep -q '^ARG:--agent$' \
  && fail "launch Forge (consumer, blocked sync): should never have reached the stub"
pass "a blocked sync aborts the launch before the stub is reached"

# --- claude missing: the launcher refuses with one line naming it, never exec's (ah-bri) ---
# A PATH of only `dirname` - the one external command a launcher needs before it even
# reaches launch-preflight's own `claude` check - so this cannot pass on a machine that
# happens to have `claude` installed under /usr/bin or /bin.
no_claude_dir="$(mktemp -d)"
cleanup_add "$no_claude_dir"
ln -s "$(command -v dirname)" "$no_claude_dir/dirname"
# launch-preflight is exec'd directly (its own `#!/usr/bin/env bash' shebang), so `env'
# needs to find `bash' under this PATH too, not only the shell invoking launch below.
ln -s "$(command -v bash)" "$no_claude_dir/bash"
set +e
out="$(PATH="$no_claude_dir" "$(command -v bash)" "$fixture_scripts/launch" Forge 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch Forge (claude missing): expected exit 2, got $status"
echo "$out" | grep -q "claude is not on PATH" \
  || fail "launch Forge (claude missing): expected the message to name claude is not on PATH, got: $out"
pass "launch Forge refuses with one line when claude is not on PATH"

# --- submodule behind: the role's agent file never arrived, refused before any sync (ah-bri) ---
#
# Its own consumer again: this one has an agent file removed from its copy of the submodule, so it
# cannot share a consumer with anything that expects a complete one.
consumer_dir2="$(consumer_new behind-consumer --copy)"
rm -f "$consumer_dir2/.claude/cerebro/agents/architect.md"
set +e
out="$(run_launcher_at "$consumer_dir2/.claude/cerebro/scripts" launch Forge 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "launch Forge (submodule behind): expected exit 2, got $status"
echo "$out" | grep -q "the submodule is behind" \
  || fail "launch Forge (submodule behind): expected the message to name the submodule as behind, got: $out"
[[ ! -L "$consumer_dir2/.claude/agents/architect.md" ]] \
  || fail "launch Forge (submodule behind): the sync should not have run before this check"
echo "$out" | grep -q '^ARG:--agent$' \
  && fail "launch Forge (submodule behind): should never have reached the stub"
pass "launch Forge refuses when the submodule never brought its agent file in"

# --- the reviewer role: on the roster, with phases agent-state accepts ---
reviewer_name="$("$builtin_dir/roster" --role reviewer | sed -n 1p)"
[[ -n "$reviewer_name" ]] || fail "roster --role reviewer: the roster names no reviewer"
entry_out="$("$builtin_dir/roster" --entry "$reviewer_name")"
IFS=$'\t' read -r entry_name entry_role entry_kind <<<"$entry_out"
[[ "$entry_name" == "$reviewer_name" ]] \
  || fail "roster --entry $reviewer_name: first field is $entry_name"
[[ "$entry_role" == "reviewer" ]] \
  || fail "roster --entry $reviewer_name: second field is $entry_role, expected reviewer"
[[ "$entry_kind" == "interactive" ]] \
  || fail "roster --entry $reviewer_name: third field is $entry_kind, expected interactive"
[[ -f "$repo_root/agents/reviewer.md" ]] || fail "agents/reviewer.md does not exist"
[[ -n "$(model_of reviewer)" ]] || fail "agents/reviewer.md: declares no model:"
pass "the roster's reviewer resolves to a reviewer/interactive row, with an agent file declaring a model"

# --- agents/architect.md exists with the right frontmatter ---
[[ -f "$repo_root/agents/architect.md" ]] || fail "agents/architect.md does not exist"
[[ -n "$(model_of architect)" ]] || fail "agents/architect.md: declares no model:"
[[ -n "$(effort_of architect)" ]] || fail "agents/architect.md: declares no effort:"
pass "agents/architect.md exists and declares both a model and an effort"

# --- a consumer roster in cerebro's own checkout, mounted in itself (cb-i3l.3) ---------------------
#
# The path arithmetic (`../../../.cerebro/roster.conf') answers for a consumer with a submodule under
# `.claude'. It cannot answer for cerebro serving ITSELF: `.claude/cerebro' is a symlink back to the
# checkout, so the kernel resolves `.claude/cerebro/scripts/../..' to the directory ABOVE the
# repository, and roster looked for a file beside somebody's clone of it. The consumer file was
# then ignored in silence and the built-in table used instead - which looks exactly like a working
# fleet until a name that is not on it fails to launch.
#
# A third candidate, tried after the arithmetic and before git, checks the same round trip through
# the mount that `consumer-root' does. No external command, so the narrowed-PATH guarantee holds.
self_cerebro="$(mktemp -d)/cerebro"
mkdir -p "$self_cerebro/.claude" "$self_cerebro/.cerebro"
copy_cerebro_into "$self_cerebro"
ln -s ".." "$self_cerebro/.claude/cerebro"
self_roster_at="$self_cerebro/.claude/cerebro/scripts/roster"

[[ "$("$self_roster_at")" == "$roster_out" ]] \
  || fail "self-consumer with no roster file: expected the built-in table"
pass "self-consumer roster: a missing file falls back to the built-in table"

cat > "$self_cerebro/.cerebro/roster.conf" <<'ROSTER'
# the fleet this checkout runs
Ada           planner
Hopper        orchestrator

Turing        implementer
ROSTER

self_rows="$("$self_roster_at")"
[[ "$self_rows" == "$(printf 'Ada\tplanner\tinteractive\nHopper\torchestrator\tinteractive\nTuring\timplementer\timplementer')" ]] \
  || fail "self-consumer roster: expected the declared fleet, got: $self_rows"
pass "self-consumer roster: the checkout's own file replaces the built-in table"

[[ "$("$self_roster_at" --implementers)" == "Turing" ]] \
  || fail "self-consumer roster: --implementers should read the consumer file too"
pass "self-consumer roster: every mode reads the same declaration"

# The self-consumer candidate refuses the old path for the same reason (cb-epr): this repository is
# a consumer of itself, so it is the one that would notice the move last.
rm -f "$self_cerebro/.cerebro/roster.conf"
printf 'Ada  planner\n' > "$self_cerebro/.claude/cerebro-roster"
set +e
"$self_roster_at" >/dev/null 2>&1
status=$?
err="$("$self_roster_at" 2>&1 >/dev/null)"
set -e
[[ $status -eq 2 ]] || fail "self-consumer roster at the old path: expected exit 2, got $status"
echo "$err" | grep -q "mv .claude/cerebro-roster .cerebro/roster.conf" \
  || fail "self-consumer roster at the old path: expected the mv line, got: $err"
pass "self-consumer roster: the retired .claude/ path refuses too"

# --- launch refuses a name whose session is already up in this fleet (cb-63m) ---
#
# Two sessions of one name is the one thing the fleet view cannot see: the newer one overwrites the
# state file with its own pid and the older disappears from every reading. Only the view's `s'
# refused a second session, and only for a name it could already see - the terminal was the way
# round it. The refusal belongs where the name is known, which is here.
#
# The fake session is the recipe tests/agent-alive.sh uses: a script file (never `bash -c', whose
# implicit exec would drop `--name' from the args) carrying the `--settings' path that proves which
# consumer's fleet it belongs to.
# `sed -n 1p' rather than `head -n 1': head closes the pipe on its first line, and under
# `set -o pipefail' roster's EPIPE would kill this suite rather than name an implementer.
dup_name="$("$fixture_scripts/roster" --implementers | sed -n 1p)"
[[ -n "$dup_name" ]] || fail "duplicate-launch: the fixture roster names no implementer"

printf '#!/usr/bin/env bash\nsleep 30\n' > "$fixture_dir/fake-session"
chmod +x "$fixture_dir/fake-session"
# agent-alive resolves the --settings directory physically, so hooks/ must exist.
mkdir -p "$fixture_dir/.claude/cerebro/hooks"
bash "$fixture_dir/fake-session" --name "$dup_name" \
  --settings "$fixture_dir/.claude/cerebro/scripts/../hooks/question-state.settings.json" &
dup_pid=$!
# The `sleep' is a child of that bash rather than the bash itself; both are registered, or the
# child outlives a kill of the wrapper for the rest of its thirty seconds.
strays+=("$dup_pid")
for child in $(pgrep -P "$dup_pid" 2>/dev/null || true); do strays+=("$child"); done

mkdir -p "$fixture_dir/.cerebro/state"
printf '{"state":"working","pid":%s}\n' "$dup_pid" \
  > "$fixture_dir/.cerebro/state/$dup_name.state.json"

set +e
dup_out="$(run_launcher launch "$dup_name" 2>&1)"
dup_status=$?
set -e
[[ $dup_status -eq 2 ]] || fail "duplicate-launch: expected exit 2, got $dup_status: $dup_out"
echo "$dup_out" | grep -q "is already running in this fleet (pid $dup_pid); end it first" \
  || fail "duplicate-launch: expected the refusal naming the pid, got: $dup_out"
echo "$dup_out" | grep -q '^ARG:' \
  && fail "duplicate-launch: the stub claude ran anyway: $dup_out"
pass "launch refuses a name whose session is already up in this fleet"

# --- and the refusal is agent-alive's rule, not a bare pid check ---
#
# $$ is this suite: a live pid whose args carry no `--name'. A launcher that only asked whether the
# pid existed would refuse here too, and every state file left behind by a killed session would
# make its name unlaunchable.
printf '{"state":"working","pid":%s}\n' "$$" \
  > "$fixture_dir/.cerebro/state/$dup_name.state.json"
live_out="$(run_launcher launch "$dup_name")"
echo "$live_out" | grep -q '^ARG:--name$' \
  || fail "recycled-pid launch: expected a normal launch, got: $live_out"
pass "launch is not fooled by a live pid that is not that name's session"

rm -f "$fixture_dir/.cerebro/state/$dup_name.state.json"

echo "all launcher tests passed"
