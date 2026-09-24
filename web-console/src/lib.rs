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
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::sse::{Event, KeepAlive, Sse},
    routing::{get, post},
    Json, Router,
};
use cerebro_tui::{
    read_bead_record, read_fleet, read_health, read_work, BeadRecord, CommandRunner, Commands, FleetHealth, FleetRow, Programs,
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

/// The most one request may type into a session: a large paste, and no more.
const INPUT_LIMIT: usize = 256 * 1024;

/// The header the console's own page sets on what it types. A page on another site cannot set it
/// without the browser asking this service first, and this service never says yes.
const INPUT_HEADER: &str = "x-cerebro-input";

/// A local HTTP boundary for browser-console reads. It writes nothing itself: typing goes to the
/// session's inbox and start, finish and kill to the supervising fleet view's control socket, so
/// the fleet view stays the one process that acts on its sessions.
///
/// Reader and supervision dependencies are supplied rather than rediscovered so endpoints reuse
/// the fleet view's bounded abstractions.
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
    fleet: Slot<Vec<Agent>>,
    work: Slot<WorkBuckets>,
    health: Slot<FleetHealth>,
}

/// One endpoint's reads, one at a time. The lock is held for the length of a read, so whoever
/// waits on it arrived while that read ran, and takes its answer rather than queueing another.
type Slot<T> = tokio::sync::Mutex<SlotState<T>>;

struct SlotState<T> {
    /// The last good protocol snapshot, which a failed read serves as stale.
    retained: Option<Snapshot<T>>,
    /// The last answer, and when its read finished.
    last: Option<(Instant, Snapshot<T>)>,
}

impl<T> Default for SlotState<T> {
    fn default() -> Self {
        Self { retained: None, last: None }
    }
}

#[derive(Clone, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum Snapshot<T> {
    Fresh {
        value: T,
        updated_at: DateTime<Utc>,
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
            .route("/api/control", get(control_snapshot))
            .route("/api/beads/{id}", get(bead_record))
            .route("/api/beads/{id}/priority", post(bead_priority))
            .route("/api/agents/{name}/{action}", post(agent_action))
            .route("/api/sessions/{name}", get(session_output))
            .route(
                "/api/sessions/{name}/input",
                post(session_input).layer(DefaultBodyLimit::max(INPUT_LIMIT)),
            )
            .fallback_service(
                ServeDir::new(self.assets_dir.clone()).fallback(ServeFile::new(index)),
            )
            .with_state(state)
    }
}

async fn fleet_snapshot(State(state): State<SnapshotState>) -> Json<Snapshot<Vec<Agent>>> {
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
    async fn fleet(&self, fresh: Duration, after: Option<Instant>) -> (Instant, Snapshot<Vec<Agent>>) {
        let reader = self.clone();
        snapshot(&self.snapshots.fleet, fresh, after, move || {
            let rows = read_fleet(&reader.reader_paths, &reader.programs, reader.commands.as_ref())?;
            let published = read_publication(&standby_path(&reader.reader_paths))?.unwrap_or_default();
            let rows = cerebro_tui::model::apply_starting(rows, &published.handed);
            Ok(cerebro_tui::model::apply_standby(rows, &published.names, &Default::default())
                .into_iter()
                .map(|mut row| {
                    // The TUI draws a starting or `up` row's bead from what it handed, until the
                    // state file names one.
                    if matches!(row.state, cerebro_tui::model::RowState::Starting | cerebro_tui::model::RowState::Up) && row.bead.is_none() {
                        row.bead = published.handed.get(&row.name).cloned();
                    }
                    row
                })
                .map(|row| Agent {
                    finishing: cerebro_tui::lifecycle::stop_flag_set(&reader.reader_paths, &row.name),
                    row,
                })
                .collect())
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

/// Everything `bd` says about bead ID, read fresh each time: the dialog that asks for it is opened
/// by hand, one bead at a time. An id is a plain name that cannot pass for a `bd` flag; a read
/// that fails is a 502 carrying why, never an empty bead.
async fn bead_record(
    State(state): State<SnapshotState>,
    Path(id): Path<String>,
) -> Result<Json<BeadRecord>, (StatusCode, Json<serde_json::Value>)> {
    if !is_plain_name(&id, &['.']) || id.starts_with('-') {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "not a bead id"})),
        ));
    }
    let read = tokio::task::spawn_blocking(move || {
        read_bead_record(&state.reader_paths, &state.programs, state.commands.as_ref(), &id)
    })
    .await;
    match read {
        Ok(Ok(record)) => Ok(Json(record)),
        Ok(Err(error)) => Err((
            StatusCode::BAD_GATEWAY,
            Json(serde_json::json!({"error": error.to_string()})),
        )),
        Err(panic) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": panic.to_string()})),
        )),
    }
}

