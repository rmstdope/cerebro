//! The Rust data boundary for the standalone fleet view (cb-vyp.1).
//!
//! This crate reads files and runs `scripts/roster`, `ps`, `bd --readonly`,
//! `gh` and `scripts/fleet-supervisor`. Since cb-kcs.2.3 it also WRITES to two of the
//! fleet's contracts, and only through `lifecycle`: it creates and removes an
//! agent's stop flag, and it deletes the state file of a session it is ending
//! or replacing. It never writes a state file - `scripts/agent-state` is the
//! one author of those. Since cb-kcs.3 it also acts UNATTENDED on the sessions
//! it hosts: it ends one whose pass is over, retires one under a stop flag and
//! clears the flag with it, and types one line into an implementer whose
//! question nobody answered.
//!
//! Since cb-kcs.4.1 it also STARTS sessions on its own: it evaluates the
//! board-backed triggers for the planner, implementer, verifier and
//! orchestrator roles, honours the roster's own `autostart`/`standby`
//! declaration, and disarms a name on `k` or on a retire. Since cb-kcs.4.3 it
//! also starts the three roles whose work arrives from OUTSIDE the fleet -
//! `user-feedback`, `reviewer` and `architect` - off a `gh` reader on its own
//! ten-minute cadence, the beads linked to a GitHub issue, and an hourly floor
//! per role. The retry backoff and both JSONL logs remain cb-kcs.4.2's
//! and .4.4's.
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
pub mod model;
pub mod readers;
pub mod session;
pub mod supervisor;
pub mod triggers;
pub mod ui;

pub use model::{
    derive_fleet, parse_processes, parse_roster, partition_beads, session_liveness, AgentKind,
    Bead, FleetRow, ModelError, ProcessRow, RosterEntry, RowState, SessionLiveness, StateInputs,
    StateObservation, StateRecord, WorkBuckets,
};
pub use readers::{
    read_beads, read_fleet, read_processes, read_roster, read_states, read_work, CommandRunner,
    Commands, Programs, ReadError, ReaderPaths, RealCommands,
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
    App, AppAction, FleetWorker, Metrics, Pane, PaneContent, PaneFocus, PaneMetrics, Prompt,
    SupervisorWorker, WorkWorker,
};
pub use lifecycle::{
    finish_outcome, join_names, kill_outcome, quit_refusal_lines, quit_refusal_title,
    start, start_outcome, FinishOutcome, KillOutcome, Situation, StartOutcome,
};
pub use ui::{draw, metrics};
