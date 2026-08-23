;;; cerebro.el --- List the Cerebro agent fleet -*- lexical-binding: t; -*-

;; Emacs 28+ (json-parse-string, iso8601-parse).  No external dependencies.

;;; Commentary:

;; `M-x cerebro' opens a buffer listing every agent on `scripts/roster' - the
;; interactive roles and the implementers - each with a state glyph, role,
;; state, and (for a working implementer) the bead it is on and for how
;; long.  It refreshes itself every 5 seconds.
;;
;; This is the list half of the fleet view (ah-vcf.2).  The live detail
;; window, and starting/killing agents, are ah-vcf.3 - RET, s and k are
;; unbound here on purpose.
;;
;; Data sources:
;;   - an agent's status file, `.cerebro/state/<name>.state.json',
;;     written by the agent itself at every state transition (see ah-vcf.1,
;;     ah-u3i and ah-2n3.2): { state: "idle"|"working"|"asking"|"done", phase,
;;     bead, since, phase_since, pid }.  Every implementer writes one; since
;;     ah-2n3.2 the interactive roles do too, `done' excepted - it is an
;;     implementer's state alone.
;;   - `scripts/roster', the fleet: name, role and kind per agent, in
;;     display order.
;;   - liveness for the interactive roles (Xavier, Cerebro, Moira, Psylocke,
;;     Forge) is the state file first, when one exists for a live pid, and
;;     falls back to scanning system processes for the `--name <Name>'
;;     argument `scripts/launch' passes when it does not - a session started
;;     by hand, outside this fleet, has no file and still has to show `up'.

;;; Code:

(require 'cl-lib)
(require 'let-alist)
(require 'json)
(require 'iso8601)
(require 'tabulated-list)
(require 'seq)
(require 'subr-x)

(defgroup cerebro nil
  "The fleet view: what every agent is doing, and starting or stopping them."
  :group 'tools
  :prefix "cerebro-")

(defcustom cerebro-bd-program "bd"
  "The beads executable cerebro runs the panel and the sweeps from.

A consumer may install it under another name, or behind a wrapper that
adds a flag or a path.  This is the *program*, not the command language:
cerebro speaks beads, and it does so in `scripts/work-beads\=',
`scripts/sweep-claims.sh\=', `scripts/sweep-epics.sh\=' and every agent
document as well as here, so a different tracker is a far larger change
than a setting and is deliberately out of scope."
  :type 'string
  :group 'cerebro)

(defconst cerebro-buffer-name "*cerebro*")

