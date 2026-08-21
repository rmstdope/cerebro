#!/usr/bin/env bash
#
# Proves scripts/project-conf reads <consumer>/.claude/cerebro-project.conf: the tracked file in
# which a consumer declares its own project facts (ah-qled.1, cerebro#58 §1).
#
# The whole point of this reader is that it NEVER fails - callers run under `set -euo pipefail`, so
# a missing file or a missing key must exit 0 with a fallback rather than take the caller down -
# and that a value runs to the end of the line, which is what separates it from launch's
# three-column `config_lookup`.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/project-conf.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# --- a throwaway consumer repo, the way tests/consumer-root.sh builds one ---
consumer="$work_dir/repo"
mkdir -p "$consumer/.claude/cerebro/scripts"
git init -q "$consumer"
git -C "$consumer" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
done
conf="$consumer/.claude/cerebro-project.conf"
project_conf="$consumer/.claude/cerebro/scripts/project-conf"

cat > "$conf" <<'CONF'
# A whole-line comment, ignored.

project_name   Atlantis HUD
install        pnpm install --frozen-lockfile
default_branch main            # trailing comments are stripped
empty_key
CONF

# --- a configured key wins ---
out="$("$project_conf" project_name 2>/dev/null)"
[[ "$out" == "Atlantis HUD" ]] || fail "configured key: expected 'Atlantis HUD', got '$out'"
pass "a configured key wins"

# --- a value containing spaces survives: THE trap, launch's `read -r k m e` splits it ---
out="$("$project_conf" install 2>/dev/null)"
[[ "$out" == "pnpm install --frozen-lockfile" ]] \
  || fail "value with spaces: expected the whole command, got '$out'"
pass "a value containing spaces survives whole"

# --- a trailing comment is stripped from a value ---
out="$("$project_conf" default_branch 2>/dev/null)"
[[ "$out" == "main" ]] || fail "trailing comment: expected 'main', got '$out'"
pass "a trailing comment is stripped from a value"

# --- a whole-line comment is not a key ---
out="$("$project_conf" "#" fallback 2>/dev/null)"
[[ "$out" == "fallback" ]] || fail "comment line: expected 'fallback', got '$out'"
pass "a whole-line comment is ignored"

# --- a key with no value says nothing, so the default stands ---
out="$("$project_conf" empty_key fallback 2>/dev/null)"
[[ "$out" == "fallback" ]] || fail "empty value: expected 'fallback', got '$out'"
pass "a key with no value yields the default"

# --- a missing key returns the default, and exits 0 ---
set +e
out="$("$project_conf" nonexistent_key fallback 2>/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "missing key: expected exit 0, got $status"
[[ "$out" == "fallback" ]] || fail "missing key: expected 'fallback', got '$out'"
pass "a missing key returns the default and exits 0"

# --- a missing key with no default prints nothing, and still exits 0 ---
set +e
out="$("$project_conf" nonexistent_key 2>/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "missing key, no default: expected exit 0, got $status"
[[ -z "$out" ]] || fail "missing key, no default: expected nothing, got '$out'"
pass "a missing key with no default prints nothing and exits 0"

# --- the explanation goes to stderr, never stdout ---
err="$("$project_conf" project_name 2>&1 >/dev/null)"
[[ -n "$err" ]] || fail "explanation: expected something on stderr"
echo "$err" | grep -q "project_name" || fail "explanation: expected the key named, got: $err"
out="$("$project_conf" project_name 2>/dev/null)"
[[ "$out" == "Atlantis HUD" ]] || fail "explanation: stdout must carry the value alone, got '$out'"
pass "the explanation goes to stderr, and stdout carries the value alone"

# --- a missing file is not an error ---
mv "$conf" "$conf.aside"
set +e
out="$("$project_conf" project_name fallback 2>/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "missing file: expected exit 0, got $status"
[[ "$out" == "fallback" ]] || fail "missing file: expected 'fallback', got '$out'"
pass "a missing file is not an error"

# --- an unreadable file is not an error ---
# Skipped as root: chmod 000 does not make a file unreadable to uid 0, so the case cannot be
# staged there at all and the assertion would fail for a reason that is not about this script.
mv "$conf.aside" "$conf"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip - an unreadable file is not an error (running as root)"
else
chmod 000 "$conf"
set +e
out="$("$project_conf" project_name fallback 2>/dev/null)"
status=$?
set -e
chmod 644 "$conf"
[[ $status -eq 0 ]] || fail "unreadable file: expected exit 0, got $status"
[[ "$out" == "fallback" ]] || fail "unreadable file: expected 'fallback', got '$out'"
pass "an unreadable file is not an error"
fi

