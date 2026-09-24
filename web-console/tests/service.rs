use axum::{
    body::{to_bytes, Body},
    http::{Method, Request, StatusCode},
};
use cerebro_tui::{Programs, ReaderPaths, RealCommands, SupervisionMode};
use cerebro_web::{ReadOnlyService, ServiceError};
use http_body_util::BodyExt;
use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tower::ServiceExt;

fn service(assets_dir: PathBuf) -> ReadOnlyService {
    service_with_commands(assets_dir, Arc::new(RealCommands))
}

fn service_with_commands(
    assets_dir: PathBuf,
    commands: Arc<dyn cerebro_tui::CommandRunner>,
) -> ReadOnlyService {
    ReadOnlyService::new(
        ReaderPaths {
            consumer_root: PathBuf::from("/consumer"),
            shared_root: PathBuf::from("/shared"),
            scripts_dir: PathBuf::from("/scripts"),
        },
        Programs::default(),
        commands,
        SupervisionMode::Supervising,
        assets_dir,
    )
}

struct ToggleCommands {
    fails: AtomicBool,
}

impl ToggleCommands {
    fn fail(&self) {
        self.fails.store(true, Ordering::SeqCst);
    }

    fn recover(&self) {
        self.fails.store(false, Ordering::SeqCst);
    }
}

impl cerebro_tui::CommandRunner for ToggleCommands {
    fn run(
        &self,
        program: &std::path::Path,
        args: &[&str],
        _cwd: Option<&std::path::Path>,
        _timeout: Duration,
    ) -> Result<Vec<u8>, cerebro_tui::ReadError> {
        if self.fails.load(Ordering::SeqCst) {
            return Err(cerebro_tui::ReadError::Spawn {
                source: cerebro_tui::Invocation::new(program, args),
                message: "reader unavailable".to_string(),
            });
        }
        if program
            .file_name()
            .is_some_and(|name| name == "second-look-beads")
        {
            return Ok(Vec::new());
        }
        if program.file_name().is_some_and(|name| name == "roster") {
            return Ok(b"Storm\tproducer\tinteractive\n".to_vec());
        }
        if program == std::path::Path::new("ps") {
            return Ok(Vec::new());
        }
        if program
            .file_name()
            .is_some_and(|name| name == "fleet-health")
        {
            return Ok(b"{\"since\":\"\",\"until\":\"\"}".to_vec());
        }
        Ok(b"[]".to_vec())
    }
}

#[tokio::test]
async fn health_is_available_only_through_a_read_request() {
    let response = service(PathBuf::from("/assets"))
        .router()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let response = service(PathBuf::from("/assets"))
        .router()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn event_stream_is_available_only_through_a_read_request() {
    let response = service(PathBuf::from("/assets"))
        .router()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/events")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers().get("content-type").unwrap(),
        "text/event-stream"
    );

    let response = service(PathBuf::from("/assets"))
        .router()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/events")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
}

#[tokio::test]
async fn event_stream_emits_a_named_event_when_a_snapshot_changes() {
    let commands = Arc::new(ToggleCommands {
        fails: AtomicBool::new(false),
    });
    let response = service_with_commands(PathBuf::from("/assets"), commands.clone())
        .router()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/events")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let mut body = response.into_body();
    let baseline = tokio::time::timeout(Duration::from_secs(1), body.frame())
        .await
        .unwrap()
        .unwrap()
        .unwrap()
        .into_data()
        .unwrap();
    assert_eq!(
        std::str::from_utf8(&baseline).unwrap(),
        ": snapshot baseline\n\n"
    );

    commands.fail();
    let event = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let frame = body.frame().await.unwrap().unwrap();
            if let Ok(data) = frame.into_data() {
                let event = String::from_utf8(data.to_vec()).unwrap();
                if event.starts_with("event: ") {
                    return event;
                }
            }
        }
    })
    .await
    .unwrap();

    assert_eq!(event, "event: fleet\ndata: snapshot changed\n\n");
}

