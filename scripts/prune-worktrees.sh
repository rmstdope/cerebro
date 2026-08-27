#!/usr/bin/env bash
#
# Removes agent worktrees that have nothing left in them.
#
# It walks TWO worktree lists: the consumer's, and `.claude/cerebro`'s (ah-apw4). A worktree of the
# submodule is registered in the submodule and nowhere else, so nothing enumerated one and two sat
# on the machine that prompted this with their merged branches still checked out, immortal. A bead
# whose diff is inside the submodule should not need such a tree at all — `implement-bead`'s
# *Workspace* declares the in-place route instead — but the ones already made are real, and this is
# what clears them. Every rule below applies to a cerebro tree unchanged; only the repository each
# rule is asked of changes.
#
# Every implementer builds its bead in `.cerebro/worktrees/<bead>` and is told to remove it on the way
# out — on every exit, including the ones that go wrong. It does not always get there: a session that
# crashes, is killed, or has its bead merged by somebody else leaves the tree, its branch and its
# build artifacts on disk. They accumulate, and a stray one costs more than space: `git worktree
# list` gets long enough that nobody reads it, and a `main` checked out in an abandoned tree makes
# the next agent's `git checkout main` fail for no visible reason.
#
#     .claude/cerebro/scripts/prune-worktrees.sh              # one sweep, then exit
#     .claude/cerebro/scripts/prune-worktrees.sh --dry-run    # say what would go, remove nothing
#     .claude/cerebro/scripts/prune-worktrees.sh --watch      # sweep every ten minutes until killed
#
# ## What counts as safe
#
# Safe means **nothing can be lost**, which is a stronger and simpler test than "nobody is using it":
#
#   1. It is under `.cerebro/worktrees/`, the one place worktrees live (ah-v82, ah-aln5). The
#      main checkout is never touched, and neither is a tree registered anywhere else: a tree
#      outside the home is not an agent worktree, whatever its name.
#   2. The working tree is clean — no modified files, no untracked ones.
#   3. Its branch holds no commit that the default branch on origin does not already have.
#   4. Nothing has changed in it for a while (see STALE_MINUTES), so a tree that was created moments
#      ago and has not been written to yet is left alone.
#
# Fail any one and it stays, with the reason printed. Together they mean the directory can go without
# destroying a line of anybody's work: the commits are on main and there is nothing uncommitted.
#
# One named exception: **the fleet's verifier** is kept by name, unconditionally, ahead of all
# four checks.
#
# The exception exists because it is the verification tree (ah-p31) — reset hard to the default
# branch before every use rather than merged, so it never satisfies "holds no commit main lacks" the
# way a normal agent worktree does, and there is nothing in it to lose by keeping it either way.
#
# Which name that is comes from `scripts/roster --role verifier` rather than from a literal here
# (ah-qled.4). A literal `psylocke` in the control flow of a destructive script means a consumer that
# renames or drops its verifier has that tree deleted mid-verification, and one with a differently
# named verifier cannot express the exception at all. Matched case-insensitively, as the literal
# was, and a roster with no verifier grants the exception to nobody.
#
# Deliberately NOT part of the test: whether the bead is `in_progress`. That sounds like the obvious
# guard and it is the wrong one — an agent that crashed leaves its bead claimed for ever, so keying
# on it would protect exactly the trees most in need of removing. ah-6xq.8 was one: merged, closed by
# nobody, claim still standing, worktree still on disk.
#
# `git worktree prune` runs first regardless. That only clears registrations whose directory is
# already gone, which can never lose anything.
#
# ## Reclaiming a kept tree's build directory
#
# **Which directories those are is the consumer's to declare, and the default is NONE** (ah-qled.4).
# `reclaim_dirs` in `.cerebro/project.conf` names them — `reclaim_dirs target node_modules`.
# Undeclared means nothing here ever deletes anything, at any age and under any pressure. That
# default is deliberate and is the safety property of this script: `target` as a built-in meant a
# Node consumer's `node_modules/` was never reclaimed, a Python consumer's `.venv/` never, and a
# consumer whose *source* lives in `target/` lost it. A destructive behaviour is opt-in.
#
# There are two windows, and they answer different questions.
#
# COLD_TARGET_MINUTES — a day — is the outer bound, and it applies whatever the disk looks like: a
# build tree nobody has written to since yesterday is not being used by anybody.
#
# PRESSURE_COLD_MINUTES — half an hour — applies **only when the disk is near the fleet's own build
# floor**, and it is the answer to ah-90gu: `prune-worktrees.sh` reclaimed nothing precisely when
# the floor was tripped, because when the fleet is full every tree belongs to a live agent. But
# **live is not building.** An implementer waiting twenty minutes on CI, or on a review, holds a
# stone-cold 3 GB tree that the day-long bound cannot distinguish from one being compiled into.
# Under pressure the coldest such tree's `target/` goes, one per sweep, and the tree it belonged to
# is untouched — its branch, its commits and its PR survive, and it pays one cold rebuild. When the
# disk is roomy nothing is reclaimed and nobody pays that rebuild for nothing.
#
# The floor is **not a second number**. It is `disk_floor_gb` from the consumer's own
# `.cerebro/project.conf`, which already defines "not enough room to build" and is what
# `disk-preflight` refuses to start a bead below; a threshold of this script's own would drift from
# it and the two would disagree at the worst possible moment. A consumer that declares no floor
# gets no pressure path at all — only the outer bound — rather than a number this script made up.
#
# The verifier is exempt from the pressure path (its tree is a tenth the size of an implementer's, so
# reclaiming it costs a verification and buys nothing) but not from the outer bound below.
#
# The verifier's tree is kept for ever, and every worktree now builds into its own `target/` (ah-gdp:
# `.cargo/config.toml` is tracked, so each worktree's search for it stops at its own root rather
# than reaching a shared one) — so its build tree only ever grows. This sweep reclaims just that
# directory, never the worktree itself, once it has sat unwritten for far longer than
# STALE_MINUTES would ever tolerate for a whole tree (see COLD_TARGET_MINUTES; a day by default —
# Psylocke runs several times a day, so this fires on a quiet weekend rather than between two
# verifications). The rebuild that follows is a cold one; Psylocke's own text already warms it
# again after her reset, so that cost is accepted on purpose.

