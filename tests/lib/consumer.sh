# tests/lib/consumer.sh - the one throwaway-consumer fabricator every bash suite sources.
#
# SOURCED, NEVER EXECUTED. It lives under `tests/lib/` precisely so the gate's suite loop -
# `for t in tests/*.sh`, a non-recursive glob (tests/gate, .github/workflows/ci.yml) - can never
# pick it up and run it as a suite, where its source-time `mktemp` and trap would "pass" as an empty
# one. Its own behaviour is proved by `tests/consumer-lib.sh`, which IS a suite.
#
# Source it once, after the suite has set `repo_root`:
#
#     repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#     source "$repo_root/tests/lib/consumer.sh"
#
# It needs `bash` and `git` and nothing else - never `jq`, `bd`, `gh`, `pnpm` or `cargo`. A suite
# that needs more says so itself. That is not tidiness: `tests/launchers.sh` and
# `tests/consumer-fixture.sh` run the scripts under test with a narrowed PATH or a stub tracker, and
# a library that reached for a fourth tool would take that away from them. Every suite runs under
# `set -euo pipefail`, so everything here must too.
#
# The surface, all bash functions:
#
#   fail <msg>                    echoes "FAIL: <msg>" on stderr and exits 1
#   pass <msg>                    echoes "ok - <msg>"
#   git_q ...                     git with a test identity, so a commit needs no global config
#
#   $work_dir                     ONE physical temp directory per suite, made on source and removed
#                                 by the EXIT trap this file installs
#   cleanup_add <path>...         more paths for that trap (a suite's stub_dir, a second mktemp)
#   suite_cleanup                 a suite may DEFINE this; the trap calls it FIRST, before removing
#                                 anything (tests/agent-alive.sh kills background sleeps in it)
#
#   copy_cerebro_into <dest>      scripts, agents, skills, hooks - no emacs/, no .git
#   link_scripts <consumer> <script>...
#                                 symlinks <script> into <consumer>/.claude/cerebro/scripts/
#   consumer_new <name> [--branch <b>] [--origin] [--copy | --link <script>...]
#                                 echoes $work_dir/<name>; refuses a name it has already built
#   fixture_name <prefix>         a name no earlier call has used, for a fabricator called in a
#                                 subshell (a counter would never survive `$( )`)
#   advance_origin <name> <n>     pushes <n> commits to <name>'s origin, so the consumer is behind
#   consumer_with_submodule <name> <mount> [--branch <b>]
#                                 echoes $work_dir/<name>, with cerebro as a REAL submodule at <mount>
#
# Rules bound into it: no function ever `cd`s the caller (subshells and `git -C` only); everything a
# function creates lives under `$work_dir`, so one trap covers it; nothing runs at source time
# except the temp directory and the trap. And nothing a suite touches lives outside `$work_dir` at
# all, because `scripts/suite-runner` runs the suites at the same time (cb-x05) - a suite that
# reaches for a shared path is a suite that fails whenever another one happens to be there.

# --- the error protocol ---------------------------------------------------------------------------

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# A test identity on the command line rather than in a config: the fixture must not depend on
# whatever `user.name` the machine running the suite happens to have, and must not write one.
git_q() { git -c user.name=test -c user.email=test@example.com "$@"; }

# --- the work directory, and the one trap over it ----------------------------------------------------
#
# -P: consumer-root, sync-symlinks.sh and the sweeps all resolve paths physically, and on macOS
# `mktemp -d` hands back /var/... for /private/var/... - so a fixture that keeps the logical spelling
# compares two names for one directory and fails for no reason at all.
work_dir="$(cd "$(mktemp -d)" && pwd -P)"

_cleanup_paths=("$work_dir")

cleanup_add() {
  _cleanup_paths+=("$@")
}

_consumer_lib_cleanup() {
  # The suite's own hook first: it may need the directories that are about to go, or have processes
  # to kill that would otherwise outlive the run.
  if declare -F suite_cleanup >/dev/null; then
    suite_cleanup || true
  fi
  rm -rf "${_cleanup_paths[@]}"
}

# Installed in the SUITE's shell, which is why a migrated suite must never write its own EXIT trap:
# bash keeps one per signal, so a later `trap ... EXIT` silently replaces this and leaks everything.
# `cleanup_add` is how a suite adds to it.
trap _consumer_lib_cleanup EXIT

# --- cerebro, into a fixture --------------------------------------------------------------------------

# The submodule, narrowed to what a fixture consumer actually needs. `cp -R "$repo_root"` dragged in
# whatever happened to be present at the time - a local `.cerebro/`, the `.git`, byte-compiled
# elisp, editor droppings - so the fixture was neither hermetic nor cheap (ah-qled.11). `emacs/` is
# deliberately absent: no bash suite reads it, and it is the largest thing in the tree.
copy_cerebro_into() {
  local dest="$1" d
  mkdir -p "$dest"
  for d in scripts agents skills hooks; do
    [ -d "$repo_root/$d" ] && cp -R "$repo_root/$d" "$dest/"
  done
  return 0
}

