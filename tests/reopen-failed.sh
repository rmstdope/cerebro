#!/usr/bin/env bash
#
# Proves `scripts/reopen-failed`: the one place a failed verification reopens a bead. The procedure
# it replaces was six `bd` commands an agent retyped out of `agents/verifier.md`, and the step that
# got dropped - `bd update <id> --assignee ""` - stranded a P0 three times, once for ten hours.
#
# The load-bearing case is `reopens-unassigns-and-records`, and specifically its assertion that
# `--assignee` is followed by an EMPTY argument: an implementation that forgot the clear would pass
# every other assertion in this file.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/reopen-failed.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"

# The script resolves its root with `consumer-root --shared`, which answers only when this copy of
# cerebro is mounted at <consumer>/.claude/cerebro - so every case runs it from a throwaway consumer.
consumer="$(consumer_new repo --link reopen-failed consumer-root)"
git_q -C "$consumer" commit -q --allow-empty -m "init"

# The dispatching stub from tests/plan-candidates.sh:39-63, with ONE addition: `show` consumes
# stdout.show.1, then stdout.show.2, ... in order, falling back to stdout.show once the numbered
# files run out. Without it the parent walk reads the same bead's JSON for ever and this suite hangs
# rather than fails.
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
# One shared, ordered log as well: argv.<sub> cannot show that `reopen' preceded the assignee
# clear, and that ordering is load-bearing.
printf 'CALL:%s\n' "$sub" >> "$stub_dir/argv.all"
for a in "$@"; do printf 'ARG:%s\n' "$a" >> "$stub_dir/argv.all"; done
show_n=""
if [ "$sub" = "show" ]; then
  show_n=1
  [ -f "$stub_dir/show.n" ] && show_n="$(cat "$stub_dir/show.n")"
  if [ -f "$stub_dir/stdout.show.$show_n" ]; then
    cat "$stub_dir/stdout.show.$show_n"
  elif [ -f "$stub_dir/stdout.show" ]; then
    cat "$stub_dir/stdout.show"
  fi
  # UNCONDITIONALLY, not only when a numbered stdout was found: a case that numbers an exit without
  # numbering the stdout would otherwise leave the counter at 1 and apply that exit to every `show'
  # call - the whole-run behaviour this numbering exists to remove.
  echo $((show_n + 1)) > "$stub_dir/show.n"
elif [ -f "$stub_dir/stdout.$sub" ]; then
  cat "$stub_dir/stdout.$sub"
fi
# A NUMBERED exit for `show', alongside its numbered stdout: without it, a case that wants only the
# PARENT's show to fail fails the bead's own show too, the first-show guard exits before the parent
# walk is reached, and the case passes against the defect it was written to catch.
if [ -n "$show_n" ] && [ -f "$stub_dir/exit.show.$show_n" ]; then
  exit "$(cat "$stub_dir/exit.show.$show_n")"
fi
if [ -f "$stub_dir/exit.$sub" ]; then exit "$(cat "$stub_dir/exit.$sub")"; fi
exit 0
STUB
sed -i.bak "s|STUB_DIR|$stub_dir|" "$stub_dir/bd" && rm -f "$stub_dir/bd.bak"
chmod +x "$stub_dir/bd"

reset_stub() {
  rm -f "$stub_dir"/argv.* "$stub_dir"/stdout.* "$stub_dir"/exit.* "$stub_dir/show.n"
}

set_show() {
  # set_show <json> [<json> ...] - one per successive `bd show` call
  local n=1 j
  for j in "$@"; do
    printf '%s' "$j" > "$stub_dir/stdout.show.$n"
    n=$((n + 1))
  done
}

run() {
  set +e
  out="$(PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/reopen-failed" "$@" 2>"$stub_dir/err")"
  status=$?
  set -e
  err="$(cat "$stub_dir/err")"
}

sha40="0123456789abcdef0123456789abcdef01234567"

