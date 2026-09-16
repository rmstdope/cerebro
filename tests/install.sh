#!/usr/bin/env bash
#
# Proves scripts/install, the one command a new consumer runs after adding the submodule (cb-4ua).
# Each step it has taken over from the README's setup section is proved here, in order.
#
# Step 1, the tools: every program the fleet needs is looked up on PATH and reported on one line
# each; the whole list is reported before anything refuses, so a person installs everything in one
# go rather than one tool per run; an agent CLI is "one of the known providers", not a fixed name;
# cargo is optional and its absence is said, not refused.
#
# Step 2, the links: `sync-symlinks.sh' is run once, so every skill and agent is discoverable from
# the consumer; a run that refused at the tools never reaches it.
#
# Step 3, the declaration: `.cerebro/project.conf' is written from an interview - the seven keys a
# fleet needs, each with a detected default, and every other key present but commented out - and an
# existing one is kept untouched. Answers come from stdin, so a case pipes them; EOF is "the
# default", and a required key with no default and no answer refuses.
#
# Step 4, the fleet: `.cerebro/roster.conf' from a second interview - how many ux, build-design and
# implementer agents, whether a verifier, a reviewer and a user-feedback agent run, and per role
# whether the fleet view autostarts it, arms it (standby) or leaves it to be started by hand. The
# orchestrator and the architect are always there. Names come from the built-in fleet's pool.
#
# Step 5, the agent settings: `.cerebro/agents.conf' from a third interview - the tool, the default
# model and effort, the implementers' own - and, on copilot, an external OpenAI-compatible model
# source that the model answers may then name. Every other role is a commented line.
#
# Step 6, the traps: an empty `.cerebro/traps.md' - a heading and what the file is for - so the
# planners and implementers that read it find the file rather than nothing; one that exists is kept.
#
# Step 7, the ignores: the three runtime directories under `.cerebro/' are appended to `.gitignore'
# with their comment, each only if it is not there already, and `.cerebro/agents.conf' joins them
# when the answer is to keep it personal rather than commit it.
#
# Step 8, the board: `bd init' with a prefix proposed from the project's name, then the Dolt remote
# from the repository's `origin' - asked for, and added to git as well, when there is none. A
# `.beads/' that exists is a board, and is kept. `bd' is a stub here that logs its calls and makes
# `.beads/' on `init', so what was run is asserted from the log.
#
# Every case runs under a NARROWED PATH: bash, the programs the later steps run (ln, readlink, git,
# ...) and the stubs the case chooses - never a tool the installer checks for. So "bd is missing"
# and "cargo is absent" are real absences whatever the machine running the suite has installed.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/install.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# What the installer's own machinery may use, and none of the tools it checks for - except `git',
# which the later steps need for real (the consumer root, the branch) and no case makes absent.
bare="$work_dir/bare"
mkdir -p "$bare"
for t in bash dirname mkdir ln readlink rm basename find awk cut grep sed tr sort cat ls tail comm git; do
  ln -s "$(command -v "$t")" "$bare/$t"
done

# stubs <name>...  ->  echoes a fresh directory holding an executable no-op for each name
stubs() {
  local d
  d="$(mktemp -d "$work_dir/stubs-XXXXXX")"
  for n in "$@"; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$n"
    chmod +x "$d/$n"
  done
  echo "$d"
}

# A consumer with something to detect - a `src/' and a `make test' - so that an interview answered
# by EOF alone (`/dev/null') completes on defaults.
new_consumer() {
  local c
  c="$(consumer_new "$1" --copy "${@:2}")"
  mkdir -p "$c/src"
  printf 'test:\n\ttrue\n' > "$c/Makefile"
  echo "$c"
}

consumer="$(new_consumer fresh)"        # the passing runs
refused="$(new_consumer refused)"       # the refusing runs, so it can be shown untouched
answers=/dev/null                       # a case that answers the interview points this at a file

# run_install <stubs-dir> [<consumer>]  ->  sets $out, $err, $status
run_install() {
  set +e
  out="$(PATH="$1:$bare" "$bare/bash" "${2:-$consumer}/.claude/cerebro/scripts/install" \
    <"$answers" 2>"$work_dir/err")"
  status=$?
  set -e
  err="$(cat "$work_dir/err")"
  # A program missing from `bare' must turn a case red, not pass as an empty answer.
  ! grep -q 'command not found' <<<"$err" || fail "a program the installer runs is not on the narrowed PATH: $err"
}

# --- every tool present -----------------------------------------------------------------------------
run_install "$(stubs bd gh jq claude cargo)"
[[ $status -eq 0 ]] || fail "all present: expected exit 0, got $status; stderr: $err"
for t in bd gh git jq claude cargo; do
  grep -Eq "^ +ok +$t\b" <<<"$out" || fail "all present: no ok line for $t in: $out"
