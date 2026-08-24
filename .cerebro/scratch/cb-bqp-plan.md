## Context

The liveness rule — *a pid is that agent's session when its own command line carries a whole-word
`--name <Name>` and a `--settings` path under this consumer's root, as a whole path component* — is
implemented twice: `cerebro--session-args-p` (`emacs/cerebro.el:166`, built from
`cerebro--name-in-args-p` at :140 and `cerebro--root-in-args-p` at :145) and `scripts/agent-alive`
(the `grep -Eq -- "--name…"` line and the `case "$settings_dir" in "$repo_root"/*` block). The two
implementations are legitimate — elisp must not spawn six subprocesses per agent per refresh, and bash
cannot call elisp — but their **case lists** are two hand-copied suites, `emacs/cerebro-test.el` and
`tests/agent-alive.sh`, and they have already diverged: the ERT side pins the sibling-prefix root
rule (`/repos/cerebro` is not `/repos/cerebro-hud`,
`cerebro-test/consumer-args-does-not-match-a-sibling-with-the-same-prefix`) and the bash side has no
such case at all, though `agent-alive` implements the guard. Every correction to the rule has landed
twice, days apart (see the bead's description for the commit pairs).

What changes when this lands: the cases about the rule itself — *(command line, name, root) →
alive/dead* — live in **one tracked table**, `tests/lib/session-args.cases`, and **both** suites run
every row of it. A row added on either side fails the other implementation until it answers the
same, which is what the "mirror" was supposed to guarantee. A new lint check advises when either
suite stops reading the table, so the guard cannot quietly lapse.

**Decision, and why not the stronger option.** The bead offers "one implementation, with elisp
shelling out to `agent-alive`". Declined: `cerebro--session-alive-p` runs once per agent on every
fleet-view refresh, `agent-alive` itself runs `roster`, `consumer-root`, `jq`, `ps`, `grep` and `sed`
— six subprocesses per call, so ~120 per refresh on a twenty-name roster — and it would move the rule
from the pure, ERT-tested core into an impure reader, which the file's design forbids (CLAUDE.md,
"Keep new logic on the pure side or it becomes untestable"). Two implementations held to one case
table is the simple design; say so if a reviewer asks.

**What the table deliberately does NOT hold.** Each side has cases about how it *obtains* the args
and the root, and those are not the rule and stay in their own suite:

- elisp-only: a root spelled `~/…` (`cerebro-test/one-rule-takes-a-root-spelled-with-a-tilde`) and a
  root with a trailing slash (`cerebro-test/consumer-args-takes-a-root-with-or-without-a-trailing-slash`)
  — `consumer-root --shared` is always physical and absolute, so bash can never see either.
- bash-only: no state file, no `pid` field, a pid that is not a single integer, a pid that has
  exited, a name not on the roster (exit 2), usage errors — `process-attributes` takes an integer and
  elisp reads no roster here.

The table's header says this in its own words, so the next person adding a case knows which file it
goes in.

## Files to change, and what to reuse

### New: `tests/lib/session-args.cases` (tracked data, read by both suites)

`tests/lib/` is the right home: `scripts/suite-runner` runs `tests/*.sh` only, so nothing there is
ever run as a suite, and `tests/lint.sh` copies `tests` whole into its fixture, so the lint check
below sees the table there too.

Format, one case per line, fields separated by runs of spaces or tabs; the **fourth field is the rest
of the line** (a command line contains spaces). `#` lines and blank lines are ignored.

```
<expect>  <name>  <root>  <args…>
```

- `expect` — `alive` or `dead`, nothing else.
- `name` — the name asked about. Always a name on the **built-in** roster (`scripts/roster`'s
  `TABLE=`: `Cyclops`, `Storm`, `Beast`, …), because the bash runner's fixture has no
  `.cerebro/roster.conf` and so runs the built-in fleet, and `agent-alive` exits 2 for a name it
  does not know. The name *inside* the args need not be on the roster (`Cyclopsly` is not).
