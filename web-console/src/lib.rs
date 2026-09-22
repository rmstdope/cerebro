use std::{
    collections::BTreeSet,
    fmt,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
};
use chrono::{DateTime, Utc};

use axum::{extract::State, routing::get, Json, Router};
use cerebro_tui::{
    read_fleet, read_health, read_work, CommandRunner, Commands, FleetHealth, FleetRow, Programs,
    ReaderPaths, SupervisionMode, WorkBuckets,
};
use serde::Serialize;
use tower_http::services::{ServeDir, ServeFile};

/// A local HTTP boundary for browser-console reads.
///
/// Reader and supervision dependencies are supplied rather than rediscovered so future endpoints
/// can reuse the fleet view's bounded, read-only abstractions without gaining lifecycle access.
pub struct ReadOnlyService {
    reader_paths: ReaderPaths,
    programs: Programs,
    commands: Commands,
    supervision: SupervisionMode,
    assets_dir: PathBuf,
    snapshots: Arc<SnapshotCache>,
}

#[derive(Clone)]
struct SnapshotState {
    reader_paths: ReaderPaths,
    programs: Programs,
    commands: Commands,
    snapshots: Arc<SnapshotCache>,
}

#[derive(Default)]
struct SnapshotCache {
    fleet: Mutex<Option<CachedSnapshot<Vec<FleetRow>>>>,
    work: Mutex<Option<CachedSnapshot<WorkBuckets>>>,
    health: Mutex<Option<CachedSnapshot<FleetHealth>>>,
}

#[derive(Clone)]
struct CachedSnapshot<T> {
    value: T,
    updated_at: DateTime<Utc>,
}

#[derive(Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum Snapshot<T> {
    Fresh { value: T },
    Stale {
        value: T,
        error: String,
        updated_at: DateTime<Utc>,
    },
    Unavailable { error: String },
}

impl ReadOnlyService {
    pub fn new(
        reader_paths: ReaderPaths,
        programs: Programs,
        commands: Arc<dyn CommandRunner>,
        supervision: SupervisionMode,
        assets_dir: PathBuf,
    ) -> Self {
        Self {
            reader_paths,
            programs,
            commands,
            supervision,
            assets_dir,
            snapshots: Arc::new(SnapshotCache::default()),
        }
    }

    pub fn reader_paths(&self) -> &ReaderPaths {
        &self.reader_paths
    }

    pub fn programs(&self) -> &Programs {
        &self.programs
    }

    pub fn commands(&self) -> &Commands {
        &self.commands
    }

    pub fn supervision(&self) -> &SupervisionMode {
        &self.supervision
    }

    pub fn assets_dir(&self) -> &PathBuf {
        &self.assets_dir
    }

    pub fn validate_listener_address(&self, address: SocketAddr) -> Result<(), ServiceError> {
        if address.ip().is_loopback() {
            Ok(())
        } else {
            Err(ServiceError::NonLoopbackAddress(address))
        }
    }

    pub fn router(&self) -> Router {
        let index = self.assets_dir.join("index.html");
        let state = SnapshotState {
            reader_paths: self.reader_paths.clone(),
            programs: self.programs.clone(),
            commands: self.commands.clone(),
            snapshots: Arc::clone(&self.snapshots),
        };
        Router::new()
            .route("/api/fleet", get(fleet_snapshot))
            .route("/api/work", get(work_snapshot))
            .route("/api/health", get(health_snapshot))
            .fallback_service(
                ServeDir::new(self.assets_dir.clone()).fallback(ServeFile::new(index)),
            )
            .with_state(state)
    }
}

async fn fleet_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<Vec<FleetRow>>> {
    Json(snapshot(&state.snapshots.fleet, || {
        read_fleet(
            &state.reader_paths,
            &state.programs,
            state.commands.as_ref(),
        )
    }))
}

async fn work_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<WorkBuckets>> {
    Json(snapshot(&state.snapshots.work, || {
        read_work(
            &state.reader_paths,
            &state.programs,
            state.commands.as_ref(),
            &BTreeSet::new(),
        )
    }))
}

async fn health_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<FleetHealth>> {
    Json(snapshot(&state.snapshots.health, || {
        read_health(&state.reader_paths, state.commands.as_ref())
    }))
}

fn snapshot<T>(
    cache: &Mutex<Option<CachedSnapshot<T>>>,
    reader: impl FnOnce() -> Result<T, cerebro_tui::ReadError>,
) -> Snapshot<T>
where
    T: Clone,
{
    let mut cache = match cache.lock() {
        Ok(cache) => cache,
        Err(_) => {
            return Snapshot::Unavailable {
                error: "snapshot cache lock is poisoned".to_string(),
            }
        }
    };
    match reader() {
        Ok(value) => {
            *cache = Some(CachedSnapshot {
                value: value.clone(),
                updated_at: Utc::now(),
            });
            Snapshot::Fresh { value }
        }
        Err(error) => match cache.clone() {
            Some(snapshot) => Snapshot::Stale {
                value: snapshot.value,
                error: error.to_string(),
                updated_at: snapshot.updated_at,
            },
            None => Snapshot::Unavailable {
                error: error.to_string(),
            },
        },
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum ServiceError {
    NonLoopbackAddress(SocketAddr),
}

impl fmt::Display for ServiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NonLoopbackAddress(address) => {
                write!(formatter, "refusing to listen outside loopback: {address}")
            }
        }
    }
}

impl std::error::Error for ServiceError {}