set -uo pipefail

STALE_MINUTES="${STALE_MINUTES:-30}"
COLD_TARGET_MINUTES="${COLD_TARGET_MINUTES:-1440}"
PRESSURE_COLD_MINUTES="${PRESSURE_COLD_MINUTES:-30}"
WATCH_SECONDS="${WATCH_SECONDS:-600}"

case "$PRESSURE_COLD_MINUTES" in
  ''|*[!0-9]*)
    echo "prune-worktrees: PRESSURE_COLD_MINUTES must be a positive integer of minutes, got '$PRESSURE_COLD_MINUTES'" >&2
    exit 2
    ;;
esac

case "$COLD_TARGET_MINUTES" in
  ''|*[!0-9]*)
    echo "prune-worktrees: COLD_TARGET_MINUTES must be a positive integer of minutes, got '$COLD_TARGET_MINUTES'" >&2
    exit 2
    ;;
esac

dry_run=false
watch=false
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=true ;;
    --watch) watch=true ;;
    *) echo "usage: .claude/cerebro/scripts/prune-worktrees.sh [--dry-run] [--watch]" >&2; exit 2 ;;
  esac
done

# The shared checkout every worktree of the repository has in common — asked of
# scripts/consumer-root rather than derived from this file's own path, which run from a bead
# worktree would otherwise answer the worktree, not the repository the sweep needs to walk. See
# consumer-root's header for the two roots and why a sweep needs the shared one.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo_root="$("$script_dir/consumer-root" --shared)" || exit 1

# The branch is resolved rather than assumed (ah-qled.3): with `main` hardcoded, a consumer whose
# branch is called anything else got "could not reach origin" and no sweep ever ran.
default_branch="$("$script_dir/default-branch" 2>/dev/null)" || default_branch=""
[ -n "$default_branch" ] || default_branch="main"

# The submodule the fleet's own harness lives in, and the second worktree list this sweep walks.
# A bead whose diff is inside it needs no worktree of its own — `implement-bead`'s *Workspace*
# declares the in-place route — but the trees older instructions left are real, are registered in
# the submodule and not in the consumer, and were therefore invisible to every sweep for ever
# (ah-apw4). Absent, or not a repository, is an ordinary state: the sweep then walks one list.
submodule_root="$repo_root/.claude/cerebro"
submodule_default_branch="$(git -C "$submodule_root" symbolic-ref --short --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
submodule_default_branch="${submodule_default_branch#origin/}"
[ -n "$submodule_default_branch" ] || submodule_default_branch="$default_branch"