argv_has() {
  # argv_has <subcommand> <arg>
  [ -f "$stub_dir/argv.$1" ] && grep -qxF "ARG:$2" "$stub_dir/argv.$1"
}

argv_has_pair() {
  # argv_has_pair <subcommand> <flag> <value> - the line after the flag
  local f="$stub_dir/argv.$1"
  [ -f "$f" ] || return 1
  grep -xF -A1 "ARG:$2" "$f" | grep -qxF "ARG:$3"
}

# --- refuses-a-missing-fault --------------------------------------------------------------------
#
# The label flip was the second step an agent could silently skip, so the flag that carries it is
# required. Nothing may reach `bd` on a refusal.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --notes "the panel was empty"
[ "$status" -eq 2 ] || fail "refuses-a-missing-fault: expected exit 2, got $status"
grep -q -- '--fault' <<<"$err" || fail "refuses-a-missing-fault: stderr does not name --fault: $err"
[ ! -f "$stub_dir/argv.update" ] || fail "refuses-a-missing-fault: a bd update was made anyway"
pass "refuses-a-missing-fault"

# --- refuses-an-unknown-argument ----------------------------------------------------------------
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault build --dry-run
[ "$status" -eq 2 ] || fail "refuses-an-unknown-argument: expected exit 2, got $status"
grep -q -- '--dry-run' <<<"$err" || fail "refuses-an-unknown-argument: stderr does not name it: $err"
[ ! -f "$stub_dir/argv.update" ] || fail "refuses-an-unknown-argument: a bd update was made anyway"
pass "refuses-an-unknown-argument"

# --- refuses-a-missing-sha ----------------------------------------------------------------------
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --notes "n" --fault build
[ "$status" -eq 2 ] || fail "refuses-a-missing-sha: expected exit 2, got $status"
grep -q -- '--sha' <<<"$err" || fail "refuses-a-missing-sha: stderr does not name --sha: $err"
[ ! -f "$stub_dir/argv.update" ] || fail "refuses-a-missing-sha: a bd update was made anyway"
pass "refuses-a-missing-sha"

# --- refuses-a-short-sha ------------------------------------------------------------------------
#
# `verified_at` must be a commit `git cat-file -e` can resolve - scripts/sweep-verdicts.sh is what
# reads it back.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha 0123456 --notes "n" --fault build
[ "$status" -eq 2 ] || fail "refuses-a-short-sha: expected exit 2, got $status"
grep -q -- '--sha' <<<"$err" || fail "refuses-a-short-sha: stderr does not name --sha: $err"
[ ! -f "$stub_dir/argv.update" ] || fail "refuses-a-short-sha: a bd update was made anyway"
pass "refuses-a-short-sha"

# --- refuses-a-missing-notes --------------------------------------------------------------------
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --fault build
[ "$status" -eq 2 ] || fail "refuses-a-missing-notes: expected exit 2, got $status"
grep -q -- '--notes' <<<"$err" || fail "refuses-a-missing-notes: stderr does not name --notes: $err"
[ ! -f "$stub_dir/argv.update" ] || fail "refuses-a-missing-notes: a bd update was made anyway"
pass "refuses-a-missing-notes"

# --- refuses-an-unknown-fault -------------------------------------------------------------------
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault maybe
[ "$status" -eq 2 ] || fail "refuses-an-unknown-fault: expected exit 2, got $status"
grep -q -- '--fault' <<<"$err" || fail "refuses-an-unknown-fault: stderr does not name --fault: $err"
[ ! -f "$stub_dir/argv.update" ] || fail "refuses-an-unknown-fault: a bd update was made anyway"
pass "refuses-an-unknown-fault"

# --- refuses-a-bead-bd-does-not-know ------------------------------------------------------------
#
# A typo must not half-reopen something.
reset_stub
set_show ''
run tt-nope --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 2 ] || fail "refuses-a-bead-bd-does-not-know: expected exit 2, got $status"
grep -qi 'no such bead' <<<"$err" \
  || fail "refuses-a-bead-bd-does-not-know: stderr does not say so: $err"
