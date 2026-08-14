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
            (should (equal (length (delete-dups (mapcar #'car tabulated-list-entries))) 18))
            ;; Not just the count: every interactive agent and every roster
            ;; name appears exactly once, with no overlap between the two -
            ;; Psylocke moving from the roster to the interactive list must
            ;; not let the row count hold by coincidence again.
            (should (equal (sort (mapcar #'car tabulated-list-entries) #'string<)
                            (sort (append (mapcar #'car cerebro-interactive-agents)
                                          (mapcar #'car cerebro-roster-fixture))
                                  #'string<)))))
      (when (get-buffer cerebro-buffer-name)
        (kill-buffer cerebro-buffer-name)))))

(defconst cerebro-roster-fixture
  (mapcar (lambda (n) (cons n nil))
          '("Cyclops" "Storm" "Wolverine" "Rogue" "Gambit" "Nightcrawler" "Colossus"
            "Iceman" "Beast" "Jubilee" "Bishop" "Phoenix" "Mystique" "Magneto")))

;; ---------------------------------------------------------------------------
;; ah-7s7: Psylocke joins the interactive roster

(ert-deftest cerebro-test/interactive-roster-has-psylocke ()
  (should (equal (assoc "Psylocke" cerebro-interactive-agents) '("Psylocke" . "verifier")))
  (should (= (length cerebro-interactive-agents) 4)))

(ert-deftest cerebro-test/launch-command-verifier ()
  (should (equal (cerebro--launch-command
                   (cerebro-test--agent "Psylocke" "verifier" 'interactive 'dead))
                  ".claude/cerebro/scripts/run-psylocke")))

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
         (verified (list (cerebro-test--bead "ah-v1" 2 "checked")))
         (text (string-join
                (cerebro--bead-panel claimed nil unplanned merged verified nil 62 8) "\n"))
         (at (lambda (s) (string-match (regexp-quote s) text))))
    ;; Each bead under the heading it belongs to, not merely present somewhere.
    (should (< (funcall at "Claimed") (funcall at "ah-13o")))
    (should (< (funcall at "ah-13o") (funcall at "Planned, unclaimed")))
    (should (< (funcall at "Unplanned") (funcall at "ah-7s7")))
    (should (< (funcall at "Merged, unverified") (funcall at "ah-m1")))
    (should (< (funcall at "Verified") (funcall at "ah-v1")))))

(ert-deftest cerebro-test/bd-json-is-quiet-when-bd-cannot-answer ()
  "A panel that cannot read must not take the fleet view down with it.

`bd' may be absent, unconfigured or mid-write; the agent list is what the
navigator actually steers by, and it has to keep refreshing regardless."
  (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 127)))
    (should (null (cerebro--bd-json "/repo" "list" "--json"))))
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) (insert "this is not json") 0)))
    (should (null (cerebro--bd-json "/repo" "list" "--json")))))

(ert-deftest cerebro-test/layout-puts-the-panel-under-the-list ()
  (let ((fleet (generate-new-buffer " *cerebro-test-fleet*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cerebro--repo-root) (lambda () default-directory))
                  ((symbol-function 'cerebro--gather-beads) (lambda (_root) (list nil nil nil nil nil nil))))
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
        (with-current-buffer cerebro-beads-buffer-name
          (when (timerp cerebro--beads-timer) (cancel-timer cerebro--beads-timer)))
        (kill-buffer cerebro-beads-buffer-name))
      (kill-buffer fleet))))

(ert-deftest cerebro-test/beads-tick-stops-itself-when-the-panel-is-gone ()
  "Killing the panel is the ordinary way to stop it refreshing.

The timer used to be cancelled through a buffer-local variable, which dies
with the buffer holding it - so the tick would have gone on shelling out to
bd every thirty seconds for a buffer nobody could see."
  (let ((dead (generate-new-buffer " *cerebro-test-dead*"))
        (cancelled nil))
    (kill-buffer dead)
    (cl-letf (((symbol-function 'cancel-function-timers)
               (lambda (f) (setq cancelled f))))
      (cerebro--beads-tick dead)
      (should (eq cancelled #'cerebro--beads-tick)))))

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
            ((symbol-function 'cerebro--gather-beads) (lambda (_root) (list nil nil nil nil nil nil))))
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
                    ((symbol-function 'vterm)
                     (lambda (name)
                       (let ((buffer (get-buffer-create name)))
                         ;; vterm owns TAB in its major-mode map; stand in for that.
                         (with-current-buffer buffer
                           (use-local-map (let ((m (make-sparse-keymap)))
                                            (define-key m (kbd "TAB") #'ignore)
                                            m)))
                         (cerebro-test--spawn-like-vterm buffer)))))
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
                            nil nil nil))))
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
  "Point starts on a bead rather than on the header above it."
  (cerebro-test--with-panel buffer
    (should (equal (cerebro--bead-at-point) "ah-c1"))
    (should hl-line-mode)))

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
                       nil nil nil nil))))
      (cerebro--beads-render buffer)
      (should (equal (cerebro--bead-at-point) "ah-p1")))))

(ert-deftest cerebro-test/a-vanished-bead-does-not-strand-the-mark ()
  "Merged and closed while selected: fall back to the first row, not to nowhere."
  (cerebro-test--with-panel buffer
    (should (equal (cerebro--bead-at-point) "ah-c1"))
    (cl-letf (((symbol-function 'cerebro--gather-beads)
               (lambda (_root)
                 (list nil nil (list (cerebro-test--bead "ah-u1" 1 "left")) nil nil nil))))
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
               (list nil nil (list (cerebro-test--bead "ah-u1" 1 "first real bead"))
                     nil nil nil))))
    (let ((buffer (get-buffer-create "*cerebro-test-window-point*"))
          (elsewhere (generate-new-buffer " *cerebro-test-elsewhere*")))
      (unwind-protect
          (save-window-excursion
            (with-current-buffer buffer (cerebro-beads-mode))
            (delete-other-windows)
            (set-window-buffer (selected-window) elsewhere)
            (let ((window (split-window (selected-window) nil 'below)))
              (set-window-buffer window buffer)
              ;; Rendered from the other window, exactly as the timer does.
              (cerebro--beads-render buffer)
              (with-current-buffer buffer
                (save-excursion
                  (goto-char (window-point window))
                  (should (equal (cerebro--bead-at-point) "ah-u1"))))))
        (kill-buffer buffer)
        (kill-buffer elsewhere)))))

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
  "Claimed, planned, unplanned, merged, verified, other - the way work moves."
  (let* ((text (string-join (cerebro--bead-panel nil nil nil nil nil nil 62 8) "\n"))
         (at (lambda (s) (string-match (regexp-quote s) text))))
    (should (< (funcall at "Claimed") (funcall at "Planned, unclaimed")))
    (should (< (funcall at "Planned, unclaimed") (funcall at "Unplanned")))
    (should (< (funcall at "Unplanned") (funcall at "Merged, unverified")))
    (should (< (funcall at "Merged, unverified") (funcall at "Verified")))
    (should (< (funcall at "Verified") (funcall at "Other")))))

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

(ert-deftest cerebro-test/every-bead-lands-in-exactly-one-section ()
  "The property that matters: nothing is invisible.

bd has five statuses - open, in_progress, blocked, deferred, closed - and
the panel used to ask about three of them, so a blocked or deferred bead
existed nowhere. Epics were excluded outright. Partitioning one list rather
than running five queries makes coverage structural: a bead the rules do not
recognise, including a status from a future bd, falls into Other instead of
falling out."
  (let* ((buckets (cerebro--partition-beads cerebro-test--every-shape))
         (all (apply #'append buckets))
         (ids (mapcar (lambda (b) (alist-get 'id b)) all)))
    (should (= (length ids) (length cerebro-test--every-shape)))   ; none lost
    (should (= (length ids) (length (delete-dups (copy-sequence ids)))))  ; none twice
    (should (equal (sort (copy-sequence ids) #'string<)
                    (sort (mapcar (lambda (b) (alist-get 'id b)) cerebro-test--every-shape)
                          #'string<)))))

(ert-deftest cerebro-test/each-shape-lands-where-it-belongs ()
  (let* ((buckets (cerebro--partition-beads cerebro-test--every-shape))
         (ids (lambda (n) (mapcar (lambda (b) (alist-get 'id b)) (nth n buckets)))))
    (should (equal (funcall ids 0) '("in-progress")))
    (should (equal (funcall ids 1) '("open-planned")))
    (should (equal (funcall ids 2) '("open-loose")))
    ;; Merged is what still wants verifying: bare, or failed and rebuilt.
    (should (equal (sort (funcall ids 3) #'string<) '("closed-bare" "closed-failed")))
    ;; Verified is passed AND not-needed - nothing further to do about either.
    (should (equal (sort (funcall ids 4) #'string<)
                    '("closed-not-needed" "closed-passed")))
    ;; Everything the fleet cannot pick up, and anything unrecognised.
    (should (equal (sort (funcall ids 5) #'string<)
                    '("blocked" "deferred" "epic" "event" "from-the-future")))))

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

(ert-deftest cerebro-test/other-is-the-last-section ()
  (let* ((text (string-join (cerebro--bead-panel nil nil nil nil nil nil 62 8) "\n"))
         (at (lambda (s) (string-match (regexp-quote s) text))))
    (should (< (funcall at "Verified") (funcall at "Other")))))

(provide 'cerebro-test)
;;; cerebro-test.el ends here