# The build directories this consumer is willing to have deleted, and NOTHING BY DEFAULT — see the
# header. Whitespace-separated, so `reclaim_dirs target node_modules` names two.
reclaim_dirs=()
declared_reclaim_dirs="$("$script_dir/project-conf" reclaim_dirs 2>/dev/null || true)"
# Deliberately unquoted: the value is a list, and word splitting is how it becomes one.
# shellcheck disable=SC2206
[ -n "$declared_reclaim_dirs" ] && reclaim_dirs=($declared_reclaim_dirs)

# How this consumer answers "did this branch's work land?". `gh` is today's behaviour and the
# default; `none` and a command are for a consumer that has no GitHub PRs to ask about. See
# `landed_on_main`.
merged_check="$("$script_dir/project-conf" merged_check gh 2>/dev/null || echo gh)"
[ -n "$merged_check" ] || merged_check="gh"

# The name of the tree kept unconditionally, taken from the roster rather than written here. Empty
# when the fleet has no verifier, which grants the exception to nobody.
verifier_roster="$("$script_dir/roster" --role verifier 2>/dev/null || true)"
verifier_name="${verifier_roster%%$'\n'*}"
verifier_lc="$(printf '%s' "$verifier_name" | tr '[:upper:]' '[:lower:]')"

is_verifier_tree() {
  # $1 = the worktree's basename. Case-insensitive on the name, as the lowercased literal it
  # replaces was (ah-qled.4). No path test: rule 1 in `sweep` admits `.cerebro/worktrees/` and
  # nothing else, so every name that reaches here is at the one path worktrees live at.
  [ -n "$verifier_lc" ] || return 1
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$verifier_lc" ]
}

# Whether the mount and the consumer are ONE GIT REPOSITORY, so that `git worktree list` asked of
# each returns the same list. When they are, walking "both" walks one list twice — every tree
# enumerated once per owner, the tallies inflated, and a tree already removed on the first pass
# reported as kept on the second.
#
# This is the one place cb-akc did NOT fold into `consumer-root --self-mounted', and the reason is
# that the two questions are not the same one. `--self-mounted' asks whether `.claude/cerebro'
# resolves back to the checkout root — true for cerebro serving its own fleet (cb-i3l.1) and false
# otherwise. That answers this question for a real submodule (two repositories) and for the
# self-mount (one repository), and gets it WRONG for the third supported layout: a vendored plain
# COPY at the standard mount (tests/consumer-root.sh, "a plain copy at the standard mount resolves
# the consumer"), where `.claude/cerebro' is an ordinary directory of the consumer's own repository
# — one worktree list — while the round trip says "not self-mounted". tests/project-sweeps.sh is
# the fixture with exactly that shape, and it reported every tree twice when this asked
# `--self-mounted'. So: compared by git dir, which is what "one repository" actually means, and
# which the symlinked self-mount also satisfies where a path comparison would not.
submodule_is_the_consumer() {
  local a b
  a="$(git -C "$submodule_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  b="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# The default branch of whichever repository owns a worktree — the consumer's for a consumer tree,
# the submodule's for one of its own.
owner_default_branch() {
  case "$1" in
    "$submodule_root") printf '%s\n' "$submodule_default_branch" ;;
    *)                 printf '%s\n' "$default_branch" ;;
  esac
}