#[tokio::test]
async fn work_snapshot_is_available_through_a_read_request() {
    let commands = Arc::new(ToggleCommands {
        fails: AtomicBool::new(false),
    });
    let service = service_with_commands(PathBuf::from("/assets"), commands.clone());
    let router = service.router();

    let response = router
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/work")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = String::from_utf8(
        to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    assert!(body.starts_with(r#"{"state":"fresh","value":{"claimed":[],"planned":[],"being_planned":[],"ux_agreed":[],"unplanned":[],"paused":[],"merged":[],"linked":[],"assignable":[],"bugfixable":[],"second_look":[],"second_look_beads":[],"candidates":{},"epics":{}},"updated_at":""#));

    commands.fail();
    let response = service
        .router()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/work")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = String::from_utf8(
        to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    assert!(body.starts_with(r#"{"state":"stale","value":{"claimed":[],"planned":[],"being_planned":[],"ux_agreed":[],"unplanned":[],"paused":[],"merged":[],"linked":[],"assignable":[],"bugfixable":[],"second_look":[],"second_look_beads":[],"candidates":{},"epics":{}},"error":"could not run "#));
}

#[tokio::test]
async fn fresh_snapshots_publish_their_update_time() {
    let commands = Arc::new(ToggleCommands {
        fails: AtomicBool::new(false),
    });
    let response = service_with_commands(PathBuf::from("/assets"), commands)
        .router()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/fleet")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = String::from_utf8(
        to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    assert!(body.contains(r#""state":"fresh""#));
    assert!(body.contains(r#""updated_at":""#));
}

#[tokio::test]
async fn failed_initial_snapshots_are_unavailable_not_empty() {
    let commands = Arc::new(ToggleCommands {
        fails: AtomicBool::new(true),
    });

    let router = service_with_commands(PathBuf::from("/assets"), commands).router();
    for path in ["/api/fleet", "/api/work", "/api/health"] {
        let response = router
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(path)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = String::from_utf8(
            to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec(),
        )
        .unwrap();
        assert!(body.starts_with(r#"{"state":"unavailable","error":"could not run "#));
    }
}

#[tokio::test]
async fn fleet_and_health_snapshots_return_typed_fresh_values() {
    let commands = Arc::new(ToggleCommands {
        fails: AtomicBool::new(false),
    });
    let service = service_with_commands(PathBuf::from("/assets"), commands.clone());

    for path in ["/api/fleet", "/api/health"] {
        commands.recover();
        let response = service
            .router()
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(path)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        assert!(
            String::from_utf8(
                to_bytes(response.into_body(), usize::MAX)
                    .await
                    .unwrap()
                    .to_vec()
            )
            .unwrap()
            .starts_with(r#"{"state":"fresh","value":"#),
            "{path} did not return a fresh snapshot"
        );

        commands.fail();
        let response = service
            .router()
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(path)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert!(
            String::from_utf8(
                to_bytes(response.into_body(), usize::MAX)
                    .await
                    .unwrap()
                    .to_vec()
            )
            .unwrap()
            .starts_with(r#"{"state":"stale","value":"#),
            "{path} did not retain its prior snapshot"
        );
    }
}

#[test]
fn public_listener_addresses_are_rejected() {
    let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 7171);

    assert_eq!(
        service(PathBuf::from("/assets")).validate_listener_address(address),
        Err(ServiceError::NonLoopbackAddress(address))
    );
}

#[tokio::test]
async fn browser_paths_fall_back_to_the_application_shell() {
    let assets = tempfile::tempdir().unwrap();
    std::fs::write(assets.path().join("index.html"), "browser shell").unwrap();

    let response = service(assets.path().to_path_buf())
        .router()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/fleet")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        to_bytes(response.into_body(), usize::MAX).await.unwrap(),
        "browser shell"
    );
}

fn service_at(shared_root: &std::path::Path) -> ReadOnlyService {
    ReadOnlyService::new(
        ReaderPaths {
            consumer_root: shared_root.to_path_buf(),
            shared_root: shared_root.to_path_buf(),
            scripts_dir: shared_root.join("scripts"),
        },
        Programs::default(),
        Arc::new(RealCommands),
        SupervisionMode::Supervising,
        PathBuf::from("/assets"),
    )
}

fn publish(root: &std::path::Path, name: &str, age: chrono::Duration, log: &[u8]) -> String {
    let dir = root.join(".cerebro/state/sessions");
    std::fs::create_dir_all(&dir).unwrap();
    let file = format!("{name}.1-0-0.log");
    std::fs::write(dir.join(&file), log).unwrap();
    let publication = cerebro_tui::PublishedSession {
        name: name.to_string(),
        log: file.clone(),
        updated_at: chrono::Utc::now() - age,
        input: None,
    };
    std::fs::write(
        dir.join(format!("{name}.json")),
        serde_json::to_string(&publication).unwrap(),
    )
    .unwrap();
    file
}

async fn session(root: &std::path::Path, path: &str) -> (StatusCode, serde_json::Value) {
    let response = service_at(root)
        .router()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{path}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (
        status,
        serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null),
    )
}

#[tokio::test]
async fn a_published_session_log_is_served_from_the_start() {
    let root = tempfile::tempdir().unwrap();
    let log = publish(
        root.path(),
        "Storm",
        chrono::Duration::zero(),
        b"\x1b[8;12;40thello",
    );

    let (status, body) = session(root.path(), "Storm").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["state"], "live");
    assert_eq!(body["log"], log.as_str());
    assert_eq!(body["reset"], true);
    assert_eq!(body["data"], "\u{1b}[8;12;40thello");
    assert_eq!(body["offset"], 15);
    assert_eq!(body["more"], false);
}

#[tokio::test]
async fn a_reader_that_has_caught_up_gets_only_what_was_appended() {
    let root = tempfile::tempdir().unwrap();
    let log = publish(
        root.path(),
        "Storm",
        chrono::Duration::zero(),
        b"hello world",
    );

    let (_, body) = session(root.path(), &format!("Storm?log={log}&from=6")).await;

    assert_eq!(
        (body["reset"].as_bool(), body["data"].as_str()),
        (Some(false), Some("world"))
    );
    assert_eq!(body["offset"], 11);
}

#[tokio::test]
async fn a_reader_of_a_replaced_log_starts_again() {
    let root = tempfile::tempdir().unwrap();
    publish(root.path(), "Storm", chrono::Duration::zero(), b"fresh");

    let (_, body) = session(root.path(), "Storm?log=Storm.1-0-9.log&from=3").await;

    assert_eq!(
        (body["reset"].as_bool(), body["data"].as_str()),
        (Some(true), Some("fresh"))
    );
}

#[tokio::test]
async fn a_chunk_never_splits_a_character() {
    let root = tempfile::tempdir().unwrap();
    let log = publish(
        root.path(),
        "Storm",
        chrono::Duration::zero(),
        "aä".as_bytes(),
    );

    // Offset 2 is inside `ä`; a well-behaved reader never asks for it, but a truncated log could
    // end there, and the reader is told to stop before it rather than given half a character.
    std::fs::write(
        root.path().join(".cerebro/state/sessions").join(&log),
        &"aä".as_bytes()[..2],
    )
    .unwrap();
    let (_, body) = session(root.path(), &format!("Storm?log={log}&from=0")).await;

    assert_eq!(
        (body["data"].as_str(), body["offset"].as_u64()),
        (Some("a"), Some(1))
    );
}

#[tokio::test]
async fn a_missing_or_abandoned_session_is_absent() {
    let root = tempfile::tempdir().unwrap();
    publish(root.path(), "Rogue", chrono::Duration::seconds(60), b"old");

    assert_eq!(session(root.path(), "Storm").await.1["state"], "absent");
    assert_eq!(session(root.path(), "Rogue").await.1["state"], "absent");
}

#[tokio::test]
async fn a_session_name_cannot_leave_the_sessions_directory() {
    let root = tempfile::tempdir().unwrap();

    let (status, _) = session(root.path(), "..%2Fsecret").await;

    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_publication_naming_a_log_elsewhere_is_refused() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join(".cerebro/state/sessions");
    std::fs::create_dir_all(&dir).unwrap();
    let publication = cerebro_tui::PublishedSession {
        name: "Storm".to_string(),
        log: "../../secret".to_string(),
        updated_at: chrono::Utc::now(),
        input: None,
    };
    std::fs::write(
        dir.join("Storm.json"),
        serde_json::to_string(&publication).unwrap(),
    )
    .unwrap();

    let (status, _) = session(root.path(), "Storm").await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
}

#[tokio::test]
async fn an_unreadable_publication_is_a_failure_not_an_absence() {
    let root = tempfile::tempdir().unwrap();
    let dir = root.path().join(".cerebro/state/sessions");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("Storm.json"), "not json").unwrap();

    let (status, _) = session(root.path(), "Storm").await;

    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
}

/// A reader that takes its time, counting each fleet read by its one `roster` run.
struct SlowCommands {
    rosters: std::sync::atomic::AtomicUsize,
    delay: Duration,
}

impl cerebro_tui::CommandRunner for SlowCommands {
    fn run(
        &self,
        program: &std::path::Path,
        _args: &[&str],
        _cwd: Option<&std::path::Path>,
        _timeout: Duration,
    ) -> Result<Vec<u8>, cerebro_tui::ReadError> {
        if program.file_name().is_some_and(|name| name == "roster") {
            self.rosters.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(self.delay);
            return Ok(b"Storm\tproducer\tinteractive\n".to_vec());
        }
        Ok(if program == std::path::Path::new("ps") { Vec::new() } else { b"[]".to_vec() })
    }
}

fn get(path: &str) -> Request<Body> {
    Request::builder().method(Method::GET).uri(path).body(Body::empty()).unwrap()
}

/// Requests that arrive while a read is running share it, rather than queueing one read each
/// behind it: a queue that grows faster than it drains is a service that never answers.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn requests_during_a_read_share_it() {
    let commands = Arc::new(SlowCommands { rosters: Default::default(), delay: Duration::from_millis(400) });
    let router = service_with_commands(PathBuf::from("/assets"), commands.clone()).router();

    let requests: Vec<_> = (0..6).map(|_| tokio::spawn(router.clone().oneshot(get("/api/fleet")))).collect();
    for request in requests {
        assert_eq!(request.await.unwrap().unwrap().status(), StatusCode::OK);
    }

    assert!(commands.rosters.load(Ordering::SeqCst) <= 2, "{} reads", commands.rosters.load(Ordering::SeqCst));
}

/// A read runs off the async workers, so a slow `bd` holds up nothing but the requests that need it.
#[tokio::test]
async fn a_slow_read_does_not_hold_up_other_requests() {
    let commands = Arc::new(SlowCommands { rosters: Default::default(), delay: Duration::from_millis(1500) });
    let router = service_with_commands(PathBuf::from("/assets"), commands.clone()).router();
    let start = std::time::Instant::now();

    // One thread: a read that blocks it holds up everything else until it is done.
    let (slow, other) = tokio::join!(router.clone().oneshot(get("/api/fleet")), async {
        tokio::time::sleep(Duration::from_millis(100)).await;
        router.clone().oneshot(get("/api/sessions/Storm")).await.unwrap();
        start.elapsed()
    });

    assert!(other < Duration::from_millis(1000), "a session request waited {other:?} behind a fleet read");
    assert_eq!(slow.unwrap().status(), StatusCode::OK);
}

/// However many pages are open, their event streams read the fleet about once an interval between
/// them, not once an interval each.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn event_streams_share_their_reads() {
    let commands = Arc::new(SlowCommands { rosters: Default::default(), delay: Duration::from_millis(50) });
    let router = service_with_commands(PathBuf::from("/assets"), commands.clone()).router();
    let mut bodies = Vec::new();
    for _ in 0..5 {
        bodies.push(router.clone().oneshot(get("/api/events")).await.unwrap().into_body());
    }
    let drain = bodies.into_iter().map(|mut body| tokio::spawn(async move {
        while let Some(Ok(_)) = body.frame().await {}
    })).collect::<Vec<_>>();

    tokio::time::sleep(Duration::from_millis(4500)).await;
    for task in drain {
        task.abort();
    }

    // Three ticks (0 s, 2 s, 4 s), and some slack for streams that tick apart.
    assert!(commands.rosters.load(Ordering::SeqCst) <= 6, "{} reads", commands.rosters.load(Ordering::SeqCst));
}

/// A roster with two agents and no processes, so a plain derivation calls both dead.
struct TwoDeadCommands;

impl cerebro_tui::CommandRunner for TwoDeadCommands {
    fn run(
        &self,
        program: &std::path::Path,
        _args: &[&str],
        _cwd: Option<&std::path::Path>,
        _timeout: Duration,
    ) -> Result<Vec<u8>, cerebro_tui::ReadError> {
        if program.file_name().is_some_and(|name| name == "roster") {
            return Ok(b"Storm\tproducer\tinteractive\nMoira\tuser-feedback\tinteractive\n".to_vec());
        }
        Ok(if program == std::path::Path::new("ps") { Vec::new() } else { b"[]".to_vec() })
    }
}

async fn fleet_states(root: &std::path::Path) -> Vec<(String, String)> {
    let service = ReadOnlyService::new(
        ReaderPaths {
            consumer_root: root.to_path_buf(),
            shared_root: root.to_path_buf(),
            scripts_dir: root.join("scripts"),
        },
        Programs::default(),
        Arc::new(TwoDeadCommands),
        SupervisionMode::Supervising,
        PathBuf::from("/assets"),
    );
    let response = service.router().oneshot(get("/api/fleet")).await.unwrap();
    let body: serde_json::Value =
        serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap()).unwrap();
    body["value"]
        .as_array()
        .unwrap_or_else(|| panic!("not a fresh fleet: {body}"))
        .iter()
        .map(|row| (row["name"].as_str().unwrap().to_string(), row["state"].as_str().unwrap().to_string()))
        .collect()
}

fn publish_standby(root: &std::path::Path, names: &[&str], age: chrono::Duration) {
    publish_standby_with(root, names, None, age);
}

fn publish_standby_with(
    root: &std::path::Path,
    names: &[&str],
    socket: Option<&std::path::Path>,
    age: chrono::Duration,
) {
    let publication = cerebro_tui::PublishedStandby {
        names: names.iter().map(|name| name.to_string()).collect(),
        control: socket.map(|socket| socket.to_string_lossy().into_owned()),
        handed: Default::default(),
        updated_at: chrono::Utc::now() - age,
    };
    std::fs::create_dir_all(root.join(".cerebro/state")).unwrap();
    std::fs::write(root.join(".cerebro/state/standby.json"), serde_json::to_string(&publication).unwrap()).unwrap();
}

fn states(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(name, state)| (name.to_string(), state.to_string())).collect()
}

/// Standby is what the supervising fleet view says it is - its armed set, which a kill, a
/// give-up or a manual start changes - not what the roster declared.
#[tokio::test]
async fn a_dead_agent_the_fleet_view_holds_on_standby_is_reported_standby() {
    let root = tempfile::tempdir().unwrap();
    publish_standby(root.path(), &["Moira"], chrono::Duration::zero());

    assert_eq!(fleet_states(root.path()).await, states(&[("Storm", "Dead"), ("Moira", "Standby")]));
}

#[tokio::test]
async fn without_a_live_fleet_view_nobody_is_on_standby() {
    let root = tempfile::tempdir().unwrap();
    assert_eq!(fleet_states(root.path()).await, states(&[("Storm", "Dead"), ("Moira", "Dead")]));

    publish_standby(root.path(), &["Moira"], chrono::Duration::seconds(60));
    assert_eq!(fleet_states(root.path()).await, states(&[("Storm", "Dead"), ("Moira", "Dead")]));

    // A view that died without tidying: its socket file is left, and nothing answers on it.
    let socket = root.path().join("control.sock");
    drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
    publish_standby_with(root.path(), &["Moira"], Some(&socket), chrono::Duration::seconds(60));
    assert_eq!(fleet_states(root.path()).await, states(&[("Storm", "Dead"), ("Moira", "Dead")]));
}

/// A bead the fleet view has handed an agent is shown as the TUI shows it: a dead row it was
/// handed is starting, and a row with no bead of its own names the handed one.
#[tokio::test]
async fn a_bead_the_fleet_view_handed_is_shown_until_the_state_file_names_one() {
    let root = tempfile::tempdir().unwrap();
    let publication = cerebro_tui::PublishedStandby {
        names: ["Moira".to_string()].into_iter().collect(),
        control: None,
        handed: [("Storm".to_string(), "cb-njw".to_string())].into_iter().collect(),
        updated_at: chrono::Utc::now(),
    };
    std::fs::create_dir_all(root.path().join(".cerebro/state")).unwrap();
    std::fs::write(root.path().join(".cerebro/state/standby.json"), serde_json::to_string(&publication).unwrap()).unwrap();

    let service = ReadOnlyService::new(
        ReaderPaths {
            consumer_root: root.path().to_path_buf(),
            shared_root: root.path().to_path_buf(),
            scripts_dir: root.path().join("scripts"),
        },
        Programs::default(),
        Arc::new(TwoDeadCommands),
        SupervisionMode::Supervising,
        PathBuf::from("/assets"),
    );
    let response = service.router().oneshot(get("/api/fleet")).await.unwrap();
    let body: serde_json::Value =
        serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap()).unwrap();
    let rows: Vec<(String, String, serde_json::Value)> = body["value"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| (row["name"].as_str().unwrap().into(), row["state"].as_str().unwrap().into(), row["bead"].clone()))
        .collect();

    assert_eq!(
        rows,
        vec![
            ("Storm".into(), "Starting".into(), serde_json::json!("cb-njw")),
            ("Moira".into(), "Standby".into(), serde_json::Value::Null),
        ]
    );
}

/// A launch or a reap can hold the fleet view's loop for longer than the publication stays fresh.
/// Its control socket is served on a thread of its own and closed the moment the view stops
/// supervising, so a socket that still answers is a view that is alive and only held up.
#[tokio::test]
async fn a_fleet_view_held_up_past_its_refresh_still_holds_its_standby_agents() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("control.sock");
    let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    publish_standby_with(root.path(), &["Moira"], Some(&socket), chrono::Duration::seconds(60));

    assert_eq!(fleet_states(root.path()).await, states(&[("Storm", "Dead"), ("Moira", "Standby")]));
}

/// A live session whose publication says where to type, and the listener standing in for it.
fn publish_with_inbox(root: &std::path::Path, name: &str) -> std::os::unix::net::UnixListener {
    let dir = root.join(".cerebro/state/sessions");
    std::fs::create_dir_all(&dir).unwrap();
    let socket = root.join("in.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let publication = cerebro_tui::PublishedSession {
        name: name.to_string(),
        log: format!("{name}.1-0-0.log"),
        updated_at: chrono::Utc::now(),
        input: Some(socket.to_string_lossy().into_owned()),
    };
    std::fs::write(dir.join(format!("{name}.json")), serde_json::to_string(&publication).unwrap()).unwrap();
    listener
}

fn typing(name: &str, headers: &[(&str, &str)], body: &'static [u8]) -> Request<Body> {
    let mut request = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/sessions/{name}/input"))
        .header("host", "127.0.0.1:7171")
        .header("content-type", "application/octet-stream")
        .header("x-cerebro-input", "1");
    for (key, value) in headers {
        request = request.header(*key, *value);
    }
    request.body(Body::from(body)).unwrap()
}

async fn type_into(root: &std::path::Path, request: Request<Body>) -> StatusCode {
    service_at(root).router().oneshot(request).await.unwrap().status()
}

/// The stand-in inbox, answering each message it reads with TAKEN.
fn answering(listener: std::os::unix::net::UnixListener, taken: u8) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        use std::io::Write as _;
        let (mut stream, _) = listener.accept().unwrap();
        let message = cerebro_tui::inbox::message(&mut stream).unwrap();
        stream.write_all(&[taken]).unwrap();
        message
    })
}

