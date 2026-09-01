//! The Rust data boundary for the standalone fleet view (cb-vyp.1).
//!
//! This crate is read-only by construction: it may read files and run
//! `scripts/roster`, `ps` and `bd --readonly`, but it exposes no write,
//! launch, stop, trigger, supervision or state-cleanup operation. Emacs
//! remains the sole supervisor. The bead panel is `cb-vyp.3`; since cb-vyp.2
//! this crate also carries the screen itself - the pure parsing/derivation
//! (`model`), the impure readers that feed it (`readers`), the display state
//! and refresh schedule (`app`) and the renderer (`ui`). The binary in
//! `main.rs` owns nothing but the terminal, the event loop and the worker.
//! Since cb-42k, Fleet and Work are two independently focused, independently
//! scrolling widgets rather than one shared document - `PaneFocus`, and each
//! pane's own `PaneMetrics` inside `Metrics`, are what the event loop and the
//! renderer share to keep that true.

pub mod app;
pub mod model;
pub mod readers;
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
pub use app::{App, AppAction, FleetWorker, Metrics, Pane, PaneContent, PaneFocus, PaneMetrics, WorkWorker};
pub use ui::{draw, metrics};
