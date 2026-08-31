#!/usr/bin/env bash
#
# Proves `scripts/cerebro-tui' - the one command a person types to open the standalone Ratatui
# fleet view - starts Cargo with the right command line, from the right directory, with the four
# roots the binary refuses to run without, and refuses rather than letting Cargo fail with a
# resolver error or the binary with a stack of missing variables.
#
# What it pins, and why each matters:
#   - the exact Cargo command: `run --release --locked', an absolute --manifest-path, and the
#     package and binary named. `--locked' is this project's rule everywhere Cargo is run: a
#     launcher that quietly re-resolved a dependency would run something no gate ever saw.
#   - the four exported roots. The binary resolves NO root of its own - `scripts/consumer-root' is
#     the one place that question is answered - so a launcher that exported three of them would
#     produce a refusal from the binary rather than a screen.
#   - that the enclosing and shared roots stay DIFFERENT in an agent worktree, and that the shared
#     one is the main checkout: state files live there, and a fleet read from a worktree's own
#     `.cerebro/state' is an empty fleet.
#   - the cwd Cargo starts in: the enclosing consumer, so `roster' and the readers run against the
#     tree the navigator is standing in.
#   - three refusals, each exit 2 with one approved line on stderr, and Cargo never reached.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Every
# fixture lives under $work_dir - suites run in parallel (cb-x05). Run from the submodule root:
#
#     bash tests/cerebro-tui.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# --- a stub `cargo' that records how it was called ----------------------------------------------

stub_dir="$work_dir/stubs"
mkdir -p "$stub_dir"
record="$work_dir/cargo-called"

cat > "$stub_dir/cargo" <<'STUB'
#!/usr/bin/env bash
# Records the cwd, every argument and the four roots the launcher must export, into the file named
# by $CEREBRO_TEST_RECORD. A real cargo would build and run the binary; this exits 0.
{
  printf 'PWD:%s\n' "$(pwd -P)"
  for a in "$@"; do printf 'ARG:%s\n' "$a"; done
  printf 'ENV:CEREBRO_CONSUMER_ROOT=%s\n' "${CEREBRO_CONSUMER_ROOT-<unset>}"
  printf 'ENV:CEREBRO_CONSUMER_SHARED_ROOT=%s\n' "${CEREBRO_CONSUMER_SHARED_ROOT-<unset>}"
  printf 'ENV:CEREBRO_CONSUMER_MOUNT=%s\n' "${CEREBRO_CONSUMER_MOUNT-<unset>}"
  printf 'ENV:CEREBRO_SCRIPTS=%s\n' "${CEREBRO_SCRIPTS-<unset>}"
} > "$CEREBRO_TEST_RECORD"
STUB
chmod +x "$stub_dir/cargo"

# A Cargo.toml beside the launcher is what makes a checkout "one that has the fleet view", so every
# fixture mount below gets one. Its contents are never read here - the stub cargo does not parse
# it - only its presence is.
give_workspace() {
  # $1 = a cerebro checkout inside a fixture consumer
  printf '[workspace]\nmembers = ["fleet-view"]\n' > "$1/Cargo.toml"
}

run_tui() {
  # Runs the launcher from directory $1, with the stub cargo first on PATH. $2 is the launcher.
  local from="$1" launcher="$2"
  shift 2
  rm -f "$record"
  ( cd "$from" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" \
      bash "$launcher" "$@" )
}

env_value() {
  # <record file> <NAME> -> the value the stub recorded for NAME
  awk -v n="ENV:$2=" 'index($0, n) == 1 { print substr($0, length(n) + 1); exit }' "$1"
}

# --- the standard mount: all four roots, the exact Cargo argv, the consumer's cwd ---------------

consumer="$(consumer_new fleet --link cerebro-tui consumer-root)"
mount="$(cd "$consumer/.claude/cerebro" && pwd -P)"
give_workspace "$mount"

run_tui "$consumer" "$consumer/.claude/cerebro/scripts/cerebro-tui"
[[ -f "$record" ]] || fail "the script never reached cargo"

args="$(grep '^ARG:' "$record" | sed 's/^ARG://' | tr '\n' ' ')"
expected_args="run --release --locked --manifest-path $mount/Cargo.toml --package cerebro-tui --bin cerebro-tui "
[[ "$args" == "$expected_args" ]] \
  || fail "expected cargo args '$expected_args', got '$args'"
pass "cargo runs the locked release binary from an absolute --manifest-path"

got_pwd="$(grep '^PWD:' "$record" | sed 's/^PWD://')"
[[ "$got_pwd" == "$consumer" ]] \
  || fail "expected cargo to start in the consumer root '$consumer', got '$got_pwd'"
pass "cargo starts in the enclosing consumer root"

[[ "$(env_value "$record" CEREBRO_CONSUMER_ROOT)" == "$consumer" ]] \
  || fail "CEREBRO_CONSUMER_ROOT: expected '$consumer', got '$(env_value "$record" CEREBRO_CONSUMER_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)" == "$consumer" ]] \
  || fail "CEREBRO_CONSUMER_SHARED_ROOT: expected '$consumer', got '$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_MOUNT)" == ".claude/cerebro" ]] \
  || fail "CEREBRO_CONSUMER_MOUNT: expected '.claude/cerebro', got '$(env_value "$record" CEREBRO_CONSUMER_MOUNT)'"