#[tokio::test]
async fn what_the_browser_types_reaches_the_session() {
    let root = tempfile::tempdir().unwrap();
    let inbox = answering(publish_with_inbox(root.path(), "Storm"), 1);

    let status = type_into(root.path(), typing("Storm", &[("origin", "http://localhost:5173")], b"hello\r")).await;

    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(inbox.join().unwrap(), b"hello\r");
}

#[tokio::test]
async fn typing_a_session_refuses_is_a_failure() {
    let root = tempfile::tempdir().unwrap();
    let inbox = answering(publish_with_inbox(root.path(), "Storm"), 0);

    let status = type_into(root.path(), typing("Storm", &[], b"hello\r")).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    inbox.join().unwrap();
}

#[tokio::test]
async fn only_this_console_may_type() {
    let root = tempfile::tempdir().unwrap();
    let listener = publish_with_inbox(root.path(), "Storm");
    listener.set_nonblocking(true).unwrap();
    let forged = |headers: &[(&str, &str)]| {
        let mut request = typing("Storm", headers, b"rm -rf /\r");
        if headers.iter().any(|(key, _)| *key == "drop") {
            request.headers_mut().remove("x-cerebro-input");
        }
        request
    };

    // A form or a simple fetch from another site cannot set the header without asking first.
    assert_eq!(type_into(root.path(), forged(&[("drop", "")])).await, StatusCode::FORBIDDEN);
    assert_eq!(type_into(root.path(), forged(&[("origin", "https://evil.example")])).await, StatusCode::FORBIDDEN);
    // A name that resolves here but was not asked for here.
    let mut rebound = forged(&[]);
    rebound.headers_mut().insert("host", "evil.example:7171".parse().unwrap());
    assert_eq!(type_into(root.path(), rebound).await, StatusCode::FORBIDDEN);

    assert!(listener.accept().is_err(), "nothing reached the session");
}