- `root` — `{root}` or `{other}`, never a literal path. Each runner substitutes its own two roots.
- `args` — the command line **after the program name**. Every `--settings` path is spelled under
  `{root}`, `{other}` or `{root}-hud` and ends in `/.claude/cerebro/hooks/question-state.settings.json`
  or `/.claude/cerebro/scripts/../hooks/question-state.settings.json`; the bash runner creates exactly
  those three `hooks` directories, because `agent-alive` resolves the settings directory physically
  (`cd … && pwd -P`) and a directory that does not exist reads dead whatever the row expects. A row
  that names a different directory is a row that cannot pass on the bash side.

Header comment (ship this text, adjusted only if a sentence is untrue by then), then the rows:

```
# The liveness rule's cases, run by BOTH implementations of the rule:
#
#   cerebro--session-args-p   (emacs/cerebro.el)   via emacs/cerebro-test.el
#   scripts/agent-alive       (bash)                via tests/agent-alive.sh
#
# The rule: a pid is <name>'s session of the fleet at <root> when its own command line carries a
# whole-word `--name <name>' AND a `--settings' path under <root>, as a whole path component.
# Add a case here and BOTH suites run it; a case that only one side answers is a divergence, which
# is what this file exists to make impossible. Before this table each side kept its own list and
# the two drifted, twice.
#
# Format:  <alive|dead>  <name>  <{root}|{other}>  <command line after the program name>
#   - fields are separated by runs of blanks; the command line is the rest of the line
#   - <name> must be on the built-in roster (scripts/roster): the bash runner's fixture declares
#     no roster of its own, and agent-alive refuses a name it does not know
#   - a --settings path is under {root}, {other} or {root}-hud, in .claude/cerebro/hooks/ (directly
#     or as scripts/../hooks/): the bash runner creates those three directories and no other, and
#     agent-alive resolves the directory physically before comparing
#
# NOT here, because they are about how one side OBTAINS the args or the root, not about the rule:
# elisp's tilde-spelled and trailing-slash roots (consumer-root is always physical and absolute),
# and bash's no-state-file / no-pid / pid-not-an-integer / pid-exited / not-on-the-roster cases
# (process-attributes takes an integer, and elisp reads no roster here). Those stay in their suite.

