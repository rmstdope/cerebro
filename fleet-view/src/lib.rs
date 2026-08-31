//! The Rust data boundary for the standalone fleet view (cb-vyp.1).
//!
//! This crate is read-only by construction: it may read files and run
//! `scripts/roster`, `ps` and `bd --readonly`, but it exposes no write,
//! launch, stop, trigger, supervision or state-cleanup operation. Emacs
//! remains the sole supervisor. Rendering (`cb-vyp.2`) and the bead panel
//! (`cb-vyp.3`) are later children; this crate only re-exports pure
//! parsing/derivation (`model`) and the impure readers that feed it
//! (`readers`).

pub mod model;
pub mod readers;

pub use model::{
    derive_fleet, parse_processes, parse_roster, partition_beads, session_liveness, AgentKind,
    Bead, FleetRow, ModelError, ProcessRow, RosterEntry, RowState, SessionLiveness, StateInputs,
    StateObservation, StateRecord, WorkBuckets,
};
pub use readers::{
    read_beads, read_processes, read_roster, read_states, Programs, ReadError, ReaderPaths,
};