#[tokio::test]
async fn a_session_nobody_hosts_cannot_be_typed_into() {
    let root = tempfile::tempdir().unwrap();
    assert_eq!(type_into(root.path(), typing("Storm", &[], b"x")).await, StatusCode::NOT_FOUND);
    publish(root.path(), "Rogue", chrono::Duration::zero(), b"");
    assert_eq!(type_into(root.path(), typing("Rogue", &[], b"x")).await, StatusCode::NOT_FOUND);
    publish(root.path(), "Old", chrono::Duration::seconds(60), b"");
    assert_eq!(type_into(root.path(), typing("Old", &[], b"x")).await, StatusCode::NOT_FOUND);
    assert_eq!(type_into(root.path(), typing("..", &[], b"x")).await, StatusCode::BAD_REQUEST);
}

/// A supervising fleet view's publication, naming SOCKET as its control socket.
fn publish_control(root: &std::path::Path, socket: Option<&std::path::Path>, age: chrono::Duration) {
    let publication = cerebro_tui::PublishedStandby {
        names: Default::default(),
        control: socket.map(|socket| socket.to_string_lossy().into_owned()),
        handed: Default::default(),
        updated_at: chrono::Utc::now() - age,
    };
    std::fs::create_dir_all(root.join(".cerebro/state")).unwrap();
    std::fs::write(root.join(".cerebro/state/standby.json"), serde_json::to_string(&publication).unwrap()).unwrap();
}

