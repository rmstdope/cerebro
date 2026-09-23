use std::{
    collections::{BTreeSet, VecDeque},
    convert::Infallible,
    fmt,
    net::SocketAddr,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::sse::{Event, KeepAlive, Sse},
    routing::get,
    Json, Router,
};
use cerebro_tui::{
    read_fleet, read_health, read_work, CommandRunner, Commands, FleetHealth, FleetRow, Programs,
    PublishedSession, ReaderPaths, SupervisionMode, WorkBuckets,
};
use chrono::{DateTime, Utc};
use futures_util::stream;
use serde::Serialize;
use tower_http::services::{ServeDir, ServeFile};

const EVENT_POLL_INTERVAL: Duration = Duration::from_secs(2);

/// A publication older than this is a file a gone fleet view left behind. Three of the fleet
/// view's `SCREEN_REFRESH` periods (5 s), a literal twin.
const SCREEN_STALE_SECONDS: i64 = 15;

/// The most session output one response carries; a reader behind by more asks again.
const OUTPUT_CHUNK: u64 = 512 * 1024;

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
    fleet: Slot<Vec<FleetRow>>,
    work: Slot<WorkBuckets>,
    health: Slot<FleetHealth>,
}

/// One endpoint's reads, one at a time. The lock is held for the length of a read, so whoever
/// waits on it arrived while that read ran, and takes its answer rather than queueing another.
type Slot<T> = tokio::sync::Mutex<SlotState<T>>;

struct SlotState<T> {
    /// The last good read, which a failed one is served as stale.
    cache: Option<CachedSnapshot<T>>,
    /// The last answer, and when its read finished.
    last: Option<(Instant, Snapshot<T>)>,
}

impl<T> Default for SlotState<T> {
    fn default() -> Self {
        Self { cache: None, last: None }
    }
}

#[derive(Clone)]
struct CachedSnapshot<T> {
    value: T,
    updated_at: DateTime<Utc>,
}

#[derive(Clone, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum Snapshot<T> {
    Fresh {
        value: T,
    },
    Stale {
        value: T,
        error: String,
        updated_at: DateTime<Utc>,
    },
    Unavailable {
        error: String,
    },
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
            .route("/api/events", get(event_stream))
            .route("/api/sessions/{name}", get(session_output))
            .fallback_service(
                ServeDir::new(self.assets_dir.clone()).fallback(ServeFile::new(index)),
            )
            .with_state(state)
    }
}

async fn fleet_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<Vec<FleetRow>>> {
    Json(state.fleet(Duration::ZERO, None).await.1)
}

async fn work_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<WorkBuckets>> {
    Json(state.work(Duration::ZERO, None).await.1)
}

async fn health_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<FleetHealth>> {
    let reader = state.clone();
    Json(
        snapshot(&state.snapshots.health, Duration::ZERO, None, move || {
            read_health(&reader.reader_paths, reader.commands.as_ref())
        })
        .await
        .1,
    )
}

impl SnapshotState {
    /// The fleet, and when its read finished, on `snapshot`'s terms.
    async fn fleet(&self, fresh: Duration, after: Option<Instant>) -> (Instant, Snapshot<Vec<FleetRow>>) {
        let reader = self.clone();
        snapshot(&self.snapshots.fleet, fresh, after, move || {
            let rows = read_fleet(&reader.reader_paths, &reader.programs, reader.commands.as_ref())?;
            let standby = read_standby(&reader.reader_paths.shared_root.join(".cerebro/state/standby.json"))?;
            Ok(cerebro_tui::model::apply_standby(rows, &standby, &Default::default()))
        })
        .await
    }

    /// The work board, on the same terms as `fleet`.
    async fn work(&self, fresh: Duration, after: Option<Instant>) -> (Instant, Snapshot<WorkBuckets>) {
        let reader = self.clone();
        snapshot(&self.snapshots.work, fresh, after, move || {
            read_work(
                &reader.reader_paths,
                &reader.programs,
                reader.commands.as_ref(),
                &BTreeSet::new(),
            )
        })
        .await
    }
}

#[derive(Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum SessionOutput {
    Live {
        log: String,
        /// The reader's log was replaced, or it had none: `data` starts the new log.
        reset: bool,
        data: String,
        /// Where the next read starts.
        offset: u64,
        /// More is already waiting beyond `offset`.
        more: bool,
    },
    Absent,
}

