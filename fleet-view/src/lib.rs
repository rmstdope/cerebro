//! The Rust data boundary for the standalone fleet view (cb-vyp.1).
//!
//! This crate reads files and runs `scripts/roster`, `ps`, `bd --readonly` and
//! `scripts/fleet-supervisor`, and it exposes no launch, stop, trigger or
//! state-cleanup operation: it still starts and ends nothing.
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
//! what keeps `ui::draw` pure while a reader thread writes continuously. Nothing
//! a navigator can press starts a child yet - `s`, `f` and `k` are cb-kcs.2.3's -
//! so this crate still starts nothing on its own.

pub mod app;
pub mod lifecycle;
pub mod model;
pub mod readers;
pub mod session;
pub mod supervisor;
pub mod ui;

pub use model::{
    derive_fleet, parse_processes, parse_roster, partition_beads, session_liveness, AgentKind,
    Bead, FleetRow, ModelError, ProcessRow, RosterEntry, RowState, SessionLiveness, StateInputs,
    StateObservation, StateRecord, WorkBuckets,
};
pub use readers::{
    read_beads, read_fleet, read_processes, read_roster, read_states, read_work, Programs,
    ReadError, ReaderPaths,
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
    start_outcome, FinishOutcome, KillOutcome, Situation, StartOutcome,
};
pub use ui::{draw, metrics};
