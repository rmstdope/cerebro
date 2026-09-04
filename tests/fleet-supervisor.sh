#!/usr/bin/env bash
#
# scripts/fleet-supervisor - the typed `fleet_supervisor' declaration, and the three diagnostic
# values both fleet views derive from the shared root (cb-kcs.1).
#
# The script is the ONE place either implementation answers "may I supervise this checkout, and
# where is the lease". Emacs and Ratatui both call it rather than parsing project.conf or hashing a
# root themselves, so a port or an identity can never mean two things at once - which is the whole
# reason the lease is safe to hold across two languages.
#
# What this suite is really guarding:
#
#   * absence means `emacs', so every existing consumer keeps its current behaviour untouched;
#   * an invalid value is FAIL-CLOSED and LOUD - exit 2, the exact human line on stderr, the raw
#     offending value alone on stdout - never a silent fall back to `emacs', because a typo that
#     read as the default would silently keep supervision where the navigator moved it away from;
#   * the endpoint is a pure function of the SHARED root, so every worktree of one checkout
#     computes one port and one identity;
#   * the endpoint, identity and record answer even when the declaration is invalid, because that
#     is exactly when a view needs them to say who holds the lease.
#
# No framework: plain bash, exit non-zero on the first failed assertion. Run from the submodule
# root:
#
#     bash tests/fleet-supervisor.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A consumer with the three scripts this reader needs; their sourced libraries come with them.
consumer="$(consumer_new repo --link fleet-supervisor project-conf consumer-root)"
supervisor="$consumer/.claude/cerebro/scripts/fleet-supervisor"
mkdir -p "$consumer/.cerebro"
conf="$consumer/.cerebro/project.conf"

declare_supervisor() { printf 'fleet_supervisor %s\n' "$1" > "$conf"; }

# ---------------------------------------------------------------------------
# 1. Absence is the default, and the default is `emacs'.
#
# This is the backwards-compatibility guarantee for every consumer that has never heard of this
# key: a fleet whose project.conf predates cb-kcs.1 must keep supervising from Emacs.
# ---------------------------------------------------------------------------
: > "$conf"
out="$("$supervisor")"
[[ "$out" == "emacs" ]] || fail "absent declaration: expected emacs, got '$out'"
pass "an absent fleet_supervisor means emacs"

rm -f "$conf"
out="$("$supervisor")"
[[ "$out" == "emacs" ]] || fail "absent project.conf: expected emacs, got '$out'"
pass "an absent project.conf means emacs"

# An explicitly empty value follows project-conf's own missing-value contract.
printf 'fleet_supervisor\n' > "$conf"
out="$("$supervisor")"
[[ "$out" == "emacs" ]] || fail "empty value: expected emacs, got '$out'"
pass "an empty fleet_supervisor means emacs, like any other missing value"

# ---------------------------------------------------------------------------
# 2. The two values it accepts, and nothing else.
# ---------------------------------------------------------------------------
for want in emacs tui; do
  declare_supervisor "$want"
  out="$("$supervisor")"
  [[ "$out" == "$want" ]] || fail "declared $want: got '$out'"
done
pass "emacs and tui are read back exactly"

# A trailing comment is project-conf's business, but the typed reader must not inherit whitespace
# from it: `tui   # for now' is `tui', not `tui   '.
printf 'fleet_supervisor tui   # while cb-kcs.5 is open\n' > "$conf"
out="$("$supervisor")"
[[ "$out" == "tui" ]] || fail "value with a comment: expected 'tui', got '$out'"
pass "a commented declaration reads as the bare value"

# ---------------------------------------------------------------------------
# 3. An invalid value is fail-closed, loud, and machine-readable.
#
# Both halves matter and they go to different channels. stderr carries the exact sentence a
# navigator reads; stdout carries the raw offending value ALONE, so the view that has to render
# `invalid fleet_supervisor "<value>"' never has to parse the human sentence to find it.
# ---------------------------------------------------------------------------
declare_supervisor "rat"
set +e
out="$("$supervisor" 2>/dev/null)"; status=$?
err="$("$supervisor" 2>&1 >/dev/null)"
set -e
[[ $status -eq 2 ]] || fail "invalid value: expected exit 2, got $status"
[[ "$out" == "rat" ]] || fail "invalid value: expected the raw value alone on stdout, got '$out'"
[[ "$err" == 'fleet-supervisor: invalid fleet_supervisor "rat" - expected "emacs" or "tui"' ]] \
  || fail "invalid value: unexpected stderr: $err"
