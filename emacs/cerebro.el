;;; cerebro.el --- List the Cerebro agent fleet -*- lexical-binding: t; -*-

;; Emacs 28+ (json-parse-string, iso8601-parse).  No external dependencies.

;;; Commentary:

;; `M-x cerebro' opens a buffer listing every agent the fleet can have -
;; Xavier, Cerebro, Moira and the fifteen implementers - each with a state
;; glyph, role, state, and (for a working implementer) the bead it is on and
;; for how long.  It refreshes itself every 5 seconds.
;;
;; This is the list half of the fleet view (ah-vcf.2).  The live detail
;; window, and starting/killing agents, are ah-vcf.3 - RET, s and k are
;; unbound here on purpose.
;;
;; Data sources:
;;   - an implementer's status file, `.claude/implementers/<name>.state.json',
;;     written by `scripts/run-implementer' at every state transition (see
;;     ah-vcf.1): { state: "idle"|"working", bead, since, pid }.
;;   - `scripts/run-implementer --roster', the fifteen implementer names.
;;   - the interactive three (Xavier, Cerebro, Moira) have no such file; their
;;     liveness comes from scanning system processes for the `--name <Name>'
;;     argument their launchers pass.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'iso8601)
(require 'tabulated-list)
(require 'seq)
(require 'subr-x)

(defgroup cerebro nil
  "The fleet view: what every agent is doing, and starting or stopping them."
  :group 'tools
  :prefix "cerebro-")

;;; The interactive roster

(defconst cerebro-interactive-agents
  '(("Xavier" . "planner")
    ("Cerebro" . "orchestrator")
    ("Moira" . "feedback"))
  "The three interactive agents, mirroring their launchers.")

;;; The pure core

(cl-defstruct cerebro-agent
  "One row of the fleet list."
  name role kind                       ; kind: 'interactive | 'implementer
  state                                ; 'up | 'working | 'idle | 'dead
  bead since external)

(defun cerebro--name-in-args-p (name args)
  "Non-nil if some string in ARGS names NAME via a whole-word \"--name NAME\"."
  (let ((needle (concat "--name[ \t]+" (regexp-quote name) "\\_>")))
    (cl-some (lambda (a) (and (stringp a) (string-match-p needle a))) args)))

(defun cerebro--derive-interactive (entry args owned)
  "Derive one interactive agent's row from (NAME . ROLE) ENTRY.

ARGS is the system process args list; OWNED the names Emacs itself started."
  (let ((name (car entry))
        (role (cdr entry)))
    (cond
     ((member name owned)
      (make-cerebro-agent :name name :role role :kind 'interactive
                                  :state 'up :bead nil :since nil :external nil))
     ((cerebro--name-in-args-p name args)
      (make-cerebro-agent :name name :role role :kind 'interactive
                                  :state 'up :bead nil :since nil :external t))
     (t
      (make-cerebro-agent :name name :role role :kind 'interactive
                                  :state 'dead :bead nil :since nil :external nil)))))

(defun cerebro--derive-implementer (name states pid-alive-p owned)
  "Derive one implementer's row for NAME.

STATES is an alist of (NAME . parsed-state-json-or-nil); PID-ALIVE-P a
predicate on a pid; OWNED the names Emacs itself started."
  (let* ((parsed (cdr (assoc name states)))
         (pid (and parsed (alist-get 'pid parsed)))
         (alive (and pid (funcall pid-alive-p pid)))
         (owned-p (and (member name owned) t)))
    (cond
     ;; A session Emacs started is alive whatever the file says: `cerebro--owned'
     ;; already requires a live process, and the file lags it twice over - a
     ;; fresh session has not written one yet, and after a restart the file on
     ;; disk is still the *previous* session's, with a dead pid and a finished
     ;; bead. Reporting dead here is not cosmetic: `cerebro--start-action' tests
     ;; aliveness before ownership, so `s' would start a second session for the
     ;; same name, and vterm would call it `*fleet: <name>*<2>' - a name
     ;; `cerebro--owned-buffer-agent-name' does not match, invisible for ever.
     ((and (not alive) owned-p)
      (make-cerebro-agent :name name :role "implementer" :kind 'implementer
                                  :state 'idle :bead nil :since nil :external nil))
     ((not alive)
      (make-cerebro-agent :name name :role "implementer" :kind 'implementer
                                  :state 'dead :bead nil :since nil :external nil))
     (t
      (let* ((raw-state (alist-get 'state parsed))
             (state (cond ((equal raw-state "working") 'working)
                          ;; The bead is merged and closed and the session has
                          ;; nothing left to do; `cerebro--supervise' replaces
                          ;; it, because an interactive session cannot end
                          ;; itself the way a --print one did.
                          ((equal raw-state "done") 'done)
                          ;; Blocked on a question only the navigator can
                          ;; answer, with a bead still in flight.
                          ((equal raw-state "asking") 'asking)
                          (t 'idle)))
             (bead (alist-get 'bead parsed))
             (since (alist-get 'since parsed))
             (external (not owned-p)))
        (make-cerebro-agent :name name :role "implementer" :kind 'implementer
                                    :state state :bead bead :since since
                                    :external external))))))

(defun cerebro--derive (roster interactive-agents states pid-alive-p args owned)
  "Return the fleet as a list of `cerebro-agent', interactive first.

ROSTER is the implementer name list, in the order they should be shown.
INTERACTIVE-AGENTS is an alist of (NAME . ROLE), normally
`cerebro-interactive-agents'.  STATES is an alist of (NAME .
parsed-state-json-or-nil).  PID-ALIVE-P is a predicate on a pid.  ARGS is the
system process args list.  OWNED is the set of agent names whose sessions
Emacs itself started."
  (append
   (mapcar (lambda (entry) (cerebro--derive-interactive entry args owned))
           interactive-agents)
   (mapcar (lambda (name) (cerebro--derive-implementer name states pid-alive-p owned))
           roster)))

;;; Formatting

(defun cerebro--glyph (state)
  "The single-character glyph for STATE, propertized."
  (cond
   ((memq state '(working up)) (propertize "●" 'face 'success))   ; ●
   ;; Waiting on the navigator: the one state that is asking for something.
   ((eq state 'asking) (propertize "?" 'face 'warning))           ; ?
   ((eq state 'done) (propertize "◍" 'face 'success))             ; ◍
   ((eq state 'idle) (propertize "◌" 'face 'shadow))              ; ◌
   (t (propertize "○" 'face 'shadow))))                           ; ○

(defun cerebro--seconds-since (since now)
  "Seconds from SINCE (an ISO-8601 string, or nil) to NOW, or nil.

Nil rather than zero when SINCE is absent or unparseable, so a caller can
tell \"no time has passed\" from \"the file did not say\" - a torn state
file must not read as a deadline that has expired."
  (when since
    (condition-case nil
        (max 0 (floor (float-time
                       (time-subtract now (encode-time (iso8601-parse since))))))
      (error nil))))

(defun cerebro--elapsed (since now)
  "How long ago SINCE (an ISO-8601 string, or nil) was, relative to NOW.

Renders as \"12m\", \"1h03\" or \"2d\".  Nil-safe: a nil SINCE, or one that
fails to parse, renders as the empty string."
  (let ((diff (cerebro--seconds-since since now)))
    (cond
     ((null diff) "")
     ((< diff 3600) (format "%dm" (/ diff 60)))
     ((< diff 86400) (format "%dh%02d" (/ diff 3600) (/ (mod diff 3600) 60)))
     (t (format "%dd" (/ diff 86400))))))

(defun cerebro--entry (agent now)
  "AGENT as a `tabulated-list-entries' element, evaluated at NOW."
  (let* ((state (cerebro-agent-state agent))
         (external (cerebro-agent-external agent))
         (agent-col (format "%s %s" (cerebro--glyph state) (cerebro-agent-name agent)))
         (role-col (cerebro-agent-role agent))
         (state-col (symbol-name state))
         (bead-col (cond (external "(external)")
                          ((cerebro-agent-bead agent))
                          (t "")))
         (for-col (if external "" (cerebro--elapsed (cerebro-agent-since agent) now))))
    (list (cerebro-agent-name agent)
          (vector agent-col role-col state-col bead-col for-col))))

;;; Supervising the implementers

(defcustom cerebro-answer-timeout 900
  "Seconds an implementer may wait on the navigator before it is told to give up.

An interactive implementer may put a question to the navigator, but it may
not wait for ever: a fleet blocked on unanswered questions drains no queue,
and the navigator is often away.  Past this, `cerebro--supervise' tells it
to hand the bead to the `human' queue and finish - a complete run rather
than an abandoned one."
  :type 'integer
  :group 'cerebro)

(defun cerebro--supervise-action (agent stop-flag-p now)
  "What the fleet poll should do about AGENT at NOW, or nil for nothing.

STOP-FLAG-P is whether `.claude/implementers/<name>.stop' exists.  The
answers are:

`restart' - AGENT finished its bead.  An interactive session cannot end
            itself the way a `--print' one did, so Emacs ends it and starts
            a fresh one, which is what keeps a session to one bead and its
            context free of every bead before it.
`retire'  - AGENT finished its bead and a stop flag says do not start
            another.  Note the flag is only ever read here, with the bead
            already merged and closed: taking an implementer down in flight
            strands a claim, a worktree and an open PR, so a stop means
            *finish*, not *stop now*.
`nudge'   - AGENT has waited past `cerebro-answer-timeout' for an answer.

Only an implementer Emacs itself started is supervised.  One running in
somebody's own terminal is theirs to end, and a dead one stays dead -
restarting it would fight the navigator's own `k'."
  (when (and (eq (cerebro-agent-kind agent) 'implementer)
             (not (cerebro-agent-external agent)))
    (pcase (cerebro-agent-state agent)
      ('done (if stop-flag-p 'retire 'restart))
      ('asking
       (let ((waited (cerebro--seconds-since (cerebro-agent-since agent) now)))
         ;; A stop flag makes no difference: the bead is still in flight, so
         ;; the question still needs an answer or a hand-back.
         (and waited (>= waited cerebro-answer-timeout) 'nudge)))
      (_ nil))))

;;; ah-vcf.3: the pure start/kill/launch decisions

(defconst cerebro--role-launch-commands
  '(("planner" . "scripts/run-planner")
    ("orchestrator" . "scripts/run-orchestrator")
    ("feedback" . "scripts/run-user-feedback"))
  "Launch command for each interactive role.")

(defun cerebro--launch-command (agent)
  "The command that launches AGENT.

A string for an interactive agent; a (COMMAND NAME) list for an
implementer, since its name is an argument rather than part of the
command name."
  (if (eq (cerebro-agent-kind agent) 'implementer)
      (list "scripts/run-implementer" (cerebro-agent-name agent))
    (or (cdr (assoc (cerebro-agent-role agent) cerebro--role-launch-commands))
        (error "cerebro: no launch command for role %s"
               (cerebro-agent-role agent)))))

(defun cerebro--session-buffer-name (agent)
  "The vterm buffer name that holds AGENT's live session."
  (format "*fleet: %s*" (cerebro-agent-name agent)))

(defun cerebro--alive-p (agent)
  "Non-nil if AGENT's state means a session is up (interactive or implementer)."
  (memq (cerebro-agent-state agent) '(up working idle)))

(defun cerebro--start-action (agent owned)
  "What `s' should do for AGENT, given OWNED session names.

One of `launch' (start a dead agent), `already-up' (an owned session is
already running) or `external' (a live session exists outside Emacs -
refuse rather than launch a second one)."
  (cond
   ((not (cerebro--alive-p agent)) 'launch)
   ((member (cerebro-agent-name agent) owned) 'already-up)
   (t 'external)))

(defun cerebro--kill-action (agent owned)
  "What `k' should do for AGENT, given OWNED session names.

One of `kill' (plain confirm), `kill-working' (an implementer mid-bead -
harder confirm), `external' (refuse - not ours to stop) or `dead'
(refuse - nothing to kill)."
  (cond
   ((not (cerebro--alive-p agent)) 'dead)
   ((not (member (cerebro-agent-name agent) owned)) 'external)
   ((and (eq (cerebro-agent-kind agent) 'implementer)
         (eq (cerebro-agent-state agent) 'working))
    'kill-working)
   (t 'kill)))

(defun cerebro--placeholder (agent)
  "The detail-window text for AGENT when it has no live view."
  (let ((name (cerebro-agent-name agent)))
    (if (cerebro-agent-external agent)
        (format "%s is running outside Emacs - no live view. Use the terminal that started it."
                name)
      (format "%s is not running. Press s to start it." name))))

;;; Impure readers - each trivially small so everything above stays pure

(defun cerebro--repo-root ()
  "The repository root above `default-directory', or an error."
  (or (locate-dominating-file default-directory ".claude/implementers")
      (error "cerebro: no .claude/implementers found above %s" default-directory)))

(defun cerebro--parse-roster (output)
  "Turn OUTPUT (one implementer name per line) into a list of names."
  (seq-filter (lambda (s) (not (string-empty-p s)))
              (mapcar #'string-trim (split-string output "\n"))))

(defvar-local cerebro--roster-cache nil
  "The roster, once read; buffer-local so a revert does not re-shell out.")

(defun cerebro--roster (repo-root)
  "The fifteen implementer names, via \"scripts/run-implementer --roster\"."
  (or cerebro--roster-cache
      (setq cerebro--roster-cache
            (cerebro--parse-roster
             (with-temp-buffer
               (call-process (expand-file-name "scripts/run-implementer" repo-root)
                              nil t nil "--roster")
               (buffer-string))))))

(defun cerebro--state-file-path (repo-root name)
  "Where NAME's status file lives, mirroring `statePath' in runImplementer.ts."
  (expand-file-name (format ".claude/implementers/%s.state.json" name) repo-root))

(defun cerebro--read-state-file (path)
  "The parsed contents of PATH, or nil if it is absent, unreadable or torn."
  (when (file-exists-p path)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents path)
          (json-parse-string (buffer-string) :object-type 'alist :array-type 'list
                              :null-object nil :false-object nil))
      (error nil))))

(defun cerebro--gather-states (repo-root roster)
  "The (NAME . parsed-state-json-or-nil) alist for every name in ROSTER."
  (mapcar (lambda (name)
            (cons name (cerebro--read-state-file
                        (cerebro--state-file-path repo-root name))))
          roster))

(defun cerebro--pid-alive-p (pid)
  "Non-nil if a process with PID currently exists."
  (and pid (process-attributes pid) t))

(defun cerebro--system-args ()
  "The command-line args string of every system process, as a list."
  (delq nil
        (mapcar (lambda (pid) (alist-get 'args (process-attributes pid)))
                (list-system-processes))))

(defun cerebro--owned-buffer-agent-name (buffer-name)
  "The agent name BUFFER-NAME names as a live session, or nil.

Matches only the plain session-buffer scheme (`--session-buffer-name'),
never the placeholder scheme (`*fleet: NAME (no view)*') - a placeholder
buffer names an agent with no live view, the opposite of owned."
  (and (string-match "\\`\\*fleet: \\([^()]+\\)\\*\\'" buffer-name)
       (match-string 1 buffer-name)))

(defun cerebro--owned ()
  "Agent names whose sessions this Emacs itself started.

Derived fresh from live buffers matching the session-buffer naming
scheme with a live process - no registry to go stale."
  (delq nil
        (mapcar (lambda (buffer)
                  (and (get-buffer-process buffer)
                       (cerebro--owned-buffer-agent-name (buffer-name buffer))))
                (buffer-list))))

;;; The detail window (ah-vcf.3)

(defvar-local cerebro--list-window nil
  "The list window of this fleet buffer's layout.")
(defvar-local cerebro--detail-window nil
  "The detail window of this fleet buffer's layout.")
(defvar-local cerebro--agents nil
  "The agents shown by the last revert, for lookup by name.")
(defvar-local cerebro--last-shown nil
  "The name of the agent last shown in the detail window.")

(defun cerebro--placeholder-buffer-name (agent)
  "The read-only placeholder buffer name for AGENT."
  (format "*fleet: %s (no view)*" (cerebro-agent-name agent)))

(defun cerebro--placeholder-buffer (agent)
  "A read-only buffer holding AGENT's placeholder text, reused across shows."
  (let ((buffer (get-buffer-create (cerebro--placeholder-buffer-name agent))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (cerebro--placeholder agent)))
      (setq buffer-read-only t))
    buffer))

(defun cerebro--show-detail (agent)
  "Put AGENT's live session, or a placeholder, in the detail window.

Returns the buffer chosen.  AGENT's session buffer is used only when
its name is in `cerebro--owned' - an owned buffer that has not
actually been created yet (should not happen; `--owned' derives from
live buffers) falls back to the placeholder rather than erroring."
  (let ((buffer (if (member (cerebro-agent-name agent) (cerebro--owned))
                     (or (get-buffer (cerebro--session-buffer-name agent))
                         (cerebro--placeholder-buffer agent))
                   (cerebro--placeholder-buffer agent))))
    (when (and cerebro--detail-window (window-live-p cerebro--detail-window))
      (set-window-buffer cerebro--detail-window buffer))
    buffer))

;;; Launching and killing (ah-vcf.3)

;; vterm is a soft dependency (see `cerebro--launch'); these keep the
;; byte-compiler quiet about the symbols it only knows about once vterm is
;; actually loaded.
(defvar vterm-shell)
(declare-function vterm "vterm" (&optional buffer-name))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-return "vterm" ())

(defun cerebro--spawn-into-detail (buffer-name spawn)
  "Run SPAWN and put the buffer it makes, named BUFFER-NAME, in the detail window.

SPAWN displays its own buffer - `vterm' uses `pop-to-buffer-same-window',
which would take the *selected* window, and that is the list window when
`s' is pressed there, leaving the navigator unable to see the fleet.
`display-buffer-overriding-action' redirects that; it beats every other
action, including same-window ones and `display-buffer-alist'.

Because it beats everything, it is scoped three ways:

- **To BUFFER-NAME.** `vterm-mode' runs *after* the session is displayed,
  so a `display-warning' from it - or the module-compile log on a first
  run - would otherwise be forced into the detail window on top of the
  session it just placed.  Anything else returns nil and takes its normal
  course.
- **Never onto the selected window.** If the detail window is gone, or
  refuses the buffer, the fallback pops up a window rather than falling
  through to the selected one, which is the list.
- **Errors do not escape.** `set-window-buffer' signals on a window
  dedicated to another buffer, and that signal would escape
  `vterm--internal' between its `generate-new-buffer' and its
  `vterm-mode', stranding a live process-less session buffer.  The next
  start then makes `*fleet: <name>*<2>', which
  `cerebro--owned-buffer-agent-name' does not match, so that agent would
  be invisible to the fleet list for ever.

`save-selected-window' keeps point in the list, so starting several agents
in a row does not leave the navigator typing into the last one's session.
It restores the current buffer too, which `cerebro-start' relies on: its
`revert-buffer' must refresh the fleet list, not the new session."
  (let* ((window cerebro--detail-window)
         ;; A (FUNCTIONS . ALIST) action; the alist is empty.
         (display-buffer-overriding-action
          (list (lambda (buffer alist)
                  (when (equal (buffer-name buffer) buffer-name)
                    (or (and (window-live-p window)
                             (condition-case nil
                                 (progn
                                   (display-buffer-record-window 'reuse window buffer)
                                   (set-window-buffer window buffer)
                                   window)
                               (error nil)))
                        (display-buffer-pop-up-window buffer alist)))))))
    (save-selected-window (funcall spawn))))

(defun cerebro--launch (agent)
  "Create AGENT's vterm session and return its buffer.

`vterm-shell' is let-bound rather than set globally, so the navigator's
ordinary vterm shells are unaffected.  The session goes into the detail
window via `cerebro--spawn-into-detail'.

The let-bound `default-directory' reaches the session by inheritance rather
than by anything staying selected: `vterm--internal' calls
`generate-new-buffer' while the fleet buffer is still current, and the new
buffer takes its `default-directory' from there.  Only then does it display
the buffer and run `vterm-mode'."
  (unless (require 'vterm nil t)
    (user-error "cerebro needs vterm for live sessions - install emacs-libvterm"))
  (let* ((default-directory (cerebro--repo-root))
         (cmd (cerebro--launch-command agent))
         (vterm-shell (if (stringp cmd) cmd (mapconcat #'shell-quote-argument cmd " ")))
         (session-name (cerebro--session-buffer-name agent))
         (buffer (cerebro--spawn-into-detail
                  session-name (lambda () (vterm session-name)))))
    ;; The navigator's quit guard: confirm before Emacs or a buffer kill
    ;; takes a live agent down.  vterm's own kill behaviour is tuned for
    ;; disposable shells and does not set this on its own.
    (let ((proc (get-buffer-process buffer)))
      (when proc (set-process-query-on-exit-flag proc t)))
    (when (eq (cerebro-agent-kind agent) 'implementer)
      (message "%s started - it will claim the next planned bead"
               (cerebro-agent-name agent)))
    buffer))

;;; Acting on the supervision decisions

(defvar-local cerebro--nudged nil
  "Names already told to give up on the question they are asking.

The poll runs every five seconds; without this the nudge would be typed
into the session on every tick, burying the agent's own output and
resetting what it was told.  A name leaves this set as soon as it is no
longer asking, so its next question is nudgeable again.")

(defun cerebro--stop-flag-path (repo-root name)
  "Where NAME's stop flag lives, as `orchestrator.md' documents it."
  (expand-file-name (format ".claude/implementers/%s.stop" name) repo-root))

(defun cerebro--stop-flag-p (repo-root name)
  "Whether a stop flag is set for NAME."
  (file-exists-p (cerebro--stop-flag-path repo-root name)))

(defconst cerebro--nudge-message
  (concat "[cerebro] Nobody answered within the timeout. Do not keep waiting: "
          "put the question and everything you have found into the bead, "
          "label it `human', release your claim, and finish the run - "
          "the hand-back in the implement-bead skill.")
  "What an implementer is told when its question goes unanswered.

It names the hand-back rather than describing it, so the skill stays the
one place that says how a bead is handed back.")

(defun cerebro--nudge (agent)
  "Type `cerebro--nudge-message' into AGENT's session."
  (let ((buffer (get-buffer (cerebro--session-buffer-name agent))))
    (when (and buffer (fboundp 'vterm-send-string))
      (with-current-buffer buffer
        (vterm-send-string cerebro--nudge-message)
        (vterm-send-return)))))

(defun cerebro--end-session (agent)
  "Kill AGENT's session buffer, without asking and without refreshing.

The query-on-exit flag guards an *accidental* kill; this one is the poll
acting on a bead the agent itself reported finished."
  (let ((buffer (get-buffer (cerebro--session-buffer-name agent))))
    (when buffer
      (let ((proc (get-buffer-process buffer)))
        (when proc (set-process-query-on-exit-flag proc nil)))
      (kill-buffer buffer))))

(defun cerebro--supervise (agents repo-root now)
  "Act on what `cerebro--supervise-action' says about each of AGENTS.

Errors are demoted: this runs from a timer, and one agent whose session
cannot be replaced must not stop the fleet view refreshing or take the
other agents down with it."
  (dolist (agent agents)
    (let ((name (cerebro-agent-name agent)))
      (unless (eq (cerebro-agent-state agent) 'asking)
        (setq cerebro--nudged (delete name cerebro--nudged)))
      (with-demoted-errors "cerebro: %S"
        (pcase (cerebro--supervise-action agent (cerebro--stop-flag-p repo-root name) now)
          ;; Kill before launching: two sessions for one name would make
          ;; vterm call the second `*fleet: <name>*<2>', which
          ;; `cerebro--owned-buffer-agent-name' does not match, leaving it
          ;; invisible to the list for ever.
          ('restart (cerebro--end-session agent)
                    (cerebro--launch agent))
          ('retire (cerebro--end-session agent))
          ('nudge (unless (member name cerebro--nudged)
                    (push name cerebro--nudged)
                    (cerebro--nudge agent))))))))

;;; The buffer

(defconst cerebro-buffer-name "*cerebro*")

(defvar cerebro--timer nil
  "The buffer-local auto-refresh timer, or nil.")
(make-variable-buffer-local 'cerebro--timer)

(defun cerebro--find-agent (name)
  "The `cerebro-agent' called NAME among `cerebro--agents'."
  (cl-find name cerebro--agents :key #'cerebro-agent-name :test #'equal))

(defun cerebro--agent-at-point ()
  "The agent on the current list line, or nil."
  (let ((id (tabulated-list-get-id)))
    (and id (cerebro--find-agent id))))

(defun cerebro--revert (&rest _)
  "Recompute `tabulated-list-entries' for the fleet buffer."
  (let* ((repo-root (cerebro--repo-root))
         (roster (cerebro--roster repo-root))
         (states (cerebro--gather-states repo-root roster))
         (args (cerebro--system-args))
         (owned (cerebro--owned))
         (now (current-time))
         (agents (cerebro--derive roster cerebro-interactive-agents states
                                          #'cerebro--pid-alive-p args owned)))
    (setq cerebro--agents agents)
    (setq tabulated-list-entries (mapcar (lambda (a) (cerebro--entry a now)) agents))))

(defun cerebro--cancel-timer ()
  "Stop this buffer's auto-refresh timer, if any."
  (when (timerp cerebro--timer)
    (cancel-timer cerebro--timer)
    (setq cerebro--timer nil)))

(defun cerebro--tick (buffer)
  "Refresh BUFFER if it is still alive; called every 5s while it lives.

The refresh comes first: `cerebro--supervise' acts on what the revert just
derived, so it never decides from a state file read five seconds ago."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (revert-buffer)
      (cerebro--supervise cerebro--agents (cerebro--repo-root) (current-time)))))

(defun cerebro--follow ()
  "Show the selected agent's detail whenever the list selection changes.

Buffer-local on `post-command-hook', so it must stay cheap - compare
ids and return - since it runs after every command in the list buffer."
  (when (derived-mode-p 'cerebro-mode)
    (let ((id (tabulated-list-get-id)))
      (when (and id (not (equal id cerebro--last-shown)))
        (setq cerebro--last-shown id)
        (let ((agent (cerebro--find-agent id)))
          (when agent (cerebro--show-detail agent)))))))

(defun cerebro--setup-layout ()
  "Ensure the list/detail window layout exists for the current buffer."
  (unless (and cerebro--list-window (window-live-p cerebro--list-window))
    (delete-other-windows)
    (setq cerebro--list-window (selected-window))
    (setq cerebro--detail-window
          (split-window cerebro--list-window nil 'right))
    (let ((width (- 45 (window-width cerebro--list-window))))
      ;; A narrow frame/terminal can make 45 columns unsatisfiable;
      ;; `window-resize' signals in that case, and the list/detail split
      ;; above must still stand rather than leaving the buffer
      ;; half-initialized.
      (when (/= width 0)
        (ignore-errors (window-resize cerebro--list-window width t))))))

(defun cerebro-start ()
  "Start the agent at point (`s')."
  (interactive)
  (let ((agent (cerebro--agent-at-point)))
    (when agent
      (pcase (cerebro--start-action agent (cerebro--owned))
        ('launch
         (cerebro--launch agent)
         (revert-buffer)
         (cerebro--show-detail agent))
        ('already-up (message "%s is already up" (cerebro-agent-name agent)))
        ('external (message "%s is running outside Emacs" (cerebro-agent-name agent)))))))

(defun cerebro--kill-session-buffer (agent)
  "Kill AGENT's session buffer if it still exists, then refresh the view.

The buffer can have died between `--kill-action' deciding it was
killable (from a `--owned' snapshot) and this running - a real race,
not a hypothetical one - so a missing buffer is not an error here.

`cerebro-kill' has already confirmed this exact kill via
`y-or-n-p'; the process's query-on-exit flag exists to guard against an
*accidental* buffer/Emacs kill, not this intentional one, so it is
cleared first rather than prompting a second time for the same kill."
  (let ((buffer (get-buffer (cerebro--session-buffer-name agent))))
    (when buffer
      (let ((proc (get-buffer-process buffer)))
        (when proc (set-process-query-on-exit-flag proc nil)))
      (kill-buffer buffer)))
  (revert-buffer)
  (cerebro--show-detail agent))

(defun cerebro-kill ()
  "Kill the agent at point (`k'), confirming first."
  (interactive)
  (let ((agent (cerebro--agent-at-point)))
    (when agent
      (pcase (cerebro--kill-action agent (cerebro--owned))
        ('kill
         (when (y-or-n-p (format "Kill %s? " (cerebro-agent-name agent)))
           (cerebro--kill-session-buffer agent)))
        ('kill-working
         (when (y-or-n-p
                (format (concat "%s is working on %s - killing mid-bead strands a claim, "
                                 "a worktree and an open PR. Kill anyway? ")
                        (cerebro-agent-name agent) (cerebro-agent-bead agent)))
           (cerebro--kill-session-buffer agent)))
        ('external
         (message "%s is running outside Emacs - stop it from its own terminal"
                  (cerebro-agent-name agent)))
        ('dead (message "%s is not running" (cerebro-agent-name agent)))))))

(defun cerebro-focus-detail ()
  "Select the detail window (`RET'), to type to the agent shown there."
  (interactive)
  (when (window-live-p cerebro--detail-window)
    (select-window cerebro--detail-window)))

(defvar cerebro-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    ;; special-mode's map does not bind n/p on its own; tabulated-list-mode
    ;; adds none either, so these are explicit.
    (define-key map "n" #'next-line)
    (define-key map "p" #'previous-line)
    (define-key map (kbd "RET") #'cerebro-focus-detail)
    (define-key map "s" #'cerebro-start)
    (define-key map "k" #'cerebro-kill)
    map)
  "Keymap for `cerebro-mode'.")

(define-derived-mode cerebro-mode tabulated-list-mode "Cerebro"
  "Major mode listing the atlantis-hud agent fleet.

\\{cerebro-mode-map}"
  (setq tabulated-list-format
        [("Agent" 14 nil) ("Role" 13 nil) ("State" 18 nil) ("Bead" 10 nil) ("For" 6 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'cerebro--revert nil t)
  (add-hook 'kill-buffer-hook #'cerebro--cancel-timer nil t)
  (add-hook 'post-command-hook #'cerebro--follow nil t)
  (tabulated-list-init-header))

;;;###autoload
(defun cerebro ()
  "Open (or refresh) the *cerebro* buffer, listing every agent."
  (interactive)
  (let ((buffer (get-buffer-create cerebro-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cerebro-mode)
        (cerebro-mode))
      (cerebro--revert)
      (tabulated-list-print t)
      (cerebro--cancel-timer)
      (setq cerebro--timer
            (run-with-timer 5 5 #'cerebro--tick buffer)))
    ;; `pop-to-buffer' must run before `--setup-layout': layout claims
    ;; `selected-window' as the list window, which is only correct once that
    ;; window is actually showing this buffer.
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (cerebro--setup-layout)
      (setq cerebro--last-shown nil)
      (cerebro--follow))))

(provide 'cerebro)
;;; cerebro.el ends here
