;;; cerebro.el --- List the Cerebro agent fleet -*- lexical-binding: t; -*-

;; Emacs 28+ (json-parse-string, iso8601-parse).  No external dependencies.

;;; Commentary:

;; `M-x cerebro' opens a buffer listing every agent the fleet can have -
;; Xavier, Cerebro, Moira, Psylocke, Bishop and the thirteen implementers - each with
;; a state glyph, role, state, and (for a working implementer) the bead it is
;; on and for how long.  It refreshes itself every 5 seconds.
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
;;     ah-2n3.2 the interactive five do too, `done' excepted - it is an
;;     implementer's state alone.
;;   - the launcher's `--roster', the thirteen implementer names.
;;   - liveness for the interactive five (Xavier, Cerebro, Moira, Psylocke,
;;     Bishop) is the state file first, when one exists for a live pid, and
;;     falls back to scanning system processes for the `--name <Name>'
;;     argument their launchers pass when it does not - a session started by
;;     hand, outside this fleet, has no file and still has to show `up'.

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

(defconst cerebro-buffer-name "*cerebro*")

(defconst cerebro-list-width 59
  "Columns for the left column of the layout.

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

(defconst cerebro-list-height 20
  "Lines given to the agent list before the bead panel starts.

Eighteen agents and a header, so the list never scrolls and the panel gets
whatever the frame has left.")

;;; The interactive roster

(defconst cerebro-interactive-agents
  '(("Xavier" . "planner")
    ("Cerebro" . "orchestrator")
    ("Moira" . "feedback")
    ("Psylocke" . "verifier")
    ("Bishop" . "architect"))
  "The five interactive agents, mirroring their launchers.")

;;; The pure core

(cl-defstruct cerebro-agent
  "One row of the fleet list."
  name role kind                       ; kind: 'interactive | 'implementer
  state                                ; 'up | 'working | 'idle | 'dead | 'done | 'asking | 'unknown
  bead since external
  phase                                ; "build"|"gate"|"review"|"ci"|"rebase"|"merge" or nil
  phase-since                          ; ISO-8601 string, or nil
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
                                :raw raw-state)))

