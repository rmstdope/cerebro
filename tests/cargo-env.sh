#!/usr/bin/env bash
#
# Proves `scripts/cargo-env.sh` — the one place bash answers which variables cargo put into this
# process's environment (cb-6fu). The fleet view is a `cargo run` child, so without the strip every
# session it starts inherits cargo's own injections AND the consumer's `.cargo/config.toml` `[env]`
# table, and writes generated files into the navigator's shared checkout.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Every
# fixture lives under `$work_dir`, which is what keeps the parallel suite runner safe. Run from the
# submodule root:
#
#     bash tests/cargo-env.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# THE SUITE RUNS INSIDE A POLLUTED SESSION. An implementer running this is itself a session the
# fleet view started, so its own environment already carries cargo's eighteen variables - and an
# assertion counting what the strip removed would count those too, green in CI and red on the
# navigator's machine (the exact shape ah-dy4x cost). Clear them here; each case exports what it
# needs.
for _n in $(compgen -e || true); do
  case "$_n" in
    CARGO_HOME|CARGO_TARGET_DIR) ;;
    CARGO|CARGO_*|TS_RS_EXPORT_DIR) unset "$_n" ;;
  esac
done
unset _n

source "$repo_root/scripts/cargo-env.sh"

# --- the names cargo injects are the ones cleared -----------------------------------------------
#
# A denylist, deliberately not the prefix `CARGO_*': clearing a navigator's CARGO_TARGET_DIR costs a
# full rebuild per session, and leaving a stray CARGO_PKG_README costs nothing.

for name in CARGO CARGO_MANIFEST_DIR CARGO_MANIFEST_PATH \
            CARGO_PKG_NAME CARGO_PKG_VERSION CARGO_PKG_SOMETHING_NEW \
            CARGO_BIN_EXE_probe CARGO_CRATE_NAME CARGO_BIN_NAME \
            CARGO_PRIMARY_PACKAGE CARGO_TARGET_TMPDIR; do
  cerebro_cargo_injected_name_p "$name" \
    || fail "cargo_env: $name is one cargo injects and should be cleared"
done
pass "cargo_env: every name cargo injects is accepted"

for name in CARGO_HOME CARGO_TARGET_DIR CARGO_BUILD_JOBS CARGO_NET_OFFLINE \
            CARGO_TERM_COLOR CARGO_INCREMENTAL CARGO_REGISTRIES_MINE_INDEX \
            CARGO_HTTP_PROXY CARGO_UNSTABLE_BUILD_STD CARGOISH MY_CARGO PATH; do
  cerebro_cargo_injected_name_p "$name" \
    && fail "cargo_env: $name is the navigator's or nothing to do with cargo; it must be kept"
done
pass "cargo_env: the navigator's own settings and lookalike names are kept"

# --- an [env] table's keys are read, and nothing else's -----------------------------------------
#
# Cargo discovers configuration by walking up from its working directory, so the file that produced
# the leak is the CONSUMER's. The reader wants key names only, never values.

# The navigator's own ${CARGO_HOME}/config.toml is a candidate the reader consults last, and on a
# real machine it may exist and declare an [env] table. Point it at an empty directory so every
# assertion below is about the fixture and nothing else.
export CARGO_HOME="$work_dir/empty-cargo-home"
mkdir -p "$CARGO_HOME"

cfg_root="$work_dir/cargo-config"
mkdir -p "$cfg_root/.cargo" "$cfg_root/sub/dir"
cat > "$cfg_root/.cargo/config.toml" <<'CFG'
# a comment, and a blank line follow

[env]
PLAIN_ONE = "plain"
TS_RS_EXPORT_DIR = { value = "generated", relative = true }
"QUOTED_KEY" = "q"

[build]
jobs = 4
CFG

names="$(cerebro_cargo_config_env_names "$cfg_root/sub/dir")"
expected="$(printf 'PLAIN_ONE\nTS_RS_EXPORT_DIR\nQUOTED_KEY\n')"
[ "$names" = "$expected" ] \
  || fail "cargo_env: expected the four keys in declaration order, got: $names"
