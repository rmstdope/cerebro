;;; cerebro-test.el --- Tests for cerebro.el -*- lexical-binding: t; -*-

;; Run from the repository root with:
;;   emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit
;; One test:
;;   emacs --batch -L emacs -l cerebro-test \
;;     --eval '(ert-run-tests-batch-and-exit "<name-or-regexp>")'

(require 'ert)
(require 'cerebro)

;; The suite exercises code that writes the fleet view's own log, and
;; `cerebro--repo-root' resolves from `default-directory' - which, running the
;; tests, is this repository. So ERT was appending fabricated `start' and
;; `exit' lines to the LIVE .cerebro/state/decisions.jsonl: twelve Forge exits
;; reading "cerebro: boom" and six Cyclops starts, from one morning's gate
;; runs. That log is the record the navigator reads to answer "why did nothing
;; happen", and a test writing to it makes the one piece of evidence untrue.
(setq cerebro-log-verbosity 'none)

(defconst cerebro-test--repo-root
  (expand-file-name ".." (file-name-directory
                           (or load-file-name buffer-file-name)))
  "The repository root: the parent of the directory holding this file.
Captured at load time - `load-file-name' is nil once loading is done, so a
test body cannot compute this itself.")

(defun cerebro-test--place-scripts (dir &rest args)
  "Place scripts into DIR.  ARGS is script names, optionally led by \"--copy\".
Shells out to `tests/lib/place-scripts\=', the one place that knows which
libraries a script sources - so a `source\=' line added to a script under
`scripts/\=' needs no edit here (cb-u70)."
  (let* ((copy (equal (car args) "--copy"))
         (names (if copy (cdr args) args)))
    (should (eq 0 (apply #'call-process
                         (expand-file-name "tests/lib/place-scripts"
                                           cerebro-test--repo-root)
                         nil nil nil
                         (append (when copy (list "--copy")) (list dir) names))))))

;; ---------------------------------------------------------------------------
;; Increment 1: the pure derivation

(defconst cerebro-test--interactive
  '(("Xavier" . "planner")
    ("Cerebro" . "orchestrator")
    ("Moira" . "user-feedback")))

;; The liveness predicate is asked about a pid *and* the name whose file claims
;; it (ah-rogue): "is this pid a live session of this agent", not "does this pid
;; exist". Both helpers ignore the name, which is what makes every test written
;; before that distinction existed still mean what it meant.
(defun cerebro-test--always-alive (_pid &optional _name) t)
(defun cerebro-test--never-alive (_pid &optional _name) nil)
(defun cerebro-test--unverified (_pid &optional _name) 'unverified)

(ert-deftest cerebro-test/derive-implementer-working-from-live-state-file ()
  (let* ((states '(("Cyclops" . ((state . "working") (bead . "ah-f9c")
                                  (since . "2026-08-14T09:00:00Z") (pid . 4242)))))
         (agents (cerebro--derive '("Cyclops") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'working))
    (should (equal (cerebro-agent-bead agent) "ah-f9c"))
    (should (equal (cerebro-agent-since agent) "2026-08-14T09:00:00Z"))))

(ert-deftest cerebro-test/derive-implementer-idle-between-beads ()
  (let* ((states '(("Wolverine" . ((state . "idle") (bead . nil)
                                    (since . "2026-08-14T09:00:00Z") (pid . 4343)))))
         (agents (cerebro--derive '("Wolverine") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'idle))
    (should (null (cerebro-agent-bead agent)))))

(ert-deftest cerebro-test/derive-implementer-dead-when-pid-gone ()
  (let* ((states '(("Storm" . ((state . "working") (bead . "ah-abc")
                                (since . "2026-08-14T09:00:00Z") (pid . 9999)))))
         (agents (cerebro--derive '("Storm") nil states
                                          #'cerebro-test--never-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'dead))
    (should (null (cerebro-agent-bead agent)))))

(ert-deftest cerebro-test/derive-implementer-dead-when-file-missing ()
  (let* ((states '(("Rogue" . nil)))
         (agents (cerebro--derive '("Rogue") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'dead))))

(ert-deftest cerebro-test/derive-implementer-external-when-not-owned ()
  (let* ((states '(("Gambit" . ((state . "working") (bead . "ah-xyz")
                                 (since . "2026-08-14T09:00:00Z") (pid . 111)))))
         (agents (cerebro--derive '("Gambit") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (cerebro-agent-external agent))))

(ert-deftest cerebro-test/derive-implementer-not-external-when-owned ()
  (let* ((states '(("Gambit" . ((state . "working") (bead . "ah-xyz")
                                 (since . "2026-08-14T09:00:00Z") (pid . 111)))))
         (agents (cerebro--derive '("Gambit") nil states
                                          #'cerebro-test--always-alive nil '("Gambit")))
         (agent (car agents)))
    (should-not (cerebro-agent-external agent))))

(ert-deftest cerebro-test/derive-implementer-keeps-the-file-when-unverified ()
  "The regression test for Wolverine reading `idle' mid-build (ah-ybsr): a
liveness that cannot prove the pid carries this consumer's own root -
`unverified', not `nil' - must not fall back to a default the way `dead'
does. The state file's own state, bead and phase are what the row shows,
with `unverified-pid' set to say the file was trusted rather than proven."
  (let* ((states '(("Cyclops" . ((state . "working") (bead . "ah-f9c")
                                  (phase . "build") (pid . 4242)))))
         (agents (cerebro--derive '("Cyclops") nil states
                                  #'cerebro-test--unverified nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'working))
    (should (equal (cerebro-agent-bead agent) "ah-f9c"))
    (should (equal (cerebro-agent-phase agent) "build"))
    (should (= (cerebro-agent-unverified-pid agent) 4242))))

(ert-deftest cerebro-test/derive-implementer-dead-when-pid-is-not-this-agent ()
  "A `nil' liveness - the recycled-pid case - still reads dead, and carries
no `unverified-pid': the hardening for `unverified' must not swallow
positive evidence against."
  (let* ((states '(("Cyclops" . ((state . "working") (bead . "ah-f9c") (pid . 4242)))))
         (agents (cerebro--derive '("Cyclops") nil states
                                  #'cerebro-test--never-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'dead))
    (should (null (cerebro-agent-unverified-pid agent)))))

(ert-deftest cerebro-test/derive-interactive-keeps-the-file-when-unverified ()
  "The interactive sibling: `waiting' survives an unverified liveness
exactly as an implementer's `working'/bead/phase do."
  (let* ((states '(("Xavier" . ((state . "waiting") (pid . 5151)))))
         (agents (cerebro--derive nil '(("Xavier" . "planner")) states
                                  #'cerebro-test--unverified nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'waiting))
    (should (= (cerebro-agent-unverified-pid agent) 5151))))

(ert-deftest cerebro-test/derive-interactive-up-from-process-args ()
  (let* ((args '("claude --agent planner --name Xavier --print This session is Xavier of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."))
         (agents (cerebro--derive nil cerebro-test--interactive nil
                                          #'cerebro-test--never-alive args nil))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'up))
    (should (cerebro-agent-external xavier))))

(ert-deftest cerebro-test/name-in-args-reads-the-marker-and-not-a-flag ()
  ;; cb-d59.3: the name is proved by cerebro's own marker sentence in the prompt, not by any
  ;; provider's flag. `--name Xavier' is still passed and is no longer evidence, and a name that
  ;; is only a prefix of the one in the marker must not match.
  (should (cerebro--name-in-args-p
           "Xavier" '("claude --agent planner --name Xavier This session is Xavier of the cerebro fleet rooted at /Users/x/repos/cerebro/.")))
  (should-not (cerebro--name-in-args-p
               "Xavier" '("claude --agent planner --name Xavier --remote-control Xavier --permission-mode auto")))
  (should-not (cerebro--name-in-args-p
               "Xavier" '("claude --name Xavier This session is Xavierly of the cerebro fleet rooted at /Users/x/repos/cerebro/.")))
  (should (cerebro--name-in-args-p
           "Storm" '("claude --name Storm This session is Storm of the cerebro fleet rooted at /Users/x/repos/cerebro/.")))
  (should-not (cerebro--name-in-args-p
               "Xavier" '("claude --name Storm This session is Storm of the cerebro fleet rooted at /Users/x/repos/cerebro/."))))

;; The process scan is machine-wide, and a name is only unique inside one consumer: every
;; consumer that takes the built-in roster has a Xavier. Scanning for `--name Xavier' alone
;; showed another repository's planners as `up' in this repository's fleet view, for any role
;; that had never run here and so had no state file to be read first.
(defconst cerebro-test--other-consumer-args
  "claude --agent planner --name Xavier --remote-control Xavier This session is Xavier of the cerebro fleet rooted at /Users/x/repos/atlantis-hud/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."
  "One process's args: a session of the fleet rooted at /Users/x/repos/atlantis-hud.")

(defconst cerebro-test--this-consumer-args
  "claude --agent planner --name Xavier --remote-control Xavier This session is Xavier of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."
  "The same session, of the fleet rooted at /Users/x/repos/cerebro.")

(ert-deftest cerebro-test/consumer-args-keeps-only-this-consumers-sessions ()
  (let ((args (list cerebro-test--other-consumer-args cerebro-test--this-consumer-args)))
    (should (equal (cerebro--consumer-args args "/Users/x/repos/cerebro")
                   (list cerebro-test--this-consumer-args)))
    (should (equal (cerebro--consumer-args args "/Users/x/repos/atlantis-hud")
                   (list cerebro-test--other-consumer-args)))))

(ert-deftest cerebro-test/consumer-args-takes-a-root-with-or-without-a-trailing-slash ()
  ;; `cerebro--repo-root' is a `locate-dominating-file' result, which carries one.
  (let ((args (list cerebro-test--this-consumer-args)))
    (should (equal (cerebro--consumer-args args "/Users/x/repos/cerebro/") args))))

;; --- the shared case table -------------------------------------------------
;; The rule's cases live in one tracked file that BOTH implementations run:
;; `tests/agent-alive.sh' drives `scripts/agent-alive' with the same rows.  A
;; row one side answers differently is the drift the table exists to catch -
;; before it, each side kept its own list and the two diverged, twice.

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

(defconst cerebro-test--beast-args
  "claude --agent planner --name Beast This session is Beast of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."
  "Another name's session of the fleet rooted at /Users/x/repos/cerebro.")

(defconst cerebro-test--duplicate-procs
  (list (cons 70687 (cons 1 cerebro-test--this-consumer-args))
        (cons 32075 (cons 1 cerebro-test--this-consumer-args))
        (cons 47482 (cons 1 cerebro-test--other-consumer-args))
        (cons 70688 (cons 1 cerebro-test--beast-args)))
  "A machine's processes as (PID PPID . ARGS): two Xaviers here, one Xavier in
another consumer, one Beast here.  Every parent is outside the set, so each
is its own session.")

(ert-deftest cerebro-test/session-pids-counts-this-consumers-sessions-of-one-name ()
  "Two sessions of one name is a count, not a yes/no - and another consumer's
same-named session is not one of them (cb-lzi)."
  (let ((mine (cerebro--consumer-processes cerebro-test--duplicate-procs
                                           "/Users/x/repos/cerebro")))
    (should (equal (cerebro--session-pids "Xavier" mine) '(32075 70687)))
    (should (equal (cerebro--session-pids "Beast" mine) '(70688)))
    (should (equal (cerebro--session-pids "Cerebro" mine) nil))
    ;; The other consumer's fleet counts its own Xavier and none of ours.
    (should (equal (cerebro--session-pids
                    "Xavier"
                    (cerebro--consumer-processes cerebro-test--duplicate-procs
                                                 "/Users/x/repos/atlantis-hud"))
                   '(47482)))))

(defconst cerebro-test--copilot-marker
  " This session is Xavier of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."
  "The marker sentence every process of Xavier's session carries.")

(defconst cerebro-test--copilot-shim-args
  (concat "node /opt/homebrew/bin/copilot --agent planner --name Xavier"
          cerebro-test--copilot-marker)
  "The node shim on PATH, which spawns the platform binary as its own child.")

(defconst cerebro-test--copilot-binary-args
  (concat "/opt/homebrew/lib/node_modules/@github/copilot/node_modules/"
          "@github/copilot-darwin-arm64/copilot --agent planner --name Xavier"
          cerebro-test--copilot-marker)
  "The platform binary the shim spawns - the pid the state file names.")

(defconst cerebro-test--copilot-procs
  (list (cons 59806 (cons 59548 cerebro-test--copilot-shim-args))
        (cons 60514 (cons 59806 cerebro-test--copilot-binary-args)))
  "One ordinary Copilot session of Xavier, as two processes (cb-3ks).")

(ert-deftest cerebro-test/a-wrapper-and-the-binary-it-spawns-are-one-session ()
  "The live shape observed on this fleet, 2026-08-27: the `copilot\=' on PATH is
a node shim that passes the whole argv - marker included - to the platform
binary it spawns, so both processes are the same session and a naive count
reads `×2\=' on every row forever (cb-3ks)."
  (let* ((stray (cons 36037 (cons 1 cerebro-test--this-consumer-args)))
         (mine (cerebro--consumer-processes
                (append cerebro-test--copilot-procs (list stray))
                "/Users/x/repos/cerebro"))
         (pair (cerebro--consumer-processes cerebro-test--copilot-procs
                                            "/Users/x/repos/cerebro")))
    ;; The stray is a second session; the shim is not.
    (should (equal (cerebro--session-pids "Xavier" mine) '(36037 60514)))
    ;; Alone, the pair is one session - and the pid kept is the leaf, which is
    ;; the one the state file names.
    (should (equal (cerebro--session-pids "Xavier" pair) '(60514)))
    (let* ((agents (cerebro--derive nil cerebro-test--interactive nil
                                    #'cerebro-test--never-alive
                                    (mapcar #'cerebro--proc-args pair) nil))
           (counted (cerebro--apply-session-counts agents pair))
           (xavier (cl-find "Xavier" counted :key #'cerebro-agent-name :test #'equal)))
      (should (= (cerebro-agent-sessions xavier) 1))
      (should-not (cerebro--duplicated-p xavier)))))

(ert-deftest cerebro-test/a-process-with-no-parent-pid-is-its-own-session ()
  "Where the platform reports no `ppid\=', nil must read as \"its own session\" -
an over-count is a visible `×N\=' the navigator can act on, an under-count
silently hides a real double-start."
  (let ((procs (list (cons 11 (cons nil cerebro-test--this-consumer-args))
                     (cons 22 (cons nil cerebro-test--this-consumer-args)))))
    (should (equal (cerebro--session-pids "Xavier" procs) '(11 22)))
    (should (equal (cerebro--drop-wrappers nil) nil))))

(ert-deftest cerebro-test/apply-session-counts-marks-a-name-with-two-sessions ()
  (let* ((procs (cerebro--consumer-processes cerebro-test--duplicate-procs
                                             "/Users/x/repos/cerebro"))
         (agents (cerebro--derive nil cerebro-test--interactive nil
                                  #'cerebro-test--never-alive
                                  (mapcar #'cerebro--proc-args procs) nil))
         (counted (cerebro--apply-session-counts agents procs))
         (by-name (lambda (name)
                    (cl-find name counted :key #'cerebro-agent-name :test #'equal))))
    (should (= (cerebro-agent-sessions (funcall by-name "Xavier")) 2))
    (should (= (cerebro-agent-sessions (funcall by-name "Cerebro")) 0))
    (should (cerebro--duplicated-p (funcall by-name "Xavier")))
    (should-not (cerebro--duplicated-p (funcall by-name "Cerebro")))
    (should-not (cerebro--duplicated-p (funcall by-name "Moira")))))

(ert-deftest cerebro-test/duplicated-p-reads-an-uncounted-agent-as-one-session ()
  "`sessions\=' is nil until `cerebro--apply-session-counts\=' has run, and a row
that was never counted is not a duplicate."
  (should-not (cerebro--duplicated-p
               (cerebro-test--agent "Xavier" "planner" 'interactive 'up))))

(ert-deftest cerebro-test/one-rule-takes-a-root-spelled-with-a-tilde ()
  "A root `locate-dominating-file\=' abbreviated still matches an absolute command line.

`cerebro--repo-root\=' is that result, and it comes back as \"~/repos/cerebro/\"
whenever the tree is under the home directory - which is where a checkout
normally is.  Every other caller expands it before use, so the abbreviation
was invisible until it reached the one place that compares it as a *string*:
a command line names `/Users/<you>/repos/cerebro/...\=', never `~\=', so the
match failed for every process, `cerebro--session-alive-p\=' answered nil for
every agent, and the view fell through to its no-file branches - reading `up\='
for a role whose state file said `waiting\=', and supervising nobody.  Both
entry points to the rule are pinned here, since both are string matches."
  (let* ((home (expand-file-name "~/"))
         (args (list (concat "claude --agent planner --name Xavier --remote-control Xavier"
                             " This session is Xavier of the cerebro fleet rooted at " home
                             "repos/cerebro/. This sentence is how the fleet view proves the"
                             " session belongs to this checkout; do not remove it."))))
    (should (equal (cerebro--consumer-args args "~/repos/cerebro/") args))
    (should (cerebro--session-args-p (car args) "Xavier" "~/repos/cerebro/"))
    ;; and the sibling rule still holds through the expansion
    (should-not (cerebro--consumer-args args "~/repos/cerebro-hud/"))))

(ert-deftest cerebro-test/the-rule-reads-a-command-line-with-escaped-whitespace ()
  "GNU/Linux `process-attributes\=' escape-quotes the whitespace inside one
argv entry, and cerebro\='s marker is one argument: the very same session
reads \"This\\ session\\ is\\ ...\" there and \"This session is ...\" on
macOS.  Both spellings are the same session and both must answer alive - a
needle spelt with plain spaces passed every fixture on the navigator\='s
machine and matched no process at all in CI (cb-d59.3)."
  (let ((escaped (concat "bash\\ /tmp/s.sh --name Rogue"
                         " This\\ session\\ is\\ Rogue\\ of\\ the\\ cerebro\\"
                         " fleet\\ rooted\\ at\\ /Users/x/repos/cerebro/.\\ This\\"
                         " sentence\\ is\\ how\\ the\\ fleet\\ view\\ proves\\ it.")))
    (should (cerebro--session-args-p escaped "Rogue" "/Users/x/repos/cerebro"))
    ;; and the escaping buys nothing a plain reading would not also refuse
    (should-not (cerebro--session-args-p escaped "Beast" "/Users/x/repos/cerebro"))
    (should-not (cerebro--session-args-p escaped "Rogue" "/Users/x/repos/cerebro-hud"))))

(ert-deftest cerebro-test/session-args-p-rejects-a-non-string ()
  "Not a string is not a command line, and so not a session.
The one case the shared table cannot express: every row of it is a command
line."
  (should-not (cerebro--session-args-p nil "Xavier" "/Users/x/repos/cerebro")))

(ert-deftest cerebro-test/scan-path-and-pid-path-apply-one-rule ()
  "The process scan and the pid path are the same two tests.
`cerebro--consumer-args' then `cerebro--name-in-args-p' is the scan
composition; `cerebro--session-args-p' is the pid path.  A command line that
passes one passes the other, for every row of this table."
  (dolist (row (cerebro-test--session-args-cases "/Users/x/repos/cerebro" "/Users/x/repos/elsewhere"))
    (pcase-let ((`(,_expect ,name ,root ,args) row))
      (ert-info ((format "row: %s %s" name args))
        (should (eq (and (cerebro--session-args-p args name root) t)
                    (and (cerebro--name-in-args-p
                          name (cerebro--consumer-args (list args) root))
                         t)))))))

(ert-deftest cerebro-test/derive-interactive-dead-for-another-consumers-session ()
  ;; The whole chain: another repository's Xavier is scanned, filtered out, and this fleet's
  ;; Xavier - which has no state file - reads `dead' rather than `up'.
  (let* ((args (cerebro--consumer-args (list cerebro-test--other-consumer-args)
                                       "/Users/x/repos/cerebro"))
         (agents (cerebro--derive nil cerebro-test--interactive nil
                                  #'cerebro-test--never-alive args nil))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'dead))))

(ert-deftest cerebro-test/derive-interactive-up-for-this-consumers-session ()
  (let* ((args (cerebro--consumer-args (list cerebro-test--this-consumer-args)
                                       "/Users/x/repos/cerebro"))
         (agents (cerebro--derive nil cerebro-test--interactive nil
                                  #'cerebro-test--never-alive args nil))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'up))
    (should (cerebro-agent-external xavier))))

(ert-deftest cerebro-test/a-scan-entry-whose-pid-has-gone-is-dropped ()
  "A snapshot is evidence about the moment it was taken, and no later.

The scan is cached for `cerebro-system-scan-seconds\=' (30), so for up to half
a minute it lists processes that have since exited - and `--name <Name>\=' in
one of those is exactly what the fallback in `cerebro--derive-interactive\='
reads as \"up, started outside this fleet\". That is what put `up\=' between
`waiting\=' and `standby\=', with `RET\=' offering \"running outside Emacs - use
the terminal that started it\" for a session that had already ended.

It is not only the parked case. A role that ends its own turn exits without
the view killing it, so nothing parks it and there is no park to date the
snapshot against; the pid simply stops being alive. Liveness is the fact that
covers both, and it is the same question `cerebro--session-alive-p\=' already
asks of the pid path - presence in a snapshot is not liveness, the way
presence in an alist was not."
  (let ((procs '((11 1 . "claude --agent planner --name Xavier")
                 (22 1 . "claude --agent planner --name Beast")))
        (alive (lambda (pid) (memq pid '(22)))))
    (should (equal (cerebro--live-processes procs alive)
                   '((22 1 . "claude --agent planner --name Beast"))))
    (should (null (cerebro--live-processes procs #'ignore)))
    (should (equal (cerebro--live-processes procs (lambda (_) t)) procs))
    (should (null (cerebro--live-processes nil (lambda (_) t))))))

(ert-deftest cerebro-test/a-role-whose-session-has-exited-reads-dead-not-up ()
  "The whole chain, for a role that ended its own turn and was never parked."
  (let* ((procs '((11 1 . "claude --agent planner --name Xavier --remote-control Xavier This session is Xavier of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.")))
         (gone (cerebro--live-processes procs #'ignore))
         (still (cerebro--live-processes procs (lambda (_) t))))
    (should (eq (cerebro-agent-state
                 (car (cerebro--derive nil cerebro-test--interactive nil
                                       #'cerebro-test--never-alive
                                       (mapcar #'cerebro--proc-args gone) nil)))
                'dead))
    (should (eq (cerebro-agent-state
                 (car (cerebro--derive nil cerebro-test--interactive nil
                                       #'cerebro-test--never-alive
                                       (mapcar #'cerebro--proc-args still) nil)))
                'up))))

(ert-deftest cerebro-test/derive-interactive-up-when-owned ()
  (let* ((agents (cerebro--derive nil cerebro-test--interactive nil
                                          #'cerebro-test--never-alive nil '("Xavier")))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'up))
    (should-not (cerebro-agent-external xavier))))

(ert-deftest cerebro-test/derive-interactive-dead-when-absent ()
  (let* ((agents (cerebro--derive nil cerebro-test--interactive nil
                                          #'cerebro-test--never-alive nil nil))
         (moira (nth 2 agents)))
    (should (equal (cerebro-agent-name moira) "Moira"))
    (should (eq (cerebro-agent-state moira) 'dead))))

(ert-deftest cerebro-test/derive-order-interactive-first-then-roster ()
  (let* ((agents (cerebro--derive '("Cyclops" "Storm") cerebro-test--interactive nil
                                          #'cerebro-test--never-alive nil nil)))
    (should (equal (mapcar #'cerebro-agent-name agents)
                    '("Xavier" "Cerebro" "Moira" "Cyclops" "Storm")))))

;; ---------------------------------------------------------------------------
;; ah-2n3.2: the interactive five write the same state file an implementer does

(ert-deftest cerebro-test/derive-interactive-reads-a-live-state-file ()
  (let* ((states '(("Psylocke" . ((state . "asking") (bead . "ah-xyz")
                                   (since . "2026-08-15T09:00:00Z")
                                   (phase . "verify")
                                   (phase_since . "2026-08-15T09:10:00Z")
                                   (pid . 555)))))
         (agents (cerebro--derive nil '(("Psylocke" . "verifier")) states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-kind agent) 'interactive))
    (should (eq (cerebro-agent-state agent) 'asking))
    (should (equal (cerebro-agent-bead agent) "ah-xyz"))
    (should (equal (cerebro-agent-phase agent) "verify"))
    (should (equal (cerebro-agent-phase-since agent) "2026-08-15T09:10:00Z"))))

(ert-deftest cerebro-test/derive-interactive-falls-back-to-the-process-scan ()
  ;; A state file exists but its pid is gone - a previous session's leftover,
  ;; same as an implementer's stale file. The row must fall back to the
  ;; process scan rather than reading the dead file's state.
  (let* ((states '(("Xavier" . ((state . "working") (bead . nil)
                                 (since . "2026-08-14T09:00:00Z") (pid . 9999)))))
         (args '("claude --agent planner --name Xavier --print This session is Xavier of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."))
         (agents (cerebro--derive nil cerebro-test--interactive states
                                          #'cerebro-test--never-alive args nil))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'up))
    (should (cerebro-agent-external xavier))))

(ert-deftest cerebro-test/derive-interactive-without-a-file-is-unchanged ()
  ;; No entry for the name in STATES at all: the three original branches -
  ;; owned, in the process args, or absent - are exercised exactly as before
  ;; ah-2n3.2, by `cerebro-test/derive-interactive-up-from-process-args',
  ;; `cerebro-test/derive-interactive-up-when-owned' and
  ;; `cerebro-test/derive-interactive-dead-when-absent' above.  This test
  ;; only pins the empty-states-alist case explicitly, since a caller who
  ;; forgets to gather interactive states must not silently show `dead'.
  (let* ((agents (cerebro--derive nil cerebro-test--interactive '(("Xavier" . nil))
                                          #'cerebro-test--never-alive nil '("Xavier")))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'up))
    (should-not (cerebro-agent-external xavier))))

(ert-deftest cerebro-test/derive-treats-done-as-unknown-for-every-kind ()
  ;; cb-1or.2 retired `done\='.  `scripts/agent-state\=' refuses it from every
  ;; name now, so a live file carrying it is a session older than the running
  ;; fleet: it shows its raw word in yellow, exactly as any word this list has
  ;; never seen does, and is never acted on.
  (let* ((states '(("Forge" . ((state . "done") (bead . nil)
                                 (since . "2026-08-15T09:00:00Z") (pid . 777)))))
         (agents (cerebro--derive nil '(("Forge" . "architect")) states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'unknown))
    (should (equal (cerebro-agent-raw agent) "done")))
  ;; The implementer half, which used to derive `done\='.
  (let* ((states '(("Cyclops" . ((state . "done") (bead . "ah-f9c")
                                 (since . "2026-08-14T09:00:00Z") (pid . 42)))))
         (agents (cerebro--derive '("Cyclops") nil states
                                          #'cerebro-test--always-alive nil
                                          '("Cyclops")))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'unknown))
    (should (equal (cerebro-agent-raw agent) "done"))))

(ert-deftest cerebro-test/supervise-ignores-an-asking-interactive-agent ()
  ;; The `kind' guard in `cerebro--supervise-action' must keep excluding
  ;; interactive agents once they can write `asking' too - nudging, retiring
  ;; or restarting one is not this function's business, ever.
  (let ((agent (make-cerebro-agent :name "Psylocke" :role "verifier" :kind 'interactive
                                           :state 'asking :bead "ah-xyz"
                                           :since "2020-01-01T00:00:00Z" :external nil)))
    (should (null (cerebro--supervise-action agent nil (current-time))))))

;; ---------------------------------------------------------------------------
;; Increment 2: formatting

(ert-deftest cerebro-test/entry-working-implementer-shows-bead-and-elapsed ()
  (let* ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z")))
         (agent (make-cerebro-agent :name "Cyclops" :role "implementer" :kind 'implementer
                                            :state 'working :bead "ah-f9c"
                                            :since "2026-08-14T09:00:00Z" :external nil))
         (entry (cerebro--entry agent now))
         (row (nth 1 entry)))
    (should (equal (aref row 3) "ah-f9c"))
    (should (equal (aref row 4) "12m"))))

(ert-deftest cerebro-test/entry-external-shows-a-dash ()
  "An external agent's bead column used to say \"(external)\", which alone
took the whole 10-column budget. A dash says the same thing in one character
and leaves the column free for real bead ids (see ah-lyc)."
  (let* ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z")))
         (agent (make-cerebro-agent :name "Storm" :role "implementer" :kind 'implementer
                                            :state 'working :bead "ah-f9c"
                                            :since "2026-08-14T09:00:00Z" :external t))
         (entry (cerebro--entry agent now))
         (row (nth 1 entry)))
    (should (equal (aref row 3) "—"))
    (should (equal (aref row 4) ""))))

(ert-deftest cerebro-test/entry-long-bead-id-truncates ()
  "A child bead's id can run past the 10-column Bead budget - up to
\"ah-dzj.1.1.1.1\" in this repository's own database. It truncates with an
ellipsis rather than pushing the rest of the row right; a short id is
unaffected."
  (let* ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z")))
         (long-agent (make-cerebro-agent :name "Cyclops" :role "implementer" :kind 'implementer
                                          :state 'working :bead "ah-dzj.1.1.1.1"
                                          :since "2026-08-14T09:00:00Z" :external nil))
         (short-agent (make-cerebro-agent :name "Storm" :role "implementer" :kind 'implementer
                                           :state 'working :bead "ah-m9q"
                                           :since "2026-08-14T09:00:00Z" :external nil))
         (long-row (nth 1 (cerebro--entry long-agent now)))
         (short-row (nth 1 (cerebro--entry short-agent now))))
    (should (equal (length (aref long-row 3)) 10))
    (should (string-suffix-p "…" (aref long-row 3)))
    (should (equal (aref short-row 3) "ah-m9q"))))

(ert-deftest cerebro-test/entry-dead-has-empty-bead-column ()
  (let* ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z")))
         (agent (make-cerebro-agent :name "Rogue" :role "implementer" :kind 'implementer
                                            :state 'dead :bead nil :since nil :external nil))
         (entry (cerebro--entry agent now))
         (row (nth 1 entry)))
    (should (equal (aref row 3) ""))
    (should (equal (aref row 4) ""))))

(defun cerebro-test--any-bold-p (text)
  "Whether any character of TEXT carries the bold face."
  (let ((bold nil))
    (dotimes (i (length text))
      (when (eq (get-text-property i 'face text) 'bold)
        (setq bold t)))
    bold))

(ert-deftest cerebro-test/entry-asking-emphasises-every-column ()
  "An agent in `asking' wants the navigator's attention, and the navigator
asked for the whole row to say so - not just the Agent, Role and State
columns, but Bead and For too, which are exactly the two facts worth
reading once the row has caught the eye (see ah-axj)."
  (let* ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z")))
         (asking (make-cerebro-agent :name "Storm" :role "implementer" :kind 'implementer
                                      :state 'asking :bead "ah-a1b"
                                      :since "2026-08-14T09:00:00Z" :external nil))
         (working (make-cerebro-agent :name "Cyclops" :role "implementer" :kind 'implementer
                                       :state 'working :bead "ah-f9c"
                                       :since "2026-08-14T09:00:00Z" :external nil))
         (asking-row (nth 1 (cerebro--entry asking now)))
         (working-row (nth 1 (cerebro--entry working now))))
    (dotimes (i 5)
      (should (cerebro-test--any-bold-p (aref asking-row i))))
    (dotimes (i 5)
      (should-not (cerebro-test--any-bold-p (aref working-row i))))))

(ert-deftest cerebro-test/elapsed-minutes-hours-days ()
  (let ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z"))))
    (should (equal (cerebro--elapsed "2026-08-14T09:00:00Z" now) "12m"))
    (should (equal (cerebro--elapsed "2026-08-14T08:09:00Z" now) "1h03"))
    (should (equal (cerebro--elapsed "2026-08-12T09:12:00Z" now) "2d"))))

(ert-deftest cerebro-test/elapsed-nil-since-is-empty ()
  (should (equal (cerebro--elapsed nil (current-time)) "")))

;; ---------------------------------------------------------------------------
;; Increment 3: the buffer

(defconst cerebro-test--fleet-fixture
  '(("Alpha" "planner" interactive) ("Beta" "verifier" interactive)
    ("One" "implementer" implementer) ("Two" "implementer" implementer)
    ("Three" "implementer" implementer)))

(ert-deftest cerebro-test/buffer-lists-every-agent-once ()
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () "/fake/repo"))
            ((symbol-function 'cerebro--fleet)
             (lambda (_repo-root) cerebro-test--fleet-fixture))
            ((symbol-function 'cerebro--gather-states)
             (lambda (_repo-root _roster) nil))
            ((symbol-function 'cerebro--system-processes) (lambda () nil))
            ((symbol-function 'cerebro--owned) (lambda () nil)))
    (unwind-protect
        (progn
          (cerebro)
          (with-current-buffer cerebro-buffer-name
            (should (= (length tabulated-list-entries) (length cerebro-test--fleet-fixture)))
            (should (equal (length (delete-dups (mapcar #'car tabulated-list-entries)))
                            (length cerebro-test--fleet-fixture)))
            (should (equal (sort (mapcar #'car tabulated-list-entries) #'string<)
                            (sort (mapcar #'car cerebro-test--fleet-fixture) #'string<)))))
      (when (get-buffer cerebro-buffer-name)
        (kill-buffer cerebro-buffer-name)))))

(defvar cerebro-test--autostart-launched nil)
(defvar cerebro-test--autostart-cleared nil)
(defvar cerebro-test--autostart-messages nil)
(defvar cerebro-test--autostart-logged nil)
(defvar cerebro-test--standby-fixture nil
  "What the stubbed `cerebro--standby-names\=' returns.

Defaults to nil so every autostart test written before cb-98u means exactly
what it did: a roster that declares no standby row.")

(defmacro cerebro-test--with-autostart (&rest body)
  "Run BODY with the fleet view's impure edges stubbed for autostart.

`cerebro--vterm-available-p\=' is a function of its own precisely so this can
stub it: stubbing `require\=' instead would reach every other library the
render path loads."
  (declare (indent 0))
  `(let ((cerebro-test--autostart-launched nil)
         (cerebro-test--autostart-cleared nil)
         (cerebro-test--autostart-messages nil)
         (cerebro-test--autostart-logged nil))
     (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () "/fake/repo"))
               ((symbol-function 'cerebro--fleet)
                (lambda (_repo-root) cerebro-test--fleet-fixture))
               ((symbol-function 'cerebro--gather-states) (lambda (_r _roster) nil))
               ((symbol-function 'cerebro--system-processes) (lambda () nil))
               ((symbol-function 'cerebro--owned) (lambda () nil))
               ((symbol-function 'cerebro--ensure-prune-watcher) (lambda (&rest _) nil))
               ((symbol-function 'cerebro--autostart-names)
                (lambda (_repo-root) '("Alpha" "One")))
               ((symbol-function 'cerebro--standby-names)
                (lambda (_repo-root) cerebro-test--standby-fixture))
               ((symbol-function 'cerebro--log)
                (lambda (_root event fields)
                  (push (cons event fields) cerebro-test--autostart-logged)
                  nil))
               ((symbol-function 'cerebro--stop-flag-p)
                (lambda (_repo-root name) (equal name "One")))
               ((symbol-function 'cerebro--clear-stop-flag)
                (lambda (_repo-root name)
                  (push name cerebro-test--autostart-cleared)))
               ((symbol-function 'cerebro--launch)
                (lambda (agent)
                  (push (cerebro-agent-name agent) cerebro-test--autostart-launched)
                  (generate-new-buffer " *cerebro-test-stub*")))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (apply #'format fmt args) cerebro-test--autostart-messages)
                  nil)))
       (unwind-protect (progn ,@body)
         (when (get-buffer cerebro-buffer-name)
           (kill-buffer cerebro-buffer-name))))))

(ert-deftest cerebro-test/autostart-runs-once-on-buffer-creation ()
  "Every declared name that is dead starts as the buffer is created, a stop
flag on such a name is cleared first, and a later `M-x cerebro\=' on the
live buffer starts nothing - or it would restart whatever `k\=' just killed
(cb-0r6)."
  (cerebro-test--with-autostart
    (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () t)))
      (cerebro)
      (should (equal (nreverse cerebro-test--autostart-launched) '("Alpha" "One")))
      (should (equal cerebro-test--autostart-cleared '("One")))
      (setq cerebro-test--autostart-launched nil)
      (cerebro)
      (should (null cerebro-test--autostart-launched))
      (kill-buffer cerebro-buffer-name)
      (cerebro)
      (should (equal (nreverse cerebro-test--autostart-launched) '("Alpha" "One"))))))

(ert-deftest cerebro-test/autostart-echoes-who-started-and-who-was-up ()
  (cerebro-test--with-autostart
    (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () t)))
      (cerebro)
      (should (member "cerebro: autostarted Alpha, One (cleared a stale stop flag)"
                      cerebro-test--autostart-messages)))))

(ert-deftest cerebro-test/autostart-says-nothing-without-vterm ()
  "Without vterm there is nothing to start a session in, so autostart says so
once instead of erroring once per declared name."
  (cerebro-test--with-autostart
    (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () nil)))
      (cerebro)
      (should (null cerebro-test--autostart-launched))
      (should (member "cerebro: vterm is not installed, so nothing was autostarted"
                      cerebro-test--autostart-messages)))))

(ert-deftest cerebro-test/roster-standby-arms-without-starting ()
  "A `standby\=' row arms its agent as the fleet buffer comes up and starts
nothing: the row reads `standby\=', its role\='s own trigger is what starts it,
and the parked entry the arming writes is what a cadence trigger counts
from (cb-98u).

A second `M-x cerebro\=' on the live buffer arms nothing more, for the same
reason it starts nothing - it would re-arm whatever `k\=' has just disarmed."
  (let ((cerebro-test--standby-fixture '("Beta")))
    (cerebro-test--with-autostart
      (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () t)))
        (cerebro)
        (should (equal (reverse cerebro-test--autostart-launched) '("Alpha" "One")))
        (with-current-buffer cerebro-buffer-name
          (should (member "Beta" cerebro--armed))
          (let ((entry (cdr (assoc "Beta" cerebro--parked))))
            (should entry)
            (should (numberp (nth 0 entry)))
            (should (null (nth 1 entry)))
            (should (null (nth 2 entry))))
          (should (eq (cerebro-agent-state
                       (seq-find (lambda (a) (equal (cerebro-agent-name a) "Beta"))
                                 cerebro--agents))
                      'standby)))
        (should (member "cerebro: autostarted Alpha, One (cleared a stale stop flag); armed Beta"
                        cerebro-test--autostart-messages))
        (let ((arms (seq-filter (lambda (e) (eq (car e) 'arm)) cerebro-test--autostart-logged)))
          (should (= (length arms) 1))
          (should (equal (alist-get 'agent (cdr (car arms))) "Beta")))
        ;; A second `M-x cerebro' on the live buffer changes none of it.
        (cerebro)
        (with-current-buffer cerebro-buffer-name
          (should (= (length cerebro--armed) 1)))
        (should (= (length (seq-filter (lambda (e) (eq (car e) 'arm))
                                       cerebro-test--autostart-logged))
                   1))))))

(ert-deftest cerebro-test/roster-standby-arms-an-implementer-without-starting ()
  "An implementer row takes `standby\=' too (cb-1or.2): since cb-1or.1 its
trigger is a real condition - a planned, unclaimed bead - so the word arms it
exactly as it arms a role, and starts nothing."
  (let ((cerebro-test--standby-fixture '("Two")))
    (cerebro-test--with-autostart
      (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () t)))
        (cerebro)
        (should (equal (reverse cerebro-test--autostart-launched) '("Alpha" "One")))
        (with-current-buffer cerebro-buffer-name
          (should (member "Two" cerebro--armed))
          (let ((entry (cdr (assoc "Two" cerebro--parked))))
            (should entry)
            (should (numberp (nth 0 entry)))
            (should (null (nth 1 entry)))
            (should (null (nth 2 entry))))
          (should (eq (cerebro-agent-state
                       (seq-find (lambda (a) (equal (cerebro-agent-name a) "Two"))
                                 cerebro--agents))
                      'standby)))))))

(ert-deftest cerebro-test/roster-standby-without-vterm-arms-nothing ()
  "Without vterm `cerebro--start-due\=' can start nothing, so an armed name
would promise a trigger that cannot fire: nothing is armed either (cb-98u)."
  (let ((cerebro-test--standby-fixture '("Beta")))
    (cerebro-test--with-autostart
      (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () nil)))
        (cerebro)
        (should (null cerebro-test--autostart-launched))
        (with-current-buffer cerebro-buffer-name
          (should (null cerebro--armed)))
        (should (member "cerebro: vterm is not installed, so nothing was autostarted"
                        cerebro-test--autostart-messages))))))

(defun cerebro-test--agent (name role kind state &optional external bead phase)
  (make-cerebro-agent :name name :role role :kind kind :state state
                              :bead bead :since nil :external external :phase phase))

;; ---------------------------------------------------------------------------
;; ah-goz: the fleet roster - one declaration, `scripts/roster', instead of
;; `cerebro-interactive-agents' and `cerebro--role-launch-commands'

(ert-deftest cerebro-test/parse-fleet-rows-into-name-role-kind ()
  (should (equal (cerebro--parse-fleet "Xavier\tplanner\tinteractive\nCyclops\timplementer\timplementer\n")
                  '(("Xavier" "planner" interactive) ("Cyclops" "implementer" implementer)))))

(ert-deftest cerebro-test/parse-fleet-skips-blank-and-short-lines ()
  (should (equal (cerebro--parse-fleet "Xavier\tplanner\tinteractive\n\nbad-line\n")
                  '(("Xavier" "planner" interactive)))))

(ert-deftest cerebro-test/fleet-roster-is-the-implementer-names-in-order ()
  (should (equal (cerebro--fleet-roster cerebro-test--fleet-fixture)
                  '("One" "Two" "Three"))))

(ert-deftest cerebro-test/fleet-interactive-is-a-name-role-alist-in-order ()
  (should (equal (cerebro--fleet-interactive cerebro-test--fleet-fixture)
                  '(("Alpha" . "planner") ("Beta" . "verifier")))))

(ert-deftest cerebro-test/list-height-is-rows-plus-header-and-mode-line ()
  (should (= (cerebro--list-height 18) 20)))

(ert-deftest cerebro-test/launch-command-is-launch-plus-name-for-every-kind ()
  (should (equal (cerebro--launch-command
                   (cerebro-test--agent "Xavier" "planner" 'interactive 'dead))
                  '(".claude/cerebro/scripts/launch" "Xavier")))
  (should (equal (cerebro--launch-command
                   (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
                  '(".claude/cerebro/scripts/launch" "Cyclops"))))

(ert-deftest cerebro-test/fleet-reads-the-roster-script ()
  (let* ((tmp (make-temp-file "cerebro-fleet-test" t))
         (repo-root cerebro-test--repo-root))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".claude" tmp) t)
          (make-symbolic-link repo-root (expand-file-name ".claude/cerebro" tmp))
          (let ((fleet (cerebro--fleet tmp)))
            (should fleet)
            (should (cl-every (lambda (row)
                                 (and (= (length row) 3)
                                      (stringp (nth 0 row))
                                      (stringp (nth 1 row))
                                      (symbolp (nth 2 row))))
                               fleet))
            (should (memq 'interactive (mapcar (lambda (r) (nth 2 r)) fleet)))
            (should (memq 'implementer (mapcar (lambda (r) (nth 2 r)) fleet)))
            (dolist (row fleet)
              (should (file-exists-p (expand-file-name
                                       (format "agents/%s.md" (nth 1 row)) repo-root))))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/standby-names-read-the-roster-script ()
  "`cerebro--standby-names\=' runs the real script against a real roster, and
the two words are read apart from each other (cb-98u).  A roster the script
refuses reads as nil rather than signalling: `cerebro--fleet\=' has already
reported that refusal for the same render."
  (let ((tmp (make-temp-file "cerebro-standby-names" t)))
    (unwind-protect
        (let ((scripts (expand-file-name ".claude/cerebro/scripts" tmp)))
          (make-directory scripts t)
          (make-directory (expand-file-name ".cerebro" tmp) t)
          (cerebro-test--place-scripts scripts "--copy" "roster" "consumer-root")
          (with-temp-file (expand-file-name ".cerebro/roster.conf" tmp)
            (insert "Ada  planner  autostart\nGrace  reviewer  standby\n"))
          (should (equal (cerebro--standby-names tmp) '("Grace")))
          (should (equal (cerebro--autostart-names tmp) '("Ada")))
          (with-temp-file (expand-file-name ".cerebro/roster.conf" tmp)
            (insert "Ada  planner  autostrat\n"))
          (should (null (cerebro--standby-names tmp))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/fleet-signals-when-roster-refuses ()
  "A roster `scripts/roster\=' refuses must reach the navigator, not be
rendered as an empty fleet (cb-0r6).  Before this, a mistyped third column
gave `M-x cerebro\=' a list of nobody and said nothing about why.

The consumer is built with real copies of the scripts rather than symlinks
to this checkout: the consumer is found by path arithmetic, and a symlinked
mount resolves that arithmetic to whatever is above the checkout instead of
to the temporary consumer.  `consumer-root\=' is copied beside `roster\=',
which asks it for that root since cb-akc; without the sibling the fixture
would find no consumer file and render the built-in fleet, refusing nothing."
  (let ((tmp (make-temp-file "cerebro-roster-refusal" t)))
    (unwind-protect
        (let ((scripts (expand-file-name ".claude/cerebro/scripts" tmp)))
          (make-directory scripts t)
          (make-directory (expand-file-name ".cerebro" tmp) t)
          (cerebro-test--place-scripts scripts "--copy" "roster" "consumer-root")
          (with-temp-file (expand-file-name ".cerebro/roster.conf" tmp)
            (insert "Ada  planner  autostrat\n"))
          (with-temp-buffer
            (let ((err (should-error (cerebro--fleet tmp))))
              (should (string-match-p "autostrat" (format "%S" err))))))
      (delete-directory tmp t))))

;; ---------------------------------------------------------------------------
;; Reader contracts: each impure reader run for real, its output fed to the
;; pure function that consumes it.  A pure function tested against invented
;; inputs can be wrong about every real one; these are the real ones.

(ert-deftest cerebro-test/canonical-root-expands-a-tilde-and-ends-in-a-slash ()
  (should (equal (cerebro--canonical-root "~/repos/cerebro/")
                 (concat (expand-file-name "~/") "repos/cerebro/")))
  (should (equal (cerebro--canonical-root "/x/y") "/x/y/"))
  (should (equal (cerebro--canonical-root "/x/y/") "/x/y/")))

(ert-deftest cerebro-test/repo-root-returns-the-abbreviated-locate-result-canonical ()
  "`locate-dominating-file\=' abbreviates - \"~/repos/cerebro/\" for a checkout
under the home directory - and `cerebro--repo-root\=' is the one reader whose
raw result is a display spelling.  cb-5yr shipped with the whole liveness chain
inert because of it; the stub here returns the shape the real producer returns,
on purpose."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (&rest _) "~/repos/cerebro/")))
    (let ((root (cerebro--repo-root)))
      (should (equal root (concat (expand-file-name "~/") "repos/cerebro/")))
      (should-not (string-prefix-p "~" root))
      (should (cerebro--session-args-p
               (concat "claude --agent planner --name Xavier --remote-control Xavier"
                       " This session is Xavier of the cerebro fleet rooted at "
                       (expand-file-name "~/")
                       "repos/cerebro/. This sentence is how the fleet view proves the"
                       " session belongs to this checkout; do not remove it.")
               "Xavier" root))))
  ;; Unstubbed, on a real temporary consumer: absolute and slash-terminated.
  (let ((tmp (make-temp-file "cerebro-repo-root-contract" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name cerebro-submodule-path tmp) t)
          (let ((default-directory (file-name-as-directory tmp)))
            (should (equal (cerebro--repo-root)
                           (file-name-as-directory (expand-file-name tmp))))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/state-file-written-by-agent-state-derives-a-row ()
  "The real `scripts/agent-state\=' writes the file `cerebro--read-state-file\='
parses and `cerebro--derive\=' turns into a row.  Green the day it is written -
that is what a contract case is for: it goes red the day either side changes
shape."
  (skip-unless (executable-find "jq"))
  (skip-unless (executable-find "git"))
  (let ((tmp (make-temp-file "cerebro-state-contract" t)))
    (unwind-protect
        (let ((scripts (expand-file-name ".claude/cerebro/scripts" tmp)))
          (make-directory scripts t)
          (make-directory (expand-file-name ".cerebro" tmp) t)
          ;; The sourced libraries come with the scripts, derived by the tool
          ;; rather than named here (cb-u70).
          (cerebro-test--place-scripts scripts "agent-state" "roster" "consumer-root")
          ;; `agent-state\=' resolves its consumer with `consumer-root --shared\=',
          ;; which asks git for the main working tree - so the fixture is a repo,
          ;; the way `tests/lib/consumer.sh\=' builds one for the bash suites.
          (let ((default-directory (file-name-as-directory tmp)))
            (should (eq 0 (call-process "git" nil nil nil "init" "-q"))))
          (let ((agent-state (expand-file-name "agent-state" scripts)))
            ;; the implementer shape
            (should (eq 0 (call-process agent-state nil nil nil
                                        "Cyclops" "working" "--bead" "cb-1"
                                        "--phase" "build" "--pid" "4242")))
            (let* ((parsed (cerebro--read-state-file
                            (cerebro--state-file-path tmp "Cyclops")))
                   (agent (car (cerebro--derive '("Cyclops") nil
                                                (list (cons "Cyclops" parsed))
                                                #'cerebro-test--always-alive nil nil))))
              (should (integerp (alist-get 'pid parsed)))   ; `pid: ($pid | tonumber)'
              (should (eq (cerebro-agent-state agent) 'working))
              (should (equal (cerebro-agent-bead agent) "cb-1"))
              (should (equal (cerebro-agent-phase agent) "build"))
              (should (stringp (cerebro-agent-since agent))))
            ;; the interactive shape, with the one field only that role writes
            (should (eq 0 (call-process agent-state nil nil nil
                                        "Xavier" "waiting"
                                        "--pid" "4243")))
            (let* ((parsed (cerebro--read-state-file
                            (cerebro--state-file-path tmp "Xavier")))
                   (agent (car (cerebro--derive nil '(("Xavier" . "planner"))
                                                (list (cons "Xavier" parsed))
                                                #'cerebro-test--always-alive nil nil))))
              (should (eq (cerebro-agent-state agent) 'waiting))
              (should (eq (cerebro-agent-bead agent) nil)))
            ;; and the same end-of-pass shape from an implementer name (cb-1or.1)
            (should (eq 0 (call-process agent-state nil nil nil
                                        "Cyclops" "waiting"
                                        "--pid" "4244")))
            (let* ((parsed (cerebro--read-state-file
                            (cerebro--state-file-path tmp "Cyclops")))
                   (agent (car (cerebro--derive '("Cyclops") nil
                                                (list (cons "Cyclops" parsed))
                                                #'cerebro-test--always-alive nil nil))))
              (should (eq (cerebro-agent-state agent) 'waiting))
              (should (eq (cerebro-agent-bead agent) nil)))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/project-conf-declares-the-role-spacing-the-view-uses ()
  "The real `scripts/project-conf\=' on a real declaration, its output fed to the
pure function that consumes it - the first value `cerebro.el\=' has ever taken
from a project\='s own `project.conf\='.

The malformed key in the fixture is deliberate: the reader must drop it rather
than pass `bad\=' into the alist, where it would reach the `<\=' in
`cerebro--role-start-too-soon-p\=' and signal on a live fleet."
  (skip-unless (executable-find "git"))
  (let ((tmp (make-temp-file "cerebro-spacing-contract" t)))
    (unwind-protect
        (let ((scripts (expand-file-name ".claude/cerebro/scripts" tmp)))
          (make-directory scripts t)
          (make-directory (expand-file-name ".cerebro" tmp) t)
          (cerebro-test--place-scripts scripts "project-conf" "consumer-root")
          ;; `project-conf' resolves its consumer with `consumer-root --shared',
          ;; which asks git for the main working tree.
          (let ((default-directory (file-name-as-directory tmp)))
            (should (eq 0 (call-process "git" nil nil nil "init" "-q"))))
          (with-temp-file (expand-file-name ".cerebro/project.conf" tmp)
            (insert "name                 fixture\n"
                    "role_start_spacing_planner      45\n"
                    "role_start_spacing_implementer  soon\n"))
          (cl-letf (((symbol-function 'cerebro--report-error) (lambda (&rest _) nil)))
            (let ((declared (cerebro--project-spacing
                             tmp '("planner" "implementer" "verifier"))))
              ;; The good key only: the malformed one and the absent one both
              ;; leave the `defcustom' to answer.
              (should (equal declared '(("planner" . 45))))
              ;; The contract half - the reader's own output, through the pure
              ;; function that decides with it.
              (let ((cerebro-role-start-spacing '(("planner" . 30) ("implementer" . 30))))
                (should (equal (cerebro--role-start-spacing "planner" declared) 45))
                (should (equal (cerebro--role-start-spacing "implementer" declared) 30))
                (should (null (cerebro--role-start-spacing "verifier" declared))))))
          ;; And a root with no submodule checked out at all answers nil rather
          ;; than signalling: `cerebro--start-due' passes whatever root it was
          ;; given, and a render must not die on a consumer mid-clone.
          (should (null (cerebro--project-spacing "/tmp/nowhere" '("planner")))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/a-spacing-that-is-not-a-number-says-so-and-falls-back ()
  "Fall back, and say so once.  A typo in one optional key must not cost the
navigator their whole view the way a bad `roster.conf\=' row does - but a fleet
running on a number nobody declared must not be silent either."
  (skip-unless (executable-find "git"))
  (let ((tmp (make-temp-file "cerebro-spacing-complaint" t))
        (said nil))
    (unwind-protect
        (let ((scripts (expand-file-name ".claude/cerebro/scripts" tmp)))
          (make-directory scripts t)
          (make-directory (expand-file-name ".cerebro" tmp) t)
          (cerebro-test--place-scripts scripts "project-conf" "consumer-root")
          (let ((default-directory (file-name-as-directory tmp)))
            (should (eq 0 (call-process "git" nil nil nil "init" "-q"))))
          (with-temp-file (expand-file-name ".cerebro/project.conf" tmp)
            (insert "role_start_spacing_planner  soon\n"))
          (let ((cerebro-role-start-spacing '(("planner" . 30) ("implementer" . 30))))
            (cl-letf (((symbol-function 'cerebro--log-error) #'ignore)
                      ((symbol-function 'message)
                       (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
              (should (null (cerebro--project-spacing tmp '("planner" "implementer")))))
            ;; Once for the one bad key, not once per role read.
            (should (equal said
                           (list (concat "cerebro: project.conf: role_start_spacing_planner"
                                         " is not a whole number of seconds (\"soon\");"
                                         " using 30"))))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/system-processes-are-pid-ppid-and-args-triples ()
  "The real process scan, on this very Emacs.  The `(emacs-pid)\=' line is the
one that would catch a platform where `process-attributes\=' returns no
`args\=': there the reader returns nothing, every interactive row falls to
`dead\=', and nothing says so.  The ppid assertion is the same test for the
key the tree collapse depends on.  Do not weaken either to `(should procs)\='."
  (let ((procs (cerebro--system-processes)))
    (should (cl-every (lambda (p) (and (integerp (cerebro--proc-pid p))
                                       (stringp (cerebro--proc-args p))
                                       (or (null (cerebro--proc-ppid p))
                                           (integerp (cerebro--proc-ppid p)))))
                      procs))
    (should (assq (emacs-pid) procs))
    (should (equal (cerebro--proc-ppid (assq (emacs-pid) procs))
                   (alist-get 'ppid (process-attributes (emacs-pid)))))
    ;; and the pure consumers take that shape without complaint
    (let ((mine (cerebro--consumer-processes procs "/no/such/root/")))
      (should (listp mine))
      (should (equal (cerebro--session-pids "Nobody" mine) nil)))))

(ert-deftest cerebro-test/fleet-snapshot-feeds-the-sweep-finders ()
  "The snapshot plist carries every key some row of `cerebro--sweeps\=' names in
its NEEDS.  A key the snapshot stopped producing would reach a finder as nil
today - a claims sweep judging every session as not live - and nothing would
say so.  `with-temp-buffer\=' because `cerebro--fleet-cache\=' is buffer-local:
without it the fixture\='s roster is cached wherever ERT happens to be."
  (let ((tmp (make-temp-file "cerebro-snapshot-contract" t)))
    (unwind-protect
        (let ((scripts (expand-file-name ".claude/cerebro/scripts" tmp)))
          (make-directory scripts t)
          (make-directory (expand-file-name ".cerebro" tmp) t)
          (cerebro-test--place-scripts scripts "roster" "consumer-root")
          (with-temp-buffer
            (let ((snap (cerebro--fleet-snapshot tmp)))
              (should (equal (plist-get snap :live-names) nil))
              (should (cl-every #'stringp (plist-get snap :roster)))
              (should (member "Cyclops" (plist-get snap :roster)))
              (should (plist-get snap :now))
              (dolist (row cerebro--sweeps)
                (dolist (key (nth 3 row))
                  (should (plist-member snap key))))
              (should (equal (cerebro--findings-from-snapshot nil snap) nil)))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/session-buffer-name-shape ()
  (should (equal (cerebro--session-buffer-name
                   (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
                  "*fleet: Cyclops*")))


;; ---------------------------------------------------------------------------
;; cb-0r6: an agent whose roster line says `autostart' comes up with the fleet
;; view. The decision is pure; the starting is at the bottom of cerebro.el.

(ert-deftest cerebro-test/autostart-action-launches-dead ()
  (should (eq (cerebro--autostart-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'dead) nil nil)
              'launch)))

(ert-deftest cerebro-test/autostart-action-clears-a-flag-for-every-kind ()
  "Unlike `s' (`cerebro--start-clears-flag-p', implementers only), autostart
clears a stop flag for every kind - the navigator's decision (cb-0r6)."
  (should (eq (cerebro--autostart-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'dead) nil t)
              'launch-clearing-flag))
  (should (eq (cerebro--autostart-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead) nil t)
              'launch-clearing-flag)))

(ert-deftest cerebro-test/autostart-action-skips-owned-and-external ()
  (dolist (flagged '(nil t))
    (should (eq (cerebro--autostart-action
                  (cerebro-test--agent "Xavier" "planner" 'interactive 'up nil)
                  '("Xavier") flagged)
                'already-up))
    (should (eq (cerebro--autostart-action
                  (cerebro-test--agent "Xavier" "planner" 'interactive 'up t)
                  nil flagged)
                'external))))

(ert-deftest cerebro-test/autostart-message-forms ()
  (should (null (cerebro--autostart-message nil)))
  (should (equal (cerebro--autostart-message
                   '(("Xavier" . launch) ("Psylocke" . launch) ("Cyclops" . launch)))
                  "cerebro: autostarted Xavier, Psylocke, Cyclops"))
  (should (equal (cerebro--autostart-message
                   '(("Xavier" . launch-clearing-flag) ("Cyclops" . launch)))
                  "cerebro: autostarted Xavier (cleared a stale stop flag), Cyclops"))
  (should (equal (cerebro--autostart-message
                   '(("Xavier" . launch) ("Psylocke" . already-up) ("Cyclops" . launch)))
                  "cerebro: autostarted Xavier, Cyclops; Psylocke is already up"))
  (should (equal (cerebro--autostart-message
                   '(("Beast" . external) ("Psylocke" . already-up) ("Cyclops" . launch)))
                  "cerebro: autostarted Cyclops; Beast and Psylocke are already up"))
  (should (equal (cerebro--autostart-message
                   '(("Beast" . already-up) ("Psylocke" . already-up)
                     ("Storm" . external) ("Cyclops" . launch)))
                  "cerebro: autostarted Cyclops; Beast, Psylocke and Storm are already up"))
  (should (equal (cerebro--autostart-message
                   '(("Xavier" . already-up) ("Psylocke" . external)))
                  "cerebro: nothing to autostart; Xavier and Psylocke are already up")))

(defun cerebro-test--duplicated-agent (name role kind state &optional external bead phase)
  "An agent as `cerebro-test--agent\=' builds one, with two sessions counted."
  (let ((agent (cerebro-test--agent name role kind state external bead phase)))
    (setf (cerebro-agent-sessions agent) 2)
    agent))

(ert-deftest cerebro-test/start-action-refuses-a-duplicated-name ()
  "With two sessions of one name, `s\=' would start a third over an ambiguity."
  (should (eq (cerebro--start-action
               (cerebro-test--duplicated-agent "Xavier" "planner" 'interactive 'dead) nil)
              'duplicate))
  ;; Ahead of `already-up' and `external' too - the answer is the same whichever
  ;; of the two sessions this Emacs happens to hold.
  (should (eq (cerebro--start-action
               (cerebro-test--duplicated-agent "Xavier" "planner" 'interactive 'up)
               '("Xavier"))
              'duplicate))
  (should (eq (cerebro--start-action
               (cerebro-test--duplicated-agent "Xavier" "planner" 'interactive 'standby) nil)
              'duplicate)))

(ert-deftest cerebro-test/kill-action-refuses-a-duplicated-name ()
  "`k\=' would kill whichever session Emacs holds, which is not necessarily the
one the navigator can see - and it beats `disarm\=', which acts on the name."
  (should (eq (cerebro--kill-action
               (cerebro-test--duplicated-agent "Cyclops" "implementer" 'implementer 'idle)
               '("Cyclops"))
              'duplicate))
  (should (eq (cerebro--kill-action
               (cerebro-test--duplicated-agent "Xavier" "planner" 'interactive 'standby) nil)
              'duplicate)))

(ert-deftest cerebro-test/finish-action-refuses-a-duplicated-name ()
  "A stop flag is per name, and two sessions would both read the one flag."
  (should (eq (cerebro--finish-action
               (cerebro-test--duplicated-agent "Cyclops" "implementer" 'implementer
                                               'working nil "cb-63m")
               nil)
              'duplicate))
  ;; Ahead of `offer-clear', which is otherwise checked before every state.
  (should (eq (cerebro--finish-action
               (cerebro-test--duplicated-agent "Cyclops" "implementer" 'implementer
                                               'working nil "cb-63m")
               t)
              'duplicate))
  (should (eq (cerebro--finish-action
               (cerebro-test--duplicated-agent "Xavier" "planner" 'interactive 'up) nil)
              'duplicate)))

(ert-deftest cerebro-test/copilot-wrapper-does-not-refuse-the-keys ()
  "The bead's headline symptom, end to end: on a Copilot fleet `s\=', `k\=' and
`f\=' asked the navigator to choose between a shim and its own child on every
row, every keypress, for as long as the fleet was up (cb-3ks).  A genuine
second session must still refuse them."
  (let* ((stray (cons 36037 (cons 1 cerebro-test--this-consumer-args)))
         (xavier-from
          (lambda (procs)
            (let* ((mine (cerebro--consumer-processes procs "/Users/x/repos/cerebro"))
                   (agents (cerebro--derive nil cerebro-test--interactive nil
                                            #'cerebro-test--never-alive
                                            (mapcar #'cerebro--proc-args mine) nil)))
              (cl-find "Xavier" (cerebro--apply-session-counts agents mine)
                       :key #'cerebro-agent-name :test #'equal))))
         (one (funcall xavier-from cerebro-test--copilot-procs))
         (two (funcall xavier-from (append cerebro-test--copilot-procs (list stray)))))
    (should-not (eq (cerebro--start-action one nil) 'duplicate))
    (should-not (eq (cerebro--kill-action one '("Xavier")) 'duplicate))
    (should-not (eq (cerebro--finish-action one nil) 'duplicate))
    (should (eq (cerebro--start-action two nil) 'duplicate))
    (should (eq (cerebro--kill-action two '("Xavier")) 'duplicate))
    (should (eq (cerebro--finish-action two nil) 'duplicate))))

(ert-deftest cerebro-test/the-duplicate-message-still-tags-the-state-file-pid ()
  "The navigator's chosen line, verbatim.  It reads this way only because the
collapse keeps the leaf: on a Copilot fleet the state file names the platform
binary, never the shim, so dropping parents is what keeps the `(state file)\='
tag meaningful (cb-3ks, decision A)."
  (should (equal (cerebro--duplicate-message "Xavier" '(36037 60514) 60514)
                 (concat "Xavier has 2 sessions in this fleet: "
                         "pid 60514 (state file), pid 36037 "
                         "— end the extra one from its own terminal"))))

(ert-deftest cerebro-test/autostart-never-launches-a-duplicated-name ()
  (should (eq (cerebro--autostart-action
               (cerebro-test--duplicated-agent "Xavier" "planner" 'interactive 'dead) nil t)
              'duplicate)))

(ert-deftest cerebro-test/duplicate-message-names-every-pid-and-tags-the-state-files ()
  (should (equal (cerebro--duplicate-message "Xavier" '(32075 70687) 70687)
                 (concat "Xavier has 2 sessions in this fleet: pid 70687 (state file), "
                         "pid 32075 — end the extra one from its own terminal"))))

(ert-deftest cerebro-test/duplicate-message-without-a-file-pid-tags-nothing ()
  "No state file, or one naming a pid that is not among them: every pid is
untagged and the order is ascending."
  (let ((expected (concat "Xavier has 2 sessions in this fleet: pid 32075, pid 70687"
                          " — end the extra one from its own terminal")))
    (should (equal (cerebro--duplicate-message "Xavier" '(32075 70687) nil) expected))
    (should (equal (cerebro--duplicate-message "Xavier" '(32075 70687) 99) expected))))

(ert-deftest cerebro-test/start-action-launches-dead ()
  (should (eq (cerebro--start-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead) nil)
              'launch)))

(ert-deftest cerebro-test/start-action-refuses-external ()
  (should (eq (cerebro--start-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'up t) nil)
              'external)))

(ert-deftest cerebro-test/start-action-already-up ()
  (should (eq (cerebro--start-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'up nil)
                '("Xavier"))
              'already-up)))

(ert-deftest cerebro-test/start-action-already-up-beats-any-state ()
  "Ownership is checked before the derived state, so no gap in how a state
is derived can start a second session over one this Emacs holds (ah-u3i's
`*fleet: <name>*<2>' double session)."
  (dolist (state '(dead asking waiting unknown))
    (should (eq (cerebro--start-action
                  (cerebro-test--agent "Cyclops" "implementer" 'implementer state)
                  '("Cyclops"))
                'already-up)))
  (should (eq (cerebro--start-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'up t) nil)
              'external))
  (should (eq (cerebro--start-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead) nil)
              'launch)))

;; ---------------------------------------------------------------------------
;; ah-kgc: a stop flag is cleared when it retires an implementer, and when
;; the name is started again

(ert-deftest cerebro-test/start-clears-a-stale-flag-for-an-implementer ()
  "Starting a name is a statement that it should run, so any flag for it is
stale by definition."
  (should (eq (cerebro--start-clears-flag-p
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead) t)
              t))
  (should (null (cerebro--start-clears-flag-p
                  (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead) nil)))
  (should (null (cerebro--start-clears-flag-p
                  (cerebro-test--agent "Xavier" "planner" 'interactive 'dead) t))))

(ert-deftest cerebro-test/kill-action-plain-kill-for-idle ()
  (should (eq (cerebro--kill-action
                (cerebro-test--agent "Wolverine" "implementer" 'implementer 'idle nil)
                '("Wolverine"))
              'kill)))

(ert-deftest cerebro-test/kill-action-harder-for-working ()
  (should (eq (cerebro--kill-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working nil "ah-f9c")
                '("Cyclops"))
              'kill-working)))

(ert-deftest cerebro-test/kill-action-external-and-dead-refused ()
  (should (eq (cerebro--kill-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'up t) nil)
              'external))
  (should (eq (cerebro--kill-action
                (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead nil) nil)
              'dead)))

(ert-deftest cerebro-test/placeholder-external-vs-dead-wording ()
  (should (equal (cerebro--placeholder
                   (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
                  "Cyclops is not running. Press s to start it."))
  (should (equal (cerebro--placeholder
                   (cerebro-test--agent "Xavier" "planner" 'interactive 'up t))
                  (concat "Xavier is running outside Emacs - no live view. "
                          "Use the terminal that started it."))))

(ert-deftest cerebro-test/placeholder-names-the-unverified-pid ()
  "`RET' on an unverified row names the cause - the marker alone says
something is off, never what (ah-ybsr). This branch must be checked before
the `external' one: an unverified row also carries `:external t'
\(`cerebro--derive-from-state' sets it from `(not owned-p)', and a session
this Emacs started never reaches `unverified' - it is launched directly, not
through the wrapper\), so without ordering it would fall into the plainer
\"running outside Emacs\" wording instead."
  (let ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working t)))
    (setf (cerebro-agent-unverified-pid agent) 4242)
    (should (equal (cerebro--placeholder agent)
                    (concat "Unverified: pid 4242 is running and names Cyclops, but its command"
                            " line carries no path under this checkout - showing the state file.\n"
                            "Cyclops is running outside Emacs - no live view. Use the terminal"
                            " that started it.")))))

;; ---------------------------------------------------------------------------
;; ah-bri: a session that dies before it gets going keeps its last line readable

(ert-deftest cerebro-test/the-log-writes-nothing-at-none ()
  "`none\=' is the one verbosity that writes nothing at all.

Every other value logs the decisions whatever it is - losing the record of a
start is worse than a typo in a setting - so silence has to be asked for by
name.  It is what the suite binds, so that running the tests cannot write into
the log the navigator reads."
  (dolist (event '(start end exit retire restart sweep evaluate triage))
    (should-not (cerebro--log-event-p event 'none)))
  ;; And every other value still records what the view did.
  (dolist (verbosity '(decisions changes evaluations nil some-typo))
    (should (cerebro--log-event-p 'start verbosity))
    (should (cerebro--log-event-p 'exit verbosity))))

(ert-deftest cerebro-test/every-exit-has-a-code-to-log ()
  "A session that ends leaves a line whatever it died of.

`cerebro--exit-record\=' answers a different question - is this worth putting
on the row as a failure - and says nil for a clean quit.  That is right for
the row and wrong for the log: an implementer went from `idle\=' to `dead\=' with
no `exit\=' line anywhere, because exiting with status 0 was recorded nowhere
at all.  \"Without apparent reason\" was the code declining to say."
  (should (equal (cerebro--exit-code "finished\n") "0"))
  (should (equal (cerebro--exit-code "exited abnormally with code 2\n") "2"))
  (should (equal (cerebro--exit-code "killed\n") "killed"))
  (should (equal (cerebro--exit-code "hangup\n") "hangup"))
  ;; The row's own record is unchanged: a clean quit is not a failure to show.
  (should (null (cerebro--exit-record "finished\n" "all done")))
  (should (equal (cerebro--exit-record "exited abnormally with code 2\n" "boom")
                 '(:code "2" :line "boom"))))

(ert-deftest cerebro-test/exit-record-only-for-abnormal-exits ()
  "The record is a plist - (:code CODE :line LINE) - since cb-ccl; it was a
cons of the two."
  (should (equal (cerebro--exit-record "exited abnormally with code 2\n" "cerebro: x")
                  '(:code "2" :line "cerebro: x")))
  (should (null (cerebro--exit-record "finished\n" "cerebro: x")))
  (should (null (cerebro--exit-record "killed\n" "cerebro: x")))
  (should (null (cerebro--exit-record "hangup\n" "cerebro: x"))))

(ert-deftest cerebro-test/exit-record-without-a-line-is-still-abnormal ()
  "cb-ccl: a session that died with nothing drawn in its buffer used to make
no record at all, so `abnormal\=' was logged null for an exit code of 2 and the
name fell into the retry path as though it had simply gone away.  An abnormal
exit is a record whether or not there is a line to show with it."
  (should (equal (cerebro--exit-record "exited abnormally with code 2\n" nil)
                 '(:code "2" :line nil)))
  (should (equal (cerebro--exit-record "exited abnormally with code 137\n" nil)
                 '(:code "137" :line nil)))
  (should (null (cerebro--exit-record "finished\n" nil)))
  (should (null (cerebro--exit-record "killed\n" nil))))

(ert-deftest cerebro-test/a-silent-death-is-standby-a-refusal-is-dead ()
  "cb-eat\='s rule, now that every abnormal exit makes a record: the names that
keep a row `dead\=' are those with something to say for themselves - a line, or
a give-up - and a session that died printing nothing is still promised a
retry (cb-ccl)."
  (let ((last-exit '(("A" :code "2" :line "cerebro: refused")
                     ("B" :code "137" :line nil)
                     ("C" :code "?" :line nil :gave-up t))))
    (should (equal (sort (cerebro--failed-names last-exit) #'string<) '("A" "C")))
    (should (null (cerebro--failed-names nil)))
    (let ((out (cerebro--apply-standby
                (list (cerebro-test--agent "A" "implementer" 'implementer 'dead)
                      (cerebro-test--agent "B" "implementer" 'implementer 'dead))
                '("A" "B") (cerebro--failed-names last-exit))))
      (should (eq (cerebro-agent-state (nth 0 out)) 'dead))
      (should (eq (cerebro-agent-state (nth 1 out)) 'standby)))))

(ert-deftest cerebro-test/last-nonblank-line ()
  (should (equal (cerebro--last-nonblank-line "a\nb  \n\n   \n") "b"))
  (should (null (cerebro--last-nonblank-line "")))
  (should (null (cerebro--last-nonblank-line "\n\n"))))

(ert-deftest cerebro-test/placeholder-shows-the-last-exit-line ()
  (let ((cerebro--last-exit '(("Forge" :code "2" :line "cerebro: boom"))))
    (should (equal (cerebro--placeholder
                     (cerebro-test--agent "Forge" "architect" 'implementer 'dead))
                    (concat "Forge is not running.\n"
                            "Its last session ended with:\n"
                            "  cerebro: boom\n"
                            "Press s to start it.")))
    (should (equal (cerebro--placeholder
                     (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
                    "Cyclops is not running. Press s to start it."))
    (should (equal (cerebro--placeholder
                     (cerebro-test--agent "Xavier" "planner" 'interactive 'up t))
                    (concat "Xavier is running outside Emacs - no live view. "
                            "Use the terminal that started it.")))))

(ert-deftest cerebro-test/placeholder-for-a-standby-implementer-says-what-happens-next ()
  "`RET' on a dead builder's row: a row that says `standby' and nothing else
leaves the navigator to work out whether anything is coming."
  (let ((cerebro-retry-backoff '(0 30 120 600))
        (cerebro--last-exit nil))
    (should (equal (cerebro--retry-when 0 0) "now"))
    (should (equal (cerebro--retry-when 0 3) "now (3 failed starts)"))
    (should (equal (cerebro--retry-when 45 1) "in 45s (1 failed start)"))
    (should (equal (cerebro--retry-when 120 3) "in 2m (3 failed starts)"))
    (let ((cyclops (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)))
      ;; While a failed start is backing off it says when it comes back.
      (should
       (equal (cerebro--placeholder cyclops 120 3)
              (concat "Cyclops is not running.\n"
                      "Its last session ended without finishing a bead;"
                      " the view starts it again in 2m (3 failed starts).\n"
                      "Press s to start it now, k to leave it down.")))
      ;; Otherwise it finished its pass and waits on the condition, whether
      ;; or not there are failures behind it whose backoff has run out.
      (dolist (failures '(0 3))
        (should
         (equal (cerebro--placeholder cyclops 0 failures)
                (concat "Cyclops is not running.\n"
                        "Its last session finished its pass; the view starts it"
                        " again when a planned bead is waiting.\n"
                        "Press s to start it now, k to leave it down.")))))
    ;; A standby *role* keeps the line it has always had: its kept buffer is
    ;; what `RET' shows, and this is only reached when that has been killed.
    (should (equal (cerebro--placeholder
                    (cerebro-test--interactive "Psylocke" "verifier" 'standby) 0 0)
                   "Psylocke is not running. Press s to start it."))))

(ert-deftest cerebro-test/placeholder-buffer-reads-the-retry-figures-before-switching ()
  "`cerebro--show-detail' runs with the fleet buffer current, and the two
figures the standby line names are buffer-local to it - so they are read
before the placeholder buffer is made current, not after."
  (let ((cerebro-retry-backoff '(0 30 120 600))
        (cerebro--last-exit nil)
        (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby))
        (buffer nil))
    (unwind-protect
        (with-temp-buffer
          (setq cerebro--failed-starts '(("Cyclops" . 3))
                cerebro--started-at '(("Cyclops" . 1000000.0)))
          (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 1000000.0))
                    ((symbol-function 'cerebro-session-mode) #'ignore))
            (setq buffer (cerebro--placeholder-buffer agent))
            (should (string-match-p "in 2m (3 failed starts)"
                                    (with-current-buffer buffer (buffer-string))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest cerebro-test/note-exit-records-and-forgets ()
  "`cerebro--note-exit' finds the agent through `cerebro--sessions', not by
the buffer's name - vterm's sentinel calls it after the process has died,
when `cerebro--session' would already say the entry is gone, so it must
read the raw table rather than go through the liveness check."
  (let ((cerebro--last-exit nil)
        (cerebro--sessions nil))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (let ((buf (generate-new-buffer "*fleet: Forge*")))
        (unwind-protect
            (progn
              (setf (alist-get "Forge" cerebro--sessions nil nil #'equal) buf)
              (with-current-buffer buf
                (insert "starting up...\ncerebro: boom\n\n"))
              (cerebro--note-exit buf "exited abnormally with code 2\n")
              (should (equal (alist-get "Forge" cerebro--last-exit nil nil #'equal)
                              '(:code "2" :line "cerebro: boom"))))
          (kill-buffer buf)))
      (let ((buf (generate-new-buffer "*fleet: Forge*")))
        (unwind-protect
            (progn
              (setf (alist-get "Forge" cerebro--sessions nil nil #'equal) buf)
              (with-current-buffer buf
                (insert "cerebro: boom\n"))
              (setq cerebro--last-exit nil)
              (cerebro--note-exit buf "finished\n")
              (should (null cerebro--last-exit)))
          (kill-buffer buf)))
      (let ((buf (get-buffer-create "*scratch*")))
        (setq cerebro--last-exit nil)
        (cerebro--note-exit buf "exited abnormally with code 2\n")
        (should (null cerebro--last-exit)))
      ;; A buffer named like a session but never recorded: the name is not
      ;; the key any more.
      (let ((buf (generate-new-buffer "*fleet: Forge*")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (insert "cerebro: boom\n"))
              (setq cerebro--last-exit nil)
              (cerebro--note-exit buf "exited abnormally with code 2\n")
              (should (null cerebro--last-exit)))
          (kill-buffer buf)))
      (setq cerebro--last-exit nil)
      (cerebro--note-exit nil "exited abnormally with code 2\n")
      (should (null cerebro--last-exit)))))

(ert-deftest cerebro-test/launch-refusal-picks-the-newest-line-for-the-name-since-the-start ()
  "The launcher writes its own refusal to errors.jsonl (cb-ccl), and the view
reads it back when vterm never drew the line.  Which line: this name's, from
this session rather than an earlier one, and the last of them."
  (let* ((since (float-time (encode-time (iso8601-parse "2026-08-26T04:51:00Z"))))
         (text (mapconcat
                #'identity
                (list "{\"event\":\"error\",\"ts\":\"2026-08-26T04:41:00Z\",\"context\":\"launch Storm\",\"message\":\"an older refusal\"}"
                      "{\"event\":\"error\",\"ts\":\"2026-08-26T04:51:05Z\",\"context\":\"launch Rogue\",\"message\":\"another agent\"}"
                      "not json at all {"
                      "{\"event\":\"error\",\"ts\":\"2026-08-26T04:51:14Z\",\"context\":\"launch Storm\",\"message\":\"the checkout is 4 commits behind\"}")
                "\n")))
    (should (equal (cerebro--launch-refusal text "Storm" since)
                   "the checkout is 4 commits behind"))
    ;; A line older than this session is a previous session's refusal.
    (should-not (cerebro--launch-refusal
                 text "Storm"
                 (float-time (encode-time (iso8601-parse "2026-08-26T04:52:00Z")))))
    ;; The `Z' is UTC wherever this Emacs is: `parse-time-string' reads the
    ;; wall clock in the local zone, so in any non-UTC timezone the launcher's
    ;; own line was compared against a `float-time' on a different scale and
    ;; the fallback silently rejected it (CI runs in UTC, which is why the
    ;; first version of this test could not see it).
    (let ((tz (getenv "TZ")))
      (unwind-protect
          (progn
            (setenv "TZ" "Asia/Tokyo")
            (should (equal (cerebro--launch-refusal text "Storm" since)
                           "the checkout is 4 commits behind"))
            (should-not (cerebro--launch-refusal
                         text "Storm"
                         (float-time (encode-time (iso8601-parse "2026-08-26T04:52:00Z"))))))
        (setenv "TZ" tz)))
    ;; No start time known: the newest line for the name.
    (should (equal (cerebro--launch-refusal text "Storm" nil)
                   "the checkout is 4 commits behind"))
    ;; A name with no line of its own.
    (should-not (cerebro--launch-refusal text "Beast" nil))
    (should-not (cerebro--launch-refusal "" "Storm" nil))
    (should-not (cerebro--launch-refusal nil "Storm" nil))))

(ert-deftest cerebro-test/file-tail-reads-the-end-and-never-signals ()
  "The fallback reads at most the last few KiB of errors.jsonl, and a file
that is not there is nil rather than an error - this runs from vterm's
sentinel, where a signal would take the record down with it."
  (let ((file (make-temp-file "cerebro-tail")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "abcdefghij"))
          (should (equal (cerebro--file-tail file 4) "ghij"))
          (should (equal (cerebro--file-tail file 100) "abcdefghij"))
          (should-not (cerebro--file-tail (concat file "-nope") 100)))
      (delete-file file))))

(ert-deftest cerebro-test/note-exit-falls-back-to-the-launcher-line ()
  "The whole of cb-ccl's first half: a session whose buffer was never drawn
takes its line from the errors.jsonl entry its own launcher wrote."
  (let* ((root (file-name-as-directory (make-temp-file "cerebro-root" t)))
         (cerebro--last-exit nil)
         (cerebro--sessions nil)
         (cerebro-log-verbosity 'decisions))
    (unwind-protect
        (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
          (make-directory (expand-file-name ".claude/cerebro" root) t)
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (let ((buf (generate-new-buffer "*fleet: Cyclops*")))
            (unwind-protect
                (progn
                  (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
                  (with-current-buffer buf
                    (setq default-directory root)
                    (setq cerebro--session-started
                          (float-time (encode-time (iso8601-parse "2026-08-26T04:51:00Z")))))
                  (with-temp-file (expand-file-name ".cerebro/state/errors.jsonl" root)
                    (insert "{\"event\":\"error\",\"ts\":\"2026-08-26T04:51:14Z\",\"context\":\"launch Cyclops\",\"message\":\"claude is not on PATH\"}\n"))
                  (cerebro--note-exit buf "exited abnormally with code 2\n")
                  (should (equal (alist-get "Cyclops" cerebro--last-exit nil nil #'equal)
                                 '(:code "2" :line "claude is not on PATH"))))
              (kill-buffer buf))))
      (delete-directory root t))))

(ert-deftest cerebro-test/note-exit-logs-an-error-for-an-exit-the-launcher-did-not-explain ()
  "errors.jsonl is the file the navigator is told to open, and it held nothing
about the day the fleet could not start.  Every abnormal exit the launcher did
not already account for gets a line there, blamed on `session <Name>' (cb-ccl)
- and one it DID account for gets none, since that line is already in this
very file."
  (let* ((root (file-name-as-directory (make-temp-file "cerebro-root" t)))
         (errors (expand-file-name ".cerebro/state/errors.jsonl" root))
         (cerebro-log-verbosity 'decisions))
    (cl-flet ((run (setup)
                (let ((cerebro--last-exit nil) (cerebro--sessions nil)
                      (buf (generate-new-buffer "*fleet: Cyclops*")))
                  (unwind-protect
                      (progn
                        (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
                        (with-current-buffer buf
                          (setq default-directory root)
                          (setq cerebro--session-started (float-time))
                          (funcall setup))
                        (cerebro--note-exit buf "exited abnormally with code 2\n"))
                    (kill-buffer buf))))
              (lines ()
                (if (file-exists-p errors)
                    (with-temp-buffer (insert-file-contents errors) (buffer-string))
                  "")))
      (unwind-protect
          (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
            (make-directory (expand-file-name ".claude/cerebro" root) t)
            (make-directory (expand-file-name ".cerebro/state" root) t)
            ;; Nothing printed, nothing from the launcher.
            (run #'ignore)
            (should (string-match-p "\"context\":\"session Cyclops\"" (lines)))
            (should (string-match-p "exited with code 2 and printed nothing" (lines)))
            ;; A line in the buffer: the error names it.
            (delete-file errors)
            (run (lambda () (insert "boom\n")))
            (should (string-match-p "exited with code 2: boom" (lines)))
            ;; The launcher already said why: no second line about it.
            (delete-file errors)
            (with-temp-file errors
              (insert "{\"event\":\"error\",\"ts\":\"2099-01-01T00:00:00Z\",\"context\":\"launch Cyclops\",\"message\":\"claude is not on PATH\"}\n"))
            (run #'ignore)
            (should-not (string-match-p "session Cyclops" (lines))))
        (delete-directory root t)))))

(ert-deftest cerebro-test/note-exit-logs-abnormal-true-without-a-line ()
  "The incident log carried 274 exits reading {\"code\":\"2\",\"abnormal\":null}:
with no line there was no record, and `abnormal\=' was computed from the record
rather than from the event.  An exit code of 2 is abnormal whether or not the
buffer had been drawn yet (cb-ccl)."
  (let* ((root (file-name-as-directory (make-temp-file "cerebro-root" t)))
         (cerebro--last-exit nil)
         (cerebro--sessions nil)
         (cerebro-log-verbosity 'decisions))
    (unwind-protect
        (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
          (make-directory (expand-file-name ".claude/cerebro" root) t)
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (let ((buf (generate-new-buffer "*fleet: Storm*")))
            (unwind-protect
                (progn
                  (setf (alist-get "Storm" cerebro--sessions nil nil #'equal) buf)
                  (with-current-buffer buf (setq default-directory root))
                  (cerebro--note-exit buf "exited abnormally with code 2\n")
                  (should (equal (alist-get "Storm" cerebro--last-exit nil nil #'equal)
                                 '(:code "2" :line nil)))
                  (with-temp-buffer
                    (insert-file-contents
                     (expand-file-name ".cerebro/state/decisions.jsonl" root))
                    (goto-char (point-max))
                    (forward-line -1)
                    (let ((line (json-parse-string
                                 (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position))
                                 :object-type 'alist)))
                      (should (equal (alist-get 'event line) "exit"))
                      (should (eq (alist-get 'abnormal line) t))
                      (should (eq (alist-get 'last_line line) :null)))))
              (kill-buffer buf))))
      (delete-directory root t))))

(ert-deftest cerebro-test/note-exit-resolves-the-root-from-the-session-buffer ()
  "vterm's sentinel runs `vterm-exit-functions' with whatever buffer happens
to be current, and `cerebro--repo-root' signals from one with no mount above
it.  `cerebro--note-exit' must therefore take the root from the buffer that
died - and must record the last line whether or not a root can be found at
all, because the row's whole account of an abnormal exit hangs on it."
  (let* ((root (file-name-as-directory (make-temp-file "cerebro-root" t)))
         (elsewhere (file-name-as-directory (make-temp-file "cerebro-nowhere" t)))
         (cerebro--last-exit nil)
         (cerebro--sessions nil)
         (cerebro-log-verbosity 'decisions))
    (unwind-protect
        (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
          (make-directory (expand-file-name ".claude/cerebro" root) t)
          (make-directory (expand-file-name ".cerebro/state" root) t)
          ;; A session buffer under a real mount: the record is made and the
          ;; log line lands under that root, not under the current buffer's.
          (let ((buf (generate-new-buffer "*fleet: Cyclops*")))
            (unwind-protect
                (with-temp-buffer
                  (setq default-directory elsewhere)
                  (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
                  (with-current-buffer buf
                    (setq default-directory root)
                    (insert "cerebro: boom\n"))
                  (cerebro--note-exit buf "exited abnormally with code 2\n")
                  (should (equal (alist-get "Cyclops" cerebro--last-exit nil nil #'equal)
                                 '(:code "2" :line "cerebro: boom")))
                  (let ((log (expand-file-name ".cerebro/state/decisions.jsonl" root)))
                    (should (file-exists-p log))
                    (with-temp-buffer
                      (insert-file-contents log)
                      (should (string-match-p "\"event\":\"exit\"" (buffer-string))))))
              (kill-buffer buf)))
          ;; A session buffer with no mount above it: no error, and the
          ;; record is still made.
          (setq cerebro--last-exit nil)
          (let ((buf (generate-new-buffer "*fleet: Cyclops*")))
            (unwind-protect
                (progn
                  (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
                  (with-current-buffer buf
                    (setq default-directory elsewhere)
                    (insert "cerebro: boom\n"))
                  (cerebro--note-exit buf "exited abnormally with code 2\n")
                  (should (equal (alist-get "Cyclops" cerebro--last-exit nil nil #'equal)
                                 '(:code "2" :line "cerebro: boom"))))
              (kill-buffer buf))))
      (delete-directory root t)
      (delete-directory elsewhere t))))

;; ---------------------------------------------------------------------------
;; ah-4ao increment 1: telling an implementer to finish

(ert-deftest cerebro-test/finish-action-writes-for-unflagged-implementer ()
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working
                                             nil "ah-f9c")
                nil)
              'write)))

(ert-deftest cerebro-test/finish-action-offers-clear-when-flagged ()
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working
                                             nil "ah-f9c")
                t)
              'offer-clear)))

(ert-deftest cerebro-test/finish-action-tells-a-running-role-to-finish-its-pass ()
  "It used to refuse: an interactive role had no bead to finish and no flag
to write.  Since cb-5yr it has a pass, and the flag ends it and leaves the
name down - `cerebro-test/finish-action-for-interactive-rows' has the rest."
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'up)
                nil)
              'write-disarm)))

;; ---------------------------------------------------------------------------
;; ah-ymn: `f' on an idle implementer stops it now, not after one more bead

(ert-deftest cerebro-test/finish-action-stops-an-idle-implementer-now ()
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'idle)
                nil)
              'stop-now))
  ;; A flag already set is still offered for clearing, whatever the state.
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'idle)
                t)
              'offer-clear)))

(ert-deftest cerebro-test/finish-action-refuses-a-dead-implementer ()
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead)
                nil)
              'dead))
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead)
                t)
              'offer-clear)))

(ert-deftest cerebro-test/finish-action-refuses-an-idle-implementer-outside-emacs ()
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'idle t)
                nil)
              'external))
  ;; The working case, external or not, is untouched by this bead.
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working
                                             t "ah-f9c")
                nil)
              'write)))

(ert-deftest cerebro-test/entry-finishing-is-a-glyph ()
  "The list says a stop flag took effect while the bead is still in flight -
`f' does not stop anything, so the marker has to come from somewhere. It used
to be the word \" finishing\", which alone cost the State column eleven
columns; a glyph says the same thing in two (see ah-lyc)."
  (let* ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working
                                             nil "ah-f9c"))
         (now (current-time))
         (flagged-state-col (aref (cadr (cerebro--entry agent now t)) 2))
         (unflagged-state-col (aref (cadr (cerebro--entry agent now nil)) 2))
         (default-state-col (aref (cadr (cerebro--entry agent now)) 2)))
    (should (equal flagged-state-col "working ■"))
    (should-not (string-match-p "■" unflagged-state-col))
    ;; The third argument is optional, and omitting it must read as unflagged -
    ;; every existing caller of `cerebro--entry' predates this argument.
    (should (equal unflagged-state-col default-state-col))))

(ert-deftest cerebro-test/finish-key-is-bound ()
  (should (eq (lookup-key cerebro-mode-map "f") #'cerebro-finish)))

(ert-deftest cerebro-test/write-stop-flag-creates-a-missing-directory ()
  "Since ah-2n3.1 `cerebro--repo-root' is located by `.claude/cerebro', not by
this directory, so `.cerebro/state' is no longer guaranteed to exist."
  (let ((root (make-temp-file "cerebro-test-" t)))
    (unwind-protect
        (progn
          (cerebro--write-stop-flag root "Wolverine")
          (should (file-exists-p (cerebro--stop-flag-path root "Wolverine"))))
      (delete-directory root t))))

(ert-deftest cerebro-test/entry-finishing-marker-only-for-in-flight-states ()
  "\"dead ■\" or \"idle ■\" would describe a bead that is not actually in
flight for the flag to be waiting on - and since ah-ymn there is barely a
window to see one: an idle implementer under a flag is retired within a
tick, and `f' refuses outright for a dead or externally-idle one rather than
writing a flag at all. This test constructs the row directly, bypassing
`cerebro--finish-action', to prove the rendering rule holds regardless."
  (let ((now (current-time)))
    (dolist (state '(dead idle))
      (let* ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer state))
             (state-col (aref (cadr (cerebro--entry agent now t)) 2)))
        (should-not (string-match-p "■" state-col))))
    (dolist (state '(working asking))
      (let* ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer state
                                                 nil "ah-f9c"))
             (state-col (aref (cadr (cerebro--entry agent now t)) 2)))
        (should (string-match-p "■" state-col))))))

;; ---------------------------------------------------------------------------
;; ah-vcf.3 increment 2: owned sessions feed the list

;; The seam this bead fills: a non-empty OWNED turns an interactive agent
;; `up' and un-externals it.  Already true of ah-vcf.2's --derive; pinned
;; here so a later change to the derivation cannot silently break the seam.
(ert-deftest cerebro-test/derive-owned-interactive-is-up-not-external ()
  (let* ((agents (cerebro--derive nil cerebro-test--interactive nil
                                          #'cerebro-test--never-alive nil '("Xavier")))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'up))
    (should-not (cerebro-agent-external xavier))))

;; ---------------------------------------------------------------------------
;; ah-5pp: the fleet view records the sessions it starts, rather than
;; inferring ownership from a buffer name

(ert-deftest cerebro-test/session-table-knows-what-it-started ()
  (let ((cerebro--sessions nil)
        (buf (generate-new-buffer " *cerebro-test-session*")))
    (unwind-protect
        (let ((proc (start-process "cerebro-test" buf "sleep" "30")))
          (unwind-protect
              (progn
                (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
                (should (eq (cerebro--session "Cyclops") buf))
                (should (equal (cerebro--owned) '("Cyclops")))
                (should (equal (cerebro--session-name buf) "Cyclops"))
                (should (null (cerebro--session "Rogue")))
                (delete-process proc)
                (while (process-live-p proc) (accept-process-output proc 0.1))
                ;; The process is gone but the buffer lingers - not `live',
                ;; but still ours: the table entry survives so
                ;; `cerebro--recorded-buffer' can still find it to clean up.
                (should (null (cerebro--session "Cyclops")))
                (should (eq (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf))
                (should (eq (cerebro--recorded-buffer "Cyclops") buf)))
            (when (process-live-p proc) (delete-process proc))))
      (kill-buffer buf))))

(ert-deftest cerebro-test/session-table-forgets-a-killed-buffer ()
  (let ((cerebro--sessions nil)
        (buf (generate-new-buffer " *cerebro-test-session-2*")))
    (let ((proc (start-process "cerebro-test" buf "sleep" "30")))
      (set-process-query-on-exit-flag proc nil)
      (unwind-protect
          (progn
            (setf (alist-get "Storm" cerebro--sessions nil nil #'equal) buf)
            (should (eq (cerebro--session "Storm") buf))
            (kill-buffer buf)
            (should (null (cerebro--session "Storm")))
            (should (null (alist-get "Storm" cerebro--sessions nil nil #'equal))))
        (when (process-live-p proc) (delete-process proc))))))

;; ---------------------------------------------------------------------------
;; ah-vcf.3 increment 3: windows and keys

(ert-deftest cerebro-test/show-detail-picks-session-when-owned-else-placeholder ()
  (let* ((cerebro--sessions nil)
         (owned-agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working
                                                    nil "ah-f9c"))
         (dead-agent (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name owned-agent))
         (placeholder-name "*fleet: Rogue (no view)*")
         (buf (get-buffer-create session-name))
         (proc (start-process "cerebro-test" buf "sleep" "30")))
    (set-process-query-on-exit-flag proc nil)
    (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
    (unwind-protect
        (progn
          (should (eq (cerebro--show-detail owned-agent) buf))
          (let ((placeholder (cerebro--show-detail dead-agent)))
            (should (equal (buffer-name placeholder) placeholder-name))
            (should (equal (with-current-buffer placeholder (buffer-string))
                            (cerebro--placeholder dead-agent)))))
      (when (process-live-p proc) (delete-process proc))
      (dolist (name (list session-name placeholder-name))
        (when (get-buffer name) (kill-buffer name))))))

;; ---------------------------------------------------------------------------
;; Starting an agent puts its session in the detail window

(defmacro cerebro-test--with-layout (list-buffer detail-window &rest body)
  "Run BODY in a two-window layout like `cerebro--setup-layout' builds.

LIST-BUFFER is bound to the selected window's buffer, standing in for the
fleet list, and DETAIL-WINDOW to the window on its right.  BODY runs with
LIST-BUFFER current and `cerebro--detail-window' set, as `cerebro-start'
runs."
  (declare (indent 2))
  `(let ((,list-buffer (generate-new-buffer " *cerebro-test-list*")))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (set-window-buffer (selected-window) ,list-buffer)
           (let ((,detail-window (split-window (selected-window) nil 'right)))
             (with-current-buffer ,list-buffer
               (setq-local cerebro--detail-window ,detail-window)
               ,@body)))
       (kill-buffer ,list-buffer))))

(defmacro cerebro-test--shown-elsewhere (buffer window &rest body)
  "Run BODY with BUFFER displayed in WINDOW while another window is selected.

How the timer sees both panels: the buffer is on screen, but not where
point is."
  (declare (indent 2))
  `(let ((elsewhere (generate-new-buffer " *cerebro-test-elsewhere*")))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (set-window-buffer (selected-window) elsewhere)
           (let ((,window (split-window (selected-window) nil 'below)))
             (set-window-buffer ,window ,buffer)
             ,@body))
       (kill-buffer elsewhere))))

;; Entering through `cerebro--launch' rather than a lower seam: without this,
;; `cerebro--launch' could go back to displaying its buffer directly and every
;; other test here would still pass.  Proven by mutation, not assumed.
;;
;; Both stub `require' rather than loading vterm, so `vterm-shell' is never
;; read - these pin where the session is displayed, not the command.
(ert-deftest cerebro-test/launch-makes-the-session-in-no-window ()
  (let* ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require))
         (vterm-mode-calls nil))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (let ((detail-buffer-name (buffer-name (window-buffer detail-window))))
            (cl-letf (((symbol-function 'cerebro--repo-root)
                       (lambda () default-directory))
                      ;; vterm is not installed in batch; stand in for it.
                      ;; Delegate rather than blanket-nil: a `should' failing
                      ;; inside this body has ert building its explanation
                      ;; while `require' is stubbed, and a lazy require
                      ;; answering nil there produces a confusing secondary
                      ;; failure.
                      ((symbol-function 'require)
                       (lambda (feature &rest args)
                         (or (eq feature 'vterm) (apply orig-require feature args))))
                      ((symbol-function 'vterm-mode)
                       (lambda () (push (current-buffer) vterm-mode-calls))))
              (let ((list-window (selected-window)))
                (cerebro--launch agent)
                (should (get-buffer session-name))
                (should (equal (mapcar #'buffer-name vterm-mode-calls)
                                (list session-name)))
                (should-not (get-buffer-window session-name t))
                (should (eq (selected-window) list-window))
                (should (equal (buffer-name (window-buffer list-window))
                                (buffer-name list-buffer)))
                (should (eq (current-buffer) list-buffer))
                (should (equal (buffer-name (window-buffer detail-window))
                                detail-buffer-name))))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

(ert-deftest cerebro-test/session-buffer-outlives-its-process ()
  "The session buffer\='s life is this view\='s to decide, never vterm\='s.

vterm kills the buffer from its own sentinel the moment the process dies
(`vterm-kill-buffer-on-exit\=' defaults to t), which is what turned every pass
end into \"Selecting deleted buffer\" and lost the record of the pass.  Bound
buffer-locally to nil, and *after* `vterm-mode\=': a major mode runs
`kill-all-local-variables\=', so a binding made before it is discarded."
  (let ((orig-require (symbol-function 'require))
        (buffer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &rest args)
                     (or (eq feature 'vterm) (apply orig-require feature args))))
                  ;; What a real major mode does, and the whole point of the
                  ;; ordering this pins.
                  ((symbol-function 'vterm-mode)
                   (lambda () (kill-all-local-variables))))
          (setq buffer (cerebro--make-session-buffer "*fleet: test*"))
          (should (local-variable-p 'vterm-kill-buffer-on-exit buffer))
          (should (null (buffer-local-value 'vterm-kill-buffer-on-exit buffer))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest cerebro-test/launch-kills-the-previous-sessions-dead-buffer ()
  "A buffer still recorded under this name belongs to a session whose process
has died - a live one was refused above.  It outlives its process now, so it
is killed here rather than orphaned when the new entry overwrites it."
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require))
         (old (generate-new-buffer "*fleet: Cyclops (dead)*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root)
                   (lambda () default-directory))
                  ((symbol-function 'require)
                   (lambda (feature &rest args)
                     (or (eq feature 'vterm) (apply orig-require feature args))))
                  ((symbol-function 'vterm-mode) #'ignore))
          (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) old)
          (cerebro--launch agent)
          (should-not (buffer-live-p old))
          (should (get-buffer session-name)))
      (when (buffer-live-p old) (kill-buffer old))
      (when (get-buffer session-name) (kill-buffer session-name)))))

(ert-deftest cerebro-test/launch-touches-no-window-even-a-dedicated-one ()
  "A dedicated detail window used to be where a signal could strand a
half-built session (`set-window-buffer' refusing it between
`generate-new-buffer' and `vterm-mode').  There is no window step inside
launch any more, so nothing can strand anything - the dedication is just
left alone."
  (let* ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require))
         (hostage (generate-new-buffer " *cerebro-test-hostage*")))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (set-window-buffer detail-window hostage)
          (set-window-dedicated-p detail-window t)
          (cl-letf (((symbol-function 'cerebro--repo-root)
                     (lambda () default-directory))
                    ((symbol-function 'require)
                     (lambda (feature &rest args)
                       (or (eq feature 'vterm) (apply orig-require feature args))))
                    ((symbol-function 'vterm-mode) #'ignore))
            (let ((list-window (selected-window)))
              (cerebro--launch agent)
              (should (get-buffer session-name))
              (should (equal (buffer-name (window-buffer detail-window))
                              (buffer-name hostage)))
              (should (equal (buffer-name (window-buffer list-window))
                              (buffer-name list-buffer))))))
      (kill-buffer hostage)
      (when (get-buffer session-name) (kill-buffer session-name)))))

;; A stubbed `vterm-mode' that starts nothing reads as dead to
;; `cerebro--session' - this one starts a real process so liveness, and
;; therefore ownership, is real.
(ert-deftest cerebro-test/launch-records-its-session-and-refuses-a-second ()
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require)))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (cl-letf (((symbol-function 'cerebro--repo-root)
                     (lambda () default-directory))
                    ((symbol-function 'require)
                     (lambda (feature &rest args)
                       (or (eq feature 'vterm) (apply orig-require feature args))))
                    ((symbol-function 'vterm-mode)
                     (lambda ()
                       (let ((proc (start-process "cerebro-test" (current-buffer)
                                                   "sleep" "30")))
                         (set-process-query-on-exit-flag proc nil)))))
            (cerebro--launch agent)
            (should (equal (cerebro--session-name (get-buffer session-name)) "Cyclops"))
            (should (equal (cerebro--owned) '("Cyclops")))
            (should-error (cerebro--launch agent))
            (should (equal (length cerebro--sessions) 1))
            (should (equal (cerebro--owned) '("Cyclops")))))
      (when (get-buffer session-name)
        (let ((proc (get-buffer-process (get-buffer session-name))))
          (when (process-live-p proc) (delete-process proc)))
        (kill-buffer session-name)))))

(ert-deftest cerebro-test/forget-session-forgets-the-session ()
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (buf (get-buffer-create session-name)))
    (unwind-protect
        (let ((proc (start-process "cerebro-test" buf "sleep" "30")))
          (set-process-query-on-exit-flag proc nil)
          (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
          (should (eq (cerebro--session "Cyclops") buf))
          (cerebro--forget-session agent)
          (should (null (get-buffer session-name)))
          (should (null (cerebro--session "Cyclops"))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

(ert-deftest cerebro-test/forget-session-kills-a-buffer-whose-process-already-exited ()
  "A session whose process exited but whose buffer lingers (vterm leaves it
for the navigator to read) is still ours to kill - `cerebro--session'
requires a live process and would wrongly skip it, leaving the buffer
around for the next launch to collide with (review comment on PR #36)."
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (buf (get-buffer-create session-name)))
    (unwind-protect
        (progn
          (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
          (should (null (cerebro--session "Cyclops")))   ; no process: not "live"
          (cerebro--forget-session agent)
          (should (null (get-buffer session-name)))
          (should (null (alist-get "Cyclops" cerebro--sessions nil nil #'equal))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

(ert-deftest cerebro-test/kill-session-buffer-kills-a-buffer-whose-process-already-exited ()
  "The same fix as `forget-session-kills-a-buffer-whose-process-already-exited',
for the `k' path."
  (let* ((cerebro--sessions nil)
         (root (make-temp-file "cerebro-test-" t))
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (buf (get-buffer-create session-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'revert-buffer) #'ignore)
                  ((symbol-function 'cerebro--show-detail) #'ignore))
          (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
          (should (null (cerebro--session "Cyclops")))
          (cerebro--kill-session-buffer agent root)
          (should (null (get-buffer session-name)))
          (should (null (alist-get "Cyclops" cerebro--sessions nil nil #'equal))))
      (when (get-buffer session-name) (kill-buffer session-name))
      (delete-directory root t))))

;; The placement itself - `cerebro-start' is where it lives now that launch
;; touches no window.
(ert-deftest cerebro-test/start-shows-the-session-in-the-detail-window ()
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require)))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (cl-letf (((symbol-function 'cerebro--agent-at-point) (lambda () agent))
                    ((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                    ((symbol-function 'cerebro--stop-flag-p) (lambda (&rest _) nil))
                    ((symbol-function 'revert-buffer) #'ignore)
                    ((symbol-function 'require)
                     (lambda (feature &rest args)
                       (or (eq feature 'vterm) (apply orig-require feature args))))
                    ((symbol-function 'vterm-mode)
                     (lambda ()
                       (let ((proc (start-process "cerebro-test" (current-buffer)
                                                   "sleep" "30")))
                         (set-process-query-on-exit-flag proc nil)))))
            (let ((list-window (selected-window)))
              (cerebro-start)
              (should (equal (buffer-name (window-buffer detail-window))
                              session-name))
              (should (equal (buffer-name (window-buffer list-window))
                              (buffer-name list-buffer)))
              (should (eq (selected-window) list-window)))))
      (when (get-buffer session-name)
        (let ((proc (get-buffer-process (get-buffer session-name))))
          (when (process-live-p proc) (delete-process proc)))
        (kill-buffer session-name)))))

(ert-deftest cerebro-test/start-with-no-detail-window-shows-the-session-nowhere ()
  "A torn-down layout must still start the agent - without popping up a
window to show it.  `cerebro--setup-layout' only rebuilds the split when the
*list* window is dead, so `C-x 1' in the list window leaves a live list and a
dead detail window that `M-x cerebro' will not restore.  Popping up a fresh
window there would reintroduce the window-choosing this bead removes."
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require)))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (delete-window detail-window)
          (cl-letf (((symbol-function 'cerebro--agent-at-point) (lambda () agent))
                    ((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                    ((symbol-function 'cerebro--stop-flag-p) (lambda (&rest _) nil))
                    ((symbol-function 'revert-buffer) #'ignore)
                    ((symbol-function 'require)
                     (lambda (feature &rest args)
                       (or (eq feature 'vterm) (apply orig-require feature args))))
                    ((symbol-function 'vterm-mode) #'ignore))
            (let ((list-window (selected-window)))
              (cerebro-start)
              (should (get-buffer session-name))
              (should-not (get-buffer-window session-name t))
              (should (equal (buffer-name (window-buffer list-window))
                              (buffer-name list-buffer))))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

;; ---------------------------------------------------------------------------
;; Interactive implementers: one bead per session, and who ends it

(ert-deftest cerebro-test/derive-implementer-asking-state ()
  "The state file gained `asking\=' when implementers became interactive."
  (let* ((states '(("Storm" . ((state . "asking") (bead . "ah-a1b")
                                (since . "2026-08-14T09:00:00Z") (pid . 43)))))
         (agents (cerebro--derive '("Storm") nil states
                                          #'cerebro-test--always-alive nil
                                          '("Storm"))))
    (should (eq (cerebro-agent-state (nth 0 agents)) 'asking))
    ;; The bead stays visible - it is what the navigator needs to see.
    (should (equal (cerebro-agent-bead (nth 0 agents)) "ah-a1b"))))

(defun cerebro-test--supervised (state &optional external since)
  (make-cerebro-agent :name "Cyclops" :role "implementer" :kind 'implementer
                              :state state :bead "ah-f9c" :since since
                              :external external))

(defconst cerebro-test--now (encode-time (iso8601-parse "2026-08-14T09:30:00Z")))

(ert-deftest cerebro-test/a-done-file-is-not-acted-on ()
  "cb-1or.2 retired `done\=', so a file carrying it derives to `unknown\=' and
this function answers nothing about it - flag or no flag.  Acting on it would
mean supervising a session older than the running fleet."
  (let ((agent (make-cerebro-agent :name "Cyclops" :role "implementer"
                                   :kind 'implementer :state 'unknown
                                   :raw "done" :bead "ah-f9c")))
    (should (null (cerebro--supervise-action agent nil cerebro-test--now)))
    (should (null (cerebro--supervise-action agent t cerebro-test--now)))))

(ert-deftest cerebro-test/supervise-leaves-a-working-implementer-alone ()
  "`idle' is covered separately below - it retires under a stop flag; this
test is only about states with a bead genuinely in flight."
  (dolist (state '(working asking))
    (should (null (cerebro--supervise-action
                   (cerebro-test--supervised state nil "2026-08-14T09:29:00Z")
                   t cerebro-test--now)))))

;; ---------------------------------------------------------------------------
;; ah-ymn: `f' on an idle implementer stops it now, not after one more bead

(ert-deftest cerebro-test/supervise-retires-an-idle-implementer-under-stop ()
  "Nothing is in flight for an idle implementer, so a stop flag means *stop
now* rather than *finish* - unlike `waiting', which is a pass already over."
  (should (eq (cerebro--supervise-action (cerebro-test--supervised 'idle) t
                                                  cerebro-test--now)
              'retire))
  (should (null (cerebro--supervise-action (cerebro-test--supervised 'idle) nil
                                                    cerebro-test--now)))
  ;; Only an owned session is supervised at all.
  (should (null (cerebro--supervise-action (cerebro-test--supervised 'idle t) t
                                                    cerebro-test--now))))

(ert-deftest cerebro-test/supervise-never-touches-a-terminal-emacs-does-not-own ()
  "An implementer started outside Emacs belongs to whoever started it."
  (should (null (cerebro--supervise-action
                 (cerebro-test--supervised 'waiting t "2026-08-14T09:00:00Z") nil
                 cerebro-test--now))))

(ert-deftest cerebro-test/supervise-leaves-a-dead-implementer-dead ()
  "Restarting a dead one would fight the navigator's own `k'.

`standby' is the retried shape (cb-hzs): a name this view armed and whose
session then went away.  A `dead' row is one it did not arm, or one whose
session printed a reason on the way out, and neither is brought back here."
  (should (null (cerebro--supervise-action (cerebro-test--supervised 'dead) nil
                                                    cerebro-test--now))))

(ert-deftest cerebro-test/supervise-retires-a-standby-implementer-under-a-stop-flag ()
  "`f' on a working implementer means *finish, then stop*.  If the session
dies before it finishes, the flag still means do not start another - so the
retry the standby row promises is the one thing that must not happen."
  (should (eq (cerebro--supervise-action (cerebro-test--supervised 'standby) t
                                         cerebro-test--now)
              'retire))
  (should (null (cerebro--supervise-action (cerebro-test--supervised 'standby) nil
                                           cerebro-test--now)))
  ;; A standby role's flag is `cerebro--start-due's to act on, not this one's.
  (should (null (cerebro--supervise-action
                 (cerebro-test--interactive "Psylocke" "verifier" 'standby) t
                 cerebro-test--now))))

(ert-deftest cerebro-test/finish-action-on-a-standby-implementer-says-which-key ()
  "There is no pass to finish and no session to stop, so `f' says which key
does what instead of writing a flag - the same answer a standby role gets."
  (should (eq (cerebro--finish-action (cerebro-test--supervised 'standby) nil)
              'standby))
  (should (eq (cerebro--finish-action (cerebro-test--supervised 'standby) t)
              'standby)))

(ert-deftest cerebro-test/supervise-nudges-a-question-nobody-answered ()
  "Asking is allowed; waiting for ever is not.

The navigator may be away, and a fleet all blocked on unanswered questions
drains no queue.  Past the timeout the session is told to hand the bead to
the `human' queue and finish, which is a complete run rather than an
abandoned one."
  (let ((cerebro-answer-timeout 900))
    ;; 14 minutes in: still the navigator's to answer.
    (should (null (cerebro--supervise-action
                   (cerebro-test--supervised 'asking nil "2026-08-14T09:16:00Z")
                   nil cerebro-test--now)))
    ;; 16 minutes in: past the timeout.
    (should (eq (cerebro--supervise-action
                 (cerebro-test--supervised 'asking nil "2026-08-14T09:14:00Z")
                 nil cerebro-test--now)
                'nudge))))

(ert-deftest cerebro-test/supervise-nudge-does-not-depend-on-the-stop-flag ()
  "A stopped implementer still has a bead in flight, so it still gets an answer."
  (let ((cerebro-answer-timeout 900))
    (should (eq (cerebro--supervise-action
                 (cerebro-test--supervised 'asking nil "2026-08-14T09:00:00Z")
                 t cerebro-test--now)
                'nudge))))

(ert-deftest cerebro-test/supervise-unparseable-since-does-not-nudge ()
  "A torn state file must not spray instructions into a working session."
  (should (null (cerebro--supervise-action
                 (cerebro-test--supervised 'asking nil "not-a-timestamp")
                 nil cerebro-test--now)))
  (should (null (cerebro--supervise-action
                 (cerebro-test--supervised 'asking nil nil)
                 nil cerebro-test--now))))

(ert-deftest cerebro-test/entry-shows-the-new-states ()
  (dolist (state '(asking))
    (let* ((agent (cerebro-test--supervised state nil "2026-08-14T09:00:00Z"))
           (row (nth 1 (cerebro--entry agent cerebro-test--now))))
      (should (equal (aref row 2) (symbol-name state)))
      (should (equal (aref row 3) "ah-f9c")))))

(ert-deftest cerebro-test/supervise-acts-once-per-question ()
  "The poll runs every 5s; the nudge must not be sprayed into the session.

Repeating it every tick would bury the agent's own output and keep resetting
what it was told, which is worse than not telling it at all."
  (let ((nudged nil)
        (agent (cerebro-test--supervised 'asking nil "2026-08-14T09:00:00Z"))
        (cerebro-answer-timeout 900))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) nil))
              ((symbol-function 'cerebro--nudge)
               (lambda (a) (push (cerebro-agent-name a) nudged))))
      (with-temp-buffer
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now '(supervising))
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now '(supervising))
        (should (equal nudged '("Cyclops")))
        ;; Once it answers and moves on, a later question is nudgeable again.
        (cerebro--supervise (list (cerebro-test--supervised 'working))
                                    "/fake/repo" cerebro-test--now '(supervising))
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now '(supervising))
        (should (equal nudged '("Cyclops" "Cyclops")))))))

;; ---------------------------------------------------------------------------
;; ah-y3j1: one typing path, and the return sent separately from the text

(ert-deftest cerebro-test/typing-into-a-session-sends-the-return-on-its-own ()
  "The return must not ride in the same terminal read as the text.

Sent back to back they arrive as one burst ending in a carriage return, which
an Ink-based TUI reads as a paste - and a paste containing a newline lands in
the composer instead of submitting.  The woken agent then sits on its own wake
message.  So the text goes now and the return goes on a timer."
  (let ((typed nil)
        (returned 0)
        (scheduled nil)
        (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'waiting))
        (cerebro-return-delay 0.3))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'cerebro--session) (lambda (_name) buf))
                  ((symbol-function 'vterm-send-string) (lambda (s) (push s typed)))
                  ((symbol-function 'vterm-send-return)
                   (lambda () (setq returned (1+ returned))))
                  ((symbol-function 'run-at-time)
                   (lambda (delay repeat fn) (push (list delay repeat fn) scheduled) nil)))
          (cerebro--type-into-session agent "hello")
          (should (equal typed '("hello")))
          ;; The bug, in one line: today the return has already gone by now.
          (should (= returned 0))
          (should (= (length scheduled) 1))
          (should (equal (nth 0 (car scheduled)) cerebro-return-delay))
          (funcall (nth 2 (car scheduled)))
          (should (= returned 1)))))))

(ert-deftest cerebro-test/a-session-killed-before-the-return-is-left-alone ()
  "A session killed inside the delay must not take the poll down with it.

Three hundred milliseconds is short, but a kill landing exactly there is the
kind of race that surfaces once a fortnight and never reproduces."
  (let ((returned 0)
        (scheduled nil)
        (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'waiting))
        (buf (generate-new-buffer " *cerebro-test-session*")))
    (cl-letf (((symbol-function 'cerebro--session) (lambda (_name) buf))
              ((symbol-function 'vterm-send-string) (lambda (_s) nil))
              ((symbol-function 'vterm-send-return)
               (lambda () (setq returned (1+ returned))))
              ((symbol-function 'run-at-time)
               (lambda (delay repeat fn) (push (list delay repeat fn) scheduled) nil)))
      (cerebro--type-into-session agent "hello")
      (kill-buffer buf)
      (funcall (nth 2 (car scheduled)))
      (should (= returned 0)))))

(ert-deftest cerebro-test/supervise-does-nothing-with-a-done-file ()
  "The retired word reaches no branch: nothing is killed and nothing launched."
  (let ((calls nil)
        (agent (make-cerebro-agent :name "Cyclops" :role "implementer"
                                   :kind 'implementer :state 'unknown
                                   :raw "done" :bead "ah-f9c")))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) nil))
              ((symbol-function 'cerebro--forget-session)
               (lambda (a) (push (cons 'kill (cerebro-agent-name a)) calls)))
              ((symbol-function 'cerebro--launch)
               (lambda (a) (push (cons 'launch (cerebro-agent-name a)) calls))))
      (with-temp-buffer
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now '(supervising))
        (should (null calls))))))

(ert-deftest cerebro-test/supervise-retire-kills-without-launching ()
  "A stop flag means this name does not come back until the navigator says so."
  (let ((calls nil)
        (agent (cerebro-test--supervised 'idle)))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) t))
              ((symbol-function 'cerebro--forget-session)
               (lambda (a) (push (cons 'kill (cerebro-agent-name a)) calls)))
              ((symbol-function 'cerebro--launch)
               (lambda (a) (push (cons 'launch (cerebro-agent-name a)) calls))))
      (with-temp-buffer
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now '(supervising))
        (should (equal calls '((kill . "Cyclops"))))))))

(ert-deftest cerebro-test/clear-stop-flag-tolerates-a-missing-file ()
  "The helper must not error when there is nothing to remove -
`cerebro--supervise' runs from a timer with demoted errors, so an
unguarded `delete-file' on a missing file would be swallowed silently."
  (let ((root (make-temp-file "cerebro-test-" t)))
    (unwind-protect
        (progn
          (should-not (cerebro--stop-flag-p root "Wolverine"))
          (cerebro--clear-stop-flag root "Wolverine")
          (should-not (cerebro--stop-flag-p root "Wolverine")))
      (delete-directory root t))))

(ert-deftest cerebro-test/retire-removes-the-stop-flag ()
  "The flag has done its job by the time `retire' runs; leaving it behind
is what let the next session inherit an instruction from a session that no
longer exists."
  (let ((root (make-temp-file "cerebro-test-" t))
        (agent (cerebro-test--supervised 'idle)))
    (unwind-protect
        (progn
          (cerebro--write-stop-flag root "Cyclops")
          (cl-letf (((symbol-function 'cerebro--forget-session) (lambda (_a) nil))
                    ((symbol-function 'cerebro--launch) (lambda (&rest _) nil)))
            (with-temp-buffer
              (cerebro--supervise (list agent) root cerebro-test--now '(supervising))))
          (should-not (cerebro--stop-flag-p root "Cyclops")))
      (delete-directory root t))))

(ert-deftest cerebro-test/supervise-ends-an-idle-session-under-stop ()
  "The supervisor, not just the pure decision, actually ends an idle
implementer under a stop flag - the session-ender, not `cerebro--launch'."
  (let ((ended nil)
        (agent (cerebro-test--supervised 'idle)))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) t))
              ((symbol-function 'cerebro--forget-session)
               (lambda (a) (push (cerebro-agent-name a) ended)))
              ((symbol-function 'cerebro--launch) (lambda (&rest _) (error "launched"))))
      (with-temp-buffer
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now '(supervising))
        (should (equal ended '("Cyclops")))))))

(ert-deftest cerebro-test/stop-flag-path-is-the-documented-one ()
  (should (equal (cerebro--stop-flag-path "/repo" "Cyclops")
                  "/repo/.cerebro/state/Cyclops.stop")))

;; ---------------------------------------------------------------------------
;; A session Emacs owns is alive, whatever the state file says yet

(ert-deftest cerebro-test/derive-owned-implementer-without-a-state-file-is-idle ()
  "A just-launched implementer has a session before it has a state file.

Reporting it dead there is not cosmetic: it is what the row shows while
`cerebro--start-action' checks ownership before state and `cerebro--launch'
refuses a second session at the source - the row should not lie about what
`s' would do in the meantime."
  (let* ((agents (cerebro--derive '("Cyclops") nil '(("Cyclops" . nil))
                                           #'cerebro-test--never-alive nil '("Cyclops")))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'idle))
    (should-not (cerebro-agent-external agent))
    (should (eq (cerebro--start-action agent '("Cyclops")) 'already-up))))

(ert-deftest cerebro-test/derive-owned-implementer-ignores-a-stale-state-file ()
  "The same race, one restart later: the file is the *previous* session's.

Its pid is gone and its bead is finished, so trusting it would show a bead
nobody is working on.  `cerebro--owned' already requires a live process, so
ownership is the better evidence."
  (let* ((states '(("Cyclops" . ((state . "working") (bead . "ah-old")
                                  (since . "2026-08-14T09:00:00Z") (pid . 4242)))))
         (agents (cerebro--derive '("Cyclops") nil states
                                           #'cerebro-test--never-alive nil '("Cyclops")))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'idle))
    (should (null (cerebro-agent-bead agent)))))

(ert-deftest cerebro-test/derive-unowned-implementer-without-a-session-is-dead ()
  "Ownership is what rescues it - absent that, a missing or stale file is death."
  (let ((no-file (car (cerebro--derive '("Rogue") nil '(("Rogue" . nil))
                                                #'cerebro-test--never-alive nil nil)))
        (stale (car (cerebro--derive
                     '("Rogue") nil
                     '(("Rogue" . ((state . "working") (bead . "ah-old")
                                    (since . "2026-08-14T09:00:00Z") (pid . 4242))))
                     #'cerebro-test--never-alive nil nil))))
    (should (eq (cerebro-agent-state no-file) 'dead))
    (should (eq (cerebro-agent-state stale) 'dead))))

(ert-deftest cerebro-test/launcher-path-is-inside-the-submodule ()
  "The launchers live in cerebro, which a consumer mounts at .claude/cerebro.

They used to live in the consumer's own scripts/, which is why the paths
here changed - a bare `scripts/launch' resolves to the consumer's
directory, where there is no longer anything by that name."
  (should (equal (cerebro--script "launch") ".claude/cerebro/scripts/launch"))
  (should (string-prefix-p ".claude/cerebro/scripts/" (cerebro--script "roster"))))

;; ---------------------------------------------------------------------------
;; Reading the list at a glance

(defun cerebro-test--faces-at (string index)
  "The face property at INDEX of STRING, always as a list."
  (let ((face (get-text-property index 'face string)))
    (if (listp face) face (list face))))

(ert-deftest cerebro-test/idle-glyph-is-blue-and-unlike-its-neighbours ()
  "Idle is not the same kind of nothing as dead, nor the same blue as standby.

An idle implementer has a session up and no bead - something the navigator
may want to act on - so it is neither the grey that means there is nobody
there at all, nor the green of an agent with work in hand.  Blue is also
`standby\='s, which is the one thing that makes this worth asserting: the two
are kept apart by shape as well, and this test is what fails if anyone ever
paints standby onto `cerebro-idle\=' or gives it the diamond."
  (should (memq 'cerebro-idle (cerebro-test--faces-at (cerebro--glyph 'idle) 0)))
  ;; Still distinguishable from the states either side of it.
  (should (memq 'success (cerebro-test--faces-at (cerebro--glyph 'working) 0)))
  (should (memq 'shadow (cerebro-test--faces-at (cerebro--glyph 'dead) 0)))
  (should (memq 'cerebro-standby (cerebro-test--faces-at (cerebro--glyph 'standby) 0)))
  (should-not (memq 'cerebro-idle (cerebro-test--faces-at (cerebro--glyph 'standby) 0)))
  ;; The three that read alike before: pairwise different pictures now.
  (let ((idle (substring-no-properties (cerebro--glyph 'idle)))
        (dead (substring-no-properties (cerebro--glyph 'dead)))
        (standby (substring-no-properties (cerebro--glyph 'standby))))
    (should-not (equal idle dead))
    (should-not (equal idle standby))
    (should-not (equal dead standby))))

(ert-deftest cerebro-test/idle-face-is-actually-blue-and-not-bold ()
  "`warning\=' is DarkOrange and bold, which is two wrongs at once.

Emacs defines `warning\=' as `:foreground \"DarkOrange\" :weight bold\' on any
colour display - so an idle glyph inheriting it would be orange, and bold,
which is the weight this view reserves for an agent that wants an answer.
`cerebro-idle\=' names its own colour instead, and is customizable in one
place for a theme where it does not read.  It is blue since cb-9qm, not the
gold it carried before - the gold moved to `cerebro-waiting\=', which is what
`waiting\=' and `unknown\=' are painted with now."
  (let ((spec (format "%S" (get 'cerebro-idle 'face-defface-spec))))
    (should (string-match-p "blue" (downcase spec)))
    (should-not (string-match-p "gold" (downcase spec)))
    (should-not (string-match-p "bold" (downcase spec)))))

(ert-deftest cerebro-test/idle-is-a-filled-diamond-not-a-ring ()
  "The shape lever has now been pulled twice on this one pair.

Idle was U+25CC DOTTED CIRCLE and dead is U+25CB WHITE CIRCLE: two hollow
rings that are the same picture at terminal sizes, so a yellow one read as
\"an empty circle, just like the dead\" however yellow it was. It became a
filled dot - and lost that argument too, because a filled dot is what
`working\=' is and what `unknown\=' is, leaving colour alone to carry the
difference from dead. It is U+25C6 BLACK DIAMOND now (cb-9qm): the only
diamond in the vocabulary, so neither shape nor colour is carrying the
distinction by itself."
  (let ((idle (substring-no-properties (cerebro--glyph 'idle)))
        (dead (substring-no-properties (cerebro--glyph 'dead)))
        (standby (substring-no-properties (cerebro--glyph 'standby)))
        (working (substring-no-properties (cerebro--glyph 'working))))
    (should (equal idle "◆"))
    (should-not (equal idle working))
    (should-not (equal idle standby))
    (should-not (equal idle dead))))

(ert-deftest cerebro-test/waiting-and-unknown-stay-gold-on-their-own-face ()
  "Only `idle\=' was asked to change colour, and it shared a face with two others.

`waiting\=' and `unknown\=' were painted with `cerebro-idle\=' because the three
meant the same thing at a glance - a session is up and there is nothing in
hand.  Repainting that one face for cb-9qm would have taken all three to blue
by accident, and blue `unknown\=' would then have been the same picture as blue
`idle\='.  So the gold moved to a face of its own and these two moved with it."
  (let ((waiting (cerebro--glyph 'waiting))
        (unknown (cerebro--glyph 'unknown))
        (spec (format "%S" (get 'cerebro-waiting 'face-defface-spec))))
    (should (memq 'cerebro-waiting (cerebro-test--faces-at waiting 0)))
    (should (memq 'cerebro-waiting (cerebro-test--faces-at unknown 0)))
    (should-not (memq 'cerebro-idle (cerebro-test--faces-at waiting 0)))
    (should-not (memq 'cerebro-idle (cerebro-test--faces-at unknown 0)))
    (should (string-match-p "gold" (downcase spec)))
    (should-not (string-match-p "bold" (downcase spec)))
    ;; Unknown keeps the filled dot; it is idle that became the diamond.
    (should (equal (substring-no-properties unknown) "●"))))

(ert-deftest cerebro-test/asking-agent-is-bold-across-its-columns ()
  "An agent waiting on an answer has to be findable in a list of eighteen.

The glyph alone is one character in the corner of the eye; bolding the name,
the role and the state makes the row itself the signal."
  (let* ((agent (cerebro-test--supervised 'asking nil "2026-08-14T09:00:00Z"))
         (row (nth 1 (cerebro--entry agent cerebro-test--now))))
    (dolist (column '(0 1 2))
      (let ((text (aref row column)))
        (should (memq 'bold (cerebro-test--faces-at text (1- (length text)))))))))

(ert-deftest cerebro-test/asking-row-keeps-its-glyph-colour ()
  "Bolding the name must not repaint the glyph it sits next to."
  (let* ((agent (cerebro-test--supervised 'asking nil "2026-08-14T09:00:00Z"))
         (agent-col (aref (nth 1 (cerebro--entry agent cerebro-test--now)) 0)))
    (should (memq 'warning (cerebro-test--faces-at agent-col 0)))))

(ert-deftest cerebro-test/a-row-nobody-is-waiting-on-is-not-bold ()
  "Bold has to mean something, so only `asking' gets it."
  (dolist (state '(working idle waiting dead))
    (let* ((agent (cerebro-test--supervised state nil "2026-08-14T09:00:00Z"))
           (row (nth 1 (cerebro--entry agent cerebro-test--now))))
      (dolist (column '(0 1 2))
        (let ((text (aref row column)))
          (should-not (memq 'bold (cerebro-test--faces-at text (1- (length text))))))))))

(ert-deftest cerebro-test/tab-switches-window ()
  "TAB moves between the list and the detail window, as `C-x o' does."
  (should (eq (lookup-key cerebro-mode-map (kbd "TAB")) #'cerebro-other-window))
  (should (eq (lookup-key cerebro-mode-map (kbd "<tab>")) #'cerebro-other-window)))

(ert-deftest cerebro-test/other-window-moves-the-selection ()
  (cerebro-test--with-layout list-buffer detail-window
    (let ((list-window (selected-window)))
      (cerebro-other-window)
      (should (eq (selected-window) detail-window))
      ;; And back, so one key cycles rather than stranding the navigator.
      (cerebro-other-window)
      (should (eq (selected-window) list-window)))))

;; ---------------------------------------------------------------------------
;; The bead panel

(defun cerebro-test--bead (id priority title &optional owner)
  `((id . ,id) (priority . ,priority) (title . ,title) (owner . ,owner)))

(defun cerebro-test--buckets (&rest overrides)
  "All six named buckets, with keyword OVERRIDES.

For a test that is not itself about classification - it wants to hand
`cerebro--bead-panel' or `cerebro--trigger-context' a buckets value without
restating `cerebro--partition-beads' own positional shape.  A test about
classification must still call `cerebro--partition-beads' itself."
  `((claimed . ,(plist-get overrides :claimed))
    (planned . ,(plist-get overrides :planned))
    (being-planned . ,(plist-get overrides :being-planned))
    (unplanned . ,(plist-get overrides :unplanned))
    (paused . ,(plist-get overrides :paused))
    (merged . ,(plist-get overrides :merged))))

(ert-deftest cerebro-test/bead-line-fits-the-width ()
  "A line never exceeds the panel width, however long the title."
  (let* ((bead (cerebro-test--bead "ah-7s7" 1
                                            "Psylocke, the verification session: prove merged work does what it claimed"))
         (line (cerebro--bead-line bead 62)))
    (should (<= (length line) 62))
    (should (string-match-p "ah-7s7" line))
    (should (string-match-p "P1" line))
    ;; Truncated rather than wrapped: a wrapped row would break the column.
    (should (string-suffix-p "…" line))))

(ert-deftest cerebro-test/bead-line-keeps-a-short-title-whole ()
  (let ((line (cerebro--bead-line (cerebro-test--bead "ah-t70" 0 "Fix release tagging") 62)))
    (should (string-match-p "Fix release tagging" line))
    (should-not (string-match-p "…" line))))

(ert-deftest cerebro-test/bead-line-never-shows-the-owner ()
  "bd's `owner' is who FILED the bead, not who is working on it.

It is set on every bead, so an owner column would print the same address on
every row — and the first version of this panel also filtered the unclaimed
lists by it, which emptied them completely.  That was caught by rendering
against the real database rather than here, which is why the guard is now a
test."
  (let ((line (cerebro--bead-line
               (cerebro-test--bead "ah-13o" 1 "Resizable split" "owner@example.com") 62)))
    (should-not (string-match-p "example\\.com" line))
    (should (string-match-p "Resizable split" line))))

(ert-deftest cerebro-test/beads-sort-by-priority-then-id ()
  "P0 first: the panel is read top-down when deciding what matters."
  (let* ((beads (list (cerebro-test--bead "ah-b" 2 "two")
                      (cerebro-test--bead "ah-c" 0 "zero")
                      (cerebro-test--bead "ah-a" 2 "two again")))
         (sorted (cerebro--sort-beads beads)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) sorted)
                    '("ah-c" "ah-a" "ah-b")))))

(ert-deftest cerebro-test/bead-section-counts-in-its-header ()
  "The count is the part that is read when the rows are folded off the bottom."
  (let ((lines (cerebro--bead-section "Claimed" (list (cerebro-test--bead "ah-a" 1 "one")) 62 8)))
    (should (string-match-p "\\`Claimed 1" (car lines)))))

(ert-deftest cerebro-test/bead-section-says-so-when-empty ()
  "An empty section still prints: a missing heading reads as a broken panel."
  (let ((lines (cerebro--bead-section "Planned, unclaimed" nil 62 8)))
    (should (string-match-p "\\`Planned, unclaimed 0" (car lines)))
    (should (string-match-p "none" (nth 1 lines)))))

(ert-deftest cerebro-test/bead-section-caps-and-says-how-many-it-hid ()
  "Twenty unplanned beads must not push the other sections off the window."
  (let* ((beads (mapcar (lambda (n) (cerebro-test--bead (format "ah-%02d" n) 2 "t")) (number-sequence 1 12)))
         (lines (cerebro--bead-section "Unplanned" beads 62 8)))
    (should (string-match-p "\\`Unplanned 12" (car lines)))
    ;; header + 8 beads + the overflow line
    (should (= (length lines) 10))
    (should (string-match-p "4 more" (car (last lines))))))

(ert-deftest cerebro-test/bead-panel-puts-each-list-in-its-own-section ()
  (let* ((claimed (list (cerebro-test--bead "ah-13o" 1 "held" "Cyclops")))
         (unplanned (list (cerebro-test--bead "ah-7s7" 1 "loose")))
         (merged (list (cerebro-test--bead "ah-m1" 2 "just landed")))
         (buckets (cerebro-test--buckets :claimed claimed :unplanned unplanned :merged merged))
         (text (string-join
                (cerebro--bead-panel buckets 62 8 (current-time))
                "\n"))
         (at (lambda (s) (string-match (regexp-quote s) text))))
    ;; Each bead under the heading it belongs to, not merely present somewhere.
    (should (< (funcall at "Claimed") (funcall at "ah-13o")))
    (should (< (funcall at "ah-13o") (funcall at "Planned, unclaimed")))
    (should (< (funcall at "Unplanned") (funcall at "ah-7s7")))
    (should (< (funcall at "Merged, unverified") (funcall at "ah-m1")))))

;; ---------------------------------------------------------------------------
;; ah-9dv: the non-blocking subprocess runner

(ert-deftest cerebro-test/run-async-calls-back-with-stdout ()
  "The common case: a program that runs and prints something."
  (let (got done)
    (should (eq (cerebro--run-async 'rt1 default-directory
                                     '("sh" "-c" "printf hi")
                                     (lambda (out) (setq got out done t)))
                'started))
    (with-timeout (5 (ert-fail "no callback"))
      (while (not done) (accept-process-output nil 0.05)))
    (should (equal got "hi"))
    (should-not (assq 'rt1 cerebro--inflight))))

(ert-deftest cerebro-test/run-async-calls-back-nil-on-a-non-zero-exit ()
  (let (got done)
    (cerebro--run-async 'rt2 default-directory '("sh" "-c" "exit 3")
                         (lambda (out) (setq got out done t)))
    (with-timeout (5 (ert-fail "no callback"))
      (while (not done) (accept-process-output nil 0.05)))
    (should (null got))))

(ert-deftest cerebro-test/run-async-calls-back-nil-when-the-program-is-missing ()
  "`make-process' with a program that does not exist fails synchronously -
CALLBACK still gets exactly one call, and the caller's `started' contract
still holds."
  (let (got done)
    (should (eq (cerebro--run-async 'rt3 default-directory
                                     '("cerebro-no-such-program-9dv")
                                     (lambda (out) (setq got out done t)))
                'started))
    (should done)
    (should (null got))))

(ert-deftest cerebro-test/run-async-does-not-leak-the-output-buffer-when-the-program-is-missing ()
  "The output buffer is created before `make-process' is called; when
`make-process' itself signals, that buffer must not be left behind
(PR #42 review)."
  (let ((before (length (buffer-list))))
    (cerebro--run-async 'rt7 default-directory '("cerebro-no-such-program-9dv-2") #'ignore)
    (should (= (length (buffer-list)) before))))

(ert-deftest cerebro-test/run-async-refuses-a-second-run-under-one-key ()
  "A slow `bd' is waited for rather than stacked."
  (let (proc)
    (unwind-protect
        (progn
          (should (eq (cerebro--run-async 'rt4 default-directory '("sleep" "5") #'ignore)
                      'started))
          (setq proc (cdr (assq 'rt4 cerebro--inflight)))
          (should (eq (cerebro--run-async 'rt4 default-directory '("sleep" "5") #'ignore)
                      'busy)))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (setq cerebro--inflight (assq-delete-all 'rt4 cerebro--inflight)))))

(ert-deftest cerebro-test/run-async-starts-again-when-the-recorded-run-is-dead ()
  "A key whose process is gone is free, not busy.

The guard used to ask only whether an entry existed. Nothing but the sentinel
ever removed one, and the sentinel fires only on a status change - so a process
reaped without one (a machine suspended and resumed) left the key held forever,
and every later refresh returned `busy\=' without starting anything. The fleet
view sat five hours on a bead panel stamped three minutes after it started.
`process-live-p\=', not presence: the same rule as `cerebro--session-alive-p\='."
  (let ((dead (make-process :name " *cerebro-test-dead*" :command '("true") :noquery t))
        got done)
    (unwind-protect
        (progn
          (with-timeout (3 (ert-fail "the fixture process never exited"))
            (while (process-live-p dead) (accept-process-output nil 0.05)))
          (push (cons 'rt6 dead) cerebro--inflight)
          (should (eq (cerebro--run-async 'rt6 default-directory '("echo" "hi")
                                          (lambda (out) (setq got out done t)))
                      'started))
          (with-timeout (3 (ert-fail "the replacement run never answered"))
            (while (not done) (accept-process-output nil 0.05)))
          (should (equal (string-trim (or got "")) "hi"))
          ;; And the stale entry is gone rather than shadowed by the new one.
          (should-not (assq 'rt6 cerebro--inflight)))
      (setq cerebro--inflight (assq-delete-all 'rt6 cerebro--inflight)))))

(ert-deftest cerebro-test/run-async-late-sentinel-leaves-the-run-that-replaced-it ()
  "A sentinel unregisters its OWN process, never whatever holds the key now.

Freeing a dead key means a stale process\='s sentinel can still fire afterwards,
with a live replacement already registered under that key. Deleting by key
alone would unregister the replacement and let a second run stack on it -
trading a permanent freeze for two concurrent `bd\='s."
  (let (replacement)
    (unwind-protect
        (progn
          (should (eq (cerebro--run-async 'rt7 default-directory '("true") #'ignore) 'started))
          (let ((first (cdr (assq 'rt7 cerebro--inflight))))
            (with-timeout (3 (ert-fail "the first run never exited"))
              (while (process-live-p first) (accept-process-output nil 0.05))))
          ;; A long second run takes the key while the first sentinel may still be pending.
          (should (eq (cerebro--run-async 'rt7 default-directory '("sleep" "5") #'ignore) 'started))
          (setq replacement (cdr (assq 'rt7 cerebro--inflight)))
          (should (process-live-p replacement))
          ;; Let any pending sentinel from the first run run to completion.
          (accept-process-output nil 0.2)
          (should (eq (cdr (assq 'rt7 cerebro--inflight)) replacement))
          (should (eq (cerebro--run-async 'rt7 default-directory '("true") #'ignore) 'busy)))
      (when (and replacement (process-live-p replacement)) (delete-process replacement))
      (setq cerebro--inflight (assq-delete-all 'rt7 cerebro--inflight)))))

(ert-deftest cerebro-test/run-async-kills-a-run-that-outlives-the-timeout ()
  (let ((cerebro-subprocess-timeout-seconds 0.2) got done proc)
    (cerebro--run-async 'rt5 default-directory '("sleep" "30")
                         (lambda (out) (setq got out done t)))
    (setq proc (cdr (assq 'rt5 cerebro--inflight)))
    (with-timeout (3 (ert-fail "not killed"))
      (while (not done) (accept-process-output nil 0.05)))
    (should (null got))
    (should-not (assq 'rt5 cerebro--inflight))
    (should-not (process-live-p proc))))

(ert-deftest cerebro-test/parse-json-is-nil-on-garbage-and-on-nil ()
  (should (null (cerebro--parse-json nil)))
  (should (null (cerebro--parse-json "this is not json")))
  (should (equal (cerebro--parse-json "[]") nil))
  (should (equal (alist-get 'a (car (cerebro--parse-json "[{\"a\":1}]"))) 1)))

;; ---------------------------------------------------------------------------
;; ah-9dv: the bead panel requests instead of blocking

(ert-deftest cerebro-test/request-beads-asks-bd-briefly ()
  (let (argv got linked)
    (cl-letf (((symbol-function 'cerebro--run-async)
               (lambda (_key _root a callback)
                 (setq argv a)
                 (funcall callback "[]")
                 'started)))
      (cerebro--request-beads "/repo" (lambda (beads &optional l)
                                        (setq got beads linked l))))
    (should (equal (car argv) "bd"))
    (should (equal (cadr argv) "list"))
    (should (member "--brief" argv))
    (should (member "--json" argv))
    ;; "[]" is a successful, empty answer - a named partition of nothing,
    ;; not "bd did not answer".
    (should (equal got (cerebro-test--buckets)))
    (should (null linked)))
  ;; The same call answers the linked beads: the panel partition deliberately
  ;; leaves out what is settled (`cerebro--settled-p'), and a VERIFIED is
  ;; exactly the transition Moira has to see, so it comes off the raw list
  ;; rather than out of the partition (cb-b4m).
  (let (got linked)
    (cl-letf (((symbol-function 'cerebro--run-async)
               (lambda (_key _root _argv callback)
                 (funcall callback
                          (concat "[{\"id\":\"cb-3qh\",\"status\":\"closed\","
                                  "\"external_ref\":\"gh-58\","
                                  "\"updated_at\":\"2026-08-24T12:36:41Z\"}]"))
                 'started)))
      (cerebro--request-beads "/repo" (lambda (beads &optional l)
                                        (setq got beads linked l))))
    (should got)
    (should (equal linked
                   (list (list "cb-3qh" 58
                               (cerebro-test--gh-time "2026-08-24T12:36:41Z")))))))

(ert-deftest cerebro-test/request-beads-treats-invalid-output-as-no-answer ()
  "`bd' exiting zero but printing garbage must not read as a valid empty
answer - both parse to nil, but only one of them is `bd' actually having
answered.  Reading garbage as an answer would blank the panel and silently
clear the \"bd did not answer\" indicator (PR #42 review)."
  (let (got)
    (cl-letf (((symbol-function 'cerebro--run-async)
               (lambda (_key _root _argv callback)
                 (funcall callback "this is not json")
                 'started)))
      (cerebro--request-beads "/repo" (lambda (beads &optional _l) (setq got beads))))
    (should (null got))))

(ert-deftest cerebro-test/panel-header-says-what-the-rows-date-from ()
  (should (equal (cerebro--panel-header nil nil nil) "Beads"))
  (let ((as-of 1000.0) (requested-at 2000.0) (failed-at 3000.0))
    (should (equal (cerebro--panel-header as-of nil nil)
                   (format "Beads · as of %s"
                           (format-time-string "%H:%M:%S" (seconds-to-time as-of)))))
    (should (equal (cerebro--panel-header as-of requested-at nil)
                   (format "Beads · as of %s · refreshing…"
                           (format-time-string "%H:%M:%S" (seconds-to-time as-of)))))
    (should (equal (cerebro--panel-header as-of nil failed-at)
                   (format "Beads · as of %s · bd did not answer at %s"
                           (format-time-string "%H:%M:%S" (seconds-to-time as-of))
                           (format-time-string "%H:%M:%S" (seconds-to-time failed-at)))))
    ;; Before the first answer: no "as of" clause yet.
    (should (equal (cerebro--panel-header nil requested-at nil) "Beads · refreshing…"))))

(ert-deftest cerebro-test/beads-render-keeps-the-rows-while-bd-is-out ()
  "The panel keeps showing the last answer while a fresh request is in
flight, and says so in the header."
  (let ((buffer (get-buffer-create "*cerebro-test-async-panel*"))
        stashed-callback)
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-beads)
                   (lambda (_root cb) (setq stashed-callback cb) 'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (setq cerebro--beads (cerebro-test--buckets
                                  :claimed (list (cerebro-test--bead "ah-c1" 1 "claimed one"))))
            (cerebro--beads-render buffer)
            (should (string-match-p "ah-c1" (buffer-string)))
            (should (string-match-p "refreshing…" header-line-format))
            (funcall stashed-callback
                     (cerebro-test--buckets
                      :claimed (list (cerebro-test--bead "ah-c2" 1 "different bead"))))
            (should (string-match-p "ah-c2" (buffer-string)))
            (should-not (string-match-p "ah-c1" (buffer-string)))
            (should (string-match-p "as of" header-line-format))
            (should-not (string-match-p "refreshing…" header-line-format))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/beads-render-keeps-the-last-rows-when-bd-does-not-answer ()
  "A `bd' that never answers must not blank a panel that had something to show."
  (let ((buffer (get-buffer-create "*cerebro-test-async-panel-fail*"))
        stashed-callback)
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-beads)
                   (lambda (_root cb) (setq stashed-callback cb) 'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (setq cerebro--beads (cerebro-test--buckets
                                  :claimed (list (cerebro-test--bead "ah-c1" 1 "claimed one"))))
            (cerebro--beads-render buffer)
            (funcall stashed-callback nil)
            (should (string-match-p "ah-c1" (buffer-string)))
            (should (string-match-p "bd did not answer at" header-line-format))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/beads-render-does-not-stack-requests ()
  "A request already out is left to finish rather than joined by a second -
`busy' must not clobber the timestamp of the request that is still out."
  (let ((buffer (get-buffer-create "*cerebro-test-async-panel-busy*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-beads)
                   (lambda (_root _cb) 'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (cerebro--beads-render buffer)
            (should (numberp cerebro--beads-requested-at))
            (let ((first-requested-at cerebro--beads-requested-at))
              (cl-letf (((symbol-function 'cerebro--request-beads)
                         (lambda (_root _cb) 'busy)))
                (cerebro--beads-render buffer))
              (should (= cerebro--beads-requested-at first-requested-at)))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/layout-puts-the-panel-under-the-list ()
  (let ((fleet (generate-new-buffer " *cerebro-test-fleet*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-beads)
                   (lambda (_root cb) (funcall cb (cerebro-test--buckets)) 'started))
                  ((symbol-function 'cerebro--request-sweeps)
                   (lambda (_root cb) (funcall cb (list nil)) 'started)))
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) fleet)
            (with-current-buffer fleet
              (cerebro--setup-layout)
              (should (window-live-p cerebro--beads-window))
              (should (equal (buffer-name (window-buffer cerebro--beads-window))
                              cerebro-beads-buffer-name))
              ;; Under the list, not beside it.
              (should (= (window-left-column cerebro--beads-window)
                          (window-left-column cerebro--list-window)))
              (should (> (window-top-line cerebro--beads-window)
                          (window-top-line cerebro--list-window)))
              ;; And the detail window still stands to the right of both.
              (should (> (window-left-column cerebro--detail-window)
                          (window-left-column cerebro--list-window))))))
      (when (get-buffer cerebro-beads-buffer-name)
        (kill-buffer cerebro-beads-buffer-name))
      (kill-buffer fleet))))

(ert-deftest cerebro-test/setup-layout-redraws-a-panel-that-already-existed ()
  "`cerebro--beads-buffer' only renders on its own first creation - a panel
that survived a fleet buffer kill-and-reopen must still be redrawn by
`cerebro--setup-layout' rather than left showing whatever it last did."
  (let ((fleet (generate-new-buffer " *cerebro-test-fleet-relayout*"))
        (render-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-sweeps)
                   (lambda (_root cb) (funcall cb (list nil)) 'started))
                  ((symbol-function 'cerebro--beads-render)
                   (lambda (_buffer) (cl-incf render-calls))))
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) fleet)
            (with-current-buffer fleet
              ;; First layout creates the panel - one render, from
              ;; `cerebro--beads-buffer's own immediate sweep.
              (cerebro--setup-layout)
              (should (= render-calls 1))
              ;; Force a second layout pass, as a fresh `M-x cerebro' does
              ;; when the fleet buffer was killed and reopened but the panel
              ;; buffer survived.
              (setq cerebro--list-window nil)
              (cerebro--setup-layout)
              (should (= render-calls 2)))))
      (when (get-buffer cerebro-beads-buffer-name)
        (kill-buffer cerebro-beads-buffer-name))
      (kill-buffer fleet))))

;; ---------------------------------------------------------------------------
;; TAB cycles from wherever the navigator is

(ert-deftest cerebro-test/tab-is-bound-in-every-window-of-the-layout ()
  "One key, three windows. Bound where the navigator might be standing."
  (dolist (map (list cerebro-mode-map cerebro-beads-mode-map cerebro-session-mode-map))
    (should (eq (lookup-key map (kbd "TAB")) #'cerebro-other-window))
    (should (eq (lookup-key map (kbd "<tab>")) #'cerebro-other-window))))

(ert-deftest cerebro-test/tab-cycles-list-beads-detail-and-round ()
  "The order the navigator reads in, and back to the top rather than stopping."
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
            ((symbol-function 'cerebro--request-beads)
             (lambda (_root cb) (funcall cb (cerebro-test--buckets)) 'started))
            ((symbol-function 'cerebro--request-sweeps)
             (lambda (_root cb) (funcall cb (list nil)) 'started)))
    (let ((fleet (generate-new-buffer " *cerebro-test-fleet*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) fleet)
            ;; The window variables are buffer-local to the fleet buffer, so
            ;; they have to be read before cycling moves the current buffer
            ;; out from under them.
            (let (list-window beads-window detail-window)
              (with-current-buffer fleet
                (cerebro--setup-layout)
                (setq list-window cerebro--list-window
                      beads-window cerebro--beads-window
                      detail-window cerebro--detail-window))
              (select-window list-window)
              (cerebro-other-window)
              (should (eq (selected-window) beads-window))
              (cerebro-other-window)
              (should (eq (selected-window) detail-window))
              ;; Round, not stuck at the right-hand edge.
              (cerebro-other-window)
              (should (eq (selected-window) list-window))))
        (when (get-buffer cerebro-beads-buffer-name)
          (kill-buffer cerebro-beads-buffer-name))
        (kill-buffer fleet)))))

(ert-deftest cerebro-test/session-buffers-take-tab-back-from-vterm ()
  "vterm binds TAB in its own major-mode map, so this has to outrank it.

A minor mode does; editing `vterm-mode-map' would have taken TAB from every
vterm the navigator has, fleet or not."
  (let ((buffer (generate-new-buffer " *cerebro-test-session*")))
    (unwind-protect
        (with-current-buffer buffer
          (cerebro-session-mode 1)
          ;; `minor-mode-map-alist' is keyed by the mode, and the binding it
          ;; produces is what actually matters.
          (should (memq 'cerebro-session-mode (mapcar #'car minor-mode-map-alist)))
          (should (eq (key-binding (kbd "TAB")) #'cerebro-other-window)))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/a-real-tab-can-still-reach-the-agent ()
  "Taking TAB from a live session has to leave a way to send one."
  (should (eq (lookup-key cerebro-session-mode-map (kbd "C-c TAB")) #'cerebro-send-tab)))

(ert-deftest cerebro-test/placeholder-buffers-cycle-too ()
  "A dead agent's placeholder sits in the same window and must not trap TAB."
  (let* ((agent (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead))
         (buffer (cerebro--placeholder-buffer agent)))
    (unwind-protect
        (with-current-buffer buffer
          (should cerebro-session-mode))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/a-launched-session-cycles-with-tab ()
  "The rightmost window is where TAB was reported dead, so enter through launch.

Removing the `cerebro-session-mode' call in `cerebro--launch' failed no test
at all before this one existed - the placeholder was covered and the live
session, which is the case the navigator actually hits, was not."
  (let* ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require)))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                    ((symbol-function 'require)
                     (lambda (feature &rest args)
                       (or (eq feature 'vterm) (apply orig-require feature args))))
                    ((symbol-function 'vterm-mode)
                     (lambda ()
                       ;; vterm owns TAB in its major-mode map; stand in for that.
                       (use-local-map (let ((m (make-sparse-keymap)))
                                        (define-key m (kbd "TAB") #'ignore)
                                        m)))))
            (cerebro--launch agent)
            (with-current-buffer session-name
              (should cerebro-session-mode)
              (should (eq (key-binding (kbd "TAB")) #'cerebro-other-window))
              (should (eq (key-binding (kbd "C-c TAB")) #'cerebro-send-tab)))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

;; ---------------------------------------------------------------------------
;; Navigating the bead panel

(defmacro cerebro-test--with-panel (buffer &rest body)
  "Render a panel of known beads into BUFFER and run BODY there."
  (declare (indent 1))
  `(let ((,buffer (get-buffer-create "*cerebro-test-beads*")))
     (unwind-protect
         (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                   ((symbol-function 'cerebro--request-beads)
                    (lambda (_root cb)
                      (funcall cb
                               (cerebro-test--buckets
                                :claimed (list (cerebro-test--bead "ah-c1" 1 "claimed one"))
                                :planned (list (cerebro-test--bead "ah-p1" 0 "planned one"))
                                :unplanned (list (cerebro-test--bead "ah-u1" 1 "unplanned one")
                                                  (cerebro-test--bead "ah-u2" 2 "unplanned two"))))
                      'started)))
           (with-current-buffer ,buffer
             (cerebro-beads-mode)
             (cerebro--beads-render ,buffer)
             ,@body))
       (kill-buffer ,buffer))))

(ert-deftest cerebro-test/bead-rows-carry-their-id ()
  "The row knows which bead it is, so navigation and selection are about
beads rather than about line numbers."
  (cerebro-test--with-panel buffer
    (goto-char (point-min))
    (should (null (cerebro--bead-at-point)))     ; the "Claimed 1" header
    (forward-line 1)
    (should (equal (cerebro--bead-at-point) "ah-c1"))))

(ert-deftest cerebro-test/navigation-skips-everything-that-is-not-a-bead ()
  "Headers, blank lines and \"(none)\" are scenery: `n' steps over them."
  (cerebro-test--with-panel buffer
    (goto-char (point-min))
    (cerebro-beads-next)
    (should (equal (cerebro--bead-at-point) "ah-c1"))
    (cerebro-beads-next)
    ;; Straight across the blank line and the "Planned, unclaimed" header.
    (should (equal (cerebro--bead-at-point) "ah-p1"))
    (cerebro-beads-next)
    (should (equal (cerebro--bead-at-point) "ah-u1"))
    (cerebro-beads-next)
    (should (equal (cerebro--bead-at-point) "ah-u2"))))

(ert-deftest cerebro-test/navigation-stops-at-the-ends ()
  "No wrap: a list that jumps to the top when you hold `n' hides its own end."
  (cerebro-test--with-panel buffer
    ;; Down to the last bead, then keep pressing.
    (dotimes (_ 6) (cerebro-beads-next))
    (should (equal (cerebro--bead-at-point) "ah-u2"))
    (cerebro-beads-next)
    (should (equal (cerebro--bead-at-point) "ah-u2"))
    ;; And back up past the top.
    (dotimes (_ 6) (cerebro-beads-previous))
    (should (equal (cerebro--bead-at-point) "ah-c1"))
    (cerebro-beads-previous)
    (should (equal (cerebro--bead-at-point) "ah-c1"))))

(ert-deftest cerebro-test/a-bead-is-marked-from-the-first-render ()
  "Point starts on a bead rather than on the header above it, and the mark is
the cursor alone - no hl-line background (ah-4xl)."
  (cerebro-test--with-panel buffer
    (should (equal (cerebro--bead-at-point) "ah-c1"))
    (should-not (bound-and-true-p hl-line-mode))))

(ert-deftest cerebro-test/the-selected-bead-survives-a-refresh ()
  "The panel redraws on a timer; the selection has to follow the bead.

Restoring by buffer position would move the mark to whatever row happened to
land on that line when the queue changed underneath."
  (cerebro-test--with-panel buffer
    ;; The render already marked the first bead, so one step reaches ah-p1.
    (cerebro-beads-next)
    (should (equal (cerebro--bead-at-point) "ah-p1"))
    ;; A bead lands above it and the rows all shift down one.
    (cl-letf (((symbol-function 'cerebro--request-beads)
               (lambda (_root cb)
                 (funcall cb
                          (cerebro-test--buckets
                           :claimed (list (cerebro-test--bead "ah-c0" 0 "new claim")
                                          (cerebro-test--bead "ah-c1" 1 "claimed one"))
                           :planned (list (cerebro-test--bead "ah-p1" 0 "planned one"))))
                 'started)))
      (cerebro--beads-render buffer)
      (should (equal (cerebro--bead-at-point) "ah-p1")))))

(ert-deftest cerebro-test/a-vanished-bead-does-not-strand-the-mark ()
  "Merged and closed while selected: fall back to the first row, not to nowhere."
  (cerebro-test--with-panel buffer
    (should (equal (cerebro--bead-at-point) "ah-c1"))
    (cl-letf (((symbol-function 'cerebro--request-beads)
               (lambda (_root cb)
                 (funcall cb (cerebro-test--buckets
                              :unplanned (list (cerebro-test--bead "ah-u1" 1 "left"))))
                 'started)))
      (cerebro--beads-render buffer)
      (should (equal (cerebro--bead-at-point) "ah-u1")))))

(ert-deftest cerebro-test/beads-keymap-navigates ()
  (should (eq (lookup-key cerebro-beads-mode-map "n") #'cerebro-beads-next))
  (should (eq (lookup-key cerebro-beads-mode-map "p") #'cerebro-beads-previous))
  (should (eq (lookup-key cerebro-beads-mode-map (kbd "<down>")) #'cerebro-beads-next))
  (should (eq (lookup-key cerebro-beads-mode-map (kbd "<up>")) #'cerebro-beads-previous)))

(ert-deftest cerebro-test/panel-width-does-not-borrow-another-window ()
  "`window-width' with no window means the SELECTED window.

The panel refreshes on a timer, so that would lay it out to the width of
whatever the navigator was standing in - usually the detail window."
  (let ((buffer (generate-new-buffer " *cerebro-test-width*")))
    (unwind-protect
        (should (= (cerebro--panel-width buffer) cerebro-list-width))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/the-mark-lands-in-the-window-not-just-the-buffer ()
  "A window keeps its own point when its buffer is not the selected one.

`goto-char' in `with-current-buffer' moves the buffer's point; the window
showing it kept pointing at line 1, so with an empty Claimed section the
navigator saw the mark sitting on \"Claimed 0\". Both the layout and the
timer render from another window, so this is the normal path, not an edge."
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
            ((symbol-function 'cerebro--request-beads)
             (lambda (_root cb)
               (funcall cb (cerebro-test--buckets
                            :unplanned (list (cerebro-test--bead "ah-u1" 1 "first real bead"))))
               'started)))
    (let ((buffer (get-buffer-create "*cerebro-test-window-point*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer (cerebro-beads-mode))
            (cerebro-test--shown-elsewhere buffer window
              ;; Rendered from the other window, exactly as the timer does.
              (cerebro--beads-render buffer)
              (with-current-buffer buffer
                (save-excursion
                  (goto-char (window-point window))
                  (should (equal (cerebro--bead-at-point) "ah-u1"))))))
        (kill-buffer buffer)))))

;; ---------------------------------------------------------------------------
;; RET on a bead shows it in the detail window

(ert-deftest cerebro-test/ret-is-bound-in-the-panel ()
  (should (eq (lookup-key cerebro-beads-mode-map (kbd "RET")) #'cerebro-beads-show)))

(ert-deftest cerebro-test/bead-detail-window-cycles-with-tab ()
  "It sits in the detail window, so TAB has to keep working from it."
  (should (eq (lookup-key cerebro-bead-mode-map (kbd "TAB")) #'cerebro-other-window))
  (should (eq (lookup-key cerebro-bead-mode-map (kbd "<tab>")) #'cerebro-other-window)))

(ert-deftest cerebro-test/ret-on-a-header-says-so-rather-than-guessing ()
  "The panel has more scenery than beads; RET on it must not show something else."
  (cerebro-test--with-panel buffer
    (goto-char (point-min))                       ; the "Claimed 1" header
    (should-error (cerebro-beads-show) :type 'user-error)))

(ert-deftest cerebro-test/ret-shows-the-bead-in-the-detail-window ()
  (cerebro-test--with-panel panel
    (let ((shown nil)
          (detail (selected-window)))
      (cl-letf (((symbol-function 'cerebro--bd-text)
                 (lambda (_root id) (setq shown id) (format "○ %s · a bead\n\nDESCRIPTION\n" id)))
                ((symbol-function 'cerebro--layout-detail-window) (lambda () detail)))
        (should (equal (cerebro--bead-at-point) "ah-c1"))
        (cerebro-beads-show)
        ;; Asked bd about the marked bead, and nothing else.
        (should (equal shown "ah-c1"))
        (let ((buffer (get-buffer cerebro-bead-buffer-name)))
          (should buffer)
          (should (eq (window-buffer detail) buffer))
          (with-current-buffer buffer
            (should (string-match-p "ah-c1" (buffer-string)))
            (should (derived-mode-p 'cerebro-bead-mode))
            ;; Read-only: this is a view of a bead, not a way to edit one.
            (should buffer-read-only))
          (kill-buffer buffer))))))

(ert-deftest cerebro-test/a-bead-that-bd-cannot-show-says-so ()
  "Silence would read as a broken key rather than as a missing bead."
  (cerebro-test--with-panel panel
    (let ((detail (selected-window)))
      (cl-letf (((symbol-function 'cerebro--bd-text) (lambda (_root _id) nil))
                ((symbol-function 'cerebro--layout-detail-window) (lambda () detail)))
        (cerebro-beads-show)
        (with-current-buffer cerebro-bead-buffer-name
          (should (string-match-p "ah-c1" (buffer-string)))
          (should (string-match-p "could not" (downcase (buffer-string)))))
        (kill-buffer cerebro-bead-buffer-name)))))

;; ---------------------------------------------------------------------------
;; Re-prioritising the marked bead

(defmacro cerebro-test--with-bd (calls &rest body)
  "Run BODY with `bd update' recorded into CALLS instead of run, succeeding."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'cerebro--bd-set-priority)
              (lambda (_root id priority) (push (cons id priority) ,calls) t))
             ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
     ,@body))

(ert-deftest cerebro-test/bead-rows-carry-their-priority ()
  "The row knows its own priority, so `+' does not have to re-parse the text."
  (cerebro-test--with-panel buffer
    (should (equal (cerebro--priority-at-point) 1))))

(ert-deftest cerebro-test/nudging-clamps-at-both-ends ()
  "P0 is as urgent as it goes and P4 is the backlog floor."
  (should (= (cerebro--nudged-priority 1 -1) 0))
  (should (= (cerebro--nudged-priority 0 -1) 0))
  (should (= (cerebro--nudged-priority 3 1) 4))
  (should (= (cerebro--nudged-priority 4 1) 4)))

(ert-deftest cerebro-test/setting-a-priority-asks-bd-and-redraws ()
  (cerebro-test--with-panel buffer
    (let (calls)
      (cerebro-test--with-bd calls
        (cerebro-beads-set-priority 0)
        (should (equal calls '(("ah-c1" . 0))))
        ;; The mark stays on the bead it was on, wherever the redraw puts it.
        (should (equal (cerebro--bead-at-point) "ah-c1"))))))

(ert-deftest cerebro-test/setting-the-priority-it-already-has-does-nothing ()
  "No write, no undo entry: a keypress that changes nothing must not look
like one that did."
  (cerebro-test--with-panel buffer
    (let (calls)
      (cerebro-test--with-bd calls
        (cerebro-beads-set-priority 1)          ; ah-c1 is already P1
        (should (null calls))
        (should (null cerebro--last-priority-change))))))

(ert-deftest cerebro-test/priority-on-a-header-line-is-refused ()
  (cerebro-test--with-panel buffer
    (goto-char (point-min))
    (should-error (cerebro-beads-set-priority 0) :type 'user-error)))

(ert-deftest cerebro-test/a-failed-update-is-not-silent-and-is-not-undoable ()
  "bd can refuse - a lock, a closed bead - and the panel must not claim it worked."
  (cerebro-test--with-panel buffer
    (cl-letf (((symbol-function 'cerebro--bd-set-priority) (lambda (&rest _) nil))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
      (should-error (cerebro-beads-set-priority 0) :type 'user-error)
      (should (null cerebro--last-priority-change)))))

(ert-deftest cerebro-test/undo-puts-the-priority-back-once ()
  "One step, because a mis-key is the case it exists for."
  (cerebro-test--with-panel buffer
    (let (calls)
      (cerebro-test--with-bd calls
        (cerebro-beads-set-priority 4)
        (should (equal cerebro--last-priority-change '("ah-c1" . 1)))
        (cerebro-beads-undo-priority)
        (should (equal (car calls) '("ah-c1" . 1)))
        ;; Spent: a second undo has nothing to put back.
        (should (null cerebro--last-priority-change))
        (should-error (cerebro-beads-undo-priority) :type 'user-error)))))

(ert-deftest cerebro-test/priority-keys-are-bound ()
  "Each digit sets its own number.

The bindings are closures made in a loop, which is the classic way to end up
with five keys that all set the last value - `commandp' alone would not have
noticed."
  (let (asked)
    (cl-letf (((symbol-function 'cerebro-beads-set-priority)
               (lambda (priority) (push priority asked))))
      (dolist (digit '("0" "1" "2" "3" "4"))
        (let ((command (lookup-key cerebro-beads-mode-map digit)))
          (should (commandp command))
          (call-interactively command))))
    (should (equal (reverse asked) '(0 1 2 3 4))))
  (should (eq (lookup-key cerebro-beads-mode-map "+") #'cerebro-beads-raise))
  (should (eq (lookup-key cerebro-beads-mode-map "-") #'cerebro-beads-lower))
  (should (eq (lookup-key cerebro-beads-mode-map "u") #'cerebro-beads-undo-priority)))

(ert-deftest cerebro-test/nudging-moves-one-step-from-where-the-bead-is ()
  (cerebro-test--with-panel buffer
    (let (calls)
      (cerebro-test--with-bd calls
        (cerebro-beads-raise)                   ; ah-c1 is P1, raise is more urgent
        (should (equal (car calls) '("ah-c1" . 0)))))))

;; ---------------------------------------------------------------------------
;; What merged, and what has been verified

(defun cerebro-test--closed (id title labels updated)
  `((id . ,id) (priority . 2) (title . ,title) (labels . ,labels) (updated_at . ,updated)))

(ert-deftest cerebro-test/panel-sections-follow-the-lifecycle ()
  "Claimed, planned, being planned, unplanned, merged - as far as the panel
follows work, and in the order it moves in read backwards.  BUCKETS is
shuffled and carries an extra key nothing reads, to pin that the panel's
visible order comes from the explicit `cerebro--bead-section' sequence in
`cerebro--bead-panel', never from the association list's own order
\(ah-vcof\)."
  (let* ((buckets '((merged . nil) (future . nil) (paused . nil) (unplanned . nil)
                    (being-planned . nil) (claimed . nil) (planned . nil)))
         (text (string-join
                (cerebro--bead-panel buckets 62 8 (current-time)) "\n"))
         (at (lambda (s) (string-match (regexp-quote s) text))))
    (should (< (funcall at "Claimed") (funcall at "Planned, unclaimed")))
    (should (< (funcall at "Planned, unclaimed") (funcall at "Being planned")))
    (should (< (funcall at "Being planned") (funcall at "Unplanned")))
    (should (< (funcall at "Unplanned") (funcall at "Waiting on you")))
    (should (< (funcall at "Waiting on you") (funcall at "Merged, unverified")))))

(ert-deftest cerebro-test/the-panel-stops-at-merged ()
  "The panel shows work the fleet can act on, and drops the rest.

Not everything needs a home here: verified work is finished, epics are
parents rather than work, bd's `event' records are its own bookkeeping, and
blocked or deferred beads cannot be picked up.  They are left out rather
than filed somewhere nobody reads."
  (let ((text (string-join
               (cerebro--bead-panel (cerebro--partition-beads cerebro-test--every-shape)
                                    62 8 (current-time))
               "\n")))
    ;; Case-sensitively: "Merged, unverified" contains "verified", and
    ;; `string-match-p' folds case by default.
    (let ((case-fold-search nil))
      (should-not (string-match-p "Verified" text))
      (should-not (string-match-p "Other" text)))
    (dolist (id '("closed-passed" "closed-not-needed" "epic" "event"
                  "blocked" "deferred" "from-the-future"))
      (should-not (string-match-p (regexp-quote id) text)))
    ;; What the panel is for is still all there.
    (dolist (id '("in-progress" "open-planned" "open-loose" "closed-bare"))
      (should (string-match-p (regexp-quote id) text)))))

(ert-deftest cerebro-test/closed-beads-sort-newest-first ()
  "Priority says nothing about finished work; recency says what just happened."
  (let* ((beads (list (cerebro-test--closed "ah-old" "older" nil "2026-08-01T09:00:00Z")
                      (cerebro-test--closed "ah-new" "newer" nil "2026-08-14T09:00:00Z")))
         (sorted (cerebro--sort-recent beads)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) sorted) '("ah-new" "ah-old")))))

(ert-deftest cerebro-test/a-reopened-bead-is-marked-where-it-lands ()
  "A failed verdict sends a bead back to the unclaimed pile at P0.

It is an ordinary open bead there - which is the point - but the row says it
has been round once, because that is the difference between new work and
work that came back."
  (let ((reopened (cerebro--bead-line
                   `((id . "ah-t65") (priority . 0) (title . "same title")
                     (labels . ("verification:failed")))
                   62))
        ;; Same id length and same title, so any difference in width is the
        ;; marker and not the text.
        (fresh (cerebro--bead-line
                '((id . "ah-t70") (priority . 0) (title . "same title")) 62)))
    (should (string-match-p "↻" reopened))
    (should-not (string-match-p "↻" fresh))
    ;; Still the same width, so the column does not shift under one row.
    (should (= (length reopened) (length fresh)))))

;; ---------------------------------------------------------------------------
;; Every bead lands somewhere

(defun cerebro-test--any (id status &optional labels type)
  `((id . ,id) (status . ,status) (priority . 2) (title . ,id)
    (labels . ,labels) (issue_type . ,(or type "task"))
    (updated_at . "2026-08-14T09:00:00Z")))

(defconst cerebro-test--every-shape
  (list (cerebro-test--any "in-progress" "in_progress")
        (cerebro-test--any "open-planned" "open" '("planned"))
        (cerebro-test--any "open-planning" "open" '("planning"))
        (cerebro-test--any "open-loose" "open")
        (cerebro-test--any "closed-bare" "closed")
        (cerebro-test--any "closed-failed" "closed" '("verification:failed"))
        (cerebro-test--any "closed-passed" "closed" '("verification:passed"))
        (cerebro-test--any "closed-not-needed" "closed" '("verification:not-needed"))
        (cerebro-test--any "blocked" "blocked")
        (cerebro-test--any "deferred" "deferred")
        (cerebro-test--any "epic" "open" nil "epic")
        ;; bd's own audit record of a state change, and it carries the label
        ;; of the change it records - so it lands in Verified unless the type
        ;; is checked first.
        (cerebro-test--any "event" "closed" '("verification:passed") "event")
        (cerebro-test--any "from-the-future" "sideways"))
  "One bead of every shape bd can produce, plus a status it cannot.")

(ert-deftest cerebro-test/each-shape-lands-where-it-belongs ()
  "Five buckets, and everything else deliberately in none of them."
  (let* ((buckets (cerebro--partition-beads cerebro-test--every-shape))
         (ids (lambda (key) (mapcar (lambda (b) (alist-get 'id b)) (alist-get key buckets)))))
    (should (= 6 (length buckets)))
    (should (equal (funcall ids 'claimed) '("in-progress")))
    (should (equal (funcall ids 'planned) '("open-planned")))
    (should (equal (funcall ids 'being-planned) '("open-planning")))
    (should (equal (funcall ids 'unplanned) '("open-loose")))
    ;; Merged is what still wants verifying: bare, or failed and rebuilt.
    (should-not (funcall ids 'paused))
    (should (equal (sort (funcall ids 'merged) #'string<) '("closed-bare" "closed-failed")))
    ;; And nothing else got in anywhere: verified work, epics, bd's own event
    ;; records, blocked, deferred, and a status from a future bd.
    (should (= 6 (length (apply #'append (mapcar #'cdr buckets)))))))

(ert-deftest cerebro-test/partition-beads-names-every-bucket ()
  "The producer's contract is a named association list, not a positional one
\(ah-vcof\): all six keys are always present, even when several buckets are
empty, and each bead shape lands under the key its status and labels say it
should - the same classification `cerebro-test/each-shape-lands-where-it-
belongs' pins, read here by name instead of by position."
  (let ((buckets (cerebro--partition-beads cerebro-test--every-shape)))
    (should (equal (mapcar #'car buckets)
                   '(claimed planned being-planned unplanned paused merged)))
    (dolist (key '(claimed planned being-planned unplanned paused merged))
      ;; Every key is present - `alist-get' with a default distinguishes an
      ;; absent key from one whose bucket is merely empty.
      (should-not (eq (alist-get key buckets 'cerebro-test--missing) 'cerebro-test--missing)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'claimed buckets))
                   '("in-progress")))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'planned buckets))
                   '("open-planned")))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'being-planned buckets))
                   '("open-planning")))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'unplanned buckets))
                   '("open-loose")))
    (should-not (alist-get 'paused buckets))
    (should (equal (sort (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'merged buckets))
                         #'string<)
                   '("closed-bare" "closed-failed")))))

;; ---------------------------------------------------------------------------
;; What the planners are holding (ah-2p.2)

(ert-deftest cerebro-test/a-bead-being-planned-has-its-own-bucket ()
  "`planning' is a planner holding a candidate. It is not pickable work, so it
cannot sit in Unplanned - where it reads as something nobody has started - and
it must not sit in Planned, unclaimed, which is what an idle implementer can
take right now."
  (let* ((beads (list (cerebro-test--any "being-planned" "open" '("planning"))))
         (buckets (cerebro--partition-beads beads)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'being-planned buckets))
                   '("being-planned")))
    (should-not (alist-get 'planned buckets))
    (should-not (alist-get 'unplanned buckets))))

(ert-deftest cerebro-test/planned-wins-over-planning-when-a-bead-carries-both ()
  "The two labels overlap for one `bd update' - `--add-label planned
--remove-label planning' is a single call, but a torn read mid-write, or a
planner that forgot the removal, leaves both. Pickable wins: an implementer
can claim it, whatever else the bead says."
  (let* ((beads (list (cerebro-test--any "both" "open" '("planning" "planned"))))
         (buckets (cerebro--partition-beads beads)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'planned buckets)) '("both")))
    (should-not (alist-get 'being-planned buckets))))

(ert-deftest cerebro-test/a-named-planning-label-is-being-planned ()
  "A planner names its hold - `planning:<its own name>' - so a finishing
session cannot strip a label it did not set. The panel has to recognise the
hold whoever holds it, or Being planned silently empties: nothing errors, the
membership test simply stops matching."
  (let* ((beads (list (cerebro-test--any "held" "open" '("planning:Xavier"))))
         (buckets (cerebro--partition-beads beads)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'being-planned buckets))
                   '("held")))
    (should-not (alist-get 'planned buckets))
    (should-not (alist-get 'unplanned buckets))))

(ert-deftest cerebro-test/a-bare-planning-label-is-still-being-planned ()
  "The bare spelling is not dropped. Sessions started before the named one
existed keep writing it, and the panel watches both at once."
  (let* ((beads (list (cerebro-test--any "bare" "open" '("planning"))))
         (buckets (cerebro--partition-beads beads)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'being-planned buckets))
                   '("bare")))))

(ert-deftest cerebro-test/a-label-that-merely-starts-with-the-word-is-not-a-hold ()
  "A hold is the word, or the word and a `:' and a name - never a bare prefix.
`planning-notes' is the near miss that says so: it starts with every letter of
the holding label and is still not somebody holding the bead. `planner:<name>'
names who plans a family rather than who holds one bead, and is not a hold
either; `planned' stays an exact match, so `planned-ish' is not pickable work.

Without the separator each of these would read as a planner holding the bead,
and it would vanish from the backlog with nobody thinking to look past."
  (let* ((beads (list (cerebro-test--any "notes" "open" '("planning-notes"))
                      (cerebro-test--any "owned" "open" '("planner:Xavier"))
                      (cerebro-test--any "nearly" "open" '("planned-ish"))))
         (buckets (cerebro--partition-beads beads)))
    (should-not (alist-get 'planned buckets))
    (should-not (alist-get 'being-planned buckets))
    (should (equal (sort (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'unplanned buckets))
                         #'string<)
                   '("nearly" "notes" "owned")))))

(ert-deftest cerebro-test/a-named-hold-is-recognised-whoever-holds-it ()
  "Every planner's hold counts, not one hard-coded name, and the panel keeps
them together in the one section - which is the whole point of reading the
label by its prefix rather than matching a string."
  (let* ((beads (list (cerebro-test--any "x" "open" '("planning:Xavier"))
                      (cerebro-test--any "b" "open" '("planning:Beast"))
                      (cerebro-test--any "old" "open" '("planning"))))
         (buckets (cerebro--partition-beads beads)))
    (should (equal (sort (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'being-planned buckets))
                         #'string<)
                   '("b" "old" "x")))
    (should-not (alist-get 'unplanned buckets))))

;; ---------------------------------------------------------------------------
;; Parked for the navigator (cb-wfb): the sixth bucket and the section it draws

(defun cerebro-test--paused (id &optional labels paused-at)
  "An open bead carrying `human', and whatever else LABELS names.
PAUSED-AT, when given, is the ISO-8601 string the pause site wrote."
  `((id . ,id) (status . "open") (priority . 2) (title . ,id)
    (labels . ,(cons "human" labels)) (issue_type . "task")
    (updated_at . "2026-08-14T09:00:00Z")
    ,@(when paused-at `((metadata . ((paused_at . ,paused-at)))))))

(ert-deftest cerebro-test/paused-beads-leave-unplanned ()
  "A bead parked for the navigator is not work nobody has started. Under
Unplanned it is indistinguishable from the backlog, which is exactly how a
pause outlives its reason with nobody counting it."
  (let* ((beads (list (cerebro-test--paused "cb-aaa")))
         (buckets (cerebro--partition-beads beads)))
    (should (= 6 (length buckets)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'paused buckets))
                   '("cb-aaa")))
    (should-not (alist-get 'unplanned buckets))))

(ert-deftest cerebro-test/paused-beads-win-over-planned ()
  "A planner parking a question adds `human' without removing `planned', and
the implementers' own pickup is `bd ready --label planned --exclude-label
human' - so such a bead is NOT claimable. Under Planned, unclaimed it would
report queue depth that does not exist."
  (let* ((beads (list (cerebro-test--paused "cb-bbb" '("planned"))))
         (buckets (cerebro--partition-beads beads)))
    (should (equal (mapcar (lambda (b) (alist-get 'id b)) (alist-get 'paused buckets))
                   '("cb-bbb")))
    (should-not (alist-get 'planned buckets))))

(ert-deftest cerebro-test/paused-section-renders-with-age ()
  "The section says how long each bead has been waiting, in the one elapsed
spelling the rest of the view uses - and an unknown pause time reads as an em
dash rather than as a small number."
  (let* ((now (encode-time (iso8601-parse "2026-08-31T00:00:00Z")))
         (paused (list (cerebro-test--paused "cb-aaa" nil "2026-08-30T20:00:00Z")
                       (cerebro-test--paused "cb-ccc")))
         (text (string-join (cerebro--bead-panel (cerebro-test--buckets :paused paused)
                                                  62 8 now)
                            "\n")))
    (should (string-match-p "Waiting on you 2" text))
    (should (string-match-p "cb-aaa" text))
    (should (string-match-p "4h00" text))
    (should (string-match-p "—" text))))

(ert-deftest cerebro-test/paused-section-empty-prints-none ()
  "Empty on nearly every render, and it still says so: a standing `Waiting on
you 0' is the reassurance the navigator asked for, unlike Sweeps, which
disappears."
  (let ((text (string-join
               (cerebro--bead-panel (cerebro-test--buckets) 62 8 (current-time))
               "\n")))
    (should (string-match-p "Waiting on you 0" text))
    (should (string-match-p "(none)" text))))

(ert-deftest cerebro-test/being-planned-renders-its-beads-and-its-count ()
  (let* ((being (list (cerebro-test--any "ah-1" "open" '("planning"))
                      (cerebro-test--any "ah-2" "open" '("planning"))))
         (text (string-join
                (cerebro--bead-panel (cerebro-test--buckets :being-planned being) 62 8 (current-time))
                "\n")))
    (should (string-match-p "Being planned 2" text))
    (should (string-match-p "ah-1" text))
    (should (string-match-p "ah-2" text))))

(ert-deftest cerebro-test/bd-list-argv-covers-every-status-briefly ()
  "Five statuses in one call: the partition can only be complete if the
list it partitions is. `--brief' drops the free-form text nothing here
renders.  A function rather than a constant since ah-qled.9, so that a
changed `cerebro-bd-program' reaches it."
  (let ((argv (cerebro--bd-list-argv)))
    (dolist (status '("open" "in_progress" "blocked" "deferred" "closed"))
      (should (cl-some (lambda (a) (string-match-p status a)) argv)))
    ;; No type exclusion: an epic has to land in Other, not vanish.
    (should-not (member "--exclude-type" argv))
    (should (member "--brief" argv))
    (should (member "--json" argv))
    (should (equal (car argv) "bd"))
    (should (equal (nth 1 argv) "list"))))

(ert-deftest cerebro-test/the-panel-skips-exactly-what-work-beads-excludes ()
  "The two owners of \"which issue types are not work\" cannot drift apart.
`scripts/work-beads' is the shell-side one; `cerebro-skipped-issue-types'
is this one.  Run as CI runs ERT, from the repository root."
  ;; Absolute, because `process-lines' searches `exec-path' rather than
  ;; `default-directory' - a relative name here reads as "no such program".
  (let ((script (expand-file-name "scripts/work-beads")))
    ;; Skip only when the file is genuinely absent - the suite is run from
    ;; elsewhere - and never merely because the executable bit was lost, which
    ;; would let the drift this test exists to catch through unnoticed. Hence
    ;; `bash SCRIPT' rather than SCRIPT.
    (unless (file-exists-p script)
      (ert-skip "scripts/work-beads not found - run ERT from the repository root"))
    (should (equal (sort (copy-sequence cerebro-skipped-issue-types) #'string<)
                   (sort (process-lines "bash" script "--print-excluded-types") #'string<)))))

(ert-deftest cerebro-test/the-trigger-counts-what-planner-buffer-counts ()
  "The two owners of the planner buffer rule cannot drift apart.
`scripts/planner-buffer' is the shell-side one, which `skills/plan-bead'
calls; `cerebro-parked-labels' and `cerebro-planner-buffer-floor' are this
one, which the trigger reads every five-second tick without a subprocess.
Run as CI runs ERT, from the repository root."
  ;; Absolute, and run through `bash' rather than directly, for the reasons
  ;; the work-beads contract above gives.
  (let ((script (expand-file-name "scripts/planner-buffer")))
    (unless (file-exists-p script)
      (ert-skip "scripts/planner-buffer not found - run ERT from the repository root"))
    (should (equal (sort (copy-sequence cerebro-parked-labels) #'string<)
                   (sort (process-lines "bash" script "--print-excluded-labels") #'string<)))
    (should (equal cerebro-planner-buffer-floor
                   (string-to-number
                    (car (process-lines "bash" script "--print-floor")))))))

;; ---------------------------------------------------------------------------
;; ah-4ao increment 3: turning a sweep's facts into a decision

;; `cerebro--claim-finding' works from `sweep-claims.sh's JSON, parsed the way
;; `cerebro--parse-json' would: an alist with symbol keys.
(defun cerebro-test--claim-candidate (id assignee &optional on-main age verification-failed
                                                    docs-only lease-age)
  ;; Booleans as `cerebro--parse-json' parses them: `:false-object nil', so JSON
  ;; false and absent both read as plain nil, same as everywhere else here.
  `((id . ,id) (assignee . ,assignee) (title . "a bead")
    (verification_failed . ,verification-failed)
    (on_main . ,on-main)
    (commit_age_min . ,age)
    (docs_only . ,docs-only)
    (lease_age_min . ,lease-age)))

(ert-deftest cerebro-test/claim-finding-leaves-verification-failed ()
  "Psylocke's reopen puts the old commit back on main every time - that
proves nothing about whether the rework has landed, so this bead is never
sweep-closed regardless of what else is true of it."
  (should (null (cerebro--claim-finding
                 (cerebro-test--claim-candidate "ah-x1" "Cyclops" t 30 t)
                 nil (current-time)))))

(ert-deftest cerebro-test/claim-finding-leaves-live-implementer ()
  "A name that is still running keeps its bead, however old the merge looks."
  (should (null (cerebro--claim-finding
                 (cerebro-test--claim-candidate "ah-x1" "Cyclops" t 30)
                 '("Cyclops") (current-time)))))

(ert-deftest cerebro-test/claim-finding-leaves-fresh-commit ()
  "An implementer closes within seconds of merging; anything fresher than
ten minutes is one still mid-cleanup, not a dead one."
  (should (null (cerebro--claim-finding
                 (cerebro-test--claim-candidate "ah-x1" "Cyclops" t 3)
                 nil (current-time)))))

(ert-deftest cerebro-test/claim-finding-closes-delivered-dead-and-old ()
  (should (equal (cerebro--claim-finding
                  (cerebro-test--claim-candidate "ah-x1" "Cyclops" t 30)
                  nil (current-time))
                 '(close "ah-x1" "Delivered in PR; closed by the fleet view, Cyclops did not"))))

(ert-deftest cerebro-test/claim-finding-reclaims-dead-not-on-main ()
  (should (equal (cerebro--claim-finding
                  (cerebro-test--claim-candidate "ah-x1" "Cyclops" nil nil nil nil 30)
                  nil (current-time))
                 '(reclaim "ah-x1"))))

(ert-deftest cerebro-test/claim-finding-leaves-a-lease-not-yet-stale ()
  "`assignee' not being on the roster is not evidence of anything by
itself - a name that is not on `scripts/roster' is a live claim held by
hand exactly as often as it is a crashed session, and only the lease tells
the two apart. A bead
this function has just claimed, whose own session sets no `BEADS_ACTOR',
must not be offered for reclaim the moment its assignee reads as a human
name - which is the bug this test was written to catch."
  (should (null (cerebro--claim-finding
                 (cerebro-test--claim-candidate "ah-x1" "A Human" nil nil nil nil 3)
                 nil (current-time))))
  (should (null (cerebro--claim-finding
                 (cerebro-test--claim-candidate "ah-x1" "A Human" nil nil nil nil nil)
                 nil (current-time)))))

(defun cerebro-test--epic-candidate (id minutes)
  `((id . ,id) (title . "an epic") (minutes_since_last_child_closed . ,minutes)))

(ert-deftest cerebro-test/epic-finding-waits-ten-minutes ()
  "An implementer closes its parent within seconds of its last child; a
close inside ten minutes is one still mid-cleanup."
  (should (null (cerebro--epic-finding (cerebro-test--epic-candidate "ah-e1" 3))))
  (should (equal (cerebro--epic-finding (cerebro-test--epic-candidate "ah-e1" 30))
                 '(epic-close "ah-e1"))))

(ert-deftest cerebro-test/epic-finding-nil-minutes-waits ()
  "A close time the script could not parse is not evidence of anything -
leave it rather than guess."
  (should (null (cerebro--epic-finding (cerebro-test--epic-candidate "ah-e1" nil)))))

(defun cerebro-test--stalled-candidate (id assignee age &optional source branch)
  `((id . ,id) (assignee . ,assignee) (title . "a bead")
    (branch . ,branch)
    (progress_age_min . ,age)
    (progress_source . ,(or source "commit"))))

(ert-deftest cerebro-test/stalled-finding-leaves-a-bead-no-live-session-holds ()
  "A claim whose session is gone is the claims sweep's case, not this one's -
offering it here as well would put two lines in front of the navigator for
one bead."
  (should (null (cerebro--stalled-finding
                 (cerebro-test--stalled-candidate "ah-x1" "Cyclops" 300)
                 nil (current-time)))))

(ert-deftest cerebro-test/stalled-finding-leaves-an-asking-session ()
  "`asking' means blocked and said so; `cerebro--supervise-action' already
nudges it, and two mechanisms firing on one session is noise."
  (should (null (cerebro--stalled-finding
                 (cerebro-test--stalled-candidate "ah-x1" "Cyclops" 300)
                 '(("Cyclops" . asking)) (current-time)))))

(ert-deftest cerebro-test/stalled-finding-leaves-a-bead-inside-the-threshold ()
  "Forty minutes of silence is a bead sitting in CI, which is exactly what
the threshold exists to tolerate."
  (should (null (cerebro--stalled-finding
                 (cerebro-test--stalled-candidate "ah-x1" "Cyclops" 40)
                 '(("Cyclops" . working)) (current-time)))))

(ert-deftest cerebro-test/stalled-finding-leaves-a-bead-with-no-age ()
  "No age is no evidence - leave it rather than guess."
  (should (null (cerebro--stalled-finding
                 (cerebro-test--stalled-candidate "ah-x1" "Cyclops" nil)
                 '(("Cyclops" . working)) (current-time)))))

(ert-deftest cerebro-test/stalled-finding-offers-a-live-session-past-the-threshold ()
  (should (equal (cerebro--stalled-finding
                  (cerebro-test--stalled-candidate "ah-x1" "Cyclops" 300)
                  '(("Cyclops" . working)) (current-time))
                 '(unclaim "ah-x1"))))

(ert-deftest cerebro-test/stalled-finding-counts-an-unreadable-state-file-as-live ()
  "A live session that reaches here with a nil state - its state file parsed
but carries no `state\=' key, or one this version does not recognise - must
still count as live. Testing the state rather than membership would turn a
half-written file into a finding against a working implementer."
  (should (equal (cerebro--stalled-finding
                  (cerebro-test--stalled-candidate "ah-x1" "Cyclops" 300)
                  '(("Cyclops" . nil)) (current-time))
                 '(unclaim "ah-x1"))))

(ert-deftest cerebro-test/stalled-label-names-which-measurement-it-used ()
  "Commit and claim mean different things to a reader, so the line says
which one the age came from."
  (should (string-match-p
           "no commit for 300m"
           (cerebro--sweep-label '(unclaim "ah-x1")
                                 (cerebro-test--stalled-candidate "ah-x1" "Cyclops" 300))))
  (should (string-match-p
           "no start for 300m"
           (cerebro--sweep-label '(unclaim "ah-x1")
                                 (cerebro-test--stalled-candidate "ah-x1" "Cyclops" 300 "claim")))))

(ert-deftest cerebro-test/finding-command-covers-only-the-known-shapes ()
  "This function is the complete list of destructive commands the fleet
view can run - so its total output range has to be pinned, not just its
happy path."
  (should (equal (cerebro--finding-command '(close "ah-x1" "reason here") "/repo")
                 '("bd" "close" "ah-x1" "--reason" "reason here")))
  (should (equal (cerebro--finding-command '(reclaim "ah-x1") "/repo")
                 '("bd" "reclaim" "--id" "ah-x1" "--older-than" "10m")))
  (should (equal (cerebro--finding-command '(epic-close "ah-e1") "/repo")
                 '("bd" "close" "ah-e1")))
  ;; `bd unclaim', not `bd reclaim --older-than': reclaim's window is about a
  ;; session that is gone, and would refuse a bead whose lease is still being
  ;; heartbeated by the very session that has stopped moving.
  (should (equal (cerebro--finding-command '(unclaim "ah-x1") "/repo")
                 '("bd" "unclaim" "ah-x1")))
  (should (null (cerebro--finding-command nil "/repo")))
  (should-error (cerebro--finding-command '(unknown-shape "ah-x1") "/repo")))

;; ---------------------------------------------------------------------------
;; ah-kjfm: an open bead carrying an assignee no live session backs up

(defun cerebro-test--assignee-candidate (id assignee age &optional priority)
  `((id . ,id) (assignee . ,assignee) (title . "a stranded bead")
    (priority . ,(or priority 0))
    (age_min . ,age)))

(ert-deftest cerebro-test/assignee-finding-leaves-a-name-off-the-roster ()
  "An assignee that is not a roster name was put there by hand, and undoing
somebody else's deliberate assignment is not the fleet view's to do."
  (should (null (cerebro--assignee-finding
                 (cerebro-test--assignee-candidate "ah-fjty" "henrik" 300)
                 '(("Cyclops" . "ah-gjq4")) '("Cyclops" "Storm") (current-time)))))

(ert-deftest cerebro-test/assignee-finding-leaves-a-session-alive-on-this-bead ()
  "A session whose state file says it is on this very bead is a moment from
claiming it; clearing the assignee under it would achieve nothing and read
as the fleet view fighting an implementer."
  (should (null (cerebro--assignee-finding
                 (cerebro-test--assignee-candidate "ah-fjty" "Cyclops" 300)
                 '(("Cyclops" . "ah-fjty")) '("Cyclops" "Storm") (current-time)))))

(ert-deftest cerebro-test/assignee-finding-leaves-a-bead-inside-the-grace-period ()
  "A bead somebody touched two minutes ago is one somebody is attending to.
The sweeps run ten-minutely, so this is seen again on the next pass."
  (should (null (cerebro--assignee-finding
                 (cerebro-test--assignee-candidate "ah-fjty" "Cyclops" 2)
                 '(("Cyclops" . "ah-gjq4")) '("Cyclops" "Storm") (current-time)))))

(ert-deftest cerebro-test/assignee-finding-leaves-a-bead-with-no-age ()
  "No age is no evidence - leave it rather than guess."
  (should (null (cerebro--assignee-finding
                 (cerebro-test--assignee-candidate "ah-fjty" "Cyclops" nil)
                 '(("Cyclops" . "ah-gjq4")) '("Cyclops" "Storm") (current-time)))))

(ert-deftest cerebro-test/assignee-finding-offers-a-session-alive-on-another-bead ()
  "ah-fjty on 2026-08-23: open at P0, naming Cyclops, while Cyclops built
ah-gjq4. It sat at the top of `bd ready' for 32 minutes."
  (should (equal (cerebro--assignee-finding
                  (cerebro-test--assignee-candidate "ah-fjty" "Cyclops" 32)
                  '(("Cyclops" . "ah-gjq4")) '("Cyclops" "Storm") (current-time))
                 '(unassign "ah-fjty" 0))))

(ert-deftest cerebro-test/assignee-finding-offers-a-session-that-is-not-running ()
  "There is deliberately no \"the session is not alive\" guard: a roster
session that is not running cannot be about to claim anything, so that case
falls through to the offer and should."
  (should (equal (cerebro--assignee-finding
                  (cerebro-test--assignee-candidate "ah-fjty" "Cyclops" 32)
                  nil '("Cyclops" "Storm") (current-time))
                 '(unassign "ah-fjty" 0))))

(ert-deftest cerebro-test/assignee-finding-carries-the-priority-it-was-given ()
  "The priority rides in the finding because `cerebro--sweep-line' needs it
and is given nothing else - see the P0 face below."
  (should (equal (cerebro--assignee-finding
                  (cerebro-test--assignee-candidate "ah-zzz" "Cyclops" 32 2)
                  nil '("Cyclops") (current-time))
                 '(unassign "ah-zzz" 2))))

(ert-deftest cerebro-test/assignee-label-names-what-the-assignee-is-doing ()
  "Both lines ship verbatim; the navigator chose this wording."
  (should (equal (cerebro--sweep-label
                  '(unassign "ah-fjty" 0)
                  (cons '(assignee_bead . "ah-gjq4")
                        (cerebro-test--assignee-candidate "ah-fjty" "Cyclops" 32)))
                 "unassign ah-fjty — Cyclops is on ah-gjq4"))
  (should (equal (cerebro--sweep-label
                  '(unassign "ah-fjty" 0)
                  (cerebro-test--assignee-candidate "ah-fjty" "Cyclops" 32))
                 "unassign ah-fjty — Cyclops is not running")))

(ert-deftest cerebro-test/a-stranded-p0-line-shouts-and-others-do-not ()
  "The escalation is that a P0 line is visibly different from the rest of
the section - the same `warning' face an `asking' session's marker uses -
and nothing more: no new face, no glyph, no popup."
  (should (eq 'warning
              (get-text-property 0 'face
                                 (cerebro--sweep-line "unassign ah-fjty — x"
                                                      '(unassign "ah-fjty" 0)))))
  (should-not (get-text-property 0 'face
                                 (cerebro--sweep-line "unassign ah-zzz — x"
                                                      '(unassign "ah-zzz" 2))))
  (should-not (get-text-property 0 'face
                                 (cerebro--sweep-line "unclaim ah-x1 — x"
                                                      '(unclaim "ah-x1")))))

(ert-deftest cerebro-test/assignee-finding-command-clears-the-assignee ()
  "The only place this write may live."
  (should (equal (cerebro--finding-command '(unassign "ah-fjty" 0) "/repo")
                 '("bd" "update" "ah-fjty" "--assignee" ""))))

(ert-deftest cerebro-test/live-session-beads-reports-what-each-session-is-on ()
  "The third derivation of the one state-file read - and the one this sweep
needs, since \"alive\" alone cannot tell a session about to claim this bead
from one building something else."
  (cl-letf (((symbol-function 'cerebro--roster) (lambda (_root) '("Cyclops" "Storm" "Rogue")))
            ((symbol-function 'cerebro--read-state-file)
             (lambda (path)
               (cond ((string-match-p "Cyclops" path)
                      '((pid . 111) (state . "working") (bead . "ah-gjq4")))
                     ((string-match-p "Storm" path)
                      '((pid . 222) (state . "idle")))
                     (t nil))))
            ((symbol-function 'cerebro--session-alive-p) (lambda (_pid _name _root) t)))
    (should (equal (cerebro--live-session-beads "/repo")
                   '(("Cyclops" . "ah-gjq4") ("Storm" . nil))))
    ;; The sibling derivation must be untouched by the refactor that added the
    ;; one above: `cerebro--claim-finding' and `cerebro--stalled-finding' read
    ;; it and are deliberately not edited by this bead.
    (should (equal (cerebro--live-session-states "/repo")
                   '(("Cyclops" . working) ("Storm" . idle))))
    (should (equal (cerebro--live-implementer-names "/repo") '("Cyclops" "Storm")))))

(ert-deftest cerebro-test/findings-from-returns-every-sweep ()
  "Every sweep in the table is wired in, and the assignee label has been
enriched with what its assignee is actually on."
  ;; `cerebro--live-sessions' is stubbed, not the three helpers that derive
  ;; from it: `cerebro--findings-from' must reach the state files exactly
  ;; once, so all five sweeps judge one snapshot of a fleet that moves.
  (cl-letf (((symbol-function 'cerebro--live-sessions)
             (lambda (_root) '(("Cyclops" working "ah-gjq4"))))
            ((symbol-function 'cerebro--roster) (lambda (_root) '("Cyclops" "Storm"))))
    (let ((findings (cerebro--findings-from "/repo" (cerebro-test--sweep-outputs))))
      (should (equal (mapcar #'cdr findings)
                     '((reclaim "ah-c1") (epic-close "ah-e1") (unclaim "ah-s1")
                       (unassign "ah-a1" 0) (recheck "ah-v1" 0) (unpause "ah-h1" 2))))
      (should (equal (nth 3 (mapcar #'car findings))
                     "unassign ah-a1 — Cyclops is on ah-gjq4"))
      (should (equal (nth 4 (mapcar #'car findings))
                     "recheck ah-v1 — verdict at 0b444332, 2 merges since"))
      (should (equal (car (last (mapcar #'car findings)))
                     "unpause ah-h1 — waiting on ah-b1, closed 2h ago")))))

(ert-deftest cerebro-test/findings-from-reads-the-state-files-once ()
  "Five sweeps, one snapshot. Deriving through the three helpers instead
would walk the roster three times and take three separate readings of a
fleet that moves between them - so one sweep could judge a session the next
no longer sees."
  (let ((reads 0))
    (cl-letf (((symbol-function 'cerebro--live-sessions)
               (lambda (_root) (setq reads (1+ reads)) '(("Cyclops" working "ah-gjq4"))))
              ((symbol-function 'cerebro--roster) (lambda (_root) '("Cyclops"))))
      (cerebro--findings-from
       "/repo"
       (list (cons 'sweep-stalled
                   (list (cerebro-test--stalled-candidate "ah-s1" "Cyclops" 300)))
             (cons 'sweep-assignees
                   (list (cerebro-test--assignee-candidate "ah-a1" "Cyclops" 32)))))
      (should (equal reads 1)))))

(ert-deftest cerebro-test/the-assignee-sweep-is-registered ()
  (should (equal (alist-get 'sweep-assignees (cerebro--sweep-scripts))
                 "sweep-assignees.sh")))

(ert-deftest cerebro-test/the-newest-sweep-is-registered-last ()
  "Each sweep is appended, so its parsed output reaches
`cerebro--findings-from' in the argument position the docstring promises."
  (should (equal (alist-get 'sweep-verdicts (cerebro--sweep-scripts))
                 "sweep-verdicts.sh"))
  (should (equal (car (last (cerebro--sweep-scripts)))
                 '(sweep-paused . "sweep-paused.sh"))))

;; cb-4s8: a sweep is one row of `cerebro--sweeps', not six edits in lockstep.

(defun cerebro-test--snapshot ()
  "The fleet slices `cerebro--sweeps' rows draw on, hand-built - Cyclops
working on ah-gjq4, Storm on the roster and not running."
  (list :live-names '("Cyclops")
        :live-states '(("Cyclops" . working))
        :live-beads '(("Cyclops" . "ah-gjq4"))
        :roster '("Cyclops" "Storm")
        :now (current-time)))

(defun cerebro-test--sweep-outputs ()
  "One candidate per sweep, keyed as `cerebro--sweeps' is."
  (list (cons 'sweep-claims
              (list (cerebro-test--claim-candidate "ah-c1" "Storm" nil nil nil nil 30)))
        (cons 'sweep-epics (list (cerebro-test--epic-candidate "ah-e1" 30)))
        (cons 'sweep-stalled (list (cerebro-test--stalled-candidate "ah-s1" "Cyclops" 300)))
        (cons 'sweep-assignees (list (cerebro-test--assignee-candidate "ah-a1" "Cyclops" 32)))
        (cons 'sweep-verdicts
              (list (cerebro-test--verdict-candidate "ah-v1" "0b444332cd" 2)))
        (cons 'sweep-paused
              (list (cerebro-test--paused-candidate
                     "ah-h1" (list (cerebro-test--blocker "ah-b1" "closed" 120)))))))

(ert-deftest cerebro-test/findings-from-snapshot-is-pure-and-table-driven ()
  "The judging half of the sweep pipeline takes its outputs as one alist and
its fleet as one plist, and walks `cerebro--sweeps' - so it reads no files
and a sixth sweep changes no signature."
  (let ((findings (cerebro--findings-from-snapshot (cerebro-test--sweep-outputs)
                                                   (cerebro-test--snapshot))))
    (should (equal (mapcar #'cdr findings)
                   '((reclaim "ah-c1") (epic-close "ah-e1") (unclaim "ah-s1")
                     (unassign "ah-a1" 0) (recheck "ah-v1" 0) (unpause "ah-h1" 2))))
    ;; The enrichment went through the row, not through the walker.
    (should (equal (nth 3 (mapcar #'car findings))
                   "unassign ah-a1 — Cyclops is on ah-gjq4")))
  ;; A key absent from OUTPUTS contributes nothing, rather than erroring.
  (should (equal (mapcar #'cdr
                         (cerebro--findings-from-snapshot
                          (assq-delete-all 'sweep-epics (cerebro-test--sweep-outputs))
                          (cerebro-test--snapshot)))
                 '((reclaim "ah-c1") (unclaim "ah-s1")
                   (unassign "ah-a1" 0) (recheck "ah-v1" 0) (unpause "ah-h1" 2)))))

(ert-deftest cerebro-test/a-sweep-row-declares-everything-the-runner-needs ()
  "Every row carries its key, its script, its finder, the fleet slices it
wants and - optionally - its label enrichment. Nothing about a sweep is
declared anywhere the runner also has to be told about."
  (dolist (row cerebro--sweeps)
    (pcase-let ((`(,key ,script ,finder ,needs . ,rest) row))
      (should (symbolp key))
      (should (string-suffix-p ".sh" script))
      (should (file-exists-p (expand-file-name (concat "scripts/" script)
                                               cerebro-test--repo-root)))
      (should (functionp finder))
      (should (listp needs))
      (dolist (need needs)
        (should (memq need '(:live-names :live-states :live-beads :roster :now))))
      (should (<= (length rest) 1))
      (when rest (should (functionp (car rest)))))))

(ert-deftest cerebro-test/a-sixth-sweep-is-one-row ()
  "The point of the table. A sweep that exists nowhere but in
`cerebro--sweeps' is run, judged and labelled - no signature, no second
list, and no other function edited to let it through."
  (let ((cerebro--sweeps
         (append cerebro--sweeps
                 `((sweep-demo "sweep-demo.sh"
                               ,(lambda (c) (and (alist-get 'flag c)
                                                 (list 'epic-close (alist-get 'id c))))
                               ())))))
    (should (equal (alist-get 'sweep-demo (cerebro--sweep-scripts)) "sweep-demo.sh"))
    (let ((findings (cerebro--findings-from-snapshot
                     (append (cerebro-test--sweep-outputs)
                             `((sweep-demo . (((id . "ah-d1") (flag . t)
                                               (minutes_since_last_child_closed . 30))
                                              ((id . "ah-d2") (flag . nil))))))
                     (cerebro-test--snapshot))))
      ;; One finding from the new row, appended in table order, labelled by the
      ;; `epic-close' arm that was already there.
      (should (equal (car (last (mapcar #'cdr findings))) '(epic-close "ah-d1")))
      (should (equal (car (last (mapcar #'car findings)))
                     "close ah-d1 — all children closed 30m ago"))
      (should (equal (length findings) 7)))))

;; ---------------------------------------------------------------------------
;; ah-4ao increment 4: showing sweep findings and acting on them, confirmed

(ert-deftest cerebro-test/sweep-section-renders-findings ()
  (let ((lines (cerebro--sweep-section
                (list (cons "close ah-x1 — delivered by Cyclops, on main 25m" '(close "ah-x1" "r"))
                      (cons "reclaim ah-x2 — Storm gone, not on main" '(reclaim "ah-x2"))))))
    (should (string-match-p "\\`Sweeps\\'" (substring-no-properties (car lines))))
    (should (= 3 (length lines)))
    (should (string-match-p "close ah-x1" (nth 1 lines)))
    (should (string-match-p "reclaim ah-x2" (nth 2 lines)))
    ;; Each line carries its own finding, the way a bead row carries its id -
    ;; `x' acts on what point is standing on, not on a re-parse of the text.
    (should (equal (get-text-property 0 'cerebro-finding (nth 1 lines)) '(close "ah-x1" "r")))))

(ert-deftest cerebro-test/sweep-section-hidden-when-empty ()
  "Unlike the bead sections, which say \"(none)\", an empty Sweeps section
says nothing at all - that is the ordinary state of every render but one."
  (should (null (cerebro--sweep-section nil))))

(ert-deftest cerebro-test/sweep-keeps-the-last-findings-when-a-script-does-not-answer ()
  "Ten-minutely housekeeping may miss a beat; an empty Sweeps section must
not say the fleet is clean when a script simply failed to answer."
  (let ((buffer (get-buffer-create "*cerebro-test-sweep-no-answer*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-sweeps)
                   (lambda (_root callback) (funcall callback nil) 'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (setq cerebro--sweep-findings (list (cons "held" '(close "ah-x1" "delivered"))))
            (cerebro--sweep buffer)
            (should (equal cerebro--sweep-findings
                           (list (cons "held" '(close "ah-x1" "delivered")))))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/sweep-clears-the-findings-when-both-answer-empty ()
  "A genuinely clean fleet has to be able to clear a stale finding, not just
add to it."
  (let ((buffer (get-buffer-create "*cerebro-test-sweep-clears*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-sweeps)
                   (lambda (_root callback) (funcall callback (list nil)) 'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (setq cerebro--sweep-findings (list (cons "held" '(close "ah-x1" "delivered"))))
            (cerebro--sweep buffer)
            (should (null cerebro--sweep-findings))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/request-sweeps-treats-invalid-claims-output-as-no-answer ()
  "`sweep-claims.sh' exiting zero but printing garbage must not read as an
answer, and must not even start the epics script (PR #42 review)."
  (let (got (started nil))
    (cl-letf (((symbol-function 'cerebro--run-async)
               (lambda (key _root _argv callback)
                 (push key started)
                 (funcall callback "this is not json")
                 'started)))
      (cerebro--request-sweeps "/repo" (lambda (answer) (setq got answer))))
    (should (null got))
    (should (equal started '(sweep-claims)))))

(ert-deftest cerebro-test/request-sweeps-treats-invalid-epics-output-as-no-answer ()
  "The same, for the epics script - a claims answer that parses fine must
not paper over an epics script that printed garbage."
  (let (got)
    (cl-letf (((symbol-function 'cerebro--run-async)
               (lambda (key _root _argv callback)
                 (if (eq key 'sweep-claims)
                     (funcall callback "[]")
                   (funcall callback "this is not json"))
                 'started)))
      (cerebro--request-sweeps "/repo" (lambda (answer) (setq got answer))))
    (should (null got))))

(ert-deftest cerebro-test/sweep-refuses-a-second-run-while-the-first-is-still-out ()
  "The claims/epics chain uses two different `cerebro--run-async' keys, so a
second sweep starting while the first's epics call is still out could
otherwise have its own epics request silently dropped as `busy' - this
guards at the `cerebro--sweep' level instead, the same way
`cerebro--beads-render' leaves a request already out to finish rather than
joining it with a second (PR #42 review)."
  (let ((buffer (get-buffer-create "*cerebro-test-sweep-overlap*"))
        (request-calls 0)
        stashed-callback)
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-sweeps)
                   (lambda (_root callback)
                     (cl-incf request-calls)
                     (setq stashed-callback callback)
                     'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (cerebro--sweep buffer)
            (should (= request-calls 1))
            ;; A second sweep while the first is still out must not start a
            ;; second chain.
            (cerebro--sweep buffer)
            (should (= request-calls 1))
            (funcall stashed-callback (list nil))
            ;; Once it has answered, a further sweep is free to run again.
            (cerebro--sweep buffer)
            (should (= request-calls 2))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/sweep-act-runs-nothing-without-confirmation ()
  "The confirmation gate is the one thing standing between a sweep finding
and a destructive `bd' call; this pins that nothing reaches the runner
without it saying yes."
  (let ((ran nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'cerebro--run-sweep-command)
               (lambda (&rest args) (push args ran) t))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory))
              ((symbol-function 'cerebro--finding-at-point)
               (lambda () '(close "ah-x1" "delivered"))))
      (cerebro-sweep-act)
      (should (null ran)))))

(ert-deftest cerebro-test/sweep-act-with-no-finding-at-point-is-refused ()
  (cl-letf (((symbol-function 'cerebro--finding-at-point) (lambda () nil)))
    (should-error (cerebro-sweep-act) :type 'user-error)))

(ert-deftest cerebro-test/sweep-act-key-is-bound ()
  (should (eq (lookup-key cerebro-beads-mode-map "x") #'cerebro-sweep-act)))

(ert-deftest cerebro-test/sweep-act-warns-when-the-push-fails ()
  "The close/reclaim itself succeeded - a `user-error' claiming nothing
happened would be wrong - but the other machines cannot see it until the
push does, and that has to reach the navigator, not just the exit status."
  (let ((calls nil) (messages nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'cerebro--run-sweep-command)
               ;; First call (the close) succeeds; second (the push) fails.
               (lambda (_root argv) (push argv calls) (= (length calls) 1)))
              ((symbol-function 'cerebro--beads-render) (lambda (&rest _) nil))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory))
              ((symbol-function 'cerebro--finding-at-point)
               (lambda () '(close "ah-x1" "delivered")))
              ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (cerebro-sweep-act)
      ;; The close ran and the push was attempted, in that order.
      (should (equal (reverse calls)
                      (list '("bd" "close" "ah-x1" "--reason" "delivered")
                            '("bd" "dolt" "push"))))
      (should (string-match-p "push" (car messages))))))

;; ---------------------------------------------------------------------------
;; ah-4ao increment 5: the prune watcher moves from Cerebro to `M-x cerebro'

(ert-deftest cerebro-test/prune-action-starts-when-absent ()
  (should (eq (cerebro--prune-action nil) 'start)))

(ert-deftest cerebro-test/prune-action-leaves-running-process ()
  "Starting a second `--watch' would sweep in duplicate and race the first
one's removals - not merely redundant, since `prune-worktrees.sh' talks to
git."
  (should (eq (cerebro--prune-action t) 'already-running)))

(ert-deftest cerebro-test/ensure-prune-watcher-starts-a-process-once ()
  (let ((started 0))
    (cl-letf (((symbol-function 'cerebro--prune-process-live-p) (lambda () nil))
              ((symbol-function 'cerebro--start-prune-process)
               (lambda (_repo-root) (setq started (1+ started)))))
      (cerebro--ensure-prune-watcher "/repo")
      (should (= started 1))))
  (let ((started 0))
    (cl-letf (((symbol-function 'cerebro--prune-process-live-p) (lambda () t))
              ((symbol-function 'cerebro--start-prune-process)
               (lambda (_repo-root) (setq started (1+ started)))))
      (cerebro--ensure-prune-watcher "/repo")
      (should (= started 0)))))

;; ---------------------------------------------------------------------------
;; ah-b8o: the fleet list keeps its selected agent across the 5s refresh

(ert-deftest cerebro-test/list-window-keeps-selection-across-refresh ()
  "A refresh must not walk the list window's selection back to the top.

`tabulated-list-print' restores the BUFFER's point by id (remember-pos),
but a window whose buffer is not the selected one keeps its own point -
so once a detail window takes the selection (as TAB does in the real
fleet view), the list window's own point is left stale across the next
refresh.  Both the list and the bead panel are redrawn through `cerebro--redraw',
which pushes the buffer's restored point out to every window showing it -
this pins that the list's own refresh path, `cerebro--list-render', goes
through it too."
  (let ((list-buffer (generate-new-buffer " *cerebro-test-fleet-list*"))
        (other-buffer (generate-new-buffer " *cerebro-test-other*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--revert) #'ignore))
          (save-window-excursion
            (with-current-buffer list-buffer
              (cerebro-mode)
              (setq tabulated-list-entries
                    '(("A" ["A" "" "" "" ""])
                      ("B" ["B" "" "" "" ""])
                      ("C" ["C" "" "" "" ""])))
              (tabulated-list-print))
            (delete-other-windows)
            (let* ((list-window (selected-window)))
              (set-window-buffer list-window list-buffer)
              ;; Select "B", the way the navigator would with point on an
              ;; agent partway down the list.
              (with-current-buffer list-buffer
                (goto-char (point-min))
                (while (not (equal (tabulated-list-get-id) "B"))
                  (forward-line 1))
                (set-window-point list-window (point)))
              ;; TAB away: a detail window takes the selection, and the list
              ;; window is left showing its own (frozen) point.
              (let ((detail-window (split-window list-window nil 'right)))
                (select-window detail-window)
                (set-window-buffer detail-window other-buffer))
              ;; Refresh, exactly as `cerebro--tick' does: from the buffer,
              ;; while the list window is not selected. `cerebro--revert' is
              ;; stubbed to a no-op so the pre-set entries survive the revert
              ;; hook and `tabulated-list-print' restores by id as usual.
              (with-current-buffer list-buffer
                (cerebro--list-render list-buffer))
              (should (equal (with-current-buffer list-buffer
                                (tabulated-list-get-id (window-point list-window)))
                              "B")))))
      (kill-buffer list-buffer)
      (kill-buffer other-buffer))))

;; ---------------------------------------------------------------------------
;; ah-lyc: the table fits inside its window

(ert-deftest cerebro-test/list-fits-inside-its-window ()
  "A table exactly as wide as its window loses its last column to Emacs's `$'
truncation marker - the bug this bead exists to kill. The table must be
strictly narrower than `cerebro-list-width', not merely equal to it."
  (with-temp-buffer
    (cerebro-mode)
    (let ((table-width (+ (apply #'+ (mapcar (lambda (c) (nth 1 c))
                                              (append tabulated-list-format nil)))
                           tabulated-list-padding)))
      (should (< table-width cerebro-list-width)))))

;; ---------------------------------------------------------------------------
;; ah-u3i: a state per phase in the fleet list

(ert-deftest cerebro-test/derive-implementer-carries-phase ()
  (let* ((states '(("Storm" . ((state . "working") (bead . "ah-axj")
                                (phase . "review") (phase_since . "2026-08-15T09:18:00Z")
                                (since . "2026-08-15T09:00:00Z") (pid . 4242)))))
         (agents (cerebro--derive '("Storm") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (equal (cerebro-agent-phase agent) "review"))
    (should (equal (cerebro-agent-phase-since agent) "2026-08-15T09:18:00Z"))
    (should (equal (cerebro-agent-raw agent) "working"))))

(ert-deftest cerebro-test/derive-implementer-carries-phase-nil-when-absent ()
  "An old-format state file - no `phase\=' or `phase_since\=' fields at all -
must derive to nil rather than erroring, so a file written before this bead
landed is still valid (see the design's \"old-format-file-is-fine\")."
  (let* ((states '(("Storm" . ((state . "working") (bead . "ah-axj")
                                (since . "2026-08-15T09:00:00Z") (pid . 4242)))))
         (agents (cerebro--derive '("Storm") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (null (cerebro-agent-phase agent)))
    (should (null (cerebro-agent-phase-since agent)))))

(ert-deftest cerebro-test/derive-implementer-unknown-state-is-not-idle ()
  "An implementer's state file can carry a raw `state\=' string this list has
never seen - a typo in the skill, most likely.  That must not read as
`idle\=', which means \"free, give it a bead\": it means \"alive, but this
list does not understand what it is doing\"."
  (let* ((states '(("Cyclops" . ((state . "finishing-up") (bead . "ah-f9c")
                                  (since . "2026-08-15T09:00:00Z") (pid . 4242)))))
         (agents (cerebro--derive '("Cyclops") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'unknown))
    (should (equal (cerebro-agent-raw agent) "finishing-up"))))

(ert-deftest cerebro-test/derive-implementer-idle-state-still-idle ()
  "`idle\=' is a known state and must keep mapping to `'idle\=', not fall into
the new `'unknown\=' bucket alongside a typo."
  (let* ((states '(("Wolverine" . ((state . "idle") (bead . nil)
                                    (since . "2026-08-15T09:00:00Z") (pid . 4343)))))
         (agents (cerebro--derive '("Wolverine") nil states
                                          #'cerebro-test--always-alive nil nil))
         (agent (car agents)))
    (should (eq (cerebro-agent-state agent) 'idle))))

(ert-deftest cerebro-test/entry-state-column-shows-a-session-count-past-one ()
  "A name with two sessions in this fleet carries a yellow \=` ×N\=' after the
state, flag first and count second (cb-63m).  One session, or a row nobody
counted, shows nothing."
  (let ((now (current-time))
        (counted (lambda (agent n)
                   (setf (cerebro-agent-sessions agent) n)
                   agent)))
    (should (equal (aref (cadr (cerebro--entry
                                (funcall counted
                                         (cerebro-test--agent "Xavier" "planner" 'interactive
                                                              'working nil "cb-63m" "build")
                                         2)
                                now))
                         2)
                   "build ×2"))
    (should (equal (aref (cadr (cerebro--entry
                                (funcall counted
                                         (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                                              'working nil "cb-63m" "ci")
                                         2)
                                now t))
                         2)
                   "ci ■ ×2"))
    (should (equal (aref (cadr (cerebro--entry
                                (funcall counted
                                         (cerebro-test--agent "Beast" "planner" 'interactive 'up)
                                         3)
                                now))
                         2)
                   "up ×3"))
    (should (equal (aref (cadr (cerebro--entry
                                (funcall counted
                                         (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                                              'working nil "cb-63m" "build")
                                         1)
                                now))
                         2)
                   "build"))
    (should (equal (aref (cadr (cerebro--entry
                                (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                                     'working nil "cb-63m" "build")
                                now))
                         2)
                   "build"))
    ;; The marker is the warning face, so it reads as something to act on.
    (let ((cell (aref (cadr (cerebro--entry
                             (funcall counted
                                      (cerebro-test--agent "Xavier" "planner" 'interactive 'up)
                                      2)
                             now))
                      2)))
      (should (eq (get-text-property (1- (length cell)) 'face cell) 'warning)))))

(ert-deftest cerebro-test/entry-marks-an-unverified-row ()
  "An `unverified-pid' adds a grey \=` ?\=' to the State column, BEFORE the
flag and the session count: it qualifies the state word itself, the way the
flag is about the bead in flight and the count about the session
\(cb-63m\) - not the other way around (ah-ybsr)."
  (let ((now (current-time)))
    ;; the slot set: the marker appears
    (let ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                      'working nil "ah-aao" "build")))
      (setf (cerebro-agent-unverified-pid agent) 4242)
      (should (equal (aref (cadr (cerebro--entry agent now)) 2) "build ?")))
    ;; the slot unset: no marker
    (should (equal (aref (cadr (cerebro--entry
                                (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                                     'working nil "ah-aao" "build")
                                now))
                         2)
                   "build"))
    ;; marker, flag and count together: " ? ■ ×2", in that order
    (let ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                      'working nil "ah-aao" "build")))
      (setf (cerebro-agent-unverified-pid agent) 4242)
      (setf (cerebro-agent-sessions agent) 2)
      (should (equal (aref (cadr (cerebro--entry agent now t)) 2) "build ? ■ ×2")))))

(ert-deftest cerebro-test/entry-state-column-shows-the-phase ()
  (let ((now (current-time)))
    (should (equal (aref (cadr (cerebro--entry
                                 (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                                       'working nil "ah-aao" "build")
                                 now))
                          2)
                    "build"))
    (should (equal (aref (cadr (cerebro--entry
                                 (cerebro-test--agent "Cyclops" "implementer" 'implementer
                                                       'working nil "ah-aao" nil)
                                 now))
                          2)
                    "working"))
    (should (equal (aref (cadr (cerebro--entry
                                 (cerebro-test--agent "Storm" "implementer" 'implementer
                                                       'asking nil "ah-axj" "review")
                                 now))
                          2)
                    "asking"))
    (should (equal (aref (cadr (cerebro--entry
                                 (cerebro-test--agent "Wolverine" "implementer" 'implementer
                                                       'working nil "ah-m9q.2" "ci")
                                 now t))
                          2)
                    "ci ■"))))

(ert-deftest cerebro-test/entry-unknown-state-shows-the-raw-word ()
  (let* ((now (current-time))
         (agent (make-cerebro-agent :name "Phoenix" :role "implementer" :kind 'implementer
                                            :state 'unknown :raw "finishing-up"))
         (row (cadr (cerebro--entry agent now)))
         (glyph (aref row 0)))
    (should (equal (aref row 2) (truncate-string-to-width "finishing-up" 10 nil nil "…")))
    (should (memq 'cerebro-waiting (cerebro-test--faces-at glyph 0)))))

(ert-deftest cerebro-test/for-column-shows-bead-and-phase-time ()
  (let ((now (encode-time (iso8601-parse "2026-08-15T09:30:00Z"))))
    (should (equal (cerebro--for-column "2026-08-15T09:00:00Z" "2026-08-15T09:18:00Z" now)
                    "30m 12m"))
    (should (equal (cerebro--for-column "2026-08-15T09:21:00Z" nil now)
                    "9m"))
    (should (equal (cerebro--for-column nil nil now)
                    ""))))

(ert-deftest cerebro-test/entry-bead-phase-column ()
  (let* ((now (encode-time (iso8601-parse "2026-08-15T09:30:00Z")))
         (agent (make-cerebro-agent :name "Storm" :role "implementer" :kind 'implementer
                                            :state 'working :bead "ah-axj"
                                            :since "2026-08-15T09:00:00Z"
                                            :phase "review"
                                            :phase-since "2026-08-15T09:18:00Z"
                                            :external nil))
         (row (cadr (cerebro--entry agent now))))
    (should (equal (aref row 4) "30m 12m")))
  (let* ((now (encode-time (iso8601-parse "2026-08-15T09:30:00Z")))
         (agent (make-cerebro-agent :name "Xavier" :role "planner" :kind 'interactive
                                            :state 'up :external t))
         (row (cadr (cerebro--entry agent now))))
    (should (equal (aref row 4) ""))))

(ert-deftest cerebro-test/for-column-header-fits ()
  (with-temp-buffer
    (cerebro-mode)
    (let ((col (aref tabulated-list-format 4)))
      (should (equal (car col) "Bead/Phase"))
      (should (<= (length (car col)) (nth 1 col))))))

(ert-deftest cerebro-test/alive-is-everything-but-dead ()
  "`asking\=', `done\=' and `unknown\=' are all live sessions - a process really
is up, whatever the fleet view makes of its state - so `s\=' must treat them
as already running rather than launching a second session over them (the
`*fleet: <name>*<2>\=' bug this folds in a fix for)."
  (dolist (state '(asking waiting unknown))
    (should (eq (cerebro--start-action
                 (cerebro-test--agent "Cyclops" "implementer" 'implementer state)
                 '("Cyclops"))
                'already-up)))
  (should (eq (cerebro--start-action
               (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead)
               nil)
              'launch)))

(ert-deftest cerebro-test/kill-action-covers-asking-and-unknown ()
  (should (eq (cerebro--kill-action
               (cerebro-test--agent "Storm" "implementer" 'implementer 'asking nil "ah-axj")
               '("Storm"))
              'kill-working))
  (should (eq (cerebro--kill-action
               (cerebro-test--agent "Phoenix" "implementer" 'implementer 'unknown)
               '("Phoenix"))
              'kill))
  (should (eq (cerebro--kill-action
               (cerebro-test--agent "Gambit" "implementer" 'implementer 'dead)
               '("Gambit"))
              'dead)))

(ert-deftest cerebro-test/supervise-ignores-an-unknown-state ()
  (let* ((now (current-time))
         (agent (cerebro-test--agent "Phoenix" "implementer" 'implementer 'unknown)))
    (should (null (cerebro--supervise-action agent nil now)))
    (should (null (cerebro--supervise-action agent t now)))))

;; ---------------------------------------------------------------------------
;; ah-6uo: one redraw step and one tick for both panels

(ert-deftest cerebro-test/redraw-gives-every-window-the-buffers-point ()
  "Every window showing the buffer gets the point DRAW left it on - not just
the buffer, which is all `goto-char' alone would move."
  (let ((buffer (generate-new-buffer " *cerebro-test-redraw*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (special-mode)
            (let ((inhibit-read-only t))
              (insert "one\ntwo\nthree")))
          (save-window-excursion
            (delete-other-windows)
            (let ((elsewhere (generate-new-buffer " *cerebro-test-elsewhere*")))
              (unwind-protect
                  (progn
                    (set-window-buffer (selected-window) elsewhere)
                    (let* ((window1 (split-window (selected-window) nil 'below))
                           (window2 (progn (set-window-buffer window1 buffer)
                                            (split-window window1 nil 'below))))
                      (set-window-buffer window2 buffer)
                      (let ((selected (selected-window))
                            (current (current-buffer)))
                        (cerebro--redraw buffer
                                          (lambda ()
                                            (goto-char (point-min))
                                            (forward-line 2)))
                        ;; Unchanged: the redraw does not touch the navigator's
                        ;; own position.
                        (should (eq (selected-window) selected))
                        (should (eq (current-buffer) current)))
                      (with-current-buffer buffer
                        (should (= (window-point window1) (point)))
                        (should (= (window-point window2) (point))))))
                (kill-buffer elsewhere)))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/redraw-does-nothing-to-a-dead-buffer ()
  "A tick that outlives its buffer must not error."
  (let ((buffer (generate-new-buffer " *cerebro-test-redraw-dead*")))
    (kill-buffer buffer)
    (should-not (cerebro--redraw buffer (lambda () (error "must not run"))))))

(ert-deftest cerebro-test/g-in-the-list-goes-through-the-same-redraw ()
  "`g' and the tick must not diverge: both reach the panel through the one
redraw step, or a fix to it stops covering one of them."
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
    (let ((list-buffer (generate-new-buffer " *cerebro-test-list-redraw*"))
          (redrawn nil))
      (unwind-protect
          (with-current-buffer list-buffer
            (cerebro-mode)
            (cl-letf (((symbol-function 'cerebro--redraw)
                       (lambda (buffer _draw) (push buffer redrawn))))
              (revert-buffer))
            (should (equal redrawn (list list-buffer))))
        (kill-buffer list-buffer)))))

(ert-deftest cerebro-test/tick-refreshes-the-panel-only-when-due ()
  "The panel and the sweeps keep their own cadences even though the list is
driven every five seconds - a five-second panel would triple `bd's load for
nothing a human would notice.  Neither blocks any more, so the two cadences
run independently: a sweep draws through `cerebro--draw-beads', not a second
`cerebro--beads-render', so a tick where both are due still counts one
panel render."
  (let ((list-calls 0) (supervise-calls 0) (panel-calls 0) (sweep-calls 0))
    (cl-letf (((symbol-function 'cerebro--list-render) (lambda (_buffer) (cl-incf list-calls)))
              ((symbol-function 'cerebro--supervise) (lambda (&rest _) (cl-incf supervise-calls)))
              ((symbol-function 'cerebro--beads-render) (lambda (_buffer) (cl-incf panel-calls)))
              ((symbol-function 'cerebro--request-sweeps)
               (lambda (_root callback)
                 (cl-incf sweep-calls)
                 (funcall callback (list nil))
                 'started))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
      (let ((list-buffer (generate-new-buffer " *cerebro-test-tick-list*"))
            (panel (generate-new-buffer cerebro-beads-buffer-name)))
        (unwind-protect
            (progn
              (with-current-buffer list-buffer (cerebro-mode))
              (with-current-buffer panel (cerebro-beads-mode))
              ;; T: nothing rendered yet, so both the panel and the sweeps are
              ;; due - and the panel is still rendered exactly once.
              (cerebro--tick list-buffer (seconds-to-time 1000))
              (should (= list-calls 1))
              (should (= supervise-calls 1))
              (should (= panel-calls 1))
              (should (= sweep-calls 1))
              ;; T+5: neither cadence is up yet.
              (cerebro--tick list-buffer (seconds-to-time 1005))
              (should (= list-calls 2))
              (should (= supervise-calls 2))
              (should (= panel-calls 1))
              (should (= sweep-calls 1))
              ;; T+30: the panel's thirty seconds are up; the sweeps' are not.
              (cerebro--tick list-buffer (seconds-to-time 1030))
              (should (= panel-calls 2))
              (should (= sweep-calls 1))
              ;; T+1000: the sweeps' ten minutes are up too - both fire.
              (cerebro--tick list-buffer (seconds-to-time 2000))
              (should (= panel-calls 3))
              (should (= sweep-calls 2)))
          (kill-buffer list-buffer)
          (kill-buffer panel))))))

(ert-deftest cerebro-test/tick-asks-gh-in-the-fleet-buffer ()
  "The reader's answers are what `cerebro--trigger-context' reads, and that
runs in the fleet buffer - so the tick asks from there, on the fleet
buffer's own cadence rather than the panel's."
  (let ((asked nil))
    (cl-letf (((symbol-function 'cerebro--list-render) #'ignore)
              ((symbol-function 'cerebro--supervise) (lambda (&rest _) nil))
              ((symbol-function 'cerebro--start-due) (lambda (&rest _) nil))
              ((symbol-function 'cerebro--refresh-gh-when-due)
               (lambda (buffer seconds) (push (cons buffer seconds) asked)))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
      (let ((list-buffer (generate-new-buffer " *cerebro-test-tick-gh*")))
        (unwind-protect
            (progn
              (with-current-buffer list-buffer (cerebro-mode))
              (cerebro--tick list-buffer (seconds-to-time 1000))
              (should (equal asked (list (cons list-buffer 1000.0)))))
          (kill-buffer list-buffer))))))

(ert-deftest cerebro-test/tick-skips-a-dead-panel-and-keeps-going ()
  "The panel buffer may not exist yet, or may have been killed by hand; the
list must still refresh and supervise without error."
  (cl-letf (((symbol-function 'cerebro--list-render) #'ignore)
            ((symbol-function 'cerebro--supervise) #'ignore)
            ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
    (let ((list-buffer (generate-new-buffer " *cerebro-test-tick-no-panel*")))
      (unwind-protect
          (progn
            (with-current-buffer list-buffer (cerebro-mode))
            (when (get-buffer cerebro-beads-buffer-name)
              (kill-buffer cerebro-beads-buffer-name))
            (should-not (cerebro--tick list-buffer (seconds-to-time 1000))))
        (kill-buffer list-buffer)))))

(ert-deftest cerebro-test/on-demand-redraws-do-not-postpone-the-timed-one ()
  "A `g' or a priority change must not push the next timer refresh back, or a
navigator who redraws by hand every twenty seconds would never see one."
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
            ((symbol-function 'cerebro--request-beads)
             (lambda (_root cb) (funcall cb (cerebro-test--buckets)) 'started))
            ((symbol-function 'cerebro--sweep) #'ignore)
            ((symbol-function 'cerebro--list-render) #'ignore)
            ((symbol-function 'cerebro--supervise) #'ignore))
    (let ((list-buffer (generate-new-buffer " *cerebro-test-tick-postpone*"))
          (panel (generate-new-buffer cerebro-beads-buffer-name)))
      (unwind-protect
          (progn
            (with-current-buffer list-buffer (cerebro-mode))
            (with-current-buffer panel (cerebro-beads-mode))
            (cerebro--tick list-buffer (seconds-to-time 1000))
            (should (= (with-current-buffer panel cerebro--beads-rendered-at) 1000.0))
            ;; An on-demand redraw, as `g' or a priority change causes, must
            ;; not move the timestamp the tick uses to decide it is due.
            (with-current-buffer panel (cerebro--beads-render panel))
            (should (= (with-current-buffer panel cerebro--beads-rendered-at) 1000.0))
            ;; T+30: the timed refresh still fires since the stamp did not move.
            (cerebro--tick list-buffer (seconds-to-time 1030))
            (should (= (with-current-buffer panel cerebro--beads-rendered-at) 1030.0)))
        (kill-buffer list-buffer)
        (kill-buffer panel)))))

;; ---------------------------------------------------------------------------
;; ah-9dv: the process scan runs on its own, slower cadence

(ert-deftest cerebro-test/system-processes-are-rescanned-every-thirty-seconds-not-five ()
  "The scan used to be on the five-second tick; it now keeps its own
thirty-second cadence, the same as the bead panel's.  It returns (PID . ARGS)
pairs since cb-63m - there is no strings-only reader left, `cerebro--revert'
taking `(mapcar #\='cdr procs)' where it needs them - and the cadence had to
survive that change."
  (let ((calls 0) (buffer (generate-new-buffer " *cerebro-test-system-processes*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--system-processes)
                   (lambda () (cl-incf calls) '((1 . "fake args")))))
          (with-current-buffer buffer
            (cerebro--cached-system-processes 1000.0)
            (should (= calls 1))
            (cerebro--cached-system-processes 1005.0)
            (should (= calls 1))
            (cerebro--cached-system-processes 1031.0)
            (should (= calls 2))))
      (kill-buffer buffer))))

;; ---------------------------------------------------------------------------
;; A pid is only alive if it is still *this agent's* session
;;
;; Seen live: Rogue finished ah-6uo at 02:43, its session ended, and the state
;; file stayed behind saying `done' with pid 92395. By morning macOS had reused
;; that pid for an unrelated system daemon, so the row read `done' - green, and
;; `s' refused it as "running outside Emacs" - for a session that had not
;; existed for ten hours.

(defun cerebro-test--session-of (owner)
  "A liveness predicate that only believes a pid belongs to OWNER."
  (lambda (_pid name) (equal name owner)))

(ert-deftest cerebro-test/recycled-pid-does-not-keep-an-implementer-alive ()
  (let* ((states '(("Rogue" . ((state . "waiting") (bead . "ah-6uo")
                               (since . "2026-08-16T02:43:32Z") (pid . 92395)))))
         (agent (car (cerebro--derive '("Rogue") nil states
                                      (cerebro-test--session-of "somebody-else")
                                      nil nil))))
    (should (eq (cerebro-agent-state agent) 'dead))
    (should-not (cerebro-agent-bead agent))))

(ert-deftest cerebro-test/a-pid-that-is-still-the-agents-own-session-is-alive ()
  "The other half of the same test: the check must not simply say dead."
  (let* ((states '(("Rogue" . ((state . "working") (bead . "ah-6uo")
                               (since . "2026-08-16T02:43:32Z") (pid . 92395)))))
         (agent (car (cerebro--derive '("Rogue") nil states
                                      (cerebro-test--session-of "Rogue")
                                      nil nil))))
    (should (eq (cerebro-agent-state agent) 'working))
    (should (equal (cerebro-agent-bead agent) "ah-6uo"))))

(ert-deftest cerebro-test/liveness-is-asked-about-the-pid-and-the-name ()
  "The contract the impure `cerebro--session-alive-p' implements."
  (let ((asked nil))
    (cerebro--derive '("Rogue") '(("Xavier" . "planner"))
                     '(("Rogue" . ((state . "working") (pid . 92395)))
                       ("Xavier" . ((state . "working") (pid . 27123))))
                     (lambda (pid name) (push (cons pid name) asked) t)
                     nil nil)
    (should (member '(92395 . "Rogue") asked))
    (should (member '(27123 . "Xavier") asked))))

(ert-deftest cerebro-test/recycled-pid-falls-back-to-the-scan-for-an-interactive-agent ()
  "An interactive row reads its file first and the process scan second; a pid
that is no longer that agent's session must drop through to the scan rather
than dressing a dead session in the file's `working'."
  (let ((states '(("Xavier" . ((state . "working") (phase . "plan")
                               (bead . "ah-1") (pid . 92395))))))
    (should (eq (cerebro-agent-state
                 (car (cerebro--derive nil '(("Xavier" . "planner")) states
                                       (cerebro-test--session-of "somebody-else")
                                       nil nil)))
                'dead))
    (should (eq (cerebro-agent-state
                 (car (cerebro--derive nil '(("Xavier" . "planner")) states
                                       (cerebro-test--session-of "somebody-else")
                                       '("claude --name Xavier --agent planner This session is Xavier of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.") nil)))
                'up))))

(defvar cerebro-test--fake-session-script nil
  "Path to a script file the liveness fixtures below run as a fake session.")

(defun cerebro-test--fake-session (&rest args)
  "Start a live process whose command line is ARGS, and return it.

A script FILE, never `bash -c\=': bash\='s exec optimisation can replace itself
with the simple command it was given, taking every argument with it, and the
fixtures here exist precisely to be read back out of the process table.
`tests/agent-alive.sh\=' records the same recipe for the same reason."
  (unless (and cerebro-test--fake-session-script
               (file-exists-p cerebro-test--fake-session-script))
    (let ((path (make-temp-file "cerebro-test-fake-session" nil ".sh")))
      (with-temp-file path (insert "#!/usr/bin/env bash\nsleep 30\n"))
      (set-file-modes path #o755)
      (setq cerebro-test--fake-session-script path)))
  (apply #'start-process "cerebro-test-session" nil
         "bash" cerebro-test--fake-session-script args))

(ert-deftest cerebro-test/session-alive-p-rejects-a-pid-that-is-not-that-session ()
  "The impure half, against this very Emacs: alive, certainly, and not Rogue."
  (should-not (cerebro--session-alive-p (emacs-pid) "Rogue" "/Users/x/repos/cerebro"))
  (should-not (cerebro--session-alive-p nil "Rogue" "/Users/x/repos/cerebro")))

(ert-deftest cerebro-test/session-alive-p-accepts-the-agents-own-process ()
  "A real process whose command line carries the marker for Rogue, rooted here."
  (let ((process (cerebro-test--fake-session "--name" "Rogue"
                                "This session is Rogue of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.")))
    (unwind-protect
        (should (cerebro--session-alive-p (process-id process) "Rogue" "/Users/x/repos/cerebro"))
      (delete-process process))))

(ert-deftest cerebro-test/session-alive-p-rejects-the-same-name-in-another-consumer ()
  "The cross product 7bd5962 and 9420ff2 each left open (cb-lzi).
A live pid whose command line names this agent, but under ANOTHER consumer's
root, is not `proven' this consumer's session - and since ah-ybsr it is not
flatly `nil' either: the args carry a cerebro marker naming Rogue, so this is
exactly the `unverified' case (a cerebro session of this name that this
checkout cannot prove is its own), not the recycled-pid `nil' case. Read as
a generalised boolean it is truthy - `cerebro--live-sessions' now counts it
as live, which is the deliberate trade the bead's plan calls out: the sweeps'
failure mode becomes \"leaves a bead alone\" rather than \"clears a live
implementer's assignee\"."
  (let ((process (cerebro-test--fake-session "--name" "Rogue"
                                "This session is Rogue of the cerebro fleet rooted at /Users/x/repos/atlantis-hud/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.")))
    (unwind-protect
        (progn
          (should (eq (cerebro--session-alive-p (process-id process) "Rogue" "/Users/x/repos/cerebro")
                      'unverified))
          (should (eq (cerebro--session-alive-p (process-id process) "Rogue" "/Users/x/repos/atlantis-hud")
                      t)))
      (delete-process process))))

(ert-deftest cerebro-test/session-alive-p-rejects-a-session-carrying-no-marker ()
  "A hand-typed `claude --name Rogue' carries no cerebro marker at all, and
since cb-d59.3 the marker is the whole rule: a provider's flag is no longer
evidence, so this is flatly `nil' rather than `unverified'.  That is the
epic's accepted cost (cb-d59, decision 4) - a session started outside the
fleet reads dead, where before it read `unverified'."
  (let ((process (cerebro-test--fake-session "--name" "Rogue")))
    (unwind-protect
        (should (eq (cerebro--session-alive-p (process-id process) "Rogue" "/Users/x/repos/cerebro")
                    nil))
      (delete-process process))))

(ert-deftest cerebro-test/session-liveness-unverified-when-the-marker-names-another-root ()
  "`cerebro--session-args-p' says no when the marker names the agent but roots
it somewhere that is not this consumer - that used to mean flatly dead.
`cerebro--session-liveness' has to tell that case apart from one that carries
no marker at all (`nil', positive evidence against - the recycled-pid case)
so a caller can trust the state file rather than substitute a default
\(ah-ybsr, re-keyed by cb-d59.3)."
  ;; a cerebro session of this name, rooted elsewhere: `unverified'.
  (let ((process (cerebro-test--fake-session
                                "This session is Storm of the cerebro fleet rooted at /Users/x/repos/atlantis-hud/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.")))
    (unwind-protect
        (should (eq (cerebro--session-liveness (process-id process) "Storm" "/Users/x/repos/cerebro")
                    'unverified))
      (delete-process process)))
  ;; no marker at all: `nil', not `unverified' - the recycled-pid case must
  ;; stay positive evidence against.
  (let ((process (cerebro-test--fake-session "--name" "Somebody-else")))
    (unwind-protect
        (should (eq (cerebro--session-liveness (process-id process) "Storm" "/Users/x/repos/cerebro")
                    nil))
      (delete-process process)))
  ;; both: `proven', same as `cerebro--session-args-p' already says yes to.
  (let ((process (cerebro-test--fake-session "--name" "Storm"
                                "This session is Storm of the cerebro fleet rooted at /Users/x/repos/cerebro/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.")))
    (unwind-protect
        (should (eq (cerebro--session-liveness (process-id process) "Storm" "/Users/x/repos/cerebro")
                    'proven))
      (delete-process process))))

(ert-deftest cerebro-test/session-alive-p-returns-unverified-through-the-compatibility-contract ()
  "`cerebro--session-alive-p' keeps its generalised-boolean contract: `t' for
`proven', the symbol `unverified' for `unverified', so every existing caller
and every ERT test that injects `(lambda (pid name) t)' keeps working
unchanged - `t' is non-nil and is not `eq' to `unverified'."
  (let ((process (cerebro-test--fake-session
                                "This session is Storm of the cerebro fleet rooted at /Users/x/repos/atlantis-hud/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.")))
    (unwind-protect
        (let ((result (cerebro--session-alive-p (process-id process) "Storm" "/Users/x/repos/cerebro")))
          (should (eq result 'unverified))
          (should result))
      (delete-process process))))

;; ---------------------------------------------------------------------------
;; Ending a session on purpose takes its state file with it

(ert-deftest cerebro-test/retire-removes-the-state-file ()
  "The file describes a session that is over; left behind, it is what the pid
recycling above turns into a phantom row (see the tests just above)."
  (let ((root (make-temp-file "cerebro-test-" t))
        (agent (cerebro-test--supervised 'idle)))
    (unwind-protect
        (let ((path (cerebro--state-file-path root "Cyclops")))
          (make-directory (file-name-directory path) t)
          (write-region "{\"state\":\"idle\",\"pid\":42}" nil path nil 'quiet)
          (cerebro--write-stop-flag root "Cyclops")
          (cl-letf (((symbol-function 'cerebro--forget-session) (lambda (_a) nil))
                    ((symbol-function 'cerebro--launch) (lambda (&rest _) nil)))
            (with-temp-buffer
              (cerebro--supervise (list agent) root cerebro-test--now '(supervising))))
          (should-not (file-exists-p path)))
      (delete-directory root t))))

(ert-deftest cerebro-test/kill-removes-the-state-file ()
  "`k' is a full session-end, so it takes the state file with it.

Left behind, the file keeps the row reading `working' on a bead nobody is
building, and once the operating system recycles that pid the row goes
green for an unrelated process (`cerebro--session-alive-p')."
  (let* ((cerebro--sessions nil)
         (root (make-temp-file "cerebro-test-" t))
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (buf (get-buffer-create session-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'revert-buffer) #'ignore)
                  ((symbol-function 'cerebro--show-detail) #'ignore))
          (let ((path (cerebro--state-file-path root "Cyclops")))
            (make-directory (file-name-directory path) t)
            (write-region "{\"state\":\"working\",\"pid\":42}" nil path nil 'quiet)
            (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
            (cerebro--kill-session-buffer agent root)
            (should-not (file-exists-p path))
            (should (null (get-buffer session-name)))))
      (when (get-buffer session-name) (kill-buffer session-name))
      (delete-directory root t))))

(ert-deftest cerebro-test/end-session-removes-the-state-file ()
  "The one owner removes buffer, session entry and state file together."
  (let* ((cerebro--sessions nil)
         (root (make-temp-file "cerebro-test-" t))
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (buf (get-buffer-create session-name)))
    (unwind-protect
        (let ((path (cerebro--state-file-path root "Cyclops")))
          (make-directory (file-name-directory path) t)
          (write-region "{\"state\":\"working\",\"pid\":42}" nil path nil 'quiet)
          (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
          (cerebro--end-session agent root)
          (should (null (get-buffer session-name)))
          (should (null (alist-get "Cyclops" cerebro--sessions nil nil #'equal)))
          (should-not (file-exists-p path)))
      (when (get-buffer session-name) (kill-buffer session-name))
      (delete-directory root t))))

(ert-deftest cerebro-test/end-session-leaves-the-stop-flag-unless-asked ()
  "The flag is opt-in, so a flag written between a restart being decided and
this running - the navigator pressing `f' - is not swallowed."
  (let* ((cerebro--sessions nil)
         (root (make-temp-file "cerebro-test-" t))
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working)))
    (unwind-protect
        (progn
          (cerebro--write-stop-flag root "Cyclops")
          (cerebro--end-session agent root)
          (should (cerebro--stop-flag-p root "Cyclops")))
      (delete-directory root t))))

(ert-deftest cerebro-test/end-session-clears-the-stop-flag-when-asked ()
  "Retire's half of the same contract: the flag has done its job by then."
  (let* ((cerebro--sessions nil)
         (root (make-temp-file "cerebro-test-" t))
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working)))
    (unwind-protect
        (progn
          (cerebro--write-stop-flag root "Cyclops")
          (cerebro--end-session agent root 'clear-stop-flag)
          (should-not (cerebro--stop-flag-p root "Cyclops")))
      (delete-directory root t))))

(ert-deftest cerebro-test/kill-leaves-the-stop-flag ()
  "`f' then `k' means stop now and stay gone; `s' is what clears a stale flag,
and it says so when it does."
  (let* ((cerebro--sessions nil)
         (root (make-temp-file "cerebro-test-" t))
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working)))
    (unwind-protect
        (cl-letf (((symbol-function 'revert-buffer) #'ignore)
                  ((symbol-function 'cerebro--show-detail) #'ignore))
          (cerebro--write-stop-flag root "Cyclops")
          (cerebro--kill-session-buffer agent root)
          (should (cerebro--stop-flag-p root "Cyclops")))
      (delete-directory root t))))

(ert-deftest cerebro-test/delete-state-file-tolerates-a-missing-file ()
  "Same race as `cerebro--clear-stop-flag': the agent, another Emacs or a
shell can remove it between a check and the delete."
  (let ((root (make-temp-file "cerebro-test-" t)))
    (unwind-protect
        (should-not (cerebro--delete-state-file root "Cyclops"))
      (delete-directory root t))))

(provide 'cerebro-test)
;;; cerebro-test.el ends here

;; ---------------------------------------------------------------------------
;; ah-hiib.2: the History section - a renderer over `scripts/fleet-history --summary'

(ert-deftest cerebro-test/history-section-renders-what-is-running-now ()
  "Per agent, the state it is in and how long it has been there. The rows come
from the script; nothing here shells out or computes a duration."
  (let ((lines (cerebro--history-section
                '(((agent . "Cyclops") (state . "working") (count . 12)
                   (total_min . 300) (median_min . 20) (max_min . 90) (open_min . 21))
                  ((agent . "Storm") (state . "asking") (count . 3)
                   (total_min . 330) (median_min . 20) (max_min . 300) (open_min . 300))))))
    (should (equal "History" (substring-no-properties (car lines))))
    (should (= 3 (length lines)))
    (should (string-match-p "Cyclops" (nth 1 lines)))
    (should (string-match-p "working" (nth 1 lines)))
    (should (string-match-p "21m" (nth 1 lines)))))

(ert-deftest cerebro-test/history-section-marks-an-interval-that-has-run-long ()
  "The point of the whole family: an interval past what is typical for that
state is marked, and one merely past the median is not - the median is
exceeded half the time by construction, so marking on it would mark half of
every ordinary day."
  (let* ((lines (cerebro--history-section
                 '(((agent . "Cyclops") (state . "working") (median_min . 20) (open_min . 21)
                    (count . 12) (total_min . 300) (max_min . 90))
                   ((agent . "Storm") (state . "asking") (median_min . 20) (open_min . 300)
                    (count . 3) (total_min . 330) (max_min . 300)))))
         (typical (substring-no-properties (nth 1 lines)))
         (long (substring-no-properties (nth 2 lines))))
    (should-not (string-match-p "long" typical))
    (should (string-match-p "long" long))
    (should (string-match-p "median 20m" long))))

(ert-deftest cerebro-test/history-section-shows-nothing-at-all-when-nothing-is-running ()
  "No rows, or rows with nothing open, render no header and no line - the same
judgement `cerebro--sweep-section' makes, and for the same reason: a section
printing \"(none)\" every five minutes is noise."
  (should (null (cerebro--history-section nil)))
  (should (null (cerebro--history-section
                 '(((agent . "Cyclops") (state . "working") (count . 12)
                    (total_min . 300) (median_min . 20) (max_min . 90) (open_min . nil)))))))

(ert-deftest cerebro-test/history-does-not-recompute-inside-its-interval ()
  "The tick is five seconds and the log can be large, so the History section
runs the script on a cadence of its own.

Driven through `cerebro--refresh-panel-when-due' rather than by asserting
`cerebro--due-p' directly: the gate is the thing that can be got wrong, and a
test of the predicate alone would pass just as happily with the gate deleted
and the script run sixty times a minute."
  (let ((history-calls 0))
    (cl-letf (((symbol-function 'cerebro--beads-render) (lambda (_buffer) nil))
              ((symbol-function 'cerebro--sweep) (lambda (_buffer) nil))
              ((symbol-function 'cerebro--history) (lambda (_buffer) (cl-incf history-calls))))
      (let ((panel (generate-new-buffer " *cerebro-test-history-cadence*")))
        (unwind-protect
            (with-current-buffer panel
              (cerebro-beads-mode)
              ;; Nothing run yet, so it is due.
              (cerebro--refresh-panel-when-due panel 1000.0)
              (should (= history-calls 1))
              ;; A tick five seconds later, and one a second short of the
              ;; interval: neither re-runs it.
              (cerebro--refresh-panel-when-due panel 1005.0)
              (cerebro--refresh-panel-when-due
               panel (+ 1000.0 (- cerebro-history-refresh-seconds 1)))
              (should (= history-calls 1))
              ;; And one past it does.
              (cerebro--refresh-panel-when-due
               panel (+ 1000.0 cerebro-history-refresh-seconds))
              (should (= history-calls 2)))
          (kill-buffer panel))))))

(ert-deftest cerebro-test/history-rows-reach-the-panel ()
  "The wiring, end to end: rows kept on the buffer are what the panel draws."
  (let ((lines (cerebro--bead-panel
                (cerebro-test--buckets) 100 3 (current-time) nil
                '(((agent . "Cyclops") (state . "working") (count . 2) (total_min . 10)
                   (median_min . 5) (max_min . 6) (open_min . 40))))))
    (should (cl-some (lambda (l) (string-match-p "History" (substring-no-properties l))) lines))
    (should (cl-some (lambda (l) (string-match-p "Cyclops working 40m" (substring-no-properties l)))
                     lines))))

(ert-deftest cerebro-test/history-an-empty-answer-clears-the-rows ()
  "The other half of the rule below: an answer of \"nothing is running\" must
replace the rows, or a section frozen at what was true five minutes ago outlives
the fleet it describes. Only the absence of an answer preserves them."
  (let ((buffer (get-buffer-create "*cerebro-test-history-empty-answer*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--draw-beads) (lambda (_buffer) nil))
                  ((symbol-function 'cerebro--request-history)
                   (lambda (_root callback) (funcall callback (list nil)) 'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (setq cerebro--history-rows '(((agent . "Cyclops") (state . "working") (open_min . 5))))
            (cerebro--history buffer)
            (should (null cerebro--history-rows))))
      (kill-buffer buffer))))

(ert-deftest cerebro-test/history-keeps-the-last-rows-when-the-script-does-not-answer ()
  "A corrupt log or a missing script leaves the section as it was rather than
replacing a real answer with an empty one - the same rule the sweeps follow."
  (let ((buffer (get-buffer-create "*cerebro-test-history-no-answer*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--request-history)
                   (lambda (_root callback) (funcall callback nil) 'started)))
          (with-current-buffer buffer
            (cerebro-beads-mode)
            (setq cerebro--history-rows '(((agent . "Cyclops") (state . "working") (open_min . 5))))
            (cerebro--history buffer)
            (should (equal cerebro--history-rows
                           '(((agent . "Cyclops") (state . "working") (open_min . 5)))))))
      (kill-buffer buffer))))

;; ---------------------------------------------------------------------------
;; ah-hiib.3: `waiting' - the monitor owns the cadence, the role owns the policy

(defun cerebro-test--waiting (&optional name since external role)
  "An interactive agent in `waiting', for the wake tests."
  (make-cerebro-agent :name (or name "Moira") :role (or role "user-feedback")
                              :kind 'interactive :state 'waiting :bead nil
                              :since (or since "2026-08-14T09:20:00Z")
                              :external external))

(ert-deftest cerebro-test/derives-waiting-from-an-interactive-state-file ()
  "`waiting' is the state a role writes when it has ended its turn."
  (let ((agent (cerebro--derive-from-state
                "Moira" "user-feedback" 'interactive
                '((state . "waiting") (bead . nil) (since . "2026-08-14T09:20:00Z")
                  (pid . 42))
                t)))
    (should (eq (cerebro-agent-state agent) 'waiting))))

(ert-deftest cerebro-test/waiting-from-an-implementer-is-waiting ()
  "Since cb-1or.1 `waiting' is every agent's end-of-pass state, so an
implementer's file carries it the same way a role's does."
  (let ((agent (cerebro--derive-from-state
                "Cyclops" "implementer" 'implementer
                '((state . "waiting") (bead . nil) (since . "2026-08-14T09:20:00Z")
                  (pid . 42))
                t)))
    (should (eq (cerebro-agent-state agent) 'waiting))
    (should (equal (cerebro-agent-raw agent) "waiting"))))

(ert-deftest cerebro-test/the-interval-comes-from-the-custom-variable ()
  (let ((cerebro-wake-intervals '(("Psylocke" . 300)))
        (cerebro-wake-interval-default 600))
    (should (equal (cerebro-wake-interval "Psylocke") 300))
    (should (equal (cerebro-wake-interval "Moira") 600))))

(ert-deftest cerebro-test/supervise-retires-a-waiting-role-under-a-stop-flag ()
  "The behaviour that is impossible while a role sleeps inside its own session:
a waiting role holds no bead, no claim and no worktree, so the flag lands
cleanly and now, whether or not its wake is due."
  (let ((cerebro-wake-interval-default 600)
        (cerebro-wake-intervals nil))
    (should (eq (cerebro--supervise-action
                 (cerebro-test--waiting nil "2026-08-14T09:29:00Z")
                 t cerebro-test--now)
                'retire))
    (should (eq (cerebro--supervise-action
                 (cerebro-test--waiting nil "2026-08-14T09:00:00Z")
                 t cerebro-test--now)
                'retire))))

(ert-deftest cerebro-test/a-waiting-implementer-is-ended-after-the-grace ()
  "The `waiting' arm's kind guard is gone (cb-1or.1): an implementer that has
ended its pass is ended exactly the way a role is - after `cerebro-end-grace',
at once under a stop flag, and never when the session is somebody else's."
  (let ((cerebro-end-grace 30))
    (cl-flet ((implementer (since &optional external)
                (make-cerebro-agent :name "Cyclops" :role "implementer"
                                    :kind 'implementer :state 'waiting
                                    :since since :external external)))
      ;; stood in `waiting' for 31s - past the grace
      (should (eq (cerebro--supervise-action
                   (implementer "2026-08-14T09:29:29Z") nil cerebro-test--now)
                  'end))
      ;; 10s - not yet
      (should (null (cerebro--supervise-action
                     (implementer "2026-08-14T09:29:50Z") nil cerebro-test--now)))
      ;; the flag lands at once, whatever `since' says
      (should (eq (cerebro--supervise-action
                   (implementer "2026-08-14T09:29:50Z") t cerebro-test--now)
                  'retire))
      ;; and a session Emacs does not own is nobody's to end
      (should (null (cerebro--supervise-action
                     (implementer "2026-08-14T09:29:29Z" t) nil cerebro-test--now)))
      (should (null (cerebro--supervise-action
                     (implementer "2026-08-14T09:29:29Z" t) t cerebro-test--now))))))

(ert-deftest cerebro-test/supervise-parks-a-waiting-implementer ()
  "An implementer that ended its pass keeps its buffer, the way a role does:
`cerebro--supervise' parks it rather than ending the session outright, and the
state file - which describes a session that is over - goes with the park."
  (let ((root (make-temp-file "cerebro-test-" t))
        (cerebro-end-grace 30)
        (parked nil)
        (launched nil))
    (unwind-protect
        (let ((path (cerebro--state-file-path root "Cyclops"))
              (agent (make-cerebro-agent :name "Cyclops" :role "implementer"
                                         :kind 'implementer :state 'waiting
                                         :since "2026-08-14T09:00:00Z")))
          (make-directory (file-name-directory path) t)
          (write-region "{\"state\":\"waiting\",\"pid\":42}" nil path nil 'quiet)
          (cl-letf (((symbol-function 'cerebro--park-session)
                     (lambda (a _root _now) (push (cerebro-agent-name a) parked)
                       (delete-file (cerebro--state-file-path _root
                                                              (cerebro-agent-name a)))))
                    ((symbol-function 'cerebro--end-session)
                     (lambda (&rest _) (push 'ended launched)))
                    ((symbol-function 'cerebro--launch)
                     (lambda (&rest _) (push 'launched launched))))
            (with-temp-buffer
              (cerebro--supervise (list agent) root cerebro-test--now '(supervising))))
          (should (equal parked '("Cyclops")))
          (should (null launched))
          (should-not (file-exists-p path)))
      (delete-directory root t))))

(ert-deftest cerebro-test/supervise-retires-a-waiting-implementer-under-a-flag ()
  "The flag says no further bead, so the session is parked - its buffer is the
record of the pass it just finished - the flag cleared, and the name disarmed."
  (let ((root (make-temp-file "cerebro-test-" t))
        (parked nil))
    (unwind-protect
        (let ((agent (make-cerebro-agent :name "Cyclops" :role "implementer"
                                         :kind 'implementer :state 'waiting
                                         :since "2026-08-14T09:29:59Z")))
          (cerebro--write-stop-flag root "Cyclops")
          (cl-letf (((symbol-function 'cerebro--park-session)
                     (lambda (a _root _now) (push (cerebro-agent-name a) parked)))
                    ((symbol-function 'cerebro--end-session)
                     (lambda (&rest _) (push 'ended parked)))
                    ((symbol-function 'cerebro--launch) (lambda (&rest _) nil)))
            (with-temp-buffer
              (setq cerebro--armed (list "Cyclops"))
              (cerebro--supervise (list agent) root cerebro-test--now '(supervising))
              (should (equal parked '("Cyclops")))
              (should-not (member "Cyclops" cerebro--armed))))
          (should-not (cerebro--stop-flag-p root "Cyclops")))
      (delete-directory root t))))

(ert-deftest cerebro-test/an-interactive-role-is-still-never-restarted-or-nudged ()
  "The docstring's warning, pinned: making the guard per-arm must not let
`restart', `retire' or `nudge' reach a role whose mockup conversation with the
navigator would be destroyed by it.

`idle' is absent since cb-5yr - it is one of the two states that end a pass,
and is answered there.  The rest still reach nothing: a role mid-pass, or one
with a state file the view cannot read, is left alone."
  (dolist (state '(unknown asking working))
    (let ((agent (make-cerebro-agent :name "Xavier" :role "planner" :kind 'interactive
                                             :state state :bead "ah-f9c"
                                             :since "2026-08-14T08:00:00Z")))
      (should (null (cerebro--supervise-action agent nil cerebro-test--now)))
      (should (null (cerebro--supervise-action agent t cerebro-test--now))))))

(ert-deftest cerebro-test/a-waiting-role-shows-its-state-and-nothing-else ()
  "Distinguishable from `idle' - which for an implementer means safe to
retire - and, since cb-5yr, carrying no countdown: a waiting role is ended
within `cerebro-end-grace', not woken at a time it named."
  (let* ((agent (cerebro-test--waiting nil "2026-08-14T09:20:00Z"))
         (row (nth 1 (cerebro--entry agent cerebro-test--now))))
    (should (equal (aref row 2) "waiting"))
    (should (equal (aref row 4) "10m"))))

(defun cerebro-test--park-fixture (agent body)
  "Run BODY with a temp repo-root and `cerebro--park-session' recording into
`acted', which is what both the end and the retire branch reach."
  (let ((root (make-temp-file "cerebro-park" t))
        (acted '()))
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'cerebro--park-session)
                     (lambda (a &rest _) (push (cerebro-agent-name a) acted))))
            (funcall body root (lambda () acted) agent)))
      (delete-directory root t))))

(ert-deftest cerebro-test/supervise-retires-a-waiting-role-under-a-flag-at-once ()
  "The flag lands on a waiting role immediately - nothing is in flight - and
the session is parked exactly as an ordinary end parks it, then disarmed."
  (let ((cerebro-end-grace 30))
    (cerebro-test--park-fixture
     (cerebro-test--waiting nil "2026-08-14T09:29:59Z")
     (lambda (root acted agent)
       (setq cerebro--armed (list "Moira"))
       (make-directory (expand-file-name ".cerebro/state" root) t)
       (write-region "" nil (expand-file-name ".cerebro/state/Moira.stop" root))
       (cerebro--supervise (list agent) root cerebro-test--now '(supervising))
       (should (equal (funcall acted) '("Moira")))
       (should-not (member "Moira" cerebro--armed))
       ;; The instruction has been carried out, so it does not outlive it.
       (should-not (file-exists-p (expand-file-name ".cerebro/state/Moira.stop" root)))))))

(ert-deftest cerebro-test/retire-carries-out-the-instruction-before-it-parks ()
  "The instruction first, the record second.

The flag and the arming are what would start the next session; parking is the
step that can signal.  A name told to finish is never started again by a
trigger, whatever happens to its buffer - and the park\='s failure is still
reported, just no longer fatal to the instruction."
  (let ((cerebro-end-grace 30)
        (reported '()))
    (cerebro-test--park-fixture
     (cerebro-test--waiting nil "2026-08-14T09:29:59Z")
     (lambda (root _acted agent)
       (setq cerebro--armed (list "Moira"))
       (make-directory (expand-file-name ".cerebro/state" root) t)
       (write-region "" nil (expand-file-name ".cerebro/state/Moira.stop" root))
       (cl-letf (((symbol-function 'cerebro--park-session)
                  (lambda (&rest _) (error "Selecting deleted buffer")))
                 ((symbol-function 'cerebro--report-error)
                  (lambda (&rest args) (push args reported))))
         ;; Demoted, not signalled: `cerebro--with-logged-errors\=' wraps it.
         (cerebro--supervise (list agent) root cerebro-test--now '(supervising)))
       (should (= 1 (length reported)))
       (should-not (member "Moira" cerebro--armed))
       (should-not (file-exists-p (expand-file-name ".cerebro/state/Moira.stop" root)))))))

(ert-deftest cerebro-test/retire-disarms-an-idle-implementer-before-ending-it ()
  "The implementer branch of retire has the same order: armed is what would
start the next session, so it goes before the step that can fail."
  (let ((reported '())
        (root (make-temp-file "cerebro-retire" t))
        (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'idle)))
    (unwind-protect
        (with-temp-buffer
          (setq cerebro--armed (list "Cyclops"))
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (write-region "" nil (expand-file-name ".cerebro/state/Cyclops.stop" root))
          (cl-letf (((symbol-function 'cerebro--end-session)
                     (lambda (&rest _) (error "Selecting deleted buffer")))
                    ((symbol-function 'cerebro--report-error)
                     (lambda (&rest args) (push args reported))))
            (cerebro--supervise (list agent) root cerebro-test--now '(supervising)))
          (should (= 1 (length reported)))
          (should-not (member "Cyclops" cerebro--armed)))
      (delete-directory root t))))

(ert-deftest cerebro-test/nudge-types-through-the-one-typing-path ()
  "It types through the helper rather than for itself - the only remaining
caller of a path that has twice needed the same fix in two places."
  (let ((calls nil)
        (typed nil)
        (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'asking)))
    (cl-letf (((symbol-function 'cerebro--type-into-session)
               (lambda (a m) (push (cons (cerebro-agent-name a) m) calls)))
              ((symbol-function 'vterm-send-string) (lambda (s) (push s typed))))
      (cerebro--nudge agent)
      (should (equal calls (list (cons "Cyclops" cerebro--nudge-message))))
      (should (null typed)))))

(ert-deftest cerebro-test/the-poke-machinery-is-gone ()
  "cb-5yr deleted it outright: the view no longer types into a waiting session,
it ends it and starts a fresh one.  Byte-compilation is what proves nothing
still calls these; this is what proves they are not quietly still defined."
  (dolist (symbol '(cerebro--poke cerebro--poke-decision cerebro--wake-due-p
                    cerebro--poke-message cerebro-poke-grace cerebro--wake-column
                    cerebro-agent-wake-at))
    (should-not (or (fboundp symbol) (boundp symbol)))))

;; ---------------------------------------------------------------------------
;; ah-qled.9: the project-shaped facts are settings, not constants

(ert-deftest cerebro-test/bd-program-is-a-setting-defaulting-to-bd ()
  "The beads executable is reachable from `M-x customize', not a literal.
Default is today's literal: this bead changes where a value can be set,
never what it is."
  (should (equal (default-value 'cerebro-bd-program) "bd"))
  (should (get 'cerebro-bd-program 'custom-type)))

(ert-deftest cerebro-test/bd-program-reaches-every-argv ()
  "A changed `cerebro-bd-program' reaches every place cerebro spells `bd'.
Seven argv positions were bare literals; a consumer with a wrapper or
another install name got a permanently empty panel with no way in."
  (let ((cerebro-bd-program "my-bd"))
    (should (equal (car (cerebro--bd-list-argv)) "my-bd"))
    (dolist (finding '((close "ah-1" "done")
                       (reclaim "ah-1")
                       (epic-close "ah-1")
                       (unclaim "ah-1")))
      (should (equal (car (cerebro--finding-command finding "/tmp")) "my-bd")))
    (should (equal (car (cerebro--bd-push-argv)) "my-bd"))))

(ert-deftest cerebro-test/the-vocabulary-and-thresholds-are-settings ()
  "The labels, issue types and thresholds cerebro partitions on are the
project's, not universals - so each is a `defcustom', and each default is
exactly today's literal."
  (dolist (pair '((cerebro-verification-settled
                   . ("verification:passed" "verification:not-needed"))
                  (cerebro-planned-label . "planned")
                  (cerebro-planning-label . "planning")
                  (cerebro-skipped-issue-types . ("epic" "event"))
                  (cerebro-priority-floor . 4)
                  (cerebro-stalled-minutes . 60)
                  (cerebro-sweep-stale-minutes . 10)))
    (should (get (car pair) 'custom-type))
    (should (equal (default-value (car pair)) (cdr pair)))))

(ert-deftest cerebro-test/a-changed-planned-label-repartitions-the-panel ()
  "The panel buckets on `cerebro-planned-label', not on the word `planned'."
  (let ((cerebro-planned-label "ready")
        (cerebro-planning-label "drafting"))
    (let* ((buckets
            (cerebro--partition-beads
             '(((id . "a") (status . "open") (issue_type . "task") (labels . ("ready")))
               ((id . "b") (status . "open") (issue_type . "task") (labels . ("drafting")))
               ((id . "c") (status . "open") (issue_type . "task") (labels . ("planned"))))))
           (planned (alist-get 'planned buckets))
           (being-planned (alist-get 'being-planned buckets))
           (unplanned (alist-get 'unplanned buckets)))
      (should (equal (mapcar (lambda (b) (alist-get 'id b)) planned) '("a")))
      (should (equal (mapcar (lambda (b) (alist-get 'id b)) being-planned) '("b")))
      (should (equal (mapcar (lambda (b) (alist-get 'id b)) unplanned) '("c"))))))

(ert-deftest cerebro-test/the-mount-point-is-one-setting-feeding-both-sites ()
  "Mounted anywhere but `.claude/cerebro', `M-x cerebro' simply errored:
the path was hardcoded at the launcher directory and again at the search
for the repository root."
  (should (equal (default-value 'cerebro-submodule-path) ".claude/cerebro"))
  (should (get 'cerebro-submodule-path 'custom-type))
  (let ((cerebro-submodule-path "vendor/cerebro"))
    (should (equal (cerebro--script-directory) "vendor/cerebro/scripts"))
    (should (string-suffix-p "vendor/cerebro/scripts/launch"
                             (cerebro--script "launch")))
    ;; And the root search looks for the mount where it now lives.
    (let* ((root (make-temp-file "cerebro-mount" t))
           (default-directory (file-name-as-directory root)))
      (make-directory (expand-file-name "vendor/cerebro" root) t)
      (should (equal (file-truename (cerebro--repo-root))
                     (file-truename (file-name-as-directory root)))))))

(ert-deftest cerebro-test/wake-intervals-are-keyed-on-role-and-still-honour-a-name ()
  "The five-minute override belonged to a role, not to the agent called
`Psylocke' - a consumer's verifier may be called anything. Name still wins
where one is given, most-specific-first, the way `models.conf' resolves."
  (should (equal (default-value 'cerebro-wake-intervals)
                 '(("verifier" . 300) ("planner" . 0) ("implementer" . 0))))
  (let ((cerebro-wake-interval-default 600)
        (cerebro-wake-intervals '(("verifier" . 300))))
    (should (equal (cerebro-wake-interval "Betsy" "verifier") 300))
    (should (equal (cerebro-wake-interval "Betsy" "planner") 600))
    ;; No role known (an external agent, a torn state file): the default.
    (should (equal (cerebro-wake-interval "Betsy") 600)))
  (let ((cerebro-wake-interval-default 600)
        (cerebro-wake-intervals '(("verifier" . 300) ("Betsy" . 120))))
    (should (equal (cerebro-wake-interval "Betsy" "verifier") 120))))

(ert-deftest cerebro-test/column-widths-match-todays-table-for-todays-fleet ()
  "Computed, not configured - and for this fleet the computation has to
produce exactly the table that is there today, or the promotion pass has
changed behaviour.

The State floor is 12 rather than 10 since cb-63m: `working ■ ×2\=' is twelve
characters, and `tabulated-list-mode\=' truncates a cell at its column
silently - at 10 the marker would be cut off while this test still passed."
  (should (equal (cerebro--column-widths
                  '("Xavier" "Cerebro" "Psylocke" "Wolverine")
                  '("planner" "orchestrator" "verifier" "implementer")
                  '("ah-qled.9" "ah-t65"))
                 '(14 13 12 10 10)))
  (should (= (cerebro--width-for '(14 13 12 10 10)) 61)))

(ert-deftest cerebro-test/column-widths-grow-for-a-long-name-or-a-long-id ()
  "A consumer's names and ids are not this project's. The Bead column is 10
because of `ah-dzj.1.1.1.1'; a nested child one level deeper must widen it
rather than being truncated away."
  (let ((wide (cerebro--column-widths '("Multiple-Man-Duplicate-7")
                                       '("technical-debt-sweeper")
                                       '("ah-dzj.1.1.1.1.1"))))
    (should (> (nth 0 wide) 14))
    (should (> (nth 1 wide) 13))
    (should (> (nth 3 wide) 10))
    ;; And the layout widens with them, or the table would overflow its window.
    (should (> (cerebro--width-for wide) 59))))

(ert-deftest cerebro-test/a-wider-bead-column-shows-the-whole-id ()
  "The width the table was given is the width the cell truncates to."
  (let* ((agent (make-cerebro-agent :name "Storm" :role "implementer"
                                    :kind 'implementer :state 'working
                                    :bead "ah-dzj.1.1.1.1.1"
                                    :since "2026-08-14T09:20:00Z"))
         (row (cerebro--entry agent cerebro-test--now nil 16)))
    (should (equal (substring-no-properties (aref (nth 1 row) 3))
                   "ah-dzj.1.1.1.1.1"))))

(ert-deftest cerebro-test/the-nudge-carries-the-cerebro-prefix ()
  "The nudge is typed into a live session, and every agent is told to
recognise it by the `[cerebro]' prefix - so the prefix is a contract with
the sessions rather than a wording preference."
  (should (string-match-p "\\[cerebro\\]" cerebro--nudge-message)))

(ert-deftest cerebro-test/every-public-constant-left-is-a-buffer-name ()
  "The audit ah-qled.9 closes, kept closed.

A `defconst' whose name is public (`cerebro-', not `cerebro--') is one a
consumer can see and cannot set - which is exactly the shape every project
fact promoted here used to have. The three left are Emacs buffer names, an
internal detail with nothing project-shaped in them; anything else appearing
in this list is a fact that wants a `defcustom'."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "emacs/cerebro.el"))
    (goto-char (point-min))
    (let (public)
      (while (re-search-forward "^(defconst \\(cerebro-[^-][^ \n]*\\)" nil t)
        (push (match-string 1) public))
      (should (equal (sort public #'string<)
                     '("cerebro-bead-buffer-name" "cerebro-beads-buffer-name"
                       "cerebro-buffer-name"))))))

;; ---------------------------------------------------------------------------
;; ah-e0kf: a failed verdict main has moved past

(defun cerebro-test--verdict-candidate (id verified-at merges &optional priority)
  `((id . ,id) (title . "a bead whose verdict may be stale")
    (priority . ,(or priority 0))
    (verified_at . ,verified-at)
    (merges_since . ,merges)))

(ert-deftest cerebro-test/a-verdict-with-no-commit-is-left-alone ()
  "Unknown is not stale. Every verdict recorded before ah-e0kf shipped has no
`verified_at', and a sweep that read absence as staleness would flag the
entire history on its first run."
  (should (null (cerebro--verdict-finding
                 (cerebro-test--verdict-candidate "ah-t2pn.3" nil nil)))))

(ert-deftest cerebro-test/a-commit-not-on-the-branch-is-left-alone ()
  "A distance that is not a number is not a small number. The script says
nil when the commit is missing from the clone, or is not an ancestor of the
default branch - a drifted worktree, a force-push."
  (should (null (cerebro--verdict-finding
                 (cerebro-test--verdict-candidate "ah-t2pn.3" "ce9d2817ab" nil)))))

(ert-deftest cerebro-test/a-verdict-at-the-head-is-left-alone ()
  "Nothing merged since the verdict, so there is nothing to say."
  (should (null (cerebro--verdict-finding
                 (cerebro-test--verdict-candidate "ah-t2pn.3" "ce9d2817ab" 0)))))

(ert-deftest cerebro-test/a-verdict-one-merge-behind-is-offered ()
  "The chosen threshold is one: anything landing on main since the verdict
is enough to be worth a second look."
  (should (equal (cerebro--verdict-finding
                  (cerebro-test--verdict-candidate "ah-vocw" "0b444332cd" 1))
                 '(recheck "ah-vocw" 0))))

(ert-deftest cerebro-test/a-verdict-many-merges-behind-is-offered ()
  "ah-fjty on 2026-08-23: six merges after the verdict, and the two causes a
planner's audit named were both correct behaviour introduced after it."
  (should (equal (cerebro--verdict-finding
                  (cerebro-test--verdict-candidate "ah-fjty" "dd3f67bdef" 6))
                 '(recheck "ah-fjty" 0))))

(ert-deftest cerebro-test/verdict-finding-carries-the-priority-it-was-given ()
  "As `cerebro--assignee-finding' does, and for the same reason:
`cerebro--sweep-line' is given nothing but the finding and needs it."
  (should (equal (cerebro--verdict-finding
                  (cerebro-test--verdict-candidate "ah-zzz" "0b444332cd" 2 2))
                 '(recheck "ah-zzz" 2))))

(ert-deftest cerebro-test/verdict-label-names-the-commit-and-the-distance ()
  "Both lines ship verbatim; the navigator chose this wording. The singular
is not optional - the threshold is one, so `1 merge since' is the most
common line this sweep will ever print."
  (should (equal (cerebro--sweep-label
                  '(recheck "ah-t2pn.3" 0)
                  (cerebro-test--verdict-candidate
                   "ah-t2pn.3" "ce9d2817ab7f3e0d1c2b" 4))
                 "recheck ah-t2pn.3 — verdict at ce9d2817, 4 merges since"))
  (should (equal (cerebro--sweep-label
                  '(recheck "ah-fjty" 0)
                  (cerebro-test--verdict-candidate
                   "ah-fjty" "dd3f67bd1a2b3c4d5e6f" 1))
                 "recheck ah-fjty — verdict at dd3f67bd, 1 merge since")))

(ert-deftest cerebro-test/a-stale-p0-verdict-line-shouts-and-others-do-not ()
  "The same `warning' face ah-kjfm shipped for a stranded assignee, and
nothing more."
  (should (eq 'warning
              (get-text-property 0 'face
                                 (cerebro--sweep-line "recheck ah-fjty — x"
                                                      '(recheck "ah-fjty" 0)))))
  (should-not (get-text-property 0 'face
                                 (cerebro--sweep-line "recheck ah-zzz — x"
                                                      '(recheck "ah-zzz" 2)))))

(ert-deftest cerebro-test/verdict-finding-command-flags-the-verdict-stale ()
  "The one write this bead adds, and the only place it may live. A dimension
of its own: `verification:' is a bd state dimension and `bd set-state'
replaces it, so a `verification=stale' would erase the verdict itself."
  (should (equal (cerebro--finding-command '(recheck "ah-vocw" 0) "/repo")
                 '("bd" "set-state" "ah-vocw" "verdict=stale"
                   "--reason" "verdict formed against a commit main has moved past"))))

;; ---------------------------------------------------------------------------
;; cb-5yr.1: the interactive roles are ended after a pass and started again on
;; a trigger of their own.  Standby is what the row shows in between.

(defun cerebro-test--interactive (name role state &optional external since)
  (make-cerebro-agent :name name :role role :kind 'interactive :state state
                              :since since :external external))

(ert-deftest cerebro-test/apply-standby-restates-an-armed-dead-role ()
  "Standby is derived, never read from a file: the view deleted the state file
when it ended the session, so `cerebro--armed' is the only thing that can say
this role is coming back."
  (let* ((armed '("Psylocke"))
         (agents (list (cerebro-test--interactive "Psylocke" "verifier" 'dead)
                       (cerebro-test--interactive "Moira" "user-feedback" 'dead)
                       (cerebro-test--interactive "Cypher" "reviewer" 'dead t)
                       (cerebro-test--interactive "Xavier" "planner" 'waiting)
                       (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead)))
         (out (cerebro--apply-standby agents (append armed '("Cypher" "Cyclops")))))
    ;; Armed, dead, interactive, ours: standby.
    (should (eq (cerebro-agent-state (nth 0 out)) 'standby))
    ;; Dead but never started this Emacs: still dead.
    (should (eq (cerebro-agent-state (nth 1 out)) 'dead))
    ;; Running outside Emacs: not ours to restate or to restart.
    (should (eq (cerebro-agent-state (nth 2 out)) 'dead))
    ;; A live role is whatever its state file said.
    (should (eq (cerebro-agent-state (nth 3 out)) 'waiting))
    ;; An armed implementer whose session died without ending its pass is on
    ;; standby too (cb-hzs).
    (should (eq (cerebro-agent-state (nth 4 out)) 'standby))
    ;; Pure: the input list is not mutated.
    (should (eq (cerebro-agent-state (nth 0 agents)) 'dead))))

(ert-deftest cerebro-test/apply-standby-restates-an-armed-dead-implementer ()
  "The cb-eat rule holds for an implementer exactly as it does for a role: a
session that printed a reason on the way out stays dead with that line until
`s', and only one that simply went away is promised a retry."
  (let* ((agents (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead)
                       (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead)
                       (cerebro-test--agent "Storm" "implementer" 'implementer 'dead)))
         (out (cerebro--apply-standby agents '("Cyclops" "Rogue") '("Rogue"))))
    (should (eq (cerebro-agent-state (nth 0 out)) 'standby))
    ;; Armed, but it died abnormally: dead, with its line on the row.
    (should (eq (cerebro-agent-state (nth 1 out)) 'dead))
    ;; Never started by this Emacs.
    (should (eq (cerebro-agent-state (nth 2 out)) 'dead))))

(ert-deftest cerebro-test/up-names-are-every-agent-with-a-session ()
  "Every state but `dead' and `standby' is up, whatever the kind.

An agent with no kept buffer and no `cerebro--parked' entry - one whose park
failed, or whose session simply died - has \"when did the last pass end\"
answered by whether the view ever saw the session up.  That was an
implementer's question alone until cb-b4m, when every interactive role turned
out to reach the same path: with nil `ended-at', Moira's condition read every
open issue as moved and started her every ten minutes for a day."
  (should (equal (cerebro--up-names
                  (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working)
                        (cerebro-test--agent "Rogue" "implementer" 'implementer 'idle)
                        (cerebro-test--agent "Storm" "implementer" 'implementer 'asking)
                        (cerebro-test--agent "Gambit" "implementer" 'implementer 'waiting)
                        (cerebro-test--agent "Jubilee" "implementer" 'implementer 'unknown)
                        (cerebro-test--agent "Bishop" "implementer" 'implementer 'dead)
                        (cerebro-test--agent "Iceman" "implementer" 'implementer 'standby)
                        (cerebro-test--interactive "Psylocke" "verifier" 'idle)
                        (cerebro-test--interactive "Moira" "user-feedback" 'standby)
                        (cerebro-test--interactive "Cypher" "reviewer" 'dead)))
                 '("Cyclops" "Rogue" "Storm" "Gambit" "Jubilee" "Psylocke"))))

(ert-deftest cerebro-test/an-interactive-context-falls-back-to-when-it-was-last-seen-up ()
  "An interactive role\='s `ended-at' is its park when it has one, and the last
tick that saw it up when it has not.

The fallback was an implementer's alone, and a role with no parked entry got
nil - which `cerebro--gh-moved' read as \"everything moved\" (cb-b4m).  A park
that throws, a session that died, an Emacs restarted mid-pass: each leaves a
role with no entry, and none of them means the world is new."
  (with-temp-buffer
    (setq cerebro--seen-up '(("Moira" . 5.0))
          cerebro--parked nil)
    (let ((mine (cerebro--agent-context
                 (cerebro-test--interactive "Moira" "user-feedback" 'standby)
                 (list (cons 'now 10.0) (cons 'gh nil)))))
      (should (equal (alist-get 'ended-at mine) 5.0)))
    ;; The park outranks it: it is the moment the pass actually ended.
    (setq cerebro--parked '(("Moira" . (7.0 4.0 nil))))
    (let ((mine (cerebro--agent-context
                 (cerebro-test--interactive "Moira" "user-feedback" 'standby)
                 (list (cons 'now 10.0) (cons 'gh nil)))))
      (should (equal (alist-get 'ended-at mine) 7.0)))
    ;; Neither: nil, and every rule measured against it reads "nothing".
    (setq cerebro--seen-up nil cerebro--parked nil)
    (let ((mine (cerebro--agent-context
                 (cerebro-test--interactive "Moira" "user-feedback" 'standby)
                 (list (cons 'now 10.0) (cons 'gh nil)))))
      (should (null (alist-get 'ended-at mine))))))

(ert-deftest cerebro-test/an-implementer-context-prefers-its-parked-entry ()
  "An implementer that ended its pass is parked like a role since cb-1or.1, so
its `ended-at' is the park.  Only one whose session simply died has no parked
entry, and there `cerebro--seen-up' still answers."
  (with-temp-buffer
    (setq cerebro--seen-up '(("Cyclops" . 5.0))
          cerebro--parked '(("Cyclops" . (7.0 4.0 nil))))
    (let ((mine (cerebro--agent-context
                 (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)
                 (list (cons 'now 10.0) (cons 'gh nil)))))
      (should (equal (alist-get 'ended-at mine) 7.0)))
    (setq cerebro--parked nil)
    (let ((mine (cerebro--agent-context
                 (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)
                 (list (cons 'now 10.0) (cons 'gh nil)))))
      (should (equal (alist-get 'ended-at mine) 5.0)))))

(ert-deftest cerebro-test/an-implementer-context-ends-when-it-was-last-seen-up ()
  "`ended-at' is what `cerebro--start-failed-p' compares a start against.  A
role's comes from `cerebro--parked'; an implementer whose session died has
none, so it is when the view last derived its session as up."
  (with-temp-buffer
    (setq cerebro--seen-up '(("Cyclops" . 5.0))
          cerebro--failed-starts '(("Cyclops" . 2))
          cerebro--started-at '(("Cyclops" . 4.0) ("Psylocke" . 1.0))
          cerebro--parked '(("Psylocke" . (9.0 1.0 nil))))
    (let ((context (list (cons 'now 10.0) (cons 'gh nil))))
      (let ((mine (cerebro--agent-context
                   (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)
                   context)))
        (should (equal (alist-get 'ended-at mine) 5.0))
        (should (equal (alist-get 'failed-starts mine) 2)))
      (let ((hers (cerebro--agent-context
                   (cerebro-test--interactive "Psylocke" "verifier" 'standby)
                   context)))
        (should (equal (alist-get 'ended-at hers) 9.0))
        ;; A name with no failures reads zero rather than nil: it indexes
        ;; the backoff schedule.
        (should (equal (alist-get 'failed-starts hers) 0))))))

(ert-deftest cerebro-test/an-interactive-context-measures-linked-beads-against-its-own-pass ()
  "`linked-moved' is `linked' filtered by this role\='s own `ended-at', the way
`gh' is - so the fleet gathers the list once a tick and each standby row asks
about its own last pass."
  (with-temp-buffer
    (setq cerebro--seen-up nil
          cerebro--parked '(("Moira" . (7.0 4.0 nil))))
    (let ((mine (cerebro--agent-context
                 (cerebro-test--interactive "Moira" "user-feedback" 'standby)
                 (list (cons 'now 10.0) (cons 'gh nil)
                       (cons 'linked '(("cb-1" 5 6.0) ("cb-2" 9 8.0)))))))
      (should (equal (alist-get 'linked-moved mine) '(("cb-2" 9 8.0)))))))

(ert-deftest cerebro-test/an-implementer-fingerprint-is-the-planned-ids ()
  "Ids, not a count.  An implementer started for a planned bead it cannot
actually claim - one `bd ready' hides behind an unbuilt blocker - ends its
pass having changed no count at all, and a count would start it again for
ever.  The ids change the moment the planned list does, which is the only
thing worth another session."
  (should (equal (cerebro--trigger-fingerprint "implementer"
                                               '((planned-ids "cb-1" "cb-2")))
                 '(("cb-1" "cb-2"))))
  (let ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)))
    ;; the same list its own last pass was started for: held
    (should (null (cerebro--unless-unchanged
                   "implementer"
                   '((planned-ids "cb-1" "cb-2")
                     (last-fingerprint ("cb-1" "cb-2"))
                     (started-at . 1.0) (ended-at . 2.0))
                   "2 planned, unclaimed")))
    ;; a different list: through
    (should (equal (cerebro--unless-unchanged
                    "implementer"
                    '((planned-ids "cb-1" "cb-3")
                      (last-fingerprint ("cb-1" "cb-2"))
                      (started-at . 1.0) (ended-at . 2.0))
                    "2 planned, unclaimed")
                   "2 planned, unclaimed"))
    (ignore agent)))

(ert-deftest cerebro-test/launch-records-an-implementer-fingerprint ()
  "Every kind records one since cb-1or.1: an implementer has a condition now,
so it has something for `cerebro--unless-unchanged' to compare."
  (let ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)))
    (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () t))
              ((symbol-function 'cerebro--make-session-buffer)
               (lambda (_a) (generate-new-buffer " *cerebro-test-session*")))
              ((symbol-function 'cerebro--repo-root) (lambda () "/fake/repo"))
              ((symbol-function 'cerebro--log) (lambda (&rest _) nil))
              ((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _) '((planned-ids "cb-1")))))
      (with-temp-buffer
        (cerebro--launch agent)
        (should (equal (cdr (assoc "Cyclops" cerebro--start-fingerprints))
                       '(("cb-1"))))))))

(ert-deftest cerebro-test/standby-glyph-and-label ()
  "Its own glyph and its own word: `dead' means nobody is coming, and standby
means somebody is, on a trigger the For column names."
  (should (equal (substring-no-properties (cerebro--glyph 'standby)) "◌"))
  (should (eq (get-text-property 0 'face (cerebro--glyph 'standby)) 'cerebro-standby))
  (should (equal (cerebro--state-label
                  (cerebro-test--interactive "Psylocke" "verifier" 'standby))
                 "standby")))

(ert-deftest cerebro-test/alive-p-treats-standby-as-not-alive ()
  "`s' has to reach `launch' and `k' has to have something to say - both ask
this one question first."
  (should-not (cerebro--alive-p (cerebro-test--interactive "Psylocke" "verifier" 'standby)))
  (should (cerebro--alive-p (cerebro-test--interactive "Psylocke" "verifier" 'waiting))))

(ert-deftest cerebro-test/start-action-launches-a-standby-role ()
  (should (eq (cerebro--start-action
               (cerebro-test--interactive "Psylocke" "verifier" 'standby) nil)
              'launch)))

(ert-deftest cerebro-test/kill-action-disarms-a-standby-role ()
  "There is no process to kill, so `k' means the other half of what it always
meant for an interactive role: stay down."
  (should (eq (cerebro--kill-action
               (cerebro-test--interactive "Psylocke" "verifier" 'standby) nil)
              'disarm))
  ;; A role that was never armed is still simply dead.
  (should (eq (cerebro--kill-action
               (cerebro-test--interactive "Psylocke" "verifier" 'dead) nil)
              'dead)))

(ert-deftest cerebro-test/supervise-ends-a-waiting-role-after-the-grace ()
  "A pass is a session now: the role writes `waiting', prints its one line, and
the view ends it half a minute later - long enough for that line to land."
  (let ((cerebro-end-grace 30))
    (should (eq (cerebro--supervise-action
                 (cerebro-test--interactive "Moira" "user-feedback" 'waiting nil
                                            "2026-08-14T09:29:29Z")
                 nil cerebro-test--now)
                'end))
    (should (null (cerebro--supervise-action
                   (cerebro-test--interactive "Moira" "user-feedback" 'waiting nil
                                              "2026-08-14T09:29:50Z")
                   nil cerebro-test--now)))
    ;; A torn file says nothing, and nothing is not a grace that has expired.
    (should (null (cerebro--supervise-action
                   (cerebro-test--interactive "Moira" "user-feedback" 'waiting)
                   nil cerebro-test--now)))))

(ert-deftest cerebro-test/supervise-retires-an-idle-interactive-role-under-a-stop-flag ()
  "The flag lands at once and whatever the grace says: nothing is in flight."
  (let ((cerebro-end-grace 30))
    (should (eq (cerebro--supervise-action
                 (cerebro-test--interactive "Forge" "architect" 'idle nil
                                            "2026-08-14T09:29:59Z")
                 t cerebro-test--now)
                'retire))))

(ert-deftest cerebro-test/forge-ends-its-sweep-with-waiting-not-idle ()
  "Forge writes `waiting' at the end of a sweep like every other interactive
role, so no role ends a pass by writing `idle' any more: the list is the
mechanism a consumer role would use, and is empty by default."
  (should (null cerebro-idle-ends-pass-roles))
  (let ((cerebro-end-grace 30))
    ;; `waiting' ends it, as it does for every role.
    (should (eq (cerebro--supervise-action
                 (cerebro-test--interactive "Forge" "architect" 'waiting nil
                                            "2026-08-14T09:29:00Z")
                 nil cerebro-test--now)
                'end))
    ;; `idle' no longer does - it means a session with nothing in hand.
    (should (null (cerebro--supervise-action
                   (cerebro-test--interactive "Forge" "architect" 'idle nil
                                              "2026-08-14T09:29:00Z")
                   nil cerebro-test--now)))))

(ert-deftest cerebro-test/forge-is-woken-hourly ()
  "The sweep is cheap and its watermark makes an empty one nearly free, so
Forge comes back every hour rather than once a day."
  (should (equal (cdr (assoc "architect" cerebro-cadence-triggers)) 3600)))

(ert-deftest cerebro-test/an-idle-orchestrator-is-never-ended ()
  "Cerebro writes `idle' between the navigator's questions - it is not a pass
that is over, it is a session waiting to be spoken to.  Only a role listed in
`cerebro-idle-ends-pass-roles' means \"my pass is finished\" by writing `idle';
every other interactive role stays up until the navigator kills it."
  (let ((cerebro-end-grace 30))
    (should (null (cerebro--supervise-action
                   (cerebro-test--interactive "Cerebro" "orchestrator" 'idle nil
                                              "2026-08-14T08:00:00Z")
                   nil cerebro-test--now)))
    ;; The stop flag still lands: nothing is in flight, so `f' means stop now.
    (should (eq (cerebro--supervise-action
                 (cerebro-test--interactive "Cerebro" "orchestrator" 'idle nil
                                            "2026-08-14T08:00:00Z")
                 t cerebro-test--now)
                'retire))))

(ert-deftest cerebro-test/idle-ends-a-pass-only-for-the-roles-that-say-so ()
  "The list is the whole rule, so a consumer role that ends its pass with
`idle' is one entry rather than a code change."
  (let ((cerebro-end-grace 30)
        (cerebro-idle-ends-pass-roles '("verifier")))
    (should (eq (cerebro--supervise-action
                 (cerebro-test--interactive "Psylocke" "verifier" 'idle nil
                                            "2026-08-14T09:29:00Z")
                 nil cerebro-test--now)
                'end))
    (should (null (cerebro--supervise-action
                   (cerebro-test--interactive "Forge" "architect" 'idle nil
                                              "2026-08-14T09:29:00Z")
                   nil cerebro-test--now)))))

(ert-deftest cerebro-test/an-external-waiting-or-idle-role-is-never-ended ()
  "Ending a session means killing a process this Emacs started; one in
somebody's own terminal is theirs."
  (let ((cerebro-end-grace 30))
    (dolist (state '(waiting idle))
      (should (null (cerebro--supervise-action
                     (cerebro-test--interactive "Moira" "user-feedback" state t
                                                "2026-08-14T09:00:00Z")
                     nil cerebro-test--now))))))


;; --- parking: the session ends, the buffer stays --------------------------

(defun cerebro-test--parkable (name body)
  "Run BODY with NAME holding a real, recorded session buffer and a state file.

BODY gets (ROOT AGENT BUFFER).  The process is a `sleep' rather than a vterm:
what parking does to it - clear the query flag, kill it, keep and rename the
buffer - is the same either way, and vterm cannot be started in batch."
  (let ((root (make-temp-file "cerebro-park" t))
        (buffer (generate-new-buffer (format "*fleet: %s*" name)))
        (cerebro--sessions nil))
    (unwind-protect
        (with-temp-buffer
          (let ((process (start-process "cerebro-test-session" buffer
                                        "bash" "-c" "sleep 30")))
            (set-process-query-on-exit-flag process t)
            (setf (alist-get name cerebro--sessions nil nil #'equal) buffer)
            (make-directory (expand-file-name ".cerebro/state" root) t)
            (write-region "{}" nil (expand-file-name
                                    (format ".cerebro/state/%s.state.json" name) root))
            (funcall body root
                     (cerebro-test--interactive name "verifier" 'waiting)
                     buffer)))
      (when (buffer-live-p buffer)
        (let ((p (get-buffer-process buffer)))
          (when p (set-process-query-on-exit-flag p nil) (delete-process p)))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest cerebro-test/park-session-keeps-the-buffer-and-forgets-the-session ()
  "Everything `cerebro--end-session' removes, except the one thing worth
keeping: the buffer, which is the only record the pass leaves behind."
  (cerebro-test--parkable
   "Psylocke"
   (lambda (root agent buffer)
     (setq cerebro--started-at '(("Psylocke" . 1000.0)))
     (cerebro--park-session agent root (encode-time (iso8601-parse "2026-08-14T09:30:00Z")))
     (should-not (process-live-p (get-buffer-process buffer)))
     (should (buffer-live-p buffer))
     (should (string-match-p "\\`\\*fleet: Psylocke (ended [0-9][0-9]:[0-9][0-9])\\*\\'"
                             (buffer-name buffer)))
     (should (with-current-buffer buffer buffer-read-only))
     ;; Forgotten, so `s' and a trigger both reach `cerebro--launch'.
     (should-not (cerebro--session "Psylocke"))
     (should-not (cerebro--recorded-buffer "Psylocke"))
     ;; The file names a pid that is gone, and pids are recycled.
     (should-not (file-exists-p (expand-file-name ".cerebro/state/Psylocke.state.json" root)))
     (let ((entry (cdr (assoc "Psylocke" cerebro--parked))))
       (should (eq (nth 2 entry) buffer))
       (should (equal (nth 1 entry) 1000.0))
       (should (numberp (nth 0 entry)))))))

(ert-deftest cerebro-test/park-replaces-an-earlier-parked-buffer ()
  "One kept buffer per role: the record of the last pass, not of every pass."
  (let ((stale (generate-new-buffer "*fleet: Psylocke (ended 08:00)*")))
    (cerebro-test--parkable
     "Psylocke"
     (lambda (root agent buffer)
       (setq cerebro--parked (list (cons "Psylocke" (list 1.0 0.0 stale))))
       (cerebro--park-session agent root (current-time))
       (should-not (buffer-live-p stale))
       (should (eq (nth 2 (cdr (assoc "Psylocke" cerebro--parked))) buffer))))))

(ert-deftest cerebro-test/park-says-nothing-when-it-kills-the-process ()
  "`cerebro--note-exit' finds an agent through `cerebro--sessions', so the
session is forgotten before the process dies: an end the view decided on is
not an abnormal exit to be echoed at the navigator."
  (cerebro-test--parkable
   "Psylocke"
   (lambda (root agent buffer)
     (let ((messages nil))
       (cl-letf (((symbol-function 'message)
                  (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
         (cerebro--park-session agent root (current-time))
         (cerebro--note-exit buffer "exited abnormally with code 1\n"))
       (should (null messages))
       (should (null (alist-get "Psylocke" cerebro--last-exit nil nil #'equal)))))))

(ert-deftest cerebro-test/park-keeps-what-it-can-when-killing-the-process-kills-the-buffer ()
  "A pass end must not fail on the record it was trying to keep.

vterm\='s own sentinel kills the session buffer the moment the process dies,
and `delete-process\=' runs that sentinel before it returns - so the buffer
`cerebro--park-session\=' is about to enter can already be gone.  Every step
after it still runs: the state file goes, the session is forgotten, and the
pass is recorded with no kept buffer rather than with an error."
  (cerebro-test--parkable
   "Psylocke"
   (lambda (root agent buffer)
     (setq cerebro--started-at '(("Psylocke" . 1000.0)))
     (let ((original (symbol-function 'delete-process)))
       (cl-letf (((symbol-function 'delete-process)
                  (lambda (p)
                    ;; What vterm\='s sentinel does, forced rather than waited
                    ;; for: whether `delete-process\=' runs sentinels
                    ;; synchronously differs between a `sleep\=' and a vterm.
                    (let ((b (process-buffer p)))
                      (funcall original p)
                      (when (buffer-live-p b) (kill-buffer b))))))
         (cerebro--park-session agent root
                                (encode-time (iso8601-parse "2026-08-14T09:30:00Z")))))
     (should-not (buffer-live-p buffer))
     (should-not (file-exists-p (expand-file-name ".cerebro/state/Psylocke.state.json" root)))
     (should-not (cerebro--recorded-buffer "Psylocke"))
     (let ((entry (cdr (assoc "Psylocke" cerebro--parked))))
       (should (numberp (nth 0 entry)))
       (should (null (nth 2 entry)))))))

(ert-deftest cerebro-test/show-detail-prefers-a-parked-buffer-over-the-placeholder ()
  "`RET' on a standby row shows what the last pass printed."
  (let ((parked (generate-new-buffer "*fleet: Psylocke (ended 08:00)*"))
        (agent (cerebro-test--interactive "Psylocke" "verifier" 'standby))
        (cerebro--sessions nil))
    (unwind-protect
        (progn
          (setq cerebro--parked (list (cons "Psylocke" (list 1.0 0.0 parked))))
          (should (eq (cerebro--show-detail agent) parked))
          ;; Killed by hand, or never there: the placeholder, as before.
          (kill-buffer parked)
          (should (eq (cerebro--show-detail agent)
                      (get-buffer (cerebro--placeholder-buffer-name agent)))))
      (when (buffer-live-p parked) (kill-buffer parked)))))

(ert-deftest cerebro-test/launch-arms-every-kind-and-deletes-the-stale-state-file ()
  "Every start arms, whatever the kind: an implementer whose session dies
without ending its pass is brought back the way a role is (cb-hzs).  And a state file
present when a launch runs is always the previous session's - nothing else
could have written it, since `cerebro--launch' refuses a name with a live
session - so it goes before the fresh one starts."
  (let* ((root (file-name-as-directory (make-temp-file "cerebro-root" t)))
         (cerebro--sessions nil)
         (buffers nil))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--make-session-buffer)
                   (lambda (name) (car (push (generate-new-buffer name) buffers))))
                  ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
                  ((symbol-function 'cerebro--repo-root) (lambda () root))
                  ((symbol-function 'cerebro--trigger-context) (lambda (&rest _) nil))
                  ((symbol-function 'cerebro-session-mode) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (let ((stale (expand-file-name ".cerebro/state/Rogue.state.json" root)))
            (write-region "{\"state\":\"idle\"}" nil stale nil 'silent)
            (with-temp-buffer
              (setq cerebro--armed nil cerebro--started-at nil
                    cerebro--failed-starts '(("Rogue" . 3)))
              (cerebro--launch (cerebro-test--interactive "Psylocke" "verifier" 'standby))
              (cerebro--launch (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead))
              (should (member "Psylocke" cerebro--armed))
              (should (member "Rogue" cerebro--armed))
              (should (assoc "Psylocke" cerebro--started-at))
              (should (assoc "Rogue" cerebro--started-at))
              ;; A start with no trigger reason is the navigator's own, and
              ;; that is what resets the count the backoff is indexed by.
              (should (equal (cdr (assoc "Rogue" cerebro--failed-starts)) 0))
              (should-not (file-exists-p stale)))))
      (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b)))
      (delete-directory root t))))

(ert-deftest cerebro-test/launch-kills-the-parked-buffer-it-replaces ()
  "The kept buffer is the record of the *last* pass, so a fresh start ends it."
  (let ((cerebro--sessions nil)
        (parked (generate-new-buffer "*fleet: Psylocke (ended 08:00)*"))
        (buffers nil))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--make-session-buffer)
                   (lambda (name) (car (push (generate-new-buffer name) buffers))))
                  ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
                  ((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro-session-mode) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (with-temp-buffer
            (setq cerebro--parked (list (cons "Psylocke" (list 1.0 0.0 parked))))
            (cerebro--launch (cerebro-test--interactive "Psylocke" "verifier" 'standby))
            (should-not (buffer-live-p parked))
            (should-not (assoc "Psylocke" cerebro--parked))))
      (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b)))
      (when (buffer-live-p parked) (kill-buffer parked)))))

;; --- triggers: why a standby role should start now ------------------------

(defun cerebro-test--context (&rest overrides)
  "The trigger context, with nothing to do, plus OVERRIDES."
  (append overrides
          '((now . 1000000.0) (ended-at . 999000.0) (started-at . 990000.0)
            (floor . 600) (implementers . 2)
            (planned . 4) (p0-unplanned) (p4-unranked . 0) (unranked-ids)
            (actionable-ids)
            (merged-unverified . 0) (stale-verdicts . 0) (gh) (linked-moved))))

(defun cerebro-test--trigger (role &rest overrides)
  (cerebro--trigger (cerebro-test--interactive "X" role 'standby)
                    (apply #'cerebro-test--context overrides)))

(ert-deftest cerebro-test/the-buffer-rule-needs-something-to-plan ()
  "A short buffer with nothing left unplanned starts nobody.

Seen in the fleet: two planners, one bead left. Beast took it and labelled it
`planning:Beast\=', which moved it out of UNPLANNED into BEING-PLANNED - and that
very change is what woke Xavier. The buffer was still short, so the rule fired;
`actionable-ids\=' was empty, so there was nothing a pass could take. Xavier
started, found the queue empty and ended.

The taking is what makes it fire, which is why the no-progress guard cannot
help: it holds a trigger naming what the role\='s OWN last pass was started for,
and a bead moving from unplanned to held changes the fingerprint. So the rule
itself has to ask whether there is work, the way the P0 and P4 rules already do
by being derived from the unplanned list."
  (let ((held '(planned . 0)) (want '(implementers . 2)))
    ;; Nothing unplanned: short buffer or not, a pass has nothing to take.
    (should (null (cerebro-test--trigger "planner" held want '(actionable-ids))))
    ;; The same fleet with one bead free: that is a pass worth starting.
    (should (equal (cerebro-test--trigger "planner" held want '(actionable-ids "cb-9zz"))
                   "buffer 0 of 2"))
    ;; And a full buffer still starts nobody, whatever is unplanned.
    (should (null (cerebro-test--trigger "planner" '(planned . 2) want
                                         '(actionable-ids "cb-9zz" "cb-8yy"))))
    ;; A P0 is not subject to it: it is planned the moment it appears, and it
    ;; is in the unplanned list by construction.
    (should (equal (cerebro-test--trigger "planner" held want
                                          '(actionable-ids "cb-9zz")
                                          '(p0-unplanned "cb-9zz"))
                   "P0 cb-9zz unplanned"))))

(ert-deftest cerebro-test/trigger-table ()
  "One `should' per row of the plan's table, and the negative beside it."
  (let ((cerebro-cadence-triggers '(("user-feedback" . 3600) ("reviewer" . 3600)
                                    ("architect" . 86400))))
    ;; A planner: an unplanned P0 first, whichever planner it is.
    (should (equal (cerebro-test--trigger "planner" '(p0-unplanned "cb-9zz"))
                   "P0 cb-9zz unplanned"))
    ;; An unranked bead starts no planner: ranking is Cerebro's (cb-5lx.1), and a
    ;; planner started for one ends having planned nothing.
    (should (null (cerebro-test--trigger "planner" '(p4-unranked . 7))))
    (should (null (cerebro-test--trigger "planner" '(p4-unranked . 1))))
    ;; The buffer: one planned, unclaimed bead per running implementer, and
    ;; never fewer than two whatever the fleet looks like. Every row carries
    ;; something unplanned, because a short buffer is only a reason to start
    ;; while there is a bead to take - see
    ;; `cerebro-test/the-buffer-rule-needs-something-to-plan'.
    (should (equal (cerebro-test--trigger "planner" '(planned . 1) '(implementers . 3)
                                          '(actionable-ids "cb-9zz"))
                   "buffer 1 of 3"))
    (should (equal (cerebro-test--trigger "planner" '(planned . 0) '(implementers . 1)
                                          '(actionable-ids "cb-9zz"))
                   "buffer 0 of 2"))
    (should (equal (cerebro-test--trigger "planner" '(planned . 1) '(implementers . 0)
                                          '(actionable-ids "cb-9zz"))
                   "buffer 1 of 2"))
    ;; Enough is enough: one each above the floor, and nobody plans ahead of
    ;; that.
    (should (null (cerebro-test--trigger "planner" '(planned . 2) '(implementers . 2)
                                         '(actionable-ids "cb-9zz"))))
    (should (null (cerebro-test--trigger "planner" '(planned . 3) '(implementers . 2)
                                         '(actionable-ids "cb-9zz"))))
    (should (null (cerebro-test--trigger "planner" '(planned . 2) '(implementers . 0)
                                         '(actionable-ids "cb-9zz"))))
    ;; The verifier: a stale verdict before a merged bead.
    (should (equal (cerebro-test--trigger "verifier" '(stale-verdicts . 2)) "2 stale verdicts"))
    (should (equal (cerebro-test--trigger "verifier" '(stale-verdicts . 1)) "1 stale verdict"))
    (should (equal (cerebro-test--trigger "verifier" '(merged-unverified . 2))
                   "2 merged, unverified"))
    (should (equal (cerebro-test--trigger "verifier" '(merged-unverified . 1))
                   "1 merged, unverified"))
    (should (null (cerebro-test--trigger "verifier")))
    ;; GitHub: what `cerebro--gh-moved' found for this role. Nil, or a
    ;; reader that has failed, leaves the cadence floor as the whole trigger.
    (should (equal (cerebro-test--trigger "user-feedback" '(gh (41 17) nil))
                   "issue #41 moved"))
    (should (equal (cerebro-test--trigger "reviewer" '(gh nil (40)))
                   "PR #40 moved"))
    (should (null (cerebro-test--trigger "user-feedback" '(gh nil nil))))
    ;; And the bead side of Moira's job: a linked bead that changed since her
    ;; last pass is a status comment owed to an issue, and the issue's own
    ;; `updatedAt' does not move for it (cb-b4m).
    (should (equal (cerebro-test--trigger "user-feedback" '(gh nil nil)
                                          '(linked-moved ("cb-3qh" 58 999500.0)))
                   "bead cb-3qh moved (issue #58)"))
    ;; The issue comes first: a person is waiting on one, and the bead is the
    ;; fleet's own bookkeeping.
    (should (equal (cerebro-test--trigger "user-feedback" '(gh (41 17) nil)
                                          '(linked-moved ("cb-3qh" 58 999500.0)))
                   "issue #41 moved"))
    ;; A reader that failed does not hide the bead side: they are two
    ;; conditions, not one with a fallback.
    (should (equal (cerebro-test--trigger "user-feedback" '(gh . failed)
                                          '(linked-moved ("cb-3qh" 58 999500.0)))
                   "bead cb-3qh moved (issue #58)"))
    (should (null (cerebro-test--trigger "reviewer" '(gh . failed))))
    ;; The cadence floor, on its own.
    (should (null (cerebro-test--trigger "user-feedback" '(gh . failed)
                                         '(ended-at . 998800.0))))
    (should (equal (cerebro-test--trigger "user-feedback" '(gh . failed)
                                          '(ended-at . 996000.0))
                   "60m since its last pass"))
    (should (null (cerebro-test--trigger "architect" '(ended-at . 917000.0))))
    (should (equal (cerebro-test--trigger "architect" '(ended-at . 910000.0))
                   "24h since its last sweep"))
    ;; Cerebro is started for an unranked bead and nothing else (cb-5lx.2); a
    ;; role the view has no rule for starts never.
    (should (null (cerebro-test--trigger "orchestrator" '(p0-unplanned "cb-9zz")
                                         '(merged-unverified . 9))))
    (should (null (cerebro-test--trigger "sommelier" '(p0-unplanned "cb-9zz"))))
    ;; The floor is above every rule: started 100s ago, floor 600.
    (should (null (cerebro-test--trigger "verifier" '(merged-unverified . 3)
                                         '(started-at . 999900.0))))
    ;; A role this Emacs has never started has no floor to clear.
    (should (equal (cerebro-test--trigger "verifier" '(merged-unverified . 3)
                                          '(started-at))
                   "3 merged, unverified"))
    ;; An implementer: a planned, unclaimed bead and nothing else.
    ;; `cerebro-test--trigger' builds an interactive agent, so these ask
    ;; `cerebro--trigger' with an implementer one directly.
    (cl-flet ((implementer (&rest overrides)
                (cerebro--trigger
                 (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)
                 (apply #'cerebro-test--context (append overrides '((floor . 0)))))))
      (should (equal (implementer '(planned-ids "cb-1" "cb-2")) "2 planned, unclaimed"))
      (should (equal (implementer '(planned-ids "cb-1")) "1 planned, unclaimed"))
      (should (null (implementer '(planned-ids))))
      ;; The backoff is `cerebro--start-due's, not this rule's: a name with
      ;; failed starts behind it still answers with the count.
      (should (equal (implementer '(planned-ids "cb-1" "cb-2") '(failed-starts . 3))
                     "2 planned, unclaimed"))
      ;; A roster-armed implementer this Emacs has never started (cb-1or.2)
      ;; has a nil `started-at' and no floor to clear, exactly as a
      ;; roster-armed role does.
      (should (equal (implementer '(planned-ids "cb-1") '(started-at))
                     "1 planned, unclaimed")))))

(ert-deftest cerebro-test/the-triage-line-names-up-to-eight-beads ()
  (should (equal (cerebro--triage-message '("cb-1" "cb-2"))
                 "[cerebro] Unranked beads are waiting for a ranking: cb-1, cb-2. Triage them with the navigator."))
  (should (equal (cerebro--triage-message '("cb-1"))
                 "[cerebro] Unranked beads are waiting for a ranking: cb-1. Triage them with the navigator."))
  (let ((ten (mapcar (lambda (n) (format "cb-%02d" n)) (number-sequence 1 10))))
    (should (equal (cerebro--triage-message ten)
                   (concat "[cerebro] Unranked beads are waiting for a ranking: "
                           "cb-01, cb-02, cb-03, cb-04, cb-05, cb-06, cb-07, cb-08 and 2 more. "
                           "Triage them with the navigator.")))
    (should (string-suffix-p " and 1 more. Triage them with the navigator."
                             (cerebro--triage-message (seq-take ten 9))))
    (should-not (string-match-p "more" (cerebro--triage-message (seq-take ten 8))))))

(defun cerebro-test--cerebro (state &optional external)
  (make-cerebro-agent :name "Cerebro" :role "orchestrator" :kind 'interactive
                      :state state :external external :since "2026-08-14T09:00:00Z"))

(ert-deftest cerebro-test/an-idle-cerebro-is-told-once-per-change ()
  "Told when the set differs from what it was last told; not again while it
is the same and recent; again on the clock (cb-5lx.2)."
  (let ((cerebro-triage-repeat 600)
        (idle-for 1800) (panel-age 10) (now 1000000.0))
    (should (eq (cerebro--triage-action (cerebro-test--cerebro 'idle) '("cb-1") nil idle-for panel-age now)
                'tell))
    (should (eq (cerebro--triage-action (cerebro-test--cerebro 'idle) '("cb-1" "cb-2")
                                        (cons '("cb-1") 999900.0) idle-for panel-age now)
                'tell))
    (should (null (cerebro--triage-action (cerebro-test--cerebro 'idle) '("cb-1")
                                          (cons '("cb-1") 999900.0) idle-for panel-age now)))
    (should (eq (cerebro--triage-action (cerebro-test--cerebro 'idle) '("cb-1")
                                        (cons '("cb-1") 999400.0) idle-for panel-age now)
                'repeat))))

(ert-deftest cerebro-test/no-line-lands-in-a-session-that-cannot-take-it ()
  "Never into a question dialog or over output (`working\=', `asking\='); never
where no state file says it is safe (`up\=', `unknown\='); never where there is
no session; never into a session this view does not own; never into a
role that is not Cerebro; and never on figures older than the idle it is
judging - the panel is thirty seconds behind bd, and a line judged on
figures read before Cerebro went idle names beads it has just ranked."
  (let ((cerebro-triage-repeat 600))
    (dolist (state '(working asking up unknown dead standby waiting))
      (should (null (cerebro--triage-action (cerebro-test--cerebro state) '("cb-1") nil 1800 10 1000000.0))))
    (should (null (cerebro--triage-action (cerebro-test--cerebro 'idle t) '("cb-1") nil 1800 10 1000000.0)))
    (should (null (cerebro--triage-action
                   (make-cerebro-agent :name "Xavier" :role "planner" :kind 'interactive
                                       :state 'idle :since "2026-08-14T09:00:00Z")
                   '("cb-1") nil 1800 10 1000000.0)))
    (should (null (cerebro--triage-action (cerebro-test--cerebro 'idle) nil nil 1800 10 1000000.0)))
    ;; Panel read 40s ago, Cerebro idle for 20s: the figures predate the idle.
    (should (null (cerebro--triage-action (cerebro-test--cerebro 'idle) '("cb-1") nil 20 40 1000000.0)))
    ;; No panel yet, or a torn state file: nothing is typed.
    (should (null (cerebro--triage-action (cerebro-test--cerebro 'idle) '("cb-1") nil 1800 nil 1000000.0)))
    (should (null (cerebro--triage-action (cerebro-test--cerebro 'idle) '("cb-1") nil nil 10 1000000.0)))))

(ert-deftest cerebro-test/triage-tell-types-remembers-and-logs ()
  (let* ((typed nil) (logged nil)
         (ids '("cb-1" "cb-2"))
         (agent (cerebro-test--cerebro 'idle))
         (now (encode-time (iso8601-parse "2026-08-14T09:30:00Z")))
         (cerebro-triage-repeat 600))
    (cl-letf (((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _) (list (cons 'unranked-ids ids)
                                       (cons 'beads-read-at (- (float-time now) 5)))))
              ((symbol-function 'cerebro--type-into-session)
               (lambda (a m) (push (cons (cerebro-agent-name a) m) typed)))
              ((symbol-function 'cerebro--log)
               (lambda (_root event fields) (push (cons event fields) logged))))
      (with-temp-buffer
        (cerebro--triage-tell (list agent) "/tmp/nowhere" now)
        (cerebro--triage-tell (list agent) "/tmp/nowhere" now)
        (should (equal typed (list (cons "Cerebro" (cerebro--triage-message ids)))))
        (should (equal (car (cdr (assoc "Cerebro" cerebro--triage-told))) ids))
        (should (equal (length logged) 1))
        (should (eq (car (car logged)) 'triage))
        (should (equal (alist-get 'ids (cdr (car logged))) ids))
        (should (null (alist-get 'repeat (cdr (car logged)))))
        ;; Ten minutes later, same set: repeated, and said to be.
        (let ((later (time-add now 601)))
          (cl-letf (((symbol-function 'cerebro--trigger-context)
                     (lambda (&rest _) (list (cons 'unranked-ids ids)
                                             (cons 'beads-read-at (- (float-time later) 5))))))
            (cerebro--triage-tell (list agent) "/tmp/nowhere" later)
            (should (equal (length typed) 2))
            (should (eq (alist-get 'repeat (cdr (car logged))) t))))
        ;; The set empties: the record goes with it, so its return is a change.
        (cl-letf (((symbol-function 'cerebro--trigger-context)
                   (lambda (&rest _) (list (cons 'unranked-ids nil) (cons 'beads-read-at 0.0)))))
          (cerebro--triage-tell (list agent) "/tmp/nowhere" now)
          (should (null (assoc "Cerebro" cerebro--triage-told))))))))

(ert-deftest cerebro-test/triage-tell-gathers-nothing-when-nobody-could-take-a-line ()
  "The context gather costs a stat per implementer; a fleet with no idle,
owned Cerebro pays it for nothing."
  (let ((gathered 0))
    (cl-letf (((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _) (cl-incf gathered) nil)))
      (with-temp-buffer
        (cerebro--triage-tell (list (cerebro-test--cerebro 'working)
                                    (cerebro-test--cerebro 'idle t)
                                    (cerebro-test--interactive "Xavier" "planner" 'idle))
                              "/tmp/nowhere" (current-time))
        (should (= gathered 0))))))

(ert-deftest cerebro-test/an-unranked-bead-starts-an-armed-cerebro ()
  "Cerebro is started for one thing - a bead waiting for a ranking - so the
triage pass it runs on startup has something to ask about (cb-5lx.2).  The
fingerprint is the ids, so a Cerebro whose pass ranked nothing is not started
again for the same set."
  (should (null (cerebro-test--trigger "orchestrator")))
  (should (equal (cerebro-test--trigger "orchestrator" '(unranked-ids "cb-1" "cb-2"))
                 "2 unranked"))
  ;; Still nothing for a P0, a short buffer or merged work.
  (should (null (cerebro-test--trigger "orchestrator" '(p0-unplanned "cb-9zz")
                                       '(planned . 0) '(merged-unverified . 9))))
  ;; The same set after a pass that ran: held.  A different set: started.
  (should (null (cerebro-test--trigger "orchestrator" '(unranked-ids "cb-1")
                                       '(last-fingerprint ("cb-1")))))
  (should (equal (cerebro-test--trigger "orchestrator" '(unranked-ids "cb-1" "cb-3")
                                        '(last-fingerprint ("cb-1")))
                 "2 unranked"))
  (should (equal (cerebro--trigger-fingerprint "orchestrator"
                                               (cerebro-test--context '(unranked-ids "cb-1")))
                 '(("cb-1"))))
  ;; The standby row says what it waits for.
  (should (equal (cerebro--standby-label (cerebro-test--interactive "Cerebro" "orchestrator" 'standby)
                                         (cerebro-test--context))
                 "→ unranked bead")))

(ert-deftest cerebro-test/two-planners-answer-every-trigger-identically ()
  "No planner is first: the context carries nothing that tells Xavier from
Beast, and a stale `first-planner-p\=' left in it by an older caller changes
no answer.  Roster order is load-bearing for the implementer names Cerebro
hands out, and for nothing about the planners."
  (dolist (extra '(nil ((first-planner-p . t)) ((first-planner-p))))
    (let ((overrides (append extra '((p4-unranked . 7)))))
      (should (null (apply #'cerebro-test--trigger "planner" overrides)))
      (should (equal (apply #'cerebro-test--trigger "planner"
                            (cons '(p0-unplanned "cb-9zz") overrides))
                     "P0 cb-9zz unplanned"))
      (should (equal (apply #'cerebro-test--trigger "planner"
                            (append '((planned . 1) (implementers . 3)
                                      (actionable-ids "cb-9zz"))
                                    overrides))
                     "buffer 1 of 3"))))
  ;; And the fingerprint no longer moves when only the unranked count does.
  (should (equal (cerebro--trigger-fingerprint "planner" (cerebro-test--context '(p4-unranked . 1)))
                 (cerebro--trigger-fingerprint "planner" (cerebro-test--context '(p4-unranked . 9))))))

;; ---------------------------------------------------------------------------
;; The view's own log: what it decided, and what it declined to do

(ert-deftest cerebro-test/a-log-line-is-one-json-object-with-the-event-first ()
  "Same shape and the same directory as `scripts/agent-state's transition log,
so one reader pairs the two halves of an event: the view deciding to start a
role, and that role's own first write seconds later."
  (let ((line (cerebro--log-line
               'start "2026-08-25T09:30:00Z"
               '((agent . "Xavier") (role . "planner") (reason . "buffer 0 of 3")))))
    (should (equal (cerebro--try-parse-json line)
                   '((event . "start") (ts . "2026-08-25T09:30:00Z")
                     (agent . "Xavier") (role . "planner")
                     (reason . "buffer 0 of 3"))))
    ;; One line, always: a log is appended to by more than one writer.
    (should-not (string-match-p "\n" line))))

(ert-deftest cerebro-test/a-nil-field-is-logged-as-null-not-dropped ()
  "\"Evaluated, and there was no reason\" is the answer the guard cases turn
on, and a missing key would read as \"not evaluated\"."
  (let ((parsed (cerebro--try-parse-json
                 (cerebro--log-line 'evaluate "2026-08-25T09:30:00Z"
                                    '((agent . "Xavier") (reason . nil))))))
    (should (assq 'reason parsed))
    (should (null (alist-get 'reason parsed)))))

(ert-deftest cerebro-test/the-verbosity-decides-which-events-are-written ()
  "Per-tick evaluations are the loud half - nine rows every five seconds - and
they are what answers \"why did nothing happen\".  So they are a level rather
than a rule: `evaluations' keeps them, `changes' keeps one line when an
evaluation's answer differs from that agent's last, `decisions' keeps only
what the view actually did."
  (should (cerebro--log-event-p 'start 'decisions))
  (should (cerebro--log-event-p 'end 'decisions))
  (should (cerebro--log-event-p 'triage 'decisions))
  (should-not (cerebro--log-event-p 'evaluate 'decisions))
  (should (cerebro--log-event-p 'evaluate 'changes))
  (should (cerebro--log-event-p 'evaluate 'evaluations))
  ;; A level nobody recognises logs the decisions rather than nothing: losing
  ;; the record of a start is worse than a typo in a setting.
  (should (cerebro--log-event-p 'start 'nonsense))
  (should-not (cerebro--log-event-p 'evaluate 'nonsense)))

(ert-deftest cerebro-test/at-changes-only-a-different-answer-is-written ()
  "The middle level, and the one that makes a day of history fit: a standby
planner evaluated seventeen thousand times a day with the same answer is one
line, and the line lands on the tick the answer changed."
  (let ((seen '(("Xavier" . "buffer 0 of 3"))))
    (should-not (cerebro--log-evaluation-p "Xavier" "buffer 0 of 3" seen 'changes))
    (should (cerebro--log-evaluation-p "Xavier" nil seen 'changes))
    (should (cerebro--log-evaluation-p "Beast" nil seen 'changes))
    ;; At `evaluations' every tick is written, same answer or not.
    (should (cerebro--log-evaluation-p "Xavier" "buffer 0 of 3" seen 'evaluations))))

(ert-deftest cerebro-test/the-log-rotates-on-size-and-keeps-generations ()
  "`agent-state' rotates its own log at 5 MB and keeps one generation. This one
is written far faster - a line per standby role per five-second tick at
`evaluations' - so the number is a setting, and what it protects is a day of
history rather than a byte count."
  (should (cerebro--log-rotate-p 5000 4096))
  (should-not (cerebro--log-rotate-p 4095 4096))
  ;; No file yet is not a rotation.
  (should-not (cerebro--log-rotate-p nil 4096)))

(ert-deftest cerebro-test/the-log-appends-and-rotates-under-a-real-root ()
  "The writer, not just the decision: lines land beside the agents' own
transition log, and the generations shift when the file passes its size."
  (let ((root (make-temp-file "cerebro-test-" t))
        (cerebro-log-verbosity 'evaluations)
        (cerebro-log-generations 2)
        (cerebro-log-max-bytes 4096))
    (unwind-protect
        (let ((file (expand-file-name ".cerebro/state/decisions.jsonl" root)))
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (cerebro--log root 'start '((agent . "Xavier") (reason . "buffer 0 of 3")))
          (cerebro--log root 'end '((agent . "Xavier")))
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (count-lines (point-min) (point-max)))
                         2))
          ;; Past the size: this file becomes generation 1 and a fresh one starts.
          (write-region (make-string 5000 ?x) nil file)
          (cerebro--log root 'start '((agent . "Beast")))
          (should (file-exists-p (expand-file-name ".cerebro/state/decisions.1.jsonl" root)))
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (count-lines (point-min) (point-max)))
                         1)))
      (delete-directory root t))))

(ert-deftest cerebro-test/a-log-that-cannot-be-written-is-not-an-error ()
  "The fleet must never be brought down by a full disk - the same rule
`scripts/agent-state' states about its own log."
  (let ((cerebro-log-verbosity 'evaluations))
    (should (null (cerebro--log "/nonexistent/root" 'start '((agent . "X")))))
    ;; And no root at all is simply nothing to write to.
    (should (null (cerebro--log nil 'start '((agent . "X")))))))

;; ---------------------------------------------------------------------------
;; The error log: what went wrong, in a file the navigator can be pointed at

(ert-deftest cerebro-test/an-error-is-logged-beside-the-decisions-not-among-them ()
  "The question this answers is \"where do I look\" - so the answer is one
short file rather than a needle in a hundred thousand evaluations.  Every
other event keeps the file it has always had."
  (should (equal (cerebro--log-basename 'error) "errors"))
  (should (equal (cerebro--log-basename 'start) "decisions"))
  (should (equal (cerebro--log-basename 'evaluate) "decisions"))
  (should (string-suffix-p ".cerebro/state/errors.jsonl"
                           (cerebro--log-file "/r" nil "errors")))
  (should (string-suffix-p ".cerebro/state/errors.2.jsonl"
                           (cerebro--log-file "/r" 2 "errors")))
  ;; The default is still the decisions log, so every existing caller is
  ;; unchanged by the base having become a parameter.
  (should (string-suffix-p ".cerebro/state/decisions.jsonl"
                           (cerebro--log-file "/r"))))

(ert-deftest cerebro-test/an-error-is-written-at-every-verbosity-but-none ()
  "An error is not a level of detail: `decisions' is a navigator asking for
less noise, not for a fleet that fails silently.  `none' still means nothing
at all - it is what the suite binds so ERT cannot append to the live log."
  (dolist (verbosity '(decisions changes evaluations nonsense))
    (should (cerebro--log-event-p 'error verbosity)))
  (should-not (cerebro--log-event-p 'error 'none)))

(ert-deftest cerebro-test/the-error-log-carries-what-went-wrong-and-where ()
  "The writer, not just the decision: a line lands in `errors.jsonl', it names
the part of the view the error came from, and the decisions log is left
alone - the two are read for different questions."
  (let ((root (make-temp-file "cerebro-test-" t))
        (cerebro-log-verbosity 'evaluations))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (cerebro--log-error root "autostart"
                              "vterm is not installed, so nothing was autostarted")
          (let ((parsed (cerebro--try-parse-json
                         (with-temp-buffer
                           (insert-file-contents
                            (expand-file-name ".cerebro/state/errors.jsonl" root))
                           (string-trim (buffer-string))))))
            (should (equal (alist-get 'event parsed) "error"))
            (should (equal (alist-get 'context parsed) "autostart"))
            (should (equal (alist-get 'message parsed)
                           "vterm is not installed, so nothing was autostarted"))
            (should (alist-get 'ts parsed)))
          (should-not (file-exists-p
                       (expand-file-name ".cerebro/state/decisions.jsonl" root))))
      (delete-directory root t))))

(ert-deftest cerebro-test/the-first-line-makes-the-directory-it-goes-in ()
  "A consumer whose fleet has never run has no `.cerebro/state\=' - the agents
make it themselves, on their first state write, and an agent that never
started never makes it.  Which is the exact case the error log exists for, so
it cannot be the case it silently drops."
  (let ((root (make-temp-file "cerebro-test-" t))
        (cerebro-log-verbosity 'evaluations))
    (unwind-protect
        (progn
          (should-not (file-directory-p (expand-file-name ".cerebro/state" root)))
          (cerebro--log-error root "autostart" "vterm is not installed")
          (should (file-exists-p (expand-file-name ".cerebro/state/errors.jsonl" root)))
          ;; And the decisions log answers the same way, for the same reason.
          (cerebro--log root 'start '((agent . "Xavier")))
          (should (file-exists-p (expand-file-name ".cerebro/state/decisions.jsonl" root))))
      (delete-directory root t))))

(ert-deftest cerebro-test/an-error-log-that-cannot-be-written-is-not-an-error ()
  "Same rule as the decisions log, and it matters more here: the one path that
must never signal is the one that runs when something has already gone wrong."
  (let ((cerebro-log-verbosity 'evaluations))
    (should (null (cerebro--log-error "/nonexistent/root" "autostart" "boom")))
    (should (null (cerebro--log-error nil "autostart" "boom")))))

(ert-deftest cerebro-test/a-reported-error-is-both-said-and-recorded ()
  "The echo area is where the navigator sees it and the log is where they find
it afterwards - one call does both, so neither can be forgotten."
  (let (said logged)
    (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () "/fake/repo"))
              ((symbol-function 'cerebro--log-error)
               (lambda (root context message) (push (list root context message) logged)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) said) nil)))
      (cerebro--report-error "autostart" "%s is not installed" "vterm")
      (should (equal said '("cerebro: vterm is not installed")))
      (should (equal logged '(("/fake/repo" "autostart" "vterm is not installed")))))))

(ert-deftest cerebro-test/a-demoted-error-is-recorded-rather-than-swallowed ()
  "`with-demoted-errors' is how the timer survives one broken agent, and it is
also how the reason vanished: the body is demoted exactly as before, but the
error now lands in the log with the part of the view it came from."
  (let (logged)
    (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () "/fake/repo"))
              ((symbol-function 'cerebro--log-error)
               (lambda (_root context message) (push (cons context message) logged)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      ;; The value of a body that does not signal is its own.
      (should (equal (cerebro--with-logged-errors "tick" (+ 1 1)) 2))
      (should (null logged))
      ;; And one that does is nil, with the error recorded under its context.
      (should (null (cerebro--with-logged-errors "tick" (error "boom") 2)))
      (should (equal (caar logged) "tick"))
      (should (string-match-p "boom" (cdar logged))))))

(ert-deftest cerebro-test/autostart-without-vterm-lands-in-the-error-log ()
  "The failure that made this log exist: eight declared agents, an
empty fleet, and the only trace a message the layout painted over half a
second later."
  (let (logged)
    (cerebro-test--with-autostart
      (cl-letf (((symbol-function 'cerebro--vterm-available-p) (lambda () nil))
                ((symbol-function 'cerebro--log-error)
                 (lambda (_root context message) (push (cons context message) logged))))
        (cerebro)
        (should (equal (caar logged) "autostart"))
        (should (string-match-p "vterm" (cdar logged)))
        ;; And still said out loud, in the words it always used.
        (should (member "cerebro: vterm is not installed, so nothing was autostarted"
                        cerebro-test--autostart-messages))))))

(ert-deftest cerebro-test/a-roster-that-refuses-is-recorded-before-it-signals ()
  "`M-x cerebro' shows the roster's own refusal, which is the loud half; the
log is what still has it once the navigator has moved on."
  (let ((root (make-temp-file "cerebro-test-" t))
        logged)
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--log-error)
                   (lambda (_root context message) (push (cons context message) logged)))
                  ((symbol-function 'call-process)
                   (lambda (&rest _)
                     (insert "roster: .cerebro/roster.conf line 3: 'autostrt' is not a word\n")
                     2)))
          (let ((cerebro--fleet-cache nil))
            (should-error (cerebro--fleet root)))
          (should (equal (caar logged) "roster"))
          (should (string-match-p "autostrt" (cdar logged))))
      (delete-directory root t))))

;; ---------------------------------------------------------------------------
;; The planners wake on a condition alone: no floor, and a guard instead

(ert-deftest cerebro-test/a-parked-bead-is-not-work-a-planner-can-take ()
  "`plan-bead' parks a bead it cannot decide alone with `human', and marks a
P4 it asked about and got no answer for with `triage:declined'.  Both are
durable *because* the pass ends; the trigger has to read them the same way
the skill's own queries do, or it starts a session to find nothing it may
touch."
  (let ((beads (list '((id . "cb-1") (priority . 0) (labels . []))
                     '((id . "cb-2") (priority . 0) (labels . ["human"]))
                     '((id . "cb-3") (priority . 4) (labels . ["triage:declined"]))
                     '((id . "cb-4") (priority . 4) (labels . [])))))
    (should (equal (mapcar (lambda (b) (alist-get 'id b))
                           (cerebro--actionable-beads beads))
                   '("cb-1" "cb-4")))))

(ert-deftest cerebro-test/a-blocked-bead-is-still-a-planner-s-work ()
  "`skills/plan-bead' plans beads whose blockers are unbuilt on purpose - `bd
ready' hides the ones most worth having planned.  So blockedness is not a
reason to leave a planner asleep, and only what the navigator holds is."
  (let ((beads (list '((id . "cb-5") (priority . 2) (labels . [])
                       (dependency_count . 2)))))
    (should (equal (length (cerebro--actionable-beads beads)) 1))))

(ert-deftest cerebro-test/a-pass-that-changed-nothing-does-not-start-another ()
  "The guard that replaces the planners' floor: a trigger naming exactly the
work its own last pass was started for is a pass that could not clear it -
a P0 parked in the navigator's queue, a crash - and starting it again would
be a loop at the speed of the end grace."
  (let* ((context (cerebro-test--context '(p0-unplanned "cb-9zz")))
         (fingerprint (cerebro--trigger-fingerprint "planner" context))
         (again (cons (cons 'last-fingerprint fingerprint) context)))
    ;; Nothing recorded yet - a role this Emacs has not started - is not a
    ;; match, and starts.
    (should (equal (cerebro--trigger (cerebro-test--interactive "X" "planner" 'standby)
                                     context)
                   "P0 cb-9zz unplanned"))
    (should (null (cerebro--trigger (cerebro-test--interactive "X" "planner" 'standby)
                                    again)))))

(ert-deftest cerebro-test/work-that-moved-starts-the-next-pass-at-once ()
  "The guard is a comparison, not a clock: the moment anything the trigger
measures changes - a bead arrives, one is planned, an implementer comes up -
the next pass starts on the next tick with no interval to wait out."
  (let* ((before (cerebro-test--context '(planned . 1) '(implementers . 3)))
         (fingerprint (cerebro--trigger-fingerprint "planner" before))
         (moved (cons (cons 'last-fingerprint fingerprint)
                      (cerebro-test--context '(planned . 1) '(implementers . 3)
                                             '(actionable-ids "cb-new")))))
    (should (null (cerebro--trigger (cerebro-test--interactive "X" "planner" 'standby)
                                    (cons (cons 'last-fingerprint fingerprint) before))))
    (should (equal (cerebro--trigger (cerebro-test--interactive "X" "planner" 'standby)
                                     moved)
                   "buffer 1 of 3"))))

(ert-deftest cerebro-test/a-launch-that-never-became-a-session-is-not-a-pass ()
  "The guard holds a pass that changed nothing, never a pass that never ran.

Seen in the fleet: a P4 arrived, the trigger fired, and the view recorded
Xavier\='s start - reason and fingerprint - at the moment it *attempted* the
launch. No session ever appeared: no state transition, no end, and no recorded
abnormal exit either, so the row went back to standby. From then on the
fingerprint matched on every tick and the guard held him, for a bead only his
triage pass could take. The board could not change, because he was the one who
would have changed it.

A pass that ran leaves an end later than its start. A launch that produced
nothing leaves the previous pass\='s end, which is earlier - so the two are
told apart by the comparison already in the context, and the guard applies to
the first alone."
  (let* ((ran (cerebro-test--context '(p0-unplanned "cb-9zz")
                                     '(started-at . 999200.0) '(ended-at . 999800.0)))
         (never (cerebro-test--context '(p0-unplanned "cb-9zz")
                                       '(started-at . 999200.0) '(ended-at . 999000.0)))
         (fingerprint (cerebro--trigger-fingerprint "planner" ran))
         (held (lambda (context)
                 (cerebro--trigger (cerebro-test--interactive "X" "planner" 'standby)
                                   (cons (cons 'last-fingerprint fingerprint) context)))))
    ;; A pass that ran and cleared nothing: held, which is the whole point.
    (should (null (funcall held ran)))
    ;; A launch that never became a session: retried on the next tick.
    (should (equal (funcall held never) "P0 cb-9zz unplanned"))))

(ert-deftest cerebro-test/a-role-this-emacs-never-started-is-never-held ()
  "No start, no fingerprint, nothing to compare - and nothing to hold."
  (let ((context (cerebro-test--context '(p0-unplanned "cb-9zz")
                                        '(started-at) '(ended-at))))
    (should (equal (cerebro--trigger (cerebro-test--interactive "X" "planner" 'standby)
                                     context)
                   "P0 cb-9zz unplanned"))))

(ert-deftest cerebro-test/a-start-that-produced-no-pass-is-a-failed-start ()
  "The same comparison the no-progress guard makes, named for what it means.

A pass that ran leaves an `ended-at\=' later than its `started-at\='. A launch
that never became a session leaves the previous pass\='s, which is earlier - or
nothing at all, for a role this Emacs has started once and never seen finish."
  (should (cerebro--start-failed-p 1000.0 900.0))
  (should (cerebro--start-failed-p 1000.0 nil))
  (should (cerebro--start-failed-p 1000.0 1000.0))
  (should-not (cerebro--start-failed-p 1000.0 1100.0))
  ;; Never started is not a failed start.
  (should-not (cerebro--start-failed-p nil nil))
  (should-not (cerebro--start-failed-p nil 900.0)))

(ert-deftest cerebro-test/a-launch-that-keeps-failing-is-tried-less-often ()
  "b94e782 traded a permanent park for a hot loop, and both are wrong.

Before it, a launch that produced no session recorded its fingerprint and the
no-progress guard parked the role for ever. After it the role is retried - and
nothing bounded that, so a launch refused by `scripts/launch-preflight\=' was
attempted every five seconds: 135 `start\=' lines for Xavier in one sitting,
because local `main' was ahead of `origin/main\=' and the preflight said no to
every one of them.

The first retry stays immediate, which is the case b94e782 exists for - a
session that died once should come back on the next tick. What escalates is
the second and every one after it."
  (should (equal (cerebro--retry-delay 0) 0))
  (should (equal (cerebro--retry-delay 1) 0))
  (should (equal (cerebro--retry-delay 2) 30))
  (should (equal (cerebro--retry-delay 3) 120))
  (should (equal (cerebro--retry-delay 4) 600))
  ;; Capped: a launch that has failed all morning is tried every ten minutes,
  ;; not once a day.
  (should (equal (cerebro--retry-delay 50) 600))
  ;; And the ceiling is the last entry of the schedule, whatever it is set to.
  (let ((cerebro-retry-backoff '(0 10)))
    (should (equal (cerebro--retry-delay 1) 0))
    (should (equal (cerebro--retry-delay 2) 10))
    (should (equal (cerebro--retry-delay 99) 10))))

(ert-deftest cerebro-test/give-up-after-the-fifth-silent-failed-start ()
  "A fleet that has failed to start thirty times is not going to succeed on
the thirty-first without a human (cb-ccl).  The predicate is asked about the
start being decided, so the fifth is the one that does not happen."
  (let ((cerebro-give-up-after 5))
    (should (cerebro--give-up-p t 4))
    (should (cerebro--give-up-p t 9))
    (should-not (cerebro--give-up-p t 3))
    ;; A start that follows a pass is not a failure at all, whatever the
    ;; count behind it says.
    (should-not (cerebro--give-up-p nil 9))))

(ert-deftest cerebro-test/start-due-gives-up-and-disarms ()
  "The fifth silent failure launches nothing, leaves the name disarmed - so
`cerebro--apply-standby' shows it `dead' rather than promising a retry - and
says so in both logs."
  (let* ((root (file-name-as-directory (make-temp-file "cerebro-root" t)))
         (launched nil)
         (said nil))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--launch)
                   (lambda (a) (push (cerebro-agent-name a) launched)))
                  ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
                  ((symbol-function 'cerebro--trigger-context)
                   (lambda (&rest _)
                     '((now . 1000000.0) (implementers . 2) (planned . 4)
                       (planned-ids "cb-1" "cb-2" "cb-3" "cb-4")
                       (p0-unplanned) (p4-unranked . 0)
                       (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
          (make-directory (expand-file-name ".claude/cerebro" root) t)
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (let ((cerebro-log-verbosity 'decisions)
                (cerebro-give-up-after 5)
                (cerebro--last-exit '(("Cyclops" :code "137" :line nil))))
            (with-temp-buffer
              (setq cerebro--agents
                    (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby))
                    cerebro--parked nil
                    cerebro--seen-up nil
                    cerebro--armed '("Cyclops")
                    cerebro--started-at '(("Cyclops" . 900000.0))
                    cerebro--failed-starts '(("Cyclops" . 4)))
              (cerebro--start-due root (seconds-to-time 1000000.0))
              (should-not launched)
              (should-not (member "Cyclops" cerebro--armed))
              (should (equal (alist-get "Cyclops" cerebro--last-exit nil nil #'equal)
                             '(:code "137" :line nil :gave-up t)))
              (should (member "Cyclops" (cerebro--failed-names cerebro--last-exit)))
              (should (seq-find (lambda (m) (string-match-p "gave up after 5 failed starts" m))
                                said))
              ;; The row, the placeholder and the message all read one count.
              ;; `cerebro--failed-starts' counts the failures BEFORE the start
              ;; being decided, so leaving it at 4 had the echo area say five
              ;; and the row say four about the same five sessions.
              (should (equal (alist-get "Cyclops" cerebro--failed-starts nil nil #'equal) 5))
              (let ((decisions (with-temp-buffer
                                 (insert-file-contents
                                  (expand-file-name ".cerebro/state/decisions.jsonl" root))
                                 (buffer-string)))
                    (errors (with-temp-buffer
                              (insert-file-contents
                               (expand-file-name ".cerebro/state/errors.jsonl" root))
                              (buffer-string))))
                (should (string-match-p "\"event\":\"give-up\"" decisions))
                (should (string-match-p "\"context\":\"start Cyclops\"" errors))
                (should (string-match-p
                         "gave up after 5 failed starts; the last session exited with code 137 and printed nothing"
                         errors)))
              ;; A name with no record at all still gets one, so the row has
              ;; something to show.
              (setq cerebro--last-exit nil
                    cerebro--armed '("Cyclops"))
              (cerebro--start-due root (seconds-to-time 1000000.0))
              (should-not launched)
              (should (equal (alist-get "Cyclops" cerebro--last-exit nil nil #'equal)
                             '(:code "?" :line nil :gave-up t))))))
      (delete-directory root t))))

(ert-deftest cerebro-test/exit-line-and-placeholder-for-a-name-the-view-gave-up-on ()
  "34 failed starts rendered identically to none.  A name the view has given
up on says so on the row and behind `RET'."
  (let ((cerebro-give-up-after 5))
    (should (equal (cerebro--exit-line '(:code "137" :line nil :gave-up t) 5)
                   "✗ exited with code 137, 5 failed starts — press s"))
    ;; A line, if there is one, still wins: it is the actionable half.
    (should (equal (cerebro--exit-line '(:code "2" :line "cerebro: boom" :gave-up t) 5)
                   "✗ boom"))
    (let ((cerebro--last-exit '(("Storm" :code "137" :line nil :gave-up t))))
      (should (equal (cerebro--placeholder
                      (cerebro-test--agent "Storm" "implementer" 'implementer 'dead)
                      nil 5)
                     (concat "Storm is not running.\n"
                             "Its last 5 sessions ended without a pass (last exit code 137)"
                             " and printed nothing; the view has stopped retrying.\n"
                             "Press s to start it."))))))

(ert-deftest cerebro-test/two-planners-are-not-started-in-the-same-breath ()
  "One planner start per `cerebro-role-start-spacing\=', because two racing.

Both planners answer the same buffer rule off the same panel, so a tick where
it is true is a tick where it is true for both - and the fleet started Xavier
and Beast in one breath more than once. They then race for the same candidate,
over startup rather than research: the `planning:<name>\=' label is taken
before the research, so the stretch neither can see is launch to that label
reaching the remote - about a minute on this fleet.

Spacing is per ROLE and counts PEERS only. A role\='s own restart is not the
race - nothing to collide with - and holding it would undo the retry that
`cerebro-test/a-launch-that-never-became-a-session-is-not-a-pass\=' asks for."
  (let ((spacing 30))
    ;; A peer started ten seconds ago: too soon.
    (should (cerebro--role-start-too-soon-p '("Beast") '(("Beast" . 990.0)) spacing 1000.0))
    ;; Forty seconds ago: the spacing has passed.
    (should-not (cerebro--role-start-too-soon-p '("Beast") '(("Beast" . 960.0)) spacing 1000.0))
    ;; Exactly the spacing is not too soon - the window is closed at its end.
    (should-not (cerebro--role-start-too-soon-p '("Beast") '(("Beast" . 970.0)) spacing 1000.0))
    ;; A peer this Emacs has never started cannot have started too recently.
    (should-not (cerebro--role-start-too-soon-p '("Beast") nil spacing 1000.0))
    ;; No peers at all - one planner, or a role with a single holder.
    (should-not (cerebro--role-start-too-soon-p nil '(("Beast" . 999.0)) spacing 1000.0))
    ;; A role with no spacing declared is never held.
    (should-not (cerebro--role-start-too-soon-p '("Beast") '(("Beast" . 999.0)) nil 1000.0))
    ;; Any one recent peer is enough, whichever it is.
    (should (cerebro--role-start-too-soon-p '("Beast" "Ororo")
                                            '(("Beast" . 100.0) ("Ororo" . 995.0))
                                            spacing 1000.0))))

(ert-deftest cerebro-test/role-peers-are-the-other-holders-of-one-role ()
  (let ((agents (list (cerebro-test--interactive "Xavier" "planner" 'standby)
                      (cerebro-test--interactive "Beast" "planner" 'standby)
                      (cerebro-test--interactive "Psylocke" "verifier" 'standby))))
    (should (equal (cerebro--role-peers (car agents) agents) '("Beast")))
    (should (equal (cerebro--role-peers (nth 1 agents) agents) '("Xavier")))
    ;; The only holder of its role has no peers, so nothing can space it out.
    (should (null (cerebro--role-peers (nth 2 agents) agents)))))

(ert-deftest cerebro-test/the-planners-are-the-role-that-is-spaced-out ()
  "The setting is an alist keyed on role, like every other per-role knob here:
the roles more than one agent holds and whose condition comes true for all of
them at once."
  (should (equal (cerebro--role-start-spacing "planner") 30))
  (should (null (cerebro--role-start-spacing "verifier")))
  ;; And the implementers since cb-1or.1: a queue that fills is a condition
  ;; true for every standby builder on the same tick.
  (should (equal (cerebro--role-start-spacing "implementer") 30)))

(ert-deftest cerebro-test/a-declared-spacing-is-a-whole-number-of-seconds-or-nothing ()
  "What a project may write against `role_start_spacing_<role>\=' in its own
`project.conf\=', and what the three answers are: a number, nothing declared,
and something that is not a number - which is not the same as nothing and
gets said out loud rather than silently ignored."
  (should (equal (cerebro--spacing-seconds "45") 45))
  ;; Zero is a value: never space this role. It is the only way a project can
  ;; opt a two-holder role out once the per-role key exists.
  (should (equal (cerebro--spacing-seconds "0") 0))
  (should (equal (cerebro--spacing-seconds " 45 ") 45))
  ;; Nothing declared: `project-conf' prints an empty line for a key it has not
  ;; got, and the `defcustom' answers for that role.
  (should (null (cerebro--spacing-seconds "")))
  (should (null (cerebro--spacing-seconds nil)))
  (should (null (cerebro--spacing-seconds "  ")))
  ;; Declared, and not a whole number of seconds.
  (dolist (raw '("-5" "soon" "30s" "4.5"))
    (should (eq (cerebro--spacing-seconds raw) 'bad))))

(ert-deftest cerebro-test/a-project-declared-spacing-beats-the-defcustom ()
  "The project wins.  `cerebro-role-start-spacing\=' is the fallback for a role
the project says nothing about and nothing else: a number in one navigator\='s
init must not decide whether every clone of a project races."
  (let ((cerebro-role-start-spacing '(("planner" . 30) ("implementer" . 30))))
    (should (equal (cerebro--role-start-spacing "planner" '(("planner" . 45))) 45))
    ;; A role the project says nothing about falls back.
    (should (equal (cerebro--role-start-spacing "implementer" '(("planner" . 45))) 30))
    ;; `0' is truthy in elisp, and a precedence written on the wrong test would
    ;; silently reassert 30 over a declared "never space this role".
    (should (equal (cerebro--role-start-spacing "planner" '(("planner" . 0))) 0))
    ;; Declared nowhere at all is still nil, which is never too soon.
    (should (null (cerebro--role-start-spacing "verifier" nil)))))

(ert-deftest cerebro-test/the-cadence-roles-are-not-held-by-the-guard ()
  "Moira and Cypher come back on the hour whatever the fleet looks like -
what they watch moves outside it, so \"nothing changed here\" is not evidence
of anything.  The guard holds a condition, never a cadence."
  (let* ((cerebro-cadence-triggers '(("user-feedback" . 3600)))
         (context (cerebro-test--context '(gh . failed) '(ended-at . 996000.0)))
         (fingerprint (cerebro--trigger-fingerprint "user-feedback" context)))
    (should (equal (cerebro--trigger
                    (cerebro-test--interactive "X" "user-feedback" 'standby)
                    (cons (cons 'last-fingerprint fingerprint) context))
                   "60m since its last pass"))))

(ert-deftest cerebro-test/planner-want-is-one-each-above-the-floor ()
  "One planned bead per running implementer, and never fewer than the floor.
The floor is a `defcustom' rather than the literal 2 the two call sites used
to spell, so `scripts/planner-buffer' can be held to it."
  (should (equal (cerebro--planner-want 0) 2))
  (should (equal (cerebro--planner-want 2) 2))
  (should (equal (cerebro--planner-want 5) 5))
  (let ((cerebro-planner-buffer-floor 4))
    (should (equal (cerebro--planner-want 3) 4))
    (should (equal (cerebro--planner-want 6) 6))))

(ert-deftest cerebro-test/the-planners-have-no-floor ()
  "The floor was the only thing damping a trigger a pass could not clear, and
the guard does that job by asking whether anything changed.  A clock in its
place would only add latency to every real change."
  (should (equal (cerebro-wake-interval "Xavier" "planner") 0)))

(ert-deftest cerebro-test/every-implementer-on-the-roster-wants-a-bead ()
  "Since cb-1or.1 a builder between beads has no session and is started by a
planned bead, so the buffer is sized to the roster and not to what is up:
standby, dead, idle and working all count, an interactive row never does,
and one told to finish is the only implementer left out (cb-1or.3)."
  (let ((agents (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working)
                      (cerebro-test--agent "Rogue" "implementer" 'implementer 'idle)
                      (cerebro-test--agent "Storm" "implementer" 'implementer 'standby)
                      (cerebro-test--agent "Gambit" "implementer" 'implementer 'dead)
                      (cerebro-test--agent "Bishop" "implementer" 'implementer 'working)
                      (cerebro-test--interactive "Psylocke" "verifier" 'idle))))
    (should (equal (cerebro--implementer-count agents (lambda (_) nil)) 5))
    (should (equal (cerebro--implementer-count agents (lambda (name) (equal name "Bishop")))
                   4))))

(ert-deftest cerebro-test/an-implementer-is-started-for-a-planned-bead-and-not-for-having-died ()
  "The condition is work, not a death (cb-1or.1).  A standby implementer with
nothing planned stays down however many starts have failed behind it; one
with a planned, unclaimed bead is started and the reason says how many."
  (let ((cyclops (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)))
    (should (null (cerebro--trigger
                   cyclops (cerebro-test--context '(planned-ids)
                                                  '(failed-starts . 0)
                                                  '(started-at . 999000.0)
                                                  '(floor . 0)))))
    (should (null (cerebro--trigger
                   cyclops (cerebro-test--context '(planned-ids)
                                                  '(failed-starts . 5)
                                                  '(started-at . 999000.0)
                                                  '(floor . 0)))))
    (should (equal (cerebro--trigger
                    cyclops (cerebro-test--context '(planned-ids "cb-1")
                                                   '(failed-starts . 0)
                                                   '(started-at . 999000.0)
                                                   '(floor . 0)))
                   "1 planned, unclaimed"))
    (should (equal (cerebro--trigger
                    cyclops (cerebro-test--context '(planned-ids "cb-1" "cb-2")
                                                   '(failed-starts . 2)
                                                   '(started-at . 999000.0)
                                                   '(floor . 0)))
                   "2 planned, unclaimed"))))

(ert-deftest cerebro-test/the-implementers-have-no-floor ()
  "A dead builder is the fleet short one builder, and ten minutes of that is
ten minutes of a bead nobody is taking.  The backoff is what spaces a retry
that keeps failing; a floor would only delay the first one."
  (should (equal (cerebro-wake-interval "Cyclops" "implementer") 0)))

(ert-deftest cerebro-test/retry-wait-and-figure ()
  "The arithmetic the row and the decision share, and how it is spelled."
  (let ((cerebro-retry-backoff '(0 30 120 600)))
    ;; The first entry is 0: a session that died once comes straight back.
    (should (equal (cerebro--retry-wait 0 999990.0 1000000.0) 0))
    (should (equal (cerebro--retry-wait 1 999990.0 1000000.0) 0))
    ;; Two failures: 30s from the failed start, 10s of which have gone.
    (should (equal (cerebro--retry-wait 2 999990.0 1000000.0) 20.0))
    (should (equal (cerebro--retry-wait 2 999900.0 1000000.0) 0))
    ;; Never started by this Emacs: nothing to measure from, so nothing to wait.
    (should (equal (cerebro--retry-wait 3 nil 1000000.0) 0)))
  (should (equal (cerebro--retry-figure 45) "45s"))
  (should (equal (cerebro--retry-figure 60) "1m"))
  (should (equal (cerebro--retry-figure 61) "2m"))
  (should (equal (cerebro--retry-figure 600) "10m")))

(ert-deftest cerebro-test/standby-label-for-an-implementer ()
  "The For column of a dead builder's row: when it comes back, and how many
starts have come to nothing - a launcher refused all morning reads as
\"9 failed\" rather than as a row that has simply stopped moving."
  (let ((cerebro-retry-backoff '(0 30 120 600))
        (cyclops (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)))
    ;; The ordinary case since cb-1or.1: nothing failed, so the row names the
    ;; condition it waits for, the way a planner's names its buffer rule.
    (should (equal (cerebro--standby-label
                    cyclops (cerebro-test--context '(failed-starts . 0)
                                                   '(started-at . 999990.0)))
                   "→ planned bead"))
    ;; The clock only while a failed start is actually backing off.
    (should (equal (cerebro--standby-label
                    cyclops (cerebro-test--context '(failed-starts . 3)
                                                   '(started-at . 999925.0)))
                   "↻ retry in 45s, 3 failed"))
    ;; A retry that is due waits on the condition like any other standby row.
    (should (equal (cerebro--standby-label
                    cyclops (cerebro-test--context '(failed-starts . 3)
                                                   '(started-at . 990000.0)))
                   "→ planned bead"))
    ;; Past the end of the schedule the last entry is the ceiling, so a
    ;; launcher refused all morning is retried steadily and says so.
    (should (equal (cerebro--standby-label
                    cyclops (cerebro-test--context '(failed-starts . 9)
                                                   '(started-at . 999999.0)))
                   "↻ retry in 10m, 9 failed"))))

(ert-deftest cerebro-test/a-role-row-backing-off-shows-the-retry-clock ()
  "Psylocke sat at 32 failed starts showing `→ merged, unverified' - the row
of a verifier waiting for a merge, not of one nothing could start.  While a
start is backing off the clock and the count come first, whatever the role
(cb-ccl); once it is due the role's own condition is back."
  (should (equal (cerebro--standby-label
                  (cerebro-test--interactive "Psylocke" "verifier" 'standby)
                  (cerebro-test--context '(failed-starts . 4) '(started-at . 999445.0)))
                 "↻ retry in 45s, 4 failed"))
  (should (equal (cerebro--standby-label
                  (cerebro-test--interactive "Xavier" "planner" 'standby)
                  (cerebro-test--context '(failed-starts . 4) '(started-at . 999445.0)))
                 "↻ retry in 45s, 4 failed"))
  ;; Nothing backing off: the condition, exactly as before.
  (should (equal (cerebro--standby-label
                  (cerebro-test--interactive "Psylocke" "verifier" 'standby)
                  (cerebro-test--context '(failed-starts . 4) '(started-at . 990000.0)))
                 "→ merged, unverified"))
  (should (equal (cerebro--standby-label
                  (cerebro-test--interactive "Xavier" "planner" 'standby)
                  (cerebro-test--context '(failed-starts . 4) '(started-at . 990000.0)))
                 "→ buffer < 2")))

(ert-deftest cerebro-test/standby-label-forms ()
  "The For column of a standby row: what it is waiting for, not how long it
has been there - there is no session for an elapsed time to describe."
  (let ((cerebro-cadence-triggers '(("user-feedback" . 3600) ("reviewer" . 3600)
                                    ("architect" . 86400))))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "planner" 'standby)
                    (cerebro-test--context '(implementers . 3)))
                   "→ buffer < 3"))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "planner" 'standby)
                    (cerebro-test--context '(implementers . 1)))
                   "→ buffer < 2"))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "verifier" 'standby)
                    (cerebro-test--context))
                   "→ merged, unverified"))
    ;; A cadence role counts down to its next start.
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "user-feedback" 'standby)
                    (cerebro-test--context '(ended-at . 997420.0)))
                   "→17m"))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "architect" 'standby)
                    (cerebro-test--context '(ended-at . 989440.0)))
                   "→21h04"))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "architect" 'standby)
                    (cerebro-test--context '(ended-at . 900000.0)))
                   "→due"))
    ;; A `gh' reader that did not answer is said so where the countdown is,
    ;; because it is the countdown that is now the only thing left running.
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "reviewer" 'standby)
                    (cerebro-test--context '(ended-at . 997420.0) '(gh . failed)))
                   "→17m gh?"))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "orchestrator" 'standby)
                    (cerebro-test--context))
                   "→ unranked bead"))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "X" "sommelier" 'standby)
                    (cerebro-test--context))
                   ""))))

(ert-deftest cerebro-test/start-message-names-the-role-and-the-reason ()
  (should (equal (cerebro--start-message "Psylocke" "2 merged, unverified")
                 "cerebro: started Psylocke — 2 merged, unverified")))

(ert-deftest cerebro-test/entry-shows-the-standby-label-in-for ()
  "The label the caller computed, in place of the elapsed time a session has."
  (let* ((agent (cerebro-test--interactive "Psylocke" "verifier" 'standby nil
                                           "2026-08-14T09:00:00Z"))
         (row (nth 1 (cerebro--entry agent cerebro-test--now nil nil
                                     "→ merged, unverified"))))
    (should (equal (aref row 2) "standby"))
    (should (equal (aref row 4) "→ merged, unverified"))
    ;; No label computed: nothing, rather than half an hour of a session that
    ;; is not running.
    (should (equal (aref (nth 1 (cerebro--entry agent cerebro-test--now)) 4) ""))))

;; --- acting on a trigger --------------------------------------------------

(ert-deftest cerebro-test/start-due-launches-and-says-why ()
  "The whole loop, in one place: a standby row whose trigger is true is
started once, the navigator is told which role and why, and the floor stops
the next tick starting it again."
  (let ((launched nil)
        (said nil))
    (cl-letf (((symbol-function 'cerebro--launch)
               (lambda (a) (push (cerebro-agent-name a) launched)))
              ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _)
                 '((now . 1000000.0) (implementers . 2) (planned . 4)
                   (p0-unplanned) (p4-unranked . 0)
                   (merged-unverified . 2) (stale-verdicts . 0) (gh)))))
      (with-temp-buffer
        (setq cerebro--agents (list (cerebro-test--interactive "Psylocke" "verifier" 'standby)
                                    (cerebro-test--interactive "Moira" "user-feedback" 'waiting)
                                    (cerebro-test--interactive "Cerebro" "orchestrator" 'standby))
              cerebro--parked '(("Psylocke" . (990000.0 980000.0 nil))
                                ("Cerebro" . (990000.0 980000.0 nil)))
              cerebro--started-at '(("Psylocke" . 980000.0) ("Cerebro" . 980000.0)))
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000000.0))
        (should (equal launched '("Psylocke")))
        (should (equal said '("cerebro: started Psylocke — 2 merged, unverified")))
        ;; A second tick with the start fresh: the floor holds it.
        (setq cerebro--started-at '(("Psylocke" . 999900.0)))
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000000.0))
        (should (equal launched '("Psylocke")))))))

(ert-deftest cerebro-test/a-dead-implementer-is-retried-on-the-backoff ()
  "The same schedule the roles wait out, indexed by the same counter: a
session that dies once comes straight back, and one that keeps dying is
retried at 30s, 2m and then every 10m rather than every five seconds."
  (let ((launched nil)
        (said nil))
    (cl-letf (((symbol-function 'cerebro--launch)
               (lambda (a) (push (cerebro-agent-name a) launched)))
              ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
              ((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _)
                 '((now . 1000000.0) (implementers . 2) (planned . 4)
                   (planned-ids "cb-1" "cb-2" "cb-3" "cb-4")
                   (p0-unplanned) (p4-unranked . 0)
                   (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
      (with-temp-buffer
        (setq cerebro--agents
              (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby))
              cerebro--parked nil
              cerebro--seen-up nil
              cerebro--started-at '(("Cyclops" . 999990.0))
              cerebro--failed-starts '(("Cyclops" . 2)))
        ;; Two failures behind it and ten seconds since the last start: the
        ;; 30-second step of the schedule has not run out.
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000000.0))
        (should (null launched))
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000030.0))
        (should (equal launched '("Cyclops")))
        (should (equal said '("cerebro: started Cyclops — 4 planned, unclaimed")))
        (should (equal (cdr (assoc "Cyclops" cerebro--failed-starts)) 3))
        ;; Seen up after that start: the start produced a session, so the
        ;; count starts over and nothing is waited out.
        (setq launched nil said nil
              cerebro--started-at '(("Cyclops" . 999990.0))
              cerebro--seen-up '(("Cyclops" . 999995.0))
              cerebro--failed-starts '(("Cyclops" . 2)))
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000000.0))
        (should (equal launched '("Cyclops")))
        (should (equal (cdr (assoc "Cyclops" cerebro--failed-starts)) 0))))
    ;; And with nothing planned there is nothing to come back for, however
    ;; long ago the last start was: the backoff is not the condition.
    (setq launched nil)
    (cl-letf (((symbol-function 'cerebro--launch)
               (lambda (a) (push (cerebro-agent-name a) launched)))
              ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
              ((symbol-function 'message) #'ignore)
              ((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _)
                 '((now . 1000000.0) (implementers . 2) (planned . 0)
                   (planned-ids)
                   (p0-unplanned) (p4-unranked . 0)
                   (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
      (with-temp-buffer
        (setq cerebro--agents
              (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby))
              cerebro--parked nil
              cerebro--seen-up '(("Cyclops" . 999995.0))
              cerebro--started-at '(("Cyclops" . 990000.0))
              cerebro--failed-starts nil)
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000000.0))
        (should (null launched))))))

(ert-deftest cerebro-test/implementers-start-one-at-a-time ()
  "A queue that fills must not start the whole roster in one tick: the same
spacing the planners answer to, applied to the implementers since cb-1or.1."
  (let ((launched nil)
        (cerebro-role-start-spacing '(("planner" . 30) ("implementer" . 30))))
    (cl-letf (((symbol-function 'cerebro--launch)
               ;; The real one writes `cerebro--started-at', which is what
               ;; `cerebro--role-start-too-soon-p' reads - a stub that does
               ;; not cannot make the spacing fire at all.
               (lambda (a)
                 (push (cerebro-agent-name a) launched)
                 (setf (alist-get (cerebro-agent-name a) cerebro--started-at
                                  nil nil #'equal)
                       (float-time (seconds-to-time 1000000.0)))))
              ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
              ((symbol-function 'message) #'ignore)
              ((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _)
                 '((now . 1000000.0) (implementers . 0) (planned . 2)
                   (planned-ids "cb-1" "cb-2")
                   (p0-unplanned) (p4-unranked . 0)
                   (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
      (with-temp-buffer
        (setq cerebro--agents
              (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)
                    (cerebro-test--agent "Rogue" "implementer" 'implementer 'standby))
              cerebro--parked nil
              cerebro--seen-up nil
              cerebro--started-at nil
              cerebro--start-fingerprints nil
              cerebro--failed-starts nil)
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000000.0))
        (should (equal launched '("Cyclops")))
        ;; 30 seconds later the other one goes - the first is up by then, so
        ;; only one row is still standby and the spacing has run out for it.
        (setq launched nil
              cerebro--agents
              (list (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working)
                    (cerebro-test--agent "Rogue" "implementer" 'implementer 'standby)))
        (cl-letf (((symbol-function 'cerebro--trigger-context)
                   (lambda (&rest _)
                     '((now . 1000030.0) (implementers . 1) (planned . 2)
                       (planned-ids "cb-1" "cb-2")
                       (p0-unplanned) (p4-unranked . 0)
                       (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
          (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000030.0)))
        (should (equal launched '("Rogue")))
        ;; And on the tick before that it is held, which is the whole point.
        (setq launched nil)
        (cl-letf (((symbol-function 'cerebro--trigger-context)
                   (lambda (&rest _)
                     '((now . 1000010.0) (implementers . 1) (planned . 2)
                       (planned-ids "cb-1" "cb-2")
                       (p0-unplanned) (p4-unranked . 0)
                       (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
          (setq cerebro--started-at '(("Cyclops" . 1000000.0)))
          (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000010.0)))
        (should (null launched))))))

(ert-deftest cerebro-test/an-evaluation-records-the-spacing-in-force ()
  "`spaced_out: true\=' beside no number is a line that says a start was held and
leaves the reader to guess by how much - and with the value declared per
project the guess gets worse, not better.  This is what makes \"it held for
seven ticks\" answerable as \"it held because the number in force was 30\"."
  (let ((root (make-temp-file "cerebro-test-" t))
        (cerebro-log-verbosity 'evaluations)
        (cerebro--log-seen nil))
    (unwind-protect
        (let ((file (expand-file-name ".cerebro/state/decisions.jsonl" root)))
          (make-directory (expand-file-name ".cerebro/state" root) t)
          (cerebro--log-evaluation
           root (cerebro-test--interactive "Beast" "planner" 'standby)
           "buffer 0 of 4"
           '((spacing . 45) (spaced-out . t)))
          (let ((line (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (string-match-p "\"spacing\":45" line))
            (should (string-match-p "\"spaced_out\":true" line))))
      (delete-directory root t))))

(ert-deftest cerebro-test/a-project-that-declares-no-spacing-gap-starts-both-planners-at-once ()
  "The whole path: a number in the consumer\='s own `project.conf\=' deciding which
sessions `cerebro--start-due\=' launches.  A declared 0 is \"never space this
role\" and both planners go on one tick; a declared 90 holds the second where
the built-in 30 would have let it through."
  (let ((launched nil)
        (cerebro-role-start-spacing '(("planner" . 30) ("implementer" . 30))))
    (cl-letf (((symbol-function 'cerebro--launch)
               ;; The real one writes `cerebro--started-at', which is what the
               ;; spacing reads - a stub that does not cannot make it fire.
               (lambda (a)
                 (push (cerebro-agent-name a) launched)
                 (setf (alist-get (cerebro-agent-name a) cerebro--started-at
                                  nil nil #'equal)
                       (float-time (seconds-to-time 1000000.0)))))
              ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
              ((symbol-function 'message) #'ignore)
              ((symbol-function 'cerebro--trigger-context)
               (lambda (&rest _)
                 '((now . 1000000.0) (implementers . 2) (planned . 0)
                   (planned-ids) (p0-unplanned) (actionable-ids "cb-x") (p4-unranked . 0)
                   (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
      (with-temp-buffer
        (setq cerebro--agents
              (list (cerebro-test--interactive "Xavier" "planner" 'standby)
                    (cerebro-test--interactive "Beast" "planner" 'standby))
              cerebro--parked nil
              cerebro--seen-up nil
              cerebro--started-at nil
              cerebro--start-fingerprints nil
              cerebro--failed-starts nil
              ;; Pre-set, so no fork happens and the test is about the wiring.
              cerebro--project-spacing-cache '(("planner" . 0)))
        (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000000.0))
        (should (equal (sort (copy-sequence launched) #'string<) '("Beast" "Xavier")))
        ;; Ninety seconds, and the second planner is held at +35s - which the
        ;; `defcustom''s 30 would have let through.
        (setq launched nil
              cerebro--started-at '(("Xavier" . 1000000.0))
              cerebro--start-fingerprints nil
              cerebro--project-spacing-cache '(("planner" . 90))
              cerebro--agents
              (list (cerebro-test--interactive "Xavier" "planner" 'working)
                    (cerebro-test--interactive "Beast" "planner" 'standby)))
        (cl-letf (((symbol-function 'cerebro--trigger-context)
                   (lambda (&rest _)
                     '((now . 1000035.0) (implementers . 2) (planned . 0)
                       (planned-ids) (p0-unplanned) (actionable-ids "cb-x") (p4-unranked . 0)
                       (merged-unverified . 0) (stale-verdicts . 0) (gh)))))
          (cerebro--start-due "/tmp/nowhere" (seconds-to-time 1000035.0)))
        (should (null launched))))))

(ert-deftest cerebro-test/start-due-does-nothing-without-vterm ()
  "There is nothing to run a session in, and a trigger firing once every five
seconds into a `user-error' is not a way to say so."
  (let ((launched nil))
    (cl-letf (((symbol-function 'cerebro--launch)
               (lambda (a) (push (cerebro-agent-name a) launched)))
              ((symbol-function 'cerebro--vterm-available-p) (lambda () nil))
              ((symbol-function 'cerebro--trigger) (lambda (&rest _) "because"))
              ((symbol-function 'cerebro--trigger-context) (lambda (&rest _) nil))
              ((symbol-function 'message) #'ignore))
      (with-temp-buffer
        (setq cerebro--agents (list (cerebro-test--interactive "Psylocke" "verifier" 'standby)))
        (cerebro--start-due "/tmp/nowhere" (current-time))
        (should (null launched))))))

(ert-deftest cerebro-test/start-due-survives-a-launcher-that-cannot-start ()
  "One role that will not start must not stop the others - the rule every
other loop in this file already follows.

`debug-on-error' is bound off for the same reason the production path never
runs with it on: `with-demoted-errors' expands to
`condition-case-unless-debug', which re-signals while debugging - and ERT's
batch runner turns debugging on for the backtrace.  Emacs 28.2 failed here
while 30.1 passed on the same commit."
  (let ((launched nil)
        (debug-on-error nil))
    (cl-letf (((symbol-function 'cerebro--launch)
               (lambda (a) (if (equal (cerebro-agent-name a) "Psylocke")
                               (error "nope")
                             (push (cerebro-agent-name a) launched))))
              ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
              ((symbol-function 'cerebro--trigger) (lambda (&rest _) "because"))
              ((symbol-function 'cerebro--trigger-context) (lambda (&rest _) nil))
              ((symbol-function 'message) #'ignore))
      (with-temp-buffer
        (setq cerebro--agents (list (cerebro-test--interactive "Psylocke" "verifier" 'standby)
                                    (cerebro-test--interactive "Xavier" "planner" 'standby)))
        (cerebro--start-due "/tmp/nowhere" (current-time))
        (should (equal launched '("Xavier")))))))

(ert-deftest cerebro-test/trigger-context-counts-what-the-buffer-already-holds ()
  "No `bd' call of its own: the panel's own partition, the fleet list beside
it, and the roster - all of which this tick has already read."
  (let ((panel (get-buffer-create "*cerebro-beads-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--fleet)
                   (lambda (_) '(("Xavier" "planner" interactive)
                                 ("Beast" "planner" interactive)
                                 ("Rogue" "implementer" implementer))))
                  ((symbol-function 'cerebro--beads-panel-buffer) (lambda () panel)))
          (with-current-buffer panel
            (setq cerebro--beads
                  (cerebro-test--buckets
                   :planned '(((id . "a")) ((id . "b")))
                   :unplanned '(((id . "c") (priority . 0))
                                ((id . "d") (priority . 4))
                                ((id . "e") (priority . 4))
                                ((id . "b2") (priority . 4)
                                 (labels . ["triage:declined"]))
                                ((id . "f") (priority . 2)
                                 (labels . ["verdict:stale"])))
                   :merged '(((id . "g")) ((id . "h")) ((id . "i")))))
            (setq cerebro--beads-read-at 3.5))
          (with-temp-buffer
            (setq cerebro--agents
                  (list (cerebro-test--agent "Rogue" "implementer" 'implementer 'working)
                        (cerebro-test--agent "Gambit" "implementer" 'implementer 'dead)
                        (cerebro-test--interactive "Xavier" "planner" 'standby)))
            (let ((context (cerebro--trigger-context "/tmp/nowhere" (seconds-to-time 5.0))))
              (should (equal (alist-get 'now context) 5.0))
              (should (equal (alist-get 'planned context) 2))
              (should (equal (alist-get 'p0-unplanned context) '("c")))
              (should (equal (alist-get 'p4-unranked context) 2))
              ;; The ids behind that count, sorted, and a P4 the navigator has
              ;; parked is in neither (cb-5lx.2).
              (should (equal (alist-get 'unranked-ids context) '("d" "e")))
              ;; When the figures were asked for, not when they arrived.
              (should (equal (alist-get 'beads-read-at context) 3.5))
              (should (equal (alist-get 'merged-unverified context) 3))
              (should (equal (alist-get 'stale-verdicts context) 1))
              ;; Rogue is working and Gambit is dead, and both count: a dead
              ;; builder is one `s' away from needing a bead (cb-1or.3).
              (should (equal (alist-get 'implementers context) 2))
              ;; The ids behind that count, in panel order: what a standby
              ;; implementer is started for (cb-1or.1).
              (should (equal (alist-get 'planned-ids context) '("a" "b")))
              ;; No `gh' answer in this buffer, so nothing for the two rows
              ;; the key feeds - and not `failed', which would say it went away.
              (should (null (alist-get 'gh context))))))
      (kill-buffer panel))))

(ert-deftest cerebro-test/trigger-context-reads-buckets-by-name ()
  "Reordered and unrecognised buckets cannot retarget any role trigger
\(ah-vcof\). `cerebro--partition-beads' documents its association order as
descriptive only, so this hands `cerebro--trigger-context' a buckets value
shuffled from what the producer would build, with an extra `(future . ...)'
entry no reader names - the same shape a seventh bucket landing anywhere in
the list would produce - and asserts every count still comes from its own
key rather than its position."
  (let ((panel (get-buffer-create "*cerebro-beads-shuffled-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--fleet) (lambda (_) nil))
                  ((symbol-function 'cerebro--beads-panel-buffer) (lambda () panel)))
          (with-current-buffer panel
            (setq cerebro--beads
                  ;; Deliberately not the producer's own order, and carrying a
                  ;; bucket nothing here reads.
                  `((future . (((id . "z"))))
                    (merged . (((id . "g")) ((id . "h"))))
                    (paused . (((id . "p") (priority . 2) (labels . ("human" "verdict:stale")))))
                    (being-planned . nil)
                    (unplanned . (((id . "c") (priority . 0))
                                  ((id . "d") (priority . 4))))
                    (claimed . nil)
                    (planned . (((id . "a")) ((id . "b"))))))
            (setq cerebro--beads-read-at 3.5))
          (with-temp-buffer
            (setq cerebro--agents nil)
            (let ((context (cerebro--trigger-context "/tmp/nowhere" (seconds-to-time 5.0))))
              (should (equal (alist-get 'planned context) 2))
              (should (equal (alist-get 'p0-unplanned context) '("c")))
              (should (equal (alist-get 'p4-unranked context) 1))
              (should (equal (alist-get 'unranked-ids context) '("d")))
              (should (equal (alist-get 'merged-unverified context) 2))
              ;; Stale-verdicts reads every open bucket by name, paused
              ;; included - a bucket named `future' must not silently join
              ;; that count, nor may reordering drop `paused' from it.
              (should (equal (alist-get 'stale-verdicts context) 1))
              (should (equal (alist-get 'planned-ids context) '("a" "b"))))))
      (kill-buffer panel))))

(ert-deftest cerebro-test/the-panel-records-when-it-asked-not-only-when-it-heard ()
  "A bead ranked between the request and the answer is in neither; a reader
deciding whether the figures postdate a transition needs the earlier clock."
  (let ((panel (get-buffer-create "*cerebro-beads-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--draw-beads) #'ignore)
                  ((symbol-function 'cerebro--update-panel-header) #'ignore)
                  ((symbol-function 'cerebro--repo-root) (lambda () "/tmp/nowhere"))
                  ((symbol-function 'cerebro--request-beads)
                   (lambda (_root answer)
                     (with-current-buffer panel (setq cerebro--beads-requested-at 41.0))
                     (funcall answer (cerebro-test--buckets) nil)
                     'answered)))
          (cerebro--beads-render panel)
          (with-current-buffer panel
            (should (equal cerebro--beads-read-at 41.0))
            (should (null cerebro--beads-requested-at))))
      (kill-buffer panel))))

(ert-deftest cerebro-test/an-implementer-told-to-finish-wants-no-bead ()
  "A stop-flagged implementer finishes the bead it holds and takes no other,
so a bead planned for it is a bead planned for nobody.  `skills/plan-bead'
has always skipped it and this count did not, so with four up and one told to
finish the skill wanted three and the view wanted four - and the view started
a planner whose pass found a full buffer and ended."
  (let ((panel (get-buffer-create "*cerebro-beads-stop-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--fleet) (lambda (_) nil))
                  ((symbol-function 'cerebro--beads-panel-buffer) (lambda () panel)))
          (with-current-buffer panel (setq cerebro--beads (cerebro-test--buckets)))
          (with-temp-buffer
            (setq cerebro--agents
                  (list (cerebro-test--agent "Rogue" "implementer" 'implementer 'working)
                        (cerebro-test--agent "Gambit" "implementer" 'implementer 'working)))
            ;; Both up and neither told to finish: two. Without this the case
            ;; below could pass by counting nothing at all.
            (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) nil)))
              (should (equal (alist-get 'implementers
                                        (cerebro--trigger-context "/tmp/nowhere"
                                                                  (seconds-to-time 5.0)))
                             2)))
            (cl-letf (((symbol-function 'cerebro--stop-flag-p)
                       (lambda (_root name) (equal name "Gambit"))))
              (should (equal (alist-get 'implementers
                                        (cerebro--trigger-context "/tmp/nowhere"
                                                                  (seconds-to-time 5.0)))
                             1)))))
      (kill-buffer panel))))

(ert-deftest cerebro-test/trigger-context-without-a-panel-says-nothing-is-wanted ()
  "A fleet view whose panel has not answered yet must not read as an empty
buffer and a backlog of nothing - that would start both planners at once."
  (cl-letf (((symbol-function 'cerebro--fleet) (lambda (_) nil))
            ((symbol-function 'cerebro--beads-panel-buffer) (lambda () nil)))
    (with-temp-buffer
      (setq cerebro--agents nil)
      (let ((context (cerebro--trigger-context "/tmp/nowhere" (current-time))))
        (should (null (alist-get 'p0-unplanned context)))
        (should (equal (alist-get 'p4-unranked context) 0))
        (should (equal (alist-get 'merged-unverified context) 0))
        (should (equal (alist-get 'stale-verdicts context) 0))
        ;; A buffer nothing has counted is not a buffer that is short.
        (should (>= (alist-get 'planned context) 2))
        ;; And no ids at all, which is what keeps "no figures yet" from
        ;; starting a builder: `planned' reads `most-positive-fixnum' here,
        ;; so the implementer rule must key on this and never on that.
        (should (null (alist-get 'planned-ids context)))))))

;; --- the `gh' reader: what moved on GitHub since a role's pass ended ------

(defun cerebro-test--gh-time (s)
  "S, an ISO-8601 instant, as `float-time' - what ENDED-AT is measured in."
  (float-time (encode-time (iso8601-parse s))))

(ert-deftest cerebro-test/gh-moved-filters-by-time-author-and-draft ()
  "The open issues, and the open non-draft pull requests somebody else opened,
that moved after the role's last pass ended - in the order `gh' listed them."
  (let ((issues '(((number . 10) (updatedAt . "2026-08-24T11:00:00Z"))
                  ((number . 31) (updatedAt . "2026-08-24T13:00:00Z"))
                  ((number . 17) (updatedAt . "2026-08-24T12:30:00Z"))))
        (prs '(((number . 38) (author (login . "navigator")) (isDraft . nil)
                (updatedAt . "2026-08-24T13:00:00Z"))
               ((number . 39) (author (login . "outsider")) (isDraft . t)
                (updatedAt . "2026-08-24T13:00:00Z"))
               ((number . 40) (author (login . "outsider")) (isDraft . nil)
                (updatedAt . "2026-08-24T13:00:00Z"))
               ((number . 41) (author (login . "outsider")) (isDraft . nil)
                (updatedAt . "2026-08-24T11:00:00Z"))))
        (ended (cerebro-test--gh-time "2026-08-24T12:00:00Z")))
    (should (equal (cerebro--gh-moved issues prs "navigator" ended)
                   '((31 17) (40))))
    ;; No end to measure against: nothing moved (cb-b4m).  It used to be
    ;; everything still open, and with one open issue that started Moira on
    ;; every tick the floor allowed, for a day - "I have no idea what has
    ;; changed" is not a reason to start a session, it is a reason not to.
    (should (equal (cerebro--gh-moved issues prs "navigator" nil) '(nil nil)))
    ;; No login yet: nothing has been shown to be somebody else's, so no PR
    ;; can start Cypher - the issues are unaffected.
    (should (equal (cerebro--gh-moved issues prs nil ended) '((31 17) nil)))
    (should (equal (cerebro--gh-moved nil nil "navigator" ended) '(nil nil)))))

(ert-deftest cerebro-test/linked-beads-are-the-ones-with-a-github-ref ()
  "Which beads carry a GitHub issue, and when each last changed.

Moira\='s second job is keeping a linked issue\='s status comments in step with
its bead, and those changes happen on the board: the issue\='s own `updatedAt'
does not move for a CLAIMED or a MERGED (cb-b4m).  So the bead is the thing to
watch, and `external_ref' of the form `gh-<n>' is what makes one hers."
  (let ((beads '(((id . "cb-3qh") (external_ref . "gh-58")
                  (updated_at . "2026-08-24T12:36:41Z"))
                 ((id . "cb-none") (updated_at . "2026-08-24T13:00:00Z"))
                 ((id . "cb-jira") (external_ref . "jira-9")
                  (updated_at . "2026-08-24T13:00:00Z"))
                 ((id . "cb-odd") (external_ref . "gh-x")
                  (updated_at . "2026-08-24T13:00:00Z"))
                 ((id . "cb-bad") (external_ref . "gh-7")
                  (updated_at . "not a time")))))
    (should (equal (cerebro--linked-beads beads)
                   (list (list "cb-3qh" 58 (cerebro-test--gh-time "2026-08-24T12:36:41Z")))))
    (should (null (cerebro--linked-beads nil)))))

(ert-deftest cerebro-test/linked-moved-is-measured-against-the-last-pass ()
  "The linked beads that changed since this role\='s pass ended - and, with no
end to measure against, none of them, exactly as `cerebro--gh-moved' answers."
  (let ((linked '(("cb-1" 5 6.0) ("cb-2" 9 8.0))))
    (should (equal (cerebro--linked-moved linked 7.0) '(("cb-2" 9 8.0))))
    (should (equal (cerebro--linked-moved linked 1.0) linked))
    (should (null (cerebro--linked-moved linked 9.0)))
    (should (null (cerebro--linked-moved linked nil)))
    (should (null (cerebro--linked-moved nil 1.0)))))

(ert-deftest cerebro-test/gh-reader-marks-failure-and-keeps-the-last-answer ()
  "A `gh' that stops answering leaves the last answer standing and says so:
the trigger then reads `failed' rather than \"nothing moved\"."
  (let ((answers nil))
    (cl-letf (((symbol-function 'cerebro--run-async)
               (lambda (key _root _argv callback)
                 (funcall callback (cdr (assq key answers)))
                 'started))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
      (with-temp-buffer
        (setq answers `((gh-issues . "[{\"number\":31,\"updatedAt\":\"2026-08-24T13:00:00Z\"}]")
                        (gh-prs . "[]")
                        (gh-me . "navigator\n")))
        (cerebro--refresh-gh-when-due (current-buffer) 100.0)
        (should (equal cerebro--gh-issues
                       '(((number . 31) (updatedAt . "2026-08-24T13:00:00Z")))))
        (should (null cerebro--gh-prs))
        (should (equal cerebro--gh-me "navigator"))
        (should (equal cerebro--gh-as-of 100.0))
        (should (null cerebro--gh-failed-at))
        ;; Not due again five seconds later: each answer is a network call.
        (setq answers nil)
        (cerebro--refresh-gh-when-due (current-buffer) 105.0)
        (should (null cerebro--gh-failed-at))
        ;; Due, and `gh' is gone. The last answer stands; the failure is
        ;; stamped after it, which is what the context reads as `failed'.
        (cerebro--refresh-gh-when-due
         (current-buffer) (+ 100.0 cerebro-gh-refresh-seconds))
        (should (equal cerebro--gh-issues
                       '(((number . 31) (updatedAt . "2026-08-24T13:00:00Z")))))
        (should (> cerebro--gh-failed-at cerebro--gh-as-of))))))

(ert-deftest cerebro-test/gh-me-is-asked-once ()
  "The navigator's login does not change while Emacs is up, so it is asked for
until it answers and never again - unlike the two lists beside it."
  (let ((asked nil))
    (cl-letf (((symbol-function 'cerebro--run-async)
               (lambda (key _root _argv callback)
                 (push key asked)
                 (funcall callback (and (eq key 'gh-me) "navigator"))
                 'started))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
      (with-temp-buffer
        (cerebro--refresh-gh-when-due (current-buffer) 100.0)
        (should (memq 'gh-me asked))
        (setq asked nil)
        (cerebro--refresh-gh-when-due
         (current-buffer) (+ 100.0 cerebro-gh-refresh-seconds))
        (should (memq 'gh-issues asked))
        (should-not (memq 'gh-me asked))))))

(ert-deftest cerebro-test/gh-garbage-is-not-an-answer ()
  "A program exiting zero and printing something that is not JSON has not
answered - the same rule the panel and the sweeps already apply."
  (cl-letf (((symbol-function 'cerebro--run-async)
             (lambda (key _root _argv callback)
               (funcall callback (if (eq key 'gh-me) "navigator" "not json"))
               'started))
            ((symbol-function 'cerebro--repo-root) (lambda () default-directory)))
    (with-temp-buffer
      (cerebro--refresh-gh-when-due (current-buffer) 100.0)
      (should (null cerebro--gh-as-of))
      (should (equal cerebro--gh-failed-at 100.0)))))

(ert-deftest cerebro-test/trigger-context-carries-gh ()
  "The `gh' key: nil before the first answer, `failed' when the newest thing
that happened was a failure, and the moved lists when a whole pair has
arrived since. Per role, because each is measured against its own last pass."
  (cl-letf (((symbol-function 'cerebro--fleet) (lambda (_) nil))
            ((symbol-function 'cerebro--beads-panel-buffer) (lambda () nil)))
    (with-temp-buffer
      (setq cerebro--agents nil)
      ;; Nothing has answered yet: not `failed', which would say `gh' is down.
      (should (null (alist-get 'gh (cerebro--trigger-context "/tmp/nowhere"
                                                             (seconds-to-time 5.0)))))
      ;; A pair has arrived.
      (setq cerebro--gh-issues '(((number . 31) (updatedAt . "2026-08-24T13:00:00Z")))
            cerebro--gh-prs '(((number . 40) (author (login . "outsider"))
                               (isDraft . nil) (updatedAt . "2026-08-24T13:00:00Z")))
            cerebro--gh-me "navigator"
            cerebro--gh-as-of 100.0
            cerebro--gh-failed-at nil)
      (let* ((context (cerebro--trigger-context "/tmp/nowhere" (seconds-to-time 5.0)))
             (gh (alist-get 'gh context)))
        (should (functionp gh))
        ;; Ended before both moved: both count.
        (should (equal (funcall gh (cerebro-test--gh-time "2026-08-24T12:00:00Z"))
                       '((31) (40))))
        ;; Ended after them: neither does.
        (should (equal (funcall gh (cerebro-test--gh-time "2026-08-24T14:00:00Z"))
                       '(nil nil))))
      ;; A failure newer than the last good pair.
      (setq cerebro--gh-failed-at 200.0)
      (should (eq (alist-get 'gh (cerebro--trigger-context "/tmp/nowhere"
                                                           (seconds-to-time 5.0)))
                  'failed))
      ;; A good pair after it: back to answering.
      (setq cerebro--gh-as-of 300.0)
      (should (functionp (alist-get 'gh (cerebro--trigger-context "/tmp/nowhere"
                                                                  (seconds-to-time 5.0))))))))

(ert-deftest cerebro-test/agent-context-resolves-gh-against-its-own-pass ()
  "One reader, two roles, two different \"since\": `cerebro--agent-context' is
where the fleet's answer becomes this role's, because `ended-at' is its own."
  (let ((context (list (cons 'gh (lambda (ended-at)
                                   (list (list (or ended-at 0)) nil))))))
    (cl-letf (((symbol-function 'cerebro-wake-interval) (lambda (&rest _) 3600)))
      (with-temp-buffer
        (setq cerebro--parked '(("Moira" 777.0 0.0 nil)) cerebro--started-at nil)
        (let ((resolved (cerebro--agent-context
                         (cerebro-test--interactive "Moira" "user-feedback" 'standby)
                         context)))
          (should (equal (alist-get 'gh resolved) '((777.0) nil))))))))

;; --- `f' and `k' on an interactive role -----------------------------------

(ert-deftest cerebro-test/finish-action-for-interactive-rows ()
  "`f' means the same thing it always meant - no further work - and for a role
that is one pass at a time, that is: finish this pass and stay down."
  (should (eq (cerebro--finish-action
               (cerebro-test--interactive "Xavier" "planner" 'working) nil)
              'write-disarm))
  (should (eq (cerebro--finish-action
               (cerebro-test--interactive "Xavier" "planner" 'standby) nil)
              'standby))
  ;; Checked before `dead': a standby row is not alive either, and "nothing
  ;; to finish" is the one thing it does not mean.
  (should (eq (cerebro--finish-action
               (cerebro-test--interactive "Xavier" "planner" 'dead) nil)
              'dead))
  (should (eq (cerebro--finish-action
               (cerebro-test--interactive "Xavier" "planner" 'working t) nil)
              'external))
  (should (eq (cerebro--finish-action
               (cerebro-test--interactive "Xavier" "planner" 'working) t)
              'offer-clear))
  ;; An implementer's answers are untouched.
  (should (eq (cerebro--finish-action (cerebro-test--supervised 'working) nil) 'write))
  (should (eq (cerebro--finish-action (cerebro-test--supervised 'idle) nil) 'stop-now)))

(ert-deftest cerebro-test/kill-disarms-a-standby-role-on-confirmation ()
  "There is no process, so the whole of `k' here is: forget the pass and do
not start another."
  (let ((parked (generate-new-buffer "*fleet: Xavier (ended 08:00)*"))
        (reverted 0))
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt)
                     (should (equal prompt "Disarm Xavier? "))
                     t))
                  ((symbol-function 'revert-buffer)
                   (lambda (&rest _) (setq reverted (1+ reverted))))
                  ((symbol-function 'cerebro--repo-root) (lambda () "/tmp/nowhere"))
                  ((symbol-function 'cerebro--show-detail) #'ignore)
                  ((symbol-function 'cerebro--agent-at-point)
                   (lambda () (cerebro-test--interactive "Xavier" "planner" 'standby))))
          (with-temp-buffer
            (setq cerebro--armed '("Xavier")
                  cerebro--parked (list (cons "Xavier" (list 1.0 0.0 parked))))
            (cerebro-kill)
            (should (null cerebro--armed))
            (should (null cerebro--parked))
            (should-not (buffer-live-p parked))
            (should (= reverted 1))))
      (when (buffer-live-p parked) (kill-buffer parked)))))

(ert-deftest cerebro-test/killing-a-live-interactive-session-disarms-it-too ()
  "`k' on a running role means stay down, exactly as it does on a standby one -
otherwise a trigger would start it again five seconds later."
  (cl-letf (((symbol-function 'cerebro--end-session) #'ignore)
            ((symbol-function 'revert-buffer) #'ignore)
            ((symbol-function 'cerebro--show-detail) #'ignore))
    (with-temp-buffer
      (setq cerebro--armed '("Xavier" "Psylocke"))
      (cerebro--kill-session-buffer
       (cerebro-test--interactive "Xavier" "planner" 'working) "/tmp/nowhere")
      (should (equal cerebro--armed '("Psylocke"))))))

(ert-deftest cerebro-test/finish-on-a-running-role-writes-the-flag-and-says-what-it-means ()
  (let ((said nil)
        (root (make-temp-file "cerebro-finish" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () root))
                  ((symbol-function 'revert-buffer) #'ignore)
                  ((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
                  ((symbol-function 'cerebro--agent-at-point)
                   (lambda () (cerebro-test--interactive "Xavier" "planner" 'working))))
          (with-temp-buffer
            (cerebro-finish)
            (should (cerebro--stop-flag-p root "Xavier"))
            (should (equal said '("told Xavier to finish its pass - it stays down until you press s")))))
      (delete-directory root t))))

(ert-deftest cerebro-test/finish-on-a-standby-role-says-which-key-to-press ()
  "There is no pass to finish, and writing a flag nothing would read is what
`f' has refused to do since ah-ymn."
  (let ((said nil)
        (root (make-temp-file "cerebro-finish" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () root))
                  ((symbol-function 'revert-buffer) #'ignore)
                  ((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
                  ((symbol-function 'cerebro--agent-at-point)
                   (lambda () (cerebro-test--interactive "Xavier" "planner" 'standby))))
          (with-temp-buffer
            (cerebro-finish)
            (should-not (cerebro--stop-flag-p root "Xavier"))
            (should (equal said
                           '("Xavier is on standby - press k to disarm it, or s to start it now")))))
      (delete-directory root t))))

(ert-deftest cerebro-test/revert-restates-armed-roles-and-labels-them ()
  "The two ends of the render meeting: `cerebro--apply-standby' after the
derive, and the label the For column shows, computed once for the buffer."
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () "/tmp/nowhere"))
            ((symbol-function 'cerebro--roster) (lambda (_) '("Rogue")))
            ((symbol-function 'cerebro--interactive-agents)
             (lambda (_) '(("Psylocke" . "verifier"))))
            ((symbol-function 'cerebro--fleet)
             (lambda (_) '(("Psylocke" "verifier" interactive) ("Rogue" "implementer" implementer))))
            ((symbol-function 'cerebro--gather-states) (lambda (&rest _) nil))
            ((symbol-function 'cerebro--cached-system-processes) (lambda (&rest _) nil))
            ((symbol-function 'cerebro--owned) (lambda () nil))
            ((symbol-function 'cerebro--stop-flag-p) (lambda (&rest _) nil))
            ((symbol-function 'cerebro--beads-panel-buffer) (lambda () nil))
            ((symbol-function 'tabulated-list-init-header) #'ignore))
    (with-temp-buffer
      (setq cerebro--armed '("Psylocke"))
      (cerebro--revert)
      (should (eq (cerebro-agent-state (nth 0 cerebro--agents)) 'standby))
      (let ((row (nth 1 (assoc "Psylocke" tabulated-list-entries))))
        (should (equal (aref row 2) "standby"))
        (should (equal (aref row 4) "→ merged, unverified")))
      ;; The implementer beside it is untouched.
      (should (eq (cerebro-agent-state (nth 1 cerebro--agents)) 'dead)))))

;; ---------------------------------------------------------------------------
;; cb-eat: a launch that dies at once shows `dead' with its last line, not
;; `standby'.  Standby is armed *and* not seen to die abnormally since.

(ert-deftest cerebro-test/apply-standby-keeps-a-failed-launch-dead ()
  "Armed is no longer the whole story: a name whose session died abnormally
stays `dead' until `s' clears its record, because the trigger loop starts
standby rows only."
  (let* ((agents (list (cerebro-test--interactive "Psylocke" "verifier" 'dead)
                       (cerebro-test--interactive "Moira" "user-feedback" 'dead)))
         (out (cerebro--apply-standby agents '("Psylocke" "Moira") '("Psylocke"))))
    (should (eq (cerebro-agent-state (nth 0 out)) 'dead))
    (should (eq (cerebro-agent-state (nth 1 out)) 'standby))
    ;; Two arguments still mean what they meant: no failures known.
    (should (eq (cerebro-agent-state
                 (nth 0 (cerebro--apply-standby agents '("Psylocke"))))
                'standby))
    ;; Pure: the input list is not mutated.
    (should (eq (cerebro-agent-state (nth 0 agents)) 'dead))))

(ert-deftest cerebro-test/exit-line-strips-the-prefix-and-truncates ()
  "The row shows why the session died, in the columns a row has: the
launcher's own `cerebro: ' prefix is nine columns spent saying nothing, and
the rest is cut with an ellipsis rather than at the window edge."
  (should (equal (cerebro--exit-line '(:code "2" :line "cerebro: the checkout is 1 commits behind") 0)
                 "✗ the checkout is 1 commits behind"))
  (should (equal (cerebro--exit-line '(:code "2" :line "boom") 0) "✗ boom"))
  (should-not (cerebro--exit-line nil 0))
  ;; An abnormal exit that printed nothing is a record with no line, and the
  ;; row has nothing to show for it until the view gives up (cb-ccl).
  (should-not (cerebro--exit-line '(:code "137" :line nil) 3))
  (let ((cerebro-exit-line-width 20))
    (let ((out (cerebro--exit-line (list :code "2" :line (make-string 100 ?x)) 0)))
      (should (= (string-width out) 20))
      (should (string-suffix-p "…" out)))))

(ert-deftest cerebro-test/entry-shows-the-exit-line-on-a-dead-row ()
  "The line the navigator has to act on goes on the row, not behind `RET':
a dead row with an exit line shows it in red, and a standby row still shows
its label."
  (let ((agent (cerebro-test--interactive "Psylocke" "verifier" 'dead)))
    (let ((col (aref (nth 1 (cerebro--entry agent cerebro-test--now nil nil nil "✗ nope")) 4)))
      (should (equal (substring-no-properties col) "✗ nope"))
      (should (eq (get-text-property 0 'face col) 'error)))
    ;; No line recorded: the column is as empty as it was.
    (should (equal (aref (nth 1 (cerebro--entry agent cerebro-test--now)) 4) "")))
  ;; A standby row given both shows the label: standby is what it is waiting
  ;; for, and it cannot be a failed row at all (`cerebro--apply-standby').
  (should (equal (substring-no-properties
                  (aref (nth 1 (cerebro--entry
                                (cerebro-test--interactive "Moira" "user-feedback" 'standby)
                                cerebro-test--now nil nil "→ 3 issues" "✗ nope"))
                        4))
                 "→ 3 issues")))

(ert-deftest cerebro-test/column-widths-grow-for-the-for-column ()
  "The last column is not truncated by `tabulated-list' and the window is
sized to the table, so a Bead/Phase text longer than the floor was cut at the
window edge - the standby label already was, and the exit line would be
unreadable."
  (should (= (nth 4 (cerebro--column-widths
                     '("Xavier") '("planner") nil
                     '("→ buffer < 4" "✗ the checkout is 1 commits behind")))
             34))
  (should (= (nth 4 (cerebro--column-widths '("Xavier") '("planner") nil)) 10))
  ;; Never below the floor, however short the texts.
  (should (= (nth 4 (cerebro--column-widths '("Xavier") '("planner") nil '("✗ x"))) 10)))

(ert-deftest cerebro-test/revert-keeps-a-failed-launch-dead-and-shows-why ()
  "The whole of cb-eat, end to end: a name whose launch was refused is drawn
`dead' with the launcher's line on the row, its trigger starts nothing while
that stands, and `s' - which clears the record - is the way back."
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () "/tmp/nowhere"))
            ((symbol-function 'cerebro--roster) (lambda (_) '("Rogue")))
            ((symbol-function 'cerebro--interactive-agents)
             (lambda (_) '(("Psylocke" . "verifier"))))
            ((symbol-function 'cerebro--fleet)
             (lambda (_) '(("Psylocke" "verifier" interactive) ("Rogue" "implementer" implementer))))
            ((symbol-function 'cerebro--gather-states) (lambda (&rest _) nil))
            ((symbol-function 'cerebro--cached-system-args) (lambda (&rest _) nil))
            ((symbol-function 'cerebro--owned) (lambda () nil))
            ((symbol-function 'cerebro--stop-flag-p) (lambda (&rest _) nil))
            ((symbol-function 'cerebro--beads-panel-buffer) (lambda () nil))
            ((symbol-function 'tabulated-list-init-header) #'ignore))
    (let ((cerebro--last-exit '(("Psylocke" :code "2" :line "cerebro: nope"))))
      (with-temp-buffer
        (setq cerebro--armed '("Psylocke"))
        (cerebro--revert)
        (should (eq (cerebro-agent-state (nth 0 cerebro--agents)) 'dead))
        (let ((row (nth 1 (assoc "Psylocke" tabulated-list-entries))))
          (should (equal (aref row 2) "dead"))
          (should (equal (substring-no-properties (aref row 4)) "✗ nope")))
        (should (>= (nth 1 (aref tabulated-list-format 4)) 6))
        ;; The trigger loop starts standby rows only, so nothing is launched.
        (let ((launched nil)
              (debug-on-error nil))
          (cl-letf (((symbol-function 'cerebro--launch)
                     (lambda (a) (push (cerebro-agent-name a) launched)))
                    ((symbol-function 'cerebro--vterm-available-p) (lambda () t))
                    ((symbol-function 'cerebro--trigger) (lambda (&rest _) "because"))
                    ((symbol-function 'cerebro--trigger-context) (lambda (&rest _) nil)))
            (cerebro--start-due "/tmp/nowhere" (current-time))
            (should-not launched)))
        ;; `s' clears the record (`cerebro--launch'), and the row is standby again.
        (setq cerebro--last-exit nil)
        (cerebro--revert)
        (should (eq (cerebro-agent-state (nth 0 cerebro--agents)) 'standby))
        (should (equal (aref (nth 1 (assoc "Psylocke" tabulated-list-entries)) 4)
                       "→ merged, unverified"))))))


;; --- cb-98u: a `standby' word in roster.conf arms without starting ---------

(ert-deftest cerebro-test/standby-arming-takes-every-declared-name-whatever-its-state ()
  "roster.conf is a statement about the fleet, not about this Emacs: every
declared name is armed whatever its state, external and up included.  An
external session keeps the row external while it lives; when it ends the name
goes standby and its trigger starts it."
  (let ((agents (list (cerebro-test--interactive "Alpha" "planner" 'working)
                      (cerebro-test--interactive "Beta" "verifier" 'dead)
                      (cerebro-test--interactive "Gamma" "reviewer" 'dead t)
                      (cerebro-test--agent "One" "implementer" 'implementer 'dead))))
    (should (equal (cerebro--standby-arming agents '("Gamma" "Beta" "One"))
                   '("Beta" "Gamma" "One")))
    (should (null (cerebro--standby-arming agents nil)))
    (should (equal (cerebro--standby-arming agents '("Alpha")) '("Alpha")))))

(ert-deftest cerebro-test/autostart-message-names-what-was-armed ()
  "One echo line carries both halves: what was started, and what was armed."
  (should-not (cerebro--autostart-message nil nil))
  (should (equal (cerebro--autostart-message
                  '(("Alpha" . launch) ("One" . launch-clearing-flag)) nil)
                 "cerebro: autostarted Alpha, One (cleared a stale stop flag)"))
  (should (equal (cerebro--autostart-message nil '("Forge" "Cypher"))
                 "cerebro: nothing to autostart; armed Forge and Cypher"))
  (should (equal (cerebro--autostart-message
                  '(("Xavier" . launch) ("Psylocke" . launch)) '("Forge" "Cypher"))
                 "cerebro: autostarted Xavier, Psylocke; armed Forge and Cypher"))
  (should (equal (cerebro--autostart-message
                  '(("Xavier" . launch) ("Beast" . already-up)) '("Forge"))
                 "cerebro: autostarted Xavier; Beast is already up; armed Forge")))

(ert-deftest cerebro-test/arm-is-a-decision-event ()
  (should (cerebro--log-event-p 'arm 'decisions))
  (should-not (cerebro--log-event-p 'arm 'none))
  (should (equal (cerebro--log-basename 'arm) "decisions")))

(ert-deftest cerebro-test/a-roster-armed-cadence-role-counts-from-arming ()
  "The parked entry arming writes is an ENDED-AT, so a cadence role counts from
the moment the view armed it rather than never firing at all - and Moira's `gh'
trigger compares against it rather than counting every open issue as moved,
which would be autostart by another name."
  (let ((cerebro-cadence-triggers '(("architect" . 3600))))
    (should (null (cerebro--trigger
                   (cerebro-test--interactive "Forge" "architect" 'standby)
                   (cerebro-test--context '(started-at) '(ended-at . 1000.0)
                                          '(now . 4000.0) '(floor . 600)))))
    (should (equal (cerebro--trigger
                    (cerebro-test--interactive "Forge" "architect" 'standby)
                    (cerebro-test--context '(started-at) '(ended-at . 1000.0)
                                           '(now . 4700.0) '(floor . 600)))
                   "60m since its last sweep"))
    (should (equal (cerebro--standby-label
                    (cerebro-test--interactive "Forge" "architect" 'standby)
                    (cerebro-test--context '(started-at) '(ended-at . 1000.0)
                                           '(now . 1060.0)))
                   "→59m")))
  (let ((issues '(((number . 1) (updatedAt . "2026-01-01T00:00:00Z"))
                  ((number . 2) (updatedAt . "2026-01-01T00:00:00Z")))))
    ;; One before the arming moment, one after: only the later number.
    (let* ((early (cerebro--gh-instant "2026-01-01T00:00:00Z"))
           (moved (cerebro--gh-moved
                   (list (car issues)
                         '((number . 2) (updatedAt . "2026-02-01T00:00:00Z")))
                   nil nil (+ early 1))))
      (should (equal (car moved) '(2))))))

(ert-deftest cerebro-test/placeholder-for-a-roster-armed-role ()
  "`RET' on a roster-armed row that has never run says what arms it and what
will start it; the plain line is what a role the view started and ended keeps."
  (let ((cerebro--last-exit nil)
        (forge (cerebro-test--interactive "Forge" "architect" 'standby))
        (cerebro-agent (cerebro-test--interactive "Cerebro" "orchestrator" 'standby)))
    (should (equal (cerebro--placeholder forge nil nil t "→59m")
                   (concat "Forge is not running.\n"
                           "roster.conf arms it: the view starts it when its own"
                           " trigger fires (→59m).\n"
                           "Press s to start it now, k to leave it down.")))
    (should (equal (cerebro--placeholder cerebro-agent nil nil t "→ unranked bead")
                   (concat "Cerebro is not running.\n"
                           "roster.conf arms it: the view starts it when its own"
                           " trigger fires (→ unranked bead).\n"
                           "Press s to start it now, k to leave it down.")))
    ;; And the other branch stays pinned by a role the view has no rule for.
    (should (equal (cerebro--placeholder
                    (cerebro-test--interactive "Sommelier" "sommelier" 'standby)
                    nil nil t "")
                   (concat "Sommelier is not running.\n"
                           "roster.conf arms it, but this role has no trigger: it is"
                           " started with s only.\n"
                           "Press s to start it, k to leave it down.")))
    (should (equal (cerebro--placeholder forge nil nil nil "→59m")
                   "Forge is not running. Press s to start it."))
    ;; Branch order: a standby implementer keeps its retry line whatever the
    ;; roster says - and the roster refuses the word on its row anyway.
    (let ((cerebro-retry-backoff '(0 30 120 600)))
      (should (string-match-p
               "starts it again"
               (cerebro--placeholder
                (cerebro-test--agent "Cyclops" "implementer" 'implementer 'standby)
                120 3 t "→59m"))))))

(ert-deftest cerebro-test/placeholder-buffer-knows-a-roster-armed-role ()
  "A parked entry with no STARTED-AT is one only arming writes:
`cerebro--park-session' always records the start it is ending."
  (let ((cerebro--last-exit nil)
        (agent (cerebro-test--interactive "Forge" "architect" 'standby))
        (buffer nil))
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'cerebro-session-mode) #'ignore)
                    ((symbol-function 'cerebro--repo-root) (lambda () "/fake/repo"))
                    ((symbol-function 'cerebro--trigger-context)
                     (lambda (_root _now) (cerebro-test--context)))
                    ((symbol-function 'cerebro--agent-context)
                     (lambda (_agent context)
                       (append '((ended-at . 1000.0) (now . 1060.0) (started-at))
                               context))))
            (setq cerebro--parked '(("Forge" 1000.0 nil nil)))
            (setq buffer (cerebro--placeholder-buffer agent))
            (should (string-match-p "roster.conf arms it"
                                    (with-current-buffer buffer (buffer-string))))
            (kill-buffer buffer)
            (setq cerebro--parked '(("Forge" 1000.0 900.0 nil)))
            (setq buffer (cerebro--placeholder-buffer agent))
            (should-not (string-match-p "roster.conf arms it"
                                        (with-current-buffer buffer (buffer-string))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

;; ---------------------------------------------------------------------------
;; cb-wfb: the pause whose reason has gone

(defun cerebro-test--paused-candidate (id &optional blockers ui-decision priority)
  `((id . ,id) (title . "a bead parked for the navigator")
    (priority . ,(or priority 2))
    (paused_at . "2026-08-30T20:00:00Z")
    (ui_decision . ,(if ui-decision t :json-false))
    (blockers . ,(or blockers []))))

(defun cerebro-test--blocker (id status &optional age)
  `((id . ,id) (status . ,status) (closed_age_min . ,age)))

(ert-deftest cerebro-test/paused-finding-needs-closed-blockers ()
  "The one case the board can judge alone: every blocker closed. Everything
else is a pause only a person can end, and offering to unpause it would put
the bead back in front of the wall that stopped it."
  (should (equal (cerebro--paused-finding
                  (cerebro-test--paused-candidate
                   "cb-aaa" (list (cerebro-test--blocker "cb-bbb" "closed" 120))))
                 '(unpause "cb-aaa" 2)))
  ;; A question is not a blocker, however closed the board looks.
  (should (null (cerebro--paused-finding
                 (cerebro-test--paused-candidate
                  "cb-aaa" (list (cerebro-test--blocker "cb-bbb" "closed" 120)) t))))
  ;; No blockers at all: the pause is prose in the notes, which nothing here reads.
  (should (null (cerebro--paused-finding (cerebro-test--paused-candidate "cb-aaa"))))
  (should (null (cerebro--paused-finding
                 (cerebro-test--paused-candidate
                  "cb-aaa" (list (cerebro-test--blocker "cb-bbb" "open"))))))
  (should (null (cerebro--paused-finding
                 (cerebro-test--paused-candidate
                  "cb-aaa" (list (cerebro-test--blocker "cb-bbb" "closed" 120)
                                 (cerebro-test--blocker "cb-ccc" "in_progress")))))))

(ert-deftest cerebro-test/paused-finding-carries-the-priority-it-was-given ()
  (should (equal (cerebro--paused-finding
                  (cerebro-test--paused-candidate
                   "cb-zzz" (list (cerebro-test--blocker "cb-bbb" "closed" 30)) nil 0))
                 '(unpause "cb-zzz" 0))))

(ert-deftest cerebro-test/paused-sweep-labels-and-commands ()
  "The line the navigator chose, verbatim, and the one write behind it -
`--remove-label human' and nothing else, so the bead goes back to the
planners for a re-read rather than in front of an implementer."
  (should (equal (cerebro--sweep-label
                  '(unpause "cb-aaa" 2)
                  (cerebro-test--paused-candidate
                   "cb-aaa" (list (cerebro-test--blocker "cb-bbb" "closed" 120))))
                 "unpause cb-aaa — waiting on cb-bbb, closed 2h ago"))
  (should (equal (cerebro--finding-command '(unpause "cb-aaa" 2) "/repo")
                 (list cerebro-bd-program "update" "cb-aaa" "--remove-label" "human"))))

(ert-deftest cerebro-test/finding-explanation-is-nil-for-the-existing-six ()
  "Today's six prompts stay byte-identical: an explanation line is what this
bead adds, for the one command that does not say its own consequence."
  (dolist (finding '((close "cb-a" "r") (reclaim "cb-a") (epic-close "cb-a")
                     (unclaim "cb-a") (unassign "cb-a" 0) (recheck "cb-a" 0)))
    (should (null (cerebro--finding-explanation finding)))))

(ert-deftest cerebro-test/unpause-explains-where-the-bead-goes ()
  "`bd close', `bd unclaim' and `bd reclaim' all say what they do; removing a
label does not, and where the bead lands is the whole of what was decided."
  (should (equal (cerebro--finding-explanation '(unpause "cb-aaa" 2))
                 "cb-aaa goes back to the planners for a re-read.")))

(defun cerebro-test--sweep-act-prompt (finding)
  "Return the string `cerebro-sweep-act' would put to the navigator for FINDING."
  (let ((prompt nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (p) (setq prompt p) nil))
              ((symbol-function 'cerebro--repo-root) (lambda () default-directory))
              ((symbol-function 'cerebro--finding-at-point) (lambda () finding)))
      (cerebro-sweep-act))
    prompt))

(ert-deftest cerebro-test/sweep-act-asks-with-the-command-alone-when-there-is-no-explanation ()
  "The five older findings read as they always did: one line, the command."
  (should (equal (cerebro-test--sweep-act-prompt '(close "ah-x1" "delivered"))
                 (format "run: %s ? "
                         (mapconcat #'identity
                                    (cerebro--finding-command '(close "ah-x1" "delivered")
                                                              default-directory)
                                    " ")))))

(ert-deftest cerebro-test/sweep-act-puts-the-explanation-on-its-own-line ()
  "An unpause takes a bead off the navigator's own queue and back into the
fleet's, which is not obvious from `bd update --remove-label human' - so the
consequence is spelled out under the command, and the `(y or n)' is still
Emacs's to add."
  (let ((prompt (cerebro-test--sweep-act-prompt '(unpause "cb-aaa" 2))))
    (should (string-match-p "\n" prompt))
    (should (equal (cadr (split-string prompt "\n"))
                   (concat (cerebro--finding-explanation '(unpause "cb-aaa" 2)) " ")))
    (should-not (string-match-p "(y or n)" prompt))))

(ert-deftest cerebro-test/trigger-context-reads-the-buckets-partition-beads-writes ()
  "`cerebro--trigger-context' reads `cerebro--beads' by name, and
`cerebro--partition-beads' is what fills it - so this builds the buffer through
the real partition rather than by hand. Before ah-vcof both sides indexed by
position, and a sixth bucket inserted ahead of `merged' made the verifier's
trigger count parked beads as merged ones, with every hand-written
five-element fixture going on passing (cb-wfb). This test pins the producer
and the consumer to the same seam so a future bucket cannot repeat that."
  (let ((panel (generate-new-buffer " *beads*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--fleet)
                   (lambda (_) '(("Rogue" "implementer" implementer))))
                  ((symbol-function 'cerebro--beads-panel-buffer) (lambda () panel)))
          (with-current-buffer panel
            (setq cerebro--beads
                  (cerebro--partition-beads
                   ;; Two parked, one merged: same-sized buckets would give the
                   ;; wrong index the right answer, which is how the bug hid.
                   (list (cerebro-test--paused "cb-parked")
                         (cerebro-test--paused "cb-parked-stale" '("verdict:stale"))
                         '((id . "cb-merged") (status . "closed") (priority . 2)
                           (title . "cb-merged") (labels . []) (issue_type . "task")
                           (updated_at . "2026-08-14T09:00:00Z"))))
                  cerebro--beads-read-at 3.5))
          (let ((context (with-temp-buffer
                           (setq cerebro--agents nil)
                           (cerebro--trigger-context default-directory (seconds-to-time 1000000.0)))))
            (should (equal (alist-get 'merged-unverified context) 1))
            ;; And a parked bead is still an open one: being asked about does not
            ;; make a stale verdict stop being stale.
            (should (equal (alist-get 'stale-verdicts context) 1))))
      (kill-buffer panel))))
;; ---------------------------------------------------------------------------
;; Supervision ownership (cb-kcs.1)
;;
;; Two views may read one checkout; one may act on it. These cases hold this
;; half of that rule to the same table `fleet-view/src/supervisor.rs' answers,
;; prove the lease is the bound listener rather than anything written down, and
;; prove that a view which does not own the checkout starts, nudges, arms and
;; prunes nothing at all.

(defconst cerebro-test--supervisor-cases-file
  (expand-file-name "tests/lib/supervisor.cases" cerebro-test--repo-root)
  "The transition table both implementations of the ownership rule run.
`fleet-view/src/supervisor.rs' runs the same rows against
`reconcile_supervision'.")

(defun cerebro-test--supervisor-cases ()
  "The rows of `cerebro-test--supervisor-cases-file' as plain lists.
Each is (LOCAL CONFIGURED HOLDS HOSTED MODE ACTION).  A malformed row is an
error, not a skipped case."
  (let (rows)
    (with-temp-buffer
      (insert-file-contents cerebro-test--supervisor-cases-file)
      (dolist (line (split-string (buffer-string) "\n" t))
        (unless (string-match-p "\\`[ \t]*\\(#\\|\\'\\)" line)
          (let ((fields (split-string (string-trim line) "[ \t]+" t)))
            (unless (= (length fields) 6)
              (error "supervisor.cases: malformed row: %s" line))
            (push fields rows)))))
    (nreverse rows)))

(ert-deftest cerebro-test/both-implementations-follow-the-shared-transition-table ()
  "Every row of `tests/lib/supervisor.cases', answered here as well as in Rust.

A row the two answer differently is a fleet with two supervisors or with none,
and neither failure is visible until a session is started twice or never."
  (let ((rows (cerebro-test--supervisor-cases)))
    (should (>= (length rows) 20))
    (dolist (row rows)
      (pcase-let* ((`(,local ,configured ,holds ,hosted ,mode-word ,action-word) row)
                   (decision (cerebro--supervision-decision
                              (intern local)
                              (if (equal configured "invalid")
                                  (cons 'invalid "rat")
                                (intern configured))
                              (equal holds "yes")
                              (string-to-number hosted))))
        (should (equal (cons (cerebro--supervision-mode-word (car decision))
                             (symbol-name (cdr decision)))
                       (cons mode-word action-word)))))))

(ert-deftest cerebro-test/a-drain-names-who-it-is-for-and-how-many-are-left ()
  "The drain carries the new owner and the count, which is what ends it."
  (let ((decision (cerebro--supervision-decision 'emacs 'tui t 3)))
    (should (equal (car decision) '(draining tui 3)))
    (should (eq (cdr decision) 'keep))
    (should-not (cerebro--supervision-may-act-p (car decision)))
    ;; The whole point of a graceful handover: what is already hosted may still
    ;; finish, and `f' and `k' still work on it.
    (should (cerebro--supervision-may-end-p (car decision))))
  ;; An invalid declaration drains for nobody, and says so.
  (let ((decision (cerebro--supervision-decision 'emacs (cons 'invalid "rat") t 1)))
    (should (equal (car decision) '(draining nil 1)))))

(ert-deftest cerebro-test/read-only-may-neither-act-nor-end ()
  "A view that owns nothing does nothing, including to sessions it can see."
  (let ((mode '(read-only configured-for tui)))
    (should-not (cerebro--supervision-may-act-p mode))
    (should-not (cerebro--supervision-may-end-p mode))
    (should (equal (cerebro--supervision-refusal mode)
                   "Ratatui owns supervision; this Emacs view is read-only"))))

(ert-deftest cerebro-test/the-mode-line-carries-the-approved-wording ()
  "The navigator chose the mode line over a banner row, and chose these words."
  (should-not (cerebro--supervision-mode-line '(supervising)))
  (should (equal (cerebro--supervision-mode-line '(read-only configured-for tui))
                 "read-only: Ratatui supervises"))
  (should (equal (cerebro--supervision-mode-line '(read-only invalid "rat"))
                 "read-only: invalid fleet_supervisor \"rat\""))
  (should (equal (cerebro--supervision-mode-line '(draining tui 2)) "handoff pending"))
  (should (equal (cerebro--supervision-mode-line '(draining nil 2))
                 "handoff pending: invalid fleet_supervisor")))

;; --- reader contracts: the real script, feeding the real decision -----------

(defun cerebro-test--supervisor-consumer (declaration)
  "A throwaway consumer declaring DECLARATION, or none when it is nil.
Returns its root; the caller deletes it."
  (let* ((tmp (make-temp-file "cerebro-supervision" t))
         (scripts (expand-file-name ".claude/cerebro/scripts" tmp)))
    (make-directory scripts t)
    (make-directory (expand-file-name ".cerebro" tmp) t)
    ;; A git working tree, because `consumer-root --shared' answers from git:
    ;; the shared root is the main working tree every worktree of a checkout
    ;; shares, and a plain directory is not a checkout at all.
    (let ((default-directory tmp))
      (should (eq 0 (call-process "git" nil nil nil "init" "-q" tmp)))
      (should (eq 0 (call-process "git" nil nil nil "-c" "user.name=test"
                                  "-c" "user.email=test@example.com"
                                  "commit" "-q" "--allow-empty" "-m" "fixture"))))
    (cerebro-test--place-scripts scripts "--copy" "fleet-supervisor" "project-conf"
                                 "consumer-root")
    (when declaration
      (with-temp-file (expand-file-name ".cerebro/project.conf" tmp)
        (insert (format "fleet_supervisor %s\n" declaration))))
    tmp))

(ert-deftest cerebro-test/the-declaration-reader-answers-the-decision-function ()
  "`scripts/fleet-supervisor' run for real, feeding `cerebro--supervision-decision'.

A pure function tested only against invented inputs can still be wrong about
every real one (cb-os4), so the reader's own output is what is fed in here."
  (let ((tmp (cerebro-test--supervisor-consumer nil)))
    (unwind-protect
        (progn
          ;; Absent: the default, and the behaviour every existing consumer keeps.
          (should (eq (cerebro--configured-supervisor tmp) 'emacs))
          (should (equal (cerebro--supervision-decision
                          'emacs (cerebro--configured-supervisor tmp) t 0)
                         '((supervising) . keep)))
          ;; Declared for the other implementation.
          (with-temp-file (expand-file-name ".cerebro/project.conf" tmp)
            (insert "fleet_supervisor tui\n"))
          (should (eq (cerebro--configured-supervisor tmp) 'tui))
          (should (equal (cerebro--supervision-decision
                          'emacs (cerebro--configured-supervisor tmp) t 0)
                         '((read-only configured-for tui) . release)))
          ;; Invalid: fail-closed, and the raw word survives to the mode line.
          (with-temp-file (expand-file-name ".cerebro/project.conf" tmp)
            (insert "fleet_supervisor rat\n"))
          (should (equal (cerebro--configured-supervisor tmp) '(invalid . "rat")))
          (should (equal (cerebro--supervision-mode-line
                          (car (cerebro--supervision-decision
                                'emacs (cerebro--configured-supervisor tmp) nil 0)))
                         "read-only: invalid fleet_supervisor \"rat\"")))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/the-endpoint-identity-and-record-come-from-the-shared-root ()
  "The three diagnostic values, read for real."
  (let ((tmp (cerebro-test--supervisor-consumer "emacs")))
    (unwind-protect
        (let ((endpoint (cerebro--supervisor-endpoint tmp))
              (identity (cerebro--supervisor-identity tmp))
              (record (cerebro--supervisor-record tmp)))
          (should (equal (car endpoint) "127.0.0.1"))
          ;; Below 32768: Linux's ephemeral range starts there, and a lease port an outbound
          ;; connection can borrow reads as a lock error. `tests/fleet-supervisor.sh' pins the
          ;; same block against the script itself.
          (should (and (>= (cdr endpoint) 20000) (<= (cdr endpoint) 32767)))
          ;; The script answers `pwd -P', so the comparison is against the
          ;; physical path too - on macOS a temp directory is reached through
          ;; /var and lives at /private/var, and an identity compared in the
          ;; display spelling would never match (cb-os4's lesson, in the small).
          (should (equal identity (directory-file-name (file-truename tmp))))
          (should (equal record (expand-file-name ".cerebro/state/supervisor.json" identity)))
          ;; Reading ownership writes nothing.
          (should-not (file-exists-p record)))
      (delete-directory tmp t))))

;; --- the lease ---------------------------------------------------------------

(ert-deftest cerebro-test/supervisor-lock-is-exclusive-and-recovers-a-crashed-owner ()
  "The bind is the lock: one holder, and a killed holder releases at once.

The second half is what no pid file or lease timeout can do - the crashed owner
here is a real second Emacs, killed without a chance to clean up, and the lease
is free the instant its process is gone rather than after a timeout nobody
could have chosen correctly."
  (skip-unless (executable-find "emacs"))
  (let ((tmp (cerebro-test--supervisor-consumer "emacs")))
    (unwind-protect
        (let* ((endpoint (cerebro--supervisor-endpoint tmp))
               (record (cerebro--supervisor-record tmp))
               (identity (cerebro--supervisor-identity tmp))
               ;; The child's program is built as DATA and printed, never as a
               ;; format string: a nested `format' quoting JSON inside elisp
               ;; inside a shell argument is three levels of escaping and got
               ;; one of them wrong the first time.
               (program `(progn
                           (make-network-process
                            :name "held" :family 'ipv4
                            :host ,(car endpoint) :service ,(cdr endpoint)
                            :server t :noquery t :reuseaddr nil)
                           (make-directory ,(file-name-directory record) t)
                           (with-temp-file ,record
                             (insert (format "{\"identity\":%S,\"owner\":\"emacs\",\"pid\":%d}"
                                             ,identity (emacs-pid))))
                           (sleep-for 60)))
               (other (start-process
                       "cerebro-test-owner" nil (expand-file-name invocation-name
                                                                  invocation-directory)
                       "--batch" "-L" (expand-file-name "emacs" cerebro-test--repo-root)
                       "-l" "cerebro"
                       "--eval" (prin1-to-string program))))
          (unwind-protect
              (progn
                ;; Wait for the other Emacs to actually hold it.
                (let ((deadline (+ (float-time) 20)))
                  (while (and (< (float-time) deadline)
                              (not (file-exists-p record)))
                    (sleep-for 0.1)))
                (should (file-exists-p record))
                (with-temp-buffer
                  (setq-local cerebro--supervision-process nil)
                  ;; Refused, and told exactly who holds it.
                  (should (equal (cerebro--acquire-supervision tmp)
                                 '(read-only owned-by emacs)))
                  ;; The owner dies without cleaning up. The kernel closes its
                  ;; listener, so the lease is free at once - the stale record
                  ;; it left behind is not permission and not an obstacle.
                  (kill-process other)
                  (let ((deadline (+ (float-time) 20)))
                    (while (and (< (float-time) deadline) (process-live-p other))
                      (sleep-for 0.1)))
                  (should-not (process-live-p other))
                  ;; The same bounded retry the Rust twin needs, and for the same reason: the
                  ;; kernel closes the listener as the process is reaped, and on a loaded runner
                  ;; that is milliseconds after the wait returns rather than before it. One
                  ;; attempt here would be a flake on exactly the CI job that runs it twice.
                  (let ((acquired nil)
                        (deadline (+ (float-time) 20)))
                    (while (and (not (eq acquired t)) (< (float-time) deadline))
                      (setq acquired (cerebro--acquire-supervision tmp))
                      (unless (eq acquired t) (sleep-for 0.05)))
                    (should (eq acquired t))
                    (should (equal (cerebro--supervision-record-field record "owner") "emacs"))
                    (should (equal (cerebro--supervision-record-field record "identity")
                                   identity)))
                  ;; And releasing takes the record with it, in that order.
                  (cerebro--release-supervision tmp)
                  (should-not (file-exists-p record))
                  (should-not cerebro--supervision-process)))
            (when (process-live-p other) (kill-process other))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/a-foreign-record-on-a-bound-port-is-never-a-takeover ()
  "A record naming another checkout is a lock error, not permission."
  (let ((tmp (cerebro-test--supervisor-consumer "emacs")))
    (unwind-protect
        (let* ((endpoint (cerebro--supervisor-endpoint tmp))
               (record (cerebro--supervisor-record tmp))
               (foreign (make-network-process
                         :name "cerebro-test-foreign" :family 'ipv4
                         :host (car endpoint) :service (cdr endpoint)
                         :server t :noquery t :reuseaddr nil)))
          (unwind-protect
              (with-temp-buffer
                (setq-local cerebro--supervision-process nil)
                ;; No record at all behind a bound port.
                (pcase (cerebro--acquire-supervision tmp)
                  (`(read-only lock-error ,message)
                   (should (string-match-p "missing or malformed" message)))
                  (other (ert-fail (format "expected a lock error, got %S" other))))
                ;; A record naming somebody else's checkout.
                (make-directory (file-name-directory record) t)
                (with-temp-file record
                  (insert "{\"identity\":\"/repos/elsewhere\",\"owner\":\"tui\",\"pid\":1}\n"))
                (pcase (cerebro--acquire-supervision tmp)
                  (`(read-only lock-error ,message)
                   (should (string-match-p "another checkout" message)))
                  (other (ert-fail (format "expected a collision, got %S" other)))))
            (delete-process foreign)))
      (delete-directory tmp t))))

;; --- what a non-owner is allowed to do, which is nothing --------------------

(ert-deftest cerebro-test/non-owner-never-acts ()
  "Read-only starts nothing, nudges nothing and prunes nothing.

The whole of the gate, asserted through the two predicates every caller in
`cerebro.el' asks - so a new caller that forgets to ask is the only way past
this, and that is what the reviewer looks for."
  (dolist (mode '((read-only configured-for tui)
                  (read-only invalid "rat")
                  (read-only owned-by tui)
                  (read-only lock-error "bound elsewhere")
                  (read-only not-owned)))
    (should-not (cerebro--supervision-may-act-p mode))
    (should-not (cerebro--supervision-may-end-p mode))
    (should (cerebro--supervision-refusal mode))))

(ert-deftest cerebro-test/owner-change-drains-without-start-or-nudge ()
  "A declaration that moves supervision keeps the lease while sessions are hosted.

`cerebro--supervise' still ends and retires - that is what empties the drain -
but the nudge branch is closed, because a nudge is a new instruction and a view
handing supervision over issues none."
  (let ((mode (car (cerebro--supervision-decision 'emacs 'tui t 2))))
    (should (equal mode '(draining tui 2)))
    (should (cerebro--supervision-may-end-p mode))
    (should-not (cerebro--supervision-may-act-p mode))
    ;; A nudge asks `may-act-p', which a drain fails.
    (should-not (cerebro--supervision-may-act-p mode))))

(ert-deftest cerebro-test/last-hosted-session-releases-for-the-new-owner ()
  "The drain ends by itself when the last session goes."
  (should (equal (cerebro--supervision-decision 'emacs 'tui t 1)
                 '((draining tui 1) . keep)))
  (should (equal (cerebro--supervision-decision 'emacs 'tui t 0)
                 '((read-only configured-for tui) . release))))

(ert-deftest cerebro-test/a-correction-during-a-drain-resumes-with-the-held-lease ()
  "Put back to `emacs' mid-drain, supervision resumes - no gap, no reacquisition."
  (should (equal (cerebro--supervision-decision 'emacs 'emacs t 3)
                 '((supervising) . keep))))

(ert-deftest cerebro-test/reacquisition-starts-nothing ()
  "Taking the lease back is quiet: the navigator chose acquisition with no
session start or arming side effect, so the decision that acquires reports
read-only until the bind succeeds and never asks for an autostart."
  (should (equal (cerebro--supervision-decision 'emacs 'emacs nil 0)
                 '((read-only not-owned) . acquire))))

(ert-deftest cerebro-test/a-deleted-lease-process-is-not-a-held-lease ()
  "Holding a lease means holding a LIVE one.

A server process deleted by hand leaves the variable set while the port is free;
believing that would be an Emacs supervising a checkout it has let go of."
  (let ((tmp (cerebro-test--supervisor-consumer "emacs")))
    (unwind-protect
        (with-temp-buffer
          (setq-local cerebro--supervision-process nil)
          (should (eq (cerebro--acquire-supervision tmp) t))
          (should (process-live-p cerebro--supervision-process))
          ;; Deleted behind its back, the way anything reaching for `delete-process' would.
          (delete-process cerebro--supervision-process)
          ;; The variable is still set, and the answer must still be `not holding it'.
          (should cerebro--supervision-process)
          (should (equal (cerebro--reconcile-supervision tmp) '(supervising)))
          ;; ... which it reached by ACQUIRING again, not by believing the dead process.
          (should (process-live-p cerebro--supervision-process))
          (cerebro--release-supervision tmp))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/the-declaration-is-not-re-read-until-it-changes ()
  "No fork per tick: the reader runs again only when project.conf has moved.

`cerebro--project-spacing-cache' states the rule this follows - a fork per
five-second tick is not a thing the view may do - and an mtime rather than a
plain cache is what keeps a changed declaration obeyed on the next tick."
  (let ((tmp (cerebro-test--supervisor-consumer "emacs")))
    (unwind-protect
        (with-temp-buffer
          (let ((reads 0))
            (cl-letf* ((real (symbol-function 'cerebro--supervisor-value))
                       ((symbol-function 'cerebro--supervisor-value)
                        (lambda (&rest args)
                          (when (= (length args) 1) (setq reads (1+ reads)))
                          (apply real args))))
              (should (eq (cerebro--configured-supervisor tmp) 'emacs))
              (should (eq reads 1))
              ;; Nine more ticks, no more forks.
              (dotimes (_ 9) (cerebro--configured-supervisor tmp))
              (should (eq reads 1))
              ;; The declaration changes, and the very next call sees it.
              (sleep-for 0.01)
              (with-temp-file (expand-file-name ".cerebro/project.conf" tmp)
                (insert "fleet_supervisor tui\n"))
              (should (eq (cerebro--configured-supervisor tmp) 'tui))
              (should (eq reads 2)))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/a-reader-that-did-not-run-is-never-cached ()
  "A transient failure must not pin `emacs' for the life of the buffer.

The fallback is right - a consumer whose submodule predates this script keeps
supervising - but caching it turns one fork failure into this Emacs supervising
a checkout the project declares for Ratatui, until somebody touches
project.conf. Before the cache the next tick recovered, and it still must."
  (let ((tmp (cerebro-test--supervisor-consumer "tui")))
    (unwind-protect
        (with-temp-buffer
          (let ((fail t))
            (cl-letf* ((real (symbol-function 'cerebro--supervisor-value))
                       ((symbol-function 'cerebro--supervisor-value)
                        (lambda (&rest args)
                          (if (and fail (= (length args) 1))
                              (error "the reader could not run")
                            (apply real args)))))
              ;; The transient failure falls back, and is NOT remembered.
              (should (eq (cerebro--configured-supervisor tmp) 'emacs))
              (setq fail nil)
              ;; The very next call sees what the project actually declares.
              (should (eq (cerebro--configured-supervisor tmp) 'tui)))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/reconciling-into-a-lock-error-reports-it ()
  "The WIRING, not the helper: a reconciliation that ends in a lock error reports.

The defect this guards was a message built and never reported - that is, a
missing call site - so a case that calls the reporter directly would have passed
against the broken code. This one drives `cerebro--reconcile-supervision\=' and
fails if the reporting call is removed from it."
  (let ((reported nil)
        (tmp (cerebro-test--supervisor-consumer "emacs")))
    (unwind-protect
        (with-temp-buffer
          (setq-local cerebro--supervision-process nil)
          (setq-local cerebro--supervision-reported nil)
          (cl-letf (((symbol-function 'cerebro--report-error)
                     (lambda (_context format-string &rest args)
                       (push (apply #'format format-string args) reported)))
                    ;; The lease is held by somebody this Emacs cannot identify - the endpoint
                    ;; collision the two-checksum port design rests on being visible.
                    ((symbol-function 'cerebro--acquire-supervision)
                     (lambda (&rest _)
                       '(read-only lock-error
                                    "the lease endpoint is bound by another checkout (/repos/x)"))))
            (let ((mode (cerebro--reconcile-supervision tmp)))
              (should (equal (car mode) 'read-only))
              (should (equal (length reported) 1))
              (should (string-match-p "another checkout" (car reported))))
            ;; Every five seconds, and still one report.
            (cerebro--reconcile-supervision tmp)
            (should (equal (length reported) 1))))
      (delete-directory tmp t))))

(ert-deftest cerebro-test/a-reconciliation-that-signals-reports-once-not-per-tick ()
  "The fail-closed branch is throttled like every other lock error.

It exists for a condition that persists, so reporting per tick would put
seventeen thousand lines a day into `errors.jsonl\=' - the log CLAUDE.md calls
the short one - and blank the echo area every five seconds while it did."
  (let ((reported nil))
    (cl-letf (((symbol-function 'cerebro--report-error)
               (lambda (_context format-string &rest args)
                 (push (apply #'format format-string args) reported)))
              ((symbol-function 'cerebro--configured-supervisor)
               (lambda (&rest _) (error "project.conf is on fire"))))
      (with-temp-buffer
        (setq-local cerebro--supervision '(supervising))
        (setq-local cerebro--supervision-reported nil)
        (dotimes (_ 10) (cerebro--reconcile-supervision-safely "/fake/repo"))
        (should (equal (length reported) 1))
        (should-not (cerebro--supervision-may-act-p cerebro--supervision))))))

(ert-deftest cerebro-test/a-lock-error-reaches-the-error-log ()
  "The reporter itself: once per distinct message, re-armed by a recovery."
  (let ((reported nil))
    (cl-letf (((symbol-function 'cerebro--report-error)
               (lambda (_context format-string &rest args)
                 (push (apply #'format format-string args) reported))))
      (with-temp-buffer
        (setq-local cerebro--supervision-reported nil)
        (cerebro--report-supervision-error
         '(read-only lock-error "the lease endpoint is bound by another checkout (/repos/other)"))
        (should (equal (length reported) 1))
        (should (string-match-p "another checkout" (car reported)))
        ;; Once per distinct message: this runs every five seconds.
        (cerebro--report-supervision-error
         '(read-only lock-error "the lease endpoint is bound by another checkout (/repos/other)"))
        (should (equal (length reported) 1))
        ;; A different failure is a different report.
        (cerebro--report-supervision-error '(read-only lock-error "record is malformed"))
        (should (equal (length reported) 2))
        ;; And recovering re-arms it, so the same fault later is reported again.
        (cerebro--report-supervision-error '(supervising))
        (cerebro--report-supervision-error '(read-only lock-error "record is malformed"))
        (should (equal (length reported) 3))))))

(ert-deftest cerebro-test/a-reconciliation-that-signals-is-read-only ()
  "A failure leaves the mode fail-closed, never whatever it said last.

The tick demotes its errors, which is right for the render - but `s', `f' and
`k' are judged against `cerebro--supervision', so a signal that left the old
value there would let a view act on a checkout it may no longer own."
  (with-temp-buffer
    (setq-local cerebro--supervision '(supervising))
    (cl-letf (((symbol-function 'cerebro--configured-supervisor)
               (lambda (&rest _) (error "project.conf is on fire"))))
      (let ((mode (cerebro--reconcile-supervision-safely "/fake/repo")))
        (should (eq (car mode) 'read-only))
        (should (equal mode cerebro--supervision))
        (should-not (cerebro--supervision-may-act-p cerebro--supervision))
        (should (cerebro--supervision-blocks 'act))))))

(ert-deftest cerebro-test/a-missing-lease-script-keeps-the-historical-behaviour ()
  "A consumer whose submodule predates cb-kcs.1 keeps supervising.

Fail-closed is right for a declaration this build cannot read, and wrong here:
nothing else can compute an endpoint that does not exist either, so nobody can
be holding it.  Read-only would have silently stopped a working fleet the day
it bumped to a submodule missing one script."
  (let ((tmp (make-temp-file "cerebro-no-supervisor" t)))
    (unwind-protect
        (with-temp-buffer
          (setq-local cerebro--supervision-process nil)
          (should (eq (cerebro--acquire-supervision tmp) 'unavailable))
          (should (equal (cerebro--reconcile-supervision tmp) '(supervising))))
      (delete-directory tmp t))))
