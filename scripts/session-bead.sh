# shellcheck shell=bash
#
# scripts/session-bead.sh - the one place bash reads which bead a session says it is on (cb-15cw).
# Sourced, never executed; it sets no shell options of its own.
#
#   cerebro_session_bead <state dir> <Name>
#       prints the bead <Name>'s state file names, or, while it names none, the bead its handover
#       names (`scripts/assign-bead` writes the handover before the session's first state write);
#       prints nothing when neither names one. Always exit 0.
#
# Whether the session is ALIVE is not asked here: that is `scripts/agent-alive`, which each caller
# runs itself. The callers then ask different questions of the answer. `release-bead` asks whether
# NAME is on bead ID, and gives a live session that names nothing the benefit of the doubt;
# `prune-worktrees.sh` asks which tree each live session holds, and a session naming nothing
# holds none.
cerebro_session_bead() {
  local state_dir="$1" name="$2" bead=""
  if [ -f "$state_dir/$name.state.json" ]; then
    bead="$(jq -r '.bead // empty' "$state_dir/$name.state.json" 2>/dev/null || true)"
  fi
  if [ -z "$bead" ] && [ -f "$state_dir/$name.handover" ]; then
    IFS= read -r bead < "$state_dir/$name.handover" || true
  fi
  printf '%s' "$bead"
  return 0
}