# Symlinks rather than copies, so a fixture reads the script this checkout has right now. A suite
# that needs the shipped *file* to differ from this checkout copies it instead.
link_scripts() {
  local consumer="$1" s
  shift
  mkdir -p "$consumer/.claude/cerebro/scripts"
  for s in "$@"; do
    ln -sf "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
  done
}

# A name no earlier call has used. A fabricator wrapping consumer_new is almost always called as
# `x="$(new_fixture)"`, and a counter incremented in that subshell is lost the moment it returns -
# so every fixture got the same name and quietly re-inited the first one's directory.
fixture_name() {
  local d
  d="$(mktemp -d "$work_dir/${1:-fixture}-XXXXXX")"
  rmdir "$d"
  basename "$d"
}

# --- the consumers ------------------------------------------------------------------------------------

# consumer_new <name> [--branch <b>] [--origin] [--copy | --link <script>...]
#
# Echoes the consumer's path, `$work_dir/<name>` - physical, because $work_dir is.
#
# `git init` matters even where nothing here commits: launch-preflight compares
# `git rev-parse --show-toplevel` against the consumer and skips its checks entirely when they
# differ, so a fixture that is not a working tree would make a case silently assert nothing.
#
# The branch is a PARAMETER, and that is the point of ah-qled.3: while every fixture said `main` and
# every script said `main` the two agreed, and no suite could catch a consumer whose branch is
# called anything else.
consumer_new() {
  local name="$1"
  shift
  case "$name" in
    */*) fail "consumer_new: <name> may not contain a slash, got: $name" ;;
  esac
  # A name twice is a mistake, and a silent one: `git init` over an existing tree re-inits it and
  # the second case then runs against the first case's state. It cost this migration a red suite.
  [ -e "$work_dir/$name" ] && fail "consumer_new: $name already exists - each consumer needs its own name"

  local branch="main" origin="" copy="" links=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      --origin) origin=1; shift ;;
      --copy)   copy=1; shift ;;
      --link)   shift; links=("$@"); break ;;
      *)        fail "consumer_new: unknown argument: $1" ;;
    esac
  done

  local consumer="$work_dir/$name"

  if [ -n "$origin" ]; then
    # A CLONE of a seeded bare origin, never `git init` + `remote add`: only a clone sets
    # refs/remotes/origin/HEAD, which is exactly what tests/default-branch.sh exists to test.
    local bare="$work_dir/$name-origin.git" seed="$work_dir/$name-seed"
    git init -q --bare -b "$branch" "$bare"
    git init -q -b "$branch" "$seed"
    echo one > "$seed/file.txt"
    git_q -C "$seed" add file.txt
    git_q -C "$seed" commit -q -m init
    git_q -C "$seed" push -q "$bare" "$branch"
    git clone -q "$bare" "$consumer"
    # A second clone of the same origin, which advance_origin pushes from when a case wants the
    # consumer to be behind.
    git clone -q "$bare" "$work_dir/$name-up"
  else
    git init -q -b "$branch" "$consumer"
    git_q -C "$consumer" commit -q --allow-empty -m init
  fi

  mkdir -p "$consumer/.claude/cerebro/scripts" "$consumer/.cerebro"
  [ -n "$copy" ] && copy_cerebro_into "$consumer/.claude/cerebro"
  ((${#links[@]})) && link_scripts "$consumer" "${links[@]}"

  echo "$consumer"
}

# Adds <n> commits to <name>'s origin, so the consumer is behind by that many. It pushes whatever
# branch the clone is on, so it needs no branch argument of its own.
advance_origin() {
  local name="$1" n="$2" up="$work_dir/$1-up" i
  for ((i = 0; i < n; i++)); do
    echo "upstream $i" >> "$up/file.txt"
    git_q -C "$up" commit -q -am "upstream $i"
  done
  git_q -C "$up" push -q origin HEAD
}

# consumer_with_submodule <name> <mount> [--branch <b>]
#
# A consumer that vendors cerebro as a submodule somewhere other than `.claude/cerebro`. A REAL
# submodule, not a copied directory, and that is the supported shape rather than a convenience of
# the fixture: `scripts/consumer-root` falls back to asking git which working tree contains this
# checkout as a submodule, which answers for a submodule and nothing else. An arbitrarily-PLACED
# copy stays unsupported, and consumer-root says so.
#
# `-c protocol.file.allow=always` because git >= 2.38.1 refuses a file:// submodule without it.
consumer_with_submodule() {
  local name="$1" mount="$2"
  shift 2
  case "$name" in
    */*) fail "consumer_with_submodule: <name> may not contain a slash, got: $name" ;;
  esac

  local branch="main"
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      *)        fail "consumer_with_submodule: unknown argument: $1" ;;
    esac
  done

  local src="$work_dir/$name-cerebro-src"
  copy_cerebro_into "$src"
  git init -q "$src"
  git_q -C "$src" add -A
  git_q -C "$src" commit -q -m "cerebro"

  local consumer="$work_dir/$name"
  git init -q -b "$branch" "$consumer"
  git_q -C "$consumer" commit -q --allow-empty -m init
  git_q -C "$consumer" -c protocol.file.allow=always submodule add -q "$src" "$mount"
  mkdir -p "$consumer/.claude" "$consumer/.cerebro"

  echo "$consumer"
}