fn acting(name: &str, action: &str, headers: &[(&str, &str)]) -> Request<Body> {
    let mut request = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/agents/{name}/{action}"))
        .header("host", "localhost:5173")
        .header("x-cerebro-input", "1");
    for (key, value) in headers {
        request = request.header(*key, *value);
    }
    request.body(Body::empty()).unwrap()
}

async fn act(root: &std::path::Path, request: Request<Body>) -> (StatusCode, serde_json::Value) {
    let response = service_at(root).router().oneshot(request).await.unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (status, serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null))
}

#[tokio::test]
async fn an_action_is_done_by_the_supervising_fleet_view_and_its_answer_returned() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("control.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    publish_control(root.path(), Some(&socket), chrono::Duration::zero());
    let view = std::thread::spawn(move || {
        use std::io::Write as _;
        let (mut stream, _) = listener.accept().unwrap();
        let asked = cerebro_tui::inbox::message(&mut stream).unwrap();
        let reply = cerebro_tui::control::Reply::done("Storm was killed.");
        stream.write_all(&cerebro_tui::inbox::framed(&serde_json::to_vec(&reply).unwrap())).unwrap();
        serde_json::from_slice::<cerebro_tui::control::Request>(&asked).unwrap()
    });

    let (status, body) = act(root.path(), acting("Storm", "kill", &[("origin", "http://localhost:5173")])).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, serde_json::json!({"done": true, "text": "Storm was killed."}));
    assert_eq!(
        view.join().unwrap(),
        cerebro_tui::control::Request { name: "Storm".into(), action: cerebro_tui::control::Action::Kill }
    );
}

