#!/usr/bin/env bash
#
# Proves `scripts/cerebro' - the one command a person types to open the fleet view - starts Emacs
# with the right command line, from the right directory, and refuses rather than letting Emacs
# fail with a backtrace.
#
# What it pins, and why each matters:
#   - the exact flags: an absolute -L, `-l cerebro -f cerebro', --no-splash, and NO -q/-Q. The
#     user's own init is where vterm comes from, and vterm is how the fleet view holds live
#     sessions, so -q would quietly cost the view its sessions.
#   - the cwd Emacs starts in: cerebro--repo-root climbs from `default-directory', so the consumer
#     root is what makes the fleet view resolve - from the root and from any subdirectory of it.
#   - the EMACS override, for a macOS user whose Emacs.app is not on PATH.
#   - four refusals, each exit 2 with one line on stderr, and Emacs never reached.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Every
# fixture lives under $work_dir - suites run in parallel (cb-x05). Run from the submodule root:
#
#     bash tests/cerebro.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# --- the consumer, and a stub `emacs' that records how it was called ----------------------------
#
# `--link cerebro consumer-root' symlinks both scripts from this checkout, so the fixture reads
# them as they are right now. link_scripts does not link emacs/, and the script refuses without
# emacs/cerebro.el, so that link is made here.
consumer="$(consumer_new fleet --link cerebro consumer-root)"
ln -s "$repo_root/emacs" "$consumer/.claude/cerebro/emacs"

stub_dir="$work_dir/stubs"
mkdir -p "$stub_dir"
record="$work_dir/emacs-called"

make_stub() {
  # $1 = path. Writes the cwd and every argument to the file named by $CEREBRO_TEST_RECORD, which
  # is what every assertion below reads. A real Emacs would open a frame; this exits 0.
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
{
  printf 'PWD:%s\n' "$(pwd -P)"
  for a in "$@"; do printf 'ARG:%s\n' "$a"; done
} > "$CEREBRO_TEST_RECORD"
STUB
  chmod +x "$1"
}

make_stub "$stub_dir/emacs"