# --- detection: `install` is inferred from a lockfile when unconfigured ---
detect_consumer="$work_dir/detect"
mkdir -p "$detect_consumer/.claude/cerebro/scripts"
git init -q "$detect_consumer"
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$detect_consumer/.claude/cerebro/scripts/$s"
done
detect_conf="$detect_consumer/.claude/cerebro/scripts/project-conf"

out="$("$detect_conf" install 2>/dev/null)"
[[ -z "$out" ]] || fail "no lockfile: expected nothing, got '$out'"
pass "no lockfile yields no install command"

touch "$detect_consumer/yarn.lock"
out="$("$detect_conf" install 2>/dev/null)"
[[ "$out" == "yarn install --immutable" ]] || fail "yarn.lock: got '$out'"
pass "yarn.lock is detected"

touch "$detect_consumer/package-lock.json"
out="$("$detect_conf" install 2>/dev/null)"
[[ "$out" == "npm ci" ]] || fail "package-lock.json: got '$out'"
pass "package-lock.json is detected"

touch "$detect_consumer/pnpm-lock.yaml"
out="$("$detect_conf" install 2>/dev/null)"
[[ "$out" == "pnpm install --frozen-lockfile" ]] || fail "pnpm-lock.yaml: got '$out'"
pass "pnpm-lock.yaml is detected, and wins over the others"

err="$("$detect_conf" install 2>&1 >/dev/null)"
echo "$err" | grep -q "pnpm-lock.yaml" \
  || fail "detection: expected the probe named on stderr, got: $err"
pass "the branch taken by detection is said out loud, on stderr"

# --- a configured install beats detection ---
echo "install make bootstrap" > "$detect_consumer/.claude/cerebro-project.conf"
out="$("$detect_conf" install 2>/dev/null)"
[[ "$out" == "make bootstrap" ]] || fail "configured beats detected: got '$out'"
pass "a configured install beats detection"

# --- prewarm is NEVER inferred: nothing could guess build:wasm ---
out="$("$detect_conf" prewarm 2>/dev/null)"
[[ -z "$out" ]] || fail "prewarm: expected nothing, never a guess, got '$out'"
pass "prewarm is never inferred"

# --- no key at all is a usage error, and that one IS non-zero ---
set +e
out="$("$project_conf" 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "no arguments: expected a non-zero exit, got 0"
echo "$out" | grep -q "usage:" || fail "no arguments: expected a usage message, got: $out"
pass "calling it with no key is a usage error"

# --- CRLF line endings do not leak into the value: this file is TRACKED, so it will be edited on
# --- Windows checkouts, and a trailing \r turns `npm ci' into `npm ci\r' and `main' into a branch
# --- that does not exist - invisibly, in every message.
crlf_consumer="$work_dir/crlf"
mkdir -p "$crlf_consumer/.claude/cerebro/scripts"
git init -q "$crlf_consumer"
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$crlf_consumer/.claude/cerebro/scripts/$s"
done
printf 'install npm ci\r\nproject_name Atlantis HUD\r\n' > "$crlf_consumer/.claude/cerebro-project.conf"
out="$("$crlf_consumer/.claude/cerebro/scripts/project-conf" install 2>/dev/null)"
[[ "$out" == "npm ci" ]] || fail "CRLF: expected 'npm ci' with no carriage return, got '$(printf %s "$out" | cat -v)'"
pass "a CRLF file yields a value with no carriage return"

# --- the first line wins when a key is repeated, so appending a second one does not silently win ---
printf 'default_branch first\ndefault_branch second\n' > "$conf"
out="$("$project_conf" default_branch 2>/dev/null)"
[[ "$out" == "first" ]] || fail "duplicate keys: expected 'first', got '$out'"
pass "the first line wins when a key is repeated"

# --- nothing reaches stdout on a fallback path, where a stray echo would poison a substitution ---
out="$("$project_conf" nonexistent_key 2>/dev/null)"
[[ -z "$out" ]] || fail "fallback stdout: expected nothing, got '$out'"
pass "a fallback path puts nothing on stdout"

# --- release_watch: ABSENT means "there is nothing to watch after tagging", which is an ordinary
# --- state, not a misconfiguration. The whole rule rests on this exiting 0 and printing nothing:
# --- a reader that made an unknown key non-zero would turn every consumer's release into a failure.
set +e
out="$("$project_conf" release_watch 2>/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "release_watch absent: expected exit 0, got $status"
[[ -z "$out" ]] || fail "release_watch absent: expected nothing, got '$out'"
pass "an undeclared release_watch prints nothing and exits 0"

# --- and a declared one names the workflow ---
printf 'release_watch  Release\n' > "$conf"
out="$("$project_conf" release_watch 2>/dev/null)"
[[ "$out" == "Release" ]] || fail "release_watch declared: expected 'Release', got '$out'"
pass "a declared release_watch names the workflow"

echo "all project-conf tests passed"