# Whether everything in this worktree is already on main.
#
# Two tests, because one is not enough. `origin/<default branch>..HEAD` empty catches a branch that was never
# committed to or was merged by fast-forward — but **this repository merges with `--squash`**, which
# writes a brand new commit, so a squash-merged branch's own commits are never reachable from main
# and that test alone would keep every worktree for ever. ah-6xq.8 was the case that found this: PR
# #156 merged, branch fully delivered, and `rev-list` still counting two commits ahead.
#
# So the second test asks whoever this consumer says can answer, and `merged_check` (ah-qled.4) says
# who that is. GitHub via `gh` was the only authority recognised here, so a GitLab or PR-less
# consumer read "not merged" for every branch and the janitor never reclaimed anything.
#
#   gh         today's behaviour, and the default: ask GitHub for a merged PR from this branch. If
#              `gh` cannot answer — no network, not authenticated — the answer is no and the
#              worktree stays. A janitor that guesses permissively is worse than one that leaves a
#              directory behind.
#   none       NOT "skip the check". The rev-list test above cannot see a squash merge, so skipping
#              would keep every delivered worktree for ever — exactly the bug the second test
#              exists for. `none` pairs it with THE STALENESS BOUND instead: a clean tree (rule 2
#              has already passed) that nobody has written to in COLD_TARGET_MINUTES — far longer
#              than a whole tree is ever left alone for — is finished with, whoever merged it and
#              however. That is the only bound available without an authority to ask, and it is a
#              bound rather than a free pass: a tree still being written to is kept.
#   <command>  run it, with `{branch}` substituted if it appears and the branch appended if it does
#              not; exit 0 means the work landed.
landed_on_main() {
  # $1 = the worktree, $2 = the default branch of the repository that owns it. The second argument
  # exists because a worktree of the submodule is judged against the submodule's own origin, not
  # the consumer's (ah-apw4); it defaults to the consumer's, which is every other caller.
  local tree="$1" base="${2:-$default_branch}" branch command_line

  [ "$(git -C "$tree" rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 1)" = "0" ] && return 0

  branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  [ -n "$branch" ] || return 1

  case "$merged_check" in
    gh)
      # From the tree, in a subshell. `gh` infers its repository from the process's working
      # directory and not from anything passed to it, so asking from the sweep's own cwd asks the
      # consumer about a branch it has never heard of — reads "not merged", and keeps a delivered
      # worktree of another repository for ever (ah-apw4). The subshell leaves the sweep's own
      # directory alone, and for a consumer tree this is where the answer already came from.
      [ "$( (cd "$tree" && gh pr list --head "$branch" --state merged --json number --jq 'length') 2>/dev/null || echo 0)" != "0" ]
      ;;
    none)
      # Deep, not `-maxdepth 0`: a tree's own mtime stops moving while every write lands in a
      # subdirectory that already exists, which would call an actively-used tree cold.
      [ -z "$(find "$tree" -mmin "-$COLD_TARGET_MINUTES" -print -quit 2>/dev/null)" ]
      ;;
    *)
      case "$merged_check" in
        *"{branch}"*) command_line="${merged_check//\{branch\}/$branch}" ;;
        *)            command_line="$merged_check $branch" ;;
      esac
      # shellcheck disable=SC2086
      eval $command_line >/dev/null 2>&1
      ;;
  esac
}

# Gigabytes free on the filesystem holding the repository, as an integer, truncated down — an
# overstatement here would let a bead start on a disk that cannot hold its build.
free_space_gb() {
  df -Pk "$repo_root" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 / 1024 }'
}

# The fleet's build floor, read from the consumer's own declaration rather than restated here.
# Empty when the consumer declares no `disk_floor_gb`, which disables the pressure path rather than
# inventing a number for it — the same absence `disk-preflight` reads as "no preflight at all", so
# the two agree even about not knowing. `FREE_SPACE_FLOOR_GB` in the environment wins, for a
# consumer that keeps its floor somewhere else.
build_floor_gb() {
  if [ -n "${FREE_SPACE_FLOOR_GB:-}" ]; then
    echo "$FREE_SPACE_FLOOR_GB"
    return 0
  fi
  "$script_dir/project-conf" disk_floor_gb 2>/dev/null
}

# How cold a build tree is, as the largest window in a ladder within which nothing was written —
# so "60" means "nothing has been touched in there for over an hour", and 0 means it is warmer
# than PRESSURE_COLD_MINUTES and therefore not eligible at all.
#
# A ladder rather than a timestamp because there is no cheap portable way to ask for the newest
# mtime beneath a directory: `stat` on every file in a 3 GB build tree is hundreds of thousands of
# calls, and `find -mmin -N -print -quit` stops at the first match. A bucket is all the ordering
# and all the log line need.
coldness_minutes() {
  local target="$1" best=0 window
  for window in "$PRESSURE_COLD_MINUTES" 60 120 240 480 1440 4320 10080; do
    [ "$window" -le "$best" ] && continue
    if [ -z "$(find "$target" -mmin "-$window" -print -quit 2>/dev/null)" ]; then
      best="$window"
    else
      break
    fi
  done
  echo "$best"
}

