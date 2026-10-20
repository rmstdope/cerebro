//! Who may supervise this checkout, and the lease that proves it (cb-kcs.1).
//!
//! Two processes can read one consumer at the same time and both be right; only one of them may
//! *act* on it. This module is that rule, in two halves that are deliberately kept apart:
//!
//! * [`reconcile_supervision`] is pure. It answers "what am I, and what do I do about the lease?"
//!   from one value and nothing else: whether this process holds the listener.
//! * [`SupervisorLease`] is the lease itself: a bound loopback [`TcpListener`] that accepts
//!   nothing. **The bind is the lock.** No pid file, no timestamp, no heartbeat, no lease duration
//!   and no stale-entry sweep takes part in acquisition, and that is the whole point - the kernel
//!   closes a listener when its holder dies, so a crashed owner releases *immediately* and without
//!   anybody deciding it had crashed. Every timeout-based scheme has a window in which a live owner
//!   looks dead; this one has none.
//!
//! The JSON record beside it (`supervisor.json`) is **diagnosis only**. It names the checkout
//! whose window holds the lease, and it never grants, transfers or withholds ownership: a
//! missing, malformed or foreign record on a bound port is a visible lock error, never permission
//! to take over. A stale record left by a crash is harmless, because the successful bind that
//! overwrites it is what was authoritative all along.

use std::fmt;
use std::fs;
use std::io::ErrorKind;
use std::net::{SocketAddr, TcpListener};
use std::path::{Path, PathBuf};

/// Why this process is not supervising. Each variant is a different sentence on the header line,
/// which is the whole of the TUI's ownership surface (the navigator's choice in cb-kcs.1).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReadOnlyReason {
    /// Somebody else holds the lease. The one thing that means a second window is driving this
    /// fleet, and the one read-only reason that hands the armed set over.
    OwnedBy,
    /// The lease could not be read or bound, and we refuse to guess.
    LockError(String),
    /// Not holding it yet, and no attempt has failed. The provisional answer
    /// [`reconcile_supervision`] returns with [`ReconcileAction::Acquire`]; a caller replaces it
    /// within the same tick with `Supervising` or with the reason the bind failed.
    NotOwned,
}

/// What this process is, right now. Display state: it is derived, never stored.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SupervisionMode {
    ReadOnly(ReadOnlyReason),
    Supervising,
}

impl SupervisionMode {
    /// The coarse word the log's `mode` field carries.
    pub fn word(&self) -> &'static str {
        match self {
            SupervisionMode::ReadOnly(_) => "read-only",
            SupervisionMode::Supervising => "supervising",
        }
    }

    /// May this process start, nudge or end anything at all? Only one mode says yes, and every
    /// caller in either implementation asks through this rather than matching the enum itself.
    pub fn may_supervise(&self) -> bool {
        matches!(self, SupervisionMode::Supervising)
    }

    /// Does this mode mean somebody ELSE has, or is taking, this checkout?
    ///
    /// The one question the armed set is answered from (cb-nc8). [`may_supervise`] asks whether
    /// this view may act NOW, which is false for a transient failure too - and disarming on one of
    /// those is what cb-nc8 was: a permanent consequence drawn from a recoverable condition. Three
    /// modes hand over, and every other one leaves the armed set exactly as it was.
    ///
    /// [`may_supervise`]: SupervisionMode::may_supervise
    pub fn hands_over(&self) -> bool {
        matches!(self, SupervisionMode::ReadOnly(ReadOnlyReason::OwnedBy))
    }
}

impl ReadOnlyReason {
    /// The log's word for this reason.
    pub fn word(&self) -> &'static str {
        match self {
            ReadOnlyReason::OwnedBy => "owned-by",
            ReadOnlyReason::LockError(_) => "lock-error",
            ReadOnlyReason::NotOwned => "not-owned",
        }
    }
}

/// What to do about the lease this tick.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReconcileAction {
    Acquire,
    Keep,
}

/// The whole ownership rule, as a function of one value.
///
/// `holds_lease` is whether this process holds the listener *now*. Holding it is supervision;
/// not holding it is read-only, and the answer is to try to take it. A retry after a failed
/// attempt is the same decision as the first attempt, which is what makes `g` a retry key rather
/// than a special case, and there is no third answer.
///
/// Read-only is the honest answer until the bind actually succeeds: a process that called itself
/// supervising before it owned anything is exactly the double supervisor the lease prevents.
pub fn reconcile_supervision(holds_lease: bool) -> (SupervisionMode, ReconcileAction) {
    if holds_lease {
        (SupervisionMode::Supervising, ReconcileAction::Keep)
    } else {
        (
            SupervisionMode::ReadOnly(ReadOnlyReason::NotOwned),
            ReconcileAction::Acquire,
        )
    }
}

