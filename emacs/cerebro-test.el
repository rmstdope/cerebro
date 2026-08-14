;;; cerebro-test.el --- Tests for cerebro.el -*- lexical-binding: t; -*-

;; Run from the repository root with:
;;   emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit
;; One test:
;;   emacs --batch -L emacs -l cerebro-test \
;;     --eval '(ert-run-tests-batch-and-exit "<name-or-regexp>")'

(require 'ert)
(require 'cerebro)

;; ---------------------------------------------------------------------------
;; Increment 1: the pure derivation

(defconst cerebro-test--interactive
  '(("Xavier" . "planner")
    ("Cerebro" . "orchestrator")
    ("Moira" . "feedback")))

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

(ert-deftest cerebro-test/entry-external-marked ()
  (let* ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z")))
         (agent (make-cerebro-agent :name "Storm" :role "implementer" :kind 'implementer
                                            :state 'working :bead "ah-f9c"
                                            :since "2026-08-14T09:00:00Z" :external t))
         (entry (cerebro--entry agent now))
         (row (nth 1 entry)))
    (should (equal (aref row 3) "(external)"))
    (should (equal (aref row 4) ""))))

(ert-deftest cerebro-test/entry-dead-has-empty-bead-column ()
  (let* ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z")))
         (agent (make-cerebro-agent :name "Rogue" :role "implementer" :kind 'implementer
                                            :state 'dead :bead nil :since nil :external nil))
         (entry (cerebro--entry agent now))
         (row (nth 1 entry)))
    (should (equal (aref row 3) ""))
    (should (equal (aref row 4) ""))))

(ert-deftest cerebro-test/elapsed-minutes-hours-days ()
  (let ((now (encode-time (iso8601-parse "2026-08-14T09:12:00Z"))))
    (should (equal (cerebro--elapsed "2026-08-14T09:00:00Z" now) "12m"))
    (should (equal (cerebro--elapsed "2026-08-14T08:09:00Z" now) "1h03"))
    (should (equal (cerebro--elapsed "2026-08-12T09:12:00Z" now) "2d"))))

(ert-deftest cerebro-test/elapsed-nil-since-is-empty ()
  (should (equal (cerebro--elapsed nil (current-time)) "")))

;; ---------------------------------------------------------------------------
;; Increment 3: the buffer

(ert-deftest cerebro-test/buffer-lists-every-agent-once ()
  (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () "/fake/repo"))
            ((symbol-function 'cerebro--roster)
             (lambda (_repo-root) (mapcar #'car cerebro-roster-fixture)))
            ((symbol-function 'cerebro--gather-states)
             (lambda (_repo-root _roster) nil))
            ((symbol-function 'cerebro--system-args) (lambda () nil))
            ((symbol-function 'cerebro--owned) (lambda () nil)))
    (unwind-protect
        (progn
          (cerebro)
          (with-current-buffer cerebro-buffer-name
            (should (= (length tabulated-list-entries) 18))
            (should (equal (length (delete-dups (mapcar #'car tabulated-list-entries))) 18))))
      (when (get-buffer cerebro-buffer-name)
        (kill-buffer cerebro-buffer-name)))))

(defconst cerebro-roster-fixture
  (mapcar (lambda (n) (cons n nil))
          '("Cyclops" "Storm" "Wolverine" "Rogue" "Gambit" "Nightcrawler" "Colossus"
            "Iceman" "Beast" "Jubilee" "Psylocke" "Bishop" "Phoenix" "Mystique" "Magneto")))

;; ---------------------------------------------------------------------------
;; Increment 4: roster parsing

(ert-deftest cerebro-test/roster-parses-lines ()
  (should (equal (cerebro--parse-roster "Cyclops\nStorm\nWolverine\n")
                  '("Cyclops" "Storm" "Wolverine"))))

(ert-deftest cerebro-test/roster-parses-lines-ignoring-blank ()
  (should (equal (cerebro--parse-roster "Cyclops\n\nStorm\n\n")
                  '("Cyclops" "Storm"))))

;; ---------------------------------------------------------------------------
;; ah-vcf.3 increment 1: the pure decisions

(defun cerebro-test--agent (name role kind state &optional external bead)
  (make-cerebro-agent :name name :role role :kind kind :state state
                              :bead bead :since nil :external external))

(ert-deftest cerebro-test/launch-command-each-interactive-launcher ()
  (should (equal (cerebro--launch-command
                   (cerebro-test--agent "Xavier" "planner" 'interactive 'dead))
                  ".claude/cerebro/scripts/run-planner"))
  (should (equal (cerebro--launch-command
                   (cerebro-test--agent "Cerebro" "orchestrator" 'interactive 'dead))
                  ".claude/cerebro/scripts/run-orchestrator"))
  (should (equal (cerebro--launch-command
                   (cerebro-test--agent "Moira" "feedback" 'interactive 'dead))
                  ".claude/cerebro/scripts/run-user-feedback")))

(ert-deftest cerebro-test/launch-command-implementer-takes-its-name ()
  (should (equal (cerebro--launch-command
                   (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
                  '(".claude/cerebro/scripts/run-implementer" "Cyclops"))))

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

(ert-deftest cerebro-test/owned-buffer-agent-name-matches-session-scheme ()
  (should (equal (cerebro--owned-buffer-agent-name "*fleet: Cyclops*") "Cyclops"))
  (should (equal (cerebro--owned-buffer-agent-name "*fleet: Xavier*") "Xavier")))

(ert-deftest cerebro-test/owned-buffer-agent-name-no-match ()
  (should (null (cerebro--owned-buffer-agent-name "*scratch*")))
  (should (null (cerebro--owned-buffer-agent-name "*fleet: Cyclops (no view)*"))))

;; ---------------------------------------------------------------------------
;; ah-vcf.3 increment 3: windows and keys

(ert-deftest cerebro-test/show-detail-picks-session-when-owned-else-placeholder ()
  (let* ((owned-agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'working
                                                    nil "ah-f9c"))
         (dead-agent (cerebro-test--agent "Rogue" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name owned-agent))
         (placeholder-name "*fleet: Rogue (no view)*"))
    (unwind-protect
        (progn
          (get-buffer-create session-name)
          (cl-letf (((symbol-function 'cerebro--owned) (lambda () '("Cyclops"))))
            (should (eq (cerebro--show-detail owned-agent) (get-buffer session-name)))
            (let ((placeholder (cerebro--show-detail dead-agent)))
              (should (equal (buffer-name placeholder) placeholder-name))
              (should (equal (with-current-buffer placeholder (buffer-string))
                              (cerebro--placeholder dead-agent))))))
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

;; vterm shows its new buffer with `pop-to-buffer-same-window', which takes
;; the *selected* window - the list window, since `s' is pressed there.  This
;; stands in for it, so the test pins the wiring rather than a helper nobody
;; would notice was bypassed.
(defun cerebro-test--spawn-like-vterm (buffer)
  "Display BUFFER the way `vterm' does, and return it."
  (pop-to-buffer-same-window buffer)
  buffer)

(ert-deftest cerebro-test/spawn-into-detail-leaves-the-list-visible ()
  (let ((session (generate-new-buffer " *cerebro-test-session*")))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          ;; Buffer names rather than objects: ert renders a failing form's
          ;; values after this test's cleanup has killed the buffers, and
          ;; "#<killed buffer> vs #<killed buffer>" says nothing.
          (let ((list-window (selected-window))
                (shown (cerebro--spawn-into-detail
                        (buffer-name session)
                        (lambda () (cerebro-test--spawn-like-vterm session)))))
            ;; The reported symptom first: the navigator can still see the fleet.
            (should (equal (buffer-name (window-buffer list-window))
                            (buffer-name list-buffer)))
            (should (equal (buffer-name (window-buffer detail-window))
                            (buffer-name session)))
            (should (eq shown session))
            (should (eq (selected-window) list-window))
            (should (eq (current-buffer) list-buffer))))
      (kill-buffer session))))

(ert-deftest cerebro-test/spawn-into-detail-without-a-detail-window-keeps-the-list ()
  "A torn-down layout must still start the agent - without hiding the fleet.

`cerebro--setup-layout' only rebuilds the split when the *list* window is
dead, so `C-x 1' in the list window leaves a live list and a dead detail
window that `M-x cerebro' will not restore.  Falling back to the selected
window there would silently reproduce the very bug this code exists to fix."
  (let ((session (generate-new-buffer " *cerebro-test-session*")))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (delete-window detail-window)
          (let ((list-window (selected-window)))
            (should (eq (cerebro--spawn-into-detail
                         (buffer-name session)
                         (lambda () (cerebro-test--spawn-like-vterm session)))
                        session))
            (should (equal (buffer-name (window-buffer list-window))
                            (buffer-name list-buffer)))))
      (kill-buffer session))))

(ert-deftest cerebro-test/spawn-into-detail-only-claims-its-own-buffer ()
  "The override must not swallow whatever else the spawn displays.

`vterm--internal' runs `vterm-mode' *after* displaying the session, so a
`display-warning' (or the module-compile log on a first run) lands while the
override is still bound.  An unscoped action would evict the session and
leave the navigator looking at a warning buffer."
  (let ((session (generate-new-buffer " *cerebro-test-session*"))
        (foreign (generate-new-buffer " *cerebro-test-foreign*")))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (let* ((extra (split-window detail-window nil 'below))
                 ;; Beaten by an overriding action, so it only gets a say if
                 ;; ours correctly declines the foreign buffer.
                 (display-buffer-alist
                  (list (cons (regexp-quote (buffer-name foreign))
                              (list (lambda (buffer _alist)
                                      (set-window-buffer extra buffer)
                                      extra))))))
            (cerebro--spawn-into-detail
             (buffer-name session)
             (lambda ()
               (prog1 (cerebro-test--spawn-like-vterm session)
                 (display-buffer foreign))))
            (should (equal (buffer-name (window-buffer detail-window))
                            (buffer-name session)))
            (should (equal (buffer-name (window-buffer extra))
                            (buffer-name foreign)))))
      (kill-buffer session)
      (kill-buffer foreign))))

(ert-deftest cerebro-test/spawn-into-detail-survives-a-dedicated-detail-window ()
  "A signal from `set-window-buffer' must not strand a half-built session.

If it propagates, it escapes `vterm--internal' between `generate-new-buffer'
and `vterm-mode', leaving a live process-less `*fleet: <name>*'.  The next
start then gets `*fleet: <name>*<2>', which `cerebro--owned-buffer-agent-name'
does not match - so that session is invisible to the fleet list for ever."
  (let ((session (generate-new-buffer " *cerebro-test-session*"))
        (hostage (generate-new-buffer " *cerebro-test-hostage*")))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (set-window-buffer detail-window hostage)
          (set-window-dedicated-p detail-window t)
          (let ((list-window (selected-window)))
            (should (eq (cerebro--spawn-into-detail
                         (buffer-name session)
                         (lambda () (cerebro-test--spawn-like-vterm session)))
                        session))
            (should (equal (buffer-name (window-buffer list-window))
                            (buffer-name list-buffer)))))
      (kill-buffer session)
      (kill-buffer hostage))))

;; Entering through `cerebro--launch' rather than the seam it calls: without
;; this, `cerebro--launch' could go back to calling `vterm' directly and every
;; other test here would still pass.  Proven by mutation, not assumed.
(ert-deftest cerebro-test/launch-puts-the-session-in-the-detail-window ()
  ;; Note this stubs `require' rather than loading vterm, so `vterm-shell' is
  ;; never read - this pins where the session is displayed, not the command.
  (let* ((agent (cerebro-test--agent "Cyclops" "implementer" 'implementer 'dead))
         (session-name (cerebro--session-buffer-name agent))
         (orig-require (symbol-function 'require)))
    (unwind-protect
        (cerebro-test--with-layout list-buffer detail-window
          (cl-letf (((symbol-function 'cerebro--repo-root)
                     (lambda () default-directory))
                    ;; vterm is not installed in batch; stand in for it.
                    ;; Delegate rather than blanket-nil: a `should' failing
                    ;; inside this body has ert building its explanation while
                    ;; `require' is stubbed, and a lazy require answering nil
                    ;; there produces a confusing secondary failure.
                    ((symbol-function 'require)
                     (lambda (feature &rest args)
                       (or (eq feature 'vterm) (apply orig-require feature args))))
                    ((symbol-function 'vterm)
                     (lambda (name)
                       (cerebro-test--spawn-like-vterm (get-buffer-create name)))))
            (let ((list-window (selected-window)))
              (cerebro--launch agent)
              (should (equal (buffer-name (window-buffer list-window))
                              (buffer-name list-buffer)))
              (should (equal (buffer-name (window-buffer detail-window))
                              session-name)))))
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
  (dolist (state '(working idle asking))
    (should (null (cerebro--supervise-action
                   (cerebro-test--supervised state nil "2026-08-14T09:29:00Z")
                   t cerebro-test--now)))))

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

Launching first would leave two sessions for one name, and vterm would call
the second `*fleet: Cyclops*<2>' - a name `cerebro--owned-buffer-agent-name'
does not match, so it would be invisible to the list for ever."
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

(ert-deftest cerebro-test/stop-flag-path-is-the-documented-one ()
  (should (equal (cerebro--stop-flag-path "/repo" "Cyclops")
                  "/repo/.claude/implementers/Cyclops.stop")))

;; ---------------------------------------------------------------------------
;; A session Emacs owns is alive, whatever the state file says yet

(ert-deftest cerebro-test/derive-owned-implementer-without-a-state-file-is-idle ()
  "A just-launched implementer has a session before it has a state file.

Reporting it dead there is not cosmetic: `cerebro--start-action' tests
aliveness *before* it tests ownership, so `s' would launch a second session
for the same name - and vterm would call it `*fleet: Cyclops*<2>', a name
`cerebro--owned-buffer-agent-name' does not match, invisible to the list for
ever."
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
  (should (memq 'warning (cerebro-test--faces-at (cerebro--glyph 'idle) 0)))
  ;; Still distinguishable from the states either side of it.
  (should (memq 'success (cerebro-test--faces-at (cerebro--glyph 'working) 0)))
  (should (memq 'shadow (cerebro-test--faces-at (cerebro--glyph 'dead) 0))))

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

(provide 'cerebro-test)
;;; cerebro-test.el ends here
