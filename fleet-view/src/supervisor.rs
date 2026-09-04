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
    /// The declaration itself could not be read - the reader timed out, failed to spawn, or
    /// answered in a way this build does not understand. Distinct from `LockError` because it
    /// says nothing about who holds the lease: a process in this state may well be holding it
    /// itself, and saying "the lease is held by another process" there would be false twice over.
    DeclarationUnreadable(String),
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

    /// May this process END something it is already hosting? `Supervising`, and also `Draining` -
    /// a view that has been told to hand over still has to be able to finish and kill the sessions
    /// it holds, because ending them is what ends the drain (`emacs/cerebro.el:4635-4641`, the same
    /// rule).
    ///
    /// Starting asks [`SupervisionMode::may_supervise`]; ending asks this. No caller matches the
    /// enum itself.
    pub fn may_end(&self) -> bool {
        matches!(
            self,
            SupervisionMode::Supervising | SupervisionMode::Draining { .. }
        )
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
        match self {
            SupervisionMode::Draining { .. } => true,
            SupervisionMode::ReadOnly(ReadOnlyReason::ConfiguredFor(_)) => true,
            SupervisionMode::ReadOnly(ReadOnlyReason::OwnedBy(_)) => true,
            SupervisionMode::ReadOnly(_) | SupervisionMode::Supervising => false,
        }
    }
}

impl ReadOnlyReason {
    /// The log's word for this reason, spelled as `emacs/cerebro.el`'s own reason symbols are.
    pub fn word(&self) -> &'static str {
        match self {
            ReadOnlyReason::ConfiguredFor(_) => "configured-for",
            ReadOnlyReason::OwnedBy(_) => "owned-by",
            ReadOnlyReason::InvalidDeclaration(_) => "invalid",
            ReadOnlyReason::LockError(_) => "lock-error",
            ReadOnlyReason::DeclarationUnreadable(_) => "declaration-unreadable",
            ReadOnlyReason::NotOwned => "not-owned",
        }
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
    use crate::probe;
    use std::net::{Ipv4Addr, SocketAddrV4};

    // --- the shared transition table ------------------------------------------------------------

    fn kind(word: &str) -> SupervisorKind {
        SupervisorKind::parse(word)
            .unwrap_or_else(|| panic!("supervisor.cases: unknown kind {word}"))
    }

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

        let hands_over = [
            SupervisionMode::Draining {
                configured_for: Some(SupervisorKind::Emacs),
                live_sessions: 2,
            },
            SupervisionMode::ReadOnly(ConfiguredFor(SupervisorKind::Emacs)),
            SupervisionMode::ReadOnly(OwnedBy(SupervisorKind::Tui)),
        ];
        for mode in hands_over {
            assert!(mode.hands_over(), "{mode:?} is a handover");
        }

        let keeps = [
            SupervisionMode::ReadOnly(InvalidDeclaration("tui2".into())),
            SupervisionMode::ReadOnly(LockError("bind refused".into())),
            SupervisionMode::ReadOnly(DeclarationUnreadable("boom".into())),
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
        assert_eq!(ConfiguredFor(SupervisorKind::Emacs).word(), "configured-for");
        assert_eq!(OwnedBy(SupervisorKind::Tui).word(), "owned-by");
        assert_eq!(InvalidDeclaration("rat".into()).word(), "invalid");
        assert_eq!(LockError("x".into()).word(), "lock-error");
        assert_eq!(DeclarationUnreadable("x".into()).word(), "declaration-unreadable");
        assert_eq!(NotOwned.word(), "not-owned");
    }