done
! grep -q MISSING <<<"$out" || fail "all present: something reported MISSING: $out"
pass "every tool present: one ok line per tool, exit 0"

# --- two required tools missing: both named, one run ---------------------------------------------
run_install "$(stubs gh claude cargo)" "$refused"
[[ $status -eq 1 ]] || fail "bd+jq missing: expected exit 1, got $status"
grep -Eq "^ +MISSING +bd\b.*github.com/steveyegge/beads" <<<"$out" \
  || fail "bd missing: expected a MISSING line naming bd and where to get it: $out"
grep -Eq "^ +MISSING +jq\b" <<<"$out" || fail "jq missing: expected a MISSING line for jq: $out"
grep -Eq "^ +ok +gh\b" <<<"$out" || fail "bd+jq missing: gh should still be reported ok: $out"
grep -q "2 tools missing" <<<"$err" || fail "bd+jq missing: expected the count on stderr, got: $err"
pass "two missing tools are both named in one run, and the run refuses"

# --- no agent CLI at all --------------------------------------------------------------------------
run_install "$(stubs bd gh jq cargo)" "$refused"
[[ $status -eq 1 ]] || fail "no agent CLI: expected exit 1, got $status"
grep -Eq "^ +MISSING +agent CLI.*claude.*copilot" <<<"$out" \
  || fail "no agent CLI: expected a MISSING line naming every known provider: $out"
pass "no agent CLI on PATH refuses, naming every provider that would do"

# --- copilot alone is an agent CLI ------------------------------------------------------------------
run_install "$(stubs bd gh jq copilot cargo)"
[[ $status -eq 0 ]] || fail "copilot only: expected exit 0, got $status; stderr: $err"
grep -Eq "^ +ok +copilot\b" <<<"$out" || fail "copilot only: expected an ok line for copilot: $out"
! grep -q MISSING <<<"$out" || fail "copilot only: something reported MISSING: $out"
pass "copilot alone satisfies the agent CLI"

# --- cargo is optional ------------------------------------------------------------------------------
run_install "$(stubs bd gh jq claude)"
[[ $status -eq 0 ]] || fail "no cargo: expected exit 0, got $status; stderr: $err"
grep -Eq "^ +absent +cargo\b.*cerebro-tui" <<<"$out" \
  || fail "no cargo: expected an absent line saying what cargo is for: $out"
! grep -q MISSING <<<"$out" || fail "no cargo: cargo must not count as missing: $out"
pass "cargo absent is said, not refused"

# --- a refused tools step reaches no later step -------------------------------------------------
[[ ! -e "$refused/.claude/skills" ]] \
  || fail "refused runs above linked something: $(ls "$refused/.claude/skills")"
pass "a run refused at the tools links nothing"

# --- 3. the links: every skill and agent is discoverable from the consumer -------------------------
all="$(stubs bd gh jq claude cargo)"
linked="$(new_consumer linked)"
run_install "$all" "$linked"
[[ $status -eq 0 ]] || fail "links: expected exit 0, got $status; stderr: $err"
grep -q "Synced .* skill link" <<<"$out" || fail "links: expected the sync's skill line in: $out"
skill_link="$linked/.claude/skills/implement-bead"
[[ -L "$skill_link" && "$(readlink "$skill_link")" == "../cerebro/skills/implement-bead" ]] \
  || fail "links: expected a relative skill link at $skill_link"
[[ -f "$skill_link/SKILL.md" ]] || fail "links: the skill link does not resolve"
agent_link="$linked/.claude/agents/implementer.md"
[[ -L "$agent_link" && -f "$agent_link" ]] || fail "links: expected a resolving agent link at $agent_link"
[[ -e "$linked/.github/agents" ]] || fail "links: the second provider's layout was not written"
pass "the installer links every skill and agent into every layout"

# --- running it again changes nothing and still exits 0 --------------------------------------------
before="$(cd "$linked" && find .claude .github -type l | sort)"
run_install "$all" "$linked"
[[ $status -eq 0 ]] || fail "second run: expected exit 0, got $status; stderr: $err"
[[ "$(cd "$linked" && find .claude .github -type l | sort)" == "$before" ]] \
  || fail "second run: the set of links changed"
pass "a second run is a no-op and exits 0"