#[tokio::test]
async fn with_no_supervising_fleet_view_nothing_is_done() {
    let root = tempfile::tempdir().unwrap();
    let (status, body) = act(root.path(), acting("Storm", "start", &[])).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["done"], false);

    // A view that stopped refreshing and left a socket nobody answers, or one that is read-only
    // and names no socket.
    let socket = root.path().join("control.sock");
    drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
    publish_control(root.path(), Some(&socket), chrono::Duration::seconds(60));
    assert_eq!(act(root.path(), acting("Storm", "start", &[])).await.0, StatusCode::SERVICE_UNAVAILABLE);
    publish_control(root.path(), None, chrono::Duration::zero());
    assert_eq!(act(root.path(), acting("Storm", "start", &[])).await.0, StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn only_this_console_may_act_and_only_as_it_knows_how() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("control.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    publish_control(root.path(), Some(&socket), chrono::Duration::zero());

    let cross_site = act(root.path(), acting("Storm", "kill", &[("origin", "https://evil.example")])).await.0;
    let mut unmarked = acting("Storm", "kill", &[]);
    unmarked.headers_mut().remove("x-cerebro-input");
    let unmarked = act(root.path(), unmarked).await.0;
    let unknown = act(root.path(), acting("Storm", "explode", &[])).await.0;
    let dotted = act(root.path(), acting("..", "kill", &[])).await.0;

    assert_eq!(cross_site, StatusCode::FORBIDDEN);
    assert_eq!(unmarked, StatusCode::FORBIDDEN);
    assert_eq!(unknown, StatusCode::NOT_FOUND);
    assert_eq!(dotted, StatusCode::BAD_REQUEST);
    assert!(listener.accept().is_err(), "nothing reached the fleet view");
}

#[tokio::test]
async fn the_console_says_whether_a_fleet_view_takes_its_actions() {
    let root = tempfile::tempdir().unwrap();
    let supervised = |root: std::path::PathBuf| async move {
        let response = service_at(&root).router().oneshot(get("/api/control")).await.unwrap();
        let body: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap()).unwrap();
        body["supervised"].as_bool().unwrap()
    };

    assert!(!supervised(root.path().to_path_buf()).await);
    publish_control(root.path(), Some(&root.path().join("control.sock")), chrono::Duration::zero());
    assert!(supervised(root.path().to_path_buf()).await);
    publish_control(root.path(), Some(&root.path().join("control.sock")), chrono::Duration::seconds(60));
    assert!(!supervised(root.path().to_path_buf()).await);
}