# the launcher's own shape: alive in its consumer
alive  Cyclops  {root}   --agent implementer --name Cyclops --remote-control Cyclops --permission-mode auto --settings {root}/.claude/cerebro/scripts/../hooks/question-state.settings.json
alive  Cyclops  {root}   --name Cyclops --settings {root}/.claude/cerebro/hooks/question-state.settings.json
# the name: another agent's session, a name that is only a prefix of the one in the args, the name
# only as a --remote-control value, a flag that merely contains "-name-"
dead   Beast    {root}   --name Cyclops --settings {root}/.claude/cerebro/hooks/question-state.settings.json
dead   Cyclops  {root}   --name Cyclopsly --settings {root}/.claude/cerebro/hooks/question-state.settings.json
dead   Cyclops  {root}   --agent implementer --remote-control Cyclops --permission-mode auto --settings {root}/.claude/cerebro/hooks/question-state.settings.json
dead   Cyclops  {root}   --remote-control-session-name-prefix Cyclops --name Storm --settings {root}/.claude/cerebro/hooks/question-state.settings.json
alive  Storm    {root}   --remote-control-session-name-prefix Cyclops --name Storm --settings {root}/.claude/cerebro/hooks/question-state.settings.json
# the root: a hand-typed session naming no root, the same name in another consumer, and a sibling
# checkout whose path merely starts with this one's
dead   Cyclops  {root}   --name Cyclops
dead   Cyclops  {root}   --name Cyclops --settings {other}/.claude/cerebro/hooks/question-state.settings.json
alive  Cyclops  {other}  --name Cyclops --settings {other}/.claude/cerebro/hooks/question-state.settings.json
dead   Cyclops  {root}   --name Cyclops --settings {root}-hud/.claude/cerebro/hooks/question-state.settings.json
```

The last row is the case the bash side is missing today. Every other row is one an existing case in
one suite or the other already makes; the point is that now both make all of them.

### `tests/agent-alive.sh`

Reuse everything already there: `new_fixture` (`consumer_new … --link roster agent-alive
consumer-root`), `write_state`, `run_alive`, the `strays` array and `suite_cleanup`, `fail`/`pass`
from `tests/lib/consumer.sh`. `$repo_root` is already the submodule root, so the table is
`"$repo_root/tests/lib/session-args.cases"`.

**Replace** these hand-written cases with the table loop, since every one of them is a row now:
`alive-for-a-live-pid-that-names-the-agent`, `dead-for-a-live-pid-whose-name-is-only-a-prefix`,
`dead-for-a-live-pid-with-the-name-as-a-prefix-of-its-own`,
`dead-for-the-same-name-in-another-consumer`, `alive-in-its-own-consumer`,
`dead-for-a-session-that-names-no-root`. The `prefix_name`/`suffixed_name` roster lookup goes with
them (the fixture runs the built-in roster, so the table names `Cyclops` and `Storm` directly — say
so in the comment where those cases were).

**Keep** unchanged: `dead-for-a-live-pid-that-is-not-that-session` (uses `$$`, a process whose args
the table cannot describe), `dead-for-a-pid-that-no-longer-exists`, `dead-when-there-is-no-state-file`,
`dead-when-the-state-file-has-no-pid`, `dead-when-the-pid-is-not-a-single-integer`,
`refuses-a-name-that-is-not-on-the-roster`, `usage-without-a-name`, `usage-with-more-than-a-name`.

The loop, to ship as written (place it where the removed cases were, after
`dead-for-a-live-pid-that-is-not-that-session`):

```bash
# --- every row of the shared case table ---
# The rule's cases live in tests/lib/session-args.cases and cerebro-test.el runs the same rows
# against cerebro--session-args-p: a row one side answers differently is the drift this table
# exists to catch. Each row becomes a live process with exactly that command line, a state file
# naming its pid, and one agent-alive call from the row's root.
cases="$repo_root/tests/lib/session-args.cases"
[[ -r "$cases" ]] || fail "session-args table: cannot read $cases"
tmp="$(new_fixture)"
other="$(new_fixture)"
# The three directories the table's --settings paths may name. agent-alive resolves the settings
# directory physically before comparing, so a directory that does not exist reads dead whatever the
# row expects - and {root}-hud is the sibling-prefix case, a checkout beside this one whose path
# merely starts with this one's.
mkdir -p "$tmp/.claude/cerebro/hooks" "$other/.claude/cerebro/hooks" "$tmp-hud/.claude/cerebro/hooks"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmp/fake-session"
chmod +x "$tmp/fake-session"
rows=0
while read -r expect name root args; do
  case "$expect" in ''|'#'*) continue ;; esac
  case "$root" in
    '{root}')  root="$tmp" ;;
    '{other}') root="$other" ;;
    *) fail "session-args table: row $((rows+1)) names a root that is not {root} or {other}: $root" ;;
  esac
  args="${args//\{root\}/$tmp}"
  args="${args//\{other\}/$other}"
  # Unquoted on purpose: a row is a command line, and the process must carry it as separate
  # arguments the way `scripts/launch' passes them. No row carries a quoted or globbing argument.
  # shellcheck disable=SC2086
  bash "$tmp/fake-session" $args &
  pid=$!
  strays+=("$pid")
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do strays+=("$child"); done
  write_state "$root" "$name" "{\"state\":\"working\",\"pid\":$pid}"
  case "$expect" in
    alive)
      run_alive "$root" "$name" \
        || fail "session-args row $((rows+1)): expected alive, reported dead ($name at $root: $args)" ;;
    dead)
      if run_alive "$root" "$name"; then
        fail "session-args row $((rows+1)): expected dead, reported alive ($name at $root: $args)"
      fi ;;
    *) fail "session-args table: row $((rows+1)) expects '$expect', not alive or dead" ;;
  esac
  rows=$((rows+1))
