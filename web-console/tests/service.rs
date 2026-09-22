use axum::{
    body::Body,
    http::{Method, Request, StatusCode},
};
use cerebro_tui::{Programs, ReaderPaths, RealCommands, SupervisionMode};
use cerebro_web::{ReadOnlyService, ServiceError};
use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::PathBuf,
    sync::Arc,
};
use tower::ServiceExt;

fn service() -> ReadOnlyService {
    ReadOnlyService::new(
        ReaderPaths {
            consumer_root: PathBuf::from("/consumer"),
            shared_root: PathBuf::from("/shared"),
            scripts_dir: PathBuf::from("/scripts"),
        },
        Programs::default(),
        Arc::new(RealCommands),
        SupervisionMode::Supervising,
        PathBuf::from("/assets"),
    )
}

#[tokio::test]
async fn health_is_available_only_through_a_read_request() {
    let response = service()
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

    let response = service()
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

#[test]
fn public_listener_addresses_are_rejected() {
    let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 7171);

    assert_eq!(
        service().validate_listener_address(address),
        Err(ServiceError::NonLoopbackAddress(address))
    );
}