#[derive(serde::Deserialize)]
struct OutputQuery {
    log: Option<String>,
    from: Option<u64>,
}

fn is_plain_name(name: &str, extra: &[char]) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || extra.contains(&c))
}

/// The end of the longest prefix of BYTES that does not stop inside a character.
fn character_boundary(bytes: &[u8]) -> usize {
    match std::str::from_utf8(bytes) {
        Ok(_) => bytes.len(),
        Err(error) if error.error_len().is_none() => error.valid_up_to(),
        Err(_) => bytes.len(),
    }
}

/// NAME's hosted session output, read-only: the log the fleet view last published for it, from
/// the reader's offset. A session the fleet view does not host - or one it stopped refreshing -
/// is `absent`; anything else that cannot be read is an error, never an empty answer.
async fn session_output(
    State(state): State<SnapshotState>,
    Path(name): Path<String>,
    Query(query): Query<OutputQuery>,
) -> Result<Json<SessionOutput>, StatusCode> {
    if !is_plain_name(&name, &[]) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let dir = state
        .reader_paths
        .shared_root
        .join(".cerebro/state/sessions");
    tokio::task::spawn_blocking(move || read_output(&dir, &name, query))
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .map(Json)
}

/// The names the supervising fleet view holds on standby. No publication, or one it stopped
/// refreshing, means no live view and so nobody on standby; one that does not parse is a fault.
fn read_standby(path: &std::path::Path) -> Result<std::collections::BTreeSet<String>, cerebro_tui::ReadError> {
    let invalid = |message: String| cerebro_tui::ReadError::Invalid {
        source: cerebro_tui::Invocation::new(path, &[]),
        message,
    };
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Default::default()),
        Err(error) => return Err(invalid(error.to_string())),
    };
    let publication = serde_json::from_str::<cerebro_tui::PublishedStandby>(&text)
        .map_err(|error| invalid(error.to_string()))?;
    let age = Utc::now().signed_duration_since(publication.updated_at).num_seconds();
    Ok(if age >= SCREEN_STALE_SECONDS { Default::default() } else { publication.names })
}

fn read_output(
    dir: &std::path::Path,
    name: &str,
    query: OutputQuery,
) -> Result<SessionOutput, StatusCode> {
    use std::io::{Read, Seek, SeekFrom};
    let fault = |_| StatusCode::INTERNAL_SERVER_ERROR;
    let text = match std::fs::read_to_string(dir.join(format!("{name}.json"))) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(SessionOutput::Absent)
        }
        Err(error) => return Err(fault(error)),
    };
    // The fleet view renames a whole file into place, so one that does not parse is a fault.
    let publication = serde_json::from_str::<PublishedSession>(&text)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    if Utc::now()
        .signed_duration_since(publication.updated_at)
        .num_seconds()
        >= SCREEN_STALE_SECONDS
    {
        return Ok(SessionOutput::Absent);
    }
    if !is_plain_name(&publication.log, &['.']) {
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    // A log replaced between reading the publication and opening it is gone for a moment only.
    let mut file = std::fs::File::open(dir.join(&publication.log))
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    let length = file.metadata().map_err(fault)?.len();
    let continuing = query.log.as_deref() == Some(publication.log.as_str());
    let from = query
        .from
        .filter(|from| continuing && *from <= length)
        .unwrap_or(0);
    let reset = !continuing || query.from.is_none_or(|asked| asked != from);
    file.seek(SeekFrom::Start(from)).map_err(fault)?;
    let mut bytes = Vec::new();
    file.take(OUTPUT_CHUNK)
        .read_to_end(&mut bytes)
        .map_err(fault)?;
    bytes.truncate(character_boundary(&bytes));
    let offset = from + bytes.len() as u64;
    Ok(SessionOutput::Live {
        log: publication.log,
        reset,
        data: String::from_utf8_lossy(&bytes).into_owned(),
        offset,
        more: offset < length,
    })
}