run_cerebro() {
  # Runs the script from $1 with the stub first on PATH, and never lets a real emacs be found.
  local from="$1"
  shift
  rm -f "$record"
  ( cd "$from" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" \
      bash "$consumer/.claude/cerebro/scripts/cerebro" "$@" )
}

# The -L value the script must pass: the mount through `pwd -P' (which is how the script derives
# its own SOURCE_ROOT) with `/emacs' on the end - never string-concatenated from $consumer, so
# this suite is not green on Linux and red on the navigator's Mac, where $TMPDIR is a symlink.
expected_load_path="$(cd "$consumer/.claude/cerebro" && pwd -P)/emacs"

# --- the command line -----------------------------------------------------------------------------
run_cerebro "$consumer"

[[ -f "$record" ]] || fail "the script never reached emacs"

args="$(grep '^ARG:' "$record" | sed 's/^ARG://' | tr '\n' ' ')"
expected_args="--no-splash -L $expected_load_path -l cerebro -f cerebro "
[[ "$args" == "$expected_args" ]] \
  || fail "expected emacs args '$expected_args', got '$args'"
pass "emacs is run with --no-splash, an absolute -L, -l cerebro and -f cerebro"

grep -q '^ARG:-[qQ]$' "$record" \
  && fail "the script passed -q or -Q: the user's init is where vterm comes from"
pass "neither -q nor -Q is passed"

got_pwd="$(grep '^PWD:' "$record" | sed 's/^PWD://')"
[[ "$got_pwd" == "$consumer" ]] \
  || fail "expected emacs to start in the consumer root '$consumer', got '$got_pwd'"
pass "emacs starts in the consumer root"

# --- from a subdirectory: same command line, same cwd ---------------------------------------------
mkdir -p "$consumer/sub/dir"
run_cerebro "$consumer/sub/dir"

got_pwd="$(grep '^PWD:' "$record" | sed 's/^PWD://')"
[[ "$got_pwd" == "$consumer" ]] \
  || fail "run from a subdirectory: expected the consumer root '$consumer', got '$got_pwd'"
args="$(grep '^ARG:' "$record" | sed 's/^ARG://' | tr '\n' ' ')"
[[ "$args" == "$expected_args" ]] \
  || fail "run from a subdirectory: expected '$expected_args', got '$args'"
pass "run from a subdirectory of the consumer, it still opens on the consumer root"

# --- $EMACS wins over the one on PATH -------------------------------------------------------------
other_dir="$work_dir/other"
mkdir -p "$other_dir"
make_stub "$other_dir/my-emacs"
other_record="$work_dir/other-called"

rm -f "$record" "$other_record"
( cd "$consumer" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$other_record" \
    EMACS="$other_dir/my-emacs" bash "$consumer/.claude/cerebro/scripts/cerebro" )

[[ -f "$other_record" ]] || fail "EMACS was ignored: the binary it names was never run"
pass "EMACS names the binary that is run"

# --- no emacs anywhere: one line, exit 2, and nothing started -------------------------------------
#
# A PATH of only `bash' and `dirname' - the shebang needs the first, consumer-root the second - so
# this cannot pass on a machine that happens to have /usr/bin/emacs. Deliberately no `emacs' here.
bare_dir="$work_dir/bare"
mkdir -p "$bare_dir"
ln -s "$(command -v bash)" "$bare_dir/bash"
ln -s "$(command -v dirname)" "$bare_dir/dirname"

rm -f "$record"
set +e
out="$( cd "$consumer" && PATH="$bare_dir" CEREBRO_TEST_RECORD="$record" \
    "$(command -v bash)" "$consumer/.claude/cerebro/scripts/cerebro" 2>&1 )"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no emacs on PATH: expected exit 2, got $status"
echo "$out" | grep -q "emacs is not on PATH" \
  || fail "no emacs on PATH: expected the message to say so, got: $out"
[[ ! -f "$record" ]] || fail "no emacs on PATH: something was started anyway"
pass "refuses with one line when emacs is not on PATH"

# --- an argument is a usage error -----------------------------------------------------------------
#
# Nothing is passed through: an argument after `-f cerebro' would be silently opened as a file.
set +e
out="$(run_cerebro "$consumer" some-file 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "an argument: expected exit 2, got $status"
echo "$out" | grep -q "^usage:" || fail "an argument: expected a usage line, got: $out"
[[ ! -f "$record" ]] || fail "an argument: emacs was reached anyway"
pass "refuses any argument with a usage line, before reaching emacs"

# --- outside a consumer ---------------------------------------------------------------------------
loose="$work_dir/loose/scripts"
mkdir -p "$loose"
cp "$repo_root/scripts/cerebro" "$loose/cerebro"
cp "$repo_root/scripts/consumer-root" "$repo_root/scripts/root-hints.sh" "$loose/"
chmod +x "$loose/cerebro" "$loose/consumer-root"

rm -f "$record"
set +e
out="$( cd "$work_dir/loose" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" \
    bash "$loose/cerebro" 2>&1 )"
status=$?
set -e
[[ $status -eq 2 ]] || fail "outside a consumer: expected exit 2, got $status"
echo "$out" | grep -q "not inside a consumer" \
  || fail "outside a consumer: expected the message to say so, got: $out"
[[ ! -f "$record" ]] || fail "outside a consumer: emacs was reached anyway"
pass "refuses outside a consumer, before reaching emacs"

# --- a checkout with no emacs/cerebro.el ----------------------------------------------------------
#
# A vendored partial copy. It refuses rather than letting `-l cerebro' fail with a backtrace.
partial="$(consumer_new partial --link cerebro consumer-root)"

rm -f "$record"
set +e
out="$( cd "$partial" && PATH="$stub_dir:$PATH" CEREBRO_TEST_RECORD="$record" \
    bash "$partial/.claude/cerebro/scripts/cerebro" 2>&1 )"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no elisp: expected exit 2, got $status"
echo "$out" | grep -q "cerebro.el is missing" \
  || fail "no elisp: expected the message to name cerebro.el, got: $out"
[[ ! -f "$record" ]] || fail "no elisp: emacs was reached anyway"
pass "refuses when this checkout of cerebro has no emacs/cerebro.el"

echo "all cerebro tests passed"