# --- 3. the declaration: an interview writes the minimum, everything else commented out ------------
declared="$(consumer_new declared --copy)"           # bare: nothing to detect
mkdir -p "$declared/app"
answers="$work_dir/answers"
printf 'Ledger\ntrunk\nmember\n^app/\nmake check && make lint\nmake check-all\nnpm ci\n' > "$answers"
run_install "$all" "$declared"
answers=/dev/null
[[ $status -eq 0 ]] || fail "declare: expected exit 0, got $status; stderr: $err"
conf="$declared/.cerebro/project.conf"
[[ -f "$conf" ]] || fail "declare: no $conf written"
pc="$declared/.claude/cerebro/scripts/project-conf"
for pair in project_name=Ledger default_branch=trunk audience_noun=member app_paths='^app/' \
            gate_fast='make check && make lint' gate_full='make check-all' install='npm ci'; do
  k="${pair%%=*}"; v="${pair#*=}"
  [[ "$("$pc" "$k" 2>/dev/null)" == "$v" ]] || fail "declare: $k: expected '$v', got '$("$pc" "$k" 2>/dev/null)'"
done
[[ "$("$declared/.claude/cerebro/scripts/app-paths" 2>/dev/null)" == '^app/' ]] || fail "declare: app-paths does not answer"
grep -Eq "^ +wrote +\.cerebro/project\.conf" <<<"$out" || fail "declare: expected a wrote line: $out"
pass "the interview's answers are the declaration, and every reader answers from it (a gate with && included)"

# Every other key the scripts read is there to be found, and off.
for k in install_shell prewarm disk_floor_gb reclaim_dirs rust_paths launch_targets port_base \
         port_env verification verification_skill fixtures_doc retro_dir merged_check \
         commit_ref_pattern non_delivery_commit_pattern role_start_spacing_implementer \
         planner_buffer_multiple; do
  grep -Eq "^#[[:space:]]*$k\b" "$conf" || fail "declare: optional key $k is not in the file, commented out"
  [[ -z "$("$pc" "$k" 2>/dev/null)" ]] || fail "declare: optional key $k is live: $("$pc" "$k")"
done
[[ "$(grep -cEv '^[[:space:]]*(#|$)' "$conf")" -eq 7 ]] \
  || fail "declare: expected exactly the seven interviewed keys live, got: $(grep -Ev '^[[:space:]]*(#|$)' "$conf")"
pass "every optional key is present, explained and commented out"

# --- the defaults are detected and shown, and EOF takes them ----------------------------------------
detected="$(new_consumer detected)"                 # src/ and make test
run_install "$all" "$detected"
[[ $status -eq 0 ]] || fail "detected: expected exit 0, got $status; stderr: $err"
grep -q '\[detected\]' <<<"$out" || fail "detected: expected the consumer's own name as the default: $out"
grep -q '\[main\]' <<<"$out" || fail "detected: expected the branch default: $out"
grep -q '\[user\]' <<<"$out" || fail "detected: expected the audience default: $out"
grep -q '\[\^src/\]' <<<"$out" || fail "detected: expected ^src/ from the src directory: $out"
grep -q '\[make test\]' <<<"$out" || fail "detected: expected make test from the Makefile: $out"
pc="$detected/.claude/cerebro/scripts/project-conf"
[[ "$("$pc" project_name 2>/dev/null)" == "detected" ]] || fail "detected: project_name not defaulted"
[[ "$("$pc" app_paths 2>/dev/null)" == '^src/' ]] || fail "detected: app_paths not defaulted"
[[ "$("$pc" gate_full 2>/dev/null)" == 'make test' ]] || fail "detected: gate_full not defaulted to the gate"
grep -Eq '^#[[:space:]]*install\b' "$detected/.cerebro/project.conf" \
  || fail "detected: with nothing to install, install should be commented out"
pass "each default is detected and shown, and an empty answer takes it"

# --- a new project has no gate yet: the gates may be left empty, and the file says what that costs --
nogate="$(consumer_new nogate --copy)"
mkdir -p "$nogate/app"                               # an app_paths default, no Makefile: no gate to detect
run_install "$all" "$nogate"
[[ $status -eq 0 ]] || fail "nogate: expected exit 0, got $status; stderr: $err"
conf="$nogate/.cerebro/project.conf"
pc="$nogate/.claude/cerebro/scripts/project-conf"
grep -Eq '^#[[:space:]]*gate_fast\b' "$conf" || fail "nogate: gate_fast should be present and commented out: $(cat "$conf")"
grep -Eq '^#[[:space:]]*gate_full\b' "$conf" || fail "nogate: gate_full should be present and commented out"
[[ -z "$("$pc" gate_fast 2>/dev/null)" ]] || fail "nogate: a gate was declared from nothing: $("$pc" gate_fast)"
[[ "$(grep -cEv '^[[:space:]]*(#|$)' "$conf")" -eq 4 ]] \
  || fail "nogate: expected four live keys, got: $(grep -Ev '^[[:space:]]*(#|$)' "$conf")"
