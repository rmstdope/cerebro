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
;;     ah-u3i and ah-2n3.2): { state: "idle"|"working"|"asking"|"waiting",
;;     phase, bead, since, phase_since, pid }.  Every implementer writes one;
;;     since ah-2n3.2 the interactive roles do too.
;;   - `scripts/roster', the fleet: name, role and kind per agent, in
;;     display order.
;;   - liveness for the interactive roles (Xavier, Cerebro, Moira, Psylocke,
;;     Forge) is the state file first, when one exists for a live pid, and
;;     falls back to scanning system processes for the `--name <Name>'
;;     argument `scripts/launch' passes when it does not - a session started
;;     by hand, outside this fleet, has no file and still has to show `up'.
;;     That scan is machine-wide and a name is unique only inside one
;;     consumer, so it is narrowed to this repository's own sessions first
;;     (`cerebro--consumer-args') - otherwise a second checkout's Xavier
;;     shows as this one's.  The rule - name AND root, on one command line -
;;     is `cerebro--session-args-p', and both paths are built from it (cb-lzi).

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

;;; Errors - said once, and kept

;; The writers live with the rest of the log (`cerebro--log-error',
;; `cerebro--report-error'); the macro is here because it is used long before
;; that section and a macro must be defined before its first call site is
;; compiled.

(defmacro cerebro--with-logged-errors (context &rest body)
  "Run BODY, demoting an error to a message the way `with-demoted-errors\=' does
and recording it in the view\='s error log under CONTEXT.

`with-demoted-errors\=' is how the five-second timer survives one broken agent,
one `bd\=' that will not answer, one launcher that cannot start - and it is also
how the reason for all three used to vanish, since the echo area is painted
over by the next render.  Same demotion, same nil, one extra line in
a file that is still there tomorrow."
  (declare (indent 1) (debug (form body)))
  ;; Gensym rather than a named variable: BODY is arbitrary code from nine
  ;; call sites, and a handler binding it could see would be a bug nothing
  ;; here would catch.
  (let ((err (gensym "cerebro--err")))
    `(condition-case ,err
         (progn ,@body)
       (error (cerebro--report-error ,context "%s" (error-message-string ,err))
              nil))))

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

(defun cerebro--fleet-role-names (fleet role)
  "The names in FLEET filling ROLE, in roster order.

Roster order is load-bearing for a role two agents hold: the P4 triage pass
belongs to the first planner alone (`skills/plan-bead\='), because two
sessions triaging one backlog interview the navigator twice over it."
  (mapcar #'car (seq-filter (lambda (row) (equal (nth 1 row) role)) fleet)))

(defun cerebro--list-height (agent-count)
  "Lines the agent list needs for AGENT-COUNT agents: the rows, the header
line and the mode line, so the list never scrolls and the bead panel gets
whatever the frame has left (was a constant of 20 for eighteen agents)."
  (+ agent-count 2))

(cl-defstruct cerebro-agent
  "One row of the fleet list."
  name role kind                       ; kind: 'interactive | 'implementer
  state                                ; 'up | 'working | 'idle | 'dead | 'asking
                                       ;  | 'waiting | 'standby | 'unknown
  bead since external
  phase                                ; "build"|"gate"|"review"|"ci"|"rebase"|"merge" or nil
  phase-since                          ; ISO-8601 string, or nil
  wake-at                              ; ISO-8601 string when `waiting', else nil
  sessions                             ; processes of this name in this consumer, or nil
  raw                                  ; the state file's `state' string verbatim, or nil
  unverified-pid)                      ; the pid, when the session could not be proved this
                                       ; fleet's but names this agent (ah-ybsr); nil otherwise

(defun cerebro--canonical-root (root)
  "ROOT as one spelling: absolute, tilde expanded, one trailing slash.

`locate-dominating-file\=' abbreviates what it returns - \"~/repos/cerebro/\"
for a checkout under the home directory - and every caller but one expanded
it on the way to a file name, which hid the abbreviation until it reached
the one place a root is compared as a *string* (cb-5yr.1).  The reader
normalises here so no comparator downstream has to know."
  (file-name-as-directory (expand-file-name root)))

(defun cerebro--name-in-args-p (name args)
  "Non-nil if some string in ARGS names NAME via a whole-word \"--name NAME\"."
  (let ((needle (concat "--name[ \t]+" (regexp-quote name) "\\_>")))
    (cl-some (lambda (a) (and (stringp a) (string-match-p needle a))) args)))

(defun cerebro--root-in-args-p (root args)
  "Non-nil if some string in ARGS carries a path under ROOT, as a whole component.

ROOT may carry a trailing slash (`cerebro--repo-root\=' is a
`locate-dominating-file\=' result, which does), and /repos/cerebro is not
/repos/cerebro-hud: the needle is ROOT with its slash normalised and one
appended, so a sibling checkout named for the same prefix is not this
consumer.

ROOT is expanded here too, although `cerebro--repo-root\=' now returns it
canonical (`cerebro--canonical-root\='): this function is also reached with
roots that never came from that reader, and the cost of a second
`expand-file-name\=' is nothing.  Every other caller expands it on
the way to a file name, so the abbreviation was invisible until it reached
this function, which is the one place the root is compared as a string: a
process names `/Users/<you>/repos/...\=' and never `~\=', so nothing matched,
every agent read as having no live session, and `cerebro--derive-interactive\='
showed `up\=' for a role whose state file said `waiting\=' - with no supervision
behind it, which is the whole cb-5yr mechanism gone quiet (cb-5yr.1)."
  (let ((needle (concat (regexp-quote (directory-file-name (expand-file-name root))) "/")))
    (cl-some (lambda (a) (and (stringp a) (string-match-p needle a))) args)))

(defun cerebro--session-args-p (args name root)
  "Non-nil if the one command line ARGS is NAME's session of the fleet at ROOT.

THE rule, stated once (cb-lzi): a whole-word `--name NAME\='
\(`cerebro--name-in-args-p\=') AND a path under ROOT
\(`cerebro--root-in-args-p\='), which every session `scripts/launch\=' starts
carries in `--settings <root>/.../question-state.settings.json\='.  The
state-file path asks it of one pid's own args (`cerebro--session-alive-p\=');
the process-scan path asks it of every process, as `cerebro--consumer-args\='
followed by `cerebro--name-in-args-p\=' - the same two tests in the other
order, which `cerebro-test/scan-path-and-pid-path-apply-one-rule\=' pins.
`scripts/agent-alive\=' is the bash copy of this function, and both are held
to `tests/lib/session-args.cases\=', the one case table their two suites run."
  (and (stringp args)
       (cerebro--name-in-args-p name (list args))
       (cerebro--root-in-args-p root (list args))
       t))

(defun cerebro--consumer-args (args root)
  "Those of ARGS - one string per system process - that belong to ROOT\='s fleet.

The process scan behind `cerebro--name-in-args-p\=' is machine-wide, and an
agent\='s name is only unique inside one consumer: every consumer that takes
the built-in roster has a Xavier and a Beast.  Matching on the name alone
showed another repository\='s planners as `up\=' here, for exactly those roles
that had never run in this one - the state file is read first, so the lie
only surfaced where there was no file to read.

The discriminator is a path under ROOT in the process\='s own command line:
`scripts/launch\=' passes every session `--settings <scripts>/../hooks/
question-state.settings.json\=', which is inside the consumer whose fleet the
session belongs to, wherever the submodule is mounted.  ROOT may carry a
trailing slash (`cerebro--repo-root\=' returns a `locate-dominating-file\='
result, which does) and must match a whole path component, so that a
sibling checkout named for the same prefix is not this consumer.

A session that names no root at all - a bare `claude --name Xavier\=' typed
by hand, bypassing the launcher - is dropped rather than credited to this
fleet.  That is the deliberate half of the trade: the scan can no longer
prove such a session is ours, and claiming it is, is the defect being fixed."
  (seq-filter (lambda (a) (cerebro--root-in-args-p root (list a))) args))

(defun cerebro--consumer-processes (procs root)
  "Those of PROCS - (PID . ARGS) pairs - that belong to ROOT\='s fleet.

`cerebro--consumer-args\=' over pairs, applying the same
`cerebro--root-in-args-p\=' test, so a count of one name\='s sessions is a
count within one consumer and never across two (cb-lzi)."
  (seq-filter (lambda (proc) (cerebro--root-in-args-p root (list (cdr proc)))) procs))

(defun cerebro--session-pids (name procs)
  "The pids in PROCS - (PID . ARGS) pairs already narrowed to one consumer by
`cerebro--consumer-processes\=' - whose ARGS name NAME.

Ascending, so the echo line that prints them is stable from one keypress to
the next.  `cerebro--name-in-args-p\=' is the whole-word `--name NAME\=' test
and already ignores `--remote-control NAME\=', which every session also
carries: counting by a plain substring search would count each session
twice."
  (sort (delq nil
              (mapcar (lambda (proc)
                        (and (cerebro--name-in-args-p name (list (cdr proc)))
                             (car proc)))
                      procs))
        #'<))

(defun cerebro--apply-session-counts (agents procs)
  "Pure.  AGENTS with `sessions\=' set from PROCS, this consumer\='s (PID . ARGS).

Applied after derivation rather than inside `cerebro--derive\=', the way
`cerebro--apply-standby\=' is: `cerebro--derive\=' and its twenty tests take the
args as a list of strings, and the count needs the pids beside them.  Adding
the pairs alongside is cheaper than rewriting that signature for no gain."
  (mapcar (lambda (agent)
            (setf (cerebro-agent-sessions agent)
                  (length (cerebro--session-pids (cerebro-agent-name agent) procs)))
            agent)
          agents))

(defun cerebro--duplicated-p (agent)
  "Non-nil when AGENT\='s name has more than one session in this fleet.

nil `sessions\=' reads as one: the count is only set once
`cerebro--apply-session-counts\=' has run, and a row nobody counted is not a
duplicate."
  (> (or (cerebro-agent-sessions agent) 1) 1))

(defun cerebro--duplicate-message (name pids file-pid)
  "Pure.  The echo line for NAME with PIDS when FILE-PID is what its state
file names, or nil when the file names none of them.

FILE-PID is listed first and tagged, because it is the session every other
reading of the fleet is about - the row\='s state, its bead, its elapsed time
all come from that file, so the other pid is the stray.  When the file names
none of PIDS, nothing is tagged and the order is the ascending one
`cerebro--session-pids\=' returns.

There is deliberately no \"(this view)\" tag: the vterm buffer\='s process is
the shell or `claude\=' depending on how it was exec\='d, and a stray started
later is the one that wrote the file - so which session this Emacs holds
cannot be established honestly."
  (let* ((tagged (and file-pid (memq file-pid pids)))
         (ordered (if tagged (cons file-pid (delq file-pid (copy-sequence pids))) pids)))
    (format "%s has %d sessions in this fleet: %s — end the extra one from its own terminal"
            name (length pids)
            (mapconcat (lambda (pid)
                         (format "pid %d%s" pid
                                 (if (and tagged (= pid file-pid)) " (state file)" "")))
                       ordered ", "))))

(defun cerebro--live-processes (procs live-p)
  "Pure.  PROCS - (PID . ARGS) pairs - minus those whose pid LIVE-P denies.

The scan is cached for `cerebro-system-scan-seconds\=' (30), so a snapshot is
evidence about the moment it was taken and no later: for up to half a minute
it lists processes that have since exited.  `--name <Name>\=' in one of those
is exactly what the fallback in `cerebro--derive-interactive\=' reads as \"up,
started outside this fleet\".

That is what put `up\=' between `waiting\=' and `standby\=', with `RET\=' offering
\"running outside Emacs - use the terminal that started it\" for a session
that had already ended.  Worse than cosmetic: `up\=' is not `dead\=', and
`cerebro--derive-standby\=' converts `dead\=' alone, so the standby row that was
the whole point of ending the pass was the one thing the role could not
become until the cache expired.

Liveness rather than the park, because a role that ends its own turn exits
without the view killing it - nothing parks it, and there is no park to date
the snapshot against.  The pid simply stops being alive, which covers that
case and the parked one together.  It is the same rule `cerebro--session-alive-p\='
applies to the pid path: presence in a snapshot is not liveness, the way
presence in an alist was not (8dced0d).

LIVE-P is injected so the rule is testable as data; `cerebro--revert\=' passes
one built on `process-attributes\=', which is a handful of calls - this
consumer\='s own sessions - once per tick."
  (seq-filter (lambda (proc) (and (funcall live-p (car proc)) t)) procs))

(defun cerebro--derive-from-state (name role kind parsed owned-p &optional unverified-pid)
  "Build one `cerebro-agent' for NAME from a live, parsed state file PARSED.

ROLE and KIND are the row's static fields; OWNED-P is whether Emacs itself
started this session. Shared between an implementer and an interactive agent
once each has confirmed the file it read names a still-live pid - this is
the one place a raw `state' string becomes the `cerebro-agent-state' symbol
the rest of the view reads.

UNVERIFIED-PID, when non-nil, is the pid whose liveness came back
`unverified' rather than `proven' (`cerebro--session-liveness', ah-ybsr):
the file is trusted rather than substituted with a default, and this is what
tells the row to say so."
  (let* ((raw-state (alist-get 'state parsed))
         (state (cond ((equal raw-state "working") 'working)
                      ;; Blocked on a question only the navigator can
                      ;; answer, with a bead still in flight.
                      ((equal raw-state "asking") 'asking)
                      ;; The agent has finished a pass and ENDED ITS TURN,
                      ;; expecting a fresh session when there is another pass
                      ;; to make (ah-hiib.3).  Every agent's state since
                      ;; cb-1or.1, an implementer's included: a bead merged
                      ;; and closed, one handed back, or nothing to claim are
                      ;; all one idea.  `done', the older spelling, was
                      ;; retired by cb-1or.2 and now falls through to
                      ;; `unknown' below like any word this list has never
                      ;; seen.
                      ((equal raw-state "waiting") 'waiting)
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
                                :raw raw-state
                                :unverified-pid unverified-pid)))

(defun cerebro--derive-interactive (entry states session-alive-p args owned)
  "Derive one interactive agent's row from (NAME . ROLE) ENTRY.

STATES is an alist of (NAME . parsed-state-json-or-nil), the same one an
implementer's row is derived from; SESSION-ALIVE-P a predicate on (PID NAME) -
is that pid still *this* agent's session, not merely a live one, answering
`t', the symbol `unverified' or nil (`cerebro--session-alive-p''s own
contract, ah-ybsr); ARGS is the system process args list, already narrowed
to this consumer by `cerebro--consumer-args'; OWNED the names Emacs itself
started.

Liveness is the state file first, the process scan second: when STATES has
an entry for NAME whose pid is still alive - proven or merely unverified,
both truthy - the row comes from the file - `working'/`idle'/`asking' and a
phase, exactly like an implementer's row; an unverified pid also marks the
row rather than being treated as proof. Otherwise (no entry, or a pid that
is flatly not this agent's session - the file, if any, is a previous
session's, and the pid may since have been recycled onto something else)
this falls back to the three process-scan branches below, so a session
started by hand outside this fleet
\(`.claude/cerebro/scripts/launch Xavier' in a terminal\) with no file at all
still shows `up' - as long as it is a session of *this* consumer's fleet,
which is what ARGS having been filtered establishes."
  (let* ((name (car entry))
         (role (cdr entry))
         (parsed (cdr (assoc name states)))
         (pid (and parsed (alist-get 'pid parsed)))
         (liveness (and pid (funcall session-alive-p pid name)))
         (alive (and liveness t))
         (owned-p (and (member name owned) t)))
    (if alive
        (cerebro--derive-from-state name role 'interactive parsed owned-p
                                    (and (eq liveness 'unverified) pid))
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
pid's own command line to name this agent, since pids are recycled, and
answers `t', the symbol `unverified' or nil (ah-ybsr); OWNED the names Emacs
itself started."
  (let* ((parsed (cdr (assoc name states)))
         (pid (and parsed (alist-get 'pid parsed)))
         (liveness (and pid (funcall session-alive-p pid name)))
         (alive (and liveness t))
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
     (t (cerebro--derive-from-state name "implementer" 'implementer parsed owned-p
                                    (and (eq liveness 'unverified) pid))))))

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

(defun cerebro--up-names (agents)
  "Pure.  The names in AGENTS whose implementer session is up.

Up is every state but `dead\=' and `standby\=' - the two that mean there is no
session - and interactive roles are never listed: they have
`cerebro--parked\=', which records when a pass ended and is the answer this
stands in for.  What the caller does with it is `cerebro--seen-up\='."
  (delq nil (mapcar (lambda (agent)
                      (and (eq (cerebro-agent-kind agent) 'implementer)
                           (not (memq (cerebro-agent-state agent) '(dead standby)))
                           (cerebro-agent-name agent)))
                    agents)))

(defun cerebro--apply-standby (agents armed &optional failed)
  "Pure.  AGENTS with every armed, dead one of ours restated as `standby\='.

ARMED is `cerebro--armed\=': the names this Emacs has started and has not been
told to leave down.  Runs after `cerebro--derive\=', which is untouched - a
state file is never the source of `standby\=', because the view deleted that
file when it ended the session, and a name with no file and no process is
exactly what `cerebro--derive\=' calls `dead\='.  Armed is the only thing that
separates \"nobody is coming\" from \"a trigger will bring one back\".

External agents are excluded with everything else this view does not own.
Implementers are not: since cb-1or.1 one ends its pass with `waiting\=' like
a role, and every other way a session can end - the process quits,
the launcher refuses, the machine sleeps - reached nothing at all, and the
row sat dead until the navigator pressed `s\=' (cb-hzs).  An armed
implementer with no session is one whose session ended without finishing,
and standby is what says the view will bring it back.

FAILED is the names with a recorded abnormal exit - the keys of
`cerebro--last-exit\=' (cb-eat).  Standby is *armed and not failed since*: a
launch that was refused died the moment it started, and a row that promised a
trigger was coming would say something untrue, once every wake floor, for as
long as the refusal stood.  The record carries this rather than the armed set
because `cerebro--note-exit\=' runs from vterm\='s sentinel with an arbitrary
buffer current while `cerebro--armed\=' is buffer-local; the record is global,
and `cerebro--launch\=' clears a name\='s entry before spawning, which is what
makes `s\=' the way back."
  (mapcar (lambda (agent)
            (if (and (eq (cerebro-agent-state agent) 'dead)
                     (not (cerebro-agent-external agent))
                     (member (cerebro-agent-name agent) armed)
                     (not (member (cerebro-agent-name agent) failed)))
                (let ((copy (copy-cerebro-agent agent)))
                  (setf (cerebro-agent-state copy) 'standby)
                  copy)
              agent))
          agents))

;;; Formatting

(defface cerebro-standby
  '((t :inherit font-lock-keyword-face))
  "The standby glyph: a dotted circle, for a role the view will start again.

Blue rather than the grey of `dead\=': somebody *is* coming back, so it is not
grey\='s \"nobody is there\".  Hollow rather than the filled diamond of `idle\=',
which is the other blue: nothing is running here at all, where an idle agent
has a session up and no bead."
  :group 'cerebro)

(defface cerebro-idle
  '((default :weight normal)
    ;; Blue that survives its background: a light blue disappears on a light
    ;; one, so that case gets the darker royal blue.
    (((class color) (background dark))  :foreground "DodgerBlue")
    (((class color) (background light)) :foreground "RoyalBlue")
    (t :inherit font-lock-keyword-face))
  "The idle glyph: a filled diamond, blue, for a session that is up with no bead.

Blue and a diamond, both, because each on its own has already failed once
against `dead\=' (cb-9qm): the gold filled dot it used to be was still read as
\"one of the circles\".  `standby\=' is the other blue and is hollow, so the two
differ in fill and outline as well as meaning.

Not the stock `warning' face, which Emacs defines as `:foreground
\"DarkOrange\" :weight bold' on any colour display - orange where it was not
asked for, and bold, which this view reserves for an agent waiting on an
answer.  Customize this one face if blue does not read against your theme."
  :group 'cerebro)

(defface cerebro-waiting
  '((default :weight normal)
    ;; Yellow that survives its background: pure yellow disappears on a light
    ;; one, so that case gets the darker goldenrod.
    (((class color) (background dark))  :foreground "gold")
    (((class color) (background light)) :foreground "goldenrod")
    (t :inherit warning))
  "The waiting glyph, and the unknown one: gold, for a live session with
nothing in hand.

Shared by `waiting\=' (a hollow half-dot, an interactive role between passes)
and `unknown\=' (a filled dot, a live session whose state word this view does
not recognise).  Gold rather than the grey of `dead\=', because a session *is*
there and may want looking at.

Not the stock `warning' face, which Emacs defines as `:foreground
\"DarkOrange\" :weight bold' on any colour display - orange where gold was
asked for, and bold, which this view reserves for an agent waiting on an
answer.  `idle\=' used to carry this colour and is blue since cb-9qm, so that
it could stop reading as one more circle beside `dead\='."
  :group 'cerebro)

(defun cerebro--glyph (state)
  "The single-character glyph for STATE, propertized."
  (cond
   ((memq state '(working up)) (propertize "●" 'face 'success))   ; ●
   ;; Waiting on the navigator: the one state that is asking for something.
   ((eq state 'asking) (propertize "?" 'face 'warning))           ; ?
   ;; Idle is a blue filled diamond - the only diamond in the vocabulary, so
   ;; neither shape nor colour is carrying the difference from dead's grey
   ;; hollow ○ or standby's blue hollow ◌ on its own. Both levers have been
   ;; spent on this pair once each already: idle was U+25CC DOTTED CIRCLE,
   ;; which is dead's U+25CB WHITE CIRCLE at terminal sizes; it became a
   ;; filled ● in gold, which was then the same picture as `working' and
   ;; `unknown' with only colour between them. Hence cb-9qm and U+25C6.
   ;; `unknown' is a live session the view does not understand - gold, for the
   ;; reason idle used to be: something the navigator may want to look at, and
   ;; grey (`dead') would say nobody is there, which is untrue. It keeps the
   ;; filled dot, and is the only gold one, so it cannot be mistaken for idle.
   ;; Waiting has a session up, nothing in flight, and a time it comes back
   ;; (ah-hiib.3). Gold like `unknown' - both are live sessions with no work
   ;; in hand - but a different shape, because who acts next differs: an idle
   ;; implementer is waiting for the navigator or the queue, a waiting role is
   ;; waiting for this very poll.
   ((eq state 'waiting) (propertize "◐" 'face 'cerebro-waiting))       ; ◐
   ;; Standby: no session at all, and one coming back when the trigger in the
   ;; For column fires. Hollow, because nothing is running; blue, because
   ;; grey would say nobody is coming (cb-5yr).
   ((eq state 'standby) (propertize "◌" 'face 'cerebro-standby))       ; ◌
   ((eq state 'idle) (propertize "◆" 'face 'cerebro-idle))             ; ◆
   ((eq state 'unknown) (propertize "●" 'face 'cerebro-waiting))       ; ●
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

(defun cerebro--countdown (left)
  "LEFT seconds rendered as \"→43m\", \"→21h04\" or \"→due\", or \"\" for nil.

Nil rather than zero for an unknown deadline, exactly as `cerebro--elapsed\='
treats an unparseable timestamp: a countdown the view cannot compute must
show nothing rather than a figure it made up.

A deadline already past reads \"→due\" rather than \"→0m\": between falling due
and the next tick acting on it there is a real, visible moment, and counting
downwards through zero would show a negative or a lie.

Was `cerebro--wake-column\=', which rendered a `waiting\=' role\='s own `wake_at\='.
Nothing waits for a wake any more (cb-5yr) - the countdown that is left is a
standby role\='s cadence trigger, in `cerebro--standby-label\='."
  (cond
   ((null left) "")
   ((<= left 0) "→due")
   ((>= left 3600) (format "→%dh%02d" (/ left 3600) (/ (mod left 3600) 60)))
   (t (format "→%dm" (/ left 60)))))

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

(defconst cerebro--column-minimums '(14 13 12 10 10)
  "The floor for each column: Agent, Role, State, Bead, Bead/Phase.

This project\='s table, kept as the floor so a short roster still gets a
readable one rather than columns that hug their own contents.

State is 12 rather than 10 because the longest thing it can say is
`working ■ ×2\=' - a flagged, duplicated session (cb-63m) - and
`tabulated-list-mode\=' truncates a cell at its column without saying so, so
a floor short of the vocabulary makes the view lie rather than wrap.")

(defun cerebro--column-widths (names roles bead-ids &optional for-texts)
  "Pure.  The five column widths for a fleet of NAMES filling ROLES, showing
BEAD-IDS, whose Bead/Phase column is about to show FOR-TEXTS.

Computed rather than configured: the widths are a fact about the data, and
four more settings would be four more things a consumer has to discover
before its own longer names stopped being truncated.  Agent allows two
columns for the state glyph and its space; Role and Bead one for the gap to
the next column.  State is a fixed vocabulary, so it is not derived from
anything a consumer varies.

Bead/Phase does vary, and FOR-TEXTS is what it varies with: every standby
label and exit line the render is about to show (cb-eat).  An elapsed-time
pair is never longer than the floor and need not be passed.  It matters
because `tabulated-list\=' truncates every column but the last, and the window
is sized to the table, so a long text in this one is cut at the window edge
instead."
  (let ((longest (lambda (strings) (apply #'max 0 (mapcar #'length strings)))))
    (list (max (nth 0 cerebro--column-minimums) (+ 2 (funcall longest names)))
          (max (nth 1 cerebro--column-minimums) (+ 1 (funcall longest roles)))
          (nth 2 cerebro--column-minimums)
          (max (nth 3 cerebro--column-minimums) (+ 1 (funcall longest bead-ids)))
          (max (nth 4 cerebro--column-minimums) (funcall longest for-texts)))))

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

(defun cerebro--entry (agent now &optional flagged bead-width standby-label exit-line)
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

STANDBY-LABEL, when non-nil, is what the Bead/Phase column shows for a
`standby' row instead of an elapsed time: what the role is waiting for
\(`cerebro--standby-label', cb-5yr).  Passed in rather than computed here
because it is derived from the bead panel and the fleet, which this
function - pure, and one call per row - must not reach into.

EXIT-LINE, when non-nil, is what the Bead/Phase column shows for a `dead\='
row: the last line its session printed before it died abnormally, already
formatted by `cerebro--exit-line\=' (cb-eat).  Passed in for the same reason
STANDBY-LABEL is - this function is pure and never reaches into
`cerebro--last-exit\='.

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
                             ;; The unverified marker comes first: it
                             ;; qualifies the state word itself (this row is
                             ;; trusted, not proven), where the flag is about
                             ;; the bead in flight and the count about the
                             ;; session running it - two different questions
                             ;; from "what does this state mean" (ah-ybsr).
                             (if (cerebro-agent-unverified-pid agent)
                                 (propertize " ?" 'face 'shadow)
                               "")
                             (if (and flagged in-flight) " ■" "")
                             ;; Flag first, then the count: the flag is about
                             ;; the bead in flight, the count about the
                             ;; session running it (cb-63m).
                             (if (cerebro--duplicated-p agent)
                                 (propertize (format " ×%d" (cerebro-agent-sessions agent))
                                             'face 'warning)
                               ""))
                     attention))
         (bead-col (cerebro--emphasize
                    (cond (external "—")
                          ((cerebro-agent-bead agent)
                           (truncate-string-to-width (cerebro-agent-bead agent)
                                                    (or bead-width 10) nil nil "…"))
                          (t ""))
                    attention))
         (for-col (cerebro--emphasize
                   (cond (external "")
                         ;; A standby row has no session and so no elapsed
                         ;; time worth showing; what it is waiting for is the
                         ;; only thing the navigator can act on.
                         ((eq state 'standby) (or standby-label ""))
                         ;; A session this view started that died on its own:
                         ;; the reason it printed, where the navigator reads
                         ;; the row rather than behind `RET'.
                         ((and (eq state 'dead) exit-line)
                          (propertize exit-line 'face 'error))
                         (t (cerebro--for-column (cerebro-agent-since agent)
                                                 (cerebro-agent-phase-since agent) now)))
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
      ;; `cerebro--assignee-enrich\=', named by that sweep's row in
      ;; `cerebro--sweeps\=', puts it on the candidate before labelling, so
      ;; this stays a pure formatter like the three arms above.
      (`(unassign ,id ,_priority)
       (format "unassign %s — %s is %s" id .assignee
               (if .assignee_bead (format "on %s" .assignee_bead) "not running")))
      ;; The short sha, seven-plus characters as every other line in the fleet
      ;; view uses - the full one lives in the bead's `verified_at\=' field,
      ;; where `git merge-base\=' reads it, and a person reads this.
      (`(recheck ,id ,_priority)
       (format "recheck %s — verdict at %s, %d merge%s since"
               id (substring .verified_at 0 8) .merges_since
               (if (= .merges_since 1) "" "s"))))))

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
      (`(recheck ,_id 0) (propertize line 'face 'warning))
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
nobody will ever close, has no line: `scripts/fleet-history' treats `waiting'
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
                      (and pid (cerebro--session-alive-p pid name repo-root)
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
`cerebro--fleet-snapshot\=' derives all three from one call to
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
`bd' is waited for rather than stacked.

An entry is a claim on the key, and like every other recorded handle here it
is only as good as the process it names: `cerebro--run-async' asks
`process-live-p' rather than trusting the entry to have been cleared.  It is
removed by the sentinel, which fires only on a status change, so a process
reaped without one - a machine suspended and resumed - would otherwise hold
its key forever, and every later refresh would return `busy' having started
nothing.  That froze a fleet view for five hours on a bead panel stamped
three minutes after it opened, with `bd' answering in two seconds all the
while.  Nothing re-arms it: this variable is global and `M-x cerebro' does
not reset it, so the freeze survives closing the buffer and reopening it.")

(defun cerebro--run-async (key repo-root argv callback)
  "Run ARGV (program, then args) in REPO-ROOT without blocking Emacs.

CALLBACK is called exactly once, later, with the program's stdout as a
string when it exited zero and nil otherwise - non-zero exit, a signal, the
program missing, or `cerebro-subprocess-timeout-seconds' passing first, in
which case the process is killed. Returns `started', or `busy' when a run
under KEY is already in flight - then nothing is started and CALLBACK is
never called. Never signals."
  (if (let ((claim (assq key cerebro--inflight)))
        ;; Presence is not enough - see `cerebro--inflight'. A claim whose
        ;; process has gone is dropped here rather than waited on, which is
        ;; what makes the key recoverable without restarting Emacs.
        (cond ((null claim) nil)
              ((process-live-p (cdr claim)) t)
              (t (setq cerebro--inflight (assq-delete-all key cerebro--inflight))
                 nil)))
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
                       ;; Unregister THIS process, never whatever holds the key
                       ;; now. Since a dead claim is dropped above, a late
                       ;; sentinel can arrive with a live replacement already
                       ;; registered, and deleting by key alone would free it -
                       ;; trading a permanent freeze for two concurrent runs.
                       (when (eq (cdr (assq key cerebro--inflight)) proc)
                         (setq cerebro--inflight (assq-delete-all key cerebro--inflight)))
                       (let ((timer (process-get proc 'cerebro-timeout)))
                         (when timer (cancel-timer timer)))
                       (let ((output (and (eq (process-status proc) 'exit)
                                          (zerop (process-exit-status proc))
                                          (with-current-buffer out (buffer-string)))))
                         (kill-buffer out)
                         (cerebro--with-logged-errors (format "%s callback" key)
                           (funcall callback output)))))))
            (process-put proc 'cerebro-timeout
                         (run-at-time cerebro-subprocess-timeout-seconds nil
                                      (lambda ()
                                        (when (process-live-p proc)
                                          (delete-process proc)))))
            (push (cons key proc) cerebro--inflight)
            'started)
        (error
         (when (buffer-live-p out) (kill-buffer out))
         (cerebro--with-logged-errors (format "%s callback" key)
           (funcall callback nil))
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

(defun cerebro--findings-from (repo-root outputs)
  "The sweep findings (LABEL . FINDING) from OUTPUTS, an alist (KEY . parsed
JSON) keyed as `cerebro--sweeps\=' is. Computed at answer time (called from
`cerebro--request-sweeps\='s callback) so the live fleet is the one described
when the findings are shown, not the one that existed when the scripts were
kicked off.

The impure half only: it reads the live fleet once, through
`cerebro--fleet-snapshot\=', and hands that to
`cerebro--findings-from-snapshot\=', which is where the judging lives and is
pure. One read rather than three helper calls - see that function."
  (cerebro--findings-from-snapshot outputs (cerebro--fleet-snapshot repo-root)))

(defun cerebro--request-sweeps (repo-root callback)
  "Run the sweep scripts without blocking, one after the other; CALLBACK gets
the (LABEL . FINDING) list when all of them have answered, or nil when any
did not - including a script exiting zero but printing something that is not
JSON, in which case no later script is started at all. Returns `busy\=' if a
sweep is already out.

List-driven rather than hand-nested: the scripts are identical in shape, and
a callback nest one level deep per script stops being readable at three."
  (cerebro--request-sweeps-1 repo-root (cerebro--sweep-scripts) nil callback))

(defun cerebro--request-sweeps-1 (repo-root remaining acc callback)
  "Run REMAINING sweep scripts in order, collecting parsed output onto ACC
\(reversed) as (KEY . PARSED) pairs, then call CALLBACK. See
`cerebro--request-sweeps\='."
  (if (null remaining)
      (funcall callback (list (cerebro--findings-from repo-root (nreverse acc))))
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
                                          (cons (cons key parsed) acc) callback)))))))))

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
        (cerebro--log repo-root 'sweep (list (cons 'command command-string)))
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

(defcustom cerebro-wake-intervals '(("verifier" . 300) ("planner" . 0)
                                    ("implementer" . 0))
  "Overrides of `cerebro-wake-interval-default\=', as (KEY . SECONDS).

KEY is a role or an agent name, and a name-keyed entry wins over a
role-keyed one - most-specific-first, the way `models.conf\=' resolves a
model.  Roles come from `scripts/roster\=', so a role key holds for whatever
a consumer calls the agent that fills it.

The planners have no floor at all.  Theirs is the one cadence a clock was
always the wrong tool for - a buffer that has just run short is work the
fleet is already idle behind, and ten minutes of it is ten minutes of
implementers with nothing to take.  What used to need the floor - a trigger
no pass can clear - is `cerebro--unless-unchanged\=', which asks whether
anything changed instead of how long it has been.

The implementers have none either, for the same reason and a starker one:
a standby implementer is one between beads, and a planned bead it has not
taken is the fleet idle behind work that is ready.  What starts it is that
bead (`cerebro--trigger'), not a clock, and what spaces a retry that keeps
failing is `cerebro-retry-backoff\=', measured from the failed start itself.

The verifier, at five minutes: Psylocke\='s own prose asks for five, and
the log agrees - 90 idle intervals, median 4.7 min - because a bead can
merge, wait and still be waiting when the navigator asks what happened to
it.  Every other role measured at ten and takes the default.  It was keyed
on the name \"Psylocke\" until ah-qled.9, which is a name a consumer\='s fleet
need not have."
  :type '(alist :key-type string :value-type integer)
  :group 'cerebro)

(defcustom cerebro-end-grace 30
  "Seconds a role that has finished a pass is left before its session is ended.

A role writes `waiting\=', prints one line saying what the pass
found, and stops.  The write comes first, so the line lands after it: this is
how long the view waits for that line before it kills the process and keeps
the buffer as the record of the pass.

Half a minute rather than five seconds because the line is the only thing
that survives the session, and rather than five minutes because a role whose
trigger is already true is doing nothing while it stands here."
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

(defcustom cerebro-idle-ends-pass-roles nil
  "Interactive roles whose `idle\=' means \"my pass is over, end me\".

Empty by default: every interactive role in this fleet ends a pass by
writing `waiting\=' (ah-hiib.3), Forge included since it stopped writing
`idle\=' at the end of its sweep (`agents/architect.md').  The list is the
mechanism a consumer role would use if it wrote `idle\=' there instead.

Every other role\='s `idle\=' means something quite different: a session with
nothing in hand, waiting to be spoken to.  Cerebro sits in exactly that
state between the navigator\='s questions, and ending it there killed the
session the navigator was about to talk to and restated it as `standby\='.
So the list is a whitelist, not a guess: a role absent from it stays up on
`idle\=' until the navigator kills it, or until a stop flag retires it."
  :type '(repeat string)
  :group 'cerebro)

(defun cerebro--end-decision (agent stop-flag-p now)
  "Pure.  `retire\=', `end\=' or nil for an interactive AGENT whose pass is over.

The flag wins and lands at once: nothing is in flight, so there is nothing
for the grace period to protect.  Otherwise the session is ended once it has
stood in the finished state for `cerebro-end-grace\=', and never on a state
file whose timestamp says nothing at all - a torn file must not read as a
grace that has expired."
  (cond
   (stop-flag-p 'retire)
   ((let ((stood (cerebro--seconds-since (cerebro-agent-since agent) now)))
      (and stood (>= stood cerebro-end-grace)))
    'end)))

(defun cerebro--supervise-action (agent stop-flag-p now)
  "What the fleet poll should do about AGENT at NOW, or nil for nothing.

STOP-FLAG-P is whether `.cerebro/state/<name>.stop' exists.  The
answers are:

`retire'  - AGENT finished its bead and a stop flag says do not start
            another; or AGENT is on `standby' under one - its session died
            before it could finish, and the flag still means no further bead,
            so it is disarmed rather than retried (cb-hzs); or AGENT is
            `idle' under a stop flag - nothing is in
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
`end'     - AGENT has finished a pass - `waiting', or `idle' for a role in
            `cerebro-idle-ends-pass-roles' that writes that instead - and
            `cerebro-end-grace' has passed since it said so (cb-5yr).  Its
            session is ended and its buffer kept; a fresh one starts when the
            agent's own trigger fires (`cerebro--trigger'), which is what
            makes a session one pass deep the way an implementer's is one
            bead deep.  An implementer reaches it the same way since
            cb-1or.1 - a bead merged and closed, one handed back, or nothing
            to claim are one pass ending.  This replaced `poke', which
            typed into the session it had rather than starting a new one.

Only a session Emacs itself started is supervised.  One running in
somebody's own terminal is theirs to end, and a dead one stays dead -
restarting it would fight the navigator's own `k'.

The `kind' guard is load-bearing now that the interactive agents write the
same state file an implementer does (ah-2n3.2): Xavier, Cerebro, Moira,
Psylocke and Forge can show `asking' or, if one ever writes it in error,
`unknown', but never `retire'd or `nudge'd from here - they are
never replaced between beads because they have none.

Since ah-hiib.3 that guard is *per-arm* rather than wrapped round the whole
body, because `poke' is the one answer that belongs to the interactive roles
alone.  The warning it used to carry still stands and is now the reason for
the shape: `retire' and `nudge' name an implementer's kind
explicitly, so unifying this function cannot let a planner be restarted
mid-mockup-conversation by accident.  Being external still excludes
everything: every answer here ends in Emacs acting on a session it owns."
  (unless (cerebro-agent-external agent)
    (pcase (cerebro-agent-state agent)
      ;; An implementer's `idle' is unchanged. An interactive one is ended
      ;; only when its role says `idle' is how it finishes a pass
      ;; (`cerebro-idle-ends-pass-roles' - Forge, at the end of a sweep).
      ;; For every other role `idle' means a live session with nothing in
      ;; hand, waiting to be spoken to: Cerebro sits there between the
      ;; navigator's questions, and ending it there took down the very
      ;; session the navigator was about to use. A stop flag still lands on
      ;; any of them - nothing is in flight, so `f' means stop now.
      ('idle
       (pcase (cerebro-agent-kind agent)
         ('implementer (and stop-flag-p 'retire))
         ('interactive
          (if (member (cerebro-agent-role agent) cerebro-idle-ends-pass-roles)
              (cerebro--end-decision agent stop-flag-p now)
            (and stop-flag-p 'retire)))))
      ;; Nothing is in flight for a waiting agent - no bead, no claim, no
      ;; worktree - so a stop flag lands cleanly and *now*, which is the
      ;; behaviour that was impossible while a role slept inside its own
      ;; session and the flag had no gap to land in.  No kind guard since
      ;; cb-1or.1: an implementer between beads has ended its pass in
      ;; exactly the sense this arm means.
      ('waiting (cerebro--end-decision agent stop-flag-p now))
      ;; A standby implementer is one the view means to start again
      ;; (cb-hzs).  A stop flag written before its session died still says
      ;; *no further bead*, so it is retired - the flag cleared with it -
      ;; rather than retried.  A standby role's flag belongs to
      ;; `cerebro--start-due', which is where a role is started from.
      ('standby (and (eq (cerebro-agent-kind agent) 'implementer)
                     stop-flag-p 'retire))
      ('asking
       (let ((waited (cerebro--seconds-since (cerebro-agent-since agent) now)))
         ;; A stop flag makes no difference: the bead is still in flight, so
         ;; the question still needs an answer or a hand-back.
         (and (eq (cerebro-agent-kind agent) 'implementer)
              waited (>= waited cerebro-answer-timeout) 'nudge)))
      (_ nil))))


;;; cb-5yr: why a role on standby should start now

(defcustom cerebro-cadence-triggers
  '(("user-feedback" . 3600) ("reviewer" . 3600) ("architect" . 3600))
  "Roles started again after this long on standby whatever else is true.

\(ROLE . SECONDS).  Moira and Cypher hourly, because what they watch moves
outside this fleet - an issue, somebody else\='s pull request - and a floor is
what covers whatever the `gh\=' reader could not see.  Forge hourly too: its
watermark makes a sweep with nothing new in it nearly free, and an hourly
floor keeps a day's debt from arriving in one lump.

A role absent here starts on its condition alone: a planner and the verifier
have conditions that are true whenever there is work, so a floor would only
start them with nothing to do.  `orchestrator\=' has neither, and is `s\=' only -
Cerebro starts nothing on its own, including itself."
  :type '(alist :key-type string :value-type integer)
  :group 'cerebro)

(defun cerebro--cadence-figure (seconds)
  "SECONDS as the figure a cadence reason names: \"60m\", \"24h\".

Minutes under a day and hours at or over one, which is what makes an hourly
cadence read as \"60m since its last pass\" rather than \"1h\": the point of the
line is how long the role has been down, and an hour of it is still counted
in minutes by anyone reading the fleet."
  (if (< seconds 86400)
      (format "%dm" (/ seconds 60))
    (format "%dh" (/ seconds 3600))))

(defun cerebro--cadence-noun (role)
  "What ROLE calls the thing it does once per cadence."
  (if (equal role "architect") "sweep" "pass"))

(defcustom cerebro-parked-labels '("human" "triage:declined")
  "Labels that say a bead is the navigator\='s rather than a planner\='s.

`skills/plan-bead\=' does not stall when the navigator is away: a bead it
cannot decide alone is parked with `human\=', a P4 it asked about and got no
answer for is marked `triage:declined\=', and the pass ends.  Both marks are
durable precisely *because* the pass ends, and both of the skill\='s own
queries exclude them.

So the trigger excludes them too.  Without that the fleet view counts work
the next pass may not touch, starts a session to find nothing to do, and
starts it again when that one ends - which is the loop the wake-interval
floor used to damp with a clock.

Blockedness is deliberately *not* on this list.  `plan-bead\=' plans beads
whose blockers are unbuilt on purpose - `bd ready\=' hides the ones most worth
having planned - so a blocked bead is a planner\='s work like any other."
  :type '(repeat string)
  :group 'cerebro)

(defcustom cerebro-planner-buffer-floor 2
  "The fewest planned, unclaimed beads the fleet wants, whatever is running.

`skills/plan-bead\=' sizes the buffer at one planned bead per implementer on
the roster, minus any told to finish, and never fewer than this - a roster of
one builder still wants two, so a second builder started by hand has
something to claim, and a queue that begins filling only once it is up is a
queue that is late.

The shell-side owner of the whole rule - this floor and
`cerebro-parked-labels\=' both - is `scripts/planner-buffer\=', which the
skill calls instead of restating a query.  This copy exists because
`cerebro--trigger-context\=' is evaluated once per standby row per
five-second tick and cannot afford a subprocess;
`cerebro-test/the-trigger-counts-what-planner-buffer-counts\=' is what keeps
the copy honest."
  :type 'integer
  :group 'cerebro)

(defun cerebro--actionable-beads (beads)
  "Pure.  BEADS minus the ones parked in the navigator\='s queue.

See `cerebro-parked-labels\=' for which those are and why the trigger has to
know."
  (seq-remove (lambda (bead)
                (seq-intersection (cerebro--bead-labels bead) cerebro-parked-labels
                                  #'equal))
              beads))

(defun cerebro--planner-want (implementers)
  "Pure.  How many planned, unclaimed beads the fleet wants right now.

One per implementer on the roster that has not been told to finish, never
fewer than `cerebro-planner-buffer-floor\='.  The shell copy is
`scripts/planner-buffer --want\='; see that script and the floor\='s
docstring for why there are two."
  (max cerebro-planner-buffer-floor implementers))

(defcustom cerebro-retry-backoff '(0 30 120 600)
  "Seconds to wait before starting a role again, by consecutive failed starts.

The Nth entry is the wait after N failed starts; past the end of the list the
last entry is the ceiling.  A failed start is one that produced no pass at all
\(`cerebro--start-failed-p\='), which is what a launch `scripts/launch-preflight\='
refuses looks like from here: the view records a start, no session appears,
and the role is standby again on the next tick.

The first entry is 0 on purpose.  A session that died once should come back
immediately - that is the case b94e782 exists for, and a clock there would
cost the fleet a pass every time something went wrong once.  What escalates is
the second failure and every one after it.

Why it is needed at all: b94e782 traded a permanent park for an unbounded
retry, and both are wrong.  With `main\=' one commit ahead of `origin/main\=' the
preflight refused every launch, and the view attempted Xavier 135 times in a
row, five seconds apart, with nothing to show for any of them."
  :type '(repeat integer)
  :group 'cerebro)

(defcustom cerebro-give-up-after 5
  "Consecutive starts that produced no pass and no reason before the view
stops retrying a name.

The backoff above bounds how *often* a refused start is retried; it never
bounds how *many* times, so a name whose launcher refused for a reason the
view could not read went on being started every ten minutes for ever.  On
2026-08-26 four agents reached thirty-odd failed starts each while the fleet
was down for a day.  A fleet that has failed this many times running is not
going to succeed on the next one without a human (cb-ccl).

Only a *silent* failure counts towards it: a launcher that said why parks the
row `dead\=' with its line the moment it refuses (cb-eat), and never reaches
this at all.  `s\=' is the way back from either."
  :type 'integer
  :group 'cerebro)

(defun cerebro--start-failed-p (started ended)
  "Pure.  Non-nil when the start at STARTED produced no pass by ENDED.

The same comparison `cerebro--unless-unchanged\=' makes, named for what it
means: a pass that ran leaves an end later than its start, and a launch that
never became a session leaves the previous pass\='s, or nothing."
  (and started (or (null ended) (<= ended started)) t))

(defun cerebro--retry-delay (failures)
  "Pure.  Seconds to wait after FAILURES consecutive failed starts.

See `cerebro-retry-backoff\='.  Past the end of the schedule the last entry is
the ceiling, so a launch that has been refused all morning is retried at a
steady interval rather than at an ever-growing one nobody would see end."
  (let ((schedule cerebro-retry-backoff))
    (cond ((null schedule) 0)
          ((<= failures 0) (car schedule))
          ((>= failures (length schedule)) (car (last schedule)))
          (t (nth (1- failures) schedule)))))

(defun cerebro--retry-wait (failures started now)
  "Pure.  Seconds until a start after FAILURES failed starts is due at NOW.

Measured from STARTED, the failed start itself, so the wait a row counts
down and the wait `cerebro--start-due\=' enforces are one calculation.  Zero
when it is due, and zero for a nil STARTED - a name this Emacs has never
started has nothing to wait out."
  (if started (max 0 (- (+ started (cerebro--retry-delay failures)) now)) 0))

(defun cerebro--retry-figure (seconds)
  "Pure.  SECONDS as the figure a retry row names: \"45s\", \"2m\".

Minutes are rounded up, so a row never says a smaller number than the wait
actually left - \"1m\" with 61 seconds to go would come due a minute after it
said it would."
  (if (< seconds 60)
      (format "%ds" (ceiling seconds))
    (format "%dm" (ceiling (/ seconds 60.0)))))

(defun cerebro--retry-when (left failures)
  "Pure.  When a retry is due, in the words the standby placeholder uses.

LEFT is seconds (`cerebro--retry-wait\='), FAILURES the starts that have come
to nothing: \"now\", \"now (3 failed starts)\", \"in 45s (1 failed start)\"."
  (concat (if (> left 0) (concat "in " (cerebro--retry-figure left)) "now")
          (if (> failures 0)
              (format " (%d failed start%s)" failures (if (= failures 1) "" "s"))
            "")))

(defvar-local cerebro--failed-starts nil
  "Alist of (NAME . COUNT) - consecutive starts that produced no pass.

Written by `cerebro--start-due\=' when it launches: incremented when the
previous start of that name failed, and reset to zero when a pass has run
since.  It is what `cerebro--retry-delay\=' is indexed by.")

(defcustom cerebro-role-start-spacing '(("planner" . 30) ("implementer" . 30))
  "Minimum seconds between two starts of one ROLE, as (ROLE . SECONDS).

A role only two agents hold can have its condition come true for both at
once, and the planners do: they answer the same buffer rule off the same
panel, so a tick where it is true is a tick where it is true for Xavier and
for Beast.  The view started them in one breath more than once.

That is a race rather than an inefficiency.  A planner marks its candidate
with `planning:<its own name>\=' *after* the research rather than before, so
two sessions can be most of the way through planning one bead before either
writes anything the other could have seen.

Spacing counts PEERS only - see `cerebro--role-start-too-soon-p\=' - so a role
is never held by its own last start.  A role absent from this list is never
spaced: one holder cannot collide with itself.  `implementer\=' is started
from `cerebro--start-due\=' too since cb-1or.1, and 30 seconds between
implementer starts is what keeps a queue that fills from starting the whole
roster in one tick."
  :type '(alist :key-type string :value-type integer)
  :group 'cerebro)

(defun cerebro--role-start-spacing (role)
  "The spacing declared for ROLE in `cerebro-role-start-spacing\=', or nil."
  (cdr (assoc role cerebro-role-start-spacing)))

(defun cerebro--role-peers (agent agents)
  "Pure.  The names in AGENTS holding AGENT\='s role, excluding AGENT itself.

Who a start could race with.  A role with one holder has none, which is what
makes the spacing check answer \"no\" for every role but the planners without
naming any of them."
  (let ((role (cerebro-agent-role agent))
        (name (cerebro-agent-name agent)))
    (delq nil (mapcar (lambda (other)
                        (and (equal (cerebro-agent-role other) role)
                             (not (equal (cerebro-agent-name other) name))
                             (cerebro-agent-name other)))
                      agents))))

(defun cerebro--role-start-too-soon-p (peers starts spacing now)
  "Pure.  Non-nil when one of PEERS was started less than SPACING before NOW.

STARTS is `cerebro--started-at\=', the (NAME . `float-time\=') alist every launch
writes.  SPACING nil - a role that declares none - is never too soon.

It covers both halves of the race with one comparison.  Two starts in one
tick: `cerebro--launch\=' writes STARTS, so the second agent in
`cerebro--start-due\='s loop already sees the first.  Two starts in
consecutive ticks: the same record is still there five seconds later.

A peer with no entry has not been started by this Emacs and cannot have been
started too recently."
  (and spacing
       (seq-some (lambda (peer)
                   (let ((at (cdr (assoc peer starts))))
                     (and at (< (- now at) spacing))))
                 peers)
       t))

(defun cerebro--trigger-fingerprint (role context)
  "Pure.  Everything ROLE\='s condition rules read out of CONTEXT, or nil.

The fleet view records this when it starts a session and compares it when it
is deciding whether to start the next one: a trigger naming exactly the work
its own last pass was started for is a pass that could not clear it, and the
answer to that is to wait for something to change rather than to wait out a
clock (`cerebro--trigger\=').

It has to carry ids and not only counts.  A planner that plans one bead while
another arrives leaves every count where it was, and \"nothing changed\" would
then be wrong in the one direction that costs the fleet work.

Nil for a role with no condition rules - `orchestrator\=', anything a consumer
added - and for the cadence roles, whose reason is a clock this must not
hold: what Moira and Cypher watch moves outside this fleet, so the fleet
looking unchanged is evidence of nothing."
  (pcase role
    ("planner" (list (alist-get 'p0-unplanned context)
                     (alist-get 'p4-unranked context)
                     (alist-get 'planned context)
                     (alist-get 'implementers context)
                     (alist-get 'actionable-ids context)))
    ("verifier" (list (alist-get 'stale-verdicts context)
                      (alist-get 'merged-unverified context)))
    ;; Ids rather than a count for a reason of its own: the panel's beads
    ;; carry no dependencies, so a planned bead `bd ready' hides behind an
    ;; unbuilt blocker starts an implementer that can claim nothing.  That
    ;; pass changes no count at all, and a count here would start it again on
    ;; the next tick, for ever.  The ids move the moment the planned list
    ;; does, which is the only change worth another session (cb-1or.1).
    ("implementer" (list (alist-get 'planned-ids context)))
    (_ nil)))

(defun cerebro--unless-unchanged (role context reason)
  "Pure.  REASON, unless it names exactly what ROLE\='s last pass was started for.

The planners have no wake-interval floor (`cerebro-wake-intervals\='), and this
is what stands in its place.  A floor damps every trigger a pass cannot
clear - a P0 sitting in the navigator\='s queue, a session that died before it
planned anything - by refusing to start anything for ten minutes, which costs
ten minutes on every trigger a pass *can* clear as well.

Comparing fingerprints costs nothing on a real change: a bead arriving, one
being planned, an implementer coming up all change what
`cerebro--trigger-fingerprint\=' returns, and the next pass starts on the next
five-second tick.  What it holds is the case where a pass ended having
changed nothing the trigger measures, which is the only case a loop can come
out of.

`last-fingerprint\=' absent - a role this Emacs has not started - is not a
match, so a first start is never held.

And it holds a pass that RAN, never a launch that never became one.  The
fingerprint is recorded when a launch is *attempted* (`cerebro--launch\='),
which is before anything has proved a session exists, so a launch that dies
without leaving a recorded exit - the row falls back to standby rather than
dead - would otherwise buy this guard\='s silence for nothing.  That parked a
planner indefinitely on a P4 only his own triage pass could take: the board
could not change, because he was the one who would have changed it.

A pass that ran leaves an `ended-at\=' later than its `started-at\='.  A launch
that produced nothing leaves the previous pass\='s, which is earlier.  Both are
already in the context, so this stays a comparison like everything else here."
  (let ((last (alist-get 'last-fingerprint context))
        (now (cerebro--trigger-fingerprint role context))
        (started (alist-get 'started-at context))
        (ended (alist-get 'ended-at context)))
    (and reason
         (not (and last now (equal last now)
                   started ended (> ended started)))
         reason)))

(defun cerebro--trigger (agent context)
  "Pure.  Why AGENT, on standby, should start now - a string - or nil.

The string is the reason the echo line carries (`cerebro--start-message\='),
so it has to say what the navigator would otherwise have to go and look up.

CONTEXT is what `cerebro--trigger-context\=' gathers - `now\=',
`implementers\=', `planned\=', `p0-unplanned\=' (ids), `p4-unranked\=',
`actionable-ids\=', `planned-ids\=', `merged-unverified\=', `stale-verdicts\=' and `gh\=' (nil for
no answer yet, `failed\=', or (ISSUE-NUMBERS PR-NUMBERS)) - plus the five
per-agent facts `cerebro--agent-context\=' adds to it: `ended-at\=',
`started-at\=', `floor\=', `last-fingerprint\=' and `first-planner-p\='.

Every rule is gated on the floor first: `cerebro-wake-interval\=' is the
minimum gap between two *starts* of one role.  A role this Emacs has never
started has no floor to clear, and the planners have no floor at all - a
buffer that has just run short is the fleet already idle, and a clock there
costs the same ten minutes on every trigger a pass *can* clear.

What the floor was really protecting against is a trigger a pass cannot
clear - a P0 parked in the navigator's queue, a session that died before it
planned anything - being started again on the next tick, for ever.  Two
things do that job without a clock now: the counts exclude what the
navigator holds (`cerebro-parked-labels'), so a trigger that is true names
work a pass may actually take; and `cerebro--unless-unchanged\=' refuses a
condition that names exactly what this role's own last pass was started
for.  Both are comparisons, so a real change starts the next pass on the
next five-second tick.

The order inside a role is the order the plan\='s table gives, first true
wins, and it is the order of urgency: what is blocking the fleet, then what
is merely waiting for it."
  (let* ((role (cerebro-agent-role agent))
         (now (alist-get 'now context))
         (started (alist-get 'started-at context))
         (ended (alist-get 'ended-at context))
         (gh (alist-get 'gh context))
         (cadence (cdr (assoc role cerebro-cadence-triggers))))
    (when (or (null started) (>= (- now started) (alist-get 'floor context)))
      (or
       (cerebro--unless-unchanged
        role context
        (pcase role
         ("planner"
          (let ((p0 (alist-get 'p0-unplanned context))
                (p4 (alist-get 'p4-unranked context))
                (planned (alist-get 'planned context))
                ;; The buffer `skills/plan-bead' asks for: one planned,
                ;; unclaimed bead per implementer on the roster, never fewer
                ;; than two - since cb-1or.1 a builder between beads has no
                ;; session and is started by a planned bead, so counting
                ;; sessions sized the buffer at the floor on every quiet
                ;; board (cb-1or.3). A pass plans one bead, so a buffer two
                ;; short is two passes. An implementer told to finish is
                ;; left out: it takes no further bead
                ;; (`cerebro--trigger-context' excludes it). The rule's shell
                ;; copy, which the skill calls, is `scripts/planner-buffer'.
                (want (cerebro--planner-want (alist-get 'implementers context))))
            (cond
             ;; A P0 is planned the moment it appears, whichever planner sees
             ;; it: it is what the whole fleet is blocked behind.
             (p0 (format "P0 %s unplanned" (car p0)))
             ;; The triage pass belongs to the first planner on the roster
             ;; alone - two sessions interview the navigator twice over one
             ;; backlog.
             ((and (alist-get 'first-planner-p context) (> p4 0))
              (format "%d unranked" p4))
             ;; A short buffer is a reason to plan only while there is
             ;; something to plan. `actionable-ids' is the unplanned list -
             ;; already minus what the navigator holds, and minus what a
             ;; planner holds, since a bead labelled `planning' is a bucket of
             ;; its own (`cerebro--partition-beads'). Two planners over one
             ;; bead is what found this: Beast taking the last one moved it out
             ;; of unplanned, the buffer stayed short, and Xavier was started
             ;; to find an empty queue. The no-progress guard cannot cover it -
             ;; that same taking changes the fingerprint - so the rule asks,
             ;; the way the P0 and P4 rules already do by being derived from
             ;; this list.
             ((and (< planned want) (alist-get 'actionable-ids context))
              (format "buffer %d of %d" planned want)))))
         ("verifier"
          (let ((stale (alist-get 'stale-verdicts context))
                (merged (alist-get 'merged-unverified context)))
            (cond
             ;; A stale verdict is a bead the fleet cannot act on until she
             ;; looks again, so it comes before work merely awaiting a look.
             ((> stale 0) (format "%d stale verdict%s" stale (if (= stale 1) "" "s")))
             ((> merged 0) (format "%d merged, unverified" merged)))))
         ;; The lists `cerebro--gh-moved' filtered for this role, or nil
         ;; before `gh' has answered and `failed' when it stopped - in both
         ;; of those the cadence floor below is the whole trigger.
         ("user-feedback"
          (and (consp gh) (car gh) (format "issue #%s moved" (car (car gh)))))
         ("reviewer"
          (and (consp gh) (cadr gh) (format "PR #%s moved" (car (cadr gh)))))
         ;; A standby implementer is started for work, not for having died: a
         ;; planned, unclaimed bead is the whole condition (cb-1or.1).  Nil
         ;; before the panel has answered.  A launch that produced no session
         ;; is still retried on `cerebro-retry-backoff' - that is
         ;; `cerebro--start-due's, not this rule's.
         ("implementer"
          (let ((ids (alist-get 'planned-ids context)))
            (and ids (format "%d planned, unclaimed" (length ids)))))
         (_ nil)))
       (and cadence ended (>= (- now ended) cadence)
            (format "%s since its last %s"
                    (cerebro--cadence-figure cadence) (cerebro--cadence-noun role)))))))

(defun cerebro--gh-instant (s)
  "Pure.  S, an ISO-8601 instant as `gh' prints one, as `float-time', or nil
when it is missing or unparseable.

`updatedAt' comes back as \"2026-08-24T13:00:00Z\" and every moment it is
compared against - a role's `ended-at' - is a `float-time', so the
conversion happens once, here."
  (and (stringp s)
       (condition-case nil
           (float-time (encode-time (iso8601-parse s)))
         (error nil))))

(defun cerebro--gh-moved (issues prs me ended-at)
  "Pure.  (ISSUE-NUMBERS PR-NUMBERS): the open issues, and the open non-draft
pull requests by an author other than ME, whose `updatedAt' is after
ENDED-AT (`float-time').

Nil ENDED-AT means the role has never ended in this Emacs, so there is no
moment to compare against and everything open counts; a draft and the
navigator's own pull request are still excluded, since those are excluded by
what they are rather than by when they moved.  Nil ME - `gh api user' has
not answered yet - excludes every pull request: authorship is the whole of
what makes one Cypher's, and a pull request that cannot be shown to be
somebody else's must not start him on the navigator's own.

Numbers in the order `gh' listed them, so the reason `cerebro--trigger'
names is the first one `gh' would show the navigator."
  (let ((moved-p (lambda (item)
                   (let ((at (cerebro--gh-instant (alist-get 'updatedAt item))))
                     (and at (or (null ended-at) (> at ended-at)))))))
    (list (mapcar (lambda (issue) (alist-get 'number issue))
                  (seq-filter moved-p issues))
          (mapcar (lambda (pr) (alist-get 'number pr))
                  (seq-filter
                   (lambda (pr)
                     (and me
                          (not (alist-get 'isDraft pr))
                          (not (equal me (alist-get 'login (alist-get 'author pr))))
                          (funcall moved-p pr)))
                   prs)))))

(defun cerebro--standby-label (agent context)
  "Pure.  The Bead/Phase column of AGENT\='s standby row: what it is waiting for.

CONTEXT is `cerebro--trigger\='s.  A role whose trigger is a condition names
the condition, since there is no time at which it becomes true; a role on a
cadence counts down to its next start, which there is.  `orchestrator\=' and
any role this view has no rule for show nothing rather than a guess.

Deliberately not gated on the floor: it says what the role is for, and a
floor that has half a minute left to run is not worth a different word."
  (let* ((role (cerebro-agent-role agent))
         (cadence (cdr (assoc role cerebro-cadence-triggers))))
    (cond
     ;; An implementer on standby is one between beads, so what it waits for
     ;; is a condition, named the way a planner's row names its buffer rule
     ;; (cb-1or.1).  The clock is shown only while a failed start is actually
     ;; backing off - that is the one time there is a moment to count down
     ;; to, and it is a launcher refusing rather than a pass that ended.
     ((equal role "implementer")
      (let* ((failures (alist-get 'failed-starts context))
             (left (cerebro--retry-wait failures (alist-get 'started-at context)
                                        (alist-get 'now context))))
        (if (> left 0)
            (format "↻ retry in %s%s" (cerebro--retry-figure left)
                    (if (> failures 0) (format ", %d failed" failures) ""))
          "→ planned bead")))
     ((equal role "planner")
      (format "→ buffer < %d" (cerebro--planner-want (alist-get 'implementers context))))
     ((equal role "verifier") "→ merged, unverified")
     (cadence
      (concat (cerebro--countdown
               (let ((ended (alist-get 'ended-at context)))
                 (and ended (floor (- (+ ended cadence) (alist-get 'now context))))))
              ;; The countdown is all that is left when the reader is down,
              ;; and the navigator should know that is why.
              (if (and (eq (alist-get 'gh context) 'failed)
                       (member role '("user-feedback" "reviewer")))
                  " gh?" "")))
     (t ""))))

(defun cerebro--start-message (name reason)
  "The echo line for a start the view decided on: who, and why."
  (format "cerebro: started %s — %s" name reason))

(defun cerebro--stale-verdict-p (bead)
  "Whether BEAD carries the label that parks it in front of the verifier."
  (and (member "verdict:stale" (append (cerebro--bead-labels bead) nil)) t))

(defun cerebro--count-priority (beads priority)
  "How many of BEADS are at PRIORITY."
  (seq-count (lambda (bead) (equal (alist-get 'priority bead) priority)) beads))

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
and `waiting' (which the fleet poll ends within `cerebro-end-grace') and
`unknown' (a process is up; the view merely does not recognise what its
state file says it is doing). Anything narrower than that reintroduces the
`*fleet: <name>*<2>' bug: `s' on an `asking' or `waiting' implementer used to
read as \"not alive\" and start a second session over the first.

`standby\=' joins `dead\=' (cb-5yr): there is no process at all, so `s\=' must
reach `launch\=' and `k\=' must have something to say."
  (not (memq (cerebro-agent-state agent) '(dead standby))))

(defun cerebro--start-action (agent owned)
  "What `s' should do for AGENT, given OWNED session names.

One of `launch' (start a dead agent), `already-up' (an owned session is
already running), `external' (a live session exists outside Emacs -
refuse rather than launch a second one) or `duplicate' (this name already has
more than one session in this fleet - every other answer would act on an
ambiguity, so it is checked ahead of all of them, cb-63m).

Ownership is checked *before* the derived state, not after: `cerebro--session'
is the one place liveness is decided now, so no gap in how a state is
derived can start a second session over one this Emacs holds (ah-u3i's
`*fleet: <name>*<2>' double session)."
  (cond
   ((cerebro--duplicated-p agent) 'duplicate)
   ((member (cerebro-agent-name agent) owned) 'already-up)
   ((not (cerebro--alive-p agent)) 'launch)
   (t 'external)))

(defun cerebro--start-clears-flag-p (agent flag-set)
  "Whether starting AGENT should first remove its stop flag.

Only an implementer has one; a flag on a name being started is stale by
definition (ah-kgc): the navigator is saying it should run."
  (and flag-set (eq (cerebro-agent-kind agent) 'implementer)))

(defun cerebro--autostart-action (agent owned flagged)
  "What autostart should do for AGENT, given OWNED session names and FLAGGED.

One of `launch\=', `launch-clearing-flag\=', `already-up\=', `external\=' or
`duplicate\=' - `cerebro--start-action\=''s answers, with the flag folded into
the first.  A duplicated name is never launched by autostart either; the
answer is inherited rather than repeated.

FLAGGED is whether a stop flag exists for AGENT.  Unlike `s\='
(`cerebro--start-clears-flag-p\=', implementers only), autostart clears a
flag for EVERY kind: the navigator decided that opening the fleet view is a
statement that everything the roster declares should be running, and a flag
left on such a name is stale by the same argument ah-kgc made for `s\='
(cb-0r6).

A flag on a name that is already up changes nothing - there is nothing to
start, so there is nothing to clear."
  (let ((action (cerebro--start-action agent owned)))
    (if (and flagged (eq action 'launch)) 'launch-clearing-flag action)))

(defun cerebro--autostart-names-and-skipped (results)
  "RESULTS split into (STARTED . SKIPPED) label lists, in RESULTS order.

RESULTS is an alist of (NAME . ACTION) as `cerebro--autostart-action\='
answered for each declared agent.  A started name carries its parenthesis
when a stop flag was cleared for it; a skipped one is just the name, since
`already-up\=' and `external\=' read the same to the navigator - the agent is
running, autostart did nothing."
  (let (started skipped)
    (dolist (entry results)
      (pcase (cdr entry)
        ('launch (push (car entry) started))
        ('launch-clearing-flag
         (push (concat (car entry) " (cleared a stale stop flag)") started))
        (_ (push (car entry) skipped))))
    (cons (nreverse started) (nreverse skipped))))

(defun cerebro--standby-arming (agents names)
  "Pure.  The names among AGENTS that NAMES declares standby, in AGENTS order.

Every one of them, whatever its state: external, up, dead.  roster.conf is a
statement about the fleet, not about what this Emacs happens to have found
running - an agent started outside the view keeps its external row while that
session lives, and when it ends the name goes standby and its trigger starts
it (cb-98u)."
  (let (armed)
    (dolist (agent agents)
      (let ((name (cerebro-agent-name agent)))
        (when (member name names) (push name armed))))
    (nreverse armed)))

(defun cerebro--autostart-message (results &optional armed)
  "The one echo line for RESULTS and ARMED, or nil when both are empty.

A roster that declares neither word says nothing at all: every consumer
that has not adopted the column sees no new line on `M-x cerebro\='.

The started half is a plain comma list because each item may carry a
parenthesis; the already-up half reads as English (\"Beast and Psylocke\"),
being a list of bare names, and so does ARMED - what `cerebro--standby-arming\='
returned, the names a `standby\=' row armed without starting (cb-98u).  All
three keep roster order."
  (when (or results armed)
    (let* ((split (cerebro--autostart-names-and-skipped results))
           (started (car split))
           (skipped (cdr split))
           (head (if started
                     (concat "autostarted " (mapconcat #'identity started ", "))
                   "nothing to autostart"))
           (tail (when skipped
                   (format "; %s %s already up"
                           (cerebro--english-list skipped)
                           (if (cdr skipped) "are" "is"))))
           (armed-tail (when armed
                         (format "; armed %s" (cerebro--english-list armed)))))
      (concat "cerebro: " head (or tail "") (or armed-tail "")))))

(defun cerebro--english-list (names)
  "NAMES joined with commas and a final \" and \"."
  (cond
   ((null (cdr names)) (car names))
   (t (concat (mapconcat #'identity (butlast names) ", ")
              " and " (car (last names))))))

(defun cerebro--kill-action (agent owned)
  "What `k' should do for AGENT, given OWNED session names.

One of `kill' (plain confirm), `kill-working' (an implementer mid-bead -
harder confirm), `external' (refuse - not ours to stop), `disarm' (a standby
role - there is no process to kill, so `k' means the other half of what it
has always meant for an interactive role: stay down, cb-5yr) or `dead'
(refuse - nothing to kill).

`duplicate' (this name has more than one session in this fleet) is checked
ahead of everything, `disarm' included: `k' kills the session this Emacs
holds, which with two of them need not be the one the navigator is looking
at, and `disarm' acts on the name rather than on either (cb-63m).

`disarm' is checked ahead of `dead' because a standby row is not alive
either, and \"nothing to kill\" is the one thing it does not mean."
  (cond
   ((cerebro--duplicated-p agent) 'duplicate)
   ((eq (cerebro-agent-state agent) 'standby) 'disarm)
   ((not (cerebro--alive-p agent)) 'dead)
   ((not (member (cerebro-agent-name agent) owned)) 'external)
   ((and (eq (cerebro-agent-kind agent) 'implementer)
         (cerebro--in-flight-p (cerebro-agent-state agent)))
    'kill-working)
   (t 'kill)))

(defun cerebro--finish-action (agent flag-set)
  "What `f' should do for AGENT given FLAG-SET.

`duplicate' comes first for either kind: a stop flag is per name, and two
sessions of one name would both read the one flag (cb-63m).

For an interactive role, `f' means what it has always meant - no further
work - and for a role that runs one pass at a time (cb-5yr) that is:
`write-disarm' (a pass is running; write the flag, which
`cerebro--supervise-action' reads when the pass ends, and the role is
disarmed as it is retired), `standby' (there is no pass to finish, so say
which key does what instead of writing a flag nothing would read) or, as
before, `dead' and `external'.  `standby' is answered ahead of `dead'
because a standby row is not alive either.

For an implementer, one of `standby' (its session died and the view means to
start it again - there is nothing to finish, so say which key does what, the
same answer a standby role gets, cb-hzs), `offer-clear' (flag already set -
ask before removing it, the cheap way back to \"actually, keep going\"; checked
ahead of
every state below, since a stale flag is worth offering to clear whatever
AGENT is doing now), `dead' (nothing is running - there is nothing to finish
and writing a flag would lie about that, ah-ymn), `external' (idle, but
running outside Emacs - the poll that would act on a flag never touches it,
so writing one would sit unread and unmarked, ah-ymn), `stop-now' (idle -
nothing is in flight, so the flag means *stop now* rather than *finish*,
ah-ymn) or `write' (a bead is in flight - tell it to finish, and it stops
once that bead is done)."
  (cond
   ((cerebro--duplicated-p agent) 'duplicate)
   ((not (eq (cerebro-agent-kind agent) 'implementer))
    (cond ((eq (cerebro-agent-state agent) 'standby) 'standby)
          ((not (cerebro--alive-p agent)) 'dead)
          ((cerebro-agent-external agent) 'external)
          (flag-set 'offer-clear)
          (t 'write-disarm)))
   ;; Ahead of the flag, because a standby implementer has neither a pass to
   ;; finish nor a session to stop, whatever is already on disk for it.
   ((eq (cerebro-agent-state agent) 'standby) 'standby)
   (flag-set 'offer-clear)
   ((not (cerebro--alive-p agent)) 'dead)
   ((and (eq (cerebro-agent-state agent) 'idle)
         (cerebro-agent-external agent)) 'external)
   ((eq (cerebro-agent-state agent) 'idle) 'stop-now)
   (t 'write)))

(defvar cerebro--last-exit nil
  "Alist of NAME -> what is known about that name\='s last abnormal exit, for
every name whose session has died abnormally since Emacs started.

The value is a plist: `:code\=' the exit status as a string, `:line\=' the last
non-blank line the session printed or nil, and `:gave-up\=' t once the view has
stopped retrying the name (cb-ccl).  It was the line alone until cb-ccl, which
is why a session that printed nothing made no entry at all.  What keeps a row
`dead\=' is `cerebro--failed-names\=', not the presence of an entry.

Global, not buffer-local: `cerebro--note-exit' runs from vterm's process
sentinel, which may not have the fleet buffer current, and the placeholder
is built from whatever agent is being shown, not from any one buffer.
Cleared for a name by `cerebro--launch' the moment a new session for it is
started, so a stale line never survives past the run that produced it.")

(defun cerebro--placeholder (agent &optional retry-left failures roster-armed trigger-label)
  "The detail-window text for AGENT when it has no live view.

A dead agent with a recorded abnormal exit (`cerebro--last-exit') shows the
last line its session printed, so a launcher that refuses - `claude'
missing, an un-synced submodule - leaves something readable behind rather
than the row going `up' for a moment and then silently `dead' (ah-bri).

RETRY-LEFT (seconds) and FAILURES describe a standby implementer\='s next
start (`cerebro--retry-when').  A RETRY-LEFT above zero is a launcher that
refused backing off, and the line says when it comes back (cb-hzs);
otherwise the session finished its pass and the line names the condition
that brings it back, since cb-1or.1 there is one.  They are
passed in rather than read here because they are buffer-local to the fleet
buffer and this runs from whatever buffer is showing.  A standby *role*
keeps the plain line: its kept buffer is what `RET' shows, and this is only
reached once that has been killed - as it is for an implementer, whose
buffer is kept the same way now.

ROSTER-ARMED and TRIGGER-LABEL describe the one role that has a standby row
and no pass behind it: one `.cerebro/roster.conf' armed with the `standby'
word (cb-98u).  There is no kept buffer to show and nothing went wrong, so
the plain line would leave the navigator to work out why a row that has
never run says standby.  TRIGGER-LABEL is the row's own For column; empty
for a role this view has no trigger rule for, which is a different sentence
because `s' is then the only thing that starts it."
  (let* ((name (cerebro-agent-name agent))
         (last (alist-get name cerebro--last-exit nil nil #'equal)))
    (cond
     ((cerebro-agent-unverified-pid agent)
      (format (concat "Unverified: pid %d is running and names %s, but its command line carries no"
                      " path under this checkout - showing the state file.\n%s is running outside"
                      " Emacs - no live view. Use the terminal that started it.")
              (cerebro-agent-unverified-pid agent) name name))
     ((cerebro-agent-external agent)
      (format "%s is running outside Emacs - no live view. Use the terminal that started it."
              name))
     ((and (eq (cerebro-agent-state agent) 'standby)
           (eq (cerebro-agent-kind agent) 'implementer))
      (if (> (or retry-left 0) 0)
          (format (concat "%s is not running.\nIts last session ended without finishing a"
                          " bead; the view starts it again %s.\nPress s to start it now,"
                          " k to leave it down.")
                  name (cerebro--retry-when retry-left (or failures 0)))
        (format (concat "%s is not running.\nIts last session finished its pass; the view"
                        " starts it again when a planned bead is waiting.\nPress s to start"
                        " it now, k to leave it down.")
                name)))
     ((and (eq (cerebro-agent-state agent) 'standby)
           (eq (cerebro-agent-kind agent) 'interactive)
           roster-armed)
      (if (and trigger-label (not (string-empty-p trigger-label)))
          (format (concat "%s is not running.\nroster.conf arms it: the view starts it when its own"
                          " trigger fires (%s).\nPress s to start it now, k to leave it down.")
                  name trigger-label)
        (format (concat "%s is not running.\nroster.conf arms it, but this role has no trigger: it is"
                        " started with s only.\nPress s to start it, k to leave it down.")
                name)))
     ;; Ahead of the line branch: a name the view gave up on has a record with
     ;; no line at all, and "not running. Press s" was the whole account of
     ;; five consecutive failures (cb-ccl).
     ((plist-get last :gave-up)
      (format (concat "%s is not running.\nIts last %d sessions ended without a pass (last exit"
                      " code %s) and printed nothing; the view has stopped retrying.\n"
                      "Press s to start it.")
              name (or failures cerebro-give-up-after) (or (plist-get last :code) "?")))
     ((plist-get last :line)
      (format "%s is not running.\nIts last session ended with:\n  %s\nPress s to start it."
              name (plist-get last :line)))
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

(defcustom cerebro-stale-verdict-merges 1
  "How many commits must land on the default branch after a failed verdict\='s
own commit before the sweep offers the bead back for a second look.

One, because anything landing on main since the verdict is enough to make it
worth re-checking: the three cases of 2026-08-23 were 4, 2 and 6 merges
behind, and erring toward a re-verification is much cheaper than erring
toward an implementer building a no-op. Three would be quieter but would
have missed `ah-vocw\=' at two merges, one of the three cases this was
filed for."
  :type 'integer
  :group 'cerebro)

(defun cerebro--verdict-finding (candidate)
  "Pure. What the verdict sweep should offer for CANDIDATE, or nil.

CANDIDATE is one parsed object from `sweep-verdicts.sh --json\='. Returns nil
or (recheck ID PRIORITY). Nil covers the two cases the script could not
answer: the bead carries no `verified_at\=', so no verdict commit is known;
or `merges_since\=' is nil, meaning the commit is not on the default branch
and the distance is not a number. A known distance below
`cerebro-stale-verdict-merges\=' is also nil.

It takes ONE argument, unlike `cerebro--assignee-finding\=': everything it
needs is in the candidate, since there is no liveness to consult and no
roster to check. PRIORITY rides in the finding for the same reason it does
there - `cerebro--sweep-line\=' is given nothing else and needs it to shout
for a P0."
  (let-alist candidate
    (cond
     ((null .verified_at) nil)
     ((null .merges_since) nil)
     ((< .merges_since cerebro-stale-verdict-merges) nil)
     (t (list 'recheck .id .priority)))))

;;; cb-4s8: one row per sweep, and the pure walker that reads it

(defconst cerebro--sweeps
  `((sweep-claims    "sweep-claims.sh"    ,#'cerebro--claim-finding    (:live-names :now))
    (sweep-epics     "sweep-epics.sh"     ,#'cerebro--epic-finding     ())
    (sweep-stalled   "sweep-stalled.sh"   ,#'cerebro--stalled-finding  (:live-states :now))
    (sweep-assignees "sweep-assignees.sh" ,#'cerebro--assignee-finding (:live-beads :roster :now)
                     ,#'cerebro--assignee-enrich)
    (sweep-verdicts  "sweep-verdicts.sh"  ,#'cerebro--verdict-finding  ()))
  "One row per sweep: (KEY SCRIPT FINDER NEEDS [ENRICH]).
KEY is the `cerebro--run-async\=' key and the key of the outputs alist
`cerebro--findings-from\=' takes; SCRIPT the file under scripts/; FINDER a
pure function (CANDIDATE . NEEDS-VALUES) -> finding or nil; NEEDS the
`cerebro--fleet-snapshot\=' keys passed after the candidate, in this order;
ENRICH, when present, (CANDIDATE SNAPSHOT) -> the candidate
`cerebro--sweep-label\=' formats, for the one sweep whose label needs a fact
its script cannot know. Run order is row order.

This table is the whole of what the runner is told about a sweep. Adding a
sixth is a row here, a `cerebro--<x>-finding\=', a `cerebro--sweep-label\='
arm and a `cerebro--finding-command\=' arm - no signature and no existing
test changes with it, which is what cb-4s8 bought. Label and command stay
outside the table deliberately: both dispatch on the finding's shape rather
than on the sweep - the claims sweep alone yields two - and
`cerebro--finding-command\=' is meant to read as one list of every
destructive command the fleet view can run.")

(defun cerebro--sweep-scripts ()
  "(KEY . SCRIPT) per sweep, in run order - derived from `cerebro--sweeps\='
rather than kept beside it as a second list in the same order."
  (mapcar (lambda (row) (cons (nth 0 row) (nth 1 row))) cerebro--sweeps))

(defun cerebro--assignee-enrich (candidate snapshot)
  "CANDIDATE with `assignee_bead\=' added from SNAPSHOT's :live-beads - what
the assignee is actually on, which sweep-assignees.sh cannot know (it reads
`bd\=', not the state files). Keeps `cerebro--sweep-label\=' a pure
two-argument formatter."
  (cons (cons 'assignee_bead
              (cdr (assoc (alist-get 'assignee candidate)
                          (plist-get snapshot :live-beads))))
        candidate))

(defun cerebro--fleet-snapshot (repo-root)
  "One read of the live fleet under REPO-ROOT, as the plist the NEEDS keys of
`cerebro--sweeps\=' name. One read, not three helper calls: those would walk
the roster three times and take three separate readings of a fleet that
moves, so one sweep could judge a session the next no longer sees."
  (let ((sessions (cerebro--live-sessions repo-root)))
    (list :live-names  (mapcar (lambda (x) (nth 0 x)) sessions)
          :live-states (mapcar (lambda (x) (cons (nth 0 x) (nth 1 x))) sessions)
          :live-beads  (mapcar (lambda (x) (cons (nth 0 x) (nth 2 x))) sessions)
          :roster      (cerebro--roster repo-root)
          :now         (current-time))))

(defun cerebro--findings-from-snapshot (outputs snapshot)
  "Pure. The (LABEL . FINDING) list for OUTPUTS - an alist (KEY . CANDIDATES),
one entry per row of `cerebro--sweeps\=' - judged against SNAPSHOT, the plist
`cerebro--fleet-snapshot\=' builds. Rows are walked in table order; a key
absent from OUTPUTS contributes nothing."
  (apply #'append
         (mapcar
          (lambda (row)
            (pcase-let ((`(,key ,_script ,finder ,needs . ,rest) row))
              (let ((args (mapcar (lambda (k) (plist-get snapshot k)) needs))
                    (enrich (car rest)))
                (delq nil
                      (mapcar (lambda (c)
                                (let ((finding (apply finder c args)))
                                  (and finding
                                       (cons (cerebro--sweep-label
                                              finding
                                              (if enrich (funcall enrich c snapshot) c))
                                             finding))))
                              (alist-get key outputs))))))
          cerebro--sweeps)))

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
    ;; `verdict\=' is a dimension of its own, deliberately: `verification\=' is a bd
    ;; state dimension and `bd set-state\=' replaces the whole of it, so
    ;; `verification=stale\=' would erase the verdict this line exists to preserve.
    ;; Nothing is destroyed here - the verdict, the notes and the plan all stay
    ;; exactly as written; the label only moves the bead out of the implementer
    ;; and planner queues and into Psylocke\='s.
    (`(recheck ,id ,_priority)
     (list cerebro-bd-program "set-state" id "verdict=stale"
           "--reason" "verdict formed against a commit main has moved past"))
    (_ (error "cerebro: no command for finding %S" finding))))

;;; Impure readers - each trivially small so everything above stays pure

(defun cerebro--repo-root ()
  "The repository root above `default-directory', or an error.
Located by `cerebro-submodule-path\=' (the submodule mount, present in
every consumer from clone time) rather than by `.cerebro/state', which
may not exist yet on a fresh machine - `agent-state' and
`cerebro--write-stop-flag' both create it on first write.

Returned canonical - absolute, expanded, slash-terminated - through
`cerebro--canonical-root\=', because this is the one reader whose raw result
is a display spelling."
  (cerebro--canonical-root
   (or (locate-dominating-file default-directory cerebro-submodule-path)
       (error "cerebro: no %s found above %s (see `cerebro-submodule-path')"
              cerebro-submodule-path default-directory))))

(defvar-local cerebro--fleet-cache nil
  "The parsed roster, once read; buffer-local so a revert does not re-shell out.")

(defun cerebro--fleet (repo-root)
  "The fleet as (NAME ROLE KIND) rows, via `scripts/roster\=' in REPO-ROOT.

A roster that REFUSES - a roster.conf left at the retired path, a third
column that is not `autostart\=' - signals rather than returning nothing
(cb-0r6).  An empty fleet drawn in silence is the one outcome that looks
like a working view: the navigator sees a list of nobody and no reason for
it.  `call-process\=''s destination is `t\=', which mixes stderr into the
buffer, so the script\='s own line is what reaches the echo area.

The signal happens inside the `or\=' producer, before the cache is set, so a
refusal is never cached as a fleet."
  (or cerebro--fleet-cache
      (setq cerebro--fleet-cache
            (cerebro--parse-fleet
             (with-temp-buffer
               (let ((status (call-process
                              (expand-file-name (cerebro--script "roster") repo-root)
                              nil t nil)))
                 (unless (eq status 0)
                   ;; Recorded before it is signalled: the signal is the loud
                   ;; half, which `M-x cerebro' shows and the navigator then
                   ;; scrolls away from.
                   (let ((text (string-trim (buffer-string))))
                     (cerebro--log-error repo-root "roster" text)
                     (error "cerebro: %s" text))))
               (buffer-string))))))

(defun cerebro--autostart-names (repo-root)
  "The names `scripts/roster --autostart\=' lists in REPO-ROOT, in file order.

nil when the script refuses, or cannot be run at all: `cerebro--fleet\=' has
already read the same script for the same render by the time this runs, so
anything wrong with it has already been reported - a second error here
would only replace the roster\='s own line with a worse one."
  (condition-case nil
      (with-temp-buffer
        (let ((status (call-process (expand-file-name (cerebro--script "roster") repo-root)
                                    nil t nil "--autostart")))
          (when (eq status 0)
            (split-string (buffer-string) "\n" t "[ \t\r]+"))))
    (error nil)))

(defun cerebro--standby-names (repo-root)
  "The names `scripts/roster --standby\=' lists in REPO-ROOT, in file order.

The other half of `cerebro--autostart-names\=' (cb-98u): a `standby\=' row says
arm this agent without starting it, so the row reads `standby\=' from the
moment the buffer comes up and the role\='s own trigger is what starts it.

nil when the script refuses, or cannot be run at all, for the reason that
one gives: `cerebro--fleet\=' has already read the same script for the same
render, so a refusal has been reported once already."
  (condition-case nil
      (with-temp-buffer
        (let ((status (call-process (expand-file-name (cerebro--script "roster") repo-root)
                                    nil t nil "--standby")))
          (when (eq status 0)
            (split-string (buffer-string) "\n" t "[ \t\r]+"))))
    (error nil)))

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

(defun cerebro--session-liveness (pid name root)
  "`proven', `unverified' or nil for PID as NAME's session of the fleet at ROOT.

Reads only the named pid's args, not the whole process list - this is asked
once per agent on every refresh, where `cerebro--system-processes' is a scan
the fleet view deliberately caches.

Three answers, not two (ah-ybsr): a wrapper (cmux) can rewrite `--settings'
from a path into merged inline JSON, so a session that is genuinely this
agent's can carry no discriminator ROOT-in-args-p can find, even though it
carries `--name NAME'.  Collapsing that into \"dead\" is the defect this
splits out of - the same broken predicate that showed every agent `idle' or
`up' regardless of what its state file said.

- nil - no pid, no args, or the args do not carry a whole-word `--name NAME'.
  This is the recycled-pid case (cb-lzi/9420ff2) and it is *positive evidence
  against*: a bare number is not an identity, so a caller must keep treating
  this exactly as a dead session.
- `proven' - `cerebro--session-args-p' is non-nil: the args carry `--name
  NAME' AND a path under ROOT.  Exactly what \"alive\" meant before this.
- `unverified' - the args name NAME but carry no path under ROOT.  There is
  no evidence against this being the session the state file describes, only
  an absence of proof - a caller should trust the file and say so, not
  substitute a confident default.

The two-part test is `cerebro--session-args-p'; this function only fetches
the args of one pid and tells `nil' apart from `unverified' within what that
function calls no."
  (let ((args (and pid (alist-get 'args (process-attributes pid)))))
    (cond
     ((not (and args (cerebro--name-in-args-p name (list args)))) nil)
     ((cerebro--root-in-args-p root (list args)) 'proven)
     (t 'unverified))))

(defun cerebro--session-alive-p (pid name root)
  "Non-nil if PID is a live process and is NAME's own session of the fleet at ROOT.

Both halves matter. \"Does this pid exist\" was the whole test until a
`done' state file outlived its session by ten hours and the operating
system reused its pid for an unrelated daemon: the row read `done' - green,
and `s' refused it as \"running outside Emacs\" - for an agent that had not
been running since the night before. Pids are recycled, so a bare number is
not an identity; the launcher passes `--name <Name>' to every session
\(`scripts/launch'), which makes the process's own command line the proof
that this pid is still the one the file was written about.

ROOT is the third discriminator (cb-lzi): a recycled pid can land on a
same-named session of ANOTHER consumer - every consumer on the built-in
roster has a Xavier - and name plus pid alone would call that one ours.
Required, not optional: a default would silently be the two-discriminator
rule this bead removes.

Built on `cerebro--session-liveness' and keeps this function's own
generalised-boolean contract: `t' for `proven', the symbol `unverified' for
`unverified' - non-nil, and not `eq' to `unverified', so every existing
caller and every ERT test that injects `(lambda (pid name) t)' keeps working
unchanged.  A caller that cares which of the two it got tests
`(eq ... \\='unverified)'; every other caller already treats both as alive."
  (pcase (cerebro--session-liveness pid name root)
    ('proven t)
    ('unverified 'unverified)
    (_ nil)))

(defun cerebro--system-processes ()
  "Every system process as (PID . ARGS), ARGS its command line string.

Every process on the machine, deliberately: which of them are this
consumer\='s fleet is a pure question, answered by
`cerebro--consumer-processes\=' at the call site rather than here.  The pid
travels beside the args because a second session of one name is a count of
processes, and the echo line that reports one names their pids
\(`cerebro--session-pids\=', cb-63m)."
  (delq nil
        (mapcar (lambda (pid)
                  (let ((args (alist-get 'args (process-attributes pid))))
                    (and args (cons pid args))))
                (list-system-processes))))

(defvar cerebro-system-scan-seconds 30
  "How often the process list is scanned for interactive agents started
outside Emacs. A rare event, polled at the rate of a state file; the scan
itself is 75 ms of blocking work and was on the five-second tick.")

(defvar-local cerebro--system-processes-cache nil
  "(PROCESSES . SCANNED-AT) from the last scan, per fleet buffer.")

(defun cerebro--cached-system-processes (&optional now)
  "`cerebro--system-processes', rescanned only when `cerebro-system-scan-seconds'
have passed. NOW is for tests."
  (let ((now (or now (float-time))))
    (if (and cerebro--system-processes-cache
             (not (cerebro--due-p (cdr cerebro--system-processes-cache)
                                  cerebro-system-scan-seconds now)))
        (car cerebro--system-processes-cache)
      (let ((procs (cerebro--system-processes)))
        (setq cerebro--system-processes-cache (cons procs now))
        procs))))

(defun cerebro--duplicate-message-for (agent repo-root)
  "The `cerebro--duplicate-message\=' for AGENT, gathering what it needs.

Impure glue and nothing else: the pids from this consumer\='s scan and the
one the state file names, handed to the pure formatter."
  (let* ((name (cerebro-agent-name agent))
         (pids (cerebro--session-pids
                name (cerebro--consumer-processes (cerebro--cached-system-processes)
                                                  repo-root)))
         (file-pid (alist-get 'pid (cerebro--read-state-file
                                    (cerebro--state-file-path repo-root name)))))
    (cerebro--duplicate-message name pids file-pid)))

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

(defvar-local cerebro--armed nil
  "Names the view will start again on their trigger (cb-5yr).

Armed by `cerebro--launch\=' - every start, `s\=' or autostart - and disarmed by
`k\=', by `f\=' once the pass ends, and by a stop flag on a waiting role.  Emacs
memory only: nothing is written to any file, so a new Emacs arms nothing
until something is started in it.  That is deliberate rather than an
omission - opening the fleet view must not resurrect a fleet the navigator
took down last night.")

(defvar-local cerebro--parked nil
  "Alist of (NAME . (ENDED-AT STARTED-AT BUFFER)) for names the view has ended.

Every agent with a pass worth keeping, an implementer included since
cb-1or.1 - a bead merged and closed, one handed back, or nothing to claim
all end a pass, and the buffer is the record of it.

ENDED-AT and STARTED-AT are `float-time\=' values - when the session ended, and
when it had started - and BUFFER is the kept session buffer holding its last
pass, or nil once something has killed it.  One entry per name: a fresh
start replaces it, and `k\=' removes it.")

(defvar-local cerebro--start-fingerprints nil
  "Alist of (NAME . FINGERPRINT) - what each agent was last started *for*.

`cerebro--trigger-fingerprint\=' of the context that was true when the view
started the session - recorded when the launch is ATTEMPTED, since nothing
here can see a session come up, which is why `cerebro--unless-unchanged\='
also asks whether a pass actually ran before holding anything on it.
`cerebro--unless-unchanged\=' is what reads it: a
trigger that names the same thing again is a pass that could not clear it,
and the answer is to wait for a change rather than for a clock.  Recorded on
every start, `s\=' included, so a pass the navigator started by hand arms the
guard exactly as an automatic one does.")

(defvar-local cerebro--started-at nil
  "Alist of (NAME . FLOAT-TIME) - when this Emacs last started each session.

The floor a trigger is gated on (`cerebro-wake-interval\=') is measured from
here rather than from the state file, which is deleted with the session it
described.")

(defvar-local cerebro--seen-up nil
  "Alist of (NAME . FLOAT-TIME) - when this view last derived NAME as up.

The `ended-at\=' of an implementer whose session DIED: one that ended its own
pass is parked like a role since cb-1or.1 and reads its park instead
(`cerebro--agent-context\=').  With no parked entry, \"did the last start
produce anything\" (`cerebro--start-failed-p\=') is answered by whether the
view saw the session alive after it was started.
Written by `cerebro--revert\=' from `cerebro--up-names\=', once a tick.")

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
  "A read-only buffer holding AGENT's placeholder text, reused across shows.

The text is computed *before* the placeholder buffer is made current: the
retry figures a standby implementer\='s line names are buffer-local to the
fleet buffer, which is what is current when `cerebro--show-detail' runs
(cb-hzs).  It is rendered when the row is shown rather than every tick -
the row itself is the live figure."
  (let* ((name (cerebro-agent-name agent))
         (failures (or (cdr (assoc name cerebro--failed-starts)) 0))
         (left (cerebro--retry-wait failures (cdr (assoc name cerebro--started-at))
                                    (float-time)))
         ;; A parked entry with no STARTED-AT is one only arming writes:
         ;; `cerebro--park-session' always records the start it is ending, so
         ;; a role whose kept buffer was killed keeps today's plain line.
         (roster-armed (let ((entry (cdr (assoc name cerebro--parked))))
                         (and entry (null (nth 1 entry)))))
         ;; One panel read per `RET', not per tick - which is what
         ;; `cerebro--trigger-context's "deliberately cheap" docstring allows:
         ;; it counts what the tick has already read and makes no `bd' call.
         (trigger-label
          (and roster-armed
               (cerebro--standby-label
                agent (cerebro--agent-context
                       agent (cerebro--trigger-context (cerebro--repo-root) (current-time))))))
         (text (cerebro--placeholder agent left failures roster-armed trigger-label))
         (buffer (get-buffer-create (cerebro--placeholder-buffer-name agent))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (setq buffer-read-only t)
      ;; It sits in the detail window like a session does, so TAB has to keep
      ;; working from it - otherwise the key dies on exactly the agents that
      ;; are not running.
      (cerebro-session-mode 1))
    buffer))

(defun cerebro--show-detail (agent)
  "Put AGENT's live session, or a placeholder, in the detail window.

Returns the buffer chosen.  A session with no live buffer - should not
happen, `cerebro--session' is what `cerebro--owned' derives from too -
falls back to the placeholder rather than erroring.

A role on standby has no session and a kept buffer instead: `RET' on that
row shows what its last pass printed (cb-5yr), which is the whole reason
the buffer outlives the process."
  (let ((buffer (or (cerebro--session (cerebro-agent-name agent))
                     (cerebro--parked-buffer (cerebro-agent-name agent))
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
the detail window through `cerebro--show-detail'.

`default-directory' reaches the session by inheritance: `generate-new-buffer'
copies it from the current buffer, which is why `cerebro--launch' let-binds
it before calling this.  Neither the selected window nor the current buffer
is changed.  Returns the buffer."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (vterm-mode))
    buffer))

(defun cerebro--vterm-available-p ()
  "Whether vterm can be loaded, so a session has something to run in.

A function of its own rather than an inline `require\=' so the autostart
tests can stub exactly this one question; stubbing `require\=' itself would
reach every other library the render path loads (cb-0r6)."
  (and (require 'vterm nil t) t))

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
believes about it (ah-5pp).  An interactive name is *armed* here and its
start time stamped, which is what a standby row and its trigger are derived
from afterwards (cb-5yr)."
  (when (cerebro--session (cerebro-agent-name agent))
    (error "cerebro: %s already has a live session" (cerebro-agent-name agent)))
  (unless (cerebro--vterm-available-p)
    ;; Logged as well as signalled, and for the same reason the autostart
    ;; message is: this is the refusal that looks, to the navigator, like `s'
    ;; having done nothing at all.
    (cerebro--log-error (ignore-errors (cerebro--repo-root)) "launch"
                        "vterm is not installed - install emacs-libvterm")
    (user-error "cerebro needs vterm for live sessions - install emacs-libvterm"))
  (add-hook 'vterm-exit-functions #'cerebro--note-exit)
  (setq cerebro--last-exit
        (assoc-delete-all (cerebro-agent-name agent) cerebro--last-exit))
  ;; The kept buffer records the last pass; this is the next one.
  (cerebro--forget-parked (cerebro-agent-name agent))
  ;; A state file present now is the *previous* session's under this name:
  ;; this function refuses a name that still has a live session, and `s' on
  ;; one running outside Emacs never reaches here. Left behind, it names a
  ;; pid that has gone, which the sweeps and `scripts/fleet-history' read as
  ;; a claim about a live session (cb-hzs). `cerebro--supervise' takes the
  ;; file with it when it ends a session; this one is then a no-op.
  (cerebro--delete-state-file (cerebro--repo-root) (cerebro-agent-name agent))
  (let* ((default-directory (cerebro--repo-root))
         (cmd (cerebro--launch-command agent))
         (vterm-shell (mapconcat #'shell-quote-argument cmd " "))
         (session-name (cerebro--session-buffer-name agent))
         (buffer (cerebro--make-session-buffer session-name)))
    (setf (alist-get (cerebro-agent-name agent) cerebro--sessions nil nil #'equal) buffer)
    ;; Starting an agent is what arms it: from here the view will start it
    ;; again on its own trigger until `k' or `f' says otherwise (cb-5yr).
    ;; An implementer is armed too (cb-hzs) - a session that dies without
    ;; ending its pass reaches nothing otherwise, and sat dead until the
    ;; navigator pressed `s'. A pass that ends with `waiting' is parked and
    ;; started again on its trigger; arming is what covers every other way a
    ;; session can end.
    (cl-pushnew (cerebro-agent-name agent) cerebro--armed :test #'equal)
    ;; The floor a trigger is gated on is measured from here: the state
    ;; file that would otherwise carry it is deleted when the session ends.
    (setf (alist-get (cerebro-agent-name agent) cerebro--started-at nil nil #'equal)
          (float-time))
    ;; The navigator starting a session by hand - `s', or the autostart -
    ;; is what clears the backoff: no reason means no trigger fired.
    (unless cerebro--log-start-reason
      (setf (alist-get (cerebro-agent-name agent) cerebro--failed-starts nil nil #'equal)
            0))
    ;; And what it is being started *for*, which is what says whether the
    ;; pass after this one has anything new to do (`cerebro--trigger').
    ;; Every kind since cb-1or.1: an implementer has a condition of its own
    ;; now - a planned, unclaimed bead - so it has something to compare, and
    ;; the context gather this costs is once per launch, which is rare.
    (setf (alist-get (cerebro-agent-name agent) cerebro--start-fingerprints
                     nil nil #'equal)
          (cerebro--trigger-fingerprint
           (cerebro-agent-role agent)
           (cerebro--trigger-context (cerebro--repo-root) (current-time))))
    ;; Every start passes through here - `s', autostart, a trigger - so this
    ;; is where one is recorded (`cerebro--log-start-reason').
    (cerebro--log (cerebro--repo-root) 'start
                  (list (cons 'agent (cerebro-agent-name agent))
                        (cons 'role (cerebro-agent-role agent))
                        (cons 'reason cerebro--log-start-reason)
                        (cons 'by (if cerebro--log-start-reason "trigger" "navigator"))))
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
failure to explain. Returns (:code CODE :line LAST-LINE), where LAST-LINE
may be nil.

A LINE-LESS record is the cb-ccl half. It used to take a line to make a
record at all, and vterm draws process output on a 0.1s timer while a
refused launcher exits within a second - so 274 refusals in one day made no
record, were logged with `abnormal' null against an exit code of 2, and fell
into the retry path as though the sessions had simply gone away. What the row
and the standby rule read is `cerebro--failed-names', which asks whether the
record has anything to say rather than whether one exists."
  (and (string-match "\\`exited abnormally with code \\([0-9]+\\)" event)
       (list :code (match-string 1 event) :line last-line)))

(defun cerebro--failed-names (last-exit)
  "Pure.  The names in LAST-EXIT whose record keeps their row `dead'.

A record with a `:line' is a launcher that refused and said why; one with
`:gave-up' is a name this view has stopped retrying.  Either way `s' is the
way back and nothing else is coming, which is what `dead' says.

A record with neither is a session that died printing nothing - the machine
slept, the process was killed from outside - and that is promised a retry on
the backoff, so its row stays `standby' (cb-ccl)."
  (delq nil (mapcar (lambda (cell)
                      (let ((record (cdr cell)))
                        (and (or (plist-get record :line)
                                 (plist-get record :gave-up))
                             (car cell))))
                    last-exit)))

(defun cerebro--exit-code (event)
  "Pure.  The code to log for a session that ended on EVENT.

`cerebro--exit-record\=' answers a narrower question - is this worth showing on
the row as a failure - and is nil for a clean quit.  That is right for the row
and wrong for the log: an implementer went from `idle\=' to `dead\=' with no
`exit\=' line anywhere, because a status of 0 was recorded nowhere at all, and
\"without apparent reason\" was this code declining to say.

`finished\=' is 0; an abnormal exit is its number; anything else - `killed\=', a
signal - is the sentinel\='s own word."
  (cond ((string-match "\\`exited abnormally with code \\([0-9]+\\)" event)
         (match-string 1 event))
        ((string-prefix-p "finished" event) "0")
        (t (string-trim event))))

(defcustom cerebro-exit-line-width 60
  "Columns of a dead session\='s last line shown on its row before an ellipsis.

The detail window (`RET\=') shows the whole line; the row shows as much of it
as a row can carry."
  :type 'integer
  :group 'cerebro)

(defun cerebro--exit-line (record failures)
  "Pure.  The Bead/Phase text for a dead row, from its `cerebro--last-exit'
RECORD and FAILURES, that name's consecutive failed starts.  Nil when there
is nothing to say.

With a `:line', \"✗ \" then the line with a leading \"cerebro: \" dropped -
the launcher's own prefix, nine columns spent on nothing.  With `:gave-up'
and no line, the count and the code instead: a name that has failed five
times running printing nothing rendered identically to one nothing had ever
asked to start (cb-ccl).  Truncated to `cerebro-exit-line-width' with an
ellipsis either way.  A plain string, like `cerebro--for-column': the red
comes from `cerebro--entry' propertizing it."
  (let* ((line (plist-get record :line))
         (text (cond
                (line (concat "✗ " (string-remove-prefix "cerebro: " line)))
                ((plist-get record :gave-up)
                 (format "✗ exited with code %s, %d failed starts — press s"
                         (or (plist-get record :code) "?") (or failures 0))))))
    (and text
         (truncate-string-to-width text cerebro-exit-line-width nil nil "…"))))

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
after the buffer itself has already been killed (`k', retire, end) -
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
             (last-line (cerebro--last-nonblank-line text))
             (record (cerebro--exit-record event last-line)))
        ;; EVERY exit is logged, clean ones included. The row and the echo
        ;; area stay abnormal-only - a clean quit is not a failure to show
        ;; anybody - but the log is where "why is this row dead" is answered
        ;; after the fact, and a session that exited with status 0 used to
        ;; leave nothing there at all.
        ;;
        ;; The record comes first, and the root is resolved inside the buffer
        ;; that died. vterm runs `vterm-exit-functions' with whatever buffer
        ;; happens to be current, and `cerebro--repo-root' *signals* from one
        ;; with no mount above it - from `*scratch*' in `~', say - which would
        ;; take the record down with it and leave the row with no account of
        ;; the exit at all (cb-hzs). The session buffer's `default-directory'
        ;; is the consumer root: `cerebro--launch' binds it around
        ;; `cerebro--make-session-buffer' and `generate-new-buffer' inherits
        ;; it. `ignore-errors' because the log is documented as silent and
        ;; unable to fail.
        (when record
          (setf (alist-get name cerebro--last-exit nil nil #'equal) record)
          (if (plist-get record :line)
              (message "%s exited (code %s): %s"
                       name (plist-get record :code) (plist-get record :line))
            (message "%s exited (code %s) and printed nothing"
                     name (plist-get record :code))))
        (let ((root (with-current-buffer buffer
                      (ignore-errors (cerebro--repo-root)))))
          (when root
            (cerebro--log root 'exit
                          (list (cons 'agent name)
                                (cons 'code (cerebro--exit-code event))
                                (cons 'abnormal (and record t))
                                (cons 'last_line last-line)))))))))

;;; Acting on the supervision decisions

(defvar-local cerebro--nudged nil
  "Names already told to give up on the question they are asking.

The poll runs every five seconds; without this the nudge would be typed
into the session on every tick, burying the agent's own output and
resetting what it was told.  A name leaves this set as soon as it is no
longer asking, so its next question is nudgeable again.")

(defun cerebro--autostart (buffer repo-root)
  "Start every declared autostart agent in BUFFER that is dead, once.

Runs after the first `cerebro--list-render\=', so `cerebro--agents\=' is
derived, and re-renders afterwards so the rows show what was started.  The
walk is over `cerebro--agents\=' rather than over the declared names, which
is what keeps the echo line in roster order.

Each launch is wrapped in `with-demoted-errors\=', as `cerebro--supervise\='
does: one launcher that cannot start must not stop the others."
  (with-current-buffer buffer
    (let ((names (cerebro--autostart-names repo-root))
          (standby (cerebro--standby-names repo-root)))
      (when (or names standby)
        (if (not (cerebro--vterm-available-p))
            ;; And nothing is ARMED either: `cerebro--start-due' is gated on
            ;; vterm, so an armed name would show a row promising a trigger
            ;; that cannot fire (cb-98u).
            (cerebro--report-error
             "autostart" "vterm is not installed, so nothing was autostarted")
          (let ((owned (cerebro--owned))
                results)
            (dolist (agent cerebro--agents)
              (let ((name (cerebro-agent-name agent)))
                (when (member name names)
                  (let ((action (cerebro--autostart-action
                                 agent owned (cerebro--stop-flag-p repo-root name))))
                    (cerebro--with-logged-errors (format "autostart %s" name)
                      (when (eq action 'launch-clearing-flag)
                        (cerebro--clear-stop-flag repo-root name))
                      (when (memq action '(launch launch-clearing-flag))
                        (cerebro--launch agent)))
                    (push (cons name action) results)))))
            ;; Arming is the other half of the same declaration (cb-98u): the
            ;; name goes on `cerebro--armed', and a parked entry gives its
            ;; trigger a moment to count from - ENDED-AT now, no STARTED-AT
            ;; (it has never started), no kept buffer. Without that entry a
            ;; cadence role would never fire at all, and Moira's `gh' trigger
            ;; would count every open issue as moved and start her at once.
            (let ((armed (cerebro--standby-arming cerebro--agents standby)))
              (dolist (name armed)
                (cl-pushnew name cerebro--armed :test #'equal)
                ;; `unless': a kept buffer from a session this Emacs ended
                ;; earlier is the record of a real pass and outranks this.
                (unless (assoc name cerebro--parked)
                  (setf (alist-get name cerebro--parked nil nil #'equal)
                        (list (float-time) nil nil)))
                (cerebro--log repo-root 'arm
                              (list (cons 'agent name)
                                    (cons 'role (let ((a (cerebro--find-agent name)))
                                                  (and a (cerebro-agent-role a))))
                                    (cons 'by "roster"))))
              ;; The render runs AFTER arming: `cerebro--apply-standby' is
              ;; what turns an armed, dead row into `standby'.
              (cerebro--list-render buffer)
              (let ((line (cerebro--autostart-message (nreverse results) armed)))
                (when line (message "%s" line))))))))))


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

It names neither a tracker label nor a skill: the words go into a live
session, and how a work item is handed back is the agent\='s own instructions
to state, not the fleet view\='s.  Saying it in cerebro\='s words would be a
second, quieter copy of a policy that must have exactly one owner.")

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

(defun cerebro--forget-session (agent)
  "Kill AGENT's session buffer, without asking and without refreshing.

The query-on-exit flag guards an *accidental* kill; this one is the poll
acting on a bead the agent itself reported finished.  Looks up the buffer
via `cerebro--recorded-buffer', not `cerebro--session': a session whose
process has already exited still has a buffer to clean up, and requiring a
live process here would leave it for the next launch to collide with.
Forgets the entry in `cerebro--sessions' too, so a launch right
afterwards sees no session even before the process sentinel
has run."
  (let ((name (cerebro-agent-name agent)))
    (let ((buffer (cerebro--recorded-buffer name)))
      (when buffer
        (let ((proc (get-buffer-process buffer)))
          (when proc (set-process-query-on-exit-flag proc nil)))
        (kill-buffer buffer)))
    (setq cerebro--sessions (assoc-delete-all name cerebro--sessions))))

(defun cerebro--parked-buffer-name (name now)
  "What NAME\='s kept session buffer is called once it has been ended at NOW.

The clock time rather than an elapsed one: a buffer name is not redrawn, so
\"ended 12m ago\" would be wrong a minute later, and the fleet row beside it
is where a live figure belongs."
  (format "*fleet: %s (ended %s)*" name (format-time-string "%H:%M" now)))

(defun cerebro--parked-buffer (name)
  "NAME\='s kept session buffer, if one is still live, or nil."
  (let ((buffer (nth 2 (cdr (assoc name cerebro--parked)))))
    (and (buffer-live-p buffer) buffer)))

(defun cerebro--forget-parked (name)
  "Kill NAME\='s kept session buffer, if any, and drop the record of it.

One kept buffer per role: it is the record of the *last* pass, so a fresh
start replaces it and `k\=' removes it.  Keeping every pass would fill the
buffer list with a role\='s whole day and bury the one worth reading."
  (let ((buffer (cerebro--parked-buffer name)))
    (when buffer (kill-buffer buffer)))
  (setq cerebro--parked (assoc-delete-all name cerebro--parked)))

(defun cerebro--park-session (agent repo-root now)
  "End AGENT\='s session at NOW, keeping its buffer as the record of its pass.

Everything `cerebro--end-session\=' removes, except the one thing worth
keeping.  The buffer is renamed by `cerebro--parked-buffer-name\=', made
read-only, and recorded in `cerebro--parked\=' with when the session ended and
when it had started (`cerebro--started-at\='); `RET' on the standby row that
follows shows it (`cerebro--show-detail\=').

The order is load-bearing.  The `cerebro--sessions\=' entry goes *first*,
before the process is killed: `cerebro--note-exit\=' runs from vterm\='s
sentinel and finds the agent through that alist, so a session still recorded
would have this deliberate end echoed at the navigator as an abnormal exit -
and recorded in `cerebro--last-exit\=', where the placeholder would repeat it.
The query-on-exit flag goes with it, for the reason
`cerebro--forget-session\=' clears it: the navigator is not asked about a
kill the view decided on.

Read-only is set after the process is dead, since a live vterm resets it on
some input paths.  `RET\=' in the kept buffer reaches `vterm-send-return\=',
which is a no-op rather than an error once the process is gone."
  (let* ((name (cerebro-agent-name agent))
         (buffer (cerebro--recorded-buffer name))
         (started (cdr (assoc name cerebro--started-at))))
    (setq cerebro--sessions (assoc-delete-all name cerebro--sessions))
    (cerebro--forget-parked name)
    (when (buffer-live-p buffer)
      (let ((process (get-buffer-process buffer)))
        (when process
          (set-process-query-on-exit-flag process nil)
          (delete-process process)))
      (with-current-buffer buffer
        (rename-buffer (cerebro--parked-buffer-name name now) t)
        (setq buffer-read-only t)))
    (cerebro--delete-state-file repo-root name)
    (setf (alist-get name cerebro--parked nil nil #'equal)
          (list (float-time now) started (and (buffer-live-p buffer) buffer)))))

(defun cerebro--end-session (agent repo-root &optional clear-stop-flag)
  "End AGENT's session and remove every per-session artifact it leaves behind.

Buffer and `cerebro--sessions' entry always (`cerebro--forget-session');
the state file always, because a file naming a session that has been ended
is a claim about a pid that no longer exists and pids are recycled (see
`cerebro--session-alive-p'); the stop flag only when CLEAR-STOP-FLAG, since
only a retire has finished with the instruction.

This is the one owner of ending a session: every artifact a session leaves
is removed here or nowhere, so a further call site cannot be added
half-right - which is how the same omission came to be fixed twice, in the
two `cerebro--supervise' branches only, while `k' kept leaking a state file.

`cerebro--park-session\=' is the one shape that is deliberately not this
function (cb-5yr): it removes the same artifacts and *keeps the buffer*, which
is the record of the pass the role just finished.  Anything ending a session
calls one or the other; neither lists the artifacts a third time.

CLEAR-STOP-FLAG stays explicit rather than inferred from the state: a flag
written between an end being decided and this running is the navigator
pressing `f', and swallowing it silently is the inherited-instruction bug
with the sign reversed."
  (let ((name (cerebro-agent-name agent)))
    (cerebro--forget-session agent)
    (cerebro--delete-state-file repo-root name)
    (when clear-stop-flag (cerebro--clear-stop-flag repo-root name))))


;;; ah: the view's own log - what it decided, and what it declined to do

(defcustom cerebro-log-verbosity 'evaluations
  "How much of what the fleet view decides is written to its log.

`decisions\=' - only what the view did: a session started (with the trigger
that fired), ended, retired, nudged, a launch refused, a sweep
finding run.

`changes\=' - the decisions, plus one line each time a standby role\='s trigger
*answer* changes.  A planner that has been \"buffer 0 of 3\" for an hour is one
line rather than seven hundred, and the line lands on the tick the answer
changed.

`evaluations\=' - the decisions, plus every trigger evaluation on every tick.
The complete record, and the expensive one: a nine-agent fleet on a
five-second tick writes on the order of a hundred thousand lines a day, which
is why `cerebro-log-max-bytes\=' and `cerebro-log-generations\=' exist.

`none\=' - nothing at all.  The one value that can lose a decision, so it has
to be asked for by name: it is what the test suite binds, since
`cerebro--repo-root\=' resolves from `default-directory\=' and ERT would
otherwise append fabricated starts and exits to the live log the navigator
reads to answer \"why did nothing happen\".

Anything else logs the decisions alone: losing the record of a start is a
worse failure than a typo in a setting."
  :type '(choice (const decisions) (const changes) (const evaluations)
                 (const none))
  :group 'cerebro)

(defcustom cerebro-log-max-bytes (* 25 1024 1024)
  "Bytes the view\='s log may reach before it is rotated.

Larger than the 5 MB `scripts/agent-state\=' uses for `transitions.jsonl\=',
because that one is written when an agent changes state and this one can be
written on every tick.  What the number is really sizing is how much history
survives, so it is paired with `cerebro-log-generations\='."
  :type 'integer
  :group 'cerebro)

(defcustom cerebro-log-generations 3
  "How many rotated generations of the view\='s log are kept.

`decisions.1.jsonl\=' and so on, oldest discarded.  Three at 25 MB is a couple
of days at `evaluations\=' and months at `changes\='."
  :type 'integer
  :group 'cerebro)

(defconst cerebro--log-decision-events
  '(start end retire nudge standby arm refused exit sweep error)
  "The events written at every verbosity: what the view did, and what went
wrong while it did it.

`error\=' is on this list rather than behind a level of its own because an
error is not a level of detail: a navigator who sets `decisions\=' is asking
for less noise, not for a fleet that fails silently.  `none\=' still
loses it, along with everything else - that is what `none\=' means.")

(defun cerebro--log-event-p (event verbosity)
  "Pure.  Whether EVENT is written at VERBOSITY.  See `cerebro-log-verbosity\='.

`none\=' silences everything; every other value - including one this list has
never seen - still records what the view did."
  (and (not (eq verbosity 'none))
       (or (memq event cerebro--log-decision-events)
           (and (eq event 'evaluate) (memq verbosity '(changes evaluations))))
       t))

(defun cerebro--log-evaluation-p (name reason seen verbosity)
  "Pure.  Whether NAME\='s evaluation answering REASON is written now.

SEEN is an alist of (NAME . LAST-REASON).  At `evaluations\=' every tick is
written; at `changes\=' only an answer that differs from this agent\='s last
one, which is what makes a day of history fit in a file somebody might read."
  (or (eq verbosity 'evaluations)
      (not (and (assoc name seen)
                (equal reason (cdr (assoc name seen)))))))

(defun cerebro--log-line (event ts fields)
  "Pure.  One JSON object, one line: EVENT, TS, then FIELDS in order.

Nil values are written as `null\=' rather than dropped - \"evaluated, and there
was no reason\" is the answer half these lines carry, and a missing key would
read as \"not evaluated\".  `json-encode\=' would drop nothing here anyway; what
this guarantees is the *shape*, which a reader written against it depends on."
  (let ((json-encoding-pretty-print nil))
    (json-encode (append (list (cons 'event (symbol-name event))
                               (cons 'ts ts))
                         fields))))

(defun cerebro--log-rotate-p (size max-bytes)
  "Pure.  Whether a log of SIZE bytes has passed MAX-BYTES.

Nil SIZE - no file yet - is never a rotation."
  (and size (> size max-bytes)))

(defvar cerebro--log-start-reason nil
  "The trigger that is starting a session, while one is being started.

Let-bound by `cerebro--start-due\=' round its own launch, so the one place a
session is started (`cerebro--launch\=') is also the one place a start is
logged - `s\=', autostart and a trigger alike.  Nil means the navigator or the
autostart did it, which is exactly what the log should say.")

(defvar-local cerebro--log-seen nil
  "Alist of (NAME . LAST-REASON) - each standby role\='s last logged answer.

Only `cerebro-log-verbosity\=' `changes\=' reads it: at `evaluations\=' every tick
is written and at `decisions\=' none is.  Buffer-local, like the rest of the
view\='s state, and lost with the buffer - which costs one redundant line per
role after `M-x cerebro\=', not a wrong one.")

(defun cerebro--log-basename (event)
  "Pure.  Which log EVENT belongs in: \"errors\" or \"decisions\".

Two files, not one, and the reason is the question each answers.  The
decisions log is a hundred thousand lines a day at `evaluations\=' and is read
by searching it for an agent; the error log is read by opening it, because
the navigator has been pointed at it by a message that said something went
wrong.  An error buried in the first is a file nobody can be sent
to."
  (if (eq event 'error) "errors" "decisions"))

(defun cerebro--log-file (repo-root &optional generation base)
  "The BASE log under REPO-ROOT, or its GENERATIONth rotated copy.

BASE is `cerebro--log-basename\='s answer and defaults to the decisions log,
so a caller that has no view on the matter gets the file this function
always named.

Beside `scripts/agent-state\='s `transitions.jsonl\=' rather than in a directory
of its own: the two halves of one event - the view deciding to start a role,
that role\='s own first write seconds later - are read together or not at all,
and `.cerebro/state\=' is already what `.gitignore\=' names and what
`scripts/fleet-history\=' reads."
  (let ((base (or base "decisions")))
    (expand-file-name (if generation
                          (format ".cerebro/state/%s.%d.jsonl" base generation)
                        (format ".cerebro/state/%s.jsonl" base))
                      repo-root)))

(defun cerebro--log-rotate (repo-root &optional base)
  "Rotate the BASE log under REPO-ROOT if it has passed its size.

Generations shift up and the oldest is discarded, which is the whole of the
retention policy: `cerebro-log-generations\=' files of `cerebro-log-max-bytes\='.
One policy for both files rather than two settings: the error log is written
when something goes wrong, so in a healthy fleet it never reaches the size at
all, and a second pair of settings would only be a second thing to explain."
  (let ((file (cerebro--log-file repo-root nil base)))
    (when (cerebro--log-rotate-p (file-attribute-size (file-attributes file))
                                 cerebro-log-max-bytes)
      (let ((n cerebro-log-generations))
        (while (> n 1)
          (let ((older (cerebro--log-file repo-root n base))
                (newer (cerebro--log-file repo-root (1- n) base)))
            (when (file-exists-p newer) (rename-file newer older t)))
          (setq n (1- n)))
        (when (> cerebro-log-generations 0)
          (rename-file file (cerebro--log-file repo-root 1 base) t))))))

(defun cerebro--log (repo-root event fields)
  "Append one line to the view\='s log for EVENT with FIELDS, under REPO-ROOT.

Silent and unable to fail, for the reason `scripts/agent-state\=' gives about
its own log: the fleet must never be brought down by a full disk.  `O_APPEND\='
is what makes this safe beside the agents\=' own writer - one line is one
`write\=', and two writers cannot interleave."
  (when (and repo-root (cerebro--log-event-p event cerebro-log-verbosity))
    (let ((base (cerebro--log-basename event)))
      (ignore-errors
        ;; `.cerebro/state' is made by whichever agent writes its state first,
        ;; and a fleet that never started never has one - which is exactly the
        ;; fleet with something to say.  So the writer makes it, and
        ;; a directory that cannot be made is swallowed like everything else
        ;; here: a full disk must not take the view down.
        (make-directory (file-name-directory (cerebro--log-file repo-root nil base)) t)
        (cerebro--log-rotate repo-root base)
        (write-region
         (concat (cerebro--log-line
                  event (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t) fields)
                 "\n")
         nil (cerebro--log-file repo-root nil base) 'append 'silent)))))

(defun cerebro--log-error (repo-root context message)
  "Record MESSAGE in the error log under REPO-ROOT, blamed on CONTEXT.

CONTEXT is the part of the view the error came from - \"autostart\",
\"roster\", \"tick\" - and is what makes the file readable without knowing
the code: the navigator is looking for what failed, not for a backtrace.

Silent and unable to fail, like `cerebro--log\=', and more so: this is the
path that runs when something has already gone wrong, so it is the last
place that may signal."
  (cerebro--log repo-root 'error
                (list (cons 'context context) (cons 'message message))))

(defun cerebro--report-error (context format-string &rest args)
  "Say FORMAT-STRING with ARGS once, and keep it in the error log under CONTEXT.

The echo area is where the navigator sees an error and the log is where they
find it afterwards, and the two used to be separate decisions - which is how
eight declared agents failed to start with the only trace a message the
layout painted over half a second later.  One call does both."
  (let ((text (apply #'format format-string args)))
    (cerebro--log-error (ignore-errors (cerebro--repo-root)) context text)
    (message "cerebro: %s" text)
    text))

(defun cerebro--log-evaluation (repo-root agent reason context)
  "Log that AGENT\='s trigger was evaluated and answered REASON.

The loud half of the log, and the half that answers \"why did nothing
happen\" - a question the no-progress guard makes unanswerable any other way,
since its whole effect is that nothing does.  So the line carries what the
trigger read as well as what it decided."
  (let ((name (cerebro-agent-name agent)))
    (when (cerebro--log-evaluation-p name reason cerebro--log-seen
                                     cerebro-log-verbosity)
      (cerebro--log
       repo-root 'evaluate
       (list (cons 'agent name)
             (cons 'role (cerebro-agent-role agent))
             (cons 'reason reason)
             (cons 'planned (alist-get 'planned context))
             (cons 'planned_ids (alist-get 'planned-ids context))
             (cons 'implementers (alist-get 'implementers context))
             (cons 'p0_unplanned (alist-get 'p0-unplanned context))
             (cons 'p4_unranked (alist-get 'p4-unranked context))
             (cons 'merged_unverified (alist-get 'merged-unverified context))
             (cons 'stale_verdicts (alist-get 'stale-verdicts context))
             (cons 'held_by_guard
                   (and (null reason)
                        (equal (alist-get 'last-fingerprint context)
                               (cerebro--trigger-fingerprint
                                (cerebro-agent-role agent) context))
                        t))
             ;; A condition that was true and did not start anything, because
             ;; another holder of this role had just been started. Without
             ;; this the line reads "reason: buffer 0 of 2" with no start
             ;; beside it, which is the same unanswerable "why did nothing
             ;; happen" the rest of this record exists to close.
             (cons 'spaced_out (and (alist-get 'spaced-out context) t))
             ;; A condition that was true and started nothing because this
             ;; role's last launches produced no session. Without the count
             ;; beside it, a backed-off row and a broken one read alike.
             (cons 'backed_off (and (alist-get 'backed-off context) t))
             (cons 'failed_starts (alist-get 'failed-starts context)))))
    (setf (alist-get name cerebro--log-seen nil nil #'equal) reason)))

(defun cerebro--supervise (agents repo-root now)
  "Act on what `cerebro--supervise-action' says about each of AGENTS.

Errors are demoted: this runs from a timer, and one agent whose session
cannot be replaced must not stop the fleet view refreshing or take the
other agents down with it."
  (dolist (agent agents)
    (let ((name (cerebro-agent-name agent)))
      (unless (eq (cerebro-agent-state agent) 'asking)
        (setq cerebro--nudged (delete name cerebro--nudged)))
      (cerebro--with-logged-errors (format "supervise %s" name)
        (pcase (let ((action (cerebro--supervise-action
                              agent (cerebro--stop-flag-p repo-root name) now)))
                 (when action
                   (cerebro--log repo-root action
                                 (list (cons 'agent name)
                                       (cons 'role (cerebro-agent-role agent))
                                       (cons 'state (symbol-name
                                                     (cerebro-agent-state agent)))
                                       (cons 'bead (cerebro-agent-bead agent))
                                       (cons 'stop_flag
                                             (and (cerebro--stop-flag-p repo-root name) t)))))
                 action)
          ;; Both branches below end a session, so both take its state file
          ;; with them (`cerebro--delete-state-file').
          ('retire
           ;; An agent with a pass worth keeping keeps its buffer, exactly as
           ;; an ordinary end does - the flag says stay down, not forget the
           ;; pass - and is disarmed, so no trigger starts it again.  That is
           ;; every interactive role, and since cb-1or.1 a `waiting'
           ;; implementer too.  The condition reads the state and not only
           ;; the kind because an `idle' or `standby' implementer has
           ;; nothing worth keeping: `cerebro--end-session' takes its state
           ;; file with it, and parking it would keep a buffer for a bead
           ;; nothing will come back to.
           (if (or (eq (cerebro-agent-kind agent) 'interactive)
                   (eq (cerebro-agent-state agent) 'waiting))
               (progn (cerebro--park-session agent repo-root now)
                      (cerebro--clear-stop-flag repo-root name)
                      (setq cerebro--armed (delete name cerebro--armed)))
             ;; An implementer is armed too now, so retiring one has to
             ;; disarm it: the flag ends this session, and armed is what
             ;; would otherwise start the next (cb-hzs).
             (progn (cerebro--end-session agent repo-root 'clear-stop-flag)
                    (setq cerebro--armed (delete name cerebro--armed)))))
          ('end (cerebro--park-session agent repo-root now))
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
        (cerebro--with-logged-errors "sweep" (cerebro--sweep buffer))
        (cerebro--with-logged-errors "history" (cerebro--history buffer))
        (cerebro--with-logged-errors "beads" (cerebro--beads-render buffer))
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

;;; cb-5yr: acting on a standby role's trigger
;;;
;;; The impure half of the trigger: everything here reads a buffer-local
;;; the render has already filled - the bead panel's own partition, the
;;; fleet list, what was parked and when each session started - and so it
;;; lives below them rather than beside `cerebro--trigger', which is pure.

(defun cerebro--beads-panel-buffer ()
  "The bead panel buffer if it is live, or nil.

Its own function so the trigger context can be tested without one - a fleet
view whose panel has not been drawn yet is an ordinary state, not an error."
  (let ((buffer (get-buffer cerebro-beads-buffer-name)))
    (and (buffer-live-p buffer) buffer)))

;;; cb-5yr.2: what moved on GitHub, for Moira's and Cypher's triggers

(defvar cerebro-gh-refresh-seconds 600
  "How often `gh' is asked for the open issues and pull requests that decide
whether Moira or Cypher come back (cb-5yr.2).

Never on the five-second tick: each answer is a network call, and the two
roles it feeds are on an hourly floor anyway, so a ten-minute reader is
already finer-grained than anything it can cause.")

(defconst cerebro--gh-issues-argv
  '("gh" "issue" "list" "--state" "open" "--json" "number,updatedAt" "--limit" "100")
  "What Moira's trigger is read from: the open issues and when each last moved.")

(defconst cerebro--gh-prs-argv
  '("gh" "pr" "list" "--state" "open" "--json" "number,author,isDraft,updatedAt"
    "--limit" "100")
  "What Cypher's trigger is read from. `author' and `isDraft' are what make a
pull request his - somebody else's, and not a draft.")

(defconst cerebro--gh-me-argv '("gh" "api" "user" "-q" ".login")
  "The navigator's own `gh' login, which is what \"somebody else's\" is measured
against. Asked for until it answers and then never again.")

(defvar-local cerebro--gh-issues nil
  "The open issues `gh' last answered with, parsed, or nil before the first.")

(defvar-local cerebro--gh-prs nil
  "The open pull requests `gh' last answered with, parsed, or nil before the
first.")

(defvar-local cerebro--gh-me nil
  "The navigator's `gh' login, or nil until `gh api user' has answered.")

(defvar-local cerebro--gh-at nil
  "`float-time' of the last request, or nil when none has been made.")

(defvar-local cerebro--gh-as-of nil
  "`float-time' at which the issues and the pull requests were both last
answered, or nil before that has ever happened.")

(defvar-local cerebro--gh-failed-at nil
  "`float-time' of the last request either list did not answer, or nil once a
whole pair has answered since.

Compared against `cerebro--gh-as-of' rather than read on its own: the last
answer stands until a newer one replaces it, and it is the *order* of the two
that says whether what the trigger has is current.")

(defvar-local cerebro--gh-answers nil
  "The keys of the request now out that have answered, for this request only.")

(defun cerebro--gh-list-answered (buffer key parsed at)
  "Record in BUFFER that KEY answered with PARSED at AT.

`cerebro--parse-failed' - or no output at all, which the caller passes as
that - is not an answer: it stamps the failure and leaves the last lists
where they are, so a `gh' that goes away downgrades the two roles to their
cadence floor rather than telling them nothing ever moves."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (eq parsed cerebro--parse-failed)
          (setq cerebro--gh-failed-at at)
        (pcase key
          ('gh-issues (setq cerebro--gh-issues parsed))
          ('gh-prs (setq cerebro--gh-prs parsed)))
        (cl-pushnew key cerebro--gh-answers)
        (when (and (memq 'gh-issues cerebro--gh-answers)
                   (memq 'gh-prs cerebro--gh-answers))
          (setq cerebro--gh-as-of at
                cerebro--gh-failed-at nil))))))

(defun cerebro--request-gh-list (buffer key argv at)
  "Ask `gh' for KEY's list into BUFFER, stamping the answer at AT."
  (cerebro--run-async
   key (with-current-buffer buffer (cerebro--repo-root)) argv
   (lambda (out)
     (cerebro--gh-list-answered
      buffer key (if out (cerebro--try-parse-json out) cerebro--parse-failed) at))))

(defun cerebro--refresh-gh-when-due (buffer seconds)
  "Ask `gh' what is open, from BUFFER, if `cerebro-gh-refresh-seconds' have
passed at SECONDS.

Three calls rather than one: `gh' has no way of answering both lists at once,
and the login is asked for only while it is unknown. A key still in flight
answers `busy' and is simply not started again - the previous request is
waited for rather than stacked."
  (with-current-buffer buffer
    (when (cerebro--due-p cerebro--gh-at cerebro-gh-refresh-seconds seconds)
      (setq cerebro--gh-at seconds
            cerebro--gh-answers nil)
      (unless cerebro--gh-me
        (cerebro--run-async
         'gh-me (cerebro--repo-root) cerebro--gh-me-argv
         (lambda (out)
           (when (and out (buffer-live-p buffer))
             (with-current-buffer buffer
               (let ((login (string-trim out)))
                 (unless (string-empty-p login)
                   (setq cerebro--gh-me login))))))))
      (cerebro--request-gh-list buffer 'gh-issues cerebro--gh-issues-argv seconds)
      (cerebro--request-gh-list buffer 'gh-prs cerebro--gh-prs-argv seconds))))

(defun cerebro--gh-resolver ()
  "What the trigger context's `gh' key carries, read from this buffer.

Nil until a pair has ever arrived; `failed' when the newest thing to happen
was a request either list did not answer - the *order* of the two stamps,
not the presence of the failure, since the last good answer stands until a
newer one replaces it; otherwise a function of a role's ENDED-AT returning
what `cerebro--gh-moved' returns for it.

A function rather than an answer because ENDED-AT is per role and this is
gathered once a tick: see `cerebro--trigger-context'."
  (let ((issues cerebro--gh-issues)
        (prs cerebro--gh-prs)
        (me cerebro--gh-me)
        (as-of cerebro--gh-as-of)
        (failed-at cerebro--gh-failed-at))
    (cond
     ((and failed-at (or (null as-of) (> failed-at as-of))) 'failed)
     ((null as-of) nil)
     (t (lambda (ended-at) (cerebro--gh-moved issues prs me ended-at))))))

(defun cerebro--implementer-count (agents flagged-p)
  "Pure.  How many of AGENTS are implementers the fleet should have beads
planned for: every implementer on the roster, minus those told to finish.

FLAGGED-P is a predicate on a name: whether a stop flag is set for it.  State
is deliberately not read - since cb-1or.1 a builder between beads has no
session, so `standby\=', `dead\=', `idle\=' and `working\=' all count
(cb-1or.3).  An implementer told to finish takes no further bead, so a bead
planned for it is planned for nobody.  The shell copy is
`scripts/planner-buffer --want\='."
  (seq-count (lambda (agent)
               (and (eq (cerebro-agent-kind agent) 'implementer)
                    (not (funcall flagged-p (cerebro-agent-name agent)))))
             agents))

(defun cerebro--trigger-context (repo-root now)
  "What every standby role\='s trigger is judged against, at NOW.

Impure, and deliberately cheap: it counts what this tick has already read -
the bead panel\='s own partition (`cerebro--beads\='), the fleet list beside it
\(`cerebro--agents\='), and the cached roster - and makes no `bd\=' call of its
own.  A trigger evaluated once per standby row per five-second tick cannot
afford a subprocess.

A panel that has not answered yet reports no work rather than none wanted:
`planned\=' comes back high enough that no buffer rule can fire, because \"the
figures have not arrived\" and \"the buffer is empty\" are the same number
otherwise, and the second of them starts both planners at once.

The `gh\=' key is what Moira\='s and Cypher\='s rows are judged on, and it
cannot be a plain answer here: \"what moved\" is measured against the
role\='s own last pass, which is `cerebro--agent-context\='s to add.  So it
is a *resolver* - a function of ENDED-AT returning what
`cerebro--gh-moved\=' returns - which that one calls once per standby row.
Nil before the first answer, and `failed\=' when the last thing to happen
was a failure, are both plain values: neither depends on whose pass it is."
  (let* ((panel (cerebro--beads-panel-buffer))
         (beads (and panel (buffer-local-value 'cerebro--beads panel)))
         ;; What a planner may actually take, both sides of the buffer rule:
         ;; a bead parked in the navigator's queue is not work anybody in the
         ;; fleet can move (`cerebro-parked-labels'), and counting it starts a
         ;; session to find nothing to do.
         (planned (cerebro--actionable-beads (nth 1 beads)))
         (unplanned (cerebro--actionable-beads (nth 3 beads)))
         (merged (nth 4 beads))
         (open-beads (append (nth 0 beads) (nth 1 beads) (nth 2 beads) (nth 3 beads))))
    (list (cons 'now (float-time now))
          (cons 'planned (if beads (length planned) most-positive-fixnum))
          (cons 'p0-unplanned
                (mapcar (lambda (bead) (alist-get 'id bead))
                        (seq-filter (lambda (bead) (equal (alist-get 'priority bead) 0))
                                    unplanned)))
          (cons 'p4-unranked (cerebro--count-priority unplanned 4))
          ;; The ids rather than their number, because the fingerprint the
          ;; no-progress guard compares has to see one bead replaced by
          ;; another (`cerebro--trigger-fingerprint').
          (cons 'actionable-ids
                (mapcar (lambda (bead) (alist-get 'id bead)) unplanned))
          ;; The planned, claimable ids: what a standby implementer is
          ;; started for, and what its fingerprint compares (cb-1or.1).  Nil
          ;; before the panel has answered, which is what keeps "no figures
          ;; yet" from starting a builder - `planned' above reads
          ;; `most-positive-fixnum' there, so the rule keys on this instead.
          (cons 'planned-ids
                (mapcar (lambda (bead) (alist-get 'id bead)) planned))
          (cons 'merged-unverified (length merged))
          (cons 'stale-verdicts (seq-count #'cerebro--stale-verdict-p open-beads))
          ;; One stat per implementer per tick, which is within what this
          ;; docstring's "deliberately cheap" allows; the rule itself is
          ;; `cerebro--implementer-count'.
          (cons 'implementers
                (cerebro--implementer-count
                 cerebro--agents
                 (lambda (name) (cerebro--stop-flag-p repo-root name))))
          (cons 'first-planner
                (car (cerebro--fleet-role-names (cerebro--fleet repo-root) "planner")))
          (cons 'gh (cerebro--gh-resolver)))))

(defun cerebro--agent-context (agent context)
  "CONTEXT with the facts that are AGENT\='s rather than the fleet\='s.

`gh\=' among them: the fleet\='s answer arrives as a resolver, and what it
resolves to is this role\='s `ended-at\=', so the same reader answers Moira
about her last pass and Cypher about his.

Kept out of `cerebro--trigger-context\=' so that one is gathered once a tick
and this one is a few conses per standby row."
  (let* ((name (cerebro-agent-name agent))
         ;; When this agent's last session ended.  The moment the view parked
         ;; it, for every agent that ended a pass - since cb-1or.1 that is an
         ;; implementer too.  Only one whose session simply *died* has no
         ;; parked entry, and there the last tick that saw it up is the
         ;; nearest thing to an end there is (cb-hzs).
         (ended-at (or (nth 0 (cdr (assoc name cerebro--parked)))
                       (and (eq (cerebro-agent-kind agent) 'implementer)
                            (cdr (assoc name cerebro--seen-up)))))
         (gh (alist-get 'gh context)))
    (append (list (cons 'gh (if (functionp gh) (funcall gh ended-at) gh))
                  (cons 'ended-at ended-at)
                  ;; What the backoff is indexed by, read here so the row and
                  ;; `cerebro--start-due' have one source for it.
                  (cons 'failed-starts
                        (or (cdr (assoc name cerebro--failed-starts)) 0))
                  (cons 'started-at (cdr (assoc name cerebro--started-at)))
                  ;; What this role's own last start was triggered by, for
                  ;; `cerebro--unless-unchanged'.
                  (cons 'last-fingerprint
                        (cdr (assoc name cerebro--start-fingerprints)))
                  (cons 'floor (cerebro-wake-interval name (cerebro-agent-role agent)))
                  (cons 'first-planner-p
                        (equal name (alist-get 'first-planner context))))
            context)))

(defun cerebro--start-due (repo-root now)
  "Start every standby role in `cerebro--agents\=' whose trigger is true at NOW.

The other half of `cerebro--supervise\=', and it runs straight after it: that
one ends a session when a pass is over, this one starts a fresh one when
there is another pass to make.  Nothing here is a clock the role set -
`cerebro--trigger\=' is the whole decision, and the echo line says which of its
rules fired, so a start is never something the navigator has to reconstruct.

Errors are demoted per agent, as everywhere else that launches in a loop:
one role whose launcher refuses must not stop the rest being started.  With
no vterm there is nothing to start a session in at all, and saying so once
per tick per role would be worse than saying nothing - `cerebro--autostart\='
is where that is said."
  (when (cerebro--vterm-available-p)
    (let ((context (cerebro--trigger-context repo-root now))
          (now-float (float-time now)))
      (dolist (agent cerebro--agents)
        (when (eq (cerebro-agent-state agent) 'standby)
          (let* ((agent-context (cerebro--agent-context agent context))
                 (reason (cerebro--trigger agent agent-context))
                 ;; A true condition is not yet a start: a role two agents
                 ;; hold answers it for both at once, and two planners racing
                 ;; for one candidate is what that costs
                 ;; (`cerebro-role-start-spacing'). Checked inside the loop
                 ;; rather than before it, because `cerebro--launch' writes
                 ;; `cerebro--started-at' - so the second planner in this very
                 ;; loop already sees the first.
                 (too-soon (and reason
                                (cerebro--role-start-too-soon-p
                                 (cerebro--role-peers agent cerebro--agents)
                                 cerebro--started-at
                                 (cerebro--role-start-spacing (cerebro-agent-role agent))
                                 now-float)))
                 ;; A launch that produced no session is retried - b94e782 -
                 ;; but not on every tick: with the preflight refusing, that
                 ;; was 135 starts for one role, five seconds apart. The wait
                 ;; is measured from the failed start itself, so the first
                 ;; retry is still immediate.
                 (name (cerebro-agent-name agent))
                 (started (alist-get 'started-at agent-context))
                 (failed (cerebro--start-failed-p started
                                                  (alist-get 'ended-at agent-context)))
                 (failures (alist-get 'failed-starts agent-context))
                 ;; The same arithmetic the standby row counts down, so the
                 ;; row and the decision cannot disagree about when a retry
                 ;; is due (`cerebro--retry-wait').
                 (backed-off (and reason failed
                                  (> (cerebro--retry-wait failures started now-float) 0)))
                 ;; `failed-starts' is already in the context
                 ;; (`cerebro--agent-context'), which is where the row reads
                 ;; it too - one source, so the label and the decision cannot
                 ;; disagree about how far into the backoff this name is.
                 (agent-context (append (list (cons 'spaced-out too-soon)
                                              (cons 'backed-off backed-off))
                                        agent-context)))
            (cerebro--log-evaluation repo-root agent reason agent-context)
            (when (and reason (not too-soon) (not backed-off))
              ;; Counted before the launch, from what the LAST one did: a
              ;; start that follows a failure is one more failure until a pass
              ;; proves otherwise, and a start that follows a pass starts over.
              (setf (alist-get name cerebro--failed-starts nil nil #'equal)
                    (if failed (1+ failures) 0))
              (cerebro--with-logged-errors (format "start %s" name)
                (let ((cerebro--log-start-reason reason))
                  (cerebro--launch agent))
                (message "%s" (cerebro--start-message
                               (cerebro-agent-name agent) reason))))))))))

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
         ;; Machine-wide scan, narrowed twice: to this consumer's own sessions,
         ;; since another checkout's fleet has the same names and a name alone
         ;; is not an identity across repositories (`cerebro--consumer-processes');
         ;; and then to the pids that are still alive, since the scan is cached
         ;; for half a minute and a snapshot is evidence about when it was taken
         ;; and no later (`cerebro--live-processes').
         (procs (cerebro--live-processes
                 (cerebro--consumer-processes (cerebro--cached-system-processes) repo-root)
                 (lambda (pid) (process-attributes pid))))
         (args (mapcar #'cdr procs))
         (owned (cerebro--owned))
         (now (current-time))
         (agents (cerebro--derive roster interactive states
                                          (lambda (pid name)
                                            (cerebro--session-alive-p pid name repo-root))
                                          args owned)))
    ;; Standby is derived here rather than in `cerebro--derive': the state
    ;; file the derive reads was deleted when the view ended the session, so
    ;; `cerebro--armed' is the only thing that can say a role is coming back.
    ;; A name whose session died abnormally is not coming back on a trigger,
    ;; however it is armed (cb-eat) - `cerebro--last-exit' is the record,
    ;; cleared by `cerebro--launch', so `s' is the way back.
    (setq agents (cerebro--apply-standby agents cerebro--armed
                                         (cerebro--failed-names cerebro--last-exit)))
    ;; And the session count, for the same reason as standby: `cerebro--derive'
    ;; is given the args as strings, and a duplicate is a fact about the pids
    ;; beside them (cb-63m).
    (setq agents (cerebro--apply-session-counts agents procs))
    (setq cerebro--agents agents)
    ;; An implementer's `ended-at': the last tick that saw its session up
    ;; (`cerebro--seen-up'). A role records the moment the view parked it;
    ;; an implementer is never parked, so this is what tells a start that
    ;; produced a session from one that produced nothing (cb-hzs).
    (let ((at (float-time now)))
      (dolist (name (cerebro--up-names agents))
        (setf (alist-get name cerebro--seen-up nil nil #'equal) at)))
    ;; The Bead/Phase text is computed before the widths, because it is what
    ;; the last column has to be wide enough for.  Once for the buffer, not
    ;; once a row: the same counts answer every standby label, and gathering
    ;; them per row would read the bead panel eighteen times a render.
    (let* ((context (and (seq-some (lambda (a) (eq (cerebro-agent-state a) 'standby)) agents)
                         (cerebro--trigger-context repo-root now)))
           (for-texts
            (mapcar (lambda (a)
                      (cons (cerebro-agent-name a)
                            (cond
                             ((eq (cerebro-agent-state a) 'standby)
                              (and context
                                   (cerebro--standby-label
                                    a (cerebro--agent-context a context))))
                             ((eq (cerebro-agent-state a) 'dead)
                              (cerebro--exit-line
                               (alist-get (cerebro-agent-name a) cerebro--last-exit
                                          nil nil #'equal)
                               (or (alist-get (cerebro-agent-name a) cerebro--failed-starts
                                              nil nil #'equal)
                                   0))))))
                    agents))
           ;; The table is sized to what is in front of it, every revert: a
           ;; roster gains an agent, a bead id gets deeper, and the columns
           ;; follow (ah-qled.9).
           (widths (cerebro--column-widths
                    (mapcar #'cerebro-agent-name agents)
                    (mapcar #'cerebro-agent-role agents)
                    (delq nil (mapcar #'cerebro-agent-bead agents))
                    (delq nil (mapcar #'cdr for-texts)))))
      (setq cerebro-list-width (cerebro--width-for widths))
      (let ((format (cerebro--table-format widths)))
        (unless (equal tabulated-list-format format)
          (setq tabulated-list-format format)
          (tabulated-list-init-header)))
      (setq tabulated-list-entries
            (mapcar (lambda (a)
                      (let ((text (alist-get (cerebro-agent-name a) for-texts
                                             nil nil #'equal))
                            (standby (eq (cerebro-agent-state a) 'standby)))
                        (cerebro--entry a now
                                        (cerebro--stop-flag-p repo-root (cerebro-agent-name a))
                                        (nth 3 widths)
                                        (and standby text)
                                        (and (not standby) text))))
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
on a state file read five seconds ago - and then `cerebro--start-due', which
starts a fresh session for every standby role whose trigger has come true
(cb-5yr).  Then the bead panel, when its
thirty seconds are up, the `gh' reader, when its ten minutes are (cb-5yr.2),
and the sweeps, when their ten minutes are: one
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
        (let ((repo-root (cerebro--repo-root)))
          (cerebro--supervise cerebro--agents repo-root now)
          ;; After, not before: a role ended on this very tick is not on
          ;; standby until the next render restates it, which is what stops a
          ;; pass being ended and restarted inside one tick.
          (cerebro--start-due repo-root now))
        ;; From the fleet buffer, because that is where the answers are read
        ;; back from (`cerebro--trigger-context'), and on its own ten-minute
        ;; cadence rather than this five-second one (cb-5yr.2).
        (cerebro--with-logged-errors "gh"
          (cerebro--refresh-gh-when-due buffer (float-time now))))
      (let ((panel (get-buffer cerebro-beads-buffer-name)))
        (when (buffer-live-p panel)
          (cerebro--with-logged-errors "panel"
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
          ('duplicate (message "%s" (cerebro--duplicate-message-for agent repo-root)))
          ('external (message "%s is running outside Emacs" name)))))))

(defun cerebro--kill-session-buffer (agent repo-root)
  "End AGENT's session (`k'), then refresh the view and the detail window.

`cerebro-kill' has already confirmed this exact kill via `y-or-n-p', so the
process's query-on-exit flag is cleared - in `cerebro--forget-session',
which `cerebro--end-session' calls - rather than prompting a
second time.  The state file goes with the session, which is
what stops the row reading `working' on a bead nobody is building.

The stop flag is left alone: `k' is not a retire, and a flag set with `f'
means this name stays down until `s' clears it and says so.  An interactive
name is *disarmed* here for the same reason (cb-5yr): `k' means stay down,
and a name still armed would be started again by its own trigger within five
seconds.

REPO-ROOT is passed in rather than looked up here, so `cerebro--repo-root'
and its buffer-local `default-directory' work stay out of the unit under
test - `cerebro-kill' computes it once for all its branches."
  (cerebro--end-session agent repo-root)
  (setq cerebro--armed (delete (cerebro-agent-name agent) cerebro--armed))
  (revert-buffer)
  (cerebro--show-detail agent))

(defun cerebro-kill ()
  "Kill the agent at point (`k'), confirming first.

A role on standby has no process to kill: `k' there is `disarm' - forget the
kept buffer and start nothing more under that name until `s' says so
(cb-5yr)."
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
        ('disarm
         (when (y-or-n-p (format "Disarm %s? " (cerebro-agent-name agent)))
           (setq cerebro--armed (delete (cerebro-agent-name agent) cerebro--armed))
           (cerebro--forget-parked (cerebro-agent-name agent))
           (revert-buffer)))
        ('duplicate
         (message "%s" (cerebro--duplicate-message-for agent repo-root)))
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
that deletes a stop flag, so retire, end and `s' can all call it
without checking first - and, since `cerebro--supervise' runs from a timer
with demoted errors, an uncaught `file-missing' here would otherwise be
swallowed silently rather than simply doing nothing."
  (condition-case nil
      (delete-file (cerebro--stop-flag-path repo-root name))
    (file-missing nil)))

(defun cerebro-finish ()
  "Tell the implementer at point to finish (`f'): write its stop flag.

An interactive role has a pass rather than a bead, and the flag means the
same thing about it: the pass finishes, and nothing starts in its place
(cb-5yr).  `cerebro--supervise-action' reads it at `waiting' or `idle', ends
the session and disarms the name, so `f' then `s' is the round trip.  A role
on standby has no pass to finish and gets a line saying which key does what.

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
          ('write-disarm
           (cerebro--write-stop-flag repo-root name)
           (revert-buffer)
           (message "told %s to finish its pass - it stays down until you press s" name))
          ('duplicate
           (message "%s" (cerebro--duplicate-message-for agent repo-root)))
          ('standby
           (message "%s is on standby - press k to disarm it, or s to start it now" name))
          ('dead (message "%s is not running - nothing to finish" name))
          ('external
           (message "%s is running outside Emacs - stop it from its own terminal" name)))))))

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
  (let ((buffer (get-buffer-create cerebro-buffer-name))
        fresh)
    (with-current-buffer buffer
      ;; Computed BEFORE `cerebro-mode' runs and consulted after the first
      ;; render: "the fleet buffer is created" is the moment autostart fires
      ;; (cb-0r6), so a later `M-x cerebro' on a live buffer starts nothing -
      ;; it would otherwise restart whatever `k' had just killed. After `q'
      ;; the next call is fresh again, which is what the navigator asked for.
      (setq fresh (not (derived-mode-p 'cerebro-mode)))
      (unless (derived-mode-p 'cerebro-mode)
        (cerebro-mode))
      (cerebro--list-render buffer)
      (cerebro--cancel-timer)
      (setq cerebro--timer
            (run-with-timer 5 5 #'cerebro--tick buffer))
      (cerebro--ensure-prune-watcher (cerebro--repo-root))
      (when fresh
        (cerebro--autostart buffer (cerebro--repo-root))))
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