# Removes a kept tree's `target/` when it has sat unwritten for far longer than a whole tree would
# ever be left alone for (COLD_TARGET_MINUTES). This never touches the worktree itself — only a
# directory inside one that is staying. Called only for the tree kept by the `psylocke` name
# exception, before any of the elif safety checks below ever run for it — those checks judge
# whether a *worktree* can be removed, which is a different question from this one; what makes
# removing just its target/ safe is this function's own existence check and the mtime check next.
reclaim_cold_target() {
  local tree="$1" name="$2" dir target size_gb

  # Nothing is declared, so nothing goes. See the header: the destructive behaviour is opt-in.
  [ "${#reclaim_dirs[@]}" -gt 0 ] || return 0

  for dir in "${reclaim_dirs[@]}"; do
    target="$tree/$dir"
    [ -d "$target" ] || continue
    # Any file or directory touched within the window, not just target/'s own mtime: a build in
    # progress only bumps that the moment a new top-level entry lands, and stays unchanged while
    # every later write lands in a subdirectory that already exists — `-maxdepth 0` alone
    # misclassified an actively-building tree as cold. `-print -quit` stops at the first match.
    [ -z "$(find "$target" -mmin "-$COLD_TARGET_MINUTES" -print -quit 2>/dev/null)" ] || continue

    size_gb="$(du -sk "$target" 2>/dev/null | awk '{printf "%.1f", $1 / 1024 / 1024}')"

    if $dry_run; then
      echo "prune-worktrees: would reclaim $name/$dir ($size_gb GB, cold for over $COLD_TARGET_MINUTES minutes)"
    else
      rm -rf "$target"
      echo "prune-worktrees: reclaimed $name/$dir ($size_gb GB, cold for over $COLD_TARGET_MINUTES minutes)"
    fi
  done
}

# Reclaims the coldest kept tree's `target/`, and only when the disk is at or below the floor that
# would refuse to start a bead. One per sweep: the next sweep reclaims another if it is still
# tight, and a single reclaim is usually two or three gigabytes.
#
# The log line is the whole of the accountability — a live agent's build tree is being deleted with
# nobody deciding — so it carries all four facts: which tree, how much it freed, the free space
# that allowed it against the floor it was measured against, and how cold the tree was.
reclaim_under_pressure() {
  local free_gb floor_gb coldest_target="" coldest_label="" coldest_age=0
  local entry tree name dir age target size

  # Nothing is declared, so nothing goes — before the disk is even measured.
  [ "${#reclaim_dirs[@]}" -gt 0 ] || return 0

  floor_gb="$(build_floor_gb)"
  [ -n "$floor_gb" ] || return 0

  free_gb="$(free_space_gb)"
  [ -n "$free_gb" ] || return 0
  # The same test disk-preflight makes — headroom is *more* than the floor — so the two can never
  # disagree about whether there is room to build.
  [ "$free_gb" -gt "$floor_gb" ] && return 0

  for entry in "$@"; do
    name="${entry%%:*}"
    tree="${entry#*:}"
    for dir in "${reclaim_dirs[@]}"; do
      target="$tree/$dir"
      [ -d "$target" ] || continue
      age="$(coldness_minutes "$target")"
      if [ "$age" -gt "$coldest_age" ]; then
        coldest_age="$age"
        coldest_target="$target"
        coldest_label="$name/$dir"
      fi
    done
  done

  if [ -z "$coldest_target" ]; then
    echo "prune-worktrees: ${free_gb} GB free against the ${floor_gb} GB floor, and no build tree has been cold for $PRESSURE_COLD_MINUTES minutes"
    return 0
  fi

  size="$(du -sh "$coldest_target" 2>/dev/null | awk '{print $1}')"

  if $dry_run; then
    echo "prune-worktrees: would reclaim $coldest_label ($size, ${free_gb} GB free against the ${floor_gb} GB floor, cold for over $coldest_age minutes)"
  else
    rm -rf "$coldest_target"
    echo "prune-worktrees: reclaimed $coldest_label ($size freed, ${free_gb} GB free against the ${floor_gb} GB floor, cold for over $coldest_age minutes)"
  fi
}

