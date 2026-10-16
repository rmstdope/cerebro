#!/usr/bin/env bash
#
# Proves `scripts/cerebro-tui' - the one command a person types to open the standalone Ratatui
# fleet view - has Cargo build the view and then execs the built binary itself, from the right
# directory, with the four roots the binary refuses to run without, and refuses rather than letting
# Cargo fail with a resolver error or the binary with a stack of missing variables.
#
# What it pins, and why each matters:
#   - that the binary is NOT Cargo's child (ah-4n2r): nothing Cargo or rustup's proxy injects may
#     reach the view, since the view hands its environment to every session it spawns.
#   - the exact Cargo command: `build --release --locked --message-format=json-render-diagnostics',
#     an absolute --manifest-path, and the package and binary named. `--locked' is this project's rule everywhere Cargo is run: a
#     launcher that quietly re-resolved a dependency would run something no gate ever saw.
#   - the four exported roots. The binary resolves NO root of its own - `scripts/consumer-root' is
#     the one place that question is answered - so a launcher that exported three of them would
#     produce a refusal from the binary rather than a screen.
#   - that the enclosing and shared roots stay DIFFERENT in an agent worktree, and that the shared
#     one is the main checkout: state files live there, and a fleet read from a worktree's own
#     `.cerebro/state' is an empty fleet.
#   - the cwd the binary starts in: the enclosing consumer, so `roster' and the readers run against
#     the tree the navigator is standing in.
#   - three refusals, each exit 2 with one approved line on stderr, and Cargo never reached; a build
#     that names no binary, exit 2; a failed build, Cargo's own status. Neither starts a binary.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Every
# fixture lives under $work_dir - suites run in parallel (cb-x05). Run from the submodule root:
#
#     bash tests/cerebro-tui.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# --- a stub `cargo' and the binary it "builds" --------------------------------------------------
#
# The launcher builds the view with `cargo build' and then execs the binary itself (ah-4n2r), so the
# fleet view is never cargo's or rustup's child and has nothing of theirs to hand its sessions. The
# stub cargo records its own cwd and argv as CARGO_PWD and CARGO_ARG lines, and answers `build' the
# way cargo does under --message-format=json-render-diagnostics: one JSON line per artifact on
# stdout, the binary's path in "executable". It exports what cargo and rustup's proxy inject into
# anything they start, and on `run' it execs the binary with them - which is what the launcher used
# to do, and what the injection case below must never see again.
#
# The stub binary records the cwd it started in, its args and the variables that matter, as PWD,
# ARG and ENV lines - appended, so the cargo lines and the binary's share one file.
#
# CEREBRO_TEST_CARGO_EXIT makes the build fail with that status; CEREBRO_TEST_NO_EXE makes it
# report no executable at all.

stub_dir="$work_dir/stubs"
mkdir -p "$stub_dir"
record="$work_dir/cargo-called"
bin="$stub_dir/cerebro-tui-bin"

cat > "$stub_dir/cargo" <<'STUB'
#!/usr/bin/env bash
{
  printf 'CARGO_PWD:%s\n' "$(pwd -P)"
  for a in "$@"; do printf 'CARGO_ARG:%s\n' "$a"; done
} >> "$CEREBRO_TEST_RECORD"
export CARGO_PKG_NAME=cerebro-tui CARGO_MANIFEST_DIR=/somewhere RUSTUP_TOOLCHAIN=stable \
       RUSTUP_TOOLCHAIN_SOURCE=default
case "${1:-}" in
  run)
    exec "$CEREBRO_TEST_BIN" ;;
  build)
    if [ -n "${CEREBRO_TEST_CARGO_EXIT:-}" ]; then
      echo "error: could not compile cerebro-tui" >&2
      exit "$CEREBRO_TEST_CARGO_EXIT"
    fi
    printf '{"reason":"compiler-artifact","target":{"name":"cerebro_tui","kind":["lib"]},"executable":null,"fresh":true}\n'
    if [ -z "${CEREBRO_TEST_NO_EXE:-}" ]; then
      printf '{"reason":"compiler-artifact","target":{"name":"cerebro-tui","kind":["bin"]},"executable":"%s","fresh":false}\n' "$CEREBRO_TEST_BIN"
    fi
    printf '{"reason":"build-finished","success":true}\n'
    ;;
