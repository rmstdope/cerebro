;;; cerebro.el --- List the Cerebro agent fleet -*- lexical-binding: t; -*-

;; Emacs 28+ (json-parse-string, iso8601-parse).  No external dependencies.

;;; Commentary:

;; `M-x cerebro' opens a buffer listing every agent the fleet can have -
;; Xavier, Cerebro, Moira, Psylocke and the fourteen implementers - each with
;; a state glyph, role, state, and (for a working implementer) the bead it is
;; on and for how long.  It refreshes itself every 5 seconds.
;;
;; This is the list half of the fleet view (ah-vcf.2).  The live detail
;; window, and starting/killing agents, are ah-vcf.3 - RET, s and k are
;; unbound here on purpose.
;;
;; Data sources:
;;   - an implementer's status file, `.claude/implementers/<name>.state.json',
;;     written by the implementer itself at every state transition (see
;;     ah-vcf.1): { state: "idle"|"working", bead, since, pid }.
;;   - the launcher's `--roster', the fourteen implementer names.
;;   - the interactive four (Xavier, Cerebro, Moira, Psylocke) have no such
;;     file; their liveness comes from scanning system processes for the
;;     `--name <Name>' argument their launchers pass.

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
    ("Moira" . "feedback")
    ("Psylocke" . "verifier"))
  "The four interactive agents, mirroring their launchers.")

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

(defface cerebro-idle
  '((default :weight normal)
    ;; Yellow that survives its background: pure yellow disappears on a light
    ;; one, so that case gets the darker goldenrod.
    (((class color) (background dark))  :foreground "gold")
    (((class color) (background light)) :foreground "goldenrod")
    (t :inherit warning))
  "The idle glyph: a filled dot, yellow, beside the green one for working.

Not the stock `warning' face, which Emacs defines as `:foreground
\"DarkOrange\" :weight bold' on any colour display.  That was two wrongs at
once here - orange where yellow was asked for, and bold, which this view
reserves for an agent waiting on an answer.  Customize this one face if gold
does not read against your theme."
  :group 'cerebro)