grep -q 'gate_fast' <<<"$out" && grep -qi 'implementer' <<<"$out" \
  || fail "nogate: expected a line saying an implementer needs gate_fast before it starts: $out"
pass "with no gate to detect the gates are left empty, written commented out, and the cost is said"

# The app_paths question explains what it is asking for before it asks.
grep -q 'extended regex' <<<"$out" && grep -qi 'invisible' <<<"$out" \
  || fail "app_paths: expected the question to explain the regex and what counts as invisible: $out"
pass "the app_paths question explains itself"

# --- a required key with no default and no answer refuses, and writes nothing ---------------------
bare_c="$(consumer_new bare-c --copy)"
run_install "$all" "$bare_c"
[[ $status -eq 1 ]] || fail "required: expected exit 1, got $status"
grep -q 'app_paths' <<<"$err" || fail "required: expected app_paths named on stderr: $err"
[[ ! -e "$bare_c/.cerebro/project.conf" ]] || fail "required: a partial project.conf was written"
pass "an unanswerable required key refuses, naming it, and writes no file"

# --- an existing declaration is kept, and not asked about --------------------------------------------
kept="$(new_consumer kept)"
printf 'project_name  Mine\napp_paths ^x/\ngate_fast true\n' > "$kept/.cerebro/project.conf"
printf 'Ada  implementer\n' > "$kept/.cerebro/roster.conf"
printf 'default tool=claude\n' > "$kept/.cerebro/agents.conf"
printf '# Traps\n\n- one\n' > "$kept/.cerebro/traps.md"
printf '.cerebro/worktrees\n.cerebro/state\n.cerebro/scratch\n' > "$kept/.gitignore"
mkdir -p "$kept/.beads"
run_install "$all" "$kept"
[[ $status -eq 0 ]] || fail "kept: expected exit 0, got $status; stderr: $err"
[[ "$(cat "$kept/.cerebro/project.conf")" == "$(printf 'project_name  Mine\napp_paths ^x/\ngate_fast true')" ]] \
  || fail "kept: the existing declaration was changed"
grep -Eq "^ +kept +\.cerebro/project\.conf" <<<"$out" || fail "kept: expected a kept line: $out"
! grep -q '\[' <<<"$out" || fail "kept: the interview ran on an existing declaration: $out"
pass "an existing project.conf is kept untouched and the interview is skipped"
[[ "$(cat "$kept/.cerebro/roster.conf")" == "Ada  implementer" ]] || fail "kept: roster.conf was changed"
grep -Eq "^ +kept +\.cerebro/roster\.conf" <<<"$out" || fail "kept: expected a kept line for the roster: $out"
pass "an existing roster.conf is kept untouched too"
[[ "$(cat "$kept/.cerebro/agents.conf")" == "default tool=claude" ]] || fail "kept: agents.conf was changed"
grep -Eq "^ +kept +\.cerebro/agents\.conf" <<<"$out" || fail "kept: expected a kept line for agents.conf: $out"
pass "an existing agents.conf is kept untouched too"
[[ "$(cat "$kept/.cerebro/traps.md")" == "$(printf '# Traps\n\n- one')" ]] || fail "kept: traps.md was changed"
grep -Eq "^ +kept +\.cerebro/traps\.md" <<<"$out" || fail "kept: expected a kept line for traps.md: $out"
pass "an existing traps.md is kept untouched too"
[[ "$(wc -l < "$kept/.gitignore")" -eq 3 ]] || fail "kept: .gitignore grew: $(cat "$kept/.gitignore")"
grep -Eq "^ +kept +\.gitignore" <<<"$out" || fail "kept: expected a kept line for .gitignore: $out"
pass "a .gitignore that already ignores the runtime is kept, and not asked about"
grep -Eq "^ +kept +the board" <<<"$out" || fail "kept: expected a kept line for the board: $out"
pass "an existing board is kept, and not asked about"

# --- 6. the traps: an empty file, so the readers find it ------------------------------------------
[[ -f "$linked/.cerebro/traps.md" ]] || fail "traps: no .cerebro/traps.md written"
[[ "$(head -1 "$linked/.cerebro/traps.md")" == "# Traps" ]] || fail "traps: expected the heading first"
! grep -q '^- ' "$linked/.cerebro/traps.md" || fail "traps: a fresh file should hold no entry"
pass "an empty traps.md is written, headed and explained"

