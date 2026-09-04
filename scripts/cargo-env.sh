# scripts/cargo-env.sh - the one place bash answers which variables cargo put in this environment.
#
# SOURCED, NEVER EXECUTED. Like scripts/root-hints.sh and scripts/session-marker.sh beside it, it
# has no `set -euo pipefail' of its own and defines functions only, so sourcing it changes nothing
# about the caller's shell but the names it can call. BUILTINS ALONE - no grep, sed, awk, env or
# sort - because it runs on the launch path cb-ue0 spent a whole bead taking from sixteen forks to
# one, and because tests/launchers.sh runs that path with a PATH holding `dirname' and `bash' alone.
#
# WHY IT EXISTS (cb-6fu). `scripts/cerebro-tui' execs `cargo run', so the Ratatui fleet view is a
# CHILD OF CARGO, and cargo hands its child eighteen variables: CARGO, the CARGO_PKG_* family,
# CARGO_MANIFEST_DIR and friends - and every key of the `[env]' table in whatever .cargo/config.toml
# cargo discovered from its cwd, which is the CONSUMER's. The view then spawns sessions with its own
# environment (fleet-view/src/session.rs, and `cerebro--launch-command' in Emacs), so every agent
# inherits the lot. In atlantis-hud that meant TS_RS_EXPORT_DIR pointing at the navigator's shared
# checkout - the consumer's `[env]' entry carries no `force = true', and an inherited value beats a
# non-forced config entry in every worktree - so every agent's `cargo test' wrote its generated
# bindings into the main checkout with no cwd mistake required (ah-79ca, ah-16pb).
#
# The strip belongs in `scripts/launch': the one place a session is started, the thing BOTH views
# spawn, and correct whoever the parent was - including a `launch' typed by hand in a shell that has
# run cargo. Putting it in the views would be two copies of one decision.
#
# ONE FORK, and it is deliberate: `cerebro_cargo_config_env_names' normalises its argument with
# `$(cd "$dir" && pwd)', which is a subshell. The walk would work on the given path, but a relative
# or symlinked one would then climb a different chain of ancestors than cargo itself did, and a
# reader that finds the wrong config is worse than a reader that costs one fork. So "builtins alone"
# is about what this library needs ON PATH - nothing but bash - rather than about forking never.
#
# ITS LIMITATION, stated rather than discovered: the `[env]' reader needs key NAMES only, never
# values, which is what makes a builtins-only parser adequate. A key whose value spans several lines,
# or one written as a dotted key outside the table (`env.FOO = ...'), is not seen. Neither shape is
# what cargo's own documentation shows, and a name this misses is exactly today's behaviour rather
# than a regression.
#
# Its cases are tests/cargo-env.sh; the launcher's own are in tests/launchers.sh.

# Is NAME one that cargo itself injects into a child process?
#   $1 = variable name
#   returns 0 (yes, clear it) / 1 (no, leave it alone)
#
# A DENYLIST, deliberately not the prefix `CARGO_*'. CARGO_HOME and CARGO_TARGET_DIR are the
# navigator's own settings that cargo merely passes through: clearing CARGO_TARGET_DIR would send
# every agent's build to a different target directory and cost a full rebuild per session, in a
# repository whose `disk_floor_gb' exists because build trees are already the expensive thing. The
# two PREFIX rules are safe as prefixes because nobody configures those families by hand; they are
# what covers a future cargo release adding another CARGO_PKG_ name without a bead.
cerebro_cargo_injected_name_p() {
  case "$1" in
    CARGO) return 0 ;;
    CARGO_MANIFEST_DIR|CARGO_MANIFEST_PATH) return 0 ;;
    CARGO_CRATE_NAME|CARGO_BIN_NAME) return 0 ;;
    CARGO_PRIMARY_PACKAGE|CARGO_TARGET_TMPDIR) return 0 ;;
    CARGO_PKG_*|CARGO_BIN_EXE_*) return 0 ;;
    *) return 1 ;;
  esac
}