done < "$cases"
# A table nobody can read, or one that went empty, must not pass as "every row held".
[[ "$rows" -ge 2 ]] || fail "session-args table: only $rows rows read from $cases"
pass "every row of tests/lib/session-args.cases holds for agent-alive ($rows rows)"
```

Notes the implementer needs: `read -r expect name root args` with the default `IFS` strips leading
blanks and hands the *rest of the line* to `args`, internal spacing intact — that is what makes the
fourth column free-form. The row counter is incremented after the checks so the number in a failure
message is the row's 1-based position among *case* lines, not file lines; that is fine, the args are
in the message too. `$tmp-hud` sits beside `$tmp` under `$work_dir`, so the library's cleanup removes
it.

### `emacs/cerebro-test.el`

Reuse `cerebro-test--repo-root` (line 13; already used to reach
`templates/consumer-dir-locals.el` at line 276, so reading a repository file from a test has
precedent). The core, `emacs/cerebro.el`, is **not changed** by this bead except its docstring (below).

Add, next to the existing consumer-args cases (after
`cerebro-test/consumer-args-takes-a-root-with-or-without-a-trailing-slash`, ~line 129):

```elisp
(defconst cerebro-test--session-args-cases-file
  (expand-file-name "tests/lib/session-args.cases" cerebro-test--repo-root)
  "The case table both implementations of the liveness rule run.
`tests/agent-alive.sh' runs the same rows against `scripts/agent-alive'.")

(defun cerebro-test--session-args-cases (root other)
  "The rows of `cerebro-test--session-args-cases-file' as (EXPECT NAME ROOT ARGS).
EXPECT is t for `alive' and nil for `dead'; {root} and {other} in the file
are replaced by ROOT and OTHER, and ARGS gets the program name prepended,
since the table holds the command line after it.  A malformed row is an
error, not a skipped case."
  (let ((sub (lambda (s)
               (replace-regexp-in-string
                "{other}" other (replace-regexp-in-string "{root}" root s t t) t t)))
        rows)
    (with-temp-buffer
      (insert-file-contents cerebro-test--session-args-cases-file)
      (dolist (line (split-string (buffer-string) "\n" t))
        (unless (string-match-p "\\`[ \t]*\\(#\\|\\'\\)" line)
          (unless (string-match
                   "\\`[ \t]*\\([^ \t]+\\)[ \t]+\\([^ \t]+\\)[ \t]+\\([^ \t]+\\)[ \t]+\\(.*\\)\\'"
                   line)
            (error "session-args.cases: malformed row: %s" line))
          (push (list (pcase (match-string 1 line)
                        ("alive" t)
                        ("dead" nil)
                        (other-word (error "session-args.cases: expects %S, not alive or dead"
                                           other-word)))
                      (match-string 2 line)
                      (funcall sub (match-string 3 line))
                      (concat "claude " (funcall sub (match-string 4 line))))
                rows))))
    (nreverse rows)))

(ert-deftest cerebro-test/session-args-table-is-read-and-not-empty ()
  "A table that went missing or empty must not pass as \"every row held\"."
  (let ((rows (cerebro-test--session-args-cases "/Users/x/repos/cerebro" "/Users/x/repos/elsewhere")))
    (should (cl-some #'car rows))
    (should (cl-some (lambda (r) (not (car r))) rows))))

(ert-deftest cerebro-test/session-args-p-answers-every-row-of-the-shared-table ()
  "The one rule, over the cases both implementations run.
The same rows drive `scripts/agent-alive' in its own suite; a row this
function answers differently from the script is the drift the table exists
to catch."
  (dolist (row (cerebro-test--session-args-cases "/Users/x/repos/cerebro" "/Users/x/repos/elsewhere"))
    (pcase-let ((`(,expect ,name ,root ,args) row))
      (ert-info ((format "row: %s %s %s" (if expect "alive" "dead") name args))
        (should (eq expect (and (cerebro--session-args-p args name root) t)))))))