pass "cargo_env: an [env] table's keys are read from an ancestor, in order, and [build] is not"

# The legacy filename, read only when the .toml is absent - cargo prefers the .toml and warns when
# both exist, so reading both would return a key twice and name it twice on stderr.
legacy="$work_dir/cargo-legacy"
mkdir -p "$legacy/.cargo"
printf '[env]\nLEGACY_KEY = "l"\n' > "$legacy/.cargo/config"
[ "$(cerebro_cargo_config_env_names "$legacy")" = "LEGACY_KEY" ] \
  || fail "cargo_env: a legacy .cargo/config should be read when the .toml is absent"
printf '[env]\nTOML_KEY = "t"\n' > "$legacy/.cargo/config.toml"
[ "$(cerebro_cargo_config_env_names "$legacy")" = "TOML_KEY" ] \
  || fail "cargo_env: .cargo/config.toml wins over the legacy .cargo/config, alone"
pass "cargo_env: the legacy filename is read only when the .toml is absent"

empty_dir="$work_dir/no-cargo-config"
mkdir -p "$empty_dir"
[ -z "$(cerebro_cargo_config_env_names "$empty_dir")" ] \
  || fail "cargo_env: a tree with no cargo config should print nothing"
[ -z "$(cerebro_cargo_config_env_names "")" ] \
  || fail "cargo_env: an empty directory argument should print nothing"
cerebro_cargo_config_env_names "" >/dev/null \
  || fail "cargo_env: an empty directory argument should still return 0"
pass "cargo_env: no config, and no directory at all, are both silent successes"

# --- the strip clears both halves and protects the rest -----------------------------------------

strip_out="$(
  export CARGO_MANIFEST_DIR=/x CARGO_PKG_NAME=y CARGO_HOME="$CARGO_HOME" \
         CARGO_TARGET_DIR=/t TS_RS_EXPORT_DIR=/leak CEREBRO_CONSUMER_ROOT=/c
  cerebro_strip_cargo_env "$cfg_root/sub/dir"
  printf -- '--\n'
  for n in CARGO_MANIFEST_DIR CARGO_PKG_NAME TS_RS_EXPORT_DIR CARGO_HOME CARGO_TARGET_DIR CEREBRO_CONSUMER_ROOT; do
    printf '%s=%s\n' "$n" "$(eval "printf '%s' \"\${$n:-<unset>}\"")"
  done
)"
removed="${strip_out%%--*}"
survivors="${strip_out#*--$'\n'}"

for n in CARGO_MANIFEST_DIR CARGO_PKG_NAME TS_RS_EXPORT_DIR; do
  grep -q "^$n=<unset>\$" <<<"$survivors" || fail "cargo_env: $n should have been unset, got: $survivors"
  grep -q "^$n\$" <<<"$removed" || fail "cargo_env: $n should have been reported removed, got: $removed"
done
grep -q "^CARGO_HOME=$CARGO_HOME\$" <<<"$survivors" || fail "cargo_env: CARGO_HOME must survive: $survivors"
grep -q '^CARGO_TARGET_DIR=/t$' <<<"$survivors" || fail "cargo_env: CARGO_TARGET_DIR must survive: $survivors"
grep -q '^CEREBRO_CONSUMER_ROOT=/c$' <<<"$survivors" || fail "cargo_env: CEREBRO_* must survive: $survivors"
[ "$(printf '%s' "$removed" | grep -c .)" = 3 ] || fail "cargo_env: exactly three names removed, got: $removed"
# The cargo-injected ones are reported before the config one.
[ "$(printf '%s' "$removed" | grep -n 'TS_RS_EXPORT_DIR' | cut -d: -f1)" = 3 ] \
  || fail "cargo_env: the config [env] name should be reported last, got: $removed"
pass "cargo_env: the strip clears both halves, protects the rest, and names what it removed"

