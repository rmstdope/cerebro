//! Who may supervise this checkout, and the lease that proves it (cb-kcs.1).
//!
//! Two processes can read one consumer at the same time and both be right; only one of them may
//! *act* on it. This module is that rule, in two halves that are deliberately kept apart:
//!
//! * [`reconcile_supervision`] is pure. It answers "what am I, and what do I do about the lease?"
//!   from four values and nothing else, and it is held to `tests/lib/supervisor.cases` - the same
//!   table `cerebro--supervision-decision` answers, because Emacs and Ratatui disagreeing here is
//!   either two supervisors or none.
//! * [`SupervisorLease`] is the lease itself: a bound loopback [`TcpListener`] that accepts
//!   nothing. **The bind is the lock.** No pid file, no timestamp, no heartbeat, no lease duration
//!   and no stale-entry sweep takes part in acquisition, and that is the whole point - the kernel
//!   closes a listener when its holder dies, so a crashed owner releases *immediately* and without
//!   anybody deciding it had crashed. Every timeout-based scheme has a window in which a live owner
//!   looks dead; this one has none.
//!
//! The JSON record beside it (`supervisor.json`) is **diagnosis only**. It says who to name in
//! `read-only; Emacs owns supervision`, and it never grants, transfers or withholds ownership: a
//! missing, malformed or foreign record on a bound port is a visible lock error, never permission
//! to take over. A stale record left by a crash is harmless, because the successful bind that
//! overwrites it is what was authoritative all along.

use std::fmt;
use std::fs;
use std::io::ErrorKind;
use std::net::{SocketAddr, TcpListener};
use std::path::{Path, PathBuf};

/// Which implementation a process is. The declaration names one of these; a process is one.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SupervisorKind {
    Emacs,
    Tui,
}

impl SupervisorKind {
    /// The word `scripts/fleet-supervisor` prints, and the word the record carries.
    pub fn as_str(self) -> &'static str {
        match self {
            SupervisorKind::Emacs => "emacs",
            SupervisorKind::Tui => "tui",
        }
    }

    /// The declaration's two accepted spellings, and nothing else - a value this does not
    /// recognise is an invalid declaration, never a default.
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "emacs" => Some(SupervisorKind::Emacs),
            "tui" => Some(SupervisorKind::Tui),
            _ => None,
        }
    }
}

impl fmt::Display for SupervisorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Why this process is not supervising. Each variant is a different sentence on the header line,
/// which is the whole of the TUI's ownership surface (the navigator's choice in cb-kcs.1).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReadOnlyReason {
    /// The project declares the other implementation.
    ConfiguredFor(SupervisorKind),
    /// The project declares us, but somebody else holds the lease.
    OwnedBy(SupervisorKind),
    /// The declaration is neither `emacs` nor `tui`; the string is the raw offending value.
    InvalidDeclaration(String),
    /// The lease could not be read or bound, and we refuse to guess.
    LockError(String),
    /// Configured for us, not holding it yet, and no attempt has failed. The provisional answer
    /// [`reconcile_supervision`] returns with [`ReconcileAction::Acquire`]; a caller replaces it
    /// within the same tick with `Supervising` or with the reason the bind failed.
    NotOwned,
}

/// What this process is, right now. Display state: it is derived, never stored.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SupervisionMode {
    ReadOnly(ReadOnlyReason),
    Supervising,
    /// Holding a lease the declaration has taken away, with sessions still hosted. New starts and
    /// nudges stop; the sessions stay usable; the lease goes when the last one ends.
    Draining {
        configured_for: Option<SupervisorKind>,
        live_sessions: usize,
    },
}

impl SupervisionMode {
    /// The coarse word `tests/lib/supervisor.cases` speaks.
    pub fn word(&self) -> &'static str {
        match self {
            SupervisionMode::ReadOnly(_) => "read-only",
            SupervisionMode::Supervising => "supervising",
            SupervisionMode::Draining { .. } => "draining",
        }
    }

    /// May this process start, nudge or end anything at all? Only one mode says yes, and every
    /// caller in either implementation asks through this rather than matching the enum itself.
    pub fn may_supervise(&self) -> bool {
        matches!(self, SupervisionMode::Supervising)
    }
}

