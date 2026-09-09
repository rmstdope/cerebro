#!/usr/bin/env bash
#
# scripts/fleet-supervisor - where this checkout's supervision lease lives (cb-kcs.1, cb-abs.2).
#
# The script is the ONE place the lease's address is computed. With one window (cb-abs.2) there is
# no longer a declaration to read: `fleet_supervisor' is gone, and so is every answer that named
# one of two implementations. What is left is the endpoint, the identity and the record.
#
# What this suite is really guarding:
#
#   * the script no longer answers "who may supervise" - a bare invocation and an explicit
#     `--declaration' are both usage errors, and a `fleet_supervisor' line left in a project.conf
#     changes no answer this script gives;
#   * the endpoint is a pure function of the SHARED root, so every worktree of one checkout
#     computes one port and one identity;
#   * the range stops below 32768, and two roots that share a prefix do not fold onto one port.
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
: > "$conf"

# ---------------------------------------------------------------------------
# 1. The script no longer answers "who may supervise".
#
# Every remaining question is an explicit flag, so a bare invocation is a usage error rather than
# a default answer to "which one did you mean" - that is how a caller asking for a record gets an
# endpoint. `--declaration' is named explicitly because it is the flag that used to be the
# default, and a caller still passing it must be told rather than answered.
# ---------------------------------------------------------------------------
for bad in "" --declaration; do
  set +e
  if [[ -z "$bad" ]]; then
    out="$("$supervisor" 2>/dev/null)"; status=$?
    err="$("$supervisor" 2>&1 >/dev/null)"
  else
    out="$("$supervisor" "$bad" 2>/dev/null)"; status=$?
    err="$("$supervisor" "$bad" 2>&1 >/dev/null)"
  fi
  set -e
  [[ $status -eq 2 ]] || fail "'${bad:-<no argument>}': expected exit 2, got $status"
  [[ -z "$out" ]] || fail "'${bad:-<no argument>}': expected nothing on stdout, got '$out'"
  grep -q "usage: fleet-supervisor" <<<"$err" \
    || fail "'${bad:-<no argument>}': no usage line, got: $err"
done
pass "a bare invocation and --declaration are both usage errors"

# A project that still carries the retired key is not read at all, and nothing is said about it.
printf 'fleet_supervisor tui\n' > "$conf"
stale_endpoint="$("$supervisor" --endpoint)"
stale_identity="$("$supervisor" --identity)"
stale_record="$("$supervisor" --record)"
: > "$conf"
[[ "$("$supervisor" --endpoint)" == "$stale_endpoint" ]] \
  || fail "a retired fleet_supervisor line changed --endpoint"
[[ "$("$supervisor" --identity)" == "$stale_identity" ]] \
  || fail "a retired fleet_supervisor line changed --identity"
[[ "$("$supervisor" --record)" == "$stale_record" ]] \
  || fail "a retired fleet_supervisor line changed --record"
pass "a fleet_supervisor line left in project.conf changes no answer"

# ---------------------------------------------------------------------------
# 2. Unknown options and stray arguments are usage errors too.
# ---------------------------------------------------------------------------
for bad in --nonsense -x extra-argument; do
  set +e
  err="$("$supervisor" "$bad" 2>&1 >/dev/null)"; status=$?
  set -e
  [[ $status -eq 2 ]] || fail "usage ($bad): expected exit 2, got $status"
  grep -q "usage: fleet-supervisor" <<<"$err" || fail "usage ($bad): no usage line, got: $err"
done
pass "an unknown option or a stray argument is a usage error, not an answer"

# ---------------------------------------------------------------------------
# 3. The endpoint: loopback, in the private range, and a pure function of the root.
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
# 4. The identity and the record: the canonical shared root, and one file beside the state files.
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
# 5. A root the diagnostic record could not round-trip is refused rather than written.
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
# 6. Every worktree of one checkout supervises the same sessions, so all three values come from the
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

# ---------------------------------------------------------------------------
# 7. A mount that is not .claude/cerebro still answers (ah-ohc2), because consumer-root does.
# ---------------------------------------------------------------------------
# A real submodule at `vendor/cerebro', which is the supported shape: `--identity' asks
# `consumer-root --shared', and only git can say which working tree holds a checkout mounted
# somewhere other than `.claude/cerebro' (tests/consumer-fixture.sh says the same of a plain copy
# there, which is the unsupported case).
vendored="$(consumer_with_submodule vendored vendor/cerebro)"
out="$("$vendored/vendor/cerebro/scripts/fleet-supervisor" --identity 2>/dev/null || echo FAILED)"
[[ "$out" == "$(cd "$vendored" && pwd -P)" ]] \
  || fail "vendored mount: expected the vendored consumer's root, got '$out'"
pass "a mount other than .claude/cerebro answers like any other"

# ---------------------------------------------------------------------------
# 8. Nothing is written. This reader is a reader: it must never create the state directory, the
#     record, or the declaration it failed to find.
# ---------------------------------------------------------------------------
[[ ! -e "$consumer/.cerebro/state/supervisor.json" ]] \
  || fail "the reader wrote the diagnostic record"
[[ ! -d "$consumer/.cerebro/state" ]] \
  || fail "the reader created the state directory"
pass "reading ownership writes nothing at all"

# ---------------------------------------------------------------------------
# 9. A root that cannot be resolved is exit 2 with nothing on stdout - never exit 0 with an empty
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