```

Then rewrite `cerebro-test/scan-path-and-pid-path-apply-one-rule` (line 231) to iterate the table
instead of its inline list — same assertion, `dolist` over
`(cerebro-test--session-args-cases "/Users/x/repos/cerebro" "/Users/x/repos/elsewhere")`, using each
row's `args` and `root` and asking for the row's `name`. Keep its docstring.

**Remove** the three tests whose every assertion is now a row:
`cerebro-test/session-args-p-requires-the-name-and-the-root-together` (line 211) — except its last
assertion, `(should-not (cerebro--session-args-p nil "Xavier" root))`, which the table cannot express
(a non-string is not a command line); keep that one line as a test named
`cerebro-test/session-args-p-rejects-a-non-string`;
`cerebro-test/consumer-args-does-not-match-a-sibling-with-the-same-prefix` (line 199);
`cerebro-test/consumer-args-drops-a-session-that-names-no-root-at-all` (line 204).

**Keep**: `cerebro-test/name-in-args-reads-only-the-name-flag` (a unit test of the helper on its own —
cheap, and it names the ah-qym reason), `cerebro-test/consumer-args-keeps-only-this-consumers-sessions`,
`…-takes-a-root-with-or-without-a-trailing-slash`, `…-one-rule-takes-a-root-spelled-with-a-tilde`,
and everything from `derive-interactive-…` down. `cerebro-test--this-consumer-args` and
`cerebro-test--other-consumer-args` stay; they are used by the derive tests.

Emacs 28.2 is in CI: `pcase-let`, `ert-info`, `replace-regexp-in-string` with FIXEDCASE and LITERAL
are all available there; do not use `string-replace` or `string-search` (28.1+, fine) — the plan
picks `replace-regexp-in-string` so nothing has to be checked.

### `emacs/cerebro.el` — docstring only

`cerebro--session-args-p` (line 166) ends "`scripts/agent-alive\=' is the bash copy of this function
and is held to it by `tests/agent-alive.sh\='." Change the last clause to: "and both are held to
`tests/lib/session-args.cases\=', the one case table their two suites run." No code change; the
byte-compile step still runs.

### `scripts/agent-alive` — header comment only

Its header says "see cerebro--session-args-p, of which this script is the bash copy." Add one
sentence after it: `Its cases are tests/lib/session-args.cases, which tests/agent-alive.sh and
emacs/cerebro-test.el both run - add a case there, not in one suite.`

### `scripts/lint` — check 16

After check 15 (line ~546) and before the final `if [[ $status -eq 0 ]]`, in the numbered-check
style the file uses:

```bash
# --- 16. both liveness suites read the shared case table ---
#
# The liveness rule has two implementations by design (elisp cannot afford a subprocess per agent
# per refresh; bash cannot call elisp), and their cases live in ONE table so that a case added on
# either side runs on both. That only holds while both suites read it: a suite that stops is a
# suite that has quietly gone back to its own list, which is how the two drifted twice before.
fired=0
table=tests/lib/session-args.cases
[[ -f "$table" ]] || { advisory "$table does not exist - the liveness rule's cases have no shared home"; fired=1; }
for f in tests/agent-alive.sh emacs/cerebro-test.el; do
  grep -qF 'session-args.cases' "$f" 2>/dev/null \
    || { advisory "$f no longer reads $table - the two liveness implementations can drift again"; fired=1; }
done
((fired)) || ok "both liveness suites read $table"
```