async fn event_stream(
    State(state): State<SnapshotState>,
) -> Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>> {
    Sse::new(stream::unfold(
        EventState {
            state,
            events: EventChanges::default(),
            interval: {
                // After a slow read, the next tick is an interval on, not a burst of the missed ones.
                let mut interval = tokio::time::interval(EVENT_POLL_INTERVAL);
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                interval
            },
            pending: VecDeque::new(),
            initialized: false,
            fleet_seen: None,
            work_seen: None,
        },
        |mut stream| async move {
            loop {
                if let Some(event) = stream.pending.pop_front() {
                    return Some((
                        Ok(Event::default().event(event).data("snapshot changed")),
                        stream,
                    ));
                }

                stream.interval.tick().await;
                // A read another stream made this interval will do: every open page polls, and
                // one read each per interval is more than `bd` can answer. Never the answer this
                // stream saw last, though, or a change would wait a tick more to be seen.
                let (seen, fleet) = stream.state.fleet(EVENT_POLL_INTERVAL, stream.fleet_seen).await;
                stream.fleet_seen = Some(seen);
                if stream.events.observe("fleet", &fleet) {
                    stream.pending.push_back("fleet");
                }

                let (seen, work) = stream.state.work(EVENT_POLL_INTERVAL, stream.work_seen).await;
                stream.work_seen = Some(seen);
                if stream.events.observe("work", &work) {
                    stream.pending.push_back("work");
                }
                if !stream.initialized {
                    stream.initialized = true;
                    return Some((Ok(Event::default().comment("snapshot baseline")), stream));
                }
            }
        },
    ))
    .keep_alive(KeepAlive::default())
}

struct EventState {
    state: SnapshotState,
    events: EventChanges,
    interval: tokio::time::Interval,
    pending: VecDeque<&'static str>,
    initialized: bool,
    /// When the read behind the last fleet and work answers this stream saw finished.
    fleet_seen: Option<Instant>,
    work_seen: Option<Instant>,
}

#[derive(Default)]
struct EventChanges {
    fleet: Option<String>,
    work: Option<String>,
}

impl EventChanges {
    fn observe<T: Serialize>(&mut self, name: &str, snapshot: &Snapshot<T>) -> bool {
        let current = serde_json::to_string(snapshot).expect("snapshot serialization cannot fail");
        let previous = match name {
            "fleet" => &mut self.fleet,
            "work" => &mut self.work,
            _ => unreachable!("event names are fixed"),
        };
        previous
            .replace(current.clone())
            .is_some_and(|prior| prior != current)
    }
}

/// SLOT's answer, and when its read finished: the last one, if that read finished no more than
/// FRESH before this call (or after it, while this call waited on the slot) and after AFTER; else
/// READER's, run off the async workers.
async fn snapshot<T>(
    slot: &Slot<T>,
    fresh: Duration,
    after: Option<Instant>,
    reader: impl FnOnce() -> Result<T, cerebro_tui::ReadError> + Send + 'static,
) -> (Instant, Snapshot<T>)
where
    T: Clone + Send + 'static,
{
    let arrived = Instant::now();
    let mut slot = slot.lock().await;
    if let Some((finished, answer)) = &slot.last {
        if arrived.saturating_duration_since(*finished) <= fresh && after.is_none_or(|seen| *finished > seen) {
            return (*finished, answer.clone());
        }
    }
    let read = tokio::task::spawn_blocking(reader)
        .await
        .unwrap_or_else(|panic| Err(cerebro_tui::ReadError::Invalid {
            source: cerebro_tui::Invocation::new(std::path::Path::new("reader"), &[]),
            message: panic.to_string(),
        }));
    let answer = match read {
        Ok(value) => {
            slot.cache = Some(CachedSnapshot {
                value: value.clone(),
                updated_at: Utc::now(),
            });
            Snapshot::Fresh { value }
        }
        Err(error) => match slot.cache.clone() {
            Some(snapshot) => Snapshot::Stale {
                value: snapshot.value,
                error: error.to_string(),
                updated_at: snapshot.updated_at,
            },
            None => Snapshot::Unavailable {
                error: error.to_string(),
            },
        },
    };
    let finished = Instant::now();
    slot.last = Some((finished, answer.clone()));
    (finished, answer)
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

#[cfg(test)]
mod tests {
    use super::{EventChanges, Snapshot};

    #[test]
    fn event_changes_emit_only_when_a_snapshot_changes() {
        let mut changes = EventChanges::default();
        let fresh = Snapshot::Fresh {
            value: vec!["Cyclops"],
        };
        let changed = Snapshot::Fresh {
            value: vec!["Cyclops", "Storm"],
        };

        assert!(!changes.observe("fleet", &fresh));
        assert!(!changes.observe("fleet", &fresh));
        assert!(changes.observe("fleet", &changed));
        assert!(!changes.observe("work", &fresh));
    }
}