(defun cerebro--glyph (state)
  "The single-character glyph for STATE, propertized."
  (cond
   ((memq state '(working up)) (propertize "●" 'face 'success))   ; ●
   ;; Waiting on the navigator: the one state that is asking for something.
   ((eq state 'asking) (propertize "?" 'face 'warning))           ; ?
   ((eq state 'done) (propertize "◍" 'face 'success))             ; ◍
   ;; Yellow, not grey: an idle agent has a session up and no bead, which is
   ;; something the navigator may want to act on. Dead is the grey one - there
   ;; is nobody there at all - and the two must not read alike.
   ;;
   ;; A filled dot, and the same one `working' uses. It was U+25CC DOTTED
   ;; CIRCLE, which is the same picture as dead's U+25CB WHITE CIRCLE at
   ;; terminal sizes - so the yellow was applied and simply lost the argument
   ;; with the shape. Only colour separates idle from working now, which the
   ;; State column beside it spells out in words anyway.
   ((eq state 'idle) (propertize "●" 'face 'cerebro-idle))        ; ●
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

(defun cerebro--wants-attention-p (state)
  "Whether STATE is one the navigator has to do something about."
  (eq state 'asking))

(defun cerebro--emphasize (text emphasize)
  "TEXT in bold when EMPHASIZE, otherwise TEXT unchanged."
  (if emphasize (propertize text 'face 'bold) text))

(defun cerebro--entry (agent now)
  "AGENT as a `tabulated-list-entries' element, evaluated at NOW."
  (let* ((state (cerebro-agent-state agent))
         (external (cerebro-agent-external agent))
         ;; A glyph is one character in the corner of the eye, and there are
         ;; eighteen rows. Bolding the name, role and state makes the row
         ;; itself the signal - so bold has to stay rare enough to mean it.
         (attention (cerebro--wants-attention-p state))
         (agent-col (format "%s %s" (cerebro--glyph state)
                            (cerebro--emphasize (cerebro-agent-name agent) attention)))
         (role-col (cerebro--emphasize (cerebro-agent-role agent) attention))
         (state-col (cerebro--emphasize (symbol-name state) attention))
         (bead-col (cond (external "(external)")
                          ((cerebro-agent-bead agent))
                          (t "")))
         (for-col (if external "" (cerebro--elapsed (cerebro-agent-since agent) now))))
    (list (cerebro-agent-name agent)
          (vector agent-col role-col state-col bead-col for-col))))

;;; The bead panel

(defcustom cerebro-beads-per-section 8
  "How many beads each section of the panel shows before it says \"+N more\".

The panel sits under an eighteen-row agent list in one window, and an
unplanned backlog is unbounded - without a cap the first two sections, which
are the ones worth reading, get pushed off the bottom by the third."
  :type 'integer
  :group 'cerebro)

(defun cerebro--truncate (text width)
  "TEXT cut to WIDTH, ending in an ellipsis when something was removed."
  (if (<= (length text) width)
      text
    (concat (substring text 0 (max 0 (1- width))) "…")))

(defun cerebro--sort-beads (beads)
  "BEADS by priority, then by id, so P0 reads first and ties do not shuffle.

A stable order matters more than the particular one: the panel redraws on a
timer, and a list that reorders under the navigator's eyes is unreadable."
  (sort (copy-sequence beads)
        (lambda (a b)
          (let ((pa (or (alist-get 'priority a) 9))
                (pb (or (alist-get 'priority b) 9)))
            (if (= pa pb)
                (string< (or (alist-get 'id a) "") (or (alist-get 'id b) ""))
              (< pa pb))))))

(defun cerebro--bead-line (bead width)
  "One line for BEAD, fitted to WIDTH.

Truncated rather than wrapped: a wrapped title would put a second line under
a row and break the column the eye follows down the panel."
  (let* ((id (or (alist-get 'id bead) "?"))
         (priority (alist-get 'priority bead))
         (prefix (format "  %-7s P%s " id (if priority (number-to-string priority) "?")))
         ;; Deliberately no owner column.  `bd's `owner' is the address of
         ;; whoever *filed* the bead and is set on every one of them, so it
         ;; says nothing about who is working on it - and the agent list
         ;; directly above already answers that for every implementer.
         (room (max 8 (- width (length prefix)))))
    (concat prefix (cerebro--truncate (or (alist-get 'title bead) "") room))))

(defun cerebro--bead-section (title beads width max)
  "Lines for one section: TITLE with its count, then up to MAX of BEADS.

The count is on the header rather than implied by the rows, because the rows
are the part that gets capped - and a section whose remainder is hidden
still has to say how much work is really in it."
  (let* ((sorted (cerebro--sort-beads beads))
         (shown (seq-take sorted max))
         (hidden (- (length sorted) (length shown))))
    (append
     (list (propertize (format "%s %d" title (length sorted)) 'face 'bold))
     (if (null sorted)
         (list (propertize "  (none)" 'face 'shadow))
       (mapcar (lambda (bead) (cerebro--bead-line bead width)) shown))
     (when (> hidden 0)
       (list (propertize (format "  +%d more" hidden) 'face 'shadow))))))

(defun cerebro--bead-panel (claimed planned unplanned width max)
  "The whole panel as a list of lines.

In the order the navigator asks the questions: what is being worked on, what
could be picked up next, and what has not been planned yet."
  (append (cerebro--bead-section "Claimed" claimed width max) (list "")
          (cerebro--bead-section "Planned, unclaimed" planned width max) (list "")
          (cerebro--bead-section "Unplanned" unplanned width max)))

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

(defconst cerebro--script-directory ".claude/cerebro/scripts"
  "Where the launchers live, relative to the consumer repository root.

Cerebro is consumed as a submodule mounted at `.claude/cerebro\', and the
launchers moved there with the agents and skills they start.  A bare
\"scripts/run-planner\" would resolve to the consumer\'s own scripts
directory, which no longer has one.")

(defun cerebro--script (name)
  "The path to launcher NAME, relative to the repository root."
  (concat cerebro--script-directory "/" name))

(defconst cerebro--role-launch-commands
  '(("planner" . "run-planner")
    ("orchestrator" . "run-orchestrator")
    ("feedback" . "run-user-feedback")
    ("verifier" . "run-psylocke"))
  "Launcher script name for each interactive role.")

(defun cerebro--launch-command (agent)
  "The command that launches AGENT.

A string for an interactive agent; a (COMMAND NAME) list for an
implementer, since its name is an argument rather than part of the
command name."
  (if (eq (cerebro-agent-kind agent) 'implementer)
      (list (cerebro--script "run-implementer") (cerebro-agent-name agent))
    (let ((script (cdr (assoc (cerebro-agent-role agent) cerebro--role-launch-commands))))
      (unless script
        (error "cerebro: no launch command for role %s" (cerebro-agent-role agent)))
      (cerebro--script script))))

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
  "The fourteen implementer names, via the launcher's --roster."
  (or cerebro--roster-cache
      (setq cerebro--roster-cache
            (cerebro--parse-roster
             (with-temp-buffer
               (call-process (expand-file-name (cerebro--script "run-implementer") repo-root)
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
(defvar-local cerebro--beads-window nil
  "The bead panel window, under the list.")
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
      ;; What was started, not what it will do: whether it claims straight away
      ;; is the launcher's behaviour, and an older `run-implementer'
      ;; still waits on the retired `.go' flag first.  Promising a claim here
      ;; would make that look like a fault in the fleet view.
      (message "%s started - watch its state in the list"
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

;;; Reading the beads

(defconst cerebro-beads-buffer-name "*cerebro-beads*")

(defvar cerebro-beads-refresh-seconds 30
  "How often the bead panel re-runs `bd'.

Slower than the five-second agent tick on purpose. Beads move on human
timescales - a claim, a plan, a merge are minutes apart - and each refresh
is three subprocesses, so a five-second cadence would buy nothing but load.
`g' refreshes on demand.")

(defvar cerebro--beads-timer nil
  "The bead panel's refresh timer, or nil.")
;; Global, not buffer-local: the tick has to be able to cancel itself once the
;; buffer is gone, and a buffer-local value dies with the buffer that held it -
;; leaving a timer firing every thirty seconds with nothing to read it from.

(defun cerebro--bd-json (repo-root &rest args)
  "Run `bd' with ARGS in REPO-ROOT and return the parsed JSON, or nil.

Never signals. `bd' may be absent, unconfigured, or mid-write, and a panel
that cannot answer must degrade to saying nothing rather than taking the
fleet view down with it."
  (condition-case nil
      (with-temp-buffer
        (let ((default-directory (file-name-as-directory repo-root)))
          (when (zerop (apply #'call-process "bd" nil t nil args))
            (json-parse-string (buffer-string)
                               :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil))))
    (error nil)))

(defun cerebro--gather-beads (repo-root)
  "The three lists the panel shows, as (CLAIMED PLANNED UNPLANNED).

Claimed is `--status in_progress' and unclaimed is `--status open'.  The two
are disjoint in `bd', so nothing filters on top of them.  An earlier version
filtered the open lists by the `owner' field and showed an empty panel every
time: `owner' is the address of whoever *filed* the bead and is set on all
of them, claimed or not.

Epics are excluded from the open lists: a split parent has children rather
than work, so it would sit in the panel as something nobody can pick up."
  (list
   (cerebro--bd-json repo-root "list" "--status" "in_progress" "--json")
   (cerebro--bd-json repo-root "list" "--status" "open" "--label" "planned"
                     "--exclude-type" "epic" "--json")
   (cerebro--bd-json repo-root "list" "--status" "open" "--exclude-label" "planned"
                     "--exclude-type" "epic" "--json")))

(defun cerebro--beads-render (buffer)
  "Redraw BUFFER's panel from `bd'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((width (max 30 (window-width (get-buffer-window buffer))))
             (beads (cerebro--gather-beads (cerebro--repo-root)))
             (lines (cerebro--bead-panel (nth 0 beads) (nth 1 beads) (nth 2 beads)
                                          width cerebro-beads-per-section))
             (inhibit-read-only t)
             (point-was (point)))
        (erase-buffer)
        (insert (string-join lines "\n"))
        (goto-char (min point-was (point-max)))))))

(defun cerebro--beads-revert (&rest _)
  "Refresh the panel, for `g' and for the timer."
  (cerebro--beads-render (current-buffer)))

(defun cerebro--beads-tick (buffer)
  "Refresh BUFFER while it lives; called every `cerebro-beads-refresh-seconds'.

Once BUFFER is gone the timer cancels itself by function rather than by the
variable that holds it: killing the panel is the ordinary way to stop it,
and a timer left running would go on shelling out to `bd' for a buffer
nobody can see."
  (if (buffer-live-p buffer)
      (with-demoted-errors "cerebro: %S" (cerebro--beads-render buffer))
    (cancel-function-timers #'cerebro--beads-tick)
    (setq cerebro--beads-timer nil)))

(define-derived-mode cerebro-beads-mode special-mode "Cerebro Beads"
  "What the fleet could be working on: claimed, planned, and unplanned."
  (setq-local revert-buffer-function #'cerebro--beads-revert)
  (setq truncate-lines t))

(defun cerebro--beads-buffer (repo-root)
  "The panel buffer, created and started if it does not exist."
  (let ((buffer (get-buffer-create cerebro-beads-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cerebro-beads-mode)
        (cerebro-beads-mode))
      ;; `bd' is answered relative to the repository, and this buffer is not
      ;; visiting a file, so it would otherwise inherit whatever directory
      ;; the navigator happened to be in.
      (setq default-directory (file-name-as-directory repo-root))
      (unless (timerp cerebro--beads-timer)
        (setq cerebro--beads-timer
              (run-at-time cerebro-beads-refresh-seconds cerebro-beads-refresh-seconds
                           #'cerebro--beads-tick buffer))))
    buffer))

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

(defconst cerebro-list-width 62
  "Columns for the left column of the layout.

The agent table is 14+13+18+10+6 plus padding, so anything narrower cuts the
elapsed-time column off the right edge - it was 45 for a while, and the
column was simply invisible. The bead panel underneath inherits this width
and wants every one of them for its titles.")

(defconst cerebro-list-height 20
  "Lines given to the agent list before the bead panel starts.

Eighteen agents and a header, so the list never scrolls and the panel gets
whatever the frame has left.")

(defun cerebro--setup-layout ()
  "Ensure the list/beads/detail window layout exists for the current buffer."
  (unless (and cerebro--list-window (window-live-p cerebro--list-window))
    (delete-other-windows)
    (setq cerebro--list-window (selected-window))
    (setq cerebro--detail-window
          (split-window cerebro--list-window nil 'right))
    (let ((width (- cerebro-list-width (window-width cerebro--list-window))))
      ;; A narrow frame/terminal can make the width or the split unsatisfiable;
      ;; `window-resize' and `split-window' signal in that case, and the
      ;; layout so far must still stand rather than leaving the buffer
      ;; half-initialized.
      (when (/= width 0)
        (ignore-errors (window-resize cerebro--list-window width t))))
    (setq cerebro--beads-window
          (ignore-errors (split-window cerebro--list-window cerebro-list-height 'below)))
    (when (window-live-p cerebro--beads-window)
      (set-window-buffer cerebro--beads-window
                         (cerebro--beads-buffer (cerebro--repo-root)))
      (cerebro--beads-render (get-buffer cerebro-beads-buffer-name)))))

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

(defun cerebro-other-window ()
  "Move to the next window (`TAB'), exactly as `C-x o' does.

With the fleet layout that is the detail window, and pressing it again comes
back - one key to cycle rather than a key out and a chord back."
  (interactive)
  (other-window 1))

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
    ;; Both spellings: a terminal sends TAB, a GUI frame sends <tab>, and
    ;; binding only one leaves the key dead in the other.
    (define-key map (kbd "TAB") #'cerebro-other-window)
    (define-key map (kbd "<tab>") #'cerebro-other-window)
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