(defun cerebro--derive-interactive (entry states pid-alive-p args owned)
  "Derive one interactive agent's row from (NAME . ROLE) ENTRY.

STATES is an alist of (NAME . parsed-state-json-or-nil), the same one an
implementer's row is derived from; PID-ALIVE-P a predicate on a pid; ARGS is
the system process args list; OWNED the names Emacs itself started.

Liveness is the state file first, the process scan second: when STATES has
an entry for NAME whose pid is still alive, the row comes from the file -
`working'/`idle'/`asking' and a phase, exactly like an implementer's row.
Otherwise (no entry, or a pid that is no longer running - the file, if any,
is a previous session's) this falls back to the three process-scan branches
below, so a session started by hand outside this fleet
\(`claude --name Xavier ...'\) with no file at all still shows `up'."
  (let* ((name (car entry))
         (role (cdr entry))
         (parsed (cdr (assoc name states)))
         (pid (and parsed (alist-get 'pid parsed)))
         (alive (and pid (funcall pid-alive-p pid)))
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
     (t (cerebro--derive-from-state name "implementer" 'implementer parsed owned-p)))))

(defun cerebro--derive (roster interactive-agents states pid-alive-p args owned)
  "Return the fleet as a list of `cerebro-agent', interactive first.

ROSTER is the implementer name list, in the order they should be shown.
INTERACTIVE-AGENTS is an alist of (NAME . ROLE), normally
`cerebro-interactive-agents'.  STATES is an alist of (NAME .
parsed-state-json-or-nil) covering both the roster and the interactive
names - see `cerebro--gather-states'.  PID-ALIVE-P is a predicate on a pid.
ARGS is the system process args list.  OWNED is the set of agent names whose
sessions Emacs itself started."
  (append
   (mapcar (lambda (entry) (cerebro--derive-interactive entry states pid-alive-p args owned))
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
   ;; `unknown' is a live session the view does not understand - the same
   ;; yellow as `idle', for the same reason: something the navigator may want
   ;; to look at. Grey (`dead') would say nobody is there, which is untrue.
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
    "triage" "plan" "prepare" "verify" "sweep" "release" "daily" "weekly")
  "The phase vocabulary. Mirrors scripts/agent-state.

Not divided by role in code - the fleet list shows whatever word a state
file carries, in the State column, and a wrong word for the role in that
column is not worth a per-role table in Elisp any more than in the script.
By role, for reference: `build gate review ci rebase merge' belong to an
implementer; `triage plan' to Xavier; `prepare verify' to Psylocke; `sweep',
or `sweep release', to Moira and Cerebro; `daily weekly' to Bishop.")

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

(defun cerebro--entry (agent now &optional flagged)
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

The Bead column is 10 columns wide; an external agent shows \"—\" rather than
the wordier \"(external)\", and a real bead id longer than 10 (a nested child
bead, e.g. \"ah-dzj.1.1.1.1\") truncates with an ellipsis rather than pushing
the rest of the row right - see ah-lyc."
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
                     (concat (cerebro--state-label agent) (if (and flagged in-flight) " ■" ""))
                     attention))
         (bead-col (cerebro--emphasize
                    (cond (external "—")
                          ((cerebro-agent-bead agent)
                           (truncate-string-to-width (cerebro-agent-bead agent) 10 nil nil "…"))
                          (t ""))
                    attention))
         (for-col (cerebro--emphasize
                   (if external ""
                     (cerebro--for-column (cerebro-agent-since agent)
                                           (cerebro-agent-phase-since agent) now))
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

(defun cerebro--bead-panel (claimed planned unplanned merged width max &optional sweep-findings)
  "The whole panel as a list of lines.

The order work moves in, and it stops where the fleet's part in it does:
being built, ready to pick up, not planned yet, and merged but not yet
verified - which is Psylocke's queue.

Verified work is not here. Neither is anything nobody can pick up. See
`cerebro--partition-beads' for what that leaves out and why.

SWEEP-FINDINGS, when given, adds a Sweeps section at the bottom (see
`cerebro--sweep-section') - what the claims and epics sweeps found, each
one a candidate for `x' rather than something already decided."
  (append (cerebro--bead-section "Claimed" claimed width max) (list "")
          (cerebro--bead-section "Planned, unclaimed" planned width max) (list "")
          (cerebro--bead-section "Unplanned" unplanned width max) (list "")
          ;; Newest first: priority says nothing about finished work, so what
          ;; this answers is what just landed and still wants checking.
          (cerebro--bead-section "Merged, unverified" merged width max
                                 #'cerebro--sort-recent)
          (let ((sweep-lines (cerebro--sweep-section sweep-findings)))
            (when sweep-lines (cons "" sweep-lines)))))

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
               .minutes_since_last_child_closed)))))

(defun cerebro--sweep-line (label finding)
  "One propertized Sweeps line: LABEL, carrying FINDING the way a bead row
carries its id - so `cerebro-sweep-act' acts on what point stands on rather
than re-deriving it from the text."
  (propertize label 'cerebro-finding finding))

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

(defun cerebro--live-implementer-names (repo-root)
  "Implementer names with a live session right now, in REPO-ROOT.

By process, not by `cerebro--owned': a session running in the navigator's
own terminal is just as live as one Emacs started, and just as much not to
be swept as one Emacs started."
  (let ((roster (cerebro--roster repo-root)))
    (delq nil
          (mapcar (lambda (name)
                    (let* ((parsed (cerebro--read-state-file
                                    (cerebro--state-file-path repo-root name)))
                           (pid (and parsed (alist-get 'pid parsed))))
                      (and pid (cerebro--pid-alive-p pid) name)))
                  roster))))

(defun cerebro--run-script-json (repo-root script &rest args)
  "Run SCRIPT (one of the sweep scripts, `cerebro--script'-relative) with
ARGS in REPO-ROOT; the parsed JSON it printed, or nil.

Never signals, the same as `cerebro--bd-json' and for the same reason: a
sweep script that cannot run - missing, erroring, no `bd' on PATH - must
leave the panel showing no findings rather than take it down."
  (condition-case nil
      (with-temp-buffer
        (let ((default-directory (file-name-as-directory repo-root)))
          (when (zerop (apply #'call-process
                              (expand-file-name (cerebro--script script) repo-root)
                              nil t nil args))
            (json-parse-string (buffer-string) :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil))))
    (error nil)))

(defun cerebro--gather-sweeps (repo-root)
  "The current sweep findings, as a list of (LABEL . FINDING). Impure."
  (let* ((live-names (cerebro--live-implementer-names repo-root))
         (now (current-time))
         (claims (cerebro--run-script-json repo-root "sweep-claims.sh" "--json"))
         (epics (cerebro--run-script-json repo-root "sweep-epics.sh" "--json")))
    (append
     (delq nil (mapcar (lambda (c)
                         (let ((finding (cerebro--claim-finding c live-names now)))
                           (and finding (cons (cerebro--sweep-label finding c) finding))))
                       claims))
     (delq nil (mapcar (lambda (e)
                         (let ((finding (cerebro--epic-finding e)))
                           (and finding (cons (cerebro--sweep-label finding e) finding))))
                       epics)))))

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
            (let ((pushed (cerebro--run-sweep-command repo-root '("bd" "dolt" "push"))))
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

Only an implementer Emacs itself started is supervised.  One running in
somebody's own terminal is theirs to end, and a dead one stays dead -
restarting it would fight the navigator's own `k'.

The `kind' guard is load-bearing now that the interactive five write the
same state file an implementer does (ah-2n3.2): Xavier, Cerebro, Moira,
Psylocke and Bishop can show `asking' or, if one ever writes it in error,
`unknown', but never `restart'ed, `retire'd or `nudge'd from here - they are
never replaced between beads because they have none, and any future
unification of this function must keep excluding them explicitly rather
than by accident."
  (when (and (eq (cerebro-agent-kind agent) 'implementer)
             (not (cerebro-agent-external agent)))
    (pcase (cerebro-agent-state agent)
      ('done (if stop-flag-p 'retire 'restart))
      ('idle (and stop-flag-p 'retire))
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
    ("verifier" . "run-psylocke")
    ("architect" . "run-bishop"))
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
refuse rather than launch a second one)."
  (cond
   ((not (cerebro--alive-p agent)) 'launch)
   ((member (cerebro-agent-name agent) owned) 'already-up)
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

One of `not-implementer' (the five interactive roles have no bead to finish
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

(defconst cerebro--sweep-stale-minutes 10
  "Minutes past which a claim's delivery, or an epic's last child close, is
old enough to act on rather than mid-cleanup.

Matches `agents/orchestrator.md's own claims and epics sweeps: an
implementer closes what it just finished within seconds, so anything
fresher than this is an agent still tidying up, not one that is gone.")

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
      (if (and .commit_age_min (> .commit_age_min cerebro--sweep-stale-minutes))
          (list 'close .id
                (format "Delivered in PR; closed by the fleet view, %s did not" .assignee))
        nil))
     ((and .lease_age_min (> .lease_age_min cerebro--sweep-stale-minutes))
      (list 'reclaim .id))
     (t nil))))

(defun cerebro--epic-finding (candidate)
  "Pure. What the epics sweep should offer for CANDIDATE, or nil.

CANDIDATE is one parsed object from `sweep-epics.sh --json' - already
known eligible (every child closed) by the script's own `bd epic status
--eligible-only'. The only question left here is staleness: nil when
`minutes_since_last_child_closed' is absent (nothing to act on) or under
`cerebro--sweep-stale-minutes' (an implementer is still mid-cleanup),
otherwise (epic-close ID)."
  (let-alist candidate
    (if (and .minutes_since_last_child_closed
             (> .minutes_since_last_child_closed cerebro--sweep-stale-minutes))
        (list 'epic-close .id)
      nil)))

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
    (`(close ,id ,reason) (list "bd" "close" id "--reason" reason))
    (`(reclaim ,id) (list "bd" "reclaim" "--id" id "--older-than" "10m"))
    (`(epic-close ,id) (list "bd" "close" id))
    (_ (error "cerebro: no command for finding %S" finding))))

;;; Impure readers - each trivially small so everything above stays pure

(defun cerebro--repo-root ()
  "The repository root above `default-directory', or an error.
Located by `.claude/cerebro' (the submodule mount, present in every
consumer from clone time) rather than by `.cerebro/state', which
may not exist yet on a fresh machine - `agent-state' and
`cerebro--write-stop-flag' both create it on first write."
  (or (locate-dominating-file default-directory ".claude/cerebro")
      (error "cerebro: no .claude/cerebro found above %s" default-directory)))

(defun cerebro--parse-roster (output)
  "Turn OUTPUT (one implementer name per line) into a list of names."
  (seq-filter (lambda (s) (not (string-empty-p s)))
              (mapcar #'string-trim (split-string output "\n"))))

(defvar-local cerebro--roster-cache nil
  "The roster, once read; buffer-local so a revert does not re-shell out.")

(defun cerebro--roster (repo-root)
  "The thirteen implementer names, via the launcher's --roster."
  (or cerebro--roster-cache
      (setq cerebro--roster-cache
            (cerebro--parse-roster
             (with-temp-buffer
               (call-process (expand-file-name (cerebro--script "run-implementer") repo-root)
                              nil t nil "--roster")
               (buffer-string))))))

(defun cerebro--state-file-path (repo-root name)
  "Where NAME's status file lives, mirroring `statePath' in runImplementer.ts."
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
roster plus the five interactive names, since ah-2n3.2 has all of them
writing the same file."
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
       (let ((buffer (get-buffer (cerebro--session-buffer-name agent))))
         (and buffer (eq (window-buffer cerebro--detail-window) buffer)))))

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
line from the one before it."
  (unless (require 'vterm nil t)
    (user-error "cerebro needs vterm for live sessions - install emacs-libvterm"))
  (add-hook 'vterm-exit-functions #'cerebro--note-exit)
  (setq cerebro--last-exit
        (assoc-delete-all (cerebro-agent-name agent) cerebro--last-exit))
  (let* ((default-directory (cerebro--repo-root))
         (cmd (cerebro--launch-command agent))
         (vterm-shell (if (stringp cmd) cmd (mapconcat #'shell-quote-argument cmd " ")))
         (session-name (cerebro--session-buffer-name agent))
         (buffer (cerebro--make-session-buffer session-name)))
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
      ;; is the launcher's behaviour, and an older `run-implementer'
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
BUFFER's text (never the whole buffer - see there), matches BUFFER's name
against a session-buffer name to find the agent, and updates the global
alist and the echo area. BUFFER can be nil - vterm's sentinel passes it
after the buffer itself has already been killed (`k', retire, restart) -
and any buffer whose name is not a session-buffer name is left alone."
  (let ((name (and (buffer-live-p buffer)
                    (cerebro--owned-buffer-agent-name (buffer-name buffer)))))
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

(defun cerebro--stop-flag-path (repo-root name)
  "Where NAME's stop flag lives, as `orchestrator.md' documents it."
  (expand-file-name (format ".cerebro/state/%s.stop" name) repo-root))

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
          ('restart (let ((watching (cerebro--detail-showing-p agent)))
                      (cerebro--end-session agent)
                      (cerebro--launch agent)
                      (when watching (cerebro--show-detail agent))))
          ('retire (cerebro--end-session agent)
                   (cerebro--clear-stop-flag repo-root name))
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

(defun cerebro--bd-text (repo-root id)
  "The output of `bd show ID' run in REPO-ROOT, or nil if it failed.

Text rather than `--json': this goes in front of the navigator, and `bd's
own rendering already lays a bead out to be read.  It wraps at eighty
columns off a tty and ignores COLUMNS, so the detail window gets eighty
columns of bead however wide it is."
  (condition-case nil
      (with-temp-buffer
        (let ((default-directory (file-name-as-directory repo-root)))
          (when (zerop (call-process "bd" nil t nil "show" id))
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

(defconst cerebro-verification-settled '("verification:passed" "verification:not-needed")
  "Labels meaning a merged bead needs nothing further from anybody.

`verification:passed' is a human having checked it; `not-needed' is the
navigator having ruled it out of scope - the cutoff for work predating the
role. Different reasons, same consequence for a queue, so the panel groups
them under Verified.

Note this is deliberately NOT how `agents/user-feedback.md' talks to a
reporter: there a `not-needed' bead never shows VERIFIED, because nobody
confirmed anything. The word means \"a person checked it\" on an issue
thread, and \"nothing left to do\" here.")

(defun cerebro--bead-labels (bead)
  "The labels on BEAD, as a list of strings."
  (alist-get 'labels bead))

(defun cerebro--settled-p (bead)
  "Whether BEAD carries a label that closes the verification question."
  (cl-some (lambda (label) (member label cerebro-verification-settled))
           (cerebro--bead-labels bead)))

(defun cerebro--partition-beads (beads)
  "Split BEADS into the four lists the panel shows.

\(CLAIMED PLANNED UNPLANNED MERGED), where merged means merged and not yet
verified.  Not every bead lands in one, deliberately: verified work is
finished, epics are parents rather than work, bd's own `event' records are
bookkeeping, and blocked or deferred beads cannot be picked up.  A panel is
a list of what to do about something, so what there is nothing to do about
is left out.

It still partitions one list rather than running a query per section, which
is what keeps those exclusions in one readable place instead of spread
across five `bd' invocations - an `event' in particular carries the very
labels these rules key on, and would otherwise arrive looking like merged
work."
  (let (claimed planned unplanned merged)
    (dolist (bead beads)
      (let ((status (alist-get 'status bead)))
        (cond
         ;; Not work, and so not shown: an epic is a parent with children, and
         ;; an `event' is bd's own audit record of a state change ("State
         ;; change: verification -> passed"). An event carries the very labels
         ;; these rules key on, so without this three of them appeared as
         ;; merged work - one per verification ever recorded.
         ((member (alist-get 'issue_type bead) '("epic" "event")) nil)
         ((equal status "in_progress") (push bead claimed))
         ((equal status "open")
          (if (member "planned" (cerebro--bead-labels bead))
              (push bead planned)
            (push bead unplanned)))
         ((equal status "closed")
          ;; Settled means nothing further is wanted from anybody - verified
          ;; by a person, or ruled out of scope. Finished, so not here.
          (unless (cerebro--settled-p bead) (push bead merged)))
         ;; Blocked, deferred, or a status from a future bd: real beads, but
         ;; nothing the fleet can pick up today.
         (t nil))))
    (list (nreverse claimed) (nreverse planned) (nreverse unplanned)
          (nreverse merged))))

(defconst cerebro-priority-floor 4
  "The least urgent priority `bd' takes; 0 is the most urgent.")

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
          (zerop (call-process "bd" nil t nil "update" id
                               "--priority" (number-to-string priority)))))
    (error nil)))

(defun cerebro--gather-beads (repo-root)
  "The six lists the panel shows, from one `bd' call.

Every status by name, and no `--exclude-type': the partition can only be
complete if the list it partitions is.  One call also costs less than the
five it replaced, and cannot show a half-updated database the way five
sequential calls could.

An earlier version filtered the open lists by the `owner' field and showed
an empty panel every time: `owner' is the address of whoever *filed* the
bead and is set on all of them, claimed or not."
  (cerebro--partition-beads
   (cerebro--bd-json repo-root "list"
                     "--status" "open,in_progress,blocked,deferred,closed"
                     "--json")))


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

(defun cerebro--beads-render (buffer)
  "Redraw BUFFER's panel from `bd'.

Draws from `cerebro--sweep-findings' rather than gathering it fresh - that
is `cerebro--sweep-tick's job, on its own ten-minute cadence, because the
sweep scripts fetch from origin and spawn twice what `cerebro--gather-beads'
does. A `g' or the thirty-second bead timer redraws with whatever the last
sweep found rather than paying that cost again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((width (cerebro--panel-width buffer))
             (beads (cerebro--gather-beads (cerebro--repo-root)))
             (lines (apply #'cerebro--bead-panel
                           (append beads (list width cerebro-beads-per-section)
                                   (list cerebro--sweep-findings))))
             (inhibit-read-only t)
             ;; By id, not by position: the panel redraws every thirty seconds
             ;; and a bead landing above the selected one would otherwise slide
             ;; the mark onto whatever row took its line.
             (selected (cerebro--bead-at-point)))
        (erase-buffer)
        (insert (string-join lines "\n"))
        (unless (and selected (cerebro--goto-bead selected))
          ;; Selected bead merged, closed, or claimed away while it was marked.
          (cerebro--goto-first-bead))
        ;; A window keeps its own point when its buffer is not the selected
        ;; one, so moving the buffer's point above is not enough: the mark
        ;; would stay on line 1 - the "Claimed 0" header - while the buffer
        ;; believed it was on a bead. Both the layout and the timer render
        ;; from another window, so this is the normal path rather than an edge.
        (dolist (window (get-buffer-window-list buffer nil t))
          (set-window-point window (point)))))))

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

(defvar cerebro-sweep-refresh-seconds 600
  "How often the Sweeps section re-runs the claims and epics sweep scripts.

Ten minutes: Cerebro's own cadence for these sweeps (`agents/orchestrator.md'),
and slower than the thirty-second bead timer on purpose - each sweep script
fetches from origin and spawns a `bd' call per candidate, which is
considerably more than `cerebro--gather-beads's one call.")

(defvar cerebro--sweep-timer nil
  "The Sweeps section's own refresh timer, or nil.

Global, not buffer-local, for the same reason `cerebro--beads-timer' is: it
has to be able to cancel itself once the buffer is gone.")

(defvar-local cerebro--sweep-findings nil
  "The sweep findings as of the last `cerebro--sweep-tick', a list of
\(LABEL . FINDING\). What `cerebro--beads-render' actually draws - see
there for why the render does not gather this itself.")

(defun cerebro--sweep-tick (buffer)
  "Refresh BUFFER's sweep findings and redraw; called every
`cerebro-sweep-refresh-seconds', and once from `cerebro--beads-buffer' so
the section is not empty until the first ten minutes are up."
  (if (buffer-live-p buffer)
      (with-demoted-errors "cerebro: %S"
        (with-current-buffer buffer
          (setq cerebro--sweep-findings (cerebro--gather-sweeps (cerebro--repo-root))))
        (cerebro--beads-render buffer))
    (cancel-function-timers #'cerebro--sweep-tick)
    (setq cerebro--sweep-timer nil)))

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
                           #'cerebro--beads-tick buffer)))
      (unless (timerp cerebro--sweep-timer)
        ;; Run once immediately, in the foreground, so the Sweeps section is
        ;; not simply empty for the first ten minutes of a fresh `M-x cerebro'.
        (cerebro--sweep-tick buffer)
        (setq cerebro--sweep-timer
              (run-at-time cerebro-sweep-refresh-seconds cerebro-sweep-refresh-seconds
                           #'cerebro--sweep-tick buffer))))
    buffer))

;;; The buffer


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
         ;; The interactive five write the same file when they can (ah-2n3.2),
         ;; so their names are gathered alongside the roster's - one read per
         ;; name per tick either way, and `cerebro--derive-interactive' falls
         ;; back to the process scan for whichever of them have none.
         (states (cerebro--gather-states
                  repo-root (append (mapcar #'car cerebro-interactive-agents) roster)))
         (args (cerebro--system-args))
         (owned (cerebro--owned))
         (now (current-time))
         (agents (cerebro--derive roster cerebro-interactive-agents states
                                          #'cerebro--pid-alive-p args owned)))
    (setq cerebro--agents agents)
    (setq tabulated-list-entries
          (mapcar (lambda (a)
                    (cerebro--entry a now (cerebro--stop-flag-p repo-root (cerebro-agent-name a))))
                  agents))))

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
same way `cerebro--bd-json' degrades rather than taking the buffer down."
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

(defun cerebro--sync-list-windows ()
  "Give every window showing the current buffer the buffer's own point.

`tabulated-list-print' restores the buffer's point by id, but a window
whose buffer is not selected keeps its own point - the timer almost
always renders from the detail or beads window, so without this the
list window's selection walks to the top on every refresh.  Mirrors the
`set-window-point' loop in `cerebro--beads-render'."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (set-window-point window (point))))

(defun cerebro--tick (buffer)
  "Refresh BUFFER if it is still alive; called every 5s while it lives.

The refresh comes first: `cerebro--supervise' acts on what the revert just
derived, so it never decides from a state file read five seconds ago."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (revert-buffer)
      (cerebro--sync-list-windows)
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
  "Major mode listing the atlantis-hud agent fleet.

\\{cerebro-mode-map}"
  (setq tabulated-list-format
        [("Agent" 14 nil) ("Role" 13 nil) ("State" 10 nil) ("Bead" 10 nil) ("Bead/Phase" 10 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'cerebro--revert nil t)
  (add-hook 'kill-buffer-hook #'cerebro--cancel-timer nil t)
  (add-hook 'kill-buffer-hook #'cerebro--kill-prune-watcher nil t)
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