/// Why an acquisition did not happen. None of these is ever a reason to take the lease anyway.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AcquireError {
    /// The port is bound and the record names this checkout: an honest, live owner.
    OwnedBy,
    /// The port is bound but the record names a different checkout - two roots hashed onto one
    /// port. Fail-closed: neither side acts.
    EndpointCollision { identity: String },
    /// The port is bound and the record is missing or malformed; or the
    /// record could not be written after a successful bind.
    LockError(String),
}

impl fmt::Display for AcquireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AcquireError::OwnedBy => write!(f, "the lease is already held"),
            AcquireError::EndpointCollision { identity } => write!(
                f,
                "the lease endpoint is bound by another checkout ({identity})"
            ),
            AcquireError::LockError(message) => write!(f, "{message}"),
        }
    }
}

/// A held supervision lease: the bound listener, plus the diagnostic record naming its holder.
///
/// Dropping it removes the record and then closes the listener, in that order. The order is the
/// whole of the cleanup contract: a replacement cannot bind until the close, so this cannot delete
/// a record its successor has already written.
#[derive(Debug)]
pub struct SupervisorLease {
    listener: TcpListener,
    record_path: PathBuf,
    identity: String,
}

impl SupervisorLease {
    /// Bind the endpoint, and only then write the record.
    ///
    /// `AddrInUse` is the ordinary contended case and is diagnosed from the record; every other
    /// bind error is a lock error. A record that cannot be written after a successful bind closes
    /// the listener again rather than holding a lease nobody can identify.
    pub fn try_acquire(
        endpoint: SocketAddr,
        record_path: &Path,
        identity: &str,
    ) -> Result<Self, AcquireError> {
        let listener = match TcpListener::bind(endpoint) {
            Ok(listener) => listener,
            Err(err) if err.kind() == ErrorKind::AddrInUse => {
                return Err(diagnose_holder(record_path, identity));
            }
            Err(err) => {
                return Err(AcquireError::LockError(format!(
                    "cannot bind the supervision lease at {endpoint}: {err}"
                )));
            }
        };

        let lease = SupervisorLease {
            listener,
            record_path: record_path.to_path_buf(),
            identity: identity.to_string(),
        };
        lease.write_record().map_err(|message| {
            // Drop the listener with the error rather than holding an lease no other process could
            // attribute: an unattributable lease is exactly the `LockError` deadlock we refuse.
            AcquireError::LockError(message)
        })?;
        Ok(lease)
    }

    /// The address actually bound. Useful when a test binds port 0 and needs to know what it got.
    pub fn endpoint(&self) -> std::io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    fn write_record(&self) -> Result<(), String> {
        if let Some(parent) = self.record_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        // Written whole and renamed into place: a reader must never see half a record, and a
        // half-written record is a `LockError` that would stall the other implementation.
        let temp = self.record_path.with_extension("json.tmp");
        // `endpoint` is diagnosis: which port the holder is on.
        let endpoint = self
            .listener
            .local_addr()
            .map_err(|e| format!("cannot read the lease's own address: {e}"))?;
        let body = format!(
            "{{\"identity\":{},\"endpoint\":{},\"pid\":{}}}\n",
            json_string(&self.identity),
            json_string(&endpoint.to_string()),
            std::process::id()
        );
        fs::write(&temp, body).map_err(|e| format!("cannot write {}: {e}", temp.display()))?;
        fs::rename(&temp, &self.record_path)
            .map_err(|e| format!("cannot install {}: {e}", self.record_path.display()))
    }
}

impl Drop for SupervisorLease {
    fn drop(&mut self) {
        // Only our own record, and only while we still hold the port. A record naming somebody
        // else is somebody else's, whatever went wrong here.
        if let Some(RecordFields { identity }) = read_record(&self.record_path) {
            if identity == self.identity {
                let _ = fs::remove_file(&self.record_path);
            }
        }
        // The listener closes as this struct drops, after the record is gone.
    }
}

struct RecordFields {
    identity: String,
}

/// The record on a bound port, read for diagnosis alone. Whatever this returns, the caller does
/// not get the lease.
fn diagnose_holder(record_path: &Path, identity: &str) -> AcquireError {
    match read_record(record_path) {
        Some(fields) if fields.identity == identity => AcquireError::OwnedBy,
        Some(fields) => AcquireError::EndpointCollision {
            identity: fields.identity,
        },
        None => AcquireError::LockError(format!(
            "the supervision lease is held, but {} is missing or malformed",
            record_path.display()
        )),
    }
}