### `tests/lint.sh`

One planted-violation case, **appended at the end of the suite** (after the retired-worktree case,
before the final `echo`), in the existing shape — mutate the fixture copy, run the lint, assert the
advisory names the file. The fixture is cumulative (earlier cases append to it and never restore),
so putting this case last and restoring afterwards keeps every earlier assertion untouched:

```bash
# --- a liveness suite that stops reading the shared case table ------------------------------------
sed -i.bak '/session-args.cases/d' "$fixture/tests/agent-alive.sh"
set +e
out="$(bash "$lint" "$fixture" 2>&1)"
set -e
grep -q '^ADVISORY: tests/agent-alive.sh no longer reads tests/lib/session-args.cases' <<<"$out" \
  || fail "lint with a suite that dropped the case table: the advisory did not name tests/agent-alive.sh
$out"
mv "$fixture/tests/agent-alive.sh.bak" "$fixture/tests/agent-alive.sh"
pass "a liveness suite that stops reading the case table fires an advisory naming the file"
```

`sed -i.bak` is the one spelling BSD and GNU sed both accept. The "every check reports" case counts
`>= 10` reporters, so one more `ok -` line needs no change there.

### `CLAUDE.md`

Lines 354–355: "It is the bash copy of `cerebro--session-args-p` — pid, name and root — and
`tests/agent-alive.sh` mirrors the ERT cases so the two cannot drift apart again (they did, twice:
`7bd5962`, `9420ff2`)." Replace with: "It is the bash copy of `cerebro--session-args-p` — pid, name
and root — and both are held to one case table, `tests/lib/session-args.cases`, which
`tests/agent-alive.sh` and `emacs/cerebro-test.el` both run in full, so a case added on either side
fails the other until both answer it (they drifted twice before the table existed: `7bd5962`,
`9420ff2`; lint check 16 advises if either suite stops reading it)." Also, in the **Gotchas** bullet
that begins "`scripts/agent-alive <Name>` is the one place bash answers", nothing changes.

## Increments

Each opens with a failing test, then the smallest change that makes it green, then the whole gate.

1. **The table exists and the bash suite runs it, sibling-prefix case included.**
   RED: add the loop above to `tests/agent-alive.sh` and the table file with **only** the last row
   (`{root}-hud`, dead) — run `bash tests/agent-alive.sh`; it fails at `only 1 rows read`
   (the `≥ 2` floor). Add the remaining rows; it must now pass every row — if the `{root}-hud` row
   reports alive, `agent-alive`'s `case "$settings_dir" in "$repo_root"/*` guard is broken and that
   is the bug, not the test. Then delete the six replaced hand-written cases and run again.
2. **The ERT suite runs the same table.**
   RED: add `cerebro-test--session-args-cases`, the two new `ert-deftest`s, and the rewritten
   `scan-path-and-pid-path-apply-one-rule`; before touching the table, temporarily point
   `cerebro-test--session-args-cases-file` at a name that does not exist and watch
   `session-args-table-is-read-and-not-empty` fail with a file error — proof the test reads the file
   rather than a cached constant. Restore the path; all three pass. Remove the three replaced tests
   and add `session-args-p-rejects-a-non-string`.
3. **The lint guards the arrangement.**
   RED: add the `tests/lint.sh` case first; `bash tests/lint.sh` fails because no advisory fires.
   Add check 16; green. Then `bash scripts/lint` on this tree must print `ok - both liveness suites
   read tests/lib/session-args.cases`.
4. **Prose follows the code.** The `cerebro--session-args-p` docstring, the `agent-alive` header,
   `CLAUDE.md`. `bash tests/gate` green.

## The test plan

- `tests/agent-alive.sh` — the table loop (`every row of tests/lib/session-args.cases holds for
  agent-alive (11 rows)`) plus the eight kept bash-only cases. Pins: every row answers as the table
  says, and the sibling-prefix root case now runs in bash.