[ ! -f "$stub_dir/argv.update" ] || fail "refuses-a-bead-bd-does-not-know: a bd update was made"
[ ! -f "$stub_dir/argv.reopen" ] || fail "refuses-a-bead-bd-does-not-know: a bd reopen was made"
pass "refuses-a-bead-bd-does-not-know"

# --- reopens-unassigns-and-records --------------------------------------------------------------
#
# THE LOAD-BEARING CASE. All six unconditional calls, with their exact arguments, in the order
# `agents/verifier.md` had them - and `--assignee` followed by an EMPTY argument, which is the
# assertion this whole bead exists to buy.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --notes "the panel was empty" --fault build
[ "$status" -eq 0 ] || fail "reopens-unassigns-and-records: expected exit 0, got $status ($err)"
argv_has_pair reopen tt-a --reason \
  || fail "reopens-unassigns-and-records: no bd reopen for the bead"
argv_has_pair reopen --reason "the panel was empty" \
  || fail "reopens-unassigns-and-records: --reason did not default to the first line of --notes"
grep -xF -A1 "ARG:--assignee" "$stub_dir/argv.update" | grep -qxF "ARG:" \
  || fail "reopens-unassigns-and-records: --assignee was not followed by an empty argument"
argv_has update "--priority=0" \
  || fail "reopens-unassigns-and-records: the bead was not set to P0"
grep -qxF -- "ARG:--append-notes" "$stub_dir/argv.update" \
  || fail "reopens-unassigns-and-records: no failure note appended"
grep -F "ARG:Verification failed (" "$stub_dir/argv.update" | grep -q "the panel was empty" \
  || fail "reopens-unassigns-and-records: the note does not carry the navigator's words"
grep -F "ARG:Verification failed (" "$stub_dir/argv.update" | grep -q "at 01234567" \
  || fail "reopens-unassigns-and-records: the note does not carry the short sha"
argv_has "set-state" "verification=failed" \
  || fail "reopens-unassigns-and-records: verification=failed was not set"
argv_has update "--set-metadata" \
  || fail "reopens-unassigns-and-records: no --set-metadata"
argv_has update "verified_at=$sha40" \
  || fail "reopens-unassigns-and-records: verified_at was not the full sha"
argv_has_pair update --remove-label "verdict:stale" \
  || fail "reopens-unassigns-and-records: verdict:stale was not removed"
# The order: reopen, then the assignee clear, then the rest.
[ "$(grep -c 'ARG:--assignee' "$stub_dir/argv.update")" -ge 1 ] \
  || fail "reopens-unassigns-and-records: no assignee clear at all"
[ "$(grep -n 'ARG:--assignee' "$stub_dir/argv.update" | head -1 | cut -d: -f1)" \
  -lt "$(grep -n 'ARG:--priority=0' "$stub_dir/argv.update" | head -1 | cut -d: -f1)" ] \
  || fail "reopens-unassigns-and-records: the assignee clear did not come before the P0"
# And across subcommands: `bd reopen' must precede the assignee clear, because the clear is refused
# while the bead is still `in_progress' and held by somebody else. argv.<sub> cannot see this.
[ "$(grep -n 'CALL:reopen' "$stub_dir/argv.all" | head -1 | cut -d: -f1)" \
  -lt "$(grep -n 'ARG:--assignee' "$stub_dir/argv.all" | head -1 | cut -d: -f1)" ] \
  || fail "reopens-unassigns-and-records: the reopen did not precede the assignee clear"
pass "reopens-unassigns-and-records"