[[ "$(env_value "$record" CEREBRO_SCRIPTS)" == "$mount/scripts" ]] \
  || fail "CEREBRO_SCRIPTS: expected '$mount/scripts', got '$(env_value "$record" CEREBRO_SCRIPTS)'"
pass "a standard consumer exports all four roots"

# From a subdirectory: the same command line, the same cwd, the same roots.
mkdir -p "$consumer/sub/dir"
run_tui "$consumer/sub/dir" "$consumer/.claude/cerebro/scripts/cerebro-tui"
got_pwd="$(grep '^PWD:' "$record" | sed 's/^PWD://')"
[[ "$got_pwd" == "$consumer" ]] \
  || fail "run from a subdirectory: expected '$consumer', got '$got_pwd'"
pass "run from a subdirectory of the consumer, it still opens on the consumer root"

# --- an arbitrary submodule mount uses its own physical source ----------------------------------

vendored="$(consumer_with_submodule vendored vendor/cerebro)"
vendored_mount="$(cd "$vendored/vendor/cerebro" && pwd -P)"
cp "$repo_root/scripts/cerebro-tui" "$vendored_mount/scripts/cerebro-tui"
chmod +x "$vendored_mount/scripts/cerebro-tui"
give_workspace "$vendored_mount"

run_tui "$vendored" "$vendored_mount/scripts/cerebro-tui"
[[ -f "$record" ]] || fail "arbitrary mount: the script never reached cargo"
args="$(grep '^ARG:' "$record" | sed 's/^ARG://' | tr '\n' ' ')"
[[ "$args" == *"--manifest-path $vendored_mount/Cargo.toml"* ]] \
  || fail "arbitrary mount: expected the manifest under '$vendored_mount', got '$args'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_MOUNT)" == "vendor/cerebro" ]] \
  || fail "arbitrary mount: expected the mount 'vendor/cerebro', got '$(env_value "$record" CEREBRO_CONSUMER_MOUNT)'"
[[ "$(env_value "$record" CEREBRO_SCRIPTS)" == "$vendored_mount/scripts" ]] \
  || fail "arbitrary mount: CEREBRO_SCRIPTS should name this mount's own scripts"
pass "an arbitrary mount uses its physical source, not the standard one"

# --- an agent worktree: enclosing and shared roots differ ---------------------------------------
#
# This is the shape every implementer runs in. The shared root is where `.cerebro/state' lives, so
# a launcher that exported the worktree as both would show a fleet in which nobody is up.
worktree_consumer="$(consumer_new worktree --link cerebro-tui consumer-root)"
worktree_mount="$(cd "$worktree_consumer/.claude/cerebro" && pwd -P)"
give_workspace "$worktree_mount"
tree="$work_dir/worktree-checkout"
git_q -C "$worktree_consumer" worktree add -q -b a-bead "$tree" HEAD
tree="$(cd "$tree" && pwd -P)"
# The worktree carries its own mount, the way a committed `.claude/cerebro' symlink does in a real
# one: the launcher inside it must answer about the worktree, not about the checkout it came from.
mkdir -p "$tree/.claude"
cp -R "$worktree_mount" "$tree/.claude/cerebro"

run_tui "$tree" "$tree/.claude/cerebro/scripts/cerebro-tui"
[[ -f "$record" ]] || fail "worktree: the script never reached cargo"
[[ "$(env_value "$record" CEREBRO_CONSUMER_ROOT)" == "$tree" ]] \
  || fail "worktree: expected the enclosing root '$tree', got '$(env_value "$record" CEREBRO_CONSUMER_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)" == "$worktree_consumer" ]] \
  || fail "worktree: expected the shared root '$worktree_consumer', got '$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)'"
got_pwd="$(grep '^PWD:' "$record" | sed 's/^PWD://')"
[[ "$got_pwd" == "$tree" ]] || fail "worktree: expected cargo to start in '$tree', got '$got_pwd'"
pass "a worktree keeps its enclosing and shared roots distinct"