/// A deliberately small hand parser rather than `serde_json`: the record has two flat fields and
/// is read on a path that must not fail in interesting ways.
fn read_record(path: &Path) -> Option<RecordFields> {
    let text = fs::read_to_string(path).ok()?;
    let identity = json_field(&text, "identity")?;
    Some(RecordFields { identity })
}

fn json_field(text: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let start = text.find(&needle)? + needle.len();
    let rest = text[start..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                other => out.push(other),
            },
            other => out.push(other),
        }
    }
    None
}

fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- the ownership rule --------------------------------------------------------------------

    /// Which modes empty the armed set, exhaustively (cb-nc8).
    ///
    /// Only a handover - somebody else has, or is taking, this checkout - may have the permanent
    /// consequence of disarming every name. Everything else, including "I could not find out",
    /// leaves the set alone and recovers on the next good poll with no keystroke.
    ///
    /// The elisp counterpart is `cerebro-test/an-unreadable-declaration-leaves-the-armed-set-alone'.
    #[test]
    fn only_a_handover_hands_over() {
        use ReadOnlyReason::*;

        assert!(
            SupervisionMode::ReadOnly(OwnedBy).hands_over(),
            "somebody else holds it: that IS the handover"
        );

        let keeps = [
            SupervisionMode::ReadOnly(LockError("bind refused".into())),
            SupervisionMode::ReadOnly(NotOwned),
            SupervisionMode::Supervising,
        ];
        for mode in keeps {
            assert!(!mode.hands_over(), "{mode:?} must not disarm anything");
        }
    }

    /// Each reason's log word, so a `disarm-all` line names why in the same vocabulary Emacs uses.
    #[test]
    fn every_read_only_reason_has_a_log_word() {
        use ReadOnlyReason::*;
        assert_eq!(OwnedBy.word(), "owned-by");
        assert_eq!(LockError("x".into()).word(), "lock-error");
        assert_eq!(NotOwned.word(), "not-owned");
    }

    #[test]
    fn only_supervising_may_supervise() {
        assert!(SupervisionMode::Supervising.may_supervise());

        for reason in [
            ReadOnlyReason::OwnedBy,
            ReadOnlyReason::LockError("boom".to_string()),
            ReadOnlyReason::NotOwned,
        ] {
            let mode = SupervisionMode::ReadOnly(reason.clone());
            assert!(!mode.may_supervise(), "may_supervise for {reason:?}");
        }
    }

    /// The whole ownership rule, which is one boolean and has exactly two answers.
    ///
    /// This replaced `tests/lib/supervisor.cases` in cb-abs.2. A `tests/lib/` table exists to hold
    /// two implementations to one rule; there is one implementation now, and the rule shrank to a
    /// bool - so the two rows it would carry are worth more here, beside the function.
    #[test]
    fn holding_the_lease_is_the_whole_of_supervision() {
        assert_eq!(
            reconcile_supervision(true),
            (SupervisionMode::Supervising, ReconcileAction::Keep)
        );
        assert_eq!(
            reconcile_supervision(false),
            (
                SupervisionMode::ReadOnly(ReadOnlyReason::NotOwned),
                ReconcileAction::Acquire
            )
        );
    }

    // --- the record's encoding --------------------------------------------------------------
    //
    // The lease itself - the bind, the record file, the collision and lock-error diagnoses - is
    // the Edge's, in `tests/supervisor_lease.rs` (cb-92g0). What stays here is the encoding, over
    // plain strings.

    /// Whatever an identity holds, the record's reader gets back what its writer put in.
    #[test]
    fn the_record_encoding_round_trips_awkward_identities() {
        for identity in [
            "/repos/x",
            "/repos/with \"quotes\" and \\ backslash",
            "/repos/tab\there/and\nnewline",
            "",
        ] {
            let record = format!("{{\"identity\":{},\"pid\":1}}\n", json_string(identity));
            assert_eq!(json_field(&record, "identity").as_deref(), Some(identity), "{record}");
        }
    }

    /// A record without the field, or with it cut short, has no identity - which a bound port
    /// turns into a lock error, never permission.
    #[test]
    fn a_missing_or_unterminated_field_is_no_identity() {
        assert_eq!(json_field("{ this is not json", "identity"), None);
        assert_eq!(json_field("{\"pid\":1}", "identity"), None);
        assert_eq!(json_field("{\"identity\":\"/repos/x", "identity"), None);
        assert_eq!(json_field("{\"identity\":42}", "identity"), None);
    }
}