/// What to do about the lease this tick.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReconcileAction {
    Acquire,
    Keep,
    Release,
}

impl ReconcileAction {
    pub fn word(self) -> &'static str {
        match self {
            ReconcileAction::Acquire => "acquire",
            ReconcileAction::Keep => "keep",
            ReconcileAction::Release => "release",
        }
    }
}

/// The whole ownership rule, as a function of four values.
///
/// `configured` is `Ok(kind)` for a declaration this build understands and `Err(raw)` for one it
/// does not - the raw word, so the header can name it. `holds_lease` is whether this process holds
/// the listener *now*; `hosted_sessions` is how many agent sessions it is hosting (always 0 until
/// cb-kcs.2 adds PTYs, and written for them now so the drain is not retrofitted later).
///
/// Every row of `tests/lib/supervisor.cases` runs through this, and through
/// `cerebro--supervision-decision` in Emacs. The two must agree row for row.
pub fn reconcile_supervision(
    local: SupervisorKind,
    configured: Result<SupervisorKind, String>,
    holds_lease: bool,
    hosted_sessions: usize,
) -> (SupervisionMode, ReconcileAction) {
    // Configured for us: supervise if we hold it, otherwise try to take it. A retry after a failed
    // attempt is the same decision as the first attempt, which is what makes `g` a retry key
    // rather than a special case.
    if configured.as_ref().ok() == Some(&local) {
        return if holds_lease {
            (SupervisionMode::Supervising, ReconcileAction::Keep)
        } else {
            (
                SupervisionMode::ReadOnly(ReadOnlyReason::NotOwned),
                ReconcileAction::Acquire,
            )
        };
    }

    // Configured for somebody else, or not configured at all. An invalid declaration lands here
    // deliberately: fail-closed, so a typo neither grants supervision nor drops live sessions.
    let reason = match &configured {
        Ok(other) => ReadOnlyReason::ConfiguredFor(*other),
        Err(raw) => ReadOnlyReason::InvalidDeclaration(raw.clone()),
    };

    if !holds_lease {
        return (SupervisionMode::ReadOnly(reason), ReconcileAction::Keep);
    }

    if hosted_sessions == 0 {
        return (SupervisionMode::ReadOnly(reason), ReconcileAction::Release);
    }

    (
        SupervisionMode::Draining {
            configured_for: configured.ok(),
            live_sessions: hosted_sessions,
        },
        ReconcileAction::Keep,
    )
}

/// Why an acquisition did not happen. None of these is ever a reason to take the lease anyway.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AcquireError {
    /// The port is bound and the record names this checkout: an honest, live owner.
    OwnedBy(SupervisorKind),
    /// The port is bound but the record names a different checkout - two roots hashed onto one
    /// port. Fail-closed: neither side acts.
    EndpointCollision { identity: String },
    /// The port is bound and the record is missing, malformed, or names an unknown owner; or the
    /// record could not be written after a successful bind.
    LockError(String),
}