    #[test]
    fn a_draining_view_may_end_but_not_start() {
        let supervising = SupervisionMode::Supervising;
        assert!(supervising.may_supervise());
        assert!(supervising.may_end());

        let draining = SupervisionMode::Draining {
            configured_for: Some(SupervisorKind::Emacs),
            live_sessions: 2,
        };
        assert!(!draining.may_supervise());
        assert!(draining.may_end());

        for reason in [
            ReadOnlyReason::ConfiguredFor(SupervisorKind::Emacs),
            ReadOnlyReason::OwnedBy(SupervisorKind::Emacs),
            ReadOnlyReason::InvalidDeclaration("rat".to_string()),
            ReadOnlyReason::LockError("boom".to_string()),
            ReadOnlyReason::DeclarationUnreadable("boom".to_string()),
            ReadOnlyReason::NotOwned,
        ] {
            let mode = SupervisionMode::ReadOnly(reason.clone());
            assert!(!mode.may_supervise(), "may_supervise for {reason:?}");
            assert!(!mode.may_end(), "may_end for {reason:?}");
        }
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

    // Between a probe closing and the caller binding, anything on the machine may take the port -
    // so NOTHING below asserts on a bind that used `probe::free_endpoint` directly. Setting up a
    // lease goes through `acquire_on_a_free_port`, which retries, and a test that needs a foreign
    // listener binds it on port 0 and asks it what it got. Two of these cases were written the
    // obvious way first and failed about one run in ten, which is the kind of test this repository
    // refuses to ship.
    fn endpoint(port: u16) -> SocketAddr {
        SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port))
    }

    /// A held lease, on whatever loopback port was actually free. A lost race here is setup
    /// noise, never the thing under assertion, so it simply tries the next port.
    fn acquire_on_a_free_port(
        record: &Path,
        identity: &str,
        owner: SupervisorKind,
    ) -> (SupervisorLease, SocketAddr) {
        probe::wait_for(probe::POLL_BOUND, || {
            let addr = probe::free_endpoint();
            SupervisorLease::try_acquire(addr, record, identity, owner)
                .ok()
                .map(|lease| (lease, addr))
        })
        .expect("no free loopback port for a test lease")
    }

    /// Take a lease that ought to be free, allowing for the moment after a release in which it is
    /// not quite.
    ///
    /// `fork` duplicates every descriptor, so any process on the machine sitting between fork and
    /// exec is holding a copy of a listener that has just been closed - it goes at the child's own
    /// exec (`O_CLOEXEC`), milliseconds later. That is a real property of the lease and not a test
    /// artefact: a supervisor releasing while something else forks is a lease that is free on the
    /// NEXT attempt, which is why both implementations retry on their own tick rather than
    /// treating one refusal as final.
    fn acquire_once_free(
        addr: SocketAddr,
        record: &Path,
        identity: &str,
        owner: SupervisorKind,
    ) -> SupervisorLease {
        let mut last = None;
        // `probe::POLL_BOUND` rather than the plan's count x interval (200 x 20ms = 4s): that
        // identity only holds when an attempt is free, and this one binds a socket. The bound is
        // the wall clock the case gets, not an attempt budget.
        let lease = probe::wait_for(probe::POLL_BOUND, || {
            match SupervisorLease::try_acquire(addr, record, identity, owner) {
                Ok(lease) => Some(lease),
                Err(error) => {
                    last = Some(error);
                    None
                }
            }
        });
        match lease {
            Some(lease) => lease,
            None => panic!("the lease never became free: {last:?}"),
        }
    }

    /// Somebody else's listener, and the address it actually got. Bound on port 0, so there is no
    /// window between finding the port and holding it.
    fn foreign_listener() -> (TcpListener, SocketAddr) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("foreign bind");
        let addr = listener.local_addr().expect("foreign addr");
        (listener, addr)
    }

    #[test]
    fn one_owner_at_a_time_and_the_record_names_it() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("state/supervisor.json");
        let (held, addr) = acquire_on_a_free_port(&record, "/repos/x", SupervisorKind::Tui);
        let body = std::fs::read_to_string(&record).expect("the record exists");
        assert!(body.contains("\"owner\":\"tui\""), "record: {body}");
        assert!(body.contains("\"identity\":\"/repos/x\""), "record: {body}");

        match SupervisorLease::try_acquire(addr, &record, "/repos/x", SupervisorKind::Emacs) {
            Err(AcquireError::OwnedBy(SupervisorKind::Tui)) => {}
            other => panic!("a second acquisition must be refused, got {other:?}"),
        }

        drop(held);
        assert!(!record.exists(), "dropping the lease removes its own record");
        acquire_once_free(addr, &record, "/repos/x", SupervisorKind::Emacs);
    }

    /// The one test that proves the two implementations share one lease, and that the lease dies
    /// with its owner rather than with its owner's children (cb-kcs.1).
    ///
    /// Not two language-local approximations: a real Emacs binds the listener and writes the
    /// record, this Rust process is refused and told exactly who holds it, and then the Emacs is
    /// killed WITHOUT a chance to clean up and the lease is free on the next call. That last step
    /// is the whole argument for a bound socket over a pid file: nobody had to decide the owner
    /// had died, and there was no window in which a live owner looked dead.
    ///
    /// The child chooses its own port and reports it, so there is no gap between finding a free
    /// port and holding it - the flake this file already paid for once.
    ///
    /// CI installs Emacs in the Rust job for exactly this test; a machine without Emacs cannot
    /// run it, and the assertion is skipped there rather than failing for the wrong reason.
    #[test]
    fn emacs_and_tui_share_one_crash_released_lease() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        let identity = "/repos/shared-checkout";

        // Bind on port 0, then report the port through a FILE rather than through stdout:
        // Emacs's batch stdout is buffered, so a `princ` before a `sleep-for` arrives two minutes
        // late - which is exactly how long the first version of this test took to fail.
        let port_file = dir.path().join("port");
        let session_file = dir.path().join("session-pid");
        // The session is started BY the owner, AFTER it binds - the only arrangement that
        // exercises the trap. Over a PIPE rather than Emacs's default pty: when the owner is
        // killed the pty master closes and the child takes a SIGHUP with it, which would end the
        // session this test needs to outlive its parent. `fork` duplicates every descriptor, so this child holds a copy of
        // the listener until its own exec; a sibling spawned by THIS process would prove nothing,
        // because this process never held that listener to begin with.
        let program = format!(
            "(let ((p (make-network-process :name \"held\" :family 'ipv4 :host \"127.0.0.1\" \
             :service 0 :server t :noquery t :reuseaddr nil))) \
             (with-temp-file {record} \
               (insert (format \"{{\\\"identity\\\":%S,\\\"owner\\\":\\\"emacs\\\",\\\"pid\\\":%d}}\" {identity} (emacs-pid)))) \
             (let* ((process-connection-type nil) \
                    (session (start-process \"session\" nil \"sleep\" \"120\"))) \
               (set-process-query-on-exit-flag session nil) \
               (with-temp-file {session_file} (insert (format \"%d\" (process-id session))))) \
             (with-temp-file {port_file} (insert (format \"%d\" (process-contact p :service)))) \
             (sleep-for 120))",
            record = format!("{:?}", record.display().to_string()),
            identity = format!("{identity:?}"),
            session_file = format!("{:?}", session_file.display().to_string()),
            port_file = format!("{:?}", port_file.display().to_string()),
        );

        let Some(child) = probe::RealEmacs::batch(
            "the only cross-implementation lock proof",
            None,
            &program,
        ) else {
            return;
        };

        // The port file appears only once the listener is bound and the record written.
        let port = probe::wait_for(std::time::Duration::from_secs(20), || {
            std::fs::read_to_string(&port_file).ok()?.trim().parse::<u16>().ok()
        })
        .expect("the Emacs owner never reported a bound port");
        let addr = endpoint(port);

        // Refused, and told who holds it - across two languages, one record, one port.
        let refused = SupervisorLease::try_acquire(addr, &record, identity, SupervisorKind::Tui);
        let outcome = match refused {
            Err(AcquireError::OwnedBy(kind)) => Ok(kind),
            other => Err(format!("{other:?}")),
        };

        // A LIVE CHILD BEHIND THE OWNER, which is the trap the plan names by hand: `fork`
        // duplicates every descriptor, so a session the owning view spawns would keep the
        // listener bound after the supervisor itself is gone - and the replacement would then
        // find a bound port with a stale record, i.e. a lock error for as long as that session
        // lives, on a checkout with no supervisor at all. `TcpListener` is opened `O_CLOEXEC`, so
        // the child drops it at exec and the lease dies with its owner and not with its children.
        // This assertion is what keeps that true when cb-kcs.2 gives the view real sessions.
        let session_pid: i32 = std::fs::read_to_string(&session_file)
            .expect("the owner reported the session it started")
            .trim()
            .parse()
            .expect("a pid");

        // The owner dies without cleaning up. Its session does not: a SIGKILLed Emacs orphans its
        // children rather than taking them with it. `Drop` kills and reaps.
        drop(child);
        assert!(
            alive(session_pid),
            "the owner's session must outlive it, or this proves nothing about inherited \
             descriptors"
        );

        assert_eq!(outcome, Ok(SupervisorKind::Emacs), "Rust must see the Emacs owner");

        // And the lease is free at once, with the crashed owner's record still on disk.
        assert!(record.exists(), "the crashed owner left its record behind");
        // The kernel closes the listener as the process is reaped; on a loaded runner that is
        // milliseconds after `wait` returns, not before it.
        let _taken = acquire_once_free(addr, &record, identity, SupervisorKind::Tui);
        // Still running: the lease came back while a session the dead owner had forked was alive,
        // which is exactly what close-on-exec buys and what cb-kcs.2 will depend on.
        assert!(alive(session_pid), "the orphaned session was still supposed to be running");
        let _ = std::process::Command::new("kill").arg(session_pid.to_string()).status();
        assert_eq!(
            read_record(&record).expect("record").owner,
            Some(SupervisorKind::Tui),
            "the successful bind overwrote the stale record"
        );
    }

    /// Is this pid still running? `kill -0`, which needs no crate and no unsafe block.
    fn alive(pid: i32) -> bool {
        std::process::Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }

    #[test]
    fn a_record_from_another_checkout_is_a_collision_not_a_takeover() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        let (_held, addr) =
            acquire_on_a_free_port(&record, "/repos/other", SupervisorKind::Emacs);

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
        // Somebody else's listener, with nothing of ours behind it.
        let (_foreign, addr) = foreign_listener();

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
        let (_foreign, addr) = foreign_listener();

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

        let (_held, _addr) = acquire_on_a_free_port(&record, "/repos/x", SupervisorKind::Tui);
        let body = std::fs::read_to_string(&record).expect("record");
        assert!(body.contains("\"owner\":\"tui\""), "record: {body}");
    }

    #[test]
    fn an_identity_round_trips_through_the_record() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("supervisor.json");
        let weird = "/repos/with \"quotes\" and \\ backslash";
        let (_held, _addr) = acquire_on_a_free_port(&record, weird, SupervisorKind::Emacs);
        let fields = read_record(&record).expect("record parses");
        assert_eq!(fields.identity, weird);
        assert_eq!(fields.owner, Some(SupervisorKind::Emacs));
    }
}