pass "an invalid declaration exits 2, names itself on stderr and prints the raw value on stdout"

# Case is not a spelling of the value: `Emacs' is a typo, not the default.
declare_supervisor "Emacs"
set +e
out="$("$supervisor" 2>/dev/null)"; status=$?
set -e
[[ $status -eq 2 ]] || fail "wrong case: expected exit 2, got $status"
[[ "$out" == "Emacs" ]] || fail "wrong case: expected 'Emacs' on stdout, got '$out'"
pass "an invalid value is never rounded to the default"

# ---------------------------------------------------------------------------
# 3b. A declaration that could not be READ is exit 3, not exit 2 (cb-nc8).
#
# Exit 2 means a value was read and refused, and section 3 above pins that it always prints that
# value alone on stdout. So an exit 2 carrying NOTHING is a lie the caller cannot detect: the
# Ratatui reader took it as an authoritative "the navigator declared something that is not us",
# went to Draining for one tick, and emptied the armed set for good. A reader's own failure is not
# a fact about the project, so it gets a status of its own.
# ---------------------------------------------------------------------------
stub_consumer="$(consumer_new stubbed --link fleet-supervisor project-conf consumer-root)"
stub_supervisor="$stub_consumer/.claude/cerebro/scripts/fleet-supervisor"
mkdir -p "$stub_consumer/.cerebro"
printf 'fleet_supervisor tui\n' > "$stub_consumer/.cerebro/project.conf"

# `place-scripts' LINKS the real scripts in, so the stub has to replace the link rather than write
# through it into this repository's own scripts/project-conf.
rm -f "$stub_consumer/.claude/cerebro/scripts/project-conf"
cat > "$stub_consumer/.claude/cerebro/scripts/project-conf" <<'STUB'
#!/usr/bin/env bash
echo "project-conf: boom" >&2
exit 1
STUB
chmod +x "$stub_consumer/.claude/cerebro/scripts/project-conf"

set +e
out="$("$stub_supervisor" 2>/dev/null)"; status=$?
err="$("$stub_supervisor" 2>&1 >/dev/null)"
set -e
[[ $status -eq 3 ]] || fail "project-conf failed: expected exit 3, got $status"
[[ -z "$out" ]] || fail "project-conf failed: expected nothing on stdout, got '$out'"
grep -q "project-conf: boom" <<<"$err" \
  || fail "project-conf failed: its own diagnosis did not reach the caller: $err"
pass "a project-conf that fails is exit 3 with nothing on stdout"

# The same shape with the REAL reader: a declaration left at the retired path and none at the new
# one. project-conf refuses with its migration sentence, and that refusal is still not a
# declaration.
retired_consumer="$(consumer_new retired --link fleet-supervisor project-conf consumer-root)"
retired_supervisor="$retired_consumer/.claude/cerebro/scripts/fleet-supervisor"
rm -rf "$retired_consumer/.cerebro"
printf 'fleet_supervisor tui\n' > "$retired_consumer/.claude/cerebro-project.conf"
set +e
out="$("$retired_supervisor" 2>/dev/null)"; status=$?
err="$("$retired_supervisor" 2>&1 >/dev/null)"
set -e
[[ $status -eq 3 ]] || fail "retired declaration path: expected exit 3, got $status"
[[ -z "$out" ]] || fail "retired declaration path: expected nothing on stdout, got '$out'"
[[ -n "$err" ]] || fail "retired declaration path: project-conf's own sentence never reached stderr"
pass "a real project-conf refusal is exit 3, and carries its own sentence"

# ---------------------------------------------------------------------------
# 4. Usage errors are exit 2 as well, and say so without touching the declaration.
# ---------------------------------------------------------------------------
declare_supervisor "emacs"
for bad in --nonsense -x extra-argument; do
  set +e
  err="$("$supervisor" "$bad" 2>&1 >/dev/null)"; status=$?
  set -e
  [[ $status -eq 2 ]] || fail "usage ($bad): expected exit 2, got $status"
  grep -q "usage: fleet-supervisor" <<<"$err" || fail "usage ($bad): no usage line, got: $err"
done
pass "an unknown option or a stray argument is a usage error, not an answer"

