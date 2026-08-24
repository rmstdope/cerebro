#!/usr/bin/env bash
#
# Proves a consumer declares HOW TO START ITS APPLICATION, and that no role file has to know
# (ah-qled.8, cerebro#58 §2).
#
# agents/verifier.md used to carry the single most project-specific passage in all seven role
# files - pnpm, Vite, Tauri v2, wasm, two @atlantis/* package names and a cargo feature flag, in
# the one place a role has to actually launch the thing. A consumer's verifier read that, could run
# none of it, and INVENTED A COMMAND. That is the worst possible outcome for the one role whose
# whole job is to put the real application in front of the navigator, so the replacement behaviour
# is not a better guess: WITH NOTHING DECLARED, THE ROLE ASKS.
#
# The shape is flat keys plus an index, NOT a list of records:
#
#     launch_targets       web desktop
#     launch_web           <command>
#     launch_web_port      5173
#
# because project-conf is `key value' with the value running to end of line and its lookup returns
# only the FIRST match - so records and repeated keys are both unexpressible, and a third config
# file with a third parser is not worth two launch targets. `notes' become comment lines, which the
# format gives free. NOTHING is added to project-conf for any of this.
#
# No framework: plain bash, exit non-zero on the first failed assertion. Run from the submodule
# root:
#
#     bash tests/launch-targets.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# --- a throwaway consumer, the way tests/project-conf.sh builds one ---
consumer="$work_dir/repo"
mkdir -p "$consumer/.claude/cerebro/scripts"
git init -q "$consumer"
git -C "$consumer" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
done
conf="$consumer/.cerebro/project.conf"
mkdir -p "$consumer/.cerebro"
project_conf="$consumer/.claude/cerebro/scripts/project-conf"

cat > "$conf" <<'CONF'
launch_targets  web desktop

# Without --features desktop-runtime this builds the stub main, which exits at once.
launch_web            pnpm --filter @atlantis/web dev
launch_web_port       5173
launch_desktop        pnpm --filter @atlantis/desktop exec tauri dev --features desktop-runtime
launch_desktop_port   4174

port_base        4173
port_block_size  10
port_env         SMOKE_PORT_BASE

prewarm          pnpm --filter @atlantis/browser-core build:wasm
fixtures_doc     tests/fixtures/reports/README.md
CONF

# --- 1. the index is iterable, and each name resolves to a command and a port ---
targets="$("$project_conf" launch_targets 2>/dev/null)"
[[ "$targets" == "web desktop" ]] || fail "launch_targets: expected 'web desktop', got '$targets'"
pass "launch_targets is an index the prompt can iterate"

for name in $targets; do
  cmd="$("$project_conf" "launch_$name" 2>/dev/null)"
  [[ -n "$cmd" ]] || fail "launch_$name: no command"
  port="$("$project_conf" "launch_${name}_port" 2>/dev/null)"
  [[ -n "$port" ]] || fail "launch_${name}_port: no port"
done
pass "every declared target yields a command and a port"

# --- the command survives whole: THE trap that rules out launch's three-column reader ---
out="$("$project_conf" launch_desktop 2>/dev/null)"
[[ "$out" == "pnpm --filter @atlantis/desktop exec tauri dev --features desktop-runtime" ]] \
  || fail "launch_desktop: the command was split or truncated, got '$out'"
pass "a launch command survives to the end of the line, flags and all"

# --- a note is a comment line, so the format needed no `notes' field ---
grep -q '^# Without --features desktop-runtime' "$conf" \
  || fail "notes: the fixture should carry a note as a comment line"
[[ "$("$project_conf" launch_web 2>/dev/null)" == "pnpm --filter @atlantis/web dev" ]] \
  || fail "notes: a preceding comment line leaked into the value"
pass "a note is a comment line, and does not leak into the value"

# --- 2. NOTHING DECLARED IS REPORTED AS SUCH, distinctly from a name that did not match ---
bare="$work_dir/bare"
mkdir -p "$bare/.claude/cerebro/scripts"
git init -q "$bare"
git -C "$bare" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$bare/.claude/cerebro/scripts/$s"
done
mkdir -p "$bare/.cerebro"
: > "$bare/.cerebro/project.conf"