(defvar cerebro-list-width 59
  "Columns for the left column of the layout, recomputed on every revert.

Derived rather than configured (ah-qled.9): `cerebro--column-widths\=' sizes
the table from the roster actually in front of it and the bead ids actually
being shown, and `cerebro--width-for\=' turns those into this.  59 is what
this project\='s own fleet produces, and is the value here until the first
render replaces it.

The agent table is 14+13+10+10+10 plus one column of padding = 58; this is
59 so the table is strictly narrower than the window, which is what keeps
Emacs's `$' truncation marker off the right edge - a table exactly as wide
as its window loses its last column to that marker (ah-lyc). It was 54
before the For column became Bead/Phase and widened 5 -> 10 to show time on
the bead and time in the phase together (ah-u3i); 62 before that, before the
State column's \" finishing\" suffix became a one-glyph \" ■\" and the Bead
column stopped needing room for the word \"(external)\". The bead panel and
detail window underneath inherit this width and, like the table, are
narrower for it - their titles get less room than they used to, an accepted
trade.")

;;; The pure core

;;; The fleet roster (replaces `cerebro-interactive-agents' and `cerebro--role-launch-commands')

(defun cerebro--parse-fleet (output)
  "Turn OUTPUT of `scripts/roster' into a list of (NAME ROLE KIND).

One agent per line, NAME, ROLE and KIND tab-separated; KIND becomes the
symbol `implementer' or `interactive' (`intern' of the third field).  Blank
lines and lines with fewer than three fields are skipped, so a torn read
cannot put a half-row in the fleet.  Order is preserved: the roster's order
is the fleet view's order."
  (let (rows)
    (dolist (line (split-string output "\n"))
      (let ((fields (split-string line "\t")))
        (when (>= (length fields) 3)
          (push (list (nth 0 fields) (nth 1 fields) (intern (nth 2 fields))) rows))))
    (nreverse rows)))

(defun cerebro--fleet-roster (fleet)
  "The implementer names in FLEET, in order."
  (mapcar #'car (seq-filter (lambda (row) (eq (nth 2 row) 'implementer)) fleet)))

(defun cerebro--fleet-interactive (fleet)
  "The (NAME . ROLE) alist of FLEET's interactive agents, in order."
  (mapcar (lambda (row) (cons (nth 0 row) (nth 1 row)))
          (seq-filter (lambda (row) (eq (nth 2 row) 'interactive)) fleet)))

(defun cerebro--list-height (agent-count)
  "Lines the agent list needs for AGENT-COUNT agents: the rows, the header
line and the mode line, so the list never scrolls and the bead panel gets
whatever the frame has left (was a constant of 20 for eighteen agents)."
  (+ agent-count 2))

(cl-defstruct cerebro-agent
  "One row of the fleet list."
  name role kind                       ; kind: 'interactive | 'implementer
  state                                ; 'up | 'working | 'idle | 'dead | 'done | 'asking
                                       ;  | 'waiting | 'unknown
  bead since external
  phase                                ; "build"|"gate"|"review"|"ci"|"rebase"|"merge" or nil
  phase-since                          ; ISO-8601 string, or nil
  wake-at                              ; ISO-8601 string when `waiting', else nil
  raw)                                 ; the state file's `state' string verbatim, or nil

(defun cerebro--name-in-args-p (name args)
  "Non-nil if some string in ARGS names NAME via a whole-word \"--name NAME\"."
  (let ((needle (concat "--name[ \t]+" (regexp-quote name) "\\_>")))
    (cl-some (lambda (a) (and (stringp a) (string-match-p needle a))) args)))

(defun cerebro--derive-from-state (name role kind parsed owned-p)
  "Build one `cerebro-agent' for NAME from a live, parsed state file PARSED.

ROLE and KIND are the row's static fields; OWNED-P is whether Emacs itself
started this session. Shared between an implementer and an interactive agent
once each has confirmed the file it read names a still-live pid - this is
the one place a raw `state' string becomes the `cerebro-agent-state' symbol
the rest of the view reads."
  (let* ((raw-state (alist-get 'state parsed))
         (state (cond ((equal raw-state "working") 'working)
                      ;; The bead is merged and closed and the session has
                      ;; nothing left to do; `cerebro--supervise' replaces
                      ;; it, because an interactive session cannot end
                      ;; itself the way a --print one did. `done' is an
                      ;; implementer's state alone - `scripts/agent-state'
                      ;; refuses it from an interactive name - so a stray one
                      ;; here is a bug, not a finished bead, and must not be
                      ;; handed to `cerebro--supervise-action' as if it were.
                      ((equal raw-state "done") (if (eq kind 'implementer) 'done 'unknown))
                      ;; Blocked on a question only the navigator can
                      ;; answer, with a bead still in flight.
                      ((equal raw-state "asking") 'asking)
                      ;; The role has finished a pass and ENDED ITS TURN,
                      ;; expecting to be woken (ah-hiib.3). An interactive
                      ;; agent's state alone, the mirror image of `done':
                      ;; an implementer is replaced between beads and has no
                      ;; cadence, so a `waiting' file under one is a bug and
                      ;; must not be handed to the poke logic as a cadence.
                      ((equal raw-state "waiting")
                       (if (eq kind 'interactive) 'waiting 'unknown))
                      ((equal raw-state "idle") 'idle)
                      ;; A raw state this list has never seen - a typo in
                      ;; the skill, most likely.  A live process the view
                      ;; does not understand is something the navigator
                      ;; may want to look at, so this must not read as
                      ;; `idle', which means "free, give it a bead".
                      (t 'unknown))))
    (make-cerebro-agent :name name :role role :kind kind
                                :state state
                                :bead (alist-get 'bead parsed)
                                :since (alist-get 'since parsed)
                                :external (not owned-p)
                                :phase (alist-get 'phase parsed)
                                :phase-since (alist-get 'phase_since parsed)
                                :wake-at (alist-get 'wake_at parsed)
                                :raw raw-state)))

(defun cerebro--derive-interactive (entry states session-alive-p args owned)
  "Derive one interactive agent's row from (NAME . ROLE) ENTRY.

STATES is an alist of (NAME . parsed-state-json-or-nil), the same one an
implementer's row is derived from; SESSION-ALIVE-P a predicate on (PID NAME) -
is that pid still *this* agent's session, not merely a live one; ARGS is
the system process args list; OWNED the names Emacs itself started.

Liveness is the state file first, the process scan second: when STATES has
an entry for NAME whose pid is still alive, the row comes from the file -
`working'/`idle'/`asking' and a phase, exactly like an implementer's row.
Otherwise (no entry, or a pid that is no longer this agent's session - the
file, if any, is a previous session's, and the pid may since have been
recycled onto something else) this falls back to the three process-scan branches
below, so a session started by hand outside this fleet
\(`claude --name Xavier ...'\) with no file at all still shows `up'."
  (let* ((name (car entry))
         (role (cdr entry))
         (parsed (cdr (assoc name states)))
         (pid (and parsed (alist-get 'pid parsed)))
         (alive (and pid (funcall session-alive-p pid name)))
         (owned-p (and (member name owned) t)))
    (if alive
        (cerebro--derive-from-state name role 'interactive parsed owned-p)
      (cond
       ((member name owned)
        (make-cerebro-agent :name name :role role :kind 'interactive
                                    :state 'up :bead nil :since nil :external nil))
       ((cerebro--name-in-args-p name args)
        (make-cerebro-agent :name name :role role :kind 'interactive
                                    :state 'up :bead nil :since nil :external t))
       (t
        (make-cerebro-agent :name name :role role :kind 'interactive
                                    :state 'dead :bead nil :since nil :external nil))))))

(defun cerebro--derive-implementer (name states session-alive-p owned)
  "Derive one implementer's row for NAME.

STATES is an alist of (NAME . parsed-state-json-or-nil); SESSION-ALIVE-P a
predicate on (PID NAME) - see `cerebro--session-alive-p', which requires the
pid's own command line to name this agent, since pids are recycled; OWNED the
names Emacs itself started."
  (let* ((parsed (cdr (assoc name states)))
         (pid (and parsed (alist-get 'pid parsed)))
         (alive (and pid (funcall session-alive-p pid name)))
         (owned-p (and (member name owned) t)))
    (cond
     ;; A session Emacs started is alive whatever the file says: `cerebro--owned'
     ;; already requires a live process, and the file lags it twice over - a
     ;; fresh session has not written one yet, and after a restart the file on
     ;; disk is still the *previous* session's, with a dead pid and a finished
     ;; bead. Reporting dead here is not cosmetic: it is what the row shows
     ;; while `cerebro--start-action' checks ownership first and `cerebro--launch'
     ;; refuses a second session at the source - the row should not lie about
     ;; what `s' would do in the meantime.
     ((and (not alive) owned-p)
      (make-cerebro-agent :name name :role "implementer" :kind 'implementer
                                  :state 'idle :bead nil :since nil :external nil))
     ((not alive)
      (make-cerebro-agent :name name :role "implementer" :kind 'implementer
                                  :state 'dead :bead nil :since nil :external nil))
     (t (cerebro--derive-from-state name "implementer" 'implementer parsed owned-p)))))

(defun cerebro--derive (roster interactive-agents states session-alive-p args owned)
  "Return the fleet as a list of `cerebro-agent', interactive first.

ROSTER is the implementer name list, in the order they should be shown.
INTERACTIVE-AGENTS is an alist of (NAME . ROLE), normally
`cerebro--interactive-agents'.  STATES is an alist of (NAME .
parsed-state-json-or-nil) covering both the roster and the interactive
names - see `cerebro--gather-states'.  SESSION-ALIVE-P is a predicate on
(PID NAME): whether that pid is still that agent's own session.
ARGS is the system process args list.  OWNED is the set of agent names whose
sessions Emacs itself started."
  (append
   (mapcar (lambda (entry) (cerebro--derive-interactive entry states session-alive-p args owned))
           interactive-agents)
   (mapcar (lambda (name) (cerebro--derive-implementer name states session-alive-p owned))
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
   ;; `unknown' is a live session the view does not understand - the same
   ;; yellow as `idle', for the same reason: something the navigator may want
   ;; to look at. Grey (`dead') would say nobody is there, which is untrue.
   ;; Waiting has a session up, nothing in flight, and a time it comes back
   ;; (ah-hiib.3). Yellow like `idle' - both are agents with no work in hand -
   ;; but a different shape, because the two mean opposite things about who
   ;; acts next: an idle implementer is waiting for the navigator or the
   ;; queue, a waiting role is waiting for this very poll.
   ((eq state 'waiting) (propertize "◐" 'face 'cerebro-idle))          ; ◐
   ((memq state '(idle unknown)) (propertize "●" 'face 'cerebro-idle))  ; ●
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

(defun cerebro--seconds-until (then now)
  "Seconds from NOW to THEN (an ISO-8601 string, or nil), or nil.

Signed, and that is the whole reason it exists beside
`cerebro--seconds-since\=': that one clamps at zero, so a timestamp in the
future and one exactly now are indistinguishable through it.  A deadline
needs to know which side of it we are on."
  (when then
    (condition-case nil
        (floor (float-time (time-subtract (encode-time (iso8601-parse then)) now)))
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

(defconst cerebro--phases
  '("build" "gate" "review" "ci" "rebase" "merge"
    "triage" "plan" "prepare" "verify" "sweep" "release" "daily" "weekly"
    "read" "check" "walk" "report")
  "The phase vocabulary this fleet uses.

`scripts/agent-state' no longer enforces it - any lower-case word is
accepted, so that a consumer adding a role of its own can report state at
all (ah-qled.5.2).  This list is what *these* agents use, kept in step with
them by tests/launchers.sh, and it is the only place saying which words
belong to which role.

Not divided by role in code - the fleet list shows whatever word a state
file carries, in the State column, and a wrong word for the role in that
column is not worth a per-role table in Elisp any more than in the script.
By role, for reference: `build gate review ci rebase merge' belong to an
implementer; `triage plan' to a planner; `prepare verify' to Psylocke; `sweep',
or `sweep release', to Moira and Cerebro; `daily weekly' to Forge; and
`read check walk report' to Cypher, whose work item is a pull request
rather than a bead.")

(defun cerebro--in-flight-p (state)
  "Whether STATE means a bead is still in flight under it."
  (memq state '(working asking)))

(defun cerebro--state-label (agent)
  "The State column's text for AGENT, without the \" ■\" flag suffix.

An `unknown' state shows its raw word, truncated to the column width -
still worth reading rather than a lie like `idle' would be. A `working'
agent with a phase shows the phase (`build\=', `review\=', ...); anything
else shows the state's own name. `asking' always shows `asking\=', even with
a phase set, because the bold row already says everything a phase word
would add."
  (let ((state (cerebro-agent-state agent)))
    (cond
     ((eq state 'unknown)
      (truncate-string-to-width (or (cerebro-agent-raw agent) "unknown") 10 nil nil "…"))
     ((and (eq state 'working) (cerebro-agent-phase agent))
      (cerebro-agent-phase agent))
     (t (symbol-name state)))))

(defun cerebro--wake-column (agent now)
  "\"→5m\" - how long until AGENT's wake, at NOW - or the empty string.

Only ever non-empty for a `waiting' agent with a parseable `wake_at': the
State column says `waiting' and this says when it comes back, which together
are what separate a waiting role from one that has hung (which shows no wake
at all) in the fleet list.

A wake already past reads \"→due\" rather than \"→0m\": between the wake
falling due and the poll poking it there is a real, visible moment, and
counting downwards through zero would show a negative or a lie."
  (if (not (eq (cerebro-agent-state agent) 'waiting))
      ""
    (let ((left (cerebro--seconds-until (cerebro-agent-wake-at agent) now)))
      (cond
       ((null left) "")
       ((<= left 0) "→due")
       ((>= left 3600) (format "→%dh%02d" (/ left 3600) (/ (mod left 3600) 60)))
       (t (format "→%dm" (/ left 60)))))))

(defun cerebro--for-column (since phase-since now)
  "The Bead/Phase column: time on the bead and time in the phase, at NOW.

SINCE and PHASE-SINCE are ISO-8601 strings or nil. Renders as \"31m 12m\"
when both are known, just the one figure when only one is, and the empty
string when neither is."
  (let ((bead-time (cerebro--elapsed since now))
        (phase-time (cerebro--elapsed phase-since now)))
    (cond
     ((string-empty-p phase-time) bead-time)
     ((string-empty-p bead-time) phase-time)
     (t (concat bead-time " " phase-time)))))

(defun cerebro--emphasize (text emphasize)
  "TEXT in bold when EMPHASIZE, otherwise TEXT unchanged."
  (if emphasize (propertize text 'face 'bold) text))

(defconst cerebro--column-minimums '(14 13 10 10 10)
  "The floor for each column: Agent, Role, State, Bead, Bead/Phase.

This project\='s table, kept as the floor so a short roster still gets a
readable one rather than columns that hug their own contents.")

(defun cerebro--column-widths (names roles bead-ids)
  "Pure.  The five column widths for a fleet of NAMES filling ROLES, showing
BEAD-IDS.

Computed rather than configured: the widths are a fact about the data, and
four more settings would be four more things a consumer has to discover
before its own longer names stopped being truncated.  Agent allows two
columns for the state glyph and its space; Role and Bead one for the gap to
the next column.  State is a fixed vocabulary and Bead/Phase a pair of
elapsed times, so neither is derived from anything a consumer varies."
  (let ((longest (lambda (strings) (apply #'max 0 (mapcar #'length strings)))))
    (list (max (nth 0 cerebro--column-minimums) (+ 2 (funcall longest names)))
          (max (nth 1 cerebro--column-minimums) (+ 1 (funcall longest roles)))
          (nth 2 cerebro--column-minimums)
          (max (nth 3 cerebro--column-minimums) (+ 1 (funcall longest bead-ids)))
          (nth 4 cerebro--column-minimums))))

(defun cerebro--width-for (widths)
  "Columns the layout\='s left window needs for a table of WIDTHS.

One for `tabulated-list-padding\=', and one more so the table is strictly
narrower than its window - a table exactly as wide as its window loses its
last column to Emacs\='s `$\=' truncation marker (ah-lyc)."
  (+ (apply #'+ widths) 2))

(defun cerebro--table-format (widths)
  "WIDTHS as a `tabulated-list-format\=' vector."
  (vector (list "Agent" (nth 0 widths) nil)
          (list "Role" (nth 1 widths) nil)
          (list "State" (nth 2 widths) nil)
          (list "Bead" (nth 3 widths) nil)
          (list "Bead/Phase" (nth 4 widths) nil)))

(defun cerebro--entry (agent now &optional flagged unanswered bead-width)
  "AGENT as a `tabulated-list-entries' element, evaluated at NOW.

FLAGGED, when non-nil, means a stop flag is set for AGENT: the state column
gains a \" ■\" suffix, so the navigator sees the flag took effect while the
bead is still in flight rather than being told nothing happened. Flags are
read between beads, never during one - see `cerebro-finish' - so this is the
only place the glyph is added.

The suffix only ever shows for a state a bead can actually be in flight
under - `working' or `asking'. \"dead ■\" or \"idle ■\" would describe a bead
that either was never running or has none to complete - there is nothing in
flight for the flag to be waiting on, so the marker would say something
untrue rather than nothing. That case barely arises any more: an idle
implementer under a flag is retired by the fleet poll within about one tick
\(`cerebro--supervise-action', ah-ymn\), and `f' no longer writes a flag at
all for a dead or externally-idle one \(`cerebro--finish-action'\) - so there
is effectively no idle-and-flagged state left to describe.

UNANSWERED, when non-nil, means AGENT is a `waiting' role that did not
answer either of its pokes: the state column gains a \" !\" suffix, which is
where the poke stops rather than being retried on every tick for ever
\(`cerebro--poke-decision', ah-hiib.3).

BEAD-WIDTH is what the Bead column was sized to (`cerebro--column-widths\=',
default 10).  An external agent shows \"—\" rather than the wordier
\"(external)\", and an id longer than the column truncates with an ellipsis
rather than pushing the rest of the row right - see ah-lyc."
  (let* ((state (cerebro-agent-state agent))
         (external (cerebro-agent-external agent))
         (in-flight (cerebro--in-flight-p state))
         ;; A glyph is one character in the corner of the eye, and there are
         ;; eighteen rows. Bolding the whole row makes the row itself the
         ;; signal - so bold has to stay rare enough to mean it, which is why
         ;; it is exclusive to `asking' (see `cerebro--wants-attention-p').
         (attention (cerebro--wants-attention-p state))
         (agent-col (format "%s %s" (cerebro--glyph state)
                            (cerebro--emphasize (cerebro-agent-name agent) attention)))
         (role-col (cerebro--emphasize (cerebro-agent-role agent) attention))
         (state-col (cerebro--emphasize
                     (concat (cerebro--state-label agent)
                             (if (and flagged in-flight) " ■" "")
                             (if unanswered " !" ""))
                     attention))
         (bead-col (cerebro--emphasize
                    (cond (external "—")
                          ((cerebro-agent-bead agent)
                           (truncate-string-to-width (cerebro-agent-bead agent)
                                                    (or bead-width 10) nil nil "…"))
                          (t ""))
                    attention))
         (for-col (cerebro--emphasize
                   (if external ""
                     (let ((for (cerebro--for-column (cerebro-agent-since agent)
                                                     (cerebro-agent-phase-since agent) now))
                           (wake (cerebro--wake-column agent now)))
                       (cond ((string-empty-p wake) for)
                             ((string-empty-p for) wake)
                             (t (concat for " " wake)))))
                   attention)))
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
         ;; A failed verdict reopens a bead into the unclaimed pile, where it
         ;; is an ordinary open bead - which is the point. The mark is the one
         ;; thing that pile cannot otherwise say: this came back rather than
         ;; arrived. Two columns either way, so the ids stay in line.
         (reopened (member "verification:failed" (alist-get 'labels bead)))
         (prefix (format "%s%-7s P%s " (if reopened "↻ " "  ")
                         id (if priority (number-to-string priority) "?")))
         ;; Deliberately no owner column.  `bd's `owner' is the address of
         ;; whoever *filed* the bead and is set on every one of them, so it
         ;; says nothing about who is working on it - and the agent list
         ;; directly above already answers that for every implementer.
         (room (max 8 (- width (length prefix)))))
    ;; The row carries its own id, so navigation and the mark are about beads
    ;; rather than about line numbers - which the next refresh would move.
    (propertize (concat prefix (cerebro--truncate (or (alist-get 'title bead) "") room))
                'cerebro-bead id 'cerebro-priority priority)))

(defun cerebro--bead-section (title beads width max &optional sort)
  "Lines for one section: TITLE with its count, then up to MAX of BEADS.

SORT is the ordering function, `cerebro--sort-beads' by default.

The count is on the header rather than implied by the rows, because the rows
are the part that gets capped - and a section whose remainder is hidden
still has to say how much work is really in it."
  (let* ((sorted (funcall (or sort #'cerebro--sort-beads) beads))
         (shown (seq-take sorted max))
         (hidden (- (length sorted) (length shown))))
    (append
     (list (propertize (format "%s %d" title (length sorted)) 'face 'bold))
     (if (null sorted)
         (list (propertize "  (none)" 'face 'shadow))
       (mapcar (lambda (bead) (cerebro--bead-line bead width)) shown))
     (when (> hidden 0)
       (list (propertize (format "  +%d more" hidden) 'face 'shadow))))))

(defun cerebro--bead-panel (claimed planned being-planned unplanned merged width max
                                    &optional sweep-findings history-rows)
  "The whole panel as a list of lines.

The order work moves in, read backwards, and it stops where the fleet's part
in it does: being built, ready to pick up, being planned, not planned yet,
and merged but not yet verified - which is Psylocke's queue.

BEING-PLANNED is the planners' own row of the pipeline. It is worth its own
section rather than being folded into Unplanned because the two answer
opposite questions: Unplanned is work nobody has started, and this is work
that is under way and simply cannot be claimed yet. Read together with
Planned, unclaimed, it is also what says whether a short queue means the
planners are behind or merely mid-bead.

Verified work is not here. Neither is anything nobody can pick up. See
`cerebro--partition-beads' for what that leaves out and why.

SWEEP-FINDINGS, when given, adds a Sweeps section at the bottom (see
`cerebro--sweep-section') - what the claims and epics sweeps found, each
one a candidate for `x' rather than something already decided.

HISTORY-ROWS, when given, adds a History section below that (see
`cerebro--history-section') - what each agent is doing right now, how long
it has been doing it, and whether that is long by its own standards."
  (append (cerebro--bead-section "Claimed" claimed width max) (list "")
          (cerebro--bead-section "Planned, unclaimed" planned width max) (list "")
          (cerebro--bead-section "Being planned" being-planned width max) (list "")
          (cerebro--bead-section "Unplanned" unplanned width max) (list "")
          ;; Newest first: priority says nothing about finished work, so what
          ;; this answers is what just landed and still wants checking.
          (cerebro--bead-section "Merged, unverified" merged width max
                                 #'cerebro--sort-recent)
          (let ((sweep-lines (cerebro--sweep-section sweep-findings)))
            (when sweep-lines (cons "" sweep-lines)))
          (let ((history-lines (cerebro--history-section history-rows)))
            (when history-lines (cons "" history-lines)))))

;;; The Sweeps section (ah-4ao): claims and epics found by the sweep scripts

(defun cerebro--sweep-label (finding candidate)
  "One line of human-readable text for FINDING, built from CANDIDATE - the
claim or epic object `cerebro--claim-finding'/`cerebro--epic-finding' judged
it from."
  (let-alist candidate
    (pcase finding
      (`(close ,id ,_reason)
       (format "close %s — delivered by %s, on main %sm" id .assignee
               (or .commit_age_min "?")))
      (`(reclaim ,id)
       (format "reclaim %s — %s gone, not on main" id .assignee))
      (`(epic-close ,id)
       (format "close %s — all children closed %sm ago" id
               .minutes_since_last_child_closed))
      (`(unclaim ,id)
       (format "unclaim %s — %s stalled, no %s for %sm" id .assignee
               (if (equal .progress_source "commit") "commit" "start")
               .progress_age_min))
      ;; `assignee_bead\=' is not a field of `sweep-assignees.sh\='s output - the
      ;; script reads `bd\=', not the state files, and cannot know it.
      ;; `cerebro--findings-from\=' enriches the candidate with it before
      ;; labelling, so this stays a pure formatter like the three arms above.
      (`(unassign ,id ,_priority)
       (format "unassign %s — %s is %s" id .assignee
               (if .assignee_bead (format "on %s" .assignee_bead) "not running"))))))

(defun cerebro--sweep-line (label finding)
  "One propertized Sweeps line: LABEL, carrying FINDING the way a bead row
carries its id - so `cerebro-sweep-act' acts on what point stands on rather
than re-deriving it from the text.

A stranded P0 additionally renders in the `warning' face, the same face an
`asking' session's marker uses. That is the whole of the escalation: the
line is visibly different from the rest of the section, and there is no new
face, glyph, popup or sound. The failure this answers (ah-kjfm) is that
nobody was looking, and a P0 line that reads like the four ordinary ones is
one nobody presses."
  (let ((line (propertize label 'cerebro-finding finding)))
    (pcase finding
      (`(unassign ,_id 0) (propertize line 'face 'warning))
      (_ line))))

(defun cerebro--sweep-section (findings)
  "Lines for the Sweeps section. FINDINGS is a list of (LABEL . FINDING).

Nil - no header, nothing - when FINDINGS is empty. That is deliberately
unlike `cerebro--bead-section', which prints \"(none)\": those sections
describe queues that are normally non-empty, so their being empty is worth
a line saying so. An empty Sweeps section is the *ordinary* result of every
render but one, and a panel that said \"Sweeps 0 / (none)\" every ten
minutes would be exactly the noise `orchestrator.md' already warns against
for a sweep that found nothing."
  (when findings
    (cons (propertize "Sweeps" 'face 'bold)
          (mapcar (lambda (f) (cerebro--sweep-line (car f) (cdr f))) findings))))

;;; The History section (ah-hiib.2): how long the fleet has been where it is

(defvar cerebro-history-long-multiple 2
  "How many times its own median an open interval must reach to be marked long.

Not one. An interval is past the median half the time by construction, so a
mark that fired on the median would fire on half of every ordinary day and
stop meaning anything. Twice the typical stretch in that state is a genuine
outlier and is worth a word.")

(defun cerebro--history-row-line (row)
  "One History line for ROW, one summary row from `scripts/fleet-history', or
nil when that row has nothing running.

Only the open interval is shown: the aggregates are what say whether it is
unusual, not what the navigator is being told. A row whose open_min is null
describes a state the agent is not in at the moment, and has no line.

A state nothing has yet finished in has no median, and so is never marked
long however far it runs. That is the script's answer, not a gap here:
there is nothing to call it long against, and a first interval judged
against itself would be marked always or never depending on the arithmetic
rather than on the fleet."
  (let-alist row
    (when .open_min
      (let* ((median (and (numberp .median_min) (> .median_min 0) .median_min))
             (long (and median (>= .open_min (* cerebro-history-long-multiple median))))
             (text (format "  %s %s %sm%s"
                           .agent .state (round .open_min)
                           (if long (format " - long, median %sm" (round median)) ""))))
        (if long (propertize text 'face 'warning) text)))))

(defun cerebro--history-section (rows)
  "Lines for the History section. ROWS is the parsed summary output of
`scripts/fleet-history': one row per agent and state, each carrying that
pair's count, total, median and longest, plus open_min when the agent is in
that state right now.

A pure function - it renders what the script computed and computes nothing
itself, which is what keeps this off the five-second tick and testable
without a subprocess.

An agent that has finished, or whose session died and left an interval
nobody will ever close, has no line: `scripts/fleet-history' treats `done'
as terminal and drops an interval open beyond a day. What is left is what
is actually running, which is what the section claims to show.

Nil - no header, nothing at all - when nothing is running, exactly as
`cerebro--sweep-section' does and for the same reason: a section saying
\"(none)\" every five minutes is the noise `orchestrator.md' warns against."
  (let ((lines (delq nil (mapcar #'cerebro--history-row-line rows))))
    (when lines
      (cons (propertize "History" 'face 'bold) lines))))

(defun cerebro--live-sessions (repo-root)
  "(NAME STATE BEAD) for every implementer with a live session in REPO-ROOT.

The single read the three derivations below share; a name is present
exactly when its state file parses and its pid is alive, whatever that file
says. A file with no `state\=' or `bead\=' key still puts the name here, with
a nil in that position - a half-written file is not evidence against a
working implementer.

Liveness is `cerebro--session-alive-p\=', which checks the pid\='s own
`--name\='. A bare pid check would make a recycled pid look like a live
session, which here would suppress a real finding."
  (let ((roster (cerebro--roster repo-root)))
    (delq nil
          (mapcar (lambda (name)
                    (let* ((parsed (cerebro--read-state-file
                                    (cerebro--state-file-path repo-root name)))
                           (pid (and parsed (alist-get 'pid parsed)))
                           (state (and parsed (alist-get 'state parsed)))
                           (bead (and parsed (alist-get 'bead parsed))))
                      (and pid (cerebro--session-alive-p pid name)
                           (list name (and state (intern state)) bead))))
                  roster))))

(defun cerebro--live-implementer-names (repo-root)
  "Implementer names with a live session right now, in REPO-ROOT.

By process, not by `cerebro--owned': a session running in the navigator's
own terminal is just as live as one Emacs started, and just as much not to
be swept as one Emacs started."
  (mapcar #'car (cerebro--live-sessions repo-root)))

(defun cerebro--live-session-states (repo-root)
  "The (NAME . STATE-SYMBOL) alist for every implementer with a live session
in REPO-ROOT. A name is present exactly when its state file parses and its
pid is alive, whatever that file says about state - a file with no `state\='
key, or one this version does not recognise, still puts the name here with
a nil state.

`cerebro--live-implementer-names\=' is the same read without the states and
`cerebro--live-session-beads\=' the same read with the beads instead;
`cerebro--findings-from\=' derives all three from one call to
`cerebro--live-sessions\='."
  (mapcar (lambda (session)
            (cons (nth 0 session) (nth 1 session)))
          (cerebro--live-sessions repo-root)))

(defun cerebro--live-session-beads (repo-root)
  "The (NAME . BEAD) alist for every implementer with a live session in
REPO-ROOT, BEAD being the bead its state file says it is on, or nil.

The third derivation of the one read `cerebro--live-sessions\=' does. The
assignee sweep needs it because \"alive\" alone cannot tell a session that is
a moment from claiming this very bead from one building something else -
and clearing the assignee under the first would be the fleet view fighting
an implementer."
  (mapcar (lambda (session)
            (cons (nth 0 session) (nth 2 session)))
          (cerebro--live-sessions repo-root)))

(defvar cerebro-subprocess-timeout-seconds 120
  "How long an asynchronous subprocess may run before it is killed and its
answer treated as none. Generous: the sweeps fetch from origin and talk to
`gh', which this bounds a hang against, not a slow answer.")

(defvar cerebro--inflight nil
  "Runs still awaiting an answer: an alist of (KEY . PROCESS). One per KEY -
`cerebro--run-async' refuses a second while the first is out, so a slow
`bd' is waited for rather than stacked.")

(defun cerebro--run-async (key repo-root argv callback)
  "Run ARGV (program, then args) in REPO-ROOT without blocking Emacs.

CALLBACK is called exactly once, later, with the program's stdout as a
string when it exited zero and nil otherwise - non-zero exit, a signal, the
program missing, or `cerebro-subprocess-timeout-seconds' passing first, in
which case the process is killed. Returns `started', or `busy' when a run
under KEY is already in flight - then nothing is started and CALLBACK is
never called. Never signals."
  (if (assq key cerebro--inflight)
      'busy
    ;; OUT is created outside the `condition-case' it is used in, so a
    ;; `make-process' error (the program is missing, say) can still kill it
    ;; in the handler - inside the protected form, the handler clause has no
    ;; access to bindings the form never finished establishing (PR #42
    ;; review: an earlier version leaked this buffer on every such error).
    (let* ((default-directory (file-name-as-directory repo-root))
           (out (generate-new-buffer (format " *cerebro-async-%s*" key))))
      (condition-case nil
          (let (proc)
            (setq proc
                  (make-process
                   :name (format " *cerebro-%s*" key)
                   :buffer out
                   :command argv
                   :noquery t
                   :connection-type 'pipe
                   :sentinel
                   (lambda (proc _event)
                     (when (memq (process-status proc) '(exit signal))
                       (setq cerebro--inflight (assq-delete-all key cerebro--inflight))
                       (let ((timer (process-get proc 'cerebro-timeout)))
                         (when timer (cancel-timer timer)))
                       (let ((output (and (eq (process-status proc) 'exit)
                                          (zerop (process-exit-status proc))
                                          (with-current-buffer out (buffer-string)))))
                         (kill-buffer out)
                         (with-demoted-errors "cerebro: %S" (funcall callback output)))))))
            (process-put proc 'cerebro-timeout
                         (run-at-time cerebro-subprocess-timeout-seconds nil
                                      (lambda ()
                                        (when (process-live-p proc)
                                          (delete-process proc)))))
            (push (cons key proc) cerebro--inflight)
            'started)
        (error
         (when (buffer-live-p out) (kill-buffer out))
         (with-demoted-errors "cerebro: %S" (funcall callback nil))
         'started)))))

(defun cerebro--parse-json (text)
  "TEXT parsed as JSON the way the panel wants it (alists, lists, nil), or nil
when TEXT is nil or not JSON."
  (and text
       (condition-case nil
           (json-parse-string text :object-type 'alist :array-type 'list
                              :null-object nil :false-object nil)
         (error nil))))

(defconst cerebro--parse-failed 'cerebro--parse-failed
  "Sentinel `cerebro--try-parse-json' returns for invalid JSON - distinct
from nil, which a valid empty answer (\"[]\") also parses to.")

(defun cerebro--try-parse-json (text)
  "TEXT parsed as JSON, or `cerebro--parse-failed' when TEXT is not valid
JSON. `cerebro--parse-json' cannot tell a genuinely empty answer (\"[]\",
parses to nil) from garbage (also nil) apart - this can, for a caller that
has to treat the two differently: a program exiting zero but printing
garbage is not `bd' or a sweep script having answered."
  (condition-case nil
      (json-parse-string text :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil)
    (error cerebro--parse-failed)))

(defun cerebro--findings-from (repo-root claims epics stalled assignees)
  "The sweep findings (LABEL . FINDING) from CLAIMS, EPICS, STALLED and
ASSIGNEES, the parsed JSON of the four sweep scripts. Computed at answer
time (called from `cerebro--request-sweeps\='s callback) so the live fleet is
the one described when the findings are shown, not the one that existed when
the scripts were kicked off.

The claims sweep wants names, the stalled sweep wants states and the
assignee sweep wants beads; all three are derived here from one call to
`cerebro--live-sessions\=', rather than through the three helpers - which
would walk the roster three times and, worse, take three separate snapshots
of a fleet that moves, so one sweep could judge a session the next one no
longer sees."
  (let* ((sessions (cerebro--live-sessions repo-root))
         (live-names (mapcar (lambda (x) (nth 0 x)) sessions))
         (live-states (mapcar (lambda (x) (cons (nth 0 x) (nth 1 x))) sessions))
         (live-beads (mapcar (lambda (x) (cons (nth 0 x) (nth 2 x))) sessions))
         (roster (cerebro--roster repo-root))
         (now (current-time)))
    (append
     (delq nil (mapcar (lambda (c)
                         (let ((finding (cerebro--claim-finding c live-names now)))
                           (and finding (cons (cerebro--sweep-label finding c) finding))))
                       claims))
     (delq nil (mapcar (lambda (e)
                         (let ((finding (cerebro--epic-finding e)))
                           (and finding (cons (cerebro--sweep-label finding e) finding))))
                       epics))
     (delq nil (mapcar (lambda (c)
                         (let ((finding (cerebro--stalled-finding c live-states now)))
                           (and finding (cons (cerebro--sweep-label finding c) finding))))
                       stalled))
     (delq nil (mapcar (lambda (c)
                         (let ((finding (cerebro--assignee-finding c live-beads roster now)))
                           (and finding
                                ;; The label wants to say what the assignee is
                                ;; actually on, which the script cannot know - it
                                ;; reads `bd\=', not the state files. Enriching the
                                ;; candidate here keeps `cerebro--sweep-label\=' a
                                ;; pure two-argument formatter.
                                (let ((enriched
                                       (cons (cons 'assignee_bead
                                                   (cdr (assoc (alist-get 'assignee c)
                                                               live-beads)))
                                             c)))
                                  (cons (cerebro--sweep-label finding enriched) finding)))))
                       assignees)))))

(defconst cerebro--sweep-scripts
  '((sweep-claims . "sweep-claims.sh")
    (sweep-epics . "sweep-epics.sh")
    (sweep-stalled . "sweep-stalled.sh")
    (sweep-assignees . "sweep-assignees.sh"))
  "The sweep scripts, in the order they are run, keyed by their
`cerebro--run-async\=' key. Their parsed output reaches
`cerebro--findings-from\=' as arguments in this same order.")

(defun cerebro--request-sweeps (repo-root callback)
  "Run the sweep scripts without blocking, one after the other; CALLBACK gets
the (LABEL . FINDING) list when all of them have answered, or nil when any
did not - including a script exiting zero but printing something that is not
JSON, in which case no later script is started at all. Returns `busy\=' if a
sweep is already out.

List-driven rather than hand-nested: the scripts are identical in shape, and
a callback nest one level deep per script stops being readable at three."
  (cerebro--request-sweeps-1 repo-root cerebro--sweep-scripts nil callback))

(defun cerebro--request-sweeps-1 (repo-root remaining acc callback)
  "Run REMAINING sweep scripts in order, collecting parsed output onto ACC
\(reversed), then call CALLBACK. See `cerebro--request-sweeps\='."
  (if (null remaining)
      (funcall callback (list (apply #'cerebro--findings-from repo-root (nreverse acc))))
    (let ((key (caar remaining))
          (script (cdar remaining)))
      (cerebro--run-async
       key repo-root
       (list (expand-file-name (cerebro--script script) repo-root) "--json")
       (lambda (out)
         (if (null out)
             (funcall callback nil)
           (let ((parsed (cerebro--try-parse-json out)))
             (if (eq parsed cerebro--parse-failed)
                 (funcall callback nil)
               (cerebro--request-sweeps-1 repo-root (cdr remaining)
                                          (cons parsed acc) callback)))))))))

(defun cerebro--request-history (repo-root callback)
  "Run `scripts/fleet-history --summary' without blocking; CALLBACK gets the
parsed rows when it answered with JSON, and nil when it did not - the script
missing, a corrupt log, or a timeout. Returns `busy' if one is already out.

All the arithmetic is the script's: the panel is a renderer, so a large log
can never be read on the five-second tick and a terminal question and this
section can never disagree about what a duration is."
  (cerebro--run-async
   'fleet-history repo-root
   (list (expand-file-name (cerebro--script "fleet-history") repo-root) "--summary")
   (lambda (out)
     (funcall callback
              (and out
                   (let ((parsed (cerebro--try-parse-json out)))
                     (and (not (eq parsed cerebro--parse-failed))
                          ;; Wrapped, so "answered with nothing" survives the
                          ;; trip as distinct from "did not answer" - the
                          ;; caller keeps its last rows only for the latter.
                          (list parsed))))))))

(defun cerebro--finding-at-point ()
  "The sweep finding on this line, or nil."
  (get-text-property (line-beginning-position) 'cerebro-finding))

(defun cerebro--run-sweep-command (repo-root argv)
  "Run ARGV (program then args) in REPO-ROOT. Non-nil if it exited zero.

The one function through which `cerebro-sweep-act' ever runs a program -
kept this thin, and this named, so a test can stub exactly this and nothing
underneath it."
  (let ((default-directory (file-name-as-directory repo-root)))
    (zerop (apply #'call-process (car argv) nil nil nil (cdr argv)))))

(defun cerebro-sweep-act ()
  "Act on the sweep finding at point (`x'), after confirming the exact
command it is about to run.

`bd dolt push' rides the same confirmation: a close or reclaim the other
machines cannot see yet is only half done, and asking twice for one
keypress's worth of intent would be its own kind of noise."
  (interactive)
  (let ((finding (cerebro--finding-at-point)))
    (unless finding
      (user-error "cerebro: no sweep finding on this line"))
    (let* ((repo-root (cerebro--repo-root))
           (argv (cerebro--finding-command finding repo-root))
           (command-string (mapconcat #'identity argv " ")))
      (when (y-or-n-p (format "run: %s ? " command-string))
        (if (cerebro--run-sweep-command repo-root argv)
            (let ((pushed (cerebro--run-sweep-command repo-root (cerebro--bd-push-argv))))
              (cerebro--beads-render (current-buffer))
              (if pushed
                  (message "ran: %s" command-string)
                ;; The close/reclaim itself succeeded - only the push failed - so this
                ;; is not `user-error's "nothing happened", but the navigator still has
                ;; to know the other machines cannot see it yet.
                (message "ran: %s - but `bd dolt push' failed; other machines will not see this until it succeeds"
                         command-string)))
          (user-error "cerebro: %s failed" command-string))))))

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

(defcustom cerebro-wake-interval-default 600
  "Seconds a `waiting' interactive role is left alone before it is woken.

Cadence belongs to the fleet view, not to the role: a role writes `waiting'
with the interval it would like (`scripts/agent-state --wake-in\='), ends its
turn, and this poll decides when it actually comes back.  So changing a
role\='s cadence is this variable, changeable while the fleet runs, rather
than an edit to an agent document and a restarted session.

Ten minutes, from `scripts/fleet-history --summary\=' over the fleet\='s own
`idle\=' intervals rather than from the number the prose used to carry: Moira
41 intervals, median 10.2 min; Xavier 10.6; Cypher\='s and the planners\='
prose asked for ten.  The measurement\='s real finding is the spread - Moira\='s
longest self-scheduled idle was 30.2 minutes against a nominal ten, which is
the drift a self-timing agent produces and this poll removes."
  :type 'integer
  :group 'cerebro)

(defcustom cerebro-wake-intervals '(("verifier" . 300))
  "Overrides of `cerebro-wake-interval-default\=', as (KEY . SECONDS).

KEY is a role or an agent name, and a name-keyed entry wins over a
role-keyed one - most-specific-first, the way `models.conf\=' resolves a
model.  Roles come from `scripts/roster\=', so a role key holds for whatever
a consumer calls the agent that fills it.

The verifier alone, at five minutes: Psylocke\='s own prose asks for five, and
the log agrees - 90 idle intervals, median 4.7 min - because a bead can
merge, wait and still be waiting when the navigator asks what happened to
it.  Every other role measured at ten and takes the default.  It was keyed
on the name \"Psylocke\" until ah-qled.9, which is a name a consumer\='s fleet
need not have."
  :type '(alist :key-type string :value-type integer)
  :group 'cerebro)

(defcustom cerebro-poke-grace 60
  "Seconds to wait for a poked role to answer before poking it a second time.

Acknowledgement is free and needs no protocol: a role that woke writes its
next transition, so one still `waiting\=' on the same `wake_at\=' after this
long has not answered.  Sixty seconds is ample for a session that is, by
construction, sitting at its prompt."
  :type 'integer
  :group 'cerebro)

(defun cerebro-wake-interval (name &optional role)
  "Seconds the agent called NAME, filling ROLE, may wait before it is woken.

NAME first, then ROLE, then `cerebro-wake-interval-default\=': the more
specific key wins, so a fleet that wants one agent on a different cadence
from the rest of its role says so by name."
  (or (cdr (assoc name cerebro-wake-intervals))
      (and role (cdr (assoc role cerebro-wake-intervals)))
      cerebro-wake-interval-default))

(defun cerebro--wake-due-p (agent now)
  "Pure.  Whether AGENT, a `waiting\=' role, should be woken at NOW.

Due when either the role\='s own `wake_at\=' has passed or `since\=' plus this
name\='s `cerebro-wake-interval\=' has - whichever comes first.  The role asks;
the monitor decides, and may decide sooner, which is what makes the
`defcustom\=' authoritative without an agent document being edited.

Nil when neither timestamp parses.  A torn state file must not read as a
deadline that has expired, for the same reason an unparseable `since\=' does
not nudge an `asking\=' implementer: a poke lands as keystrokes in a live
session."
  (let* ((asked (cerebro--seconds-until (cerebro-agent-wake-at agent) now))
         (waited (cerebro--seconds-since (cerebro-agent-since agent) now))
         (interval (cerebro-wake-interval (cerebro-agent-name agent)
                                          (cerebro-agent-role agent))))
    (and (or (and asked (<= asked 0))
             (and waited (>= waited interval)))
         t)))

(defun cerebro--poke-decision (record wake-key now)
  "Pure.  `send\=', nil (wait) or `surface\=' for a role whose wake is due.

RECORD is what the poll remembers about the last poke for this agent -
\(WAKE-KEY SENT-AT COUNT), or nil for none - and WAKE-KEY identifies the wake
being answered, so a role that woke, worked and waited again is a fresh wake
rather than a continuation of one it already answered.

The poke cannot fail loudly - it is keystrokes typed into a terminal - so it
is bounded instead: send once, re-send once after `cerebro-poke-grace\=', then
stop and let the fleet view say so.  A poke repeated on every five-second
tick is an infinite loop nobody sees, and it buries the output of the very
session it is trying to wake."
  (cond
   ((or (null record) (not (equal (nth 0 record) wake-key))) 'send)
   ((>= (nth 2 record) 2) 'surface)
   (t (let ((since-sent (cerebro--seconds-since (nth 1 record) now)))
        (and since-sent (>= since-sent cerebro-poke-grace) 'send)))))

(defun cerebro--supervise-action (agent stop-flag-p now)
  "What the fleet poll should do about AGENT at NOW, or nil for nothing.

STOP-FLAG-P is whether `.cerebro/state/<name>.stop' exists.  The
answers are:

`restart' - AGENT finished its bead.  An interactive session cannot end
            itself the way a `--print' one did, so Emacs ends it and starts
            a fresh one, which is what keeps a session to one bead and its
            context free of every bead before it.
`retire'  - AGENT finished its bead and a stop flag says do not start
            another; or AGENT is `idle' under a stop flag - nothing is in
            flight, so nothing is stranded by ending it now, and the flag
            means *stop now* rather than *finish* (ah-ymn).  This is what
            makes `f' - and Cerebro's own `touch' - mean the same thing on an
            idle implementer as on a working one: no further bead.  Note the
            flag is only ever read here, with the bead already merged and
            closed (or with none in flight at all): taking an implementer
            down mid-bead strands a claim, a worktree and an open PR, so a
            stop on a working one means *finish*, not *stop now*.  The flag
            is removed as it retires (ah-kgc), so the next session started
            under that name does not inherit an instruction meant for this
            one.
`nudge'   - AGENT has waited past `cerebro-answer-timeout' for an answer.
`poke'    - AGENT is an interactive role in `waiting' whose wake is due
            (ah-hiib.3).  The roles no longer sleep inside their own
            sessions: one finishes a pass, writes `waiting' and ends its
            turn, and this poll is what brings it back.  Interactive-only,
            and the exact mirror of the three above - an implementer is
            replaced between beads and has no cadence of its own.

Only a session Emacs itself started is supervised.  One running in
somebody's own terminal is theirs to end, and a dead one stays dead -
restarting it would fight the navigator's own `k'.

The `kind' guard is load-bearing now that the interactive agents write the
same state file an implementer does (ah-2n3.2): Xavier, Cerebro, Moira,
Psylocke and Forge can show `asking' or, if one ever writes it in error,
`unknown', but never `restart'ed, `retire'd or `nudge'd from here - they are
never replaced between beads because they have none.

Since ah-hiib.3 that guard is *per-arm* rather than wrapped round the whole
body, because `poke' is the one answer that belongs to the interactive roles
alone.  The warning it used to carry still stands and is now the reason for
the shape: `restart', `retire' and `nudge' name an implementer's kind
explicitly, so unifying this function cannot let a planner be restarted
mid-mockup-conversation by accident.  Being external still excludes
everything: every answer here ends in Emacs acting on a session it owns."
  (unless (cerebro-agent-external agent)
    (pcase (cerebro-agent-state agent)
      ('done (and (eq (cerebro-agent-kind agent) 'implementer)
                  (if stop-flag-p 'retire 'restart)))
      ('idle (and (eq (cerebro-agent-kind agent) 'implementer) stop-flag-p 'retire))
      ;; Nothing is in flight for a waiting role - no bead, no claim, no
      ;; worktree - so a stop flag lands cleanly and *now*, which is the
      ;; behaviour that was impossible while a role slept inside its own
      ;; session and the flag had no gap to land in.
      ('waiting
       (and (eq (cerebro-agent-kind agent) 'interactive)
            (cond (stop-flag-p 'retire)
                  ((cerebro--wake-due-p agent now) 'poke))))
      ('asking
       (let ((waited (cerebro--seconds-since (cerebro-agent-since agent) now)))
         ;; A stop flag makes no difference: the bead is still in flight, so
         ;; the question still needs an answer or a hand-back.
         (and (eq (cerebro-agent-kind agent) 'implementer)
              waited (>= waited cerebro-answer-timeout) 'nudge)))
      (_ nil))))

;;; ah-vcf.3: the pure start/kill/launch decisions

(defcustom cerebro-submodule-path ".claude/cerebro"
  "Where cerebro is mounted, relative to the consumer repository root.

Cerebro is consumed as a git submodule, and this is the one place its
mount point is written down: it is both where the launchers are found and
what `cerebro--repo-root\=' searches upwards for.  A consumer mounting it
at, say, \"vendor/cerebro\" sets this and needs nothing else.

`githooks/sync-if-changed.sh\=' carries the same assumption on the shell
side, and takes the path as an argument for it."
  :type 'string
  :group 'cerebro)

(defun cerebro--script-directory ()
  "Where the launchers live, relative to the consumer repository root.

The launchers moved into the submodule with the agents and skills they
start.  A bare \"scripts/launch\" would resolve to the consumer\'s own
scripts directory, which no longer has one."
  (concat cerebro-submodule-path "/scripts"))

(defun cerebro--script (name)
  "The path to launcher NAME, relative to the repository root."
  (concat (cerebro--script-directory) "/" name))

(defun cerebro--launch-command (agent)
  "The command that launches AGENT: `scripts/launch' and the agent's name,
for every kind - a role's launcher is no longer a fact this file knows."
  (list (cerebro--script "launch") (cerebro-agent-name agent)))

(defun cerebro--session-buffer-name (agent)
  "The vterm buffer name that holds AGENT's live session."
  (format "*fleet: %s*" (cerebro-agent-name agent)))

(defun cerebro--alive-p (agent)
  "Non-nil if AGENT's state means a session is up (interactive or implementer).

Alive is every state a session can be in except `dead' - including `asking'
and `done' (which the fleet poll replaces within about five seconds) and
`unknown' (a process is up; the view merely does not recognise what its
state file says it is doing). Anything narrower than that reintroduces the
`*fleet: <name>*<2>' bug: `s' on an `asking' or `done' implementer used to
read as \"not alive\" and start a second session over the first."
  (not (eq (cerebro-agent-state agent) 'dead)))

(defun cerebro--start-action (agent owned)
  "What `s' should do for AGENT, given OWNED session names.

One of `launch' (start a dead agent), `already-up' (an owned session is
already running) or `external' (a live session exists outside Emacs -
refuse rather than launch a second one).

Ownership is checked *before* the derived state, not after: `cerebro--session'
is the one place liveness is decided now, so no gap in how a state is
derived can start a second session over one this Emacs holds (ah-u3i's
`*fleet: <name>*<2>' double session)."
  (cond
   ((member (cerebro-agent-name agent) owned) 'already-up)
   ((not (cerebro--alive-p agent)) 'launch)
   (t 'external)))

(defun cerebro--start-clears-flag-p (agent flag-set)
  "Whether starting AGENT should first remove its stop flag.

Only an implementer has one; a flag on a name being started is stale by
definition (ah-kgc): the navigator is saying it should run."
  (and flag-set (eq (cerebro-agent-kind agent) 'implementer)))

(defun cerebro--kill-action (agent owned)
  "What `k' should do for AGENT, given OWNED session names.

One of `kill' (plain confirm), `kill-working' (an implementer mid-bead -
harder confirm), `external' (refuse - not ours to stop) or `dead'
(refuse - nothing to kill)."
  (cond
   ((not (cerebro--alive-p agent)) 'dead)
   ((not (member (cerebro-agent-name agent) owned)) 'external)
   ((and (eq (cerebro-agent-kind agent) 'implementer)
         (cerebro--in-flight-p (cerebro-agent-state agent)))
    'kill-working)
   (t 'kill)))

(defun cerebro--finish-action (agent flag-set)
  "What `f' should do for AGENT given FLAG-SET.

One of `not-implementer' (an interactive agent has no bead to finish
and no flag to write), `offer-clear' (flag already set - ask before removing
it, which is the cheap way back to \"actually, keep going\"; checked ahead of
every state below, since a stale flag is worth offering to clear whatever
AGENT is doing now), `dead' (nothing is running - there is nothing to finish
and writing a flag would lie about that, ah-ymn), `external' (idle, but
running outside Emacs - the poll that would act on a flag never touches it,
so writing one would sit unread and unmarked, ah-ymn), `stop-now' (idle -
nothing is in flight, so the flag means *stop now* rather than *finish*,
ah-ymn) or `write' (a bead is in flight - tell it to finish, and it stops
once that bead is done)."
  (cond
   ((not (eq (cerebro-agent-kind agent) 'implementer)) 'not-implementer)
   (flag-set 'offer-clear)
   ((not (cerebro--alive-p agent)) 'dead)
   ((and (eq (cerebro-agent-state agent) 'idle)
         (cerebro-agent-external agent)) 'external)
   ((eq (cerebro-agent-state agent) 'idle) 'stop-now)
   (t 'write)))

(defvar cerebro--last-exit nil
  "Alist of NAME -> the last non-blank line an abnormally-exited session
printed, for every name whose session has died since Emacs started.

Global, not buffer-local: `cerebro--note-exit' runs from vterm's process
sentinel, which may not have the fleet buffer current, and the placeholder
is built from whatever agent is being shown, not from any one buffer.
Cleared for a name by `cerebro--launch' the moment a new session for it is
started, so a stale line never survives past the run that produced it.")

(defun cerebro--placeholder (agent)
  "The detail-window text for AGENT when it has no live view.

A dead agent with a recorded abnormal exit (`cerebro--last-exit') shows the
last line its session printed, so a launcher that refuses - `claude'
missing, an un-synced submodule - leaves something readable behind rather
than the row going `up' for a moment and then silently `dead' (ah-bri)."
  (let* ((name (cerebro-agent-name agent))
         (last (alist-get name cerebro--last-exit nil nil #'equal)))
    (cond
     ((cerebro-agent-external agent)
      (format "%s is running outside Emacs - no live view. Use the terminal that started it."
              name))
     (last
      (format "%s is not running.\nIts last session ended with:\n  %s\nPress s to start it."
              name last))
     (t (format "%s is not running. Press s to start it." name)))))

;;; Sweep findings (ah-4ao): turning `sweep-claims.sh'/`sweep-epics.sh' facts into a decision

(defcustom cerebro-sweep-stale-minutes 10
  "Minutes past which a claim's delivery, or an epic's last child close, is
old enough to act on rather than mid-cleanup.

Matches `agents/orchestrator.md's own claims and epics sweeps: an
implementer closes what it just finished within seconds, so anything
fresher than this is an agent still tidying up, not one that is gone.

This project's number, not a universal: a consumer whose implementers tidy
up more slowly wants a larger one."
  :type 'integer
  :group 'cerebro)

(defun cerebro--claim-finding (candidate live-names now)
  "Pure. What the claims sweep should offer for CANDIDATE, or nil.

CANDIDATE is one parsed object from `sweep-claims.sh --json'. LIVE-NAMES is
the implementer names with a live session (from the state files the fleet
view already gathers - `cerebro--gather-states'). NOW is unused by the
guards themselves (which key on `commit_age_min' and `lease_age_min',
computed by the script at the moment it ran) but taken for symmetry with
`cerebro--supervise-action' and so a future guard can use it without
changing every caller.

Returns nil (leave it alone), (close ID REASON), or (reclaim ID). Nil
covers four cases: a live session still holds it; a `verification:failed'
label makes `on_main' meaningless; the delivering commit is too fresh to be
sure the implementer has finished tidying up; or nothing is on main but the
lease has not been expired long enough to call the claim dead.

The last of those is not a detail: `assignee' not being in LIVE-NAMES means
only that no roster session's pid is holding this claim - it is exactly as
true of a claim the navigator is holding by hand as of one a crashed
implementer left behind, and `agents/orchestrator.md's own rule for telling
them apart is the lease, not the name. `lease_age_min' mirrors `bd reclaim
--id <id> --older-than 10m's own window for that reason: a finding this
function offers and the command it maps to must agree on what counts as
dead, or a confirmed `reclaim' could still be refused by `bd' - or worse,
accepted, on a claim that was never actually abandoned."
  (ignore now)
  (let-alist candidate
    (cond
     (.verification_failed nil)
     ((member .assignee live-names) nil)
     (.on_main
      (if (and .commit_age_min (> .commit_age_min cerebro-sweep-stale-minutes))
          (list 'close .id
                (format "Delivered in PR; closed by the fleet view, %s did not" .assignee))
        nil))
     ((and .lease_age_min (> .lease_age_min cerebro-sweep-stale-minutes))
      (list 'reclaim .id))
     (t nil))))

(defun cerebro--epic-finding (candidate)
  "Pure. What the epics sweep should offer for CANDIDATE, or nil.

CANDIDATE is one parsed object from `sweep-epics.sh --json' - already
known eligible (every child closed) by the script's own `bd epic status
--eligible-only'. The only question left here is staleness: nil when
`minutes_since_last_child_closed' is absent (nothing to act on) or under
`cerebro-sweep-stale-minutes' (an implementer is still mid-cleanup),
otherwise (epic-close ID)."
  (let-alist candidate
    (if (and .minutes_since_last_child_closed
             (> .minutes_since_last_child_closed cerebro-sweep-stale-minutes))
        (list 'epic-close .id)
      nil)))

(defcustom cerebro-stalled-minutes 60
  "Minutes without a commit past which a claim is offered as stalled.

Empirical, not chosen (ah-4xm4): across the 72 hours to 2026-08-20 every
one of the 36 beads that ran cleanly made its first commit 6 to 36 minutes
after being claimed, and the four that parked sat 2.3 hours or more. Sixty
separates them with no false positive in that window - and it is well clear
of a long CI wait, which is the legitimate reason a working bead is quiet.

That measurement is this project's own, not a universal: a consumer whose
builds take an hour gets false stalled findings until this is raised."
  :type 'integer
  :group 'cerebro)

(defun cerebro--stalled-finding (candidate live-states now)
  "Pure. What the stalled sweep should offer for CANDIDATE, or nil.

CANDIDATE is one parsed object from `sweep-stalled.sh --json\='. LIVE-STATES
is an alist of (NAME . STATE-SYMBOL) for sessions whose pid is alive. NOW is
unused, taken for symmetry with `cerebro--claim-finding\='.

Returns nil or (unclaim ID). Nil covers four cases: nobody live holds it
\(a dead claim is the claims sweep\='s, not this one\='s); the session is
`asking\=', so it is blocked and has said so and `cerebro--supervise-action\='
already nudges it; there is no age to judge; or the age is inside the
threshold - which includes every bead sitting in CI.

Membership is tested with `assoc\=', not by the state being non-nil: a live
session whose state file carries no `state\=' key reaches here with a nil
state and must still count as live, or a half-written file would become a
finding against a working implementer."
  (ignore now)
  (let-alist candidate
    (let ((state (cdr (assoc .assignee live-states))))
      (cond
       ((null (assoc .assignee live-states)) nil)
       ((eq state 'asking) nil)
       ((null .progress_age_min) nil)
       ((> .progress_age_min cerebro-stalled-minutes) (list 'unclaim .id))
       (t nil)))))

(defcustom cerebro-stale-assignee-minutes 10
  "How long an open bead may carry an assignee no live session is on before
the sweep offers to clear it.

Ten minutes is one sweep cycle, so a bead is effectively seen twice before
it is offered - long enough that a claim in flight is never interrupted,
short enough that a stranded P0 surfaces on the next pass. Five would
surface on the very next cycle, at some risk of offering a bead an
implementer is a moment from claiming; thirty would only just have caught
ah-fjty, which sat 32 minutes."
  :type 'integer
  :group 'cerebro)

(defun cerebro--assignee-finding (candidate live-beads roster now)
  "Pure. What the assignee sweep should offer for CANDIDATE, or nil.

CANDIDATE is one parsed object from `sweep-assignees.sh --json\='. LIVE-BEADS
is an alist of (NAME . BEAD) for sessions whose pid is alive. ROSTER is the
implementer roster. NOW is unused, taken for symmetry with the other
findings.

Returns nil or (unassign ID PRIORITY). Nil covers four cases: the assignee
is not a roster name, so it was assigned by hand and is not ours to undo;
the session is alive and on this very bead, so it is about to claim it; the
bead was touched inside the grace period, so somebody may be attending to
it; or there is no age to judge.

Note what is absent: there is no \"the session is not alive\" arm, because
that case falls through to the offer and should. A roster session that is
not running cannot be about to claim anything.

PRIORITY rides in the finding because `cerebro--sweep-line\=' is given
nothing but the finding and needs it to shout for a P0."
  (ignore now)
  (let-alist candidate
    (cond
     ((not (member .assignee roster)) nil)
     ((equal (cdr (assoc .assignee live-beads)) .id) nil)
     ((null .age_min) nil)
     ((< .age_min cerebro-stale-assignee-minutes) nil)
     (t (list 'unassign .id .priority)))))

(defun cerebro--finding-command (finding repo-root)
  "The exact argv for FINDING, or nil for nil.

This function is the complete list of destructive commands the fleet view
can run - every other path to `bd close' or `bd reclaim' goes through a
sweep finding built by `cerebro--claim-finding' or `cerebro--epic-finding'
and then this. REPO-ROOT is accepted for symmetry with the rest of the
sweep pipeline; the command itself carries no path, since it is run with
`default-directory' already bound the way every other `bd' call here is."
  (ignore repo-root)
  (pcase finding
    ('nil nil)
    (`(close ,id ,reason) (list cerebro-bd-program "close" id "--reason" reason))
    (`(reclaim ,id) (list cerebro-bd-program "reclaim" "--id" id "--older-than" "10m"))
    (`(epic-close ,id) (list cerebro-bd-program "close" id))
    ;; `bd unclaim', not `bd reclaim --older-than': reclaim is for a claim whose
    ;; session is gone, and its window would refuse a bead whose lease is still
    ;; being heartbeated. This finding is about a session alive and not moving.
    (`(unclaim ,id) (list cerebro-bd-program "unclaim" id))
    ;; Clearing the field, not touching the status: the bead is already `open\='
    ;; and holds no lease, so there is nothing to unclaim or reclaim. This is
    ;; the whole write, and this arm is the only place it may live.
    (`(unassign ,id ,_priority) (list cerebro-bd-program "update" id "--assignee" ""))
    (_ (error "cerebro: no command for finding %S" finding))))

;;; Impure readers - each trivially small so everything above stays pure

(defun cerebro--repo-root ()
  "The repository root above `default-directory', or an error.
Located by `cerebro-submodule-path\=' (the submodule mount, present in
every consumer from clone time) rather than by `.cerebro/state', which
may not exist yet on a fresh machine - `agent-state' and
`cerebro--write-stop-flag' both create it on first write."
  (or (locate-dominating-file default-directory cerebro-submodule-path)
      (error "cerebro: no %s found above %s (see `cerebro-submodule-path')"
             cerebro-submodule-path default-directory)))

(defvar-local cerebro--fleet-cache nil
  "The parsed roster, once read; buffer-local so a revert does not re-shell out.")

(defun cerebro--fleet (repo-root)
  "The fleet as (NAME ROLE KIND) rows, via `scripts/roster' in REPO-ROOT."
  (or cerebro--fleet-cache
      (setq cerebro--fleet-cache
            (cerebro--parse-fleet
             (with-temp-buffer
               (call-process (expand-file-name (cerebro--script "roster") repo-root) nil t nil)
               (buffer-string))))))

(defun cerebro--roster (repo-root)                 ; keeps its name and both callers
  "The implementer names, in roster order."
  (cerebro--fleet-roster (cerebro--fleet repo-root)))

(defun cerebro--interactive-agents (repo-root)
  "The (NAME . ROLE) alist of interactive agents, in roster order."
  (cerebro--fleet-interactive (cerebro--fleet repo-root)))

(defun cerebro--state-file-path (repo-root name)
  "Where NAME's status file lives, matching `scripts/agent-state'."
  (expand-file-name (format ".cerebro/state/%s.state.json" name) repo-root))

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
  "The (NAME . parsed-state-json-or-nil) alist for every name in ROSTER.

ROSTER need not be only implementers - `cerebro--revert' passes it the
roster plus the interactive names, since ah-2n3.2 has all of them
writing the same file."
  (mapcar (lambda (name)
            (cons name (cerebro--read-state-file
                        (cerebro--state-file-path repo-root name))))
          roster))

(defun cerebro--session-alive-p (pid name)
  "Non-nil if PID is a live process and is NAME's own session.

Both halves matter. \"Does this pid exist\" was the whole test until a
`done' state file outlived its session by ten hours and the operating
system reused its pid for an unrelated daemon: the row read `done' - green,
and `s' refused it as \"running outside Emacs\" - for an agent that had not
been running since the night before. Pids are recycled, so a bare number is
not an identity; the launcher passes `--name <Name>' to every session
\(`scripts/launch'), which makes the process's own command line the proof
that this pid is still the one the file was written about.

Reads only the named pid's args, not the whole process list - this is asked
once per agent on every refresh, where `cerebro--system-args' is a scan the
fleet view deliberately caches."
  (let ((args (and pid (alist-get 'args (process-attributes pid)))))
    (and args (cerebro--name-in-args-p name (list args)) t)))

(defun cerebro--system-args ()
  "The command-line args string of every system process, as a list."
  (delq nil
        (mapcar (lambda (pid) (alist-get 'args (process-attributes pid)))
                (list-system-processes))))

(defvar cerebro-system-scan-seconds 30
  "How often the process list is scanned for interactive agents started
outside Emacs. A rare event, polled at the rate of a state file; the scan
itself is 75 ms of blocking work and was on the five-second tick.")

(defvar-local cerebro--system-args-cache nil
  "(ARGS . SCANNED-AT) from the last scan, per fleet buffer.")

(defun cerebro--cached-system-args (&optional now)
  "`cerebro--system-args', rescanned only when `cerebro-system-scan-seconds'
have passed. NOW is for tests."
  (let ((now (or now (float-time))))
    (if (and cerebro--system-args-cache
             (not (cerebro--due-p (cdr cerebro--system-args-cache)
                                  cerebro-system-scan-seconds now)))
        (car cerebro--system-args-cache)
      (let ((args (cerebro--system-args)))
        (setq cerebro--system-args-cache (cons args now))
        args))))

(defvar cerebro--sessions nil
  "The sessions this Emacs started: an alist of (NAME . BUFFER), one per agent.

The one record of ownership (ah-5pp).  It used to be inferred by matching
every buffer's name against `*fleet: NAME*', so a second launch for a name -
which vterm would call `*fleet: NAME*<2>' - made an agent nobody could see,
and four separate guards stood in front of that one failure.  Now
`cerebro--launch' writes here and refuses a second session while the first
is live, and everything that asks whose session it is, whether it is up,
or which buffer holds it, reads here.  Global, not buffer-local: sessions
outlive the fleet buffer, and `M-x cerebro' after a `q' must still know
what it started.")

(defun cerebro--session (name)
  "The live session buffer this Emacs started for NAME, or nil.

Live means the buffer exists and its process is running - the same test
`cerebro--owned' has always applied.  The table entry is pruned only when
the *buffer* itself is gone, not merely because its process exited - a
session whose shell has finished but whose buffer still exists (vterm
leaves it for the navigator to read) is not `live' here, but it is still
ours, and `cerebro--recorded-buffer' is what finds it so it can be cleaned
up rather than left to collide with the next launch."
  (let ((buffer (alist-get name cerebro--sessions nil nil #'equal)))
    (unless (and buffer (buffer-live-p buffer))
      (when buffer
        (setq cerebro--sessions (assoc-delete-all name cerebro--sessions))))
    (and buffer (buffer-live-p buffer) (get-buffer-process buffer) buffer)))

(defun cerebro--session-name (buffer)
  "The agent name whose session is BUFFER, or nil when it is not one of ours."
  (car (rassq buffer cerebro--sessions)))

(defun cerebro--recorded-buffer (name)
  "NAME's recorded session buffer, live or not, or nil.

Unlike `cerebro--session', this does not require a live process - a vterm
buffer whose shell has already exited stays around for the navigator to
read, and is still ours to kill.  Forgets a dead entry on the way past, the
same as `cerebro--session'."
  (let ((buffer (alist-get name cerebro--sessions nil nil #'equal)))
    (if (and buffer (buffer-live-p buffer))
        buffer
      (when buffer
        (setq cerebro--sessions (assoc-delete-all name cerebro--sessions)))
      nil)))

(defun cerebro--owned ()
  "Agent names whose sessions this Emacs itself started and which are still up."
  (delq nil (mapcar (lambda (entry) (and (cerebro--session (car entry)) (car entry)))
                     cerebro--sessions)))

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
      (setq buffer-read-only t)
      ;; It sits in the detail window like a session does, so TAB has to keep
      ;; working from it - otherwise the key dies on exactly the agents that
      ;; are not running.
      (cerebro-session-mode 1))
    buffer))

(defun cerebro--detail-showing-p (agent)
  "Non-nil when the detail window is live and shows AGENT's session buffer."
  (and cerebro--detail-window
       (window-live-p cerebro--detail-window)
       (let ((buffer (cerebro--session (cerebro-agent-name agent))))
         (and buffer (eq (window-buffer cerebro--detail-window) buffer)))))

(defun cerebro--show-detail (agent)
  "Put AGENT's live session, or a placeholder, in the detail window.

Returns the buffer chosen.  A session with no live buffer - should not
happen, `cerebro--session' is what `cerebro--owned' derives from too -
falls back to the placeholder rather than erroring."
  (let ((buffer (or (cerebro--session (cerebro-agent-name agent))
                     (cerebro--placeholder-buffer agent))))
    (when (and cerebro--detail-window (window-live-p cerebro--detail-window))
      (set-window-buffer cerebro--detail-window buffer))
    buffer))

;;; Launching and killing (ah-vcf.3)

;; vterm is a soft dependency (see `cerebro--launch'); these keep the
;; byte-compiler quiet about the symbols it only knows about once vterm is
;; actually loaded.
(defvar vterm-shell)
(declare-function vterm-mode "vterm" ())
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-return "vterm" ())
(declare-function vterm-send-tab "vterm" ())

(defun cerebro--make-session-buffer (name)
  "Create the vterm session buffer NAME, process running, shown in no window.

This is `vterm--internal' minus its `pop-to-buffer': `generate-new-buffer'
then `vterm-mode' in it, which starts the process from `vterm-shell'.
vterm is never given the chance to choose a window, so nothing has to be
taken back from it afterwards - no `display-buffer-overriding-action',
no `save-window-excursion', and one code path whoever the caller is.
The caller places the buffer, or does not: `cerebro-start' shows it in
the detail window through `cerebro--show-detail'; a restart shows it only
where the navigator was already watching.

`default-directory' reaches the session by inheritance: `generate-new-buffer'
copies it from the current buffer, which is why `cerebro--launch' let-binds
it before calling this.  Neither the selected window nor the current buffer
is changed.  Returns the buffer."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (vterm-mode))
    buffer))

(defun cerebro--launch (agent)
  "Create AGENT's vterm session and return its buffer.

`vterm-shell' is let-bound rather than set globally, so the navigator's
ordinary vterm shells are unaffected.  The session is created in no window
(`cerebro--make-session-buffer'); the caller decides where, if anywhere, it
is shown.

The let-bound `default-directory' reaches the session by inheritance:
`cerebro--make-session-buffer' calls `generate-new-buffer' while the fleet
buffer is still current, and the new buffer takes its `default-directory'
from there.

Hooks `cerebro--note-exit' onto `vterm-exit-functions' - globally and
idempotently, since vterm's sentinel (vterm.el) runs it with whatever buffer
happens to be current, not necessarily this one, so a buffer-local hook
would silently never fire (ah-bri). AGENT's name is cleared from
`cerebro--last-exit' before spawning, so a fresh run starts with no stale
line from the one before it.

The buffer is recorded in `cerebro--sessions', which is what makes it ours;
a name with a live session is refused here, whatever the derived state
believes about it (ah-5pp)."
  (when (cerebro--session (cerebro-agent-name agent))
    (error "cerebro: %s already has a live session" (cerebro-agent-name agent)))
  (unless (require 'vterm nil t)
    (user-error "cerebro needs vterm for live sessions - install emacs-libvterm"))
  (add-hook 'vterm-exit-functions #'cerebro--note-exit)
  (setq cerebro--last-exit
        (assoc-delete-all (cerebro-agent-name agent) cerebro--last-exit))
  (let* ((default-directory (cerebro--repo-root))
         (cmd (cerebro--launch-command agent))
         (vterm-shell (mapconcat #'shell-quote-argument cmd " "))
         (session-name (cerebro--session-buffer-name agent))
         (buffer (cerebro--make-session-buffer session-name)))
    (setf (alist-get (cerebro-agent-name agent) cerebro--sessions nil nil #'equal) buffer)
    ;; The navigator's quit guard: confirm before Emacs or a buffer kill
    ;; takes a live agent down.  vterm's own kill behaviour is tuned for
    ;; disposable shells and does not set this on its own.
    (let ((proc (get-buffer-process buffer)))
      (when proc (set-process-query-on-exit-flag proc t)))
    ;; TAB cycles out of here rather than reaching the shell; `C-c TAB' sends
    ;; a real one when the agent wants it.
    (with-current-buffer buffer (cerebro-session-mode 1))
    (when (eq (cerebro-agent-kind agent) 'implementer)
      ;; What was started, not what it will do: whether it claims straight away
      ;; is the launcher's behaviour, and an older `launch'
      ;; still waits on the retired `.go' flag first.  Promising a claim here
      ;; would make that look like a fault in the fleet view.
      (message "%s started - watch its state in the list"
               (cerebro-agent-name agent)))
    buffer))

;;; A session that dies before it gets going (ah-bri)

(defun cerebro--last-nonblank-line (text)
  "The last line of TEXT with anything but whitespace on it, trimmed; nil if none."
  (let ((lines (delq nil (mapcar (lambda (line)
                                    (let ((trimmed (string-trim line)))
                                      (and (not (string-empty-p trimmed)) trimmed)))
                                  (split-string text "\n")))))
    (car (last lines))))

(defun cerebro--exit-record (event last-line)
  "What to remember about a session exit, or nil.

EVENT is the sentinel string vterm hands `vterm-exit-functions'. Only an
abnormal exit is worth remembering - `finished' is a clean quit, `killed'
is `k' or the poll ending a session on purpose (ah-bri), and neither is a
failure to explain. Returns (CODE . LAST-LINE)."
  (and last-line
       (string-match "\\`exited abnormally with code \\([0-9]+\\)" event)
       (cons (match-string 1 event) last-line)))

(defconst cerebro--exit-tail-chars 4000
  "How far back from the end of a dying session's buffer to look for its
last line. A session that ran a while can hold megabytes of scrollback;
only the very end can possibly hold the line printed just before it died,
so `cerebro--note-exit' never reads more than this many characters of it.")

(defun cerebro--note-exit (buffer event)
  "Record BUFFER's last line in `cerebro--last-exit' when EVENT is abnormal.

The impure counterpart to `cerebro--exit-record' and
`cerebro--last-nonblank-line': reads the last `cerebro--exit-tail-chars' of
BUFFER's text (never the whole buffer - see there), finds the agent through
`cerebro--sessions' - not by the buffer's name - and updates the global
alist and the echo area. BUFFER can be nil - vterm's sentinel passes it
after the buffer itself has already been killed (`k', retire, restart) -
and a buffer that is not one of ours is left alone.

Reads `cerebro--session-name' rather than `cerebro--session': the sentinel
calls this after the process has already died, when `cerebro--session'
would already say the entry is gone and prune it before this ever saw the
name."
  (let ((name (and (buffer-live-p buffer)
                    (cerebro--session-name buffer))))
    (when name
      (let* ((text (with-current-buffer buffer
                      (buffer-substring-no-properties
                       (max (point-min) (- (point-max) cerebro--exit-tail-chars))
                       (point-max))))
             (record (cerebro--exit-record event (cerebro--last-nonblank-line text))))
        (when record
          (setf (alist-get name cerebro--last-exit nil nil #'equal) (cdr record))
          (message "%s exited (code %s): %s" name (car record) (cdr record)))))))

;;; Acting on the supervision decisions

(defvar-local cerebro--nudged nil
  "Names already told to give up on the question they are asking.

The poll runs every five seconds; without this the nudge would be typed
into the session on every tick, burying the agent's own output and
resetting what it was told.  A name leaves this set as soon as it is no
longer asking, so its next question is nudgeable again.")

(defvar-local cerebro--pokes nil
  "What the poll remembers about the pokes it has sent, as (NAME WAKE-KEY
SENT-AT COUNT).

A poke is keystrokes typed into a terminal and cannot report success, so
this is what bounds it: `cerebro--poke-decision\=' reads the record to send
once, re-send once after `cerebro-poke-grace\=', and then stop.  A name leaves
this the moment it is no longer `waiting\=' - which is the acknowledgement,
since a role that woke writes its next transition.")

(defvar-local cerebro--unanswered-pokes nil
  "Names of `waiting\=' roles that answered neither poke.

Shown as a \" !\" in the State column (`cerebro--entry\='), which is where a
poke stops: a line the navigator can see beats retrying every five seconds
for ever.  Cleared with the record above when the role transitions.")

(defun cerebro--stop-flag-path (repo-root name)
  "Where NAME's stop flag lives, as `orchestrator.md' documents it."
  (expand-file-name (format ".cerebro/state/%s.stop" name) repo-root))

(defun cerebro--stop-flag-p (repo-root name)
  "Whether a stop flag is set for NAME."
  (file-exists-p (cerebro--stop-flag-path repo-root name)))

(defconst cerebro--nudge-message
  (concat "[cerebro] Nobody answered within the timeout. Do not keep waiting: "
          "put the question and everything you have found into the work item, "
          "hand it back for a person to decide, exactly as your own instructions describe, "
          "and finish the run.")
  "What an interactive agent is told when its question goes unanswered.

It names neither a tracker label nor a skill, for the same reason
`cerebro--poke-message\=' names no pass: the words go into a live session, and
how a work item is handed back is the agent\='s own instructions to state, not
the fleet view\='s.  Saying it in cerebro\='s words would be a second, quieter
copy of a policy that must have exactly one owner.")

(defcustom cerebro-return-delay 0.3
  "Seconds between typing a line into a session and sending its return.

Sent together, they arrive in one terminal read, and a TUI that treats a
burst ending in a carriage return as a paste puts the newline in its
composer instead of submitting it - which leaves a woken agent sitting on
its own wake message.  Any separation at all is enough; the value is a
`defcustom\=' so a terminal that needs longer can be given it without
editing this file, which in a submodule would otherwise cost a pull request
and a pointer bump in every consumer."
  :type 'number
  :group 'cerebro)

(defun cerebro--type-into-session (agent message)
  "Type MESSAGE into AGENT\='s session, then send its return separately.

The return goes on a timer rather than immediately - see
`cerebro-return-delay\=' for why.  The buffer is re-checked when the timer
fires, because a session can be killed inside the delay, and
`vterm-send-return\=' is guarded there in its own right: the outer guard now
runs at a different time from the return.  Both `with-current-buffer\=' forms
are needed - a timer fires with no buffer current."
  (let ((buffer (cerebro--session (cerebro-agent-name agent))))
    (when (and buffer (fboundp 'vterm-send-string))
      (with-current-buffer buffer
        (vterm-send-string message))
      (run-at-time cerebro-return-delay nil
                   (lambda ()
                     (when (and (buffer-live-p buffer)
                                (fboundp 'vterm-send-return))
                       (with-current-buffer buffer
                         (vterm-send-return))))))))

(defun cerebro--nudge (agent)
  "Type `cerebro--nudge-message' into AGENT's session."
  (cerebro--type-into-session agent cerebro--nudge-message))

(defconst cerebro--poke-message
  (concat "[cerebro] Your wait is over - start your next pass now, "
          "exactly as your own instructions describe it.")
  "What a `waiting' role is told when its wake falls due.

It names nothing about *what* the pass is: cadence is the fleet view's and
policy stays in the role's own skill, which is the whole point of the split.

Typing into a vterm is a fragile channel in general - keystrokes arriving
mid-tool-call are a real failure mode - and `waiting' is precisely what makes
it safe here: a role in that state has ended its turn and is sitting at its
prompt by construction.  Only a `waiting' role is ever poked.")

(defun cerebro--poke (agent)
  "Type `cerebro--poke-message' into AGENT's session."
  (cerebro--type-into-session agent cerebro--poke-message))

(defun cerebro--forget-session (agent)
  "Kill AGENT's session buffer, without asking and without refreshing.

The query-on-exit flag guards an *accidental* kill; this one is the poll
acting on a bead the agent itself reported finished.  Looks up the buffer
via `cerebro--recorded-buffer', not `cerebro--session': a session whose
process has already exited still has a buffer to clean up, and requiring a
live process here would leave it for the next launch to collide with.
Forgets the entry in `cerebro--sessions' too, so a launch right
afterwards - a restart - sees no session even before the process sentinel
has run."
  (let ((name (cerebro-agent-name agent)))
    (let ((buffer (cerebro--recorded-buffer name)))
      (when buffer
        (let ((proc (get-buffer-process buffer)))
          (when proc (set-process-query-on-exit-flag proc nil)))
        (kill-buffer buffer)))
    (setq cerebro--sessions (assoc-delete-all name cerebro--sessions))))

(defun cerebro--end-session (agent repo-root &optional clear-stop-flag)
  "End AGENT's session and remove every per-session artifact it leaves behind.

Buffer and `cerebro--sessions' entry always (`cerebro--forget-session');
the state file always, because a file naming a session that has been ended
is a claim about a pid that no longer exists and pids are recycled (see
`cerebro--session-alive-p'); the stop flag only when CLEAR-STOP-FLAG, since
only a retire has finished with the instruction.

This is the one owner of ending a session: every artifact a session leaves
is removed here or nowhere, so a fourth call site cannot be added
half-right - which is how the same omission came to be fixed twice, in the
two `cerebro--supervise' branches only, while `k' kept leaking a state file.

CLEAR-STOP-FLAG stays explicit rather than inferred from the state: a flag
written between a restart being decided and this running is the navigator
pressing `f', and swallowing it silently is the inherited-instruction bug
with the sign reversed."
  (let ((name (cerebro-agent-name agent)))
    (cerebro--forget-session agent)
    (cerebro--delete-state-file repo-root name)
    (when clear-stop-flag (cerebro--clear-stop-flag repo-root name))))

(defun cerebro--supervise (agents repo-root now)
  "Act on what `cerebro--supervise-action' says about each of AGENTS.

Errors are demoted: this runs from a timer, and one agent whose session
cannot be replaced must not stop the fleet view refreshing or take the
other agents down with it."
  (dolist (agent agents)
    (let ((name (cerebro-agent-name agent)))
      (unless (eq (cerebro-agent-state agent) 'asking)
        (setq cerebro--nudged (delete name cerebro--nudged)))
      ;; The role's own next transition is the acknowledgement, so leaving
      ;; `waiting' is what clears both the poke record and the mark.
      (unless (eq (cerebro-agent-state agent) 'waiting)
        (setq cerebro--pokes (assoc-delete-all name cerebro--pokes))
        (setq cerebro--unanswered-pokes (delete name cerebro--unanswered-pokes)))
      (with-demoted-errors "cerebro: %S"
        (pcase (cerebro--supervise-action agent (cerebro--stop-flag-p repo-root name) now)
          ;; Kill before launching: `cerebro--launch' would refuse a second
          ;; session for a name it still holds, rather than making one vterm
          ;; would call `*fleet: <name>*<2>' and the list would never show.
          ;; Both branches end a session, so both take its state file with
          ;; them (`cerebro--delete-state-file'). On a restart the deletion
          ;; must come before the launch: the file is the *previous*
          ;; session's, and the fresh one under the same name would otherwise
          ;; be read as the finished session it replaced and restarted again.
          ('restart (let ((watching (cerebro--detail-showing-p agent)))
                      (cerebro--end-session agent repo-root)
                      (cerebro--launch agent)
                      (when watching (cerebro--show-detail agent))))
          ('retire (cerebro--end-session agent repo-root 'clear-stop-flag))
          ('nudge (unless (member name cerebro--nudged)
                    (push name cerebro--nudged)
                    (cerebro--nudge agent)))
          ('poke
           (let* ((wake-key (or (cerebro-agent-wake-at agent)
                                (cerebro-agent-since agent)))
                  (record (cdr (assoc name cerebro--pokes))))
             (pcase (cerebro--poke-decision record wake-key now)
               ('send
                (let ((count (if (equal (nth 0 record) wake-key) (1+ (nth 2 record)) 1)))
                  (setf (alist-get name cerebro--pokes nil nil #'equal)
                        (list wake-key (format-time-string "%Y-%m-%dT%H:%M:%SZ" now t) count))
                  (cerebro--poke agent)))
               ('surface
                (unless (member name cerebro--unanswered-pokes)
                  (push name cerebro--unanswered-pokes)
                  (message "%s did not answer its wake - poke it by hand, or `k' and `s' it"
                           name)))))))))))

;;; Reading the beads

(defconst cerebro-beads-buffer-name "*cerebro-beads*")

(defvar cerebro-beads-refresh-seconds 30
  "How often the bead panel re-runs `bd'.

Slower than the five-second agent tick on purpose. Beads move on human
timescales - a claim, a plan, a merge are minutes apart - and each refresh
is three subprocesses, so a five-second cadence would buy nothing but load.
`g' refreshes on demand.")

(defun cerebro--bd-push-argv ()
  "The argv for pushing the bead database to its remote.

`dolt push\=' is a beads feature rather than a project fact, so only the
program is configurable here."
  (list cerebro-bd-program "dolt" "push"))

(defun cerebro--bd-list-argv ()
  "The one `bd' call the panel is drawn from. `--brief' drops the free-form
text nothing here renders (1.95 MB to 199 KB on this backlog); every status
by name and no `--exclude-type', as before - the partition is only complete
if the list it partitions is."
  (list cerebro-bd-program "list" "--status"
        "open,in_progress,blocked,deferred,closed" "--json" "--brief"))

(defun cerebro--request-beads (repo-root callback)
  "Ask `bd' for the panel's beads without blocking; CALLBACK gets the four
partition lists (see `cerebro--partition-beads') when the answer lands, or
nil when `bd' did not answer - including `bd' exiting zero but printing
something that is not JSON, which is not a valid empty answer either.
Returns what `cerebro--run-async' returns."
  (cerebro--run-async
   'beads repo-root (cerebro--bd-list-argv)
   (lambda (out)
     (funcall callback
              (and out
                   (let ((parsed (cerebro--try-parse-json out)))
                     (and (not (eq parsed cerebro--parse-failed))
                          (cerebro--partition-beads parsed))))))))

(defun cerebro--bd-text (repo-root id)
  "The output of `bd show ID' run in REPO-ROOT, or nil if it failed.

Text rather than `--json': this goes in front of the navigator, and `bd's
own rendering already lays a bead out to be read.  It wraps at eighty
columns off a tty and ignores COLUMNS, so the detail window gets eighty
columns of bead however wide it is."
  (condition-case nil
      (with-temp-buffer
        (let ((default-directory (file-name-as-directory repo-root)))
          (when (zerop (call-process cerebro-bd-program nil t nil "show" id))
            (buffer-string))))
    (error nil)))

(defun cerebro--sort-recent (beads)
  "BEADS newest first, by `updated_at'.

Finished work does not sort by priority - a merged P3 is no less done than a
merged P0 - so these sections answer \"what just happened\" instead."
  (sort (copy-sequence beads)
        (lambda (a b)
          (string> (or (alist-get 'updated_at a) "")
                   (or (alist-get 'updated_at b) "")))))

(defcustom cerebro-verification-settled '("verification:passed" "verification:not-needed")
  "Labels meaning a merged bead needs nothing further from anybody.

`verification:passed' is a human having checked it; `not-needed' is the
navigator having ruled it out of scope - the cutoff for work predating the
role. Different reasons, same consequence for a queue, so the panel groups
them under Verified.

Note this is deliberately NOT how `agents/user-feedback.md' talks to a
reporter: there a `not-needed' bead never shows VERIFIED, because nobody
confirmed anything. The word means \"a person checked it\" on an issue
thread, and \"nothing left to do\" here.

This project's label vocabulary; a consumer that settles verification some
other way sets its own here."
  :type '(repeat string)
  :group 'cerebro)

(defun cerebro--bead-labels (bead)
  "The labels on BEAD, as a list of strings."
  (alist-get 'labels bead))

(defun cerebro--settled-p (bead)
  "Whether BEAD carries a label that closes the verification question."
  (cl-some (lambda (label) (member label cerebro-verification-settled))
           (cerebro--bead-labels bead)))

(defcustom cerebro-skipped-issue-types '("epic" "event")
  "Issue types that are bookkeeping rather than work, and so never shown.
The shell has the same list, in `scripts/work-beads', which is where the
reasoning is written down for every reader of closed beads (ah-cg1);
`cerebro-test/the-panel-skips-exactly-what-work-beads-excludes' holds the
two to each other - so both sides move together."
  :type '(repeat string)
  :group 'cerebro)

(defcustom cerebro-planned-label "planned"
  "The label meaning a bead has a plan and an implementer may claim it.

This project's word for it; the panel's Planned section is whatever a
consumer calls the same thing."
  :type 'string
  :group 'cerebro)

(defcustom cerebro-planning-label "planning"
  "The PREFIX of the label a planner holds a bead under while it writes the plan.

Open, unclaimable by anybody else, and shown in its own section rather
than among the unplanned backlog.

A prefix rather than the whole label, because a planner names its hold
after itself - `planning:<name>' - so that a session finishing its own
bead cannot strip a label another session set.  The bare word is still a
hold: both spellings are live at once, since a session started before the
named one existed keeps writing the bare label."
  :type 'string
  :group 'cerebro)

(defun cerebro--holding-label-p (labels)
  "Non-nil when LABELS carries a planner's hold.

A hold is the bare word, or the word followed by `:' and the planner
holding it - `planning:Xavier'.  The separator is required rather than a
bare prefix, so an unrelated label that merely starts with the same
letters is not mistaken for somebody holding the bead; `planner:<name>',
which names who plans a family rather than who is holding one bead, is
excluded by that and by diverging from the word anyway."
  (let ((held (concat cerebro-planning-label ":")))
    (seq-some (lambda (label)
                (or (equal label cerebro-planning-label)
                    (string-prefix-p held label)))
              labels)))

(defun cerebro--partition-beads (beads)
  "Split BEADS into the five lists the panel shows.

\(CLAIMED PLANNED BEING-PLANNED UNPLANNED MERGED), where merged means merged
and not yet verified, and BEING-PLANNED is what a planner is holding right
now - open, labelled `planning', and not claimable by anybody until the plan
lands (ah-2p.2).  Not every bead lands in one, deliberately: verified work is
finished, epics are parents rather than work, bd's own `event' records are
bookkeeping, and blocked or deferred beads cannot be picked up.  A panel is
a list of what to do about something, so what there is nothing to do about
is left out.

It still partitions one list rather than running a query per section, which
is what keeps those exclusions in one readable place instead of spread
across five `bd' invocations - an `event' in particular carries the very
labels these rules key on, and would otherwise arrive looking like merged
work."
  (let (claimed planned being-planned unplanned merged)
    (dolist (bead beads)
      (let ((status (alist-get 'status bead)))
        (cond
         ;; Not work, and so not shown: an epic is a parent with children, and
         ;; an `event' is bd's own audit record of a state change ("State
         ;; change: verification -> passed"). An event carries the very labels
         ;; these rules key on, so without this three of them appeared as
         ;; merged work - one per verification ever recorded.
         ;; `scripts/work-beads' owns the same list on the shell side.
         ((member (alist-get 'issue_type bead) cerebro-skipped-issue-types) nil)
         ((equal status "in_progress") (push bead claimed))
         ((equal status "open")
          (let ((labels (cerebro--bead-labels bead)))
            (cond
             ;; `planned' first, and deliberately: `bd update --add-label
             ;; planned --remove-label planning' is one call, but a bead read
             ;; mid-write - or left behind by a planner that forgot the
             ;; removal - carries both. Pickable wins, because an implementer
             ;; can claim it whatever else the bead says.
             ((member cerebro-planned-label labels) (push bead planned))
             ((cerebro--holding-label-p labels) (push bead being-planned))
             (t (push bead unplanned)))))
         ((equal status "closed")
          ;; Settled means nothing further is wanted from anybody - verified
          ;; by a person, or ruled out of scope. Finished, so not here.
          (unless (cerebro--settled-p bead) (push bead merged)))
         ;; Blocked, deferred, or a status from a future bd: real beads, but
         ;; nothing the fleet can pick up today.
         (t nil))))
    (list (nreverse claimed) (nreverse planned) (nreverse being-planned)
          (nreverse unplanned) (nreverse merged))))

(defcustom cerebro-priority-floor 4
  "The least urgent priority `bd\=' takes; 0 is the most urgent.

This project's backlog floor: a consumer whose tracker ranks differently
sets its own."
  :type 'integer
  :group 'cerebro)

(defun cerebro--nudged-priority (priority delta)
  "PRIORITY moved by DELTA, clamped to the range `bd' accepts.

Clamped rather than wrapped: holding `+' should stop at the backlog floor,
not roll a bead round to P0."
  (min cerebro-priority-floor (max 0 (+ priority delta))))

(defun cerebro--bd-set-priority (repo-root id priority)
  "Set ID's priority to PRIORITY in REPO-ROOT.  Non-nil if `bd' accepted it."
  (condition-case nil
      (with-temp-buffer
        (let ((default-directory (file-name-as-directory repo-root)))
          (zerop (call-process cerebro-bd-program nil t nil "update" id
                               "--priority" (number-to-string priority)))))
    (error nil)))

(defun cerebro--layout-detail-window ()
  "The layout's detail window, or nil.

`cerebro--detail-window' is buffer-local to the fleet buffer, and the panel
is a different buffer - so this reads it from there rather than keeping a
second copy that could disagree with the first."
  (let ((fleet (get-buffer cerebro-buffer-name)))
    (when fleet
      (let ((window (buffer-local-value 'cerebro--detail-window fleet)))
        (and (window-live-p window) window)))))

(defconst cerebro-bead-buffer-name "*cerebro-bead*")

(defvar cerebro-bead-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'cerebro-other-window)
    (define-key map (kbd "<tab>") #'cerebro-other-window)
    map)
  "Keymap for `cerebro-bead-mode'.")

(define-derived-mode cerebro-bead-mode special-mode "Cerebro Bead"
  "One bead, as `bd show' renders it.")

(defun cerebro-beads-show ()
  "Show the marked bead in the detail window (`RET').

One buffer, reused: the navigator is reading one bead at a time, and a
buffer per bead would leave a drift of them behind a morning's browsing."
  (interactive)
  (let ((id (cerebro--bead-at-point)))
    (unless id
      (user-error "cerebro: no bead on this line"))
    (let ((text (cerebro--bd-text (cerebro--repo-root) id))
          (buffer (get-buffer-create cerebro-bead-buffer-name))
          (window (cerebro--layout-detail-window)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'cerebro-bead-mode) (cerebro-bead-mode))
        (let ((inhibit-read-only t))
          (erase-buffer)
          ;; Say which bead could not be shown rather than leaving an empty
          ;; buffer, which reads as a key that did nothing.
          (insert (or text (format "%s: could not be shown.\n\nbd show %s failed - it may have been closed, or bd may be unavailable here.\n"
                                   id id))))
        (setq buffer-read-only t)
        (goto-char (point-min)))
      (if window
          (set-window-buffer window buffer)
        ;; No layout - `M-x cerebro-beads-show' from a stray panel. Put it
        ;; somewhere rather than doing nothing visible.
        (display-buffer buffer))
      buffer)))

(defvar-local cerebro--last-priority-change nil
  "The last priority this panel changed, as (ID . PREVIOUS-PRIORITY).

One step, because the case it exists for is a mis-keyed digit: the change is
immediate and the only notice is a line in the echo area.")

(defun cerebro--priority-at-point ()
  "The priority of the bead on this line, or nil if it is not a bead."
  (get-text-property (line-beginning-position) 'cerebro-priority))

(defun cerebro--set-priority (id from to)
  "Ask `bd' to move ID from FROM to TO, then redraw and say what happened."
  (unless (cerebro--bd-set-priority (cerebro--repo-root) id to)
    (user-error "cerebro: bd would not set %s to P%d" id to))
  (setq cerebro--last-priority-change (cons id from))
  (cerebro--beads-render (current-buffer))
  (message "%s: P%s -> P%d" id (if from (number-to-string from) "?") to))

(defun cerebro-beads-set-priority (priority)
  "Set the marked bead's priority to PRIORITY, one of 0 to 4."
  (interactive)
  (let ((id (cerebro--bead-at-point))
        (current (cerebro--priority-at-point)))
    (unless id
      (user-error "cerebro: no bead on this line"))
    (if (equal current priority)
        ;; Not a failure, but not a change either - and a keypress that did
        ;; nothing must not leave an undo entry claiming it did.
        (message "%s is already P%d" id priority)
      (cerebro--set-priority id current priority))))

(defun cerebro-beads-raise ()
  "Make the marked bead one step more urgent (`+')."
  (interactive)
  (let ((current (cerebro--priority-at-point)))
    (unless current (user-error "cerebro: no bead on this line"))
    (cerebro-beads-set-priority (cerebro--nudged-priority current -1))))

(defun cerebro-beads-lower ()
  "Make the marked bead one step less urgent (`-')."
  (interactive)
  (let ((current (cerebro--priority-at-point)))
    (unless current (user-error "cerebro: no bead on this line"))
    (cerebro-beads-set-priority (cerebro--nudged-priority current 1))))

(defun cerebro-beads-undo-priority ()
  "Put back the priority this panel last changed (`u')."
  (interactive)
  (let ((change cerebro--last-priority-change))
    (unless change
      (user-error "cerebro: no priority change to undo"))
    (let ((id (car change))
          (previous (cdr change)))
      (unless (cerebro--bd-set-priority (cerebro--repo-root) id previous)
        (user-error "cerebro: bd would not put %s back to P%s" id previous))
      ;; Spent: one step back, not a stack, so a second `u' has nothing to do
      ;; rather than quietly redoing the change.
      (setq cerebro--last-priority-change nil)
      (cerebro--beads-render (current-buffer))
      (message "%s: back to P%s" id previous))))

(defun cerebro--panel-width (buffer)
  "Columns to render BUFFER's panel into.

Its own window when it has one, and the width the layout gives it otherwise.
`window-width' with no window falls back to the *selected* one, which during
a timer refresh is wherever the navigator happens to be standing - so the
panel would be laid out to the width of the detail window."
  (let ((window (get-buffer-window buffer)))
    (max 30 (if window (window-width window) cerebro-list-width))))

(defun cerebro--bead-at-point ()
  "The id of the bead on this line, or nil on a header, blank or \"(none)\"."
  (get-text-property (line-beginning-position) 'cerebro-bead))

(defun cerebro--goto-bead (id)
  "Put point on the row for ID, and return non-nil if it is there."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (if (equal (cerebro--bead-at-point) id)
          (setq found t)
        (forward-line 1)))
    found))

(defun cerebro--goto-first-bead ()
  "Put point on the first bead row, if the panel has one."
  (goto-char (point-min))
  (while (and (not (eobp)) (null (cerebro--bead-at-point)))
    (forward-line 1))
  (when (eobp) (goto-char (point-min))))

(defun cerebro--move-bead (direction)
  "Move point one bead row in DIRECTION, 1 forward or -1 back.

Stops at the ends rather than wrapping: a list that jumps back to the top
when the navigator holds the key down hides where it finishes."
  (let ((start (point))
        (found nil))
    (forward-line direction)
    (while (and (not found)
                (if (> direction 0) (not (eobp)) (not (bobp))))
      (if (cerebro--bead-at-point)
          (setq found t)
        (forward-line direction)))
    ;; The last line has no newline, so `forward-line' can land on a bead row
    ;; at `eobp'; take it, and otherwise go back where we started.
    (unless (or found (cerebro--bead-at-point))
      (goto-char start))
    (beginning-of-line)))

(defun cerebro-beads-next ()
  "Move to the next bead (`n'), stepping over headers and blank lines."
  (interactive)
  (cerebro--move-bead 1))

(defun cerebro-beads-previous ()
  "Move to the previous bead (`p')."
  (interactive)
  (cerebro--move-bead -1))

(defvar-local cerebro--beads-rendered-at nil
  "`float-time' of the last timer redraw of this panel, or nil.

Not touched by an on-demand redraw (`g', a priority change) - only the
tick's own timed refresh sets it, so redrawing by hand never postpones the
next timed one. See `cerebro--refresh-panel-when-due'.")

(defvar-local cerebro--swept-at nil
  "`float-time' of the last timed sweep of this panel, or nil.

Also set by `cerebro--beads-buffer's own immediate sweep, so the first
timed one is ten minutes after the layout, not five seconds after.")

(defvar-local cerebro--sweep-requested-at nil
  "`float-time' of the sweep chain now in flight, or nil when none is.

`cerebro--sweep' refuses to start a second chain while one is out: the
claims and epics scripts run under two different `cerebro--run-async' keys,
so without this a second chain's own epics call could be silently dropped
as `busy' by the first chain's still-running one (PR #42 review).")

(defvar-local cerebro--beads nil
  "The last partition `bd' answered with, or nil before the first.")

(defvar-local cerebro--beads-as-of nil
  "`float-time' when `cerebro--beads' arrived, or nil.")

(defvar-local cerebro--beads-requested-at nil
  "`float-time' of the request now in flight, or nil when none is.")

(defvar-local cerebro--beads-failed-at nil
  "`float-time' of the last request that got no answer, or nil once one has
succeeded since.")

(defun cerebro--panel-header (as-of requested-at failed-at)
  "Pure. The panel's header line: what the rows date from and what is going on."
  (concat "Beads"
          (and as-of (format " · as of %s"
                             (format-time-string "%H:%M:%S" (seconds-to-time as-of))))
          (and requested-at " · refreshing…")
          (and failed-at (format " · bd did not answer at %s"
                                 (format-time-string "%H:%M:%S" (seconds-to-time failed-at))))))

(defun cerebro--update-panel-header (buffer)
  "Set BUFFER's `header-line-format' from its panel state and redisplay it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq header-line-format
            (cerebro--panel-header cerebro--beads-as-of cerebro--beads-requested-at
                                   cerebro--beads-failed-at))
      (force-mode-line-update))))

(defun cerebro--draw-beads (buffer)
  "Draw BUFFER's rows from `cerebro--beads' and `cerebro--sweep-findings'.

Draws from `cerebro--sweep-findings' rather than gathering it fresh - that
is `cerebro--sweep's job, on its own ten-minute cadence, because the
sweep scripts fetch from origin and spawn twice what one bead request
does."
  (cerebro--redraw
   buffer
   (lambda ()
     (let* ((width (cerebro--panel-width buffer))
            (beads (or cerebro--beads (list nil nil nil nil nil)))
            (lines (apply #'cerebro--bead-panel
                          (append beads (list width cerebro-beads-per-section)
                                  (list cerebro--sweep-findings)
                                  (list cerebro--history-rows))))
            ;; By id, not by position: the panel redraws every thirty seconds
            ;; and a bead landing above the selected one would otherwise slide
            ;; the mark onto whatever row took its line.
            (selected (cerebro--bead-at-point)))
       (erase-buffer)
       (insert (string-join lines "\n"))
       (unless (and selected (cerebro--goto-bead selected))
         ;; Selected bead merged, closed, or claimed away while it was marked.
         (cerebro--goto-first-bead))))))

(defun cerebro--beads-render (buffer)
  "Refresh BUFFER: draw what is known now, ask `bd' for what is current, and
draw again when it answers. Never blocks. A request already out is left to
finish rather than joined by a second (`cerebro--run-async' says `busy')."
  (cerebro--draw-beads buffer)
  (when (buffer-live-p buffer)
    (let ((root (with-current-buffer buffer (cerebro--repo-root))))
      (pcase (cerebro--request-beads
              root
              (lambda (beads)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (setq cerebro--beads-requested-at nil)
                    (if beads
                        (setq cerebro--beads beads
                              cerebro--beads-as-of (float-time)
                              cerebro--beads-failed-at nil)
                      (setq cerebro--beads-failed-at (float-time))))
                  (cerebro--draw-beads buffer)
                  (cerebro--update-panel-header buffer))))
        ('started (with-current-buffer buffer
                    (setq cerebro--beads-requested-at (float-time)))))))
  (cerebro--update-panel-header buffer))

(defun cerebro--beads-revert (&rest _)
  "Refresh the panel, for `g'."
  (cerebro--beads-render (current-buffer)))

(defvar cerebro-sweep-refresh-seconds 600
  "How often the Sweeps section re-runs the claims and epics sweep scripts.

Ten minutes: Cerebro's own cadence for these sweeps (`agents/orchestrator.md'),
and slower than the thirty-second bead timer on purpose - each sweep script
fetches from origin and spawns a `bd' call per candidate, which is
considerably more than the one `bd list' call `cerebro--request-beads' makes.")

(defvar-local cerebro--sweep-findings nil
  "The sweep findings as of the last `cerebro--sweep', a list of
\(LABEL . FINDING\). What `cerebro--beads-render' actually draws - see
there for why the render does not gather this itself.")

(defun cerebro--sweep (buffer)
  "Re-run the sweeps for BUFFER without blocking; when they answer, keep the
findings and redraw. A sweep that does not answer leaves the last findings
standing - ten-minutely housekeeping may miss a beat, and an empty Sweeps
section would say the fleet is clean when the script simply failed.

Called by `cerebro--refresh-panel-when-due' every
`cerebro-sweep-refresh-seconds', and once from `cerebro--beads-buffer' so the
section is not empty until the first ten minutes are up.  A chain already
out is left to finish rather than joined by a second - see
`cerebro--sweep-requested-at'."
  (when (and (buffer-live-p buffer)
             (not (with-current-buffer buffer cerebro--sweep-requested-at)))
    (with-current-buffer buffer (setq cerebro--sweep-requested-at (float-time)))
    (let ((root (with-current-buffer buffer (cerebro--repo-root))))
      (cerebro--request-sweeps
       root
       (lambda (answer)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (setq cerebro--sweep-requested-at nil))
           ;; ANSWER is (FINDINGS), possibly (nil), when both scripts
           ;; answered; nil when either did not - so only an actual answer
           ;; replaces what is already shown.
           (when answer
             (with-current-buffer buffer
               (setq cerebro--sweep-findings (car answer))))
           (cerebro--draw-beads buffer)))))))

(defvar cerebro-history-refresh-seconds 300
  "How often the History section re-runs `scripts/fleet-history'.

Five minutes: it reads a log that may hold weeks of transitions, and the
distribution it computes moves slowly, while the fleet tick is five seconds.
Recomputing on the tick would make the whole fleet view stutter, and it
would be blamed on Emacs.")

(defvar-local cerebro--history-rows nil
  "The summary rows as of the last `cerebro--history', or nil before the first.
What `cerebro--draw-beads' renders the History section from - the render
never gathers this itself, for the reason in `cerebro-history-refresh-seconds'.")

(defvar-local cerebro--history-at nil
  "`float-time' of the last timed history refresh of this panel, or nil.")

(defvar-local cerebro--history-requested-at nil
  "`float-time' of the history run now in flight, or nil when none is.")

(defun cerebro--history (buffer)
  "Re-run `scripts/fleet-history' for BUFFER without blocking; when it answers,
keep the rows and redraw.

A run that does not answer leaves the last rows standing: a corrupt log or a
missing script must not quietly replace real numbers with an empty section,
which would say every agent is idle when the query simply broke."
  (when (and (buffer-live-p buffer)
             (not (with-current-buffer buffer cerebro--history-requested-at)))
    (with-current-buffer buffer (setq cerebro--history-requested-at (float-time)))
    (let ((root (with-current-buffer buffer (cerebro--repo-root))))
      (cerebro--request-history
       root
       (lambda (answer)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq cerebro--history-requested-at nil)
             (when answer (setq cerebro--history-rows (car answer))))
           (cerebro--draw-beads buffer)))))))

(defvar cerebro-beads-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'cerebro-other-window)
    (define-key map (kbd "<tab>") #'cerebro-other-window)
    (define-key map "n" #'cerebro-beads-next)
    (define-key map "p" #'cerebro-beads-previous)
    (define-key map (kbd "<down>") #'cerebro-beads-next)
    (define-key map (kbd "<up>") #'cerebro-beads-previous)
    (define-key map (kbd "RET") #'cerebro-beads-show)
    ;; Digits set the priority outright, which takes them from
    ;; `digit-argument' in this buffer - there is nothing here a numeric
    ;; prefix would have been for.
    (dotimes (priority (1+ cerebro-priority-floor))
      (define-key map (number-to-string priority)
                  (lambda () (interactive) (cerebro-beads-set-priority priority))))
    (define-key map "+" #'cerebro-beads-raise)
    (define-key map "-" #'cerebro-beads-lower)
    (define-key map "u" #'cerebro-beads-undo-priority)
    (define-key map "x" #'cerebro-sweep-act)
    map)
  "Keymap for `cerebro-beads-mode'.")

(define-derived-mode cerebro-beads-mode special-mode "Cerebro Beads"
  "What the fleet could be working on: claimed, planned, and unplanned."
  (setq-local revert-buffer-function #'cerebro--beads-revert)
  (setq truncate-lines t)
  ;; No `hl-line-mode' here, deliberately (ah-4xl): the mark is the cursor
  ;; alone, as in the agent list - a hollow box in a window the navigator is
  ;; not in, since `cursor-in-non-selected-windows' defaults to t. If that
  ;; ever proves too faint, the agreed next step is
  ;; (setq-local cursor-in-non-selected-windows 'box) in both modes, not a
  ;; row background.
  )

(defun cerebro--beads-buffer (repo-root)
  "The panel buffer, created and started if it does not exist.

Starts no timer of its own - `cerebro--tick' redraws and re-sweeps this
buffer on its own cadences once the fleet buffer's tick is running (ah-6uo)."
  (let ((buffer (get-buffer-create cerebro-beads-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cerebro-beads-mode)
        (cerebro-beads-mode))
      ;; `bd' is answered relative to the repository, and this buffer is not
      ;; visiting a file, so it would otherwise inherit whatever directory
      ;; the navigator happened to be in.
      (setq default-directory (file-name-as-directory repo-root))
      (unless cerebro--swept-at
        ;; Kick off both once immediately, so neither section is simply
        ;; empty until its own cadence next comes due - the beads section
        ;; for up to thirty seconds, the Sweeps section for up to ten
        ;; minutes. Neither blocks: each asks in the background and
        ;; redraws when it answers. Still demoted: a `bd' or `gh' that
        ;; errors synchronously (program missing) must not stop the fleet
        ;; view opening.
        (with-demoted-errors "cerebro: %S" (cerebro--sweep buffer))
        (with-demoted-errors "cerebro: %S" (cerebro--history buffer))
        (with-demoted-errors "cerebro: %S" (cerebro--beads-render buffer))
        (setq cerebro--swept-at (float-time)
              cerebro--history-at (float-time))))
    buffer))

;;; The buffer


(defun cerebro--redraw (buffer draw)
  "Redraw BUFFER with DRAW, and put the result where the navigator can see it.

DRAW runs with BUFFER current and `inhibit-read-only' bound.  It rebuilds
the text and leaves point on the row that should stay selected - by id,
never by position, since a row landing above the selection would otherwise
slide the mark onto whatever took its line.  Then every window showing
BUFFER is given that point: a window keeps its own point while its buffer
is not the selected one, and both panels are almost always redrawn from
some other window - the timer, the layout, a key pressed in the detail
window - so without this the visible mark stays where it was while the
buffer believes it moved.  The one place this rule is written; the agent
list and the bead panel both come through here (ah-6uo).

Does nothing when BUFFER is dead."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (funcall draw))
      (dolist (window (get-buffer-window-list buffer nil t))
        (set-window-point window (point))))))

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
         (interactive (cerebro--interactive-agents repo-root))
         ;; The interactive roles write the same file when they can
         ;; (ah-2n3.2), so their names are gathered alongside the roster's -
         ;; one read per name per tick either way, and
         ;; `cerebro--derive-interactive' falls back to the process scan for
         ;; whichever of them have none.
         (states (cerebro--gather-states
                  repo-root (append (mapcar #'car interactive) roster)))
         (args (cerebro--cached-system-args))
         (owned (cerebro--owned))
         (now (current-time))
         (agents (cerebro--derive roster interactive states
                                          #'cerebro--session-alive-p args owned)))
    (setq cerebro--agents agents)
    ;; The table is sized to what is in front of it, every revert: a roster
    ;; gains an agent, a bead id gets deeper, and the columns follow (ah-qled.9).
    (let ((widths (cerebro--column-widths
                   (mapcar #'cerebro-agent-name agents)
                   (mapcar #'cerebro-agent-role agents)
                   (delq nil (mapcar #'cerebro-agent-bead agents)))))
      (setq cerebro-list-width (cerebro--width-for widths))
      (let ((format (cerebro--table-format widths)))
        (unless (equal tabulated-list-format format)
          (setq tabulated-list-format format)
          (tabulated-list-init-header)))
      (setq tabulated-list-entries
            (mapcar (lambda (a)
                      (cerebro--entry a now
                                      (cerebro--stop-flag-p repo-root (cerebro-agent-name a))
                                      (member (cerebro-agent-name a) cerebro--unanswered-pokes)
                                      (nth 3 widths)))
                    agents)))))

;;; The prune watcher (ah-4ao): `prune-worktrees.sh --watch' moves here from Cerebro

(defconst cerebro--prune-process-name " *cerebro-prune*"
  "Name of the background `prune-worktrees.sh --watch' process and its
output buffer. Leading space: an internal process, not something the
navigator picks from the buffer list.")

(defun cerebro--prune-action (process-live)
  "Pure. `start' when no watcher is live, `already-running' otherwise.

The script's own guards are the safety story - clean tree, work already on
main, untouched for half an hour (see `prune-worktrees.sh') - this decides
nothing about what gets removed, only whether a second `--watch' loop
should be started alongside a first. It should not: two would sweep the
same worktrees at once and race each other's `git worktree remove', not
merely duplicate work."
  (if process-live 'already-running 'start))

(defun cerebro--prune-process-live-p ()
  "Non-nil if the prune watcher process is already running."
  (let ((process (get-process cerebro--prune-process-name)))
    (and process (process-live-p process))))

(defun cerebro--start-prune-process (repo-root)
  "Start `prune-worktrees.sh --watch' in REPO-ROOT, output going nowhere
the navigator has to look at - the script already says why it kept or
removed each tree, and that is for troubleshooting, not the ordinary case.

Never signals: `M-x cerebro' has to open even when the script is missing or
unrunnable (a fresh checkout without `--recurse-submodules', for one), the
same way `cerebro--run-async' degrades rather than taking the buffer down."
  (condition-case nil
      (make-process
       :name cerebro--prune-process-name
       :buffer (get-buffer-create cerebro--prune-process-name)
       :command (list (expand-file-name (cerebro--script "prune-worktrees.sh") repo-root) "--watch")
       :noquery t)
    (error nil)))

(defun cerebro--ensure-prune-watcher (repo-root)
  "Start the prune watcher in REPO-ROOT unless one is already running.

Called from `M-x cerebro' on every open, not only the first - `--prune-action'
is what makes a second call a no-op rather than a second `--watch' loop, the
same way `cerebro--beads-buffer' guards its own timers."
  (when (eq (cerebro--prune-action (cerebro--prune-process-live-p)) 'start)
    (cerebro--start-prune-process repo-root)))

(defun cerebro--kill-prune-watcher ()
  "Stop the prune watcher, if running.

Bound to the fleet buffer's own `kill-buffer-hook': the watcher exists to
serve `M-x cerebro', and a `sleep 600' loop nobody can see it report is not
something to leave running past the buffer that started it - unlike the
sweep scripts here, `prune-worktrees.sh' talks to git and disk, not merely
to `bd', so an orphaned loop is more than idle load."
  (let ((process (get-process cerebro--prune-process-name)))
    (when process (delete-process process))))

(defun cerebro--cancel-timer ()
  "Stop this buffer's auto-refresh timer, if any."
  (when (timerp cerebro--timer)
    (cancel-timer cerebro--timer)
    (setq cerebro--timer nil)))

(defun cerebro--list-render (buffer)
  "Refresh BUFFER's table and give every window showing it the buffer's point.

`tabulated-list-revert' runs `cerebro--revert' (via
`tabulated-list-revert-hook') and then `tabulated-list-print', which
restores the buffer's point by id -
`cerebro--redraw' is what pushes that out to windows that are not selected.
Bound as `revert-buffer-function' so `g' and the tick share this one path."
  (cerebro--redraw buffer #'tabulated-list-revert))

(defun cerebro--due-p (last every seconds)
  "Non-nil when LAST is nil or EVERY seconds have passed since it, at SECONDS."
  (or (null last) (>= (- seconds last) every)))

(defun cerebro--refresh-panel-when-due (panel seconds)
  "Redraw PANEL and re-run the sweeps if their cadences say so at SECONDS.

The two run independently: neither blocks any more, so there is no cost to
avoid by coupling them the way an earlier version did (a sweep costs no
`bd list' call, so a tick where both are due simply runs both)."
  (with-current-buffer panel
    (when (cerebro--due-p cerebro--swept-at cerebro-sweep-refresh-seconds seconds)
      (setq cerebro--swept-at seconds)
      (cerebro--sweep panel))
    (when (cerebro--due-p cerebro--history-at cerebro-history-refresh-seconds seconds)
      (setq cerebro--history-at seconds)
      (cerebro--history panel))
    (when (cerebro--due-p cerebro--beads-rendered-at cerebro-beads-refresh-seconds seconds)
      (setq cerebro--beads-rendered-at seconds)
      (cerebro--beads-render panel))))

(defun cerebro--tick (buffer &optional now)
  "Refresh BUFFER if it is still alive; called every 5s while it lives.

The list first, then `cerebro--supervise' on what that just derived - never
on a state file read five seconds ago.  Then the bead panel, when its
thirty seconds are up, and the sweeps, when their ten minutes are: one
timer with the fleet buffer's lifetime, instead of a timer per panel each
cancelling itself by a different route (ah-6uo).  Both are demoted: a `bd'
that will not answer must not stop the list refreshing.  NOW is for tests.

Nothing here waits on a subprocess: the panel and the sweeps request and
draw when answered (ah-9dv); the process scan is the one blocking read
left and runs every `cerebro-system-scan-seconds'."
  (when (buffer-live-p buffer)
    (let ((now (or now (current-time))))
      (with-current-buffer buffer
        (cerebro--list-render buffer)
        (cerebro--supervise cerebro--agents (cerebro--repo-root) now))
      (let ((panel (get-buffer cerebro-beads-buffer-name)))
        (when (buffer-live-p panel)
          (with-demoted-errors "cerebro: %S"
            (cerebro--refresh-panel-when-due panel (float-time now))))))))

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
          (ignore-errors (split-window cerebro--list-window
                                        (cerebro--list-height (length cerebro--agents))
                                        'below)))
    (when (window-live-p cerebro--beads-window)
      ;; `cerebro--beads-buffer' only renders on its own first creation -
      ;; before calling it, so a panel that already existed (the fleet
      ;; buffer was killed and reopened, say) is redrawn once here rather
      ;; than sitting however it last looked until the tick's own cadence
      ;; next comes due, and a brand new one is not rendered twice.
      (let* ((preexisting (get-buffer cerebro-beads-buffer-name))
             (panel (cerebro--beads-buffer (cerebro--repo-root))))
        (set-window-buffer cerebro--beads-window panel)
        (when preexisting
          (cerebro--beads-render panel))))))

(defun cerebro-start ()
  "Start the agent at point (`s').

Starting a name is a statement that it should run, so any stop flag left
over for it - from a session killed with `k', an Emacs that quit mid-bead,
or a flag set by hand - is cleared first (ah-kgc), and the echo area says
so: silently discarding an instruction the navigator may have set thirty
seconds earlier would be a worse surprise than announcing it."
  (interactive)
  (let ((agent (cerebro--agent-at-point)))
    (when agent
      (let* ((repo-root (cerebro--repo-root))
             (name (cerebro-agent-name agent))
             (flagged (cerebro--stop-flag-p repo-root name))
             (clears-flag (cerebro--start-clears-flag-p agent flagged)))
        (pcase (cerebro--start-action agent (cerebro--owned))
          ('launch
           (when clears-flag
             (cerebro--clear-stop-flag repo-root name))
           (cerebro--launch agent)
           (revert-buffer)
           (cerebro--show-detail agent)
           (when clears-flag
             (message "%s: cleared a stale stop flag" name)))
          ('already-up (message "%s is already up" name))
          ('external (message "%s is running outside Emacs" name)))))))

(defun cerebro--kill-session-buffer (agent repo-root)
  "End AGENT's session (`k'), then refresh the view and the detail window.

`cerebro-kill' has already confirmed this exact kill via `y-or-n-p', so the
process's query-on-exit flag is cleared - in `cerebro--forget-session',
which `cerebro--end-session' calls - rather than prompting a
second time.  The state file goes with the session, which is
what stops the row reading `working' on a bead nobody is building.

The stop flag is left alone: `k' is not a retire, and a flag set with `f'
means this name stays down until `s' clears it and says so.

REPO-ROOT is passed in rather than looked up here, so `cerebro--repo-root'
and its buffer-local `default-directory' work stay out of the unit under
test - `cerebro-kill' computes it once for all its branches."
  (cerebro--end-session agent repo-root)
  (revert-buffer)
  (cerebro--show-detail agent))

(defun cerebro-kill ()
  "Kill the agent at point (`k'), confirming first."
  (interactive)
  (let ((agent (cerebro--agent-at-point)))
    (when agent
      ;; Once, for whichever branch needs it - `cerebro--kill-session-buffer'
      ;; takes the root as a parameter so the buffer-local `default-directory'
      ;; work stays out of the unit under test.
      (let ((repo-root (cerebro--repo-root)))
       (pcase (cerebro--kill-action agent (cerebro--owned))
        ('kill
         (when (y-or-n-p (format "Kill %s? " (cerebro-agent-name agent)))
           (cerebro--kill-session-buffer agent repo-root)))
        ('kill-working
         (when (y-or-n-p
                (format (concat "%s is working on %s - killing mid-bead strands a claim, "
                                 "a worktree and an open PR. Kill anyway? ")
                        (cerebro-agent-name agent) (cerebro-agent-bead agent)))
           (cerebro--kill-session-buffer agent repo-root)))
        ('external
         (message "%s is running outside Emacs - stop it from its own terminal"
                  (cerebro-agent-name agent)))
        ('dead (message "%s is not running" (cerebro-agent-name agent))))))))

(defun cerebro--write-stop-flag (repo-root name)
  "Create NAME's stop flag in REPO-ROOT, empty - only its existence is read.

`make-directory' first, `:parents' t, mirroring the documented
\"mkdir -p .cerebro/state && touch ...\" flow (`orchestrator.md') - since
ah-2n3.1, `cerebro--repo-root' is located by `.claude/cerebro' rather than by
this directory, so `.cerebro/state' is no longer guaranteed to exist by
the time this runs."
  (let ((path (cerebro--stop-flag-path repo-root name)))
    (make-directory (file-name-directory path) t)
    (write-region "" nil path)))

(defun cerebro--delete-state-file (repo-root name)
  "Remove NAME's state file in REPO-ROOT, if any.

A state file describes a session that is running; once the fleet view has
ended one on purpose, the file is a claim about a process that no longer
exists. The agent cannot retract it - it is killed, so it never writes a
last transition - which leaves the fleet view, the only other writer, to do
it. Left behind, the file outlives the pid it names, and pids are recycled:
see `cerebro--session-alive-p' for what that looked like the morning it
happened.

Deletes unconditionally and catches `file-missing' rather than checking
first, for the reason `cerebro--clear-stop-flag' gives: the file has
several writers, so a pre-check would leave the very race it looks like it
closes - and this runs from a timer with demoted errors, where an uncaught
signal would be swallowed rather than simply doing nothing."
  (condition-case nil
      (delete-file (cerebro--state-file-path repo-root name))
    (file-missing nil)))

(defun cerebro--clear-stop-flag (repo-root name)
  "Remove NAME's stop flag in REPO-ROOT, if any.

A pre-check with `file-exists-p' would leave a race - the flag can vanish
between the check and the `delete-file' (another Emacs, a shell `rm', a
second caller), which raises `file-missing' right where the check was
meant to prevent it.  Deleting unconditionally and catching that signal
closes the race instead of narrowing its window.  This is the one place
that deletes a stop flag, so retire, restart and `s' can all call it
without checking first - and, since `cerebro--supervise' runs from a timer
with demoted errors, an uncaught `file-missing' here would otherwise be
swallowed silently rather than simply doing nothing."
  (condition-case nil
      (delete-file (cerebro--stop-flag-path repo-root name))
    (file-missing nil)))

(defun cerebro-finish ()
  "Tell the implementer at point to finish (`f'): write its stop flag.

The flag is read between beads, never during one (see `orchestrator.md'):
a working or asking session completes the bead it is on, closes it, and only
then stops - so this cannot end an implementer mid-bead, and does not try
to. An idle implementer has nothing in flight, so the flag means *stop now*
instead (ah-ymn): the flag is written and the fleet poll is run at once
\(`cerebro--tick'), so the session ends on this keypress rather than up to
five seconds later. If a flag is already set, offers to clear it instead,
which cancels the instruction cleanly. A flag left on disk is also cleared
when the fleet view retires the session it stopped, and when `s' starts
that name again (ah-kgc), so it never outlives the session it was written
for. A dead implementer has nothing to finish, and an idle one running
outside Emacs is never touched by the poll that would act on a flag - both
refuse rather than write one that would sit unread (ah-ymn)."
  (interactive)
  (let ((agent (cerebro--agent-at-point)))
    (when agent
      (let* ((repo-root (cerebro--repo-root))
             (name (cerebro-agent-name agent))
             (flagged (cerebro--stop-flag-p repo-root name)))
        (pcase (cerebro--finish-action agent flagged)
          ('write
           (cerebro--write-stop-flag repo-root name)
           (revert-buffer)
           (message "told %s to finish - it completes its current bead first" name))
          ('stop-now
           (cerebro--write-stop-flag repo-root name)
           (cerebro--tick (current-buffer))
           (message "%s was idle - stopped now, no replacement" name))
          ('offer-clear
           (when (y-or-n-p (format "Stop flag already set for %s - clear it? " name))
             (cerebro--clear-stop-flag repo-root name)
             (revert-buffer)
             (message "%s will keep going" name)))
          ('dead (message "%s is not running - nothing to finish" name))
          ('external
           (message "%s is running outside Emacs - stop it from its own terminal" name))
          ('not-implementer
           (message "%s is not an implementer - nothing to finish" name)))))))

(defun cerebro-other-window ()
  "Move to the next window (`TAB'), exactly as `C-x o' does.

The layout cycles list -> beads -> detail -> list, so one key reaches every
window of it and comes back round rather than stopping at the right-hand
edge.  Bound in all three, which for the detail window means taking TAB off
vterm - see `cerebro-session-mode'."
  (interactive)
  (other-window 1))

(defun cerebro-send-tab ()
  "Send a real tab to the agent in this session (`C-c TAB').

`cerebro-session-mode' takes TAB for window cycling, and an agent still
needs to receive one occasionally - a shell completion, a TUI that uses it."
  (interactive)
  (if (fboundp 'vterm-send-tab)
      (vterm-send-tab)
    (user-error "cerebro: no live vterm session here to send a tab to")))

(defvar cerebro-session-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'cerebro-other-window)
    (define-key map (kbd "<tab>") #'cerebro-other-window)
    (define-key map (kbd "C-c TAB") #'cerebro-send-tab)
    map)
  "Keymap for `cerebro-session-mode'.")

(define-minor-mode cerebro-session-mode
  "Make TAB cycle windows in a fleet-owned session buffer.

vterm binds TAB in `vterm-mode-map', its own major-mode map, so a plain
major-mode binding could not win.  A minor mode outranks it and stays
confined to the buffers the fleet view created: editing `vterm-mode-map'
would have taken TAB from every vterm the navigator has, fleet or not.

`C-c TAB' sends a real tab on to the agent."
  :lighter " Fleet"
  :keymap cerebro-session-mode-map)

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
    (define-key map "f" #'cerebro-finish)
    map)
  "Keymap for `cerebro-mode'.")

(define-derived-mode cerebro-mode tabulated-list-mode "Cerebro"
  "Major mode listing the agent fleet of the repository it is opened in.

\\{cerebro-mode-map}"
  ;; A starting shape only: `cerebro--revert' resizes it from the roster and
  ;; the bead ids actually being shown on every render (ah-qled.9).
  (setq tabulated-list-format (cerebro--table-format cerebro--column-minimums))
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'cerebro--revert nil t)
  (add-hook 'kill-buffer-hook #'cerebro--cancel-timer nil t)
  (add-hook 'kill-buffer-hook #'cerebro--kill-prune-watcher nil t)
  (add-hook 'post-command-hook #'cerebro--follow nil t)
  ;; So `g' and the tick share one path (`cerebro--list-render') instead of
  ;; `g' calling the parent mode's default and the tick calling `revert-buffer'
  ;; some other way (ah-6uo). Set here, after `tabulated-list-mode's own body
  ;; has already run, or this would be clobbered by its default.
  (setq-local revert-buffer-function
              (lambda (&rest _) (cerebro--list-render (current-buffer))))
  (tabulated-list-init-header))

;;;###autoload
(defun cerebro ()
  "Open (or refresh) the *cerebro* buffer, listing every agent."
  (interactive)
  (let ((buffer (get-buffer-create cerebro-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cerebro-mode)
        (cerebro-mode))
      (cerebro--list-render buffer)
      (cerebro--cancel-timer)
      (setq cerebro--timer
            (run-with-timer 5 5 #'cerebro--tick buffer))
      (cerebro--ensure-prune-watcher (cerebro--repo-root)))
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