# ---------------------------------------------------------------------------
# 5. The endpoint: loopback, in the private range, and a pure function of the root.
# ---------------------------------------------------------------------------
endpoint="$("$supervisor" --endpoint)"
[[ "$endpoint" =~ ^127\.0\.0\.1:[0-9]+$ ]] || fail "--endpoint: unexpected shape '$endpoint'"
port="${endpoint##*:}"
# Below 32768 deliberately: Linux's default ephemeral range starts there, and a lease port an
# outbound connection can borrow reads as a lock error and takes the fleet read-only until the
# next tick.
[[ "$port" -ge 20000 && "$port" -le 32767 ]] || fail "--endpoint: port $port outside 20000-32767"
pass "--endpoint is a loopback address below the ephemeral range"

for probe in /repos/alpha /repos/beta /repos/alpha2 / /a "$HOME" "$work_dir"; do
  probe_port="$("$supervisor" --endpoint-for "$probe")"
  probe_port="${probe_port##*:}"
  [[ "$probe_port" -ge 20000 && "$probe_port" -le 32767 ]] \
    || fail "--endpoint-for $probe: port $probe_port outside 20000-32767"
done
pass "every root lands in the 20000-32767 block"

again="$("$supervisor" --endpoint)"
[[ "$again" == "$endpoint" ]] || fail "--endpoint is not deterministic: $endpoint then $again"
pass "--endpoint answers the same port every time for one root"

# The declaration does not enter the endpoint at all: a TUI that cannot read the declaration still
# has to be able to say who holds the lease.
declare_supervisor "tui"
[[ "$("$supervisor" --endpoint)" == "$endpoint" ]] || fail "--endpoint changed with the declaration"
declare_supervisor "rat"
[[ "$("$supervisor" --endpoint)" == "$endpoint" ]] || fail "--endpoint failed on an invalid declaration"
[[ "$("$supervisor" --record)" == "$consumer/.cerebro/state/supervisor.json" ]] \
  || fail "--record failed on an invalid declaration"
pass "the endpoint and the record answer even when the declaration is invalid"
declare_supervisor "emacs"

# --endpoint-for exposes the port function itself, so the arithmetic is pinned against fixed
# strings rather than against whatever path mktemp handed this run - a distinctness assertion over
# two random roots would be a one-in-twenty-thousand flake, which is not a test.
fixed_a="$("$supervisor" --endpoint-for /repos/alpha)"
fixed_b="$("$supervisor" --endpoint-for /repos/alpha)"
[[ "$fixed_a" == "$fixed_b" ]] || fail "--endpoint-for is not a function: $fixed_a then $fixed_b"
[[ "$fixed_a" =~ ^127\.0\.0\.1:[0-9]+$ ]] || fail "--endpoint-for: unexpected shape '$fixed_a'"
pass "--endpoint-for is a pure function of the root it is given"

different="$("$supervisor" --endpoint-for /repos/beta)"
[[ "$different" != "$fixed_a" ]] || fail "/repos/alpha and /repos/beta collided on $fixed_a"
pass "two different roots take two different ports"

# A near-miss pair: one trailing character must not fold onto the same port. This is the case the
# two-checksum XOR exists for - a single sum over a short string moves too predictably.
near="$("$supervisor" --endpoint-for /repos/alpha2)"
[[ "$near" != "$fixed_a" ]] || fail "/repos/alpha and /repos/alpha2 collided on $fixed_a"
pass "a root that differs by one character takes a different port"

[[ "$("$supervisor" --endpoint-for "$consumer")" == "$endpoint" ]] \
  || fail "--endpoint-for <shared root> disagrees with --endpoint"
pass "--endpoint is --endpoint-for of the shared root"

# ---------------------------------------------------------------------------
# 6. The identity and the record: the canonical shared root, and one file beside the state files.
# ---------------------------------------------------------------------------
identity="$("$supervisor" --identity)"
[[ "$identity" == "$(cd "$consumer" && pwd -P)" ]] \
  || fail "--identity: expected $consumer, got $identity"
pass "--identity is the canonical absolute shared root"

record="$("$supervisor" --record)"
[[ "$record" == "$consumer/.cerebro/state/supervisor.json" ]] \
  || fail "--record: expected $consumer/.cerebro/state/supervisor.json, got $record"
pass "--record names supervisor.json beside the state files"

# ---------------------------------------------------------------------------
# 7. A root the diagnostic record could not round-trip is refused rather than written.
#
# The record is JSON holding the identity; a root carrying a tab or a newline would come back
# ambiguous, and an ambiguous identity is what turns a port collision into a silent takeover.
# ---------------------------------------------------------------------------
tab_root="$work_dir/tab$(printf '\t')root"
mkdir -p "$tab_root/.cerebro"
git_q init -q "$tab_root"
git_q -C "$tab_root" commit -q --allow-empty -m "tabbed root"
"$repo_root/tests/lib/place-scripts" "$tab_root/.claude/cerebro/scripts" \
  fleet-supervisor project-conf consumer-root
