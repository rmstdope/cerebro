//! The Edge half of `supervisor.rs` (cb-92g0): the supervision lease itself, which binds real
//! loopback sockets and writes `supervisor.json` under a temp dir. `.cerebro/test-architecture.md`
//! keeps sockets, files and the real clock out of the Unit level and names the lease listener at
//! the Edge, so the unit module holds only the ownership rule and these run here, once, against
//! the crate's public surface.
//!
//! Every bind of a probed address is retried within `probe::POLL_BOUND` (`.cerebro/traps.md`, "A
//! port a probe just released is not a port you can bind"): a lost race is setup noise, never the
//! thing under assertion.

use std::net::{Ipv4Addr, SocketAddr, TcpListener};
use std::path::Path;

use cerebro_tui::probe;
use cerebro_tui::supervisor::{AcquireError, SupervisorLease};

/// A held lease, on whatever loopback port was actually free. A lost race here is setup
/// noise, never the thing under assertion, so it simply tries the next port.
fn acquire_on_a_free_port(record: &Path, identity: &str) -> (SupervisorLease, SocketAddr) {
    probe::wait_for(probe::POLL_BOUND, || {
        let addr = probe::free_endpoint();
        SupervisorLease::try_acquire(addr, record, identity)
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
/// NEXT attempt, which is why the view retries on its own tick rather than treating one refusal
/// as final. `probe::POLL_BOUND` is the wall clock the case gets, not an attempt budget.
fn acquire_once_free(addr: SocketAddr, record: &Path, identity: &str) -> SupervisorLease {
    let mut last = None;
    let lease = probe::wait_for(probe::POLL_BOUND, || {
        match SupervisorLease::try_acquire(addr, record, identity) {
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
    let (held, addr) = acquire_on_a_free_port(&record, "/repos/x");
    let body = std::fs::read_to_string(&record).expect("the record exists");
    assert!(body.contains("\"identity\":\"/repos/x\""), "record: {body}");

    match SupervisorLease::try_acquire(addr, &record, "/repos/x") {
        Err(AcquireError::OwnedBy) => {}
        other => panic!("a second acquisition must be refused, got {other:?}"),
    }

    drop(held);
    assert!(!record.exists(), "dropping the lease removes its own record");
    acquire_once_free(addr, &record, "/repos/x");
}

#[test]
fn a_record_from_another_checkout_is_a_collision_not_a_takeover() {
    let dir = tempfile::tempdir().expect("tempdir");
    let record = dir.path().join("supervisor.json");
    let (_held, addr) = acquire_on_a_free_port(&record, "/repos/other");

    match SupervisorLease::try_acquire(addr, &record, "/repos/mine") {
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

    match SupervisorLease::try_acquire(addr, &record, "/repos/x") {
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

    match SupervisorLease::try_acquire(addr, &record, "/repos/x") {
        Err(AcquireError::LockError(_)) => {}
        other => panic!("a malformed record must be a lock error, got {other:?}"),
    }
}

#[test]
fn a_stale_record_is_overwritten_by_a_successful_bind() {
    let dir = tempfile::tempdir().expect("tempdir");
    let record = dir.path().join("supervisor.json");
    // What a crashed owner leaves behind: a record, and no listener.
    std::fs::write(&record, "{\"identity\":\"/repos/stale\",\"pid\":1}\n").expect("write");

    let (_held, _addr) = acquire_on_a_free_port(&record, "/repos/x");
    let body = std::fs::read_to_string(&record).expect("record");
    assert!(body.contains("\"identity\":\"/repos/x\""), "record: {body}");
}

/// The identity written into the record is the identity read back out of it. The record's
/// reader is private, so the read-back is the one a second checkout's acquisition does: the
/// collision it reports carries the identity parsed from the file.
#[test]
fn an_identity_round_trips_through_the_record() {
    let dir = tempfile::tempdir().expect("tempdir");
    let record = dir.path().join("supervisor.json");
    let weird = "/repos/with \"quotes\" and \\ backslash";
    let (_held, addr) = acquire_on_a_free_port(&record, weird);

    match SupervisorLease::try_acquire(addr, &record, "/repos/somebody-else") {
        Err(AcquireError::EndpointCollision { identity }) => assert_eq!(identity, weird),
        other => panic!("the record must name the holder, got {other:?}"),
    }
}