esac
STUB
chmod +x "$stub_dir/cargo"

cat > "$bin" <<'STUB'
#!/usr/bin/env bash
{
  printf 'PWD:%s\n' "$(pwd -P)"
  for a in "$@"; do printf 'ARG:%s\n' "$a"; done
  printf 'ENV:CEREBRO_CONSUMER_ROOT=%s\n' "${CEREBRO_CONSUMER_ROOT-<unset>}"
  printf 'ENV:CEREBRO_CONSUMER_SHARED_ROOT=%s\n' "${CEREBRO_CONSUMER_SHARED_ROOT-<unset>}"
  printf 'ENV:CEREBRO_CONSUMER_MOUNT=%s\n' "${CEREBRO_CONSUMER_MOUNT-<unset>}"
  printf 'ENV:CEREBRO_SCRIPTS=%s\n' "${CEREBRO_SCRIPTS-<unset>}"
  printf 'ENV:CARGO_PKG_NAME=%s\n' "${CARGO_PKG_NAME-<unset>}"
  printf 'ENV:CARGO_MANIFEST_DIR=%s\n' "${CARGO_MANIFEST_DIR-<unset>}"
  printf 'ENV:RUSTUP_TOOLCHAIN=%s\n' "${RUSTUP_TOOLCHAIN-<unset>}"
  printf 'ENV:RUSTUP_TOOLCHAIN_SOURCE=%s\n' "${RUSTUP_TOOLCHAIN_SOURCE-<unset>}"
} >> "$CEREBRO_TEST_RECORD"
STUB
chmod +x "$bin"

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
  ( cd "$from" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" CEREBRO_TEST_BIN="$bin" \
      bash "$launcher" "$@" )
}

env_value() {
  # <record file> <NAME> -> the value the stub recorded for NAME
  awk -v n="ENV:$2=" 'index($0, n) == 1 { print substr($0, length(n) + 1); exit }' "$1"
}

# --- the standard mount: all four roots, the exact Cargo argv, the consumer's cwd ---------------

consumer="$(consumer_new fleet --link cerebro-tui consumer-root)"
mount="$(cd "$consumer/.cerebro/cerebro" && pwd -P)"
give_workspace "$mount"

run_tui "$consumer" "$consumer/.cerebro/cerebro/scripts/cerebro-tui"
[[ -f "$record" ]] || fail "the script never reached cargo"

args="$(grep '^CARGO_ARG:' "$record" | sed 's/^CARGO_ARG://' | tr '\n' ' ')"
expected_args="build --release --locked --message-format=json-render-diagnostics --manifest-path $mount/Cargo.toml --package cerebro-tui --bin cerebro-tui "
[[ "$args" == "$expected_args" ]] \
  || fail "expected cargo args '$expected_args', got '$args'"
pass "cargo builds the locked release binary from an absolute --manifest-path"

got_pwd="$(grep '^CARGO_PWD:' "$record" | sed 's/^CARGO_PWD://')"
[[ "$got_pwd" == "$consumer" ]] \
  || fail "expected cargo to start in the consumer root '$consumer', got '$got_pwd'"
got_pwd="$(grep '^PWD:' "$record" | sed 's/^PWD://')"
[[ "$got_pwd" == "$consumer" ]] \
  || fail "expected the binary to start in the consumer root '$consumer', got '$got_pwd'"
! grep -q '^ARG:' "$record" || fail "the binary should be started with no arguments, got: $(grep '^ARG:' "$record")"
pass "cargo and the binary both start in the enclosing consumer root, the binary with no arguments"