set +e
err="$("$tab_root/.claude/cerebro/scripts/fleet-supervisor" --identity 2>&1 >/dev/null)"; status=$?
set -e
[[ $status -eq 2 ]] || fail "tabbed root: expected exit 2 from --identity, got $status"
grep -q "cannot be used as a supervision identity" <<<"$err" \
  || fail "tabbed root: expected the identity refusal, got: $err"
pass "a root containing a tab is refused rather than written into the record"

# ---------------------------------------------------------------------------
# 8. Every worktree of one checkout supervises the same sessions, so all three values come from the
#    SHARED root - the same rule project-conf and agent-state already follow.
# ---------------------------------------------------------------------------
worktree="$consumer/.cerebro/worktrees/wt"
git_q -C "$consumer" worktree add -q "$worktree" -b wt-branch
"$repo_root/tests/lib/place-scripts" "$worktree/.claude/cerebro/scripts" \
  fleet-supervisor project-conf consumer-root
wt_supervisor="$worktree/.claude/cerebro/scripts/fleet-supervisor"

[[ "$("$wt_supervisor" --identity)" == "$identity" ]] \
  || fail "worktree --identity: expected the shared root $identity"
[[ "$("$wt_supervisor" --endpoint)" == "$endpoint" ]] \
  || fail "worktree --endpoint: expected the shared root's $endpoint"
[[ "$("$wt_supervisor" --record)" == "$record" ]] \
  || fail "worktree --record: expected the shared root's $record"
pass "a worktree answers the shared root's identity, endpoint and record"

# The declaration is the shared checkout's too, for the reason implement-bead already documents:
# one fleet, one answer.
declare_supervisor "tui"
[[ "$("$wt_supervisor")" == "tui" ]] || fail "worktree: the declaration is not read from the shared root"
pass "a worktree reads the shared checkout's declaration"
declare_supervisor "emacs"

# ---------------------------------------------------------------------------
# 9. A mount that is not .claude/cerebro still answers (ah-ohc2), because consumer-root does.
# ---------------------------------------------------------------------------
vendored="$(consumer_new vendored --origin)"
mkdir -p "$vendored/.cerebro"
"$repo_root/tests/lib/place-scripts" "$vendored/vendor/cerebro/scripts" \
  fleet-supervisor project-conf consumer-root
git_q -C "$vendored" add -A >/dev/null 2>&1 || true
git_q -C "$vendored" commit -qm "vendor cerebro" >/dev/null 2>&1 || true
out="$("$vendored/vendor/cerebro/scripts/fleet-supervisor" 2>/dev/null || echo FAILED)"
[[ "$out" == "emacs" ]] || fail "vendored mount: expected emacs, got '$out'"
pass "a mount other than .claude/cerebro answers like any other"

# ---------------------------------------------------------------------------
# 10. Nothing is written. This reader is a reader: it must never create the state directory, the
#     record, or the declaration it failed to find.
# ---------------------------------------------------------------------------
[[ ! -e "$consumer/.cerebro/state/supervisor.json" ]] \
  || fail "the reader wrote the diagnostic record"
[[ ! -d "$consumer/.cerebro/state" ]] \
  || fail "the reader created the state directory"
pass "reading ownership writes nothing at all"

# ---------------------------------------------------------------------------
# 11. A root that cannot be resolved is exit 2 with nothing on stdout - never exit 0 with an empty
#     answer.
#
# Earned during this bead: `shared_root' is only ever called from a command substitution, and an
# `exit' inside one leaves the subshell rather than the script. The first version exited 0 printing
# nothing, which a caller would have bound a listener to.
# ---------------------------------------------------------------------------
standalone="$work_dir/loose/cerebro/scripts"
"$repo_root/tests/lib/place-scripts" "$standalone" fleet-supervisor project-conf consumer-root
for option in --endpoint --identity --record; do
  set +e
  out="$("$standalone/fleet-supervisor" "$option" 2>/dev/null)"; status=$?
  set -e
  [[ $status -eq 2 ]] || fail "no consumer root ($option): expected exit 2, got $status"
  [[ -z "$out" ]] || fail "no consumer root ($option): expected no stdout, got '$out'"
done
pass "an unresolvable root exits 2 with nothing on stdout, never 0 with an empty answer"

suite_passed
