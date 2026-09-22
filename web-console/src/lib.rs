use std::{
    collections::BTreeSet,
    fmt,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
};

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
}

#[derive(Clone)]
struct SnapshotState {
    reader_paths: ReaderPaths,
    programs: Programs,
    commands: Commands,
    fleet_cache: Arc<Mutex<Option<Vec<FleetRow>>>>,
    work_cache: Arc<Mutex<Option<WorkBuckets>>>,
    health_cache: Arc<Mutex<Option<FleetHealth>>>,
}

#[derive(Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum Snapshot<T> {
    Fresh { value: T },
    Stale { value: T, error: String },
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
            fleet_cache: Arc::new(Mutex::new(None)),
            work_cache: Arc::new(Mutex::new(None)),
            health_cache: Arc::new(Mutex::new(None)),
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
    Json(snapshot(&state.fleet_cache, || {
        read_fleet(
            &state.reader_paths,
            &state.programs,
            state.commands.as_ref(),
        )
    }))
}

async fn work_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<WorkBuckets>> {
    Json(snapshot(&state.work_cache, || {
        read_work(
            &state.reader_paths,
            &state.programs,
            state.commands.as_ref(),
            &BTreeSet::new(),
        )
    }))
}

async fn health_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<FleetHealth>> {
    Json(snapshot(&state.health_cache, || {
        read_health(&state.reader_paths, state.commands.as_ref())
    }))
}

fn snapshot<T>(
    cache: &Mutex<Option<T>>,
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
            *cache = Some(value.clone());
            Snapshot::Fresh { value }
        }
        Err(error) => match cache.clone() {
            Some(value) => Snapshot::Stale {
                value,
                error: error.to_string(),
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