- `emacs/cerebro-test.el` — `cerebro-test/session-args-table-is-read-and-not-empty` (the file is
  read and has both verdicts in it), `cerebro-test/session-args-p-answers-every-row-of-the-shared-table`
  (the rule, row by row, each failure naming its row through `ert-info`),
  `cerebro-test/scan-path-and-pid-path-apply-one-rule` (the scan composition agrees with the pid path
  on every row), `cerebro-test/session-args-p-rejects-a-non-string`.
- `tests/lint.sh` — a fixture whose `tests/agent-alive.sh` no longer mentions the table gets an
  advisory naming that file.
- Suites that must run: `bash tests/gate` — byte-compile, all of ERT, every `tests/*.sh`. CI runs
  ERT on Emacs 28.2 and 30.1 and the bash suites on ubuntu; `ps -o args= -p` and `pgrep -P` are
  already what the suite uses on both.

## User-facing decisions

None. This bead touches tests, a data file, a lint check and comments; nothing the audience sees.

## Out of scope

- Collapsing the two implementations into one (see *Context* for why not).
- Moving elisp's tilde/trailing-slash cases or bash's file/pid/roster cases into the table — they
  are about each side's inputs, not the rule, and the table header says so.
- Touching `cerebro--live-implementer-names`, `cerebro--session-pids` or any caller of the rule.
- A table format richer than four whitespace-separated columns (no quoting, no escapes). If a future
  case needs a quoted argument, that is the day to extend the format, not this one.

## Validation

```bash
bash tests/agent-alive.sh                 # ends: all agent-alive tests passed; the table line says 11 rows
emacs --batch -L emacs -l cerebro-test \
  --eval '(ert-run-tests-batch-and-exit "session-args\\|one-rule")'
bash tests/lint.sh
bash scripts/lint | grep 'session-args'  # ok - both liveness suites read tests/lib/session-args.cases
bash tests/gate                           # gate: green
```

Nothing here needs a human to look at anything.

## Known traps

- **`{root}-hud` must exist on disk for the bash row to mean anything.** `agent-alive` does `cd
  "$(dirname "$settings")" && pwd -P` and reads a missing directory as dead — so a sibling-prefix
  row against a directory that was never created passes for the wrong reason. The `mkdir -p` of all
  three `hooks` directories before the loop is load-bearing; keep it.
- **`read` and the fourth column.** `while read -r expect name root args` only works because `args`
  is the *last* variable; add a fifth column and the free-form command line breaks. Do not reorder.
- **`shellcheck` SC2086 on the unquoted `$args` is intended**; the disable comment says why. Quoting it would pass the whole row as one argument and every alive row
  would read dead.
- **`pgrep -P` immediately after `&` may not see the `sleep` child yet** — the existing suite has
  the same race and tolerates it: a missed child is a 30-second `sleep` that exits on its own, not a
  failed assertion.
- **The ERT fixture path is captured at load time** (`cerebro-test--repo-root` uses
  `load-file-name`); a `defconst` built from it must be top-level in the file, not computed inside
  a test body, or it is nil there. The plan's `defconst` is top-level for that reason.
- **`tests/lint.sh` copies this tree's `tests/` into its fixture**, so the table is present there;
  but it copies at the *start* of the suite — a check that reads the table's contents (this one
  only checks existence and the two mentions) would see the committed file, not an edited one.
- **The `docs-in-suites` lint rule** forbids the string `docs/` followed by a letter anywhere under
  `tests/` and in `cerebro-test.el`; the table and the new test code must not mention `docs/…`.
- **A `.elc` left behind** by a manual `batch-byte-compile` shadows the source for every later ERT
  run; `tests/gate` removes it, a hand run does not — `rm -f emacs/cerebro.elc` if a test seems to
  ignore an edit.