# --- does-not-reopen-an-already-open-bead -------------------------------------------------------
#
# The status guard is what makes the script re-runnable after a half-finished run.
reset_stub
set_show '[{"id":"tt-a","status":"open","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 0 ] || fail "does-not-reopen-an-already-open-bead: expected exit 0, got $status ($err)"
[ ! -f "$stub_dir/argv.reopen" ] \
  || fail "does-not-reopen-an-already-open-bead: an open bead was reopened anyway"
grep -qxF "ARG:--assignee" "$stub_dir/argv.update" \
  || fail "does-not-reopen-an-already-open-bead: the assignee clear was skipped with the reopen"
pass "does-not-reopen-an-already-open-bead"

# --- plan-fault-flips-the-labels ----------------------------------------------------------------
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault plan
[ "$status" -eq 0 ] || fail "plan-fault-flips-the-labels: expected exit 0, got $status ($err)"
argv_has_pair update --remove-label planned \
  || fail "plan-fault-flips-the-labels: planned was not removed"
argv_has_pair update --add-label "plan:revise" \
  || fail "plan-fault-flips-the-labels: plan:revise was not added"
pass "plan-fault-flips-the-labels"

# --- build-fault-touches-neither-label ----------------------------------------------------------
#
# The case that stops a sound plan being sent back for a rewrite.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 0 ] || fail "build-fault-touches-neither-label: expected exit 0, got $status ($err)"
grep -qxF "ARG:plan:revise" "$stub_dir/argv.update" \
  && fail "build-fault-touches-neither-label: plan:revise was added on the build branch"
grep -xF -A1 "ARG:--remove-label" "$stub_dir/argv.update" | grep -qxF "ARG:planned" \
  && fail "build-fault-touches-neither-label: planned was removed on the build branch"
pass "build-fault-touches-neither-label"

# --- reopens-a-closed-parent-chain --------------------------------------------------------------
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":"tt-p"}]' \
         '[{"id":"tt-p","status":"closed","parent":"tt-g"}]' \
         '[{"id":"tt-g","status":"open","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 0 ] || fail "reopens-a-closed-parent-chain: expected exit 0, got $status ($err)"
argv_has reopen tt-a || fail "reopens-a-closed-parent-chain: the child was not reopened"
argv_has reopen tt-p || fail "reopens-a-closed-parent-chain: the closed parent was not reopened"
argv_has reopen tt-g \
  && fail "reopens-a-closed-parent-chain: the OPEN grandparent was reopened"
argv_has update tt-p || fail "reopens-a-closed-parent-chain: no bd update for the parent"
grep -xF -A1 "ARG:tt-p" "$stub_dir/argv.update" | grep -qxF "ARG:--assignee" \
  || fail "reopens-a-closed-parent-chain: the parent's assignee was not cleared"
pass "reopens-a-closed-parent-chain"

# --- stops-at-an-open-parent --------------------------------------------------------------------
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":"tt-p"}]' \
         '[{"id":"tt-p","status":"open","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 0 ] || fail "stops-at-an-open-parent: expected exit 0, got $status ($err)"
argv_has reopen tt-a || fail "stops-at-an-open-parent: the child was not reopened"
argv_has reopen tt-p && fail "stops-at-an-open-parent: an open parent was reopened"
pass "stops-at-an-open-parent"

# --- refuses-a-parent-cycle ---------------------------------------------------------------------
#
# A cycle must be an error, not a hang against a live board.
reset_stub
printf '%s' '[{"id":"tt-a","status":"closed","parent":"tt-a"}]' > "$stub_dir/stdout.show"
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 1 ] || fail "refuses-a-parent-cycle: expected exit 1, got $status"
grep -qi 'cycle' <<<"$err" || fail "refuses-a-parent-cycle: stderr does not name the cycle: $err"
pass "refuses-a-parent-cycle"

# --- pushes-after-everything --------------------------------------------------------------------
#
# A reopen that reaches no other machine strands the bead just as thoroughly as one that keeps its
# assignee.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 0 ] || fail "pushes-after-everything: expected exit 0, got $status ($err)"
argv_has dolt push || fail "pushes-after-everything: no bd dolt push"
pass "pushes-after-everything"