# --- 7. the ignores: the runtime is ignored, the declarations are not --------------------------------
ig="$linked/.gitignore"
[[ -f "$ig" ]] || fail "ignore: no .gitignore written"
for d in worktrees state scratch; do
  grep -qx "\.cerebro/$d" "$ig" || fail "ignore: .cerebro/$d is not in .gitignore"
  git -C "$linked" check-ignore -q ".cerebro/$d/x" || fail "ignore: .cerebro/$d/x is not ignored"
done
git -C "$linked" check-ignore -q .cerebro/project.conf && fail "ignore: project.conf is ignored" || true
git -C "$linked" check-ignore -q .cerebro/agents.conf && fail "ignore: agents.conf is ignored though shared by default" || true
grep -q '^# Cerebro writes these' "$ig" || fail "ignore: the block has no comment"
pass "the runtime directories are ignored with a comment, the declarations and agents.conf are not"

# A second run adds nothing: `linked' has run twice, so each line appears once.
for d in worktrees state scratch; do
  [[ "$(grep -cx "\.cerebro/$d" "$ig")" -eq 1 ]] || fail "ignore: .cerebro/$d appears more than once after two runs"
done
[[ "$(grep -c '^# Cerebro writes these' "$ig")" -eq 1 ]] || fail "ignore: the comment was written twice"
pass "a second run leaves .gitignore as it was"

# An existing .gitignore is appended to, keeping what it had; a line already there is not repeated.
own="$(new_consumer own)"
printf 'node_modules/\n.cerebro/state' > "$own/.gitignore"       # no trailing newline, on purpose
answers="$work_dir/own-answers"
{ printf '\n\n\n\n\n\n\n'; printf '\n\n\n\n\n\n\n\n\n\n\n\n'; printf '\n\n\n\n\n'; printf 'personal\n'; } > "$answers"
run_install "$all" "$own"
answers=/dev/null
[[ $status -eq 0 ]] || fail "own: expected exit 0, got $status; stderr: $err"
[[ "$(head -1 "$own/.gitignore")" == "node_modules/" ]] || fail "own: the project's own line was lost"
[[ "$(grep -cx '\.cerebro/state' "$own/.gitignore")" -eq 1 ]] || fail "own: .cerebro/state was repeated"
grep -qx '\.cerebro/worktrees' "$own/.gitignore" || fail "own: .cerebro/worktrees was not added"
grep -qx '\.cerebro/agents\.conf' "$own/.gitignore" || fail "own: a personal agents.conf was not ignored"
git -C "$own" check-ignore -q .cerebro/agents.conf || fail "own: agents.conf is not ignored"
grep -Eq "^ +wrote +\.gitignore" <<<"$out" || fail "own: expected a wrote line: $out"
[[ "$(sed -n '2,4p' "$own/.gitignore")" == "$(printf '.cerebro/state\n\n# Cerebro writes these while the fleet runs; the declarations beside them are tracked.')" ]] \
  || fail "own: a file without a trailing newline was not repaired before the block: $(cat "$own/.gitignore")"
pass "an existing .gitignore keeps its lines, gains the missing ones, and a personal agents.conf"

# --- 8. the board: bd init with a prefix, and the Dolt remote from origin ---------------------------
# A `bd' that logs what it was asked and behaves like the real one where the step depends on it
# (probed against bd HEAD-62d2119): `init' makes `.beads/', appends to `.gitignore', COMMITS both on
# the current branch, and configures the Dolt remote from the git origin when there is one, as
# `git+<url>'; `dolt remote list' prints it; `dolt remote add' refuses a URL equal to the git
# origin, exit 1.
logging_bd="$(stubs gh jq claude cargo)"
cat > "$logging_bd/bd" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$BD_LOG"
origin="$(git remote get-url origin 2>/dev/null || true)"
case "$1 ${2:-} ${3:-}" in
  "init  "*|"init "*)
    mkdir -p .beads
    echo '{}' > .beads/metadata.json
    echo '*.gate.lock*' >> .gitignore
    git -c user.name=bd -c user.email=bd@example.com add .beads/metadata.json .gitignore >/dev/null
    git -c user.name=bd -c user.email=bd@example.com commit -q -m 'bd init: initialize beads issue tracking' >/dev/null
    [[ -z "$origin" ]] || printf 'origin\tgit+%s\n' "$origin" > .beads/remotes ;;
  "dolt remote list") [[ -f .beads/remotes ]] && cat .beads/remotes ;;
  "dolt remote add")
    if [[ "${5:-}" == "$origin" ]]; then
      echo "Error: refusing to add \"$5\" as a Dolt remote - this URL matches the git origin." >&2
      exit 1
    fi
    printf '%s\t%s\n' "$4" "$5" >> .beads/remotes ;;