# --- the self-mount: cerebro running its own fleet ----------------------------------------------
#
# `.claude/cerebro' a symlink back to the checkout it lives in (cb-i3l.1). Neither the path climb
# nor the submodule probe sees that mount, so this is its own case.
self="$work_dir/self-mounted"
copy_cerebro_into "$self"
give_workspace "$self"
mkdir -p "$self/.claude"
ln -s "$self" "$self/.claude/cerebro"
git init -q -b main "$self"
git_q -C "$self" commit -q --allow-empty -m init

run_tui "$self" "$self/scripts/cerebro-tui"
[[ -f "$record" ]] || fail "self-mount: the script never reached cargo"
self_physical="$(cd "$self" && pwd -P)"
[[ "$(env_value "$record" CEREBRO_CONSUMER_ROOT)" == "$self_physical" ]] \
  || fail "self-mount: expected '$self_physical', got '$(env_value "$record" CEREBRO_CONSUMER_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_MOUNT)" == ".claude/cerebro" ]] \
  || fail "self-mount: expected the mount '.claude/cerebro', got '$(env_value "$record" CEREBRO_CONSUMER_MOUNT)'"
pass "a self-mounted checkout launches its own fleet view"

# --- an argument is a usage error ---------------------------------------------------------------
#
# Nothing is passed through: an argument would reach `cargo run' and be read as a Cargo flag.
set +e
out="$(run_tui "$consumer" "$consumer/.claude/cerebro/scripts/cerebro-tui" --wide 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "an argument: expected exit 2, got $status"
[[ "$out" == "usage: cerebro-tui (no arguments; run it from anywhere inside the consumer)" ]] \
  || fail "an argument: expected the approved usage line, got: $out"
[[ ! -f "$record" ]] || fail "an argument: cargo was reached anyway"
pass "arguments are refused with the approved usage line, before reaching cargo"

# --- outside a consumer -------------------------------------------------------------------------

loose="$work_dir/loose/scripts"
mkdir -p "$loose"
cp "$repo_root/scripts/cerebro-tui" "$loose/cerebro-tui"
cp "$repo_root/scripts/consumer-root" "$repo_root/scripts/root-hints.sh" "$loose/"
chmod +x "$loose/cerebro-tui" "$loose/consumer-root"
give_workspace "$work_dir/loose"

set +e
out="$( cd "$work_dir/loose" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" \
    bash "$loose/cerebro-tui" 2>&1 )"
status=$?
set -e
[[ $status -eq 2 ]] || fail "outside a consumer: expected exit 2, got $status"
[[ "$out" == "cerebro-tui: not inside a consumer - run this from a repository that mounts cerebro" ]] \
  || fail "outside a consumer: expected the approved line, got: $out"
[[ ! -f "$record" ]] || fail "outside a consumer: cargo was reached anyway"
pass "outside a consumer it refuses with the approved line, before reaching cargo"

# --- no cargo on PATH ---------------------------------------------------------------------------
#
# A PATH of `bash' and `dirname' alone - the shebang needs the first, consumer-root the second - so
# this cannot pass on a machine that happens to have cargo installed.
bare_dir="$work_dir/bare"
mkdir -p "$bare_dir"
ln -s "$(command -v bash)" "$bare_dir/bash"
ln -s "$(command -v dirname)" "$bare_dir/dirname"

rm -f "$record"
set +e
out="$( cd "$consumer" && PATH="$bare_dir" CEREBRO_TEST_RECORD="$record" \
    "$(command -v bash)" "$consumer/.claude/cerebro/scripts/cerebro-tui" 2>&1 )"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no cargo: expected exit 2, got $status"
[[ "$out" == "cerebro-tui: cargo is not on PATH - install Rust and Cargo" ]] \
  || fail "no cargo: expected the approved line, got: $out"
[[ ! -f "$record" ]] || fail "no cargo: something was started anyway"
pass "a missing cargo is refused with the approved line"

# --- a checkout with no workspace ---------------------------------------------------------------
#
# A vendored partial copy, or a submodule pinned before cb-vyp.1. It refuses rather than letting
# `cargo run --manifest-path' fail with a path error.
partial="$(consumer_new partial --link cerebro-tui consumer-root)"
partial_mount="$(cd "$partial/.claude/cerebro" && pwd -P)"

set +e
out="$(run_tui "$partial" "$partial/.claude/cerebro/scripts/cerebro-tui" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no workspace: expected exit 2, got $status"
[[ "$out" == "cerebro-tui: $partial_mount/Cargo.toml is missing - this checkout of cerebro has no Ratatui fleet view" ]] \
  || fail "no workspace: expected the approved line naming the absolute source, got: $out"
[[ ! -f "$record" ]] || fail "no workspace: cargo was reached anyway"
pass "a checkout with no workspace is refused, naming its absolute Cargo.toml"

suite_passed