# --- a-failed-bd-call-stops-the-run -------------------------------------------------------------
#
# A reopen that half-happened must not be pushed as if it were whole.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
printf '1' > "$stub_dir/exit.update"
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 1 ] || fail "a-failed-bd-call-stops-the-run: expected exit 1, got $status"
[ -n "$err" ] || fail "a-failed-bd-call-stops-the-run: nothing on stderr"
[ ! -f "$stub_dir/argv.dolt" ] \
  || fail "a-failed-bd-call-stops-the-run: a half-reopen was pushed"
pass "a-failed-bd-call-stops-the-run"

# --- a-flag-with-no-value-is-a-usage-error ------------------------------------------------------
#
# `shift 2` with one argument left returns non-zero and `set -euo pipefail` kills the script before
# any validation - exit 1 with no message, where exit 1 is documented as "a bd call failed; the bead
# may be half-reopened". The one thing that status tells the reader would be wrong.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":null}]'
run tt-a --notes n --fault build --sha
[ "$status" -eq 2 ] || fail "a-flag-with-no-value-is-a-usage-error: expected exit 2, got $status"
[ -n "$err" ] || fail "a-flag-with-no-value-is-a-usage-error: nothing on stderr"
[ ! -f "$stub_dir/argv.update" ] \
  || fail "a-flag-with-no-value-is-a-usage-error: a bd update was made anyway"
pass "a-flag-with-no-value-is-a-usage-error"

# --- a-failed-parent-show-stops-the-run ---------------------------------------------------------
#
# "bd could not answer" must not be indistinguishable from "there is no parent". A Dolt-remote
# timeout on the parent's `show` would otherwise skip the whole chain, push, and exit 0 - telling
# the navigator the reopen succeeded while the closed parent keeps its status and its assignee.
reset_stub
set_show '[{"id":"tt-a","status":"closed","parent":"tt-p"}]' '[{"id":"tt-p","status":"closed","parent":null}]'
# The SECOND show - the parent's - and only that one. `exit.show` would fail the bead's own show
# first, the first-show guard would exit before the walk was reached, and this case would pass
# against the very defect it exists to catch.
printf '1' > "$stub_dir/exit.show.2"
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 1 ] || fail "a-failed-parent-show-stops-the-run: expected exit 1, got $status"
[ -n "$err" ] || fail "a-failed-parent-show-stops-the-run: nothing on stderr"
[ ! -f "$stub_dir/argv.dolt" ] \
  || fail "a-failed-parent-show-stops-the-run: a half-reopen was pushed"
# The walk was actually REACHED: without this the case is satisfied by the first-show guard and
# proves nothing about the parent walk at all.
grep -q "ARG:tt-p" "$stub_dir/argv.show" \
  || fail "a-failed-parent-show-stops-the-run: the parent's show was never reached"
argv_has update "--assignee" \
  || fail "a-failed-parent-show-stops-the-run: the bead's own reopen never ran"
pass "a-failed-parent-show-stops-the-run"

# --- a-failed-first-show-is-not-reported-as-a-typo ----------------------------------------------
#
# A bd outage reported as `no such bead' sends the reader hunting for a typo that is not there.
reset_stub
printf '1' > "$stub_dir/exit.show.1"
run tt-a --sha "$sha40" --notes "n" --fault build
[ "$status" -eq 1 ] \
  || fail "a-failed-first-show-is-not-reported-as-a-typo: expected exit 1, got $status"
grep -qi 'no such bead' <<<"$err" \
  && fail "a-failed-first-show-is-not-reported-as-a-typo: a bd failure was called a missing bead"
[ ! -f "$stub_dir/argv.update" ] \
  || fail "a-failed-first-show-is-not-reported-as-a-typo: a bd update was made anyway"
pass "a-failed-first-show-is-not-reported-as-a-typo"

suite_passed
