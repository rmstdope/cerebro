use axum::{
    body::{to_bytes, Body},
    http::{Method, Request, StatusCode},
};
use cerebro_tui::{Programs, ReaderPaths, RealCommands, SupervisionMode};
use cerebro_web::{ReadOnlyService, ServiceError};
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
    assert_eq!(
        to_bytes(response.into_body(), usize::MAX).await.unwrap(),
        r#"{"state":"fresh","value":{"claimed":[],"planned":[],"being_planned":[],"ux_agreed":[],"unplanned":[],"paused":[],"merged":[],"linked":[],"assignable":[],"implementer_assignable":[],"bugfixable":[],"second_look":[],"candidates":{}}}"#
    );

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
    assert!(body.starts_with(r#"{"state":"stale","value":{"claimed":[],"planned":[],"being_planned":[],"ux_agreed":[],"unplanned":[],"paused":[],"merged":[],"linked":[],"assignable":[],"implementer_assignable":[],"bugfixable":[],"second_look":[],"candidates":{}},"error":"could not run "#));
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