esac
exit 0
STUB
chmod +x "$logging_bd/bd"

board="$(new_consumer board --origin)"                # a clone: origin is the bare repository
export BD_LOG="$work_dir/board.log"
run_install "$logging_bd" "$board"
[[ $status -eq 0 ]] || fail "board: expected exit 0, got $status; stderr: $err"
grep -q '\[bd\]' <<<"$out" || fail "board: expected the prefix proposed from the name 'board': $out"
grep -qx 'init --prefix bd --quiet --non-interactive --skip-agents' "$BD_LOG" || fail "board: bd init not run as expected: $(cat "$BD_LOG")"
! grep -q 'remote add' "$BD_LOG" || fail "board: a remote was added over the one init configured: $(cat "$BD_LOG")"
[[ -d "$board/.beads" ]] || fail "board: no .beads/ after init"
grep -Eq "^ +wrote +the board .*git\+$(git -C "$board" remote get-url origin)" <<<"$out" \
  || fail "board: expected the remote init configured to be reported: $out"
grep -Eq "^ +bd init committed [0-9a-f]{7} on main: \.beads/ and \.gitignore" <<<"$out" \
  || fail "board: expected the commit bd init made to be reported with what it holds: $out"
[[ "$(git -C "$board" log -1 --format=%s)" == "bd init: initialize beads issue tracking" ]] || fail "board: the stub did not commit"
pass "the board is initialised with a proposed prefix and no agent files; init's remote and its commit are reported"

# A second run finds the board and runs nothing.
: > "$BD_LOG"
run_install "$logging_bd" "$board"
[[ $status -eq 0 ]] || fail "board again: expected exit 0, got $status; stderr: $err"
[[ ! -s "$BD_LOG" ]] || fail "board again: bd was run on an existing board: $(cat "$BD_LOG")"
grep -Eq "^ +kept +the board" <<<"$out" || fail "board again: expected a kept line: $out"
pass "an existing board is kept, and bd is not run"

# No origin: the URL is asked for, added to git as origin, and given to the board.
noorigin="$(new_consumer noorigin)"
export BD_LOG="$work_dir/noorigin.log"
answers="$work_dir/noorigin-answers"
{ printf '\n\n\n\n\n\n\n'; printf '\n\n\n\n\n\n\n\n\n\n\n\n'; printf '\n\n\n\n\n'; printf '\n'; printf 'nx\nhttps://example.com/x.git\n'; } > "$answers"
run_install "$logging_bd" "$noorigin"
answers=/dev/null
[[ $status -eq 0 ]] || fail "noorigin: expected exit 0, got $status; stderr: $err"
grep -qx 'init --prefix nx --quiet --non-interactive --skip-agents' "$BD_LOG" || fail "noorigin: the typed prefix was not used: $(cat "$BD_LOG")"
[[ "$(git -C "$noorigin" remote get-url origin)" == "https://example.com/x.git" ]] || fail "noorigin: git has no origin"
! grep -q 'remote add' "$BD_LOG" || fail "noorigin: a remote was added over the one init took from the new origin: $(cat "$BD_LOG")"
grep -q 'git+https://example.com/x.git' <<<"$out" || fail "noorigin: expected the remote reported: $out"
pass "with no origin the URL is asked for, becomes git's origin, and init takes it as the board's remote"

# No origin and no URL: the board still exists, and the missing remote is said, not refused.
noremote="$(new_consumer noremote)"
export BD_LOG="$work_dir/noremote.log"
run_install "$logging_bd" "$noremote"
[[ $status -eq 0 ]] || fail "noremote: expected exit 0, got $status; stderr: $err"
grep -q '^init ' "$BD_LOG" || fail "noremote: bd init was not run: $(cat "$BD_LOG")"
! grep -q 'remote add' "$BD_LOG" || fail "noremote: a remote was added from nothing: $(cat "$BD_LOG")"
grep -q 'bd dolt remote add origin' <<<"$out" || fail "noremote: expected the command to run later: $out"
pass "with no remote at all the board is made and the remote is left for later, named"
unset BD_LOG

# --- 4. the fleet: counts, the optional roles, and how each role is started ------------------------
roster_at() { "$1/.claude/cerebro/scripts/roster" "${@:2}"; }

# The defaults alone (the `linked' run above answered everything by EOF): one ux, one build-design,
# two implementers, a verifier, no reviewer and no user-feedback; the orchestrator autostarts, the
# planners and implementers stand by, the rest wait for `s'.
expected="$(printf 'Cerebro\torchestrator\tinteractive\nXavier\tux\tinteractive\nGambit\tbuild-design\tinteractive\nPsylocke\tverifier\tinteractive\nForge\tarchitect\tinteractive\nCyclops\timplementer\timplementer\nStorm\timplementer\timplementer')"
[[ "$(roster_at "$linked")" == "$expected" ]] \
  || fail "fleet defaults: expected the default fleet, got: $(roster_at "$linked")"
