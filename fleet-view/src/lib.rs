//! The Rust data boundary for the standalone fleet view (cb-vyp.1).
//!
//! This crate reads files and runs `scripts/roster`, `ps`, `bd --readonly`,
//! `gh` and `scripts/fleet-supervisor`. Since cb-kcs.2.3 it also WRITES to two of the
//! fleet's contracts, and only through `lifecycle`: it creates and removes an
//! agent's stop flag, and it deletes the state file of a session it is ending
//! or replacing, and it appends to the three JSONL logs beside them
//! (`decisions.jsonl` and `errors.jsonl`, cb-kcs.4.4; `evaluations.jsonl`,
//! cb-xhu.2). Since cb-kcs.5.1 it also
//! writes to the BOARD, in one place and only on a confirmed keystroke:
//! `lifecycle::run_finding` runs the `bd` a sweep finding names and then `bd
//! dolt push`, both through `readers::CommandRunner` like every other
//! command this crate runs (cb-i1w). It never writes a state file -
//! `scripts/agent-state` is the one author of those. Since cb-kcs.3 it also
//! acts UNATTENDED on the sessions it hosts: it ends one whose pass is over,
//! retires one under a stop flag and clears the flag with it, and types one
//! line into an implementer whose question nobody answered.
//!
//! Since cb-kcs.4.1 it also STARTS sessions on its own: it evaluates the
//! board-backed triggers for the planner, implementer, verifier and
//! orchestrator roles, honours the roster's own `autostart`/`standby`
//! declaration, and disarms a name on `k` or on a retire. Since cb-kcs.4.2 a
//! start that keeps failing is not retried for ever: it backs off on
//! `0/30s/2m/10m`, its row counts the wait down, and after five consecutive
//! starts that produced no pass the name is disarmed and only `s` brings it
//! back. Since cb-kcs.5.1 it also runs the six sweep scripts on their own
//! ten-minute cadence, draws what they found as the Work pane's first section,
//! and acts on one with `x` after showing the exact command. Since cb-kcs.5.2
//! it runs the last two of the supervisor's own unattended jobs: it keeps a
//! `prune-worktrees.sh --watch` child alive beside itself while it may act -
//! killing it when it may not, and saying in red when it will not start - and
//! it types the triage line into an idle orchestrator when unranked beads are
//! waiting for a ranking. Since cb-kcs.4.3 it also starts the three roles whose work arrives
//! from OUTSIDE the fleet - `user-feedback`, `reviewer` and `architect` - off
//! a `gh` reader on its own ten-minute cadence, the beads linked to a GitHub
//! issue, and an hourly floor per role. Both JSONL logs remain cb-kcs.4.4's.
//!
//! Since cb-kcs.1 it may hold ONE piece of state - the supervision lease
//! (`supervisor`), a bound loopback listener that says which fleet view a
//! project has declared may act on this checkout. Holding it is not acting:
//! this crate takes the lease when `.cerebro/project.conf` says `tui` and
//! then does nothing further with it, because the sessions, the lifecycle
//! keys and the triggers are `cb-kcs.2` onwards. With the declaration absent
//! or `emacs` - which is every consumer today, this one included - the lease
//! is Emacs's and this crate is exactly the reader it always was. The bead panel is `cb-vyp.3`; since cb-vyp.2
//! this crate also carries the screen itself - the pure parsing/derivation
//! (`model`), the impure readers that feed it (`readers`), the display state
//! and refresh schedule (`app`) and the renderer (`ui`). The binary in
//! `main.rs` owns nothing but the terminal, the event loop and the worker.
//! Since cb-42k, Fleet and Work are two independently focused, independently
//! scrolling widgets rather than one shared document - `PaneFocus`, and each
//! pane's own `PaneMetrics` inside `Metrics`, are what the event loop and the
//! renderer share to keep that true.
//!
//! Since cb-kcs.2.2 the Session pane can hold a real child: `session` owns the
//! pty, the terminal emulator behind it and the pure functions that turn a
//! keystroke into bytes and a screen into lines. `main` owns the `SessionHost`;
//! `App` only ever sees a `SessionView` materialised before the frame, which is
//! what keeps `ui::draw` pure while a reader thread writes continuously.
//!
//! Since cb-kcs.2.3 the navigator can press `s`, `f` and `k` - start the selected
//! agent, toggle its stop flag, and kill a session this process hosts after a
//! confirmation - each of them gated on `SupervisionMode` (`may_supervise` to
//! start, `may_end` to finish or kill) and each refused with a visible line when
//! it is not. `lifecycle` is where all three decide and where every write lives;
//! `main::route_key` is the one path a keystroke takes to reach them.

pub mod app;
pub mod lifecycle;
pub mod log;
pub mod model;
pub mod pruner;
pub mod probe;
pub mod readers;
pub mod session;
pub mod supervisor;
pub mod sweeps;
pub mod triggers;
pub mod ui;

pub use model::{
    derive_fleet, parse_processes, parse_roster, partition_beads, session_liveness, AgentKind,
    Bead, FleetRow, ModelError, ProcessRow, RosterEntry, RowState, SessionLiveness, StateInputs,
    StateObservation, StateRecord, WorkBuckets,
};
pub use readers::{
    read_beads, read_fleet, read_processes, read_roster, read_states, read_sweeps, read_work,
    Judged, CommandRunner,
    Commands, Invocation, Programs, ReadError, ReaderPaths, RealCommands,
};
pub use supervisor::{
    reconcile_supervision, AcquireError, ReadOnlyReason, ReconcileAction, SupervisionMode,
    SupervisorKind, SupervisorLease,
};
pub use session::{
    exit_line, key_bytes, materialise, paste_bytes, transcript, Ended, Retained, Session,
    SessionHost, SessionView, SCROLLBACK_LINES,
};
pub use app::{
    work_body, work_line_of_cursor, App, AppAction, FleetWorker, Metrics, Pane, PaneContent,
    HistoryWorker, PaneFocus, PaneMetrics, Prompt, SupervisorWorker, SweepWorker,
    WorkBodyLine, WorkWorker,
};
pub use sweeps::{
    finding_command, findings_from, label as sweep_label, prompt as sweep_prompt, Blocker,
    Candidate, Finding, LiveSession, Snapshot, Sweep,
};
pub use lifecycle::{
    finish_outcome, join_names, kill_outcome, quit_refusal_lines, quit_refusal_title,
    start, start_outcome, FinishOutcome, KillOutcome, Situation, StartOutcome,
};
pub use log::{
    log_evaluation_p, log_event_p, log_file, log_line, log_rotate_p, reader_context, Event, Logger,
    Verbosity, GENERATIONS, MAX_BYTES, VERBOSITY,
};
pub use ui::{draw, metrics};