#[tokio::test]
async fn a_publication_that_cannot_be_read_is_a_fault_not_an_unsupervised_checkout() {
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(root.path().join(".cerebro/state")).unwrap();
    std::fs::write(root.path().join(".cerebro/state/standby.json"), "{ not json").unwrap();

    let response = service_at(root.path()).router().oneshot(get("/api/control")).await.unwrap();
    let body: serde_json::Value =
        serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap()).unwrap();
    let (status, acted) = act(root.path(), acting("Storm", "start", &[])).await;

    assert!(body["error"].is_string(), "{body}");
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert!(acted["text"].as_str().unwrap().starts_with("Couldn’t read"), "{acted}");
}

#[tokio::test]
async fn an_agent_whose_stop_flag_is_set_is_reported_finishing() {
    let root = tempfile::tempdir().unwrap();
    let paths = ReaderPaths {
        consumer_root: root.path().to_path_buf(),
        shared_root: root.path().to_path_buf(),
        scripts_dir: root.path().join("scripts"),
    };
    cerebro_tui::lifecycle::write_stop_flag(&paths, "Storm").unwrap();
    let service = ReadOnlyService::new(
        paths,
        Programs::default(),
        Arc::new(TwoDeadCommands),
        SupervisionMode::Supervising,
        PathBuf::from("/assets"),
    );

    let response = service.router().oneshot(get("/api/fleet")).await.unwrap();
    let body: serde_json::Value =
        serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap()).unwrap();

    let finishing: Vec<(String, bool)> = body["value"]
        .as_array()
        .unwrap_or_else(|| panic!("not a fresh fleet: {body}"))
        .iter()
        .map(|row| (row["name"].as_str().unwrap().to_string(), row["finishing"].as_bool().unwrap_or(false)))
        .collect();
    assert_eq!(finishing, vec![("Storm".to_string(), true), ("Moira".to_string(), false)]);
}

struct BeadShow;

impl cerebro_tui::CommandRunner for BeadShow {
    fn run(
        &self,
        program: &std::path::Path,
        args: &[&str],
        _cwd: Option<&std::path::Path>,
        _timeout: Duration,
    ) -> Result<Vec<u8>, cerebro_tui::ReadError> {
        match args {
            [.., "show", "cb-7.1", "--json"] => {
                Ok(br#"[{"id":"cb-7.1","notes":"all of it","dependencies":[{"id":"cb-7"}]}]"#.to_vec())
            }
            _ => Err(cerebro_tui::ReadError::Spawn {
                source: cerebro_tui::Invocation::new(program, args),
                message: "no such bead".to_string(),
            }),
        }
    }
}

async fn bead(path: &str) -> (StatusCode, serde_json::Value) {
    let router = service_with_commands(PathBuf::from("/assets"), Arc::new(BeadShow)).router();
    let response = router.oneshot(get(path)).await.unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (status, serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null))
}