# THE POINT OF ah-4n2r: the binary is exec'd by the launcher, not by cargo, so nothing cargo or
# rustup's proxy injects reaches the fleet view - or, through it, any session it spawns.
for n in CARGO_PKG_NAME CARGO_MANIFEST_DIR RUSTUP_TOOLCHAIN RUSTUP_TOOLCHAIN_SOURCE; do
  [[ "$(env_value "$record" "$n")" == "<unset>" ]] \
    || fail "the fleet view inherited $n=$(env_value "$record" "$n") from cargo"
done
pass "the fleet view is not cargo's child: no cargo or rustup injection reaches it"

[[ "$(env_value "$record" CEREBRO_CONSUMER_ROOT)" == "$consumer" ]] \
  || fail "CEREBRO_CONSUMER_ROOT: expected '$consumer', got '$(env_value "$record" CEREBRO_CONSUMER_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)" == "$consumer" ]] \
  || fail "CEREBRO_CONSUMER_SHARED_ROOT: expected '$consumer', got '$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_MOUNT)" == ".cerebro/cerebro" ]] \
  || fail "CEREBRO_CONSUMER_MOUNT: expected '.cerebro/cerebro', got '$(env_value "$record" CEREBRO_CONSUMER_MOUNT)'"
[[ "$(env_value "$record" CEREBRO_SCRIPTS)" == "$mount/scripts" ]] \
  || fail "CEREBRO_SCRIPTS: expected '$mount/scripts', got '$(env_value "$record" CEREBRO_SCRIPTS)'"
pass "a standard consumer exports all four roots"

# From a subdirectory: the same command line, the same cwd, the same roots.
mkdir -p "$consumer/sub/dir"
run_tui "$consumer/sub/dir" "$consumer/.cerebro/cerebro/scripts/cerebro-tui"
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
args="$(grep '^CARGO_ARG:' "$record" | sed 's/^CARGO_ARG://' | tr '\n' ' ')"
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
worktree_mount="$(cd "$worktree_consumer/.cerebro/cerebro" && pwd -P)"
give_workspace "$worktree_mount"
tree="$work_dir/worktree-checkout"
git_q -C "$worktree_consumer" worktree add -q -b a-bead "$tree" HEAD
tree="$(cd "$tree" && pwd -P)"
# The worktree carries its own mount, the way a committed `.cerebro/cerebro' symlink does in a real
# one: the launcher inside it must answer about the worktree, not about the checkout it came from.
mkdir -p "$tree/.cerebro"
cp -R "$worktree_mount" "$tree/.cerebro/cerebro"

run_tui "$tree" "$tree/.cerebro/cerebro/scripts/cerebro-tui"
[[ -f "$record" ]] || fail "worktree: the script never reached cargo"
[[ "$(env_value "$record" CEREBRO_CONSUMER_ROOT)" == "$tree" ]] \
  || fail "worktree: expected the enclosing root '$tree', got '$(env_value "$record" CEREBRO_CONSUMER_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)" == "$worktree_consumer" ]] \
  || fail "worktree: expected the shared root '$worktree_consumer', got '$(env_value "$record" CEREBRO_CONSUMER_SHARED_ROOT)'"
got_pwd="$(grep '^PWD:' "$record" | sed 's/^PWD://')"
[[ "$got_pwd" == "$tree" ]] || fail "worktree: expected the binary to start in '$tree', got '$got_pwd'"
pass "a worktree keeps its enclosing and shared roots distinct"

# --- the self-mount: cerebro running its own fleet ----------------------------------------------
#
# `.cerebro/cerebro' a symlink back to the checkout it lives in (cb-i3l.1). Neither the path climb
# nor the submodule probe sees that mount, so this is its own case.
self="$work_dir/self-mounted"
copy_cerebro_into "$self"
give_workspace "$self"
mkdir -p "$self/.claude"
mkdir -p "$self/.cerebro"
ln -s "$self" "$self/.cerebro/cerebro"
git init -q -b main "$self"
git_q -C "$self" commit -q --allow-empty -m init