# A legal cargo config may name PATH. Clearing it would leave the session unable to find its own
# agent CLI, so the protected list wins over anything an [env] table says.
prot="$work_dir/protective"
mkdir -p "$prot/.cargo"
printf '[env]\nPATH = "/nowhere"\nHOME = "/nowhere"\nCEREBRO_CONSUMER_ROOT = "/nowhere"\n' \
  > "$prot/.cargo/config.toml"
out="$( cerebro_strip_cargo_env "$prot"; printf -- '--\n%s|%s\n' "${PATH:-<unset>}" "${HOME:-<unset>}" )"
[ -n "${out#*--$'\n'}" ] || fail "cargo_env: PATH and HOME should still be set"
grep -q '<unset>' <<<"${out#*--$'\n'}" && fail "cargo_env: a [env] table must not be able to unset PATH or HOME"
pass "cargo_env: an [env] table naming PATH or HOME cannot break a session"

( set -euo pipefail
  # THE SUITE RUNS INSIDE A POLLUTED SESSION. An implementer running this is itself a session the
# fleet view started, so its own environment already carries cargo's eighteen variables - and an
# assertion counting what the strip removed would count those too, green in CI and red on the
# navigator's machine (the exact shape ah-dy4x cost). Clear them here; each case exports what it
# needs.
for _n in $(compgen -e || true); do
  case "$_n" in
    CARGO_HOME|CARGO_TARGET_DIR) ;;
    CARGO|CARGO_*|TS_RS_EXPORT_DIR) unset "$_n" ;;
  esac
done
unset _n

source "$repo_root/scripts/cargo-env.sh"
  unset CARGO_MANIFEST_DIR CARGO_PKG_NAME TS_RS_EXPORT_DIR 2>/dev/null || true
  out="$(cerebro_strip_cargo_env "$empty_dir")"
  [ -z "$out" ] || exit 1
) || fail "cargo_env: with nothing cargo-ish set, the strip must print nothing and survive errexit"
pass "cargo_env: with no cargo variable set at all, the strip is silent and survives set -euo pipefail"

# The builtins-only claim, proved rather than asserted: a PATH holding `bash' alone.
bin_only="$work_dir/bin-only"
mkdir -p "$bin_only"
ln -sf "$(command -v bash)" "$bin_only/bash"
out="$(PATH="$bin_only" bash -c '
  set -euo pipefail
  source "'"$repo_root"'/scripts/cargo-env.sh"
  export CARGO_MANIFEST_DIR=/x TS_RS_EXPORT_DIR=/leak
  cerebro_strip_cargo_env "'"$cfg_root"'"
')" || fail "cargo_env: the library must work with a PATH holding bash alone"
[ "$(printf '%s' "$out" | grep -c .)" = 2 ] \
  || fail "cargo_env: with bash alone on PATH, expected two removals, got: $out"
pass "cargo_env: the library needs nothing on PATH but bash"

# The arrays, which are how a caller in the CALLER'S OWN shell learns what went - reading the
# printed lines instead means `$(...)' or a process substitution, which runs the whole strip in a
# subshell and clears nothing while printing a convincing list of what it did not do (cb-6fu).
( export CARGO_MANIFEST_DIR=/x TS_RS_EXPORT_DIR=/leak
  cerebro_strip_cargo_env "$cfg_root" >/dev/null
  [ "${#cerebro_cargo_stripped_injected[@]}" = 1 ] || exit 1
  [ "${cerebro_cargo_stripped_injected[0]}" = CARGO_MANIFEST_DIR ] || exit 1
  [ "${#cerebro_cargo_stripped_config[@]}" = 1 ] || exit 1
  [ "${cerebro_cargo_stripped_config[0]}" = TS_RS_EXPORT_DIR ] || exit 1
  [ -z "${CARGO_MANIFEST_DIR:-}" ] && [ -z "${TS_RS_EXPORT_DIR:-}" ] || exit 1
) || fail "cargo_env: the strip must report through its arrays and unset in the caller's own shell"
pass "cargo_env: what was removed is readable without a subshell, and the removal is the caller's"

suite_passed