impl fmt::Display for AcquireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AcquireError::OwnedBy(kind) => write!(f, "the lease is held by {kind}"),
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
        owner: SupervisorKind,
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
        lease.write_record(owner).map_err(|message| {
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

    fn write_record(&self, owner: SupervisorKind) -> Result<(), String> {
        if let Some(parent) = self.record_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        // Written whole and renamed into place: a reader must never see half a record, and a
        // half-written record is a `LockError` that would stall the other implementation.
        let temp = self.record_path.with_extension("json.tmp");
        let body = format!(
            "{{\"identity\":{},\"owner\":\"{}\",\"pid\":{}}}\n",
            json_string(&self.identity),
            owner.as_str(),
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
        if let Some(RecordFields { identity, .. }) = read_record(&self.record_path) {
            if identity == self.identity {
                let _ = fs::remove_file(&self.record_path);
            }
        }
        // The listener closes as this struct drops, after the record is gone.
    }
}

struct RecordFields {
    identity: String,
    owner: Option<SupervisorKind>,
}

/// The record on a bound port, read for diagnosis alone. Whatever this returns, the caller does
/// not get the lease.
fn diagnose_holder(record_path: &Path, identity: &str) -> AcquireError {
    match read_record(record_path) {
        Some(fields) if fields.identity == identity => match fields.owner {
            Some(kind) => AcquireError::OwnedBy(kind),
            None => AcquireError::LockError(format!(
                "the supervision lease is held, but {} names an owner this build does not know",
                record_path.display()
            )),
        },
        Some(fields) => AcquireError::EndpointCollision {
            identity: fields.identity,
        },
        None => AcquireError::LockError(format!(
            "the supervision lease is held, but {} is missing or malformed",
            record_path.display()
        )),
    }
}

/// A deliberately small hand parser rather than `serde_json`: the record has three flat fields and
/// is read on a path that must not fail in interesting ways.
fn read_record(path: &Path) -> Option<RecordFields> {
    let text = fs::read_to_string(path).ok()?;
    let identity = json_field(&text, "identity")?;
    let owner = json_field(&text, "owner").and_then(|word| SupervisorKind::parse(&word));
    Some(RecordFields { identity, owner })
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
    use std::net::{Ipv4Addr, SocketAddrV4};

    // --- the shared transition table ------------------------------------------------------------

    fn kind(word: &str) -> SupervisorKind {
        SupervisorKind::parse(word)
            .unwrap_or_else(|| panic!("supervisor.cases: unknown kind {word}"))
    }

    /// Every row of `tests/lib/supervisor.cases`, which `cerebro--supervision-decision` answers
    /// too. A row either side answers differently is a fleet with two supervisors or none.
    #[test]
    fn both_implementations_follow_the_shared_transition_table() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/lib/supervisor.cases");
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"));
        let mut rows = 0;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = trimmed.split_whitespace().collect();
            assert_eq!(fields.len(), 6, "supervisor.cases: malformed row: {line}");
            let local = kind(fields[0]);
            let configured = match fields[1] {
                "invalid" => Err("rat".to_string()),
                word => Ok(kind(word)),
            };
            let holds = match fields[2] {
                "yes" => true,
                "no" => false,
                other => panic!("supervisor.cases: expected yes or no, got {other}"),
            };
            let hosted: usize = fields[3]
                .parse()
                .unwrap_or_else(|_| panic!("supervisor.cases: bad hosted count: {line}"));

            let (mode, action) = reconcile_supervision(local, configured, holds, hosted);
            assert_eq!(mode.word(), fields[4], "mode for row: {line}");
            assert_eq!(action.word(), fields[5], "action for row: {line}");
            rows += 1;
        }
        assert!(rows >= 20, "supervisor.cases: only {rows} rows ran");
    }

    #[test]
    fn a_drain_names_who_it_is_draining_for_and_how_many_are_left() {
        let (mode, action) = reconcile_supervision(
            SupervisorKind::Emacs,
            Ok(SupervisorKind::Tui),
            true,
            3,
        );
        assert_eq!(action, ReconcileAction::Keep);
        assert_eq!(
            mode,
            SupervisionMode::Draining {
                configured_for: Some(SupervisorKind::Tui),
                live_sessions: 3
            }
        );
        assert!(!mode.may_supervise(), "a draining view must not act");
    }

    #[test]
    fn an_invalid_declaration_drains_for_nobody_and_keeps_its_raw_word() {
        let (mode, action) = reconcile_supervision(
            SupervisorKind::Emacs,
            Err("rat".to_string()),
            true,
            1,
        );
        assert_eq!(action, ReconcileAction::Keep);
        assert_eq!(
            mode,
            SupervisionMode::Draining { configured_for: None, live_sessions: 1 }
        );

        let (mode, action) =
            reconcile_supervision(SupervisorKind::Tui, Err("rat".to_string()), false, 0);
        assert_eq!(action, ReconcileAction::Keep);
        assert_eq!(
            mode,
            SupervisionMode::ReadOnly(ReadOnlyReason::InvalidDeclaration("rat".to_string()))
        );
    }

    #[test]
    fn only_supervising_may_act() {
        assert!(SupervisionMode::Supervising.may_supervise());
        assert!(!SupervisionMode::ReadOnly(ReadOnlyReason::NotOwned).may_supervise());
        assert!(!SupervisionMode::Draining { configured_for: None, live_sessions: 1 }
            .may_supervise());
    }

    // --- the lease itself -----------------------------------------------------------------------

    /// A free loopback port, found by binding one and letting it go. The race this leaves is
    /// harmless here: every test below binds the port it was given and asserts on the result.
    fn free_port() -> u16 {
        let probe = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind probe");
        probe.local_addr().expect("probe addr").port()
    }

    fn endpoint(port: u16) -> SocketAddr {
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port))
    }

    #[test]
    fn one_owner_at_a_time_and_the_record_names_it() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("state/supervisor.json");
        let addr = endpoint(free_port());

        let held = SupervisorLease::try_acquire(addr, &record, "/repos/x", SupervisorKind::Tui)
            .expect("the first acquisition");
        let body = std::fs::read_to_string(&record).expect("the record exists");
        assert!(body.contains("\"owner\":\"tui\""), "record: {body}");
        assert!(body.contains("\"identity\":\"/repos/x\""), "record: {body}");

        match SupervisorLease::try_acquire(addr, &record, "/repos/x", SupervisorKind::Emacs) {
            Err(AcquireError::OwnedBy(SupervisorKind::Tui)) => {}
            other => panic!("a second acquisition must be refused, got {other:?}"),
        }

        drop(held);
        assert!(!record.exists(), "dropping the lease removes its own record");
        SupervisorLease::try_acquire(addr, &record, "/repos/x", SupervisorKind::Emacs)
            .expect("the port is free once the lease drops");
    }

    #[test]
    fn a_record_from_another_checkout_is_a_collision_not_a_takeover() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        let addr = endpoint(free_port());

        let _held = SupervisorLease::try_acquire(addr, &record, "/repos/other", SupervisorKind::Emacs)
            .expect("the first acquisition");

        match SupervisorLease::try_acquire(addr, &record, "/repos/mine", SupervisorKind::Tui) {
            Err(AcquireError::EndpointCollision { identity }) => {
                assert_eq!(identity, "/repos/other");
            }
            other => panic!("a foreign record must be a collision, got {other:?}"),
        }
    }

    #[test]
    fn a_bound_port_with_no_record_is_a_lock_error_never_permission() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        let addr = endpoint(free_port());

        // Somebody else's listener, with nothing of ours behind it.
        let _foreign = TcpListener::bind(addr).expect("foreign bind");

        match SupervisorLease::try_acquire(addr, &record, "/repos/x", SupervisorKind::Tui) {
            Err(AcquireError::LockError(message)) => {
                assert!(message.contains("missing or malformed"), "message: {message}");
            }
            other => panic!("a bound port with no record must be a lock error, got {other:?}"),
        }
    }

    #[test]
    fn a_malformed_record_is_a_lock_error_too() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        std::fs::write(&record, "{ this is not json").expect("write");
        let addr = endpoint(free_port());
        let _foreign = TcpListener::bind(addr).expect("foreign bind");

        match SupervisorLease::try_acquire(addr, &record, "/repos/x", SupervisorKind::Tui) {
            Err(AcquireError::LockError(_)) => {}
            other => panic!("a malformed record must be a lock error, got {other:?}"),
        }
    }

    #[test]
    fn a_stale_record_is_overwritten_by_a_successful_bind() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        // What a crashed owner leaves behind: a record, and no listener.
        std::fs::write(&record, "{\"identity\":\"/repos/x\",\"owner\":\"emacs\",\"pid\":1}\n")
            .expect("write");

        let addr = endpoint(free_port());
        let _held = SupervisorLease::try_acquire(addr, &record, "/repos/x", SupervisorKind::Tui)
            .expect("a stale record must not block acquisition");
        let body = std::fs::read_to_string(&record).expect("record");
        assert!(body.contains("\"owner\":\"tui\""), "record: {body}");
    }

    #[test]
    fn an_identity_round_trips_through_the_record() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        let addr = endpoint(free_port());
        let weird = "/repos/with \"quotes\" and \\ backslash";

        let _held = SupervisorLease::try_acquire(addr, &record, weird, SupervisorKind::Emacs)
            .expect("acquire");
        let fields = read_record(&record).expect("record parses");
        assert_eq!(fields.identity, weird);
        assert_eq!(fields.owner, Some(SupervisorKind::Emacs));
    }
}