run_tui "$self" "$self/scripts/cerebro-tui"
[[ -f "$record" ]] || fail "self-mount: the script never reached cargo"
self_physical="$(cd "$self" && pwd -P)"
[[ "$(env_value "$record" CEREBRO_CONSUMER_ROOT)" == "$self_physical" ]] \
  || fail "self-mount: expected '$self_physical', got '$(env_value "$record" CEREBRO_CONSUMER_ROOT)'"
[[ "$(env_value "$record" CEREBRO_CONSUMER_MOUNT)" == ".cerebro/cerebro" ]] \
  || fail "self-mount: expected the mount '.cerebro/cerebro', got '$(env_value "$record" CEREBRO_CONSUMER_MOUNT)'"
pass "a self-mounted checkout launches its own fleet view"

# --- an argument is a usage error ---------------------------------------------------------------
#
# Nothing is passed through: the binary takes no arguments, and a launcher that forwarded them would
# be a second, undocumented interface to it.
set +e
out="$(run_tui "$consumer" "$consumer/.cerebro/cerebro/scripts/cerebro-tui" --wide 2>&1)"
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
out="$( cd "$work_dir/loose" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" CEREBRO_TEST_BIN="$bin" \
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
    "$(command -v bash)" "$consumer/.cerebro/cerebro/scripts/cerebro-tui" 2>&1 )"
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
# `cargo build --manifest-path' fail with a path error.
partial="$(consumer_new partial --link cerebro-tui consumer-root)"
partial_mount="$(cd "$partial/.cerebro/cerebro" && pwd -P)"

set +e
out="$(run_tui "$partial" "$partial/.cerebro/cerebro/scripts/cerebro-tui" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no workspace: expected exit 2, got $status"
[[ "$out" == "cerebro-tui: $partial_mount/Cargo.toml is missing - this checkout of cerebro has no Ratatui fleet view" ]] \
  || fail "no workspace: expected the approved line naming the absolute source, got: $out"
[[ ! -f "$record" ]] || fail "no workspace: cargo was reached anyway"
pass "a checkout with no workspace is refused, naming its absolute Cargo.toml"

# --- a failed build: cargo's own status, and nothing started -------------------------------------
#
# Cargo has already put the diagnostics on stderr; the launcher adds nothing and starts nothing.
rm -f "$record"
set +e
out="$( cd "$consumer" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" CEREBRO_TEST_BIN="$bin" \
    CEREBRO_TEST_CARGO_EXIT=101 bash "$consumer/.cerebro/cerebro/scripts/cerebro-tui" 2>&1 )"
status=$?
set -e
[[ $status -eq 101 ]] || fail "a failed build: expected cargo's exit 101, got $status"
[[ "$out" == "error: could not compile cerebro-tui" ]] \
  || fail "a failed build: expected cargo's own diagnostics and nothing else, got: $out"
! grep -q '^PWD:' "$record" || fail "a failed build: a binary was started anyway"
pass "a failed build exits with cargo's status and starts nothing"

# --- a build that names no binary ---------------------------------------------------------------
rm -f "$record"
set +e
out="$( cd "$consumer" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" CEREBRO_TEST_BIN="$bin" \
    CEREBRO_TEST_NO_EXE=1 bash "$consumer/.cerebro/cerebro/scripts/cerebro-tui" 2>&1 )"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no executable: expected exit 2, got $status"
[[ "$out" == "cerebro-tui: cargo built nothing to run - expected the cerebro-tui binary" ]] \
  || fail "no executable: expected the one refusal line, got: $out"
! grep -q '^PWD:' "$record" || fail "no executable: a binary was started anyway"
pass "a build that reports no binary is refused with one line"

suite_passed
