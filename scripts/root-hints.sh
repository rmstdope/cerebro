# scripts/root-hints.sh - the launch path's root hints, and the mount round trip under them.
#
# SOURCED, NEVER EXECUTED. It has no `set -euo pipefail' of its own and defines functions only, so
# sourcing it changes nothing about the caller's shell but the names it can call. Builtins alone
# (`cd', `pwd', `printf'), because tests/launchers.sh runs the launch path with a PATH holding
# `dirname' and `bash' and nothing else.
#
# WHY IT EXISTS (cb-ue0). One `scripts/launch' used to fork `consumer-root' sixteen times: launch
# resolved the root, then preflight resolved it again, then `default-branch', `project-conf',
# `agent-cli' and `sync-symlinks.sh' each resolved it again from scratch - a quarter of a second of
# pure re-derivation on every session start, and 84% of the gate's slowest suite. So `launch'
# resolves all three answers ONCE (`consumer-root --hints') and exports them down its own process
# tree; every consumer script below prefers the hint and falls back, unchanged, to forking
# `consumer-root' when there is none.
#
#   CEREBRO_CONSUMER_ROOT         the enclosing working tree      (`consumer-root')
#   CEREBRO_CONSUMER_SHARED_ROOT  the shared working tree         (`consumer-root --shared')
#   CEREBRO_CONSUMER_MOUNT        this checkout, relative to it   (`consumer-root --mount')
#
# WHY THEY ARE VALIDATED RATHER THAN TRUSTED, which is the whole of the design. `consumer-root'
# deliberately resolves from `${BASH_SOURCE[0]}', so a copy of cerebro living inside a bead worktree
# answers about THAT worktree and not the main checkout. An inherited answer would quietly take that
# away: an environment variable outlives the process that set it, so a script run by hand in a
# worktree from a shell that once launched an agent would read the main checkout's root and write
# its links there.
#
# The guard is the same round trip `consumer-root' resolves by, run against the hint rather than a
# guess: <hinted root>/<hinted mount> must resolve to the checkout THIS caller lives in. It cannot
# be true for two checkouts at once, so a hint from another tree - or from a tree that has since
# moved - is rejected and the caller falls back. That makes the hints an optimisation and never a
# source of truth, which is the only shape safe to inherit.
#
# `CEREBRO_CONSUMER_MOUNT' is part of the stamp rather than a convenience: it is what lets the
# round trip work for a submodule vendored somewhere other than `.claude/cerebro'.

# THE one answer to "does <root>/<mount> resolve to <checkout>" (cb-akc). `consumer-root' resolves
# by it, `--self-mounted' and `--mount' expose it, and the hint guard below reuses it - so roster
# (through the plain form) and sync-symlinks.sh (through `--mount') ask rather than spelling the
# round trip again; five copies by three mechanisms is how the janitor walked one list twice and
# roster fell back to the built-in fleet in silence. prune-worktrees.sh is NOT one of the callers
# and is not a sixth copy: it compares git dirs, which asks "one repository or two" rather than
# "does the mount resolve back", and the two part company for a vendored plain copy at the standard
# mount - its own header carries the reason. Physical on both sides: macOS mktemp lives under
# /var -> /private/var.
cerebro_mount_resolves_to() {
  # $1 = a candidate consumer root, $2 = a checkout of cerebro, $3 = the mount (default the standard one)
  local mount checkout
  mount="$(cd "$1/${3:-.claude/cerebro}" 2>/dev/null && pwd -P)" || return 1
  checkout="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  [[ "$mount" == "$checkout" ]]
}

# Exit 0 when the exported hints describe the checkout at $1, and 1 for every other case - unset,
# half-set, or set by a shell that was inside a different tree. Nothing printed.
cerebro_root_hints_valid() {
  # $1 = the cerebro checkout the caller lives in
  [[ -n "${CEREBRO_CONSUMER_ROOT:-}" && -n "${CEREBRO_CONSUMER_MOUNT:-}" ]] || return 1
  cerebro_mount_resolves_to "$CEREBRO_CONSUMER_ROOT" "$1" "$CEREBRO_CONSUMER_MOUNT"
}

# One hinted answer on stdout, or exit 1 with nothing printed - so a caller writes
#
#     root="$(cerebro_hinted_root "$checkout" shared)" || root="$("$here/consumer-root" --shared)"
#
# and keeps its existing fallback exactly as it was. `shared' fails on its own when `launch'
# resolved no shared root (a consumer that is not a git working tree): the caller then forks
# `consumer-root --shared', which fails there too, which is the behaviour it already had.
cerebro_hinted_root() {
  # $1 = the cerebro checkout the caller lives in, $2 = plain|shared|mount
  cerebro_root_hints_valid "$1" || return 1
  case "$2" in
    plain)  printf '%s\n' "$CEREBRO_CONSUMER_ROOT" ;;
    shared) [[ -n "${CEREBRO_CONSUMER_SHARED_ROOT:-}" ]] || return 1
            printf '%s\n' "$CEREBRO_CONSUMER_SHARED_ROOT" ;;
    mount)  printf '%s\n' "$CEREBRO_CONSUMER_MOUNT" ;;
    *)      return 1 ;;
  esac
}
