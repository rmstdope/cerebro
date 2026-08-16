;;; cerebro-test.el --- Tests for cerebro.el -*- lexical-binding: t; -*-

;; Run from the repository root with:
;;   emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit
;; One test:
;;   emacs --batch -L emacs -l cerebro-test \
;;     --eval '(ert-run-tests-batch-and-exit "<name-or-regexp>")'

(require 'ert)
(require 'cerebro)

(defconst cerebro-test--repo-root
  (expand-file-name ".." (file-name-directory
                           (or load-file-name buffer-file-name)))
  "The repository root: the parent of the directory holding this file.
Captured at load time - `load-file-name' is nil once loading is done, so a
test body cannot compute this itself.")

;; ---------------------------------------------------------------------------
;; Increment 1: the pure derivation

(defconst cerebro-test--interactive
  '(("Xavier" . "planner")
    ("Cerebro" . "orchestrator")
    ("Moira" . "user-feedback")))

(defun cerebro-test--always-alive (_pid) t)
(defun cerebro-test--never-alive (_pid) nil)

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

(ert-deftest cerebro-test/derive-interactive-up-from-process-args ()
  (let* ((args '("claude --agent planner --name Xavier --print"))
         (agents (cerebro--derive nil cerebro-test--interactive nil
                                          #'cerebro-test--never-alive args nil))
         (xavier (car agents)))
    (should (eq (cerebro-agent-state xavier) 'up))
    (should (cerebro-agent-external xavier))))

(ert-deftest cerebro-test/name-in-args-reads-only-the-name-flag ()
  ;; ah-qym: every launch now carries `--remote-control NAME' too. The needle must still key on
  ;; `--name' alone - a name that appears only as the remote-control value, or a flag that merely
  ;; contains "-name-", must not make an agent look up.
  (should (cerebro--name-in-args-p
           "Xavier" '("claude --agent planner --name Xavier --remote-control Xavier --permission-mode auto")))
  (should-not (cerebro--name-in-args-p
               "Xavier" '("claude --agent planner --remote-control Xavier --permission-mode auto")))
  (should-not (cerebro--name-in-args-p
               "Xavier" '("claude --remote-control-session-name-prefix Xavier --name Storm")))
  (should (cerebro--name-in-args-p
           "Storm" '("claude --remote-control-session-name-prefix Xavier --name Storm"))))

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
         (args '("claude --agent planner --name Xavier --print"))
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

(ert-deftest cerebro-test/derive-interactive-treats-done-as-unknown ()
  ;; `scripts/agent-state' refuses `done' from an interactive name, so a live
  ;; file carrying it anyway is a bug, not a finished bead - it must not be
  ;; handed to `cerebro--supervise-action' as a `done' implementer would be.
  (let* ((states '(("Forge" . ((state . "done") (bead . nil)
                                 (since . "2026-08-15T09:00:00Z") (pid . 777)))))
         (agents (cerebro--derive nil '(("Forge" . "architect")) states
                                          #'cerebro-test--always-alive nil nil))
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
            ((symbol-function 'cerebro--system-args) (lambda () nil))
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

(ert-deftest cerebro-test/session-buffer-name-shape ()
  (should (equal (cerebro--session-buffer-name
                   (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
                  "*fleet: Cyclops*")))

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
  (dolist (state '(dead asking done unknown))
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

;; ---------------------------------------------------------------------------
;; ah-bri: a session that dies before it gets going keeps its last line readable

(ert-deftest cerebro-test/exit-record-only-for-abnormal-exits ()
  (should (equal (cerebro--exit-record "exited abnormally with code 2\n" "cerebro: x")
                  (cons "2" "cerebro: x")))
  (should (null (cerebro--exit-record "finished\n" "cerebro: x")))
  (should (null (cerebro--exit-record "killed\n" "cerebro: x")))
  (should (null (cerebro--exit-record "hangup\n" "cerebro: x")))
  (should (null (cerebro--exit-record "exited abnormally with code 2\n" nil))))

(ert-deftest cerebro-test/last-nonblank-line ()
  (should (equal (cerebro--last-nonblank-line "a\nb  \n\n   \n") "b"))
  (should (null (cerebro--last-nonblank-line "")))
  (should (null (cerebro--last-nonblank-line "\n\n"))))

(ert-deftest cerebro-test/placeholder-shows-the-last-exit-line ()
  (let ((cerebro--last-exit '(("Forge" . "cerebro: boom"))))
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
                              "cerebro: boom")))
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

(ert-deftest cerebro-test/finish-action-refuses-interactive-roles ()
  (should (eq (cerebro--finish-action
                (cerebro-test--agent "Xavier" "planner" 'interactive 'up)
                nil)
              'not-implementer)))

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
    (dolist (state '(dead idle done))
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

;; ---------------------------------------------------------------------------
;; ah-aao: a restart only refreshes a detail window that was watching it

(ert-deftest cerebro-test/detail-showing-p-tracks-the-window ()
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (session (get-buffer-create session-name))
         (proc (start-process "cerebro-test" session "sleep" "30"))
         (other (generate-new-buffer " *cerebro-test-other*")))
    (set-process-query-on-exit-flag proc nil)
    (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) session)
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (set-window-buffer detail-window session)
          (should (cerebro--detail-showing-p agent))
          (set-window-buffer detail-window other)
          (should-not (cerebro--detail-showing-p agent))
          (let ((dead-window detail-window))
            (delete-window detail-window)
            (setq-local cerebro--detail-window dead-window)
            (should-not (cerebro--detail-showing-p agent)))
          (setq-local cerebro--detail-window nil)
          (should-not (cerebro--detail-showing-p agent)))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer session)
      (kill-buffer other))))

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

(ert-deftest cerebro-test/end-session-forgets-the-session ()
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (buf (get-buffer-create session-name)))
    (unwind-protect
        (let ((proc (start-process "cerebro-test" buf "sleep" "30")))
          (set-process-query-on-exit-flag proc nil)
          (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
          (should (eq (cerebro--session "Cyclops") buf))
          (cerebro--end-session agent)
          (should (null (get-buffer session-name)))
          (should (null (cerebro--session "Cyclops"))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

(ert-deftest cerebro-test/end-session-kills-a-buffer-whose-process-already-exited ()
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
          (cerebro--end-session agent)
          (should (null (get-buffer session-name)))
          (should (null (alist-get "Cyclops" cerebro--sessions nil nil #'equal))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

(ert-deftest cerebro-test/kill-session-buffer-kills-a-buffer-whose-process-already-exited ()
  "The same fix as `end-session-kills-a-buffer-whose-process-already-exited',
for the `k' path."
  (let* ((cerebro--sessions nil)
         (agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working))
         (session-name (cerebro--session-buffer-name agent))
         (buf (get-buffer-create session-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'revert-buffer) #'ignore)
                  ((symbol-function 'cerebro--show-detail) #'ignore))
          (setf (alist-get "Cyclops" cerebro--sessions nil nil #'equal) buf)
          (should (null (cerebro--session "Cyclops")))
          (cerebro--kill-session-buffer agent)
          (should (null (get-buffer session-name)))
          (should (null (alist-get "Cyclops" cerebro--sessions nil nil #'equal))))
      (when (get-buffer session-name) (kill-buffer session-name)))))

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

(ert-deftest cerebro-test/derive-implementer-done-and-asking-states ()
  "The state file gained two states when implementers became interactive."
  (let* ((states '(("Cyclops" . ((state . "done") (bead . "ah-f9c")
                                  (since . "2026-08-14T09:00:00Z") (pid . 42)))
                   ("Storm" . ((state . "asking") (bead . "ah-a1b")
                                (since . "2026-08-14T09:00:00Z") (pid . 43)))))
         (agents (cerebro--derive '("Cyclops" "Storm") nil states
                                          #'cerebro-test--always-alive nil
                                          '("Cyclops" "Storm"))))
    (should (eq (cerebro-agent-state (nth 0 agents)) 'done))
    (should (eq (cerebro-agent-state (nth 1 agents)) 'asking))
    ;; The bead stays visible in both - it is what the navigator needs to see.
    (should (equal (cerebro-agent-bead (nth 1 agents)) "ah-a1b"))))

(defun cerebro-test--supervised (state &optional external since)
  (make-cerebro-agent :name "Cyclops" :role "implementer" :kind 'implementer
                              :state state :bead "ah-f9c" :since since
                              :external external))

(defconst cerebro-test--now (encode-time (iso8601-parse "2026-08-14T09:30:00Z")))

(ert-deftest cerebro-test/supervise-restarts-a-finished-implementer ()
  "One bead per session: a finished session is replaced, not reused.

This is the whole reason the sessions are short - a fresh one starts with a
clean context instead of the residue of every bead before it."
  (should (eq (cerebro--supervise-action (cerebro-test--supervised 'done) nil
                                                  cerebro-test--now)
              'restart)))

(ert-deftest cerebro-test/supervise-retires-a-finished-implementer-under-stop ()
  "A stop flag lets the bead finish and then takes the terminal down.

The flag is read here, between beads, and never mid-bead: an implementer
killed in flight strands a claim, a worktree and an open PR."
  (should (eq (cerebro--supervise-action (cerebro-test--supervised 'done) t
                                                  cerebro-test--now)
              'retire)))

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
now* rather than *finish* - unlike `done', which waits for nothing further to
strand."
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
  (should (null (cerebro--supervise-action (cerebro-test--supervised 'done t) nil
                                                    cerebro-test--now))))

(ert-deftest cerebro-test/supervise-leaves-a-dead-implementer-dead ()
  "Restarting a dead one would fight the navigator's own `k'."
  (should (null (cerebro--supervise-action (cerebro-test--supervised 'dead) nil
                                                    cerebro-test--now))))

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
  (dolist (state '(done asking))
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
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)
        (should (equal nudged '("Cyclops")))
        ;; Once it answers and moves on, a later question is nudgeable again.
        (cerebro--supervise (list (cerebro-test--supervised 'working))
                                    "/fake/repo" cerebro-test--now)
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)
        (should (equal nudged '("Cyclops" "Cyclops")))))))

(ert-deftest cerebro-test/supervise-restart-kills-then-launches ()
  "Restart is a kill and a fresh launch, in that order.

Launching first would leave two sessions for one name, and `cerebro--launch'
would refuse the second rather than let vterm call it `*fleet: Cyclops*<2>'
and leave it invisible to the list."
  (let ((calls nil)
        (agent (cerebro-test--supervised 'done)))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) nil))
              ((symbol-function 'cerebro--end-session)
               (lambda (a) (push (cons 'kill (cerebro-agent-name a)) calls)))
              ((symbol-function 'cerebro--launch)
               (lambda (a) (push (cons 'launch (cerebro-agent-name a)) calls))))
      (with-temp-buffer
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)
        (should (equal (reverse calls) '((kill . "Cyclops") (launch . "Cyclops"))))))))

(ert-deftest cerebro-test/restart-shows-the-session-only-where-it-was-watched ()
  "A restart only refreshes a detail window that was showing that agent.

The showing-check has to run before `cerebro--end-session' kills the
buffer the window is showing - after that the window shows whatever the
kill left behind, and the check would be meaningless.  Placement now goes
through `cerebro--show-detail', the same function `s' uses."
  (let ((calls nil)
        (agent (cerebro-test--supervised 'done)))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) nil))
              ((symbol-function 'cerebro--end-session)
               (lambda (a) (push (cons 'kill (cerebro-agent-name a)) calls)))
              ((symbol-function 'cerebro--launch)
               (lambda (a) (push (cons 'launch (cerebro-agent-name a)) calls)))
              ((symbol-function 'cerebro--show-detail)
               (lambda (a) (push (cons 'shown (cerebro-agent-name a)) calls))))
      ;; Watching: a detail window showing the agent's own session.
      (let ((watching t))
        (cl-letf (((symbol-function 'cerebro--detail-showing-p)
                   (lambda (a)
                     (push (cons 'checked (cerebro-agent-name a)) calls)
                     watching)))
          (with-temp-buffer
            (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)))
        (should (equal (reverse calls)
                        (list (cons 'checked "Cyclops")
                              (cons 'kill "Cyclops")
                              (cons 'launch "Cyclops")
                              (cons 'shown "Cyclops")))))
      ;; Not watching: nothing in the detail window was showing this agent.
      (setq calls nil)
      (let ((watching nil))
        (cl-letf (((symbol-function 'cerebro--detail-showing-p)
                   (lambda (a)
                     (push (cons 'checked (cerebro-agent-name a)) calls)
                     watching)))
          (with-temp-buffer
            (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)))
        (should (equal (reverse calls)
                        (list (cons 'checked "Cyclops")
                              (cons 'kill "Cyclops")
                              (cons 'launch "Cyclops"))))))))

(ert-deftest cerebro-test/supervise-retire-kills-without-launching ()
  "A stop flag means this name does not come back until the navigator says so."
  (let ((calls nil)
        (agent (cerebro-test--supervised 'done)))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) t))
              ((symbol-function 'cerebro--end-session)
               (lambda (a) (push (cons 'kill (cerebro-agent-name a)) calls)))
              ((symbol-function 'cerebro--launch)
               (lambda (a) (push (cons 'launch (cerebro-agent-name a)) calls))))
      (with-temp-buffer
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)
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
        (agent (cerebro-test--supervised 'done)))
    (unwind-protect
        (progn
          (cerebro--write-stop-flag root "Cyclops")
          (cl-letf (((symbol-function 'cerebro--end-session) (lambda (_a) nil))
                    ((symbol-function 'cerebro--launch) (lambda (&rest _) nil)))
            (with-temp-buffer
              (cerebro--supervise (list agent) root cerebro-test--now)))
          (should-not (cerebro--stop-flag-p root "Cyclops")))
      (delete-directory root t))))

(ert-deftest cerebro-test/restart-leaves-no-flag-to-remove ()
  "The mirror of the retire case: no flag, nothing to clear, the launch
still happens exactly once."
  (let ((root (make-temp-file "cerebro-test-" t))
        (agent (cerebro-test--supervised 'done))
        (launched nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'cerebro--end-session) (lambda (_a) nil))
                    ((symbol-function 'cerebro--launch)
                     (lambda (&rest _) (setq launched (1+ (or launched 0))))))
            (with-temp-buffer
              (cerebro--supervise (list agent) root cerebro-test--now)))
          (should-not (cerebro--stop-flag-p root "Cyclops"))
          (should (= launched 1)))
      (delete-directory root t))))

(ert-deftest cerebro-test/supervise-ends-an-idle-session-under-stop ()
  "The supervisor, not just the pure decision, actually ends an idle
implementer under a stop flag - `cerebro--end-session', not `cerebro--launch'."
  (let ((ended nil)
        (agent (cerebro-test--supervised 'idle)))
    (cl-letf (((symbol-function 'cerebro--stop-flag-p) (lambda (_root _name) t))
              ((symbol-function 'cerebro--end-session)
               (lambda (a) (push (cerebro-agent-name a) ended)))
              ((symbol-function 'cerebro--launch) (lambda (&rest _) (error "launched"))))
      (with-temp-buffer
        (cerebro--supervise (list agent) "/fake/repo" cerebro-test--now)
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
here changed - a bare `scripts/run-planner' resolves to the consumer's
directory, where there is no longer anything by that name."
  (should (equal (cerebro--script "run-planner") ".claude/cerebro/scripts/run-planner"))
  (should (string-prefix-p ".claude/cerebro/scripts/" (cerebro--script "run-implementer"))))

;; ---------------------------------------------------------------------------
;; Reading the list at a glance

(defun cerebro-test--faces-at (string index)
  "The face property at INDEX of STRING, always as a list."
  (let ((face (get-text-property index 'face string)))
    (if (listp face) face (list face))))

(ert-deftest cerebro-test/idle-glyph-is-yellow ()
  "Idle is not the same kind of nothing as dead.

An idle implementer has a session up and no bead - something the navigator
may want to act on - so it reads as yellow rather than as the grey that
means there is nobody there at all."
  (should (memq 'cerebro-idle (cerebro-test--faces-at (cerebro--glyph 'idle) 0)))
  ;; Still distinguishable from the states either side of it.
  (should (memq 'success (cerebro-test--faces-at (cerebro--glyph 'working) 0)))
  (should (memq 'shadow (cerebro-test--faces-at (cerebro--glyph 'dead) 0))))

(ert-deftest cerebro-test/idle-face-is-actually-yellow-and-not-bold ()
  "`warning\=' is DarkOrange and bold, which is two wrongs at once.

Emacs defines `warning\=' as `:foreground \"DarkOrange\" :weight bold\' on any
colour display - so the idle dot was orange rather than yellow, and bold,
which is the weight this view reserves for an agent that wants an answer.
`cerebro-idle\=' is a plain yellow instead, and customizable in one place for
a theme where gold does not read."
  (let ((spec (format "%S" (get 'cerebro-idle 'face-defface-spec))))
    (should (string-match-p "gold\\|yellow" (downcase spec)))
    (should-not (string-match-p "bold" (downcase spec)))))

(ert-deftest cerebro-test/idle-is-a-filled-dot-not-a-ring ()
  "The colour was right and the shape defeated it.

Idle was U+25CC DOTTED CIRCLE and dead is U+25CB WHITE CIRCLE: two hollow
rings that are the same picture at terminal sizes, so a yellow one read as
\"an empty circle, just like the dead\" however yellow it was. Idle is a
filled dot now - the thing that was actually asked for - and only the colour
separates it from working, which is what the State column spells out anyway."
  (let ((idle (substring-no-properties (cerebro--glyph 'idle)))
        (dead (substring-no-properties (cerebro--glyph 'dead)))
        (working (substring-no-properties (cerebro--glyph 'working))))
    (should (equal idle "●"))
    (should (equal idle working))
    (should-not (equal idle dead))))

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
  (dolist (state '(working idle done dead))
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
               (cerebro-test--bead "ah-13o" 1 "Resizable split" "henrik@kurelid.se") 62)))
    (should-not (string-match-p "henrik" line))
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
         (text (string-join
                (cerebro--bead-panel claimed nil unplanned merged 62 8) "\n"))
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

(ert-deftest cerebro-test/layout-puts-the-panel-under-the-list ()
  (let ((fleet (generate-new-buffer " *cerebro-test-fleet*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--gather-beads) (lambda (_root) (list nil nil nil nil)))
                  ((symbol-function 'cerebro--gather-sweeps) (lambda (_root) nil)))
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
                  ((symbol-function 'cerebro--gather-sweeps) (lambda (_root) nil))
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
            ((symbol-function 'cerebro--gather-beads) (lambda (_root) (list nil nil nil nil)))
            ((symbol-function 'cerebro--gather-sweeps) (lambda (_root) nil)))
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
                   ((symbol-function 'cerebro--gather-beads)
                    (lambda (_root)
                      (list (list (cerebro-test--bead "ah-c1" 1 "claimed one"))
                            (list (cerebro-test--bead "ah-p1" 0 "planned one"))
                            (list (cerebro-test--bead "ah-u1" 1 "unplanned one")
                                  (cerebro-test--bead "ah-u2" 2 "unplanned two"))
                            nil))))
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
    (cl-letf (((symbol-function 'cerebro--gather-beads)
               (lambda (_root)
                 (list (list (cerebro-test--bead "ah-c0" 0 "new claim")
                             (cerebro-test--bead "ah-c1" 1 "claimed one"))
                       (list (cerebro-test--bead "ah-p1" 0 "planned one"))
                       nil nil))))
      (cerebro--beads-render buffer)
      (should (equal (cerebro--bead-at-point) "ah-p1")))))

(ert-deftest cerebro-test/a-vanished-bead-does-not-strand-the-mark ()
  "Merged and closed while selected: fall back to the first row, not to nowhere."
  (cerebro-test--with-panel buffer
    (should (equal (cerebro--bead-at-point) "ah-c1"))
    (cl-letf (((symbol-function 'cerebro--gather-beads)
               (lambda (_root)
                 (list nil nil (list (cerebro-test--bead "ah-u1" 1 "left")) nil))))
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
            ((symbol-function 'cerebro--gather-beads)
             (lambda (_root)
               (list nil nil (list (cerebro-test--bead "ah-u1" 1 "first real bead")) nil))))
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
  "Claimed, planned, unplanned, merged - as far as the panel follows work."
  (let* ((text (string-join (cerebro--bead-panel nil nil nil nil 62 8) "\n"))
         (at (lambda (s) (string-match (regexp-quote s) text))))
    (should (< (funcall at "Claimed") (funcall at "Planned, unclaimed")))
    (should (< (funcall at "Planned, unclaimed") (funcall at "Unplanned")))
    (should (< (funcall at "Unplanned") (funcall at "Merged, unverified")))))

(ert-deftest cerebro-test/the-panel-stops-at-merged ()
  "The panel shows work the fleet can act on, and drops the rest.

Not everything needs a home here: verified work is finished, epics are
parents rather than work, bd's `event' records are its own bookkeeping, and
blocked or deferred beads cannot be picked up.  They are left out rather
than filed somewhere nobody reads."
  (let ((text (string-join
               (apply #'cerebro--bead-panel
                      (append (cerebro--partition-beads cerebro-test--every-shape)
                              (list 62 8)))
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
  "Four buckets, and everything else deliberately in none of them."
  (let* ((buckets (cerebro--partition-beads cerebro-test--every-shape))
         (ids (lambda (n) (mapcar (lambda (b) (alist-get 'id b)) (nth n buckets)))))
    (should (= 4 (length buckets)))
    (should (equal (funcall ids 0) '("in-progress")))
    (should (equal (funcall ids 1) '("open-planned")))
    (should (equal (funcall ids 2) '("open-loose")))
    ;; Merged is what still wants verifying: bare, or failed and rebuilt.
    (should (equal (sort (funcall ids 3) #'string<) '("closed-bare" "closed-failed")))
    ;; And nothing else got in anywhere: verified work, epics, bd's own event
    ;; records, blocked, deferred, and a status from a future bd.
    (should (= 5 (length (apply #'append buckets))))))

(ert-deftest cerebro-test/one-query-covers-every-status ()
  "Five statuses in one call: the partition can only be complete if the
list it partitions is."
  (let ((asked nil))
    (cl-letf (((symbol-function 'cerebro--bd-json)
               (lambda (_root &rest args) (push args asked) nil)))
      (cerebro--gather-beads "/repo")
      (should (= 1 (length asked)))
      (let ((args (car asked)))
        (dolist (status '("open" "in_progress" "blocked" "deferred" "closed"))
          (should (cl-some (lambda (a) (string-match-p status a)) args)))
        ;; No type exclusion: an epic has to land in Other, not vanish.
        (should-not (member "--exclude-type" args))))))

;; ---------------------------------------------------------------------------
;; ah-4ao increment 3: turning a sweep's facts into a decision

;; `cerebro--claim-finding' works from `sweep-claims.sh's JSON, parsed the way
;; `cerebro--bd-json' would: an alist with symbol keys.
(defun cerebro-test--claim-candidate (id assignee &optional on-main age verification-failed
                                                    docs-only lease-age)
  ;; Booleans as `cerebro--bd-json' parses them: `:false-object nil', so JSON
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
itself - \"Henrik Kurelid\" is a live claim held by hand exactly as often
as it is a crashed session, and only the lease tells the two apart. A bead
this function has just claimed, whose own session sets no `BEADS_ACTOR',
must not be offered for reclaim the moment its assignee reads as a human
name - which is the bug this test was written to catch."
  (should (null (cerebro--claim-finding
                 (cerebro-test--claim-candidate "ah-x1" "Henrik Kurelid" nil nil nil nil 3)
                 nil (current-time))))
  (should (null (cerebro--claim-finding
                 (cerebro-test--claim-candidate "ah-x1" "Henrik Kurelid" nil nil nil nil nil)
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

(ert-deftest cerebro-test/finding-command-covers-only-the-three-shapes ()
  "This function is the complete list of destructive commands the fleet
view can run - so its total output range has to be pinned, not just its
happy path."
  (should (equal (cerebro--finding-command '(close "ah-x1" "reason here") "/repo")
                 '("bd" "close" "ah-x1" "--reason" "reason here")))
  (should (equal (cerebro--finding-command '(reclaim "ah-x1") "/repo")
                 '("bd" "reclaim" "--id" "ah-x1" "--older-than" "10m")))
  (should (equal (cerebro--finding-command '(epic-close "ah-e1") "/repo")
                 '("bd" "close" "ah-e1")))
  (should (null (cerebro--finding-command nil "/repo")))
  (should-error (cerebro--finding-command '(unknown-shape "ah-x1") "/repo")))

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
    (should (memq 'cerebro-idle (cerebro-test--faces-at glyph 0)))))

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
  (dolist (state '(asking done unknown))
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
nothing a human would notice.  `cerebro--sweep' itself is not stubbed, so
its own call to `cerebro--beads-render' counts toward PANEL-CALLS too - a
tick where both cadences are due must still render exactly once."
  (let ((list-calls 0) (supervise-calls 0) (panel-calls 0) (sweep-gather-calls 0))
    (cl-letf (((symbol-function 'cerebro--list-render) (lambda (_buffer) (cl-incf list-calls)))
              ((symbol-function 'cerebro--supervise) (lambda (&rest _) (cl-incf supervise-calls)))
              ((symbol-function 'cerebro--beads-render) (lambda (_buffer) (cl-incf panel-calls)))
              ((symbol-function 'cerebro--gather-sweeps)
               (lambda (_root) (cl-incf sweep-gather-calls) nil))
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
              (should (= sweep-gather-calls 1))
              ;; T+5: neither cadence is up yet.
              (cerebro--tick list-buffer (seconds-to-time 1005))
              (should (= list-calls 2))
              (should (= supervise-calls 2))
              (should (= panel-calls 1))
              (should (= sweep-gather-calls 1))
              ;; T+30: the panel's thirty seconds are up; the sweeps' are not.
              (cerebro--tick list-buffer (seconds-to-time 1030))
              (should (= panel-calls 2))
              (should (= sweep-gather-calls 1))
              ;; T+1000: the sweeps' ten minutes are up too - one render, not two.
              (cerebro--tick list-buffer (seconds-to-time 2000))
              (should (= panel-calls 3))
              (should (= sweep-gather-calls 2)))
          (kill-buffer list-buffer)
          (kill-buffer panel))))))

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
            ((symbol-function 'cerebro--gather-beads) (lambda (_root) (list nil nil nil nil)))
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

(provide 'cerebro-test)
;;; cerebro-test.el ends here