[[ "$(roster_at "$linked" --autostart)" == "Cerebro" ]] \
  || fail "fleet defaults: expected only Cerebro to autostart, got: $(roster_at "$linked" --autostart)"
[[ "$(roster_at "$linked" --standby)" == "$(printf 'Xavier\nGambit\nCyclops\nStorm')" ]] \
  || fail "fleet defaults: expected the planners and implementers on standby, got: $(roster_at "$linked" --standby)"
pass "the default fleet: the seven rows, the orchestrator autostarted, builders on standby"

# Every answer given: two ux, one build-design, three implementers, a verifier, no reviewer, a
# user-feedback agent; then how each present role starts, in the order the roles are listed.
fleet="$(new_consumer fleet)"
answers="$work_dir/fleet-answers"
{
  printf '\n\n\n\n\n\n\n'                    # project.conf: every default
  printf '2\n1\n3\ny\nn\ny\n'                 # the counts and the optional roles
  printf '\nmanual\n\nstandby\n\n\nautostart\n'  # orchestrator ux build-design verifier user-feedback architect implementer
} > "$answers"
run_install "$all" "$fleet"
answers=/dev/null
[[ $status -eq 0 ]] || fail "fleet: expected exit 0, got $status; stderr: $err"
expected="$(printf 'Cerebro\torchestrator\tinteractive\nXavier\tux\tinteractive\nBeast\tux\tinteractive\nGambit\tbuild-design\tinteractive\nPsylocke\tverifier\tinteractive\nMoira\tuser-feedback\tinteractive\nForge\tarchitect\tinteractive\nCyclops\timplementer\timplementer\nStorm\timplementer\timplementer\nWolverine\timplementer\timplementer')"
[[ "$(roster_at "$fleet")" == "$expected" ]] || fail "fleet: got: $(roster_at "$fleet")"
[[ "$(roster_at "$fleet" --autostart)" == "$(printf 'Cerebro\nCyclops\nStorm\nWolverine')" ]] \
  || fail "fleet: autostart: got: $(roster_at "$fleet" --autostart)"
[[ "$(roster_at "$fleet" --standby)" == "$(printf 'Gambit\nPsylocke')" ]] \
  || fail "fleet: standby: got: $(roster_at "$fleet" --standby)"
grep -Eq "^ +wrote +\.cerebro/roster\.conf" <<<"$out" || fail "fleet: expected a wrote line: $out"
! grep -q 'reviewer' <<<"$(roster_at "$fleet")" || fail "fleet: a declined role was written"
pass "the fleet interview: counts, optional roles and each role's start are the roster"

# A fleet with nobody to build is refused, and nothing is written.
nobody="$(new_consumer nobody)"
answers="$work_dir/nobody-answers"
{ printf '\n\n\n\n\n\n\n'; printf '\n\n0\n'; } > "$answers"
run_install "$all" "$nobody"
answers=/dev/null
[[ $status -eq 1 ]] || fail "nobody: expected exit 1, got $status"
grep -q 'implementer' <<<"$err" || fail "nobody: expected the refusal to name implementers: $err"
[[ ! -e "$nobody/.cerebro/roster.conf" ]] || fail "nobody: a roster was written"
pass "zero implementers refuses, naming it, and writes no roster"

# An answer that is neither of the offered words is refused rather than read as one of them.
typo="$(new_consumer typo)"
answers="$work_dir/typo-answers"
{ printf '\n\n\n\n\n\n\n'; printf '\n\n\n\n\n\n'; printf 'autostrat\n'; } > "$answers"
run_install "$all" "$typo"
answers=/dev/null
[[ $status -eq 1 ]] || fail "typo: expected exit 1, got $status"
grep -q 'autostrat' <<<"$err" || fail "typo: expected the bad word named: $err"
[[ ! -e "$typo/.cerebro/roster.conf" ]] || fail "typo: a roster was written"
pass "a misspelt start word refuses, naming it"

# --- 5. the agent settings: tool, models, effort, and an external source on copilot ----------------
# field <line> <n>  ->  the n-th tab-separated field of an agents-conf answer
field() { awk -F'\t' -v n="$2" '{print $n}' <<<"$1"; }
settings_at() { "$1/.claude/cerebro/scripts/agents-conf" "${@:2}"; }