out="$("$bare/.claude/cerebro/scripts/project-conf" launch_targets 2>"$work_dir/err")" || true
[[ -z "$out" ]] || fail "no launch_targets: expected no value on stdout, got '$out'"
grep -q 'launch_targets unset' "$work_dir/err" \
  || fail "no launch_targets: the absence must be SAID, not silent - that is what makes the role ask"
pass "no launch_targets is reported as unset, which is what turns into asking the navigator"

# --- 3. a name in the index with no launch_<name> is reported, not silently dropped ---
half="$work_dir/half"
mkdir -p "$half/.claude/cerebro/scripts"
git init -q "$half"
git -C "$half" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
for s in consumer-root project-conf; do
  ln -s "$repo_root/scripts/$s" "$half/.claude/cerebro/scripts/$s"
done
mkdir -p "$half/.cerebro"
printf 'launch_targets web desktop\nlaunch_web  run me\nlaunch_web_port 5173\n' \
  > "$half/.cerebro/project.conf"

out="$("$half/.claude/cerebro/scripts/project-conf" launch_desktop 2>"$work_dir/err2")" || true
[[ -z "$out" ]] || fail "half-written conf: expected no value for launch_desktop, got '$out'"
grep -q 'launch_desktop unset' "$work_dir/err2" \
  || fail "half-written conf: a name in the index with no command must be reported"
pass "a name in the index with no launch_<name> is reported, not silently dropped"

# --- 4. the smoke port block comes from port_base / port_block_size ---
base="$("$project_conf" port_base 2>/dev/null)"
size="$("$project_conf" port_block_size 2>/dev/null)"
[[ "$base" == "4173" && "$size" == "10" ]] || fail "port keys: got base '$base', size '$size'"
block=""
for i in 0 1 2; do block+="$((base + size + i)) "; done
[[ "$block" == "4183 4184 4185 " ]] || fail "port arithmetic: got '$block'"
pass "port_base and port_block_size produce the block the smoke prose describes"

# --- the port a role checks before starting a server comes from the same declaration ---
[[ "$("$project_conf" launch_web_port 2>/dev/null)" == "5173" ]] \
  || fail "launch_web_port: the lsof check has nowhere to get its port"
pass "the port to check before starting a server is declared, not written into the prose"

# --- 5. the warm build and fixtures_doc are OPTIONAL, and absent means the step is skipped.
# --- The warm build is `prewarm', ah-qled.2's spelling, which merged first: the plan for this bead
# --- called it `warm_build_cmd', and a THIRD spelling of one thing is worse than either.
for key in prewarm fixtures_doc; do
  [[ -n "$("$project_conf" "$key" 2>/dev/null)" ]] || fail "$key: declared but did not resolve"
  out="$("$bare/.claude/cerebro/scripts/project-conf" "$key" 2>/dev/null)" || true
  [[ -z "$out" ]] || fail "$key: absent must resolve to nothing, not to a guess"
done
pass "prewarm and fixtures_doc are optional, and absent yields nothing to run"

# --- nothing was added to project-conf's format: still key/value, still no records ---
grep -qE 'launch_target|launch_<|launch_.*_port' "$repo_root/scripts/project-conf" \
  && fail "project-conf must know nothing about launching - these are ordinary keys"
pass "project-conf gained no knowledge of launch targets"

for f in "$repo_root"/scripts/launch-targets "$repo_root"/scripts/launch-conf; do
  [[ -e "$f" ]] && fail "no third config reader was to be introduced: $f exists"
done
pass "no new parser and no third config file"

# ---------------------------------------------------------------------------
# 6. NO ROLE NAMES ANOTHER PROJECT'S TOOL OR PORT
# ---------------------------------------------------------------------------
sites="agents/verifier.md agents/reviewer.md skills/implement-bead/SKILL.md docs/agent-workflow.md"

for f in $sites; do
  if grep -nE 'pnpm --filter|tauri|@atlantis|\b5173\b|\b4174\b|\b4183\b|\b4173\b|\b4193\b' \
       "$repo_root/$f" >/dev/null 2>&1; then
    grep -nE 'pnpm --filter|tauri|@atlantis|\b5173\b|\b4174\b|\b4183\b|\b4173\b|\b4193\b' \
      "$repo_root/$f" >&2
    fail "$f still names one consumer's tooling or ports"
  fi