# The key names of the `[env]' table in every cargo config discovered from DIR upward, plus the one
# in CARGO_HOME (or $HOME/.cargo). One name per line, in declaration order, no duplicates.
#   $1 = directory to walk up from (may be empty or missing: prints nothing, returns 0)
#
# The candidates, each read if it exists: <dir>/.cargo/config.toml then <dir>/.cargo/config (the
# legacy name, read ONLY when the .toml is absent - cargo prefers the .toml and warns when both
# exist, so reading both would return a key twice); then the same pair in each ancestor, up to `/';
# then ${CARGO_HOME:-$HOME/.cargo}.
cerebro_cargo_config_env_names() {
  local dir="${1:-}"
  local -a files=()
  local d prev

  if [ -n "$dir" ] && [ -d "$dir" ]; then
    d="$(cd "$dir" 2>/dev/null && pwd)" || d=""
    while [ -n "$d" ]; do
      if [ -f "$d/.cargo/config.toml" ]; then
        files[${#files[@]}]="$d/.cargo/config.toml"
      elif [ -f "$d/.cargo/config" ]; then
        files[${#files[@]}]="$d/.cargo/config"
      fi
      prev="$d"
      d="${d%/*}"
      [ -z "$d" ] && d="/"
      [ "$d" = "$prev" ] && break
    done
  fi

  local home="${CARGO_HOME:-${HOME:-}/.cargo}"
  if [ -n "$home" ]; then
    if [ -f "$home/config.toml" ]; then
      files[${#files[@]}]="$home/config.toml"
    elif [ -f "$home/config" ]; then
      files[${#files[@]}]="$home/config"
    fi
  fi

  local seen=" " f line table key
  for f in ${files+"${files[@]}"}; do
    table=""
    # `read' with no IFS change would still split; IFS= keeps the line whole, and the `|| [ -n ... ]'
    # is what reads a final line with no trailing newline.
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ ^[[:space:]]*\[([^]]*)\][[:space:]]*$ ]]; then
        table="${BASH_REMATCH[1]}"
        continue
      fi
      [ "$table" = "env" ] || continue
      if [[ $line =~ ^[[:space:]]*\"?([A-Za-z_][A-Za-z0-9_]*)\"?[[:space:]]*= ]]; then
        key="${BASH_REMATCH[1]}"
        case "$seen" in *" $key "*) continue ;; esac
        seen="$seen$key "
        printf '%s\n' "$key"
      fi
    done < "$f"
  done
  return 0
}

# Is NAME one no strip may ever remove?
#   $1 = variable name
#   returns 0 (protected) / 1 (fair game)
#
# A `[env]' table naming PATH is legal cargo config, and clearing it would leave the session unable
# to find its own agent CLI. PWD, OLDPWD and SHLVL are here because `unset' on a name that is also a
# shell variable removes BOTH, and unsetting those breaks the shell's own bookkeeping rather than
# merely a child's environment. CARGO_HOME and CARGO_TARGET_DIR are the navigator's own settings;
# CEREBRO_* and BEADS_* are the launch path's own, set deliberately a few lines above the strip.
cerebro_cargo_protected_name_p() {
  case "$1" in
    PATH|HOME|SHELL|USER|LOGNAME|TERM|TMPDIR|LANG|LC_ALL|PWD|OLDPWD|SHLVL) return 0 ;;
    CARGO_HOME|CARGO_TARGET_DIR) return 0 ;;
    CEREBRO_*|BEADS_*) return 0 ;;
    *) return 1 ;;
  esac
}

# Unset every exported variable that either predicate above claims, except the protected names.
# Prints the names it removed, one per line: the cargo-injected ones first (whatever order
# `compgen -e' gave), then the config `[env]' ones in declaration order. It also leaves them in two
# arrays, `cerebro_cargo_stripped_injected' and `cerebro_cargo_stripped_config', reset on entry.
#   $1 = directory to walk up from, for the [env] half
#
# THE ARRAYS ARE NOT DECORATION, and a caller wanting to report what went must read them rather than
# the printed lines. `unset' takes effect in the shell that runs it, so a caller consuming this
# function's stdout - `$(...)' or `while read ... < <(...)' - runs the whole strip in a SUBSHELL and
# clears nothing at all, while printing a perfectly convincing list of what it did not do. That is
# how this landed the first time (cb-6fu); the printed lines survive because the suite reads them
# from inside a subshell it has already accepted.
#
# `compgen -e' EXITS 1 WHEN IT PRINTS NOTHING, and every caller of this runs under `set -euo
# pipefail'. It is read through a process substitution with `|| true' - never `compgen -e | while
# read', which also builds the result in a subshell that is gone by the next line (the trap
# `scripts/launch' already documents about its own --argv reader).
cerebro_strip_cargo_env() {
  local dir="${1:-}"
  local name
  cerebro_cargo_stripped_injected=()
  cerebro_cargo_stripped_config=()

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cerebro_cargo_protected_name_p "$name" && continue
    if cerebro_cargo_injected_name_p "$name"; then
      unset "$name"
      cerebro_cargo_stripped_injected[${#cerebro_cargo_stripped_injected[@]}]="$name"
      printf '%s\n' "$name"
    fi
  done < <(compgen -e || true)

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cerebro_cargo_protected_name_p "$name" && continue
    cerebro_cargo_injected_name_p "$name" && continue   # already reported by the loop above
    if [ -n "${!name+set}" ]; then
      unset "$name"
      cerebro_cargo_stripped_config[${#cerebro_cargo_stripped_config[@]}]="$name"
      printf '%s\n' "$name"
    fi
  done < <(cerebro_cargo_config_env_names "$dir")

  return 0
}