#[derive(serde::Deserialize)]
struct PriorityChange {
    to: u8,
    /// What the board showed before, for the sentence only; `bd` is given `to` alone.
    from: Option<u8>,
}

/// Rank bead ID: the fleet view's own board write (`lifecycle::set_priority` - `bd update`, then
/// `bd dolt push`), made here rather than through the control socket because board writes sit
/// outside the supervision lease: a checkout nobody supervises may still rank its beads.
async fn bead_priority(
    State(state): State<SnapshotState>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(change): Json<PriorityChange>,
) -> (StatusCode, Json<cerebro_tui::control::Reply>) {
    use cerebro_tui::{control::Reply, lifecycle::PriorityOutcome};
    if !from_this_console(&headers) {
        return (StatusCode::FORBIDDEN, Json(Reply::refused("Only this console’s own page may do that.")));
    }
    if !is_plain_name(&id, &['.']) || id.starts_with('-') {
        return (StatusCode::BAD_REQUEST, Json(Reply::refused("That is not a bead id.")));
    }
    if change.to > 4 {
        return (StatusCode::BAD_REQUEST, Json(Reply::refused("A priority is P0 to P4.")));
    }
    let written = tokio::task::spawn_blocking(move || {
        cerebro_tui::lifecycle::set_priority(
            &state.reader_paths,
            &state.programs,
            state.commands.as_ref(),
            &id,
            change.from,
            change.to,
            false,
        )
    })
    .await;
    match written {
        Ok(PriorityOutcome::Ran { text } | PriorityOutcome::Pushed { text }) => (StatusCode::OK, Json(Reply::done(text))),
        Ok(PriorityOutcome::Failed { text }) => (StatusCode::BAD_GATEWAY, Json(Reply::refused(text))),
        Err(panic) => (StatusCode::INTERNAL_SERVER_ERROR, Json(Reply::refused(panic.to_string()))),
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

/// Type BODY into NAME's session, through the inbox the fleet view hosting it publishes.
async fn session_input(
    State(state): State<SnapshotState>,
    Path(name): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> StatusCode {
    if !is_plain_name(&name, &[]) {
        return StatusCode::BAD_REQUEST;
    }
    if !from_this_console(&headers) {
        return StatusCode::FORBIDDEN;
    }
    let dir = state.reader_paths.shared_root.join(".cerebro/state/sessions");
    tokio::task::spawn_blocking(move || write_input(&dir, &name, &body))
        .await
        .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR)
}

/// Whether a request came from this console's own page: it carries `INPUT_HEADER`, and it names
/// this machine as the host it asked for, and as its origin if it gives one - so neither another
/// site nor a name rebound to this address can type into a session.
fn from_this_console(headers: &HeaderMap) -> bool {
    let text = |name| headers.get(name).and_then(|value| value.to_str().ok());
    let loopback = |authority: &str| {
        let host = match authority.rsplit_once(':') {
            Some((host, port)) if !host.is_empty() && port.chars().all(|c| c.is_ascii_digit()) && !authority.ends_with(']') => host,
            _ => authority,
        };
        let host = host.trim_start_matches('[').trim_end_matches(']');
        host.eq_ignore_ascii_case("localhost")
            || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
    };
    let origin = match text(header::ORIGIN.as_str()) {
        None => true,
        Some(origin) => origin
            .split_once("://")
            .is_some_and(|(scheme, rest)| matches!(scheme, "http" | "https") && loopback(rest.trim_end_matches('/'))),
    };
    text(INPUT_HEADER) == Some("1") && text(header::HOST.as_str()).is_some_and(loopback) && origin
}

fn write_input(dir: &std::path::Path, name: &str, bytes: &[u8]) -> StatusCode {
    use std::io::Write;
    let Ok(text) = std::fs::read_to_string(dir.join(format!("{name}.json"))) else {
        return StatusCode::NOT_FOUND;
    };
    let Ok(publication) = serde_json::from_str::<PublishedSession>(&text) else {
        return StatusCode::INTERNAL_SERVER_ERROR;
    };
    let age = Utc::now().signed_duration_since(publication.updated_at).num_seconds();
    let Some(input) = publication.input.filter(|_| age < SCREEN_STALE_SECONDS) else {
        return StatusCode::NOT_FOUND;
    };
    let Ok(mut stream) = std::os::unix::net::UnixStream::connect(input) else {
        return StatusCode::SERVICE_UNAVAILABLE;
    };
    use std::io::Read;
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let mut taken = [0u8; 1];
    // The inbox answers 1 once the message is queued for the pty, and 0 when too much waits.
    match stream.write_all(&cerebro_tui::inbox::framed(bytes)).and_then(|()| stream.read_exact(&mut taken)) {
        Ok(()) if taken == [1] => StatusCode::NO_CONTENT,
        _ => StatusCode::SERVICE_UNAVAILABLE,
    }
}

/// An agent as the console shows it: the fleet view's row, and whether its stop flag is set.
#[derive(Clone, Serialize)]
pub struct Agent {
    #[serde(flatten)]
    row: FleetRow,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    finishing: bool,
}

fn standby_path(paths: &ReaderPaths) -> std::path::PathBuf {
    paths.shared_root.join(".cerebro/state/standby.json")
}

/// What the supervising fleet view publishes. No publication, or one it stopped refreshing whose
/// control socket no longer answers, means no live view; one that does not parse is a fault. The
/// socket is served off the view's loop and closed when it stops supervising, so it outlives a
/// launch or a reap that holds the loop past the refresh.
fn read_publication(path: &std::path::Path) -> Result<Option<cerebro_tui::PublishedStandby>, cerebro_tui::ReadError> {
    let invalid = |message: String| cerebro_tui::ReadError::Invalid {
        source: cerebro_tui::Invocation::new(path, &[]),
        message,
    };
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(invalid(error.to_string())),
    };
    let publication = serde_json::from_str::<cerebro_tui::PublishedStandby>(&text)
        .map_err(|error| invalid(error.to_string()))?;
    let age = Utc::now().signed_duration_since(publication.updated_at).num_seconds();
    let answers = || {
        publication
            .control
            .as_deref()
            .is_some_and(|socket| std::os::unix::net::UnixStream::connect(socket).is_ok())
    };
    Ok((age < SCREEN_STALE_SECONDS || answers()).then_some(publication))
}

/// The socket a live, supervising fleet view takes start, finish and kill requests on; none with
/// no such view, and an error when its publication cannot be read.
fn control_socket(paths: &ReaderPaths) -> Result<Option<String>, String> {
    read_publication(&standby_path(paths))
        .map(|publication| publication.and_then(|publication| publication.control))
        .map_err(|error| error.to_string())
}

async fn read_control(paths: &ReaderPaths) -> Result<Option<String>, String> {
    let paths = paths.clone();
    tokio::task::spawn_blocking(move || control_socket(&paths))
        .await
        .unwrap_or_else(|panic| Err(panic.to_string()))
}

#[derive(Serialize)]
struct ControlState {
    /// A fleet view supervises this checkout and will take start, finish and kill requests.
    supervised: bool,
    /// Why that could not be told; `supervised` is false then, but it is not known to be.
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

async fn control_snapshot(State(state): State<SnapshotState>) -> Json<ControlState> {
    Json(match read_control(&state.reader_paths).await {
        Ok(socket) => ControlState { supervised: socket.is_some(), error: None },
        Err(error) => ControlState { supervised: false, error: Some(error) },
    })
}

/// Start, finish, resume or kill NAME, by asking the fleet view that supervises this checkout -
/// the one process allowed to - and answering with what it did. A kill arrives confirmed: the
/// page asked first.
async fn agent_action(
    State(state): State<SnapshotState>,
    Path((name, action)): Path<(String, String)>,
    headers: HeaderMap,
) -> (StatusCode, Json<cerebro_tui::control::Reply>) {
    use cerebro_tui::control::{Action, Reply, Request};
    let refused = |status, text: &str| (status, Json(Reply::refused(text)));
    let Ok(action) = serde_json::from_value::<Action>(serde_json::Value::String(action)) else {
        return refused(StatusCode::NOT_FOUND, "There is no such action.");
    };
    if !is_plain_name(&name, &[]) {
        return refused(StatusCode::BAD_REQUEST, "That is not an agent's name.");
    }
    if !from_this_console(&headers) {
        return refused(StatusCode::FORBIDDEN, "Only this console's own page may do that.");
    }
    let socket = match read_control(&state.reader_paths).await {
        Err(error) => {
            return refused(StatusCode::SERVICE_UNAVAILABLE, &format!("Couldn’t read the fleet view’s publication: {error}"));
        }
        Ok(None) => {
            return refused(
                StatusCode::SERVICE_UNAVAILABLE,
                "No fleet view is supervising this checkout, so nothing can be started, finished or killed from here.",
            );
        }
        Ok(Some(socket)) => socket,
    };
    let asked = tokio::task::spawn_blocking(move || {
        cerebro_tui::control::ask(std::path::Path::new(&socket), &Request { name, action })
    })
    .await;
    match asked {
        Ok(Ok(reply)) => (StatusCode::OK, Json(reply)),
        _ => refused(StatusCode::SERVICE_UNAVAILABLE, "The fleet view did not answer."),
    }
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
            supervised: None,
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

                // A publication that could not be read says nothing either way, but the good read
                // after it is news: the page may have been told nothing since.
                let seen = read_control(&stream.state.reader_paths).await.map(|socket| socket.is_some()).map_err(|_| ());
                if seen.is_ok() && stream.supervised.replace(seen).is_some_and(|prior| prior != seen) {
                    stream.pending.push_back("control");
                } else if seen.is_err() {
                    stream.supervised = Some(seen);
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
    /// Whether a fleet view took control requests, as this stream last read it, or that it could
    /// not be read.
    supervised: Option<Result<bool, ()>>,
}

#[derive(Default)]
struct EventChanges {
    fleet: Option<String>,
    work: Option<String>,
}

impl EventChanges {
    fn observe<T: Serialize>(&mut self, name: &str, snapshot: &Snapshot<T>) -> bool {
        let mut current = serde_json::to_value(snapshot).expect("snapshot serialization cannot fail");
        current
            .as_object_mut()
            .expect("snapshot serialization is an object")
            .remove("updated_at");
        let current = serde_json::to_string(&current).expect("snapshot serialization cannot fail");
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
            let snapshot = Snapshot::Fresh {
                value,
                updated_at: Utc::now(),
            };
            slot.retained = Some(snapshot.clone());
            snapshot
        }
        Err(error) => match slot.retained.as_ref() {
            Some(Snapshot::Fresh { value, updated_at }) => Snapshot::Stale {
                value: value.clone(),
                error: error.to_string(),
                updated_at: *updated_at,
            },
            Some(Snapshot::Stale { value, updated_at, .. }) => Snapshot::Stale {
                value: value.clone(),
                error: error.to_string(),
                updated_at: *updated_at,
            },
            Some(Snapshot::Unavailable { .. }) | None => Snapshot::Unavailable {
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
    use chrono::Utc;

    use super::{EventChanges, Snapshot};

    #[test]
    fn event_changes_emit_only_when_a_snapshot_changes() {
        let mut changes = EventChanges::default();
        let fresh = Snapshot::Fresh {
            value: vec!["Cyclops"],
            updated_at: Utc::now(),
        };
        let changed = Snapshot::Fresh {
            value: vec!["Cyclops", "Storm"],
            updated_at: Utc::now(),
        };

        assert!(!changes.observe("fleet", &fresh));
        assert!(!changes.observe("fleet", &fresh));
        assert!(changes.observe("fleet", &changed));
        assert!(!changes.observe("work", &fresh));
    }

    #[test]
    fn event_changes_ignore_a_freshness_timestamp_refresh() {
        let mut changes = EventChanges::default();
        let first = Snapshot::Fresh {
            value: vec!["Cyclops"],
            updated_at: Utc::now(),
        };
        let refreshed = Snapshot::Fresh {
            value: vec!["Cyclops"],
            updated_at: Utc::now() + chrono::Duration::seconds(1),
        };

        assert!(!changes.observe("fleet", &first));
        assert!(!changes.observe("fleet", &refreshed));
    }
}