done
pass "no launch site names pnpm --filter, tauri, @atlantis or a hardcoded port"

# --- and each of them says where the answer comes from ---
for f in agents/verifier.md agents/reviewer.md; do
  grep -q 'launch_targets' "$repo_root/$f" \
    || fail "$f names no way to find out how to start the application"
  grep -q 'launch_.*_port\|launch_<name>_port' "$repo_root/$f" \
    || fail "$f names no way to find the port to check"
done
grep -qE 'port_base' "$repo_root/skills/implement-bead/SKILL.md" \
  || fail "implement-bead names no way to find its port block"
grep -qE 'port_base|port_block_size' "$repo_root/docs/agent-workflow.md" \
  || fail "agent-workflow still describes the blocks as fixed numbers"
pass "each launch site names the declaration it reads"

# --- THE ASK. With nothing declared, the verifier must ask - not guess, not skip ---
verifier="$(tr '\n' ' ' < "$repo_root/agents/verifier.md" | tr -s ' ')"
case "$verifier" in
  *"ask the navigator how to run the application"*) ;;
  *) fail "verifier.md must say, in those words, that with nothing declared it ASKS the navigator" ;;
esac
grep -q 'improvise\|invent\|guess' "$repo_root/agents/verifier.md" \
  || fail "verifier.md must forbid improvising a command, not merely omit it"
pass "with nothing declared the verifier asks the navigator, and is forbidden to improvise"

reviewer="$(tr '\n' ' ' < "$repo_root/agents/reviewer.md" | tr -s ' ')"
case "$reviewer" in
  *"ask the navigator how to run the application"*) ;;
  *) fail "reviewer.md must ask too - it launches the application for the same reason" ;;
esac
pass "the reviewer asks on the same terms"

# ---------------------------------------------------------------------------
# 7. THE FOUR RULES SURVIVE. The commands were the illustration; these are the content.
# ---------------------------------------------------------------------------
for f in agents/verifier.md agents/reviewer.md; do
  body="$(tr '\n' ' ' < "$repo_root/$f" | tr -s ' ' | tr 'A-Z' 'a-z')"
  case "$body" in *"before starting a server"*) ;; *) fail "$f: the check-the-port rule is gone" ;; esac
  case "$body" in
    *"refuse to start and refuse to reuse"*|*"refusal, not something to reuse"*) ;;
    *) fail "$f: the refuse-rather-than-reuse rule is gone" ;;
  esac
done
pass "check the port before starting, and refuse rather than reuse, both survive"

case "$verifier" in
  *"Build after the reset, never before"*) ;;
  *) fail "verifier.md: the build-after-the-reset rule is gone" ;;
esac
case "$verifier" in
  *"exercises what the bead changed"*) ;;
  *) fail "verifier.md: the pick-the-right-fixture rule is gone" ;;
esac
pass "build after the reset, and pick the fixture that exercises what changed, both survive"

# --- the smoke prose keeps the rule the numbers only illustrated ---
skill="$(tr '\n' ' ' < "$repo_root/skills/implement-bead/SKILL.md" | tr -s ' ')"
case "$skill" in
  *"its own block of ports"*) ;;
  *) fail "implement-bead: the give-each-session-its-own-block rule is gone" ;;
esac
case "$skill" in
  *"check before claiming"*) ;;
  *) fail "implement-bead: the check-before-claiming rule is gone" ;;
esac
pass "give each session its own block of ports, and check before claiming one, both survive"

echo "all launch-targets tests passed"

# --- the warm build has ONE spelling across the whole harness ---
if grep -rn 'warm_build_cmd' "$repo_root/agents" "$repo_root/skills" "$repo_root/scripts" \
     "$repo_root/docs" >/dev/null 2>&1; then
  fail "warm_build_cmd is a third spelling of ah-qled.2's prewarm - there must be only one"
fi
pass "the warm build is spelled prewarm everywhere, and nowhere else"