# The defaults alone (`linked' again): claude, opus, medium effort, the implementers the same.
line="$(settings_at "$linked" --name Cyclops --role implementer)"
[[ "$(field "$line" 1)" == hit && "$(field "$line" 2)" == implementer ]] || fail "settings defaults: implementer line: $line"
[[ "$(field "$line" 3)" == claude && "$(field "$line" 4)" == opus && "$(field "$line" 5)" == medium ]] \
  || fail "settings defaults: expected claude/opus/medium for implementers, got: $line"
line="$(settings_at "$linked" --name Forge --role architect)"
[[ "$(field "$line" 2)" == default && "$(field "$line" 3)" == claude && "$(field "$line" 4)" == opus ]] \
  || fail "settings defaults: expected the architect to fall to default, got: $line"
for r in ux build-design orchestrator verifier reviewer user-feedback architect; do
  grep -Eq "^#[[:space:]]*$r[[:space:]]+tool=" "$linked/.cerebro/agents.conf" || fail "settings defaults: no commented line for $r"
done
pass "the default settings: claude on opus at medium, implementers the same, other roles commented out"

# Copilot with an external source: the source is defined, and the model answers name it.
ext="$(new_consumer ext)"
answers="$work_dir/ext-answers"
{
  printf '\n\n\n\n\n\n\n'                        # project.conf
  printf '\n\n\n\n\n\n\n\n\n\n\n\n'              # the fleet, every default: six counts, six roles
  printf 'copilot\ny\n\n\n\ngpt-5.4\n'            # tool; external: yes, name, url, key variable, model id
  printf '\nhigh\n\nlow\n'                        # default model (the source), effort; implementer model, effort
} > "$answers"
run_install "$all" "$ext"
answers=/dev/null
[[ $status -eq 0 ]] || fail "ext: expected exit 0, got $status; stderr: $err"
line="$(settings_at "$ext" --name Cyclops --role implementer)"
[[ "$(field "$line" 3)" == copilot && "$(field "$line" 5)" == low && "$(field "$line" 6)" == external ]] \
  || fail "ext: expected an external copilot implementer at low, got: $line"
[[ "$(field "$line" 7)" == research && "$(field "$line" 8)" == openai \
   && "$(field "$line" 9)" == "https://api.openai.com/v1" && "$(field "$line" 10)" == OPENAI_API_KEY ]] \
  || fail "ext: the external definition did not come back whole: $line"
[[ "$(field "$line" 4)" == gpt-5.4 ]] || fail "ext: expected the external's model id as the model, got: $line"
line="$(settings_at "$ext" --name Forge --role architect)"
[[ "$(field "$line" 5)" == high && "$(field "$line" 6)" == external ]] || fail "ext: the default line: $line"
pass "copilot with an external OpenAI-compatible source: defined once, named by the model answers"

# On claude there is no external question at all.
cl="$(new_consumer cl)"
answers="$work_dir/cl-answers"
{ printf '\n\n\n\n\n\n\n'; printf '\n\n\n\n\n\n\n\n\n\n\n\n'; printf 'claude\nsonnet\n\nhaiku\n\n'; } > "$answers"
run_install "$all" "$cl"
answers=/dev/null
[[ $status -eq 0 ]] || fail "cl: expected exit 0, got $status; stderr: $err"
! grep -qi 'external' <<<"$out" || fail "cl: claude was asked about an external source: $out"
line="$(settings_at "$cl" --name Cyclops --role implementer)"
[[ "$(field "$line" 4)" == haiku && "$(field "$line" 6)" == ordinary ]] || fail "cl: implementer: $line"
line="$(settings_at "$cl" --name Forge --role architect)"
[[ "$(field "$line" 4)" == sonnet ]] || fail "cl: default model: $line"
pass "on claude the external source is not asked about, and the models are the answers"

# A tool this cerebro cannot run is refused, naming the ones it can.
badtool="$(new_consumer badtool)"
answers="$work_dir/badtool-answers"
{ printf '\n\n\n\n\n\n\n'; printf '\n\n\n\n\n\n\n\n\n\n\n\n'; printf 'gemini\n'; } > "$answers"
run_install "$all" "$badtool"
answers=/dev/null
[[ $status -eq 1 ]] || fail "badtool: expected exit 1, got $status"
grep -q 'gemini' <<<"$err" && grep -q 'claude' <<<"$err" && grep -q 'copilot' <<<"$err" \
  || fail "badtool: expected the bad tool and the known ones named: $err"
[[ ! -e "$badtool/.cerebro/agents.conf" ]] || fail "badtool: agents.conf was written"
pass "an unknown tool refuses, naming the known ones, and writes nothing"

suite_passed