sweep() {
  git -C "$repo_root" worktree prune

  # One fetch per sweep: rule 3 compares against the default branch, and a stale ref would call an already
  # merged branch unmerged and keep every worktree for ever.
  git -C "$repo_root" fetch --quiet origin "$default_branch" 2>/dev/null || {
    echo "prune-worktrees: could not reach origin; skipping this sweep rather than guessing"
    return 0
  }

  # The same two steps for the submodule, and a failure here costs the submodule half ONLY. The
  # consumer's fetch above returns from the whole sweep because without it nothing can be judged;
  # a cerebro remote that cannot be reached is no reason to leave the consumer's trees unswept.
  local sweep_submodule=false
  if git -C "$submodule_root" rev-parse --git-dir >/dev/null 2>&1 && ! submodule_is_the_consumer; then
    git -C "$submodule_root" worktree prune 2>/dev/null || true
    if git -C "$submodule_root" fetch --quiet origin "$submodule_default_branch" 2>/dev/null; then
      sweep_submodule=true
    else
      echo "prune-worktrees: could not reach the submodule's origin; sweeping the consumer's worktrees only"
    fi
  fi

  local removed=0 kept=0
  # Trees that are staying and could give up their build directory if the disk is tight. The
  # verifier's is not among them: see the pressure note in the header.
  local pressure_candidates=()

  # Each line is `<owning repository>|<worktree>`. Every other git call in this loop already
  # passes `$tree` and needs no owner; the four that address the repository do (ah-apw4).
  local owner
  while IFS='|' read -r owner tree; do
    case "$tree" in
      "$repo_root"/.cerebro/worktrees/*) ;;
      *) continue ;;
    esac

    local name reason=""
    name="$(basename "$tree")"

    if is_verifier_tree "$name"; then
      reason="it is $verifier_name's verification tree, reset to origin/$default_branch before every use (ah-p31)"
      reclaim_cold_target "$tree" "$name"
    elif [ -n "$(git -C "$tree" status --porcelain 2>/dev/null)" ]; then
      reason="it has uncommitted or untracked changes"
    elif ! landed_on_main "$tree" "$(owner_default_branch "$owner")"; then
      reason="it holds work that is not on main yet"
    elif [ -n "$(find "$tree" -maxdepth 0 -mmin "-$STALE_MINUTES" 2>/dev/null)" ]; then
      reason="it was touched in the last $STALE_MINUTES minutes"
    fi

    if [ -n "$reason" ]; then
      echo "prune-worktrees: keeping $name — $reason"
      kept=$((kept + 1))
      is_verifier_tree "$name" || pressure_candidates+=("$name:$tree")
      continue
    fi

    if $dry_run; then
      echo "prune-worktrees: would remove $name"
      removed=$((removed + 1))
      continue
    fi

    # No `--force`. The checks above already established the tree is clean and merged; forcing would
    # override the very guard that makes this safe, and a removal that git refuses is a surprise
    # worth reporting rather than steamrolling.
    local branch
    branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if git -C "$owner" worktree remove "$tree" 2>/dev/null; then
      echo "prune-worktrees: removed $name"
      removed=$((removed + 1))
      # `-d` first, then `-D`. The fallback looks reckless and is not: `landed_on_main` has already
      # passed, so either the commits are on main — in which case `-d` succeeds and `-D` never runs —
      # or GitHub says the PR merged, and git only calls the branch unmerged because a squash merge
      # rewrote it. Without the fallback every squash-merged branch stays for ever.
      if [ -n "$branch" ]; then
        git -C "$owner" branch -d "$branch" >/dev/null 2>&1 ||
          git -C "$owner" branch -D "$branch" >/dev/null 2>&1
      fi
    else
      echo "prune-worktrees: keeping $name — git would not remove it"
      kept=$((kept + 1))
    fi
  done < <(
    git -C "$repo_root" worktree list --porcelain \
      | sed -n "s|^worktree |$repo_root\||p"
    if $sweep_submodule; then
      # The submodule's list names its own git dir first. That is not an agent worktree, and it
      # needs no guard of its own: it is not under `.cerebro/worktrees/`, so rule 1's filter above
      # already declines it.
      git -C "$submodule_root" worktree list --porcelain \
        | sed -n "s|^worktree |$submodule_root\||p"
    fi
  )

  if [ "${#pressure_candidates[@]}" -gt 0 ]; then
    reclaim_under_pressure "${pressure_candidates[@]}"
  fi

  if [ "$removed" -eq 0 ] && [ "$kept" -eq 0 ]; then
    echo "prune-worktrees: no agent worktrees"
  fi
}

if $watch; then
  while :; do
    sweep
    sleep "$WATCH_SECONDS"
  done
else
  sweep
fi