#[tokio::test]
async fn a_bead_is_served_whole() {
    let (status, body) = bead("/api/beads/cb-7.1").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["notes"], "all of it");
    assert_eq!(body["dependencies"][0]["id"], "cb-7");
}

#[tokio::test]
async fn a_bead_that_cannot_be_read_is_a_failure_with_its_reason() {
    let (status, body) = bead("/api/beads/cb-nope").await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert!(body["error"].as_str().unwrap().contains("no such bead"), "{body}");
}

#[tokio::test]
async fn a_bead_id_is_a_plain_name() {
    for path in ["/api/beads/.hidden", "/api/beads/-rf", "/api/beads/a%20b"] {
        assert_eq!(bead(path).await.0, StatusCode::BAD_REQUEST, "{path}");
    }
}

/// A `bd` that records what it was asked and answers each call in turn from ANSWERS.
struct Board {
    calls: std::sync::Mutex<Vec<String>>,
    answers: std::sync::Mutex<Vec<bool>>,
}

impl Board {
    fn new(answers: &[bool]) -> Arc<Self> {
        Arc::new(Self { calls: Default::default(), answers: std::sync::Mutex::new(answers.iter().rev().copied().collect()) })
    }
    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

impl cerebro_tui::CommandRunner for Board {
    fn run(
        &self,
        program: &std::path::Path,
        args: &[&str],
        cwd: Option<&std::path::Path>,
        _timeout: Duration,
    ) -> Result<Vec<u8>, cerebro_tui::ReadError> {
        assert_eq!(cwd, Some(std::path::Path::new("/shared")));
        self.calls.lock().unwrap().push(args.join(" "));
        if self.answers.lock().unwrap().pop().unwrap_or(true) {
            Ok(Vec::new())
        } else {
            Err(cerebro_tui::ReadError::Exit { source: cerebro_tui::Invocation::new(program, args), status: Some(1), stderr: "refused".into() })
        }
    }
}

fn ranking(id: &str, body: &str, headers: &[(&str, &str)]) -> Request<Body> {
    let mut request = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/beads/{id}/priority"))
        .header("host", "localhost:5173")
        .header("content-type", "application/json");
    for (key, value) in headers {
        request = request.header(*key, *value);
    }
    request.body(Body::from(body.to_string())).unwrap()
}

async fn rank(board: &Arc<Board>, request: Request<Body>) -> (StatusCode, serde_json::Value) {
    let router = service_with_commands(PathBuf::from("/assets"), board.clone()).router();
    let response = router.oneshot(request).await.unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    (status, serde_json::from_slice(&body).unwrap_or(serde_json::Value::Null))
}

const OURS: &[(&str, &str)] = &[("x-cerebro-input", "1")];

#[tokio::test]
async fn a_priority_is_written_and_pushed_as_the_fleet_view_writes_it() {
    let board = Board::new(&[]);
    let (status, body) = rank(&board, ranking("cb-7.1", r#"{"to":0,"from":2}"#, OURS)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, serde_json::json!({"done": true, "text": "cb-7.1: P2 → P0"}));
    assert_eq!(board.calls(), vec!["update cb-7.1 --priority 0", "dolt push"]);
}

#[tokio::test]
async fn a_priority_bd_refuses_is_a_failure_and_one_it_cannot_push_says_so() {
    let refused = Board::new(&[false]);
    let (status, body) = rank(&refused, ranking("cb-7", r#"{"to":1}"#, OURS)).await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(body, serde_json::json!({"done": false, "text": "bd would not set cb-7 to P1"}));
    assert_eq!(refused.calls(), vec!["update cb-7 --priority 1"]);

    let unpushed = Board::new(&[true, false]);
    let (status, body) = rank(&unpushed, ranking("cb-7", r#"{"to":1}"#, OURS)).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["text"].as_str().unwrap().contains("bd dolt push failed"), "{body}");
}

#[tokio::test]
async fn only_this_console_may_rank_a_plain_bead_within_p0_to_p4() {
    for (id, body, headers, status) in [
        ("cb-7", r#"{"to":1}"#, &[][..], StatusCode::FORBIDDEN),
        ("cb-7", r#"{"to":1}"#, &[("x-cerebro-input", "1"), ("origin", "https://evil.example")][..], StatusCode::FORBIDDEN),
        ("-rf", r#"{"to":1}"#, OURS, StatusCode::BAD_REQUEST),
        ("cb-7", r#"{"to":5}"#, OURS, StatusCode::BAD_REQUEST),
    ] {
        let board = Board::new(&[]);
        assert_eq!(rank(&board, ranking(id, body, headers)).await.0, status, "{id} {body} {headers:?}");
        assert!(board.calls().is_empty(), "nothing ran for {id} {body}");
    }
}
