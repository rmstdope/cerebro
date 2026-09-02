//! Filesystem and subprocess I/O, kept apart from `crate::model`'s pure parsing/derivation.
//!
//! Read-only by construction: every function here reads a file or runs a read-only external
//! program (`scripts/roster`, `ps`, `bd --readonly`, `gh`) and returns data for `crate::model` to
//! parse. Nothing here writes a file, launches, stops, triggers, supervises, or cleans up state.
//!
//! That sentence is still true of THIS file, and `crate::lifecycle` exists so that it stays so:
//! since cb-kcs.2.3 the crate does write to the fleet's contracts - a stop flag, and the deletion
//! of a state file, which cb-kcs.3 made unattended - and every one of those writes lives there.
//! The one thing this module shares with it is the state-file path, which it asks
//! `lifecycle::state_file_path` for rather than spelling a second time. Since cb-kcs.5.1 the
//! same division holds for the sweeps: `read_sweeps` below runs the six read-only scripts and
//! takes the fleet snapshot they are judged against, `crate::sweeps` judges, and the one `bd`
//! that WRITES - the command behind a confirmed finding - is `lifecycle::run_finding`.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use wait_timeout::ChildExt;

use chrono::{DateTime, Utc};

use crate::supervisor::SupervisorKind;
use crate::sweeps::{self, Candidate, Finding, LiveSession, Snapshot, Sweep};
use crate::model::{
    self, Bead, FleetRow, GhIssue, GhPull, GhSnapshot, ProcessRow, RosterEntry, StateInputs,
    StateObservation, StateRecord, WorkBuckets,
};

/// How long a reader's child may run before it is killed and reported as a failure.
///
/// A `roster` that blocks on a lock, or a `ps` that never returns, would otherwise leave the
/// screen saying `refreshing...` forever: the request is in flight, so no later tick can replace
/// it, and nothing on screen says anything is wrong. Five seconds is far longer than either
/// program has ever taken and short enough that the next five-second tick is the recovery.
/// The wall-clock bound every reader puts on its child.
///
/// Five seconds, and deliberately kept there: it is measurably thin on a loaded developer
/// machine — a two-line bash script has exceeded it beside three concurrent `cargo test` runs —
/// so a fleet building in its worktrees will show `Unavailable`/`Stale` panes while it does. That is the designed recovery — the next tick retries — and a longer bound
/// would trade a visible, self-healing pane for a screen that sits on `refreshing...` instead.
const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);

/// Roots this crate reads from, supplied by the launcher (`cb-vyp.2`); this child does not
/// rediscover them itself.
#[derive(Clone, Debug)]
pub struct ReaderPaths {
    /// The enclosing working tree (a bead worktree's own checkout, or the main one).
    pub consumer_root: PathBuf,
    /// The checkout every worktree shares - where state files and `bd`'s database live
    /// (`scripts/work-beads:25-29`: a worktree-local `bd` query can silently read the wrong
    /// database, so this is mandatory rather than derived from `consumer_root`).
    pub shared_root: PathBuf,
    /// Where `scripts/roster` (and its siblings) live.
    pub scripts_dir: PathBuf,
}

/// The external programs this crate runs, injectable so tests never depend on - or mutate - the
/// developer's own `bd` database or process table.
#[derive(Clone, Debug)]
pub struct Programs {
    pub bd: PathBuf,
    pub ps: PathBuf,
    /// Injectable like the other two, and that is not decoration: it is the only thing that keeps
    /// this crate's tests off the network. A test that used the default would assert about the
    /// developer's own GitHub account, pass on their machine, and fail in CI - where `gh` is
    /// present and authenticated as somebody else entirely.
    pub gh: PathBuf,
}

impl Default for Programs {
    fn default() -> Self {
        Self {
            bd: PathBuf::from("bd"),
            ps: PathBuf::from("ps"),
            gh: PathBuf::from("gh"),
        }
    }
}

/// One impure read gone wrong. Each variant keeps enough to diagnose it: which program or path,
/// and what it said.
#[derive(Debug)]
pub enum ReadError {
    Spawn { source: String, message: String },
    Exit {
        source: String,
        status: Option<i32>,
        stderr: String,
        /// What the program printed before it failed. Carried because one reader's refusal is
        /// still an answer: `scripts/fleet-supervisor` exits 2 on an invalid declaration and
        /// prints the raw offending value, which is what the header has to name. Everywhere else
        /// this is simply empty.
        stdout: String,
    },
    Invalid { source: String, message: String },
    Timeout { source: String, seconds: u64 },
    /// A sweep script that did not answer, in the words the header shows: `sweep-claims failed`.
    ///
    /// Its `Display` is deliberately shorter than every other variant's. The navigator chose one
    /// word for all three causes - a non-zero exit, the timeout, and output that is not the JSON
    /// array it promised - because the next move is the same for all three. The cause is not lost
    /// with it: `cause` carries the underlying failure's own words, and `main` writes THAT to
    /// `errors.jsonl` while the header shows the one word.
    Sweep { script: String, cause: String },
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Spawn { source, message } => write!(f, "could not run {source}: {message}"),
            Self::Exit { source, status, stderr, .. } =>
                write!(f, "{source} exited with status {status:?}: {stderr}"),
            Self::Invalid { source, message } =>
                write!(f, "{source} produced invalid output: {message}"),
            Self::Timeout { source, seconds } =>
                write!(f, "{source} did not answer within {seconds}s"),
            Self::Sweep { script, .. } => write!(f, "{script} failed"),
        }
    }
}

impl ReadError {
    /// The underlying failure's own words, for the log - the one thing `Display` does not say.
    ///
    /// `None` for every variant but `Sweep`, whose `Display` is one word by the navigator's own
    /// choice: everywhere else the message the header shows IS the cause.
    pub fn cause(&self) -> Option<&str> {
        match self {
            Self::Sweep { cause, .. } => Some(cause),
            _ => None,
        }
    }
}

impl std::error::Error for ReadError {}

/// What a reader asks of the outside world: run this program, with these arguments, in this
/// directory, bounded by this wall clock, and give me its stdout - or the failure as itself.
///
/// The seam exists so that a test about PARSING never starts a process. Four separate patches in
/// this module - `c25701f`, `4e70768`, `dd3066d`, `fa52613` - were each a new wrapper around a
/// fixture spawn (a widened timeout, an `ETXTBSY` retry, a zombie poll) rather than a way of not
/// spawning at all, and every new reader test widened the window for the next one.
///
/// `RealCommands` is the only implementation production ever uses; `testing::FakeCommands`
/// answers from a table and records the argv, and `tests/command_runner.rs` proves the real one
/// against tracked fixture scripts, in its own process.
pub trait CommandRunner: Send + Sync {
    fn run(
        &self,
        program: &Path,
        args: &[&str],
        cwd: Option<&Path>,
        timeout: Duration,
    ) -> Result<Vec<u8>, ReadError>;
}

/// The runner that actually spawns - the only one that does.
///
/// Both pipes are drained on their own threads *before* anything waits: a child that fills a pipe
/// blocks writing while the parent blocks waiting, which is a deadlock no timeout can see, since
/// the child is not idle - it is running, waiting on us. A timed-out child is killed and then
/// waited for, so no zombie is left behind.
#[derive(Clone, Copy, Debug, Default)]
pub struct RealCommands;

/// What a worker moves onto its own thread: a runner it does not own exclusively.
pub type Commands = std::sync::Arc<dyn CommandRunner>;

impl CommandRunner for RealCommands {
    fn run(
        &self,
        program: &Path,
        args: &[&str],
        cwd: Option<&Path>,
        timeout: Duration,
    ) -> Result<Vec<u8>, ReadError> {
    let program_name = program.display().to_string();
    let spawn_failed = |e: std::io::Error| ReadError::Spawn {
        source: program_name.clone(),
        message: e.to_string(),
    };

    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = cwd {
        command.current_dir(dir);
    }
    let mut child = command.spawn().map_err(spawn_failed)?;

    let mut stdout_pipe = child.stdout.take().expect("stdout was piped");
    let mut stderr_pipe = child.stderr.take().expect("stderr was piped");
    let stdout_reader = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = stdout_pipe.read_to_end(&mut buffer);
        buffer
    });
    let stderr_reader = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = stderr_pipe.read_to_end(&mut buffer);
        buffer
    });

    let waited = child.wait_timeout(timeout).map_err(spawn_failed)?;
    let status = match waited {
        Some(status) => status,
        None => {
            // Kill, then wait: killing alone leaves a zombie, and this process outlives every
            // refresh it makes.
            let _ = child.kill();
            let _ = child.wait();
            // A descendant may still hold either pipe open. Dropping the join handles lets the
            // worker return at the timeout boundary instead of waiting for that unrelated process.
            return Err(ReadError::Timeout {
                source: program_name,
                seconds: timeout.as_secs(),
            });
        }
    };

    let stdout = stdout_reader.join().unwrap_or_default();
    let stderr = stderr_reader.join().unwrap_or_default();
    if !status.success() {
        return Err(ReadError::Exit {
            source: program_name,
            status: status.code(),
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
        });
    }
    Ok(stdout)
    }
}

/// The roster, via `<scripts_dir>/roster` - the one place the fleet is declared
/// (`emacs/cerebro.el:117-129`).
pub fn read_roster(
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
) -> Result<Vec<RosterEntry>, ReadError> {
    let program = paths.scripts_dir.join("roster");
    let stdout = commands.run(&program, &[], Some(&paths.consumer_root), COMMAND_TIMEOUT)?;
    let text = String::from_utf8(stdout).map_err(|e| ReadError::Invalid {
        source: program.display().to_string(),
        message: e.to_string(),
    })?;
    model::parse_roster(&text).map_err(|e| ReadError::Invalid {
        source: program.display().to_string(),
        message: e.to_string(),
    })
}

/// The names `scripts/roster --autostart` lists, in file order - the agents this project wants
/// started as the view comes up.
pub fn read_autostart_names(
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
) -> Result<Vec<String>, ReadError> {
    read_roster_names(paths, "--autostart", commands)
}

/// The names `scripts/roster --standby` lists, in file order - ARMED without being started
/// (cb-98u). The other half of the same declaration.
pub fn read_standby_names(
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
) -> Result<Vec<String>, ReadError> {
    read_roster_names(paths, "--standby", commands)
}

/// One name per line, blank lines dropped. A read that fails is an error the caller reports and
/// treats as an empty list: a roster this view cannot read is a fleet it must not start guesses
/// from.
fn read_roster_names(
    paths: &ReaderPaths,
    flag: &str,
    commands: &dyn CommandRunner,
) -> Result<Vec<String>, ReadError> {
    let program = paths.scripts_dir.join("roster");
    let stdout = commands.run(&program, &[flag], Some(&paths.consumer_root), COMMAND_TIMEOUT)?;
    let text = String::from_utf8(stdout).map_err(|e| ReadError::Invalid {
        source: program.display().to_string(),
        message: e.to_string(),
    })?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect())
}

/// The `role_start_spacing_<role>` each of ROLES declares, one `scripts/project-conf` call per
/// distinct role (`cerebro--project-spacing`).
///
/// Three things it copies, each already paid for: **stdout only**, because `project-conf` prints
/// which branch it took to stderr on every call; **a non-zero exit is "declared nothing", not an
/// error**, since it exits non-zero only for a caller's programming error or a declaration left
/// at the retired `.claude/` path; and **a value that is not a whole number of seconds is a THIRD
/// answer**, returned beside the map so the caller can say so out loud once rather than silently
/// using a fallback.
///
/// Runs once, at startup, beside `read_configured_supervisor` - not per tick and not per row.
pub fn read_role_spacing(
    paths: &ReaderPaths,
    roles: &[&str],
    commands: &dyn CommandRunner,
) -> (BTreeMap<String, u64>, Vec<String>) {
    let program = paths.scripts_dir.join("project-conf");
    let mut declared = BTreeMap::new();
    let mut complaints = Vec::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for role in roles {
        if !seen.insert(role) {
            continue;
        }
        let key = format!("role_start_spacing_{role}");
        let Ok(stdout) =
            commands.run(&program, &[&key], Some(&paths.consumer_root), COMMAND_TIMEOUT)
        else {
            continue;
        };
        let raw = String::from_utf8_lossy(&stdout).trim().to_string();
        match crate::triggers::parse_spacing(&raw) {
            Ok(Some(seconds)) => {
                declared.insert((*role).to_string(), seconds);
            }
            Ok(None) => {}
            Err(bad) => {
                let fallback = crate::triggers::default_spacing(role);
                complaints.push(match fallback {
                    Some(seconds) => format!(
                        "project.conf: {key} is not a whole number of seconds (\"{bad}\"); using {seconds}."
                    ),
                    None => format!(
                        "project.conf: {key} is not a whole number of seconds (\"{bad}\"); using no spacing."
                    ),
                });
            }
        }
    }
    (declared, complaints)
}

/// Which implementation this project declares may supervise, from `scripts/fleet-supervisor`
/// (cb-kcs.1).
///
/// The refusal is an answer, not a failure to paper over: an invalid declaration exits 2 and
/// prints the raw offending value, and this returns it as `Err(raw)` so the header can name it.
/// A declaration this build cannot read is NEVER rounded to `emacs` - that fallback is the one
/// thing fail-closed forbids, because a typo that read as the default would leave supervision
/// where the navigator moved it away from.
pub fn read_configured_supervisor(
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
) -> Result<Result<SupervisorKind, String>, ReadError> {
    let program = paths.scripts_dir.join("fleet-supervisor");
    match commands.run(&program, &[], Some(&paths.consumer_root), COMMAND_TIMEOUT) {
        Ok(stdout) => {
            let word = String::from_utf8_lossy(&stdout).trim().to_string();
            Ok(SupervisorKind::parse(&word).ok_or(word))
        }
        // Exit 2 with the raw value on stdout is the documented invalid-declaration answer.
        Err(ReadError::Exit { status: Some(2), stdout, .. }) => Ok(Err(stdout.trim().to_string())),
        Err(other) => Err(other),
    }
}

/// The loopback address this checkout's supervision lease lives at.
pub fn read_supervisor_endpoint(
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
) -> Result<SocketAddr, ReadError> {
    let program = paths.scripts_dir.join("fleet-supervisor");
    let stdout = commands.run(&program, &["--endpoint"], Some(&paths.consumer_root), COMMAND_TIMEOUT)?;
    let text = String::from_utf8_lossy(&stdout).trim().to_string();
    text.parse().map_err(|e: std::net::AddrParseError| ReadError::Invalid {
        source: program.display().to_string(),
        message: format!("{text:?} is not an address: {e}"),
    })
}

/// The canonical shared root this checkout supervises - the identity the record round-trips.
pub fn read_supervisor_identity(
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
) -> Result<String, ReadError> {
    let program = paths.scripts_dir.join("fleet-supervisor");
    let stdout = commands.run(&program, &["--identity"], Some(&paths.consumer_root), COMMAND_TIMEOUT)?;
    Ok(String::from_utf8_lossy(&stdout).trim().to_string())
}

/// Where the diagnostic record goes. Reading this creates nothing.
pub fn read_supervisor_record(
    paths: &ReaderPaths,
    commands: &dyn CommandRunner,
) -> Result<PathBuf, ReadError> {
    let program = paths.scripts_dir.join("fleet-supervisor");
    let stdout = commands.run(&program, &["--record"], Some(&paths.consumer_root), COMMAND_TIMEOUT)?;
    Ok(PathBuf::from(String::from_utf8_lossy(&stdout).trim().to_string()))
}

/// One `.cerebro/state/<name>.state.json` per ROSTER entry, under `paths.shared_root` - the
/// checkout every worktree shares (`agent-state`'s own `--shared` resolution).
///
/// `NotFound` is `Missing`; any other read failure or a parse failure is `Invalid` with the path
/// and the underlying error, so one bad file produces one explicit invalid row rather than
/// discarding it silently or, worse, treating it as healthy.
pub fn read_states(paths: &ReaderPaths, roster: &[RosterEntry]) -> StateInputs {
    let mut states = StateInputs::new();
    for entry in roster {
        // The path is spelled once, in `lifecycle`, which is also where it is deleted: two
        // spellings of one contract path is drift this repository has already paid for.
        let path = crate::lifecycle::state_file_path(paths, &entry.name);
        let observation = match std::fs::read_to_string(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => StateObservation::Missing,
            Err(e) => StateObservation::Invalid(format!("{}: {e}", path.display())),
            Ok(text) => match serde_json::from_str::<StateRecord>(&text) {
                Ok(record) => StateObservation::Parsed(record),
                Err(e) => StateObservation::Invalid(format!("{}: {e}", path.display())),
            },
        };
        states.insert(entry.name.clone(), observation);
    }
    states
}

/// Every system process, via `ps -axo pid=,ppid=,args=` - matching `cerebro--system-processes`'s
/// contract (`emacs/cerebro.el:3255-3271`), fed to the pure `model::parse_processes`.
pub fn read_processes(
    programs: &Programs,
    commands: &dyn CommandRunner,
) -> Result<Vec<ProcessRow>, ReadError> {
    let stdout =
        commands.run(&programs.ps, &["-axo", "pid=,ppid=,args="], None, COMMAND_TIMEOUT)?;
    let text = String::from_utf8(stdout).map_err(|e| ReadError::Invalid {
        source: programs.ps.display().to_string(),
        message: e.to_string(),
    })?;
    model::parse_processes(&text).map_err(|e| ReadError::Invalid {
        source: programs.ps.display().to_string(),
        message: e.to_string(),
    })
}

/// Every bead the panel partitions, via `bd --readonly -C <shared_root> list --status
/// open,in_progress,blocked,deferred,closed --json --brief` - matching `cerebro--bd-list-argv`
/// (`emacs/cerebro.el:4564-4571`). `--readonly` and the explicit `-C` are mandatory: `bd` answers
/// about whatever repository it runs in and defaults to open beads only
/// (`scripts/work-beads:17-29`).
pub fn read_beads(
    paths: &ReaderPaths,
    programs: &Programs,
    commands: &dyn CommandRunner,
) -> Result<Vec<Bead>, ReadError> {
    let root = paths.shared_root.to_string_lossy().into_owned();
    let stdout = commands.run(
        &programs.bd,
        &[
            "--readonly",
            "-C",
            &root,
            "list",
            "--status",
            "open,in_progress,blocked,deferred,closed",
            "--json",
            "--brief",
        ],
        None,
        COMMAND_TIMEOUT,
    )?;
    serde_json::from_slice(&stdout).map_err(|e| ReadError::Invalid {
        source: programs.bd.display().to_string(),
        message: e.to_string(),
    })
}

/// The whole bead panel in one read: one `bd` answer, partitioned by `model::partition_beads`.
///
/// The only aggregate Work read there is, and the counterpart of `read_fleet` above. A failure of
/// any kind - a non-zero `bd`, a timed-out one, output that is not the JSON list it promised - is
/// returned as itself. `Ok(WorkBuckets::default())` would render as six empty queues, which is a
/// fleet with nothing to do rather than a board nobody could read.
pub fn read_work(
    paths: &ReaderPaths,
    programs: &Programs,
    commands: &dyn CommandRunner,
) -> Result<WorkBuckets, ReadError> {
    Ok(model::partition_beads(read_beads(paths, programs, commands)?))
}

/// How long each `gh` child may run. Thirty seconds, not `COMMAND_TIMEOUT`'s five: these are
/// network calls, and a slow answer read as a failure would put `gh?` on two rows and drop both
/// roles to their hourly floor for something that was merely slow. Three children at thirty
/// seconds is ninety in the worst case, comfortably inside the ten-minute cadence, and the pane's
/// own in-flight slot is what stops a slow read from stacking. `M-x cerebro` allows 120s for the
/// same calls (`cerebro-subprocess-timeout-seconds`); this is shorter because it runs on a thread
/// the navigator is not waiting on and the next request is ten minutes away either way.
const GH_TIMEOUT: Duration = Duration::from_secs(30);

const GH_ISSUES_ARGV: [&str; 8] = [
    "issue", "list", "--state", "open", "--json", "number,updatedAt", "--limit", "100",
];
const GH_PRS_ARGV: [&str; 8] = [
    "pr", "list", "--state", "open", "--json", "number,author,isDraft,updatedAt", "--limit", "100",
];
const GH_ME_ARGV: [&str; 4] = ["api", "user", "-q", ".login"];

/// What is open on GitHub, and who the navigator is - one snapshot from three `gh` calls
/// (`emacs/cerebro.el:5749-5761`).
///
/// ME is the login this reader has already learnt, and it is an in/out parameter for one reason:
/// `gh api user` answers the same thing for the life of the process, so it is asked for until it
/// answers and then never again (`emacs/cerebro.el:5825-5834`). A failure of THAT call is not a
/// failure of the read - the two lists are what the triggers are made of - so it leaves ME where
/// it was and the snapshot carries whatever is known. Folding it in would turn "we do not know who
/// you are" into `gh?` on both rows when the issue half of Moira's trigger is perfectly
/// answerable without it. A failure of either LIST is returned as itself:
/// `Ok(GhSnapshot::default())` would say every issue is closed and nothing has moved, which is a
/// lie a trigger would act on.
///
/// `cwd` is `paths.consumer_root`, matching `cerebro--refresh-gh-when-due`'s `(cerebro--repo-root)`:
/// `gh` answers about the repository it is run in, and a worktree has the same remote as its main
/// checkout.
pub fn read_gh(
    paths: &ReaderPaths,
    programs: &Programs,
    me: &mut Option<String>,
    commands: &dyn CommandRunner,
) -> Result<GhSnapshot, ReadError> {
    let cwd = Some(paths.consumer_root.as_path());
    let invalid = |e: serde_json::Error| ReadError::Invalid {
        source: programs.gh.display().to_string(),
        message: e.to_string(),
    };
    let issues: Vec<GhIssue> =
        serde_json::from_slice(&commands.run(&programs.gh, &GH_ISSUES_ARGV, cwd, GH_TIMEOUT)?)
            .map_err(invalid)?;
    let prs: Vec<GhPull> =
        serde_json::from_slice(&commands.run(&programs.gh, &GH_PRS_ARGV, cwd, GH_TIMEOUT)?)
            .map_err(invalid)?;
    if me.is_none() {
        if let Ok(stdout) = commands.run(&programs.gh, &GH_ME_ARGV, cwd, GH_TIMEOUT) {
            let login = String::from_utf8_lossy(&stdout).trim().to_string();
            if !login.is_empty() {
                *me = Some(login);
            }
        }
    }
    Ok(GhSnapshot { issues, prs, me: me.clone() })
}

/// The whole fleet in one read: roster, every state file, the process table - fed to
/// `model::derive_fleet` against the SHARED root, which is both where the state files live and
/// what `scripts/launch` roots every session's marker sentence at (`scripts/agent-alive:61-107`).
///
/// One call rather than three, because a screen showing rows read at three different moments is a
/// screen that can show a bead in a row whose process scan predates the claim. A failure in
/// either subprocess is returned as itself: a fleet that could not be read is never an empty
/// fleet, which would read as "every agent is dead".
pub fn read_fleet(
    paths: &ReaderPaths,
    programs: &Programs,
    commands: &dyn CommandRunner,
) -> Result<Vec<FleetRow>, ReadError> {
    let roster = read_roster(paths, commands)?;
    let states = read_states(paths, &roster);
    let processes = read_processes(programs, commands)?;
    Ok(model::derive_fleet(
        &roster,
        &states,
        &processes,
        &paths.shared_root,
    ))
}

/// How long a sweep script may run. Twenty times `COMMAND_TIMEOUT`, and the same number
/// `cerebro-subprocess-timeout-seconds` (`emacs/cerebro.el:1285-1288`) uses: three of the six
/// `git fetch` from origin, so the thing being bounded here is a hang, not a slow answer. The
/// five-second bound would fail every sweep on a slow network, which reads as a broken script.
const SWEEP_TIMEOUT: Duration = Duration::from_secs(120);

/// A finding and the line the Sweeps section shows for it.
///
/// It carries the already-formatted label rather than the candidate it was judged from: the
/// candidate is needed for nothing else, and keeping it would put one in `App`'s state for the
/// lifetime of a pane. The label is computed on the worker thread, where the snapshot is.
#[derive(Clone, Debug, PartialEq)]
pub struct Judged {
    pub finding: Finding,
    pub label: String,
}

/// The six sweeps, run in `Sweep::ALL` order, and the findings they justify.
///
/// The chain stops at the first script that does not answer and no later script is started -
/// `cerebro--request-sweeps-1`'s own rule (`emacs/cerebro.el:1419-1437`) - so at most one script
/// name is ever knowable, which is what lets the header name exactly one.
///
/// "Does not answer" is three things and they are one outcome: a non-zero exit, the timeout, and
/// output that is not the JSON array it promised. An empty `[]` is a real answer and not a
/// failure - `serde_json` tells the two apart for free, provided this never "helpfully" falls
/// back to an empty vector on a parse error.
///
/// The snapshot is taken AFTER the last script answers, never before the first: the fleet moves
/// while six scripts run, and a candidate judged against a fleet six scripts old is a finding
/// about a session that has since started.
pub fn read_sweeps(
    paths: &ReaderPaths,
    programs: &Programs,
    commands: &dyn CommandRunner,
) -> Result<Vec<Judged>, ReadError> {
    let mut outputs: Vec<(Sweep, Vec<Candidate>)> = Vec::new();
    for sweep in Sweep::ALL {
        let program = paths.scripts_dir.join(sweep.script());
        let failed = |cause: String| ReadError::Sweep { script: sweep.key().to_string(), cause };
        let stdout = commands
            .run(&program, &["--json"], Some(&paths.consumer_root), SWEEP_TIMEOUT)
            .map_err(|error| failed(error.to_string()))?;
        let candidates: Vec<Candidate> = serde_json::from_slice(&stdout)
            .map_err(|error| failed(format!("{program}: {error}", program = program.display())))?;
        outputs.push((sweep, candidates));
    }
    let snapshot = read_sweep_snapshot(paths, programs, commands, Utc::now())?;
    // The candidate comes back WITH the finding rather than being looked up by id afterwards:
    // `sweep-claims` and `sweep-stalled` both emit one object per `in_progress` bead, so a lookup
    // across the six answers the wrong sweep's candidate as often as the right one - and the
    // evidence four of the seven labels print then comes out `nil`.
    Ok(sweeps::findings_from(&outputs, &snapshot)
        .into_iter()
        .map(|(finding, candidate)| {
            let label = sweeps::label(&finding, candidate, &snapshot);
            Judged { finding, label }
        })
        .collect())
}

/// The fleet as `sweeps::Snapshot` wants it: every roster IMPLEMENTER whose state file parses and
/// whose pid is that agent's own session, plus the implementer names and the clock.
///
/// Liveness is `model::session_liveness` through `derive_fleet`, never a bare pid check - a
/// recycled pid would suppress a real finding here, which is the failure the marker sentence
/// exists to prevent.
///
/// It re-reads the roster and the process table the fleet pane read seconds ago, and that is
/// deliberate rather than an oversight: the snapshot must be taken AFTER the last script answers,
/// because the fleet moves while six scripts run and a candidate judged against a fleet six
/// scripts old is a finding about a session that has since started. Once per ten minutes, against
/// six subprocesses that ran first.
///
/// The names are the roster's IMPLEMENTERS alone, which is what `cerebro--roster` returns:
/// widening it to every agent would make `unassign` refuse to fire on any bead assigned to an
/// interactive agent's name - a silent nil, indistinguishable from a clean board.
fn read_sweep_snapshot(
    paths: &ReaderPaths,
    programs: &Programs,
    commands: &dyn CommandRunner,
    now: DateTime<Utc>,
) -> Result<Snapshot, ReadError> {
    let roster = read_roster(paths, commands)?;
    let states = read_states(paths, &roster);
    let processes = read_processes(programs, commands)?;
    let rows = model::derive_fleet(&roster, &states, &processes, &paths.shared_root);
    let implementers: Vec<String> = roster
        .iter()
        .filter(|entry| entry.kind == model::AgentKind::Implementer)
        .map(|entry| entry.name.clone())
        .collect();
    let live = rows
        .iter()
        .filter(|row| row.kind == model::AgentKind::Implementer)
        .filter_map(|row| {
            // A pid on the row means the state file parsed AND that pid is this agent's own
            // session - `cerebro--live-sessions`' rule, whatever the file then says.
            if row.pid.is_some() {
                return Some(LiveSession {
                    name: row.name.clone(),
                    state: Some(row.state.word().to_string()),
                    bead: row.bead.clone(),
                });
            }
            // A file that did not parse leaves `derive_fleet` no pid to report, and a running
            // session behind it. It is LIVE with no state, which is what the stalled sweep's
            // membership test needs: a half-written file must never become a finding against a
            // working implementer.
            model::any_live(&row.name, &paths.shared_root, &processes).then(|| LiveSession {
                name: row.name.clone(),
                state: None,
                bead: None,
            })
        })
        .collect();
    Ok(Snapshot { live, implementers, now })
}

/// Fixtures for this crate's own tests AND for the binary's: `main.rs` is a separate crate, so a
/// `#[cfg(test)]` item here would be invisible to it.
///
/// Nothing in here starts a process. That is the point of cb-x3u: a test about PARSING answers
/// from a table, and the real runner is proved once, in `tests/command_runner.rs`.
pub mod testing {
    use super::{CommandRunner, ReadError};
    use std::path::{Path, PathBuf};
    use std::sync::Mutex;
    use std::time::Duration;

    /// One call a reader made - what it ran, with what, where, and under which bound.
    ///
    /// The timeout is recorded rather than ignored: `GH_TIMEOUT`'s thirty seconds used to be
    /// asserted by nothing at all, because a bash fixture cannot see the bound it was run under.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Call {
        pub program: PathBuf,
        pub args: Vec<String>,
        pub cwd: Option<PathBuf>,
        pub timeout: Duration,
    }

    /// A `CommandRunner` that runs nothing: it answers from a function the test supplied, and
    /// records every call, so the argv assertions that used to live inside a bash fixture's
    /// `want=`/`got=` comparison are made directly in Rust.
    ///
    /// `Mutex`, not `RefCell`: `CommandRunner` is `Send + Sync` because a worker moves it to
    /// another thread.
    pub struct FakeCommands {
        answer: Box<dyn Fn(&Call) -> Result<Vec<u8>, ReadError> + Send + Sync>,
        calls: Mutex<Vec<Call>>,
    }

    impl FakeCommands {
        /// Answer every call with this function, which sees the whole `Call` and so can dispatch
        /// on the program or the argv the way a fixture script's `case` used to.
        pub fn new(
            answer: impl Fn(&Call) -> Result<Vec<u8>, ReadError> + Send + Sync + 'static,
        ) -> Self {
            Self { answer: Box::new(answer), calls: Mutex::new(Vec::new()) }
        }

        /// Answer every call with the same stdout - the common case.
        pub fn always(stdout: impl Into<Vec<u8>>) -> Self {
            let stdout = stdout.into();
            Self::new(move |_| Ok(stdout.clone()))
        }

        /// Fail every call the same way.
        pub fn failing(error: impl Fn() -> ReadError + Send + Sync + 'static) -> Self {
            Self::new(move |_| Err(error()))
        }

        /// What was run, in order.
        pub fn calls(&self) -> Vec<Call> {
            self.calls.lock().expect("no test panics while holding this").clone()
        }
    }

    impl CommandRunner for FakeCommands {
        fn run(
            &self,
            program: &Path,
            args: &[&str],
            cwd: Option<&Path>,
            timeout: Duration,
        ) -> Result<Vec<u8>, ReadError> {
            let call = Call {
                program: program.to_path_buf(),
                args: args.iter().map(|a| (*a).to_string()).collect(),
                cwd: cwd.map(Path::to_path_buf),
                timeout,
            };
            self.calls.lock().expect("no test panics while holding this").push(call.clone());
            (self.answer)(&call)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{Call, FakeCommands};
    use super::*;
    use crate::partition_beads;

    /// Nothing in this module starts a process any more (cb-x3u). Every case below answers from
    /// a `FakeCommands`, which is why there is no `TEST_TIMEOUT`, no `retry_if_text_busy` and no
    /// `write_executable` here: those three were the accumulated cost of testing PARSING by
    /// spawning. The real runner is proved in `tests/command_runner.rs`, and the one case that
    /// must run this checkout's own `scripts/roster` is in `tests/reader_contracts.rs`.

    fn paths_at(root: &Path) -> ReaderPaths {
        ReaderPaths {
            consumer_root: root.to_path_buf(),
            shared_root: root.join("shared"),
            scripts_dir: root.join("scripts"),
        }
    }

    fn exit(status: i32, stderr: &str) -> ReadError {
        ReadError::Exit {
            source: "fake".into(),
            status: Some(status),
            stderr: stderr.into(),
            stdout: String::new(),
        }
    }

    fn ids(beads: &[Bead]) -> Vec<&str> {
        beads.iter().map(|b| b.id.as_str()).collect()
    }

    /// The seam itself: a reader runs the program it is meant to, with the argv it is meant to,
    /// in the directory it is meant to, under the bound it is meant to - and parses what came
    /// back. Everything the bash fixtures used to check with `want=`/`got=`, checked in Rust.
    #[test]
    fn readers_run_through_the_injected_runner() {
        let fake = FakeCommands::always("Xavier\tplanner\tinteractive\n");
        let paths = paths_at(Path::new("/consumer"));

        let roster = read_roster(&paths, &fake).unwrap();
        assert_eq!(roster.len(), 1);
        assert_eq!(roster[0].name, "Xavier");

        let calls = fake.calls();
        assert_eq!(calls.len(), 1, "one program, run once");
        assert!(calls[0].program.ends_with("roster"), "{:?}", calls[0].program);
        assert!(calls[0].args.is_empty());
        assert_eq!(calls[0].cwd.as_deref(), Some(paths.consumer_root.as_path()));
        assert_eq!(calls[0].timeout, Duration::from_secs(5));
    }


    #[test]
    fn state_files_surface_missing_invalid_and_parsed_rows() {
        let dir = tempfile::tempdir().unwrap();
        let state_dir = dir.path().join(".cerebro/state");
        std::fs::create_dir_all(&state_dir).unwrap();
        std::fs::write(
            state_dir.join("Parsed.state.json"),
            r#"{"state":"working","phase":"build","bead":"cb-1","since":"2026-01-01T00:00:00Z","phase_since":null,"pid":42}"#,
        )
        .unwrap();
        std::fs::write(state_dir.join("Invalid.state.json"), "{ not json").unwrap();
        // "Missing" gets no file at all.

        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().to_path_buf(),
            scripts_dir: dir.path().to_path_buf(),
        };
        let roster = vec![
            RosterEntry { name: "Parsed".into(), role: "r".into(), kind: model::AgentKind::Interactive },
            RosterEntry { name: "Invalid".into(), role: "r".into(), kind: model::AgentKind::Interactive },
            RosterEntry { name: "Missing".into(), role: "r".into(), kind: model::AgentKind::Interactive },
        ];
        let states = read_states(&paths, &roster);

        match states.get("Parsed").unwrap() {
            StateObservation::Parsed(record) => {
                assert_eq!(record.state, "working");
                assert_eq!(record.pid, 42);
            }
            other => panic!("expected Parsed, got {other:?}"),
        }
        match states.get("Invalid").unwrap() {
            StateObservation::Invalid(message) => assert!(message.contains("Invalid.state.json")),
            other => panic!("expected Invalid, got {other:?}"),
        }
        assert_eq!(states.get("Missing"), Some(&StateObservation::Missing));
    }

    #[test]
    fn padded_ps_output_feeds_process_derivation() {
        let fake = FakeCommands::always(
            "    1     0 /sbin/launchd\n  123     1 some prog --flag a  b\n",
        );
        let rows = read_processes(&Programs::default(), &fake).unwrap();
        assert_eq!(
            rows,
            vec![
                ProcessRow { pid: 1, ppid: Some(0), args: "/sbin/launchd".into() },
                ProcessRow { pid: 123, ppid: Some(1), args: "some prog --flag a  b".into() },
            ]
        );

        // `cerebro--system-processes`'s own argv, and no working directory: `ps` answers about
        // the machine, not about a checkout.
        let calls = fake.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].args, vec!["-axo", "pid=,ppid=,args="]);
        assert_eq!(calls[0].cwd, None);
    }

    #[test]
    fn ps_exit_failure_preserves_stderr() {
        let fake = FakeCommands::failing(|| exit(3, "ps: boom"));
        let err = read_processes(&Programs::default(), &fake).unwrap_err();
        match err {
            ReadError::Exit { status, stderr, .. } => {
                assert_eq!(status, Some(3));
                assert!(stderr.contains("boom"));
            }
            other => panic!("expected Exit, got {other:?}"),
        }
    }

    /// A spawn failure passes through as itself; invalid UTF-8 becomes the READER's own
    /// `Invalid`, because decoding is the reader's job and not the runner's.
    #[test]
    fn readers_report_spawn_and_decode_failures() {
        let spawn_failed = FakeCommands::failing(|| ReadError::Spawn {
            source: "/does/not/exist/ps".into(),
            message: "No such file or directory".into(),
        });
        assert!(matches!(
            read_processes(&Programs::default(), &spawn_failed),
            Err(ReadError::Spawn { .. })
        ));

        let not_utf8 = FakeCommands::always(vec![0xff]);
        assert!(matches!(
            read_processes(&Programs::default(), &not_utf8),
            Err(ReadError::Invalid { .. })
        ));
    }

    /// The declaration reader: both words, and the refusal that is still an answer (cb-kcs.1).
    #[test]
    fn configured_supervisor_reader_preserves_default_invalid_and_shared_root() {
        let paths = paths_at(Path::new("/consumer"));

        assert_eq!(
            read_configured_supervisor(&paths, &FakeCommands::always("emacs\n")).unwrap(),
            Ok(SupervisorKind::Emacs)
        );
        assert_eq!(
            read_configured_supervisor(&paths, &FakeCommands::always("tui\n")).unwrap(),
            Ok(SupervisorKind::Tui)
        );

        // The refusal is an answer: exit 2 with the RAW value on stdout, which survives and is
        // NOT rounded to the default.
        let refused = FakeCommands::failing(|| ReadError::Exit {
            source: "fleet-supervisor".into(),
            status: Some(2),
            stderr: "invalid".into(),
            stdout: "rat\n".into(),
        });
        assert_eq!(
            read_configured_supervisor(&paths, &refused).unwrap(),
            Err("rat".to_string())
        );

        let calls = refused.calls();
        assert!(calls[0].program.ends_with("fleet-supervisor"), "{:?}", calls[0].program);
        assert_eq!(calls[0].cwd.as_deref(), Some(paths.consumer_root.as_path()));
    }

    /// A reader that cannot run at all is an error, never `emacs`. Fail-open here is the one
    /// failure cb-kcs.1 exists to refuse.
    #[test]
    fn a_missing_supervisor_script_is_an_error_not_a_default() {
        let paths = paths_at(Path::new("/consumer"));
        let missing = FakeCommands::failing(|| ReadError::Spawn {
            source: "fleet-supervisor".into(),
            message: "No such file or directory".into(),
        });
        assert!(read_configured_supervisor(&paths, &missing).is_err());
        assert!(read_supervisor_endpoint(&paths, &missing).is_err());
    }

    /// The panel's whole `bd` argv, which `--readonly` and the explicit `-C <shared root>` are
    /// mandatory parts of: `bd` answers about whatever repository it runs in and defaults to open
    /// beads only (`scripts/work-beads:17-29`).
    fn bd_argv(shared: &Path) -> Vec<String> {
        [
            "--readonly",
            "-C",
            shared.to_string_lossy().as_ref(),
            "list",
            "--status",
            "open,in_progress,blocked,deferred,closed",
            "--json",
            "--brief",
        ]
        .iter()
        .map(|a| (*a).to_string())
        .collect()
    }

    #[test]
    fn bd_reader_uses_shared_root_all_statuses_and_readonly() {
        let fake = FakeCommands::always(
            r#"[{"id":"cb-1","title":"t","status":"open","issue_type":"feature","labels":[],"priority":1,"updated_at":null,"assignee":null}]"#,
        );
        let paths = paths_at(Path::new("/consumer"));
        let beads = read_beads(&paths, &Programs::default(), &fake).unwrap();
        assert_eq!(beads.len(), 1);
        assert_eq!(beads[0].id, "cb-1");
        assert_eq!(partition_beads(beads).unplanned.len(), 1);

        let calls = fake.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].args, bd_argv(&paths.shared_root));
    }

    #[test]
    fn bd_reader_reports_invalid_json() {
        let paths = paths_at(Path::new("/consumer"));
        assert!(matches!(
            read_beads(&paths, &Programs::default(), &FakeCommands::always("")),
            Err(ReadError::Invalid { .. })
        ));
    }

    /// A non-zero `bd` is preserved as itself. That the argv it refuses on is the panel's own is
    /// `bd_reader_uses_shared_root_all_statuses_and_readonly`'s claim, and since cb-x3u it is
    /// made against `fake.calls()` rather than inside a fixture's `want=`/`got=`.
    #[test]
    fn bd_reader_preserves_a_non_zero_exit() {
        let paths = paths_at(Path::new("/consumer"));
        let fake = FakeCommands::failing(|| exit(2, "bd: refusing"));
        let err = read_beads(&paths, &Programs::default(), &fake).unwrap_err();
        match err {
            ReadError::Exit { status, stderr, .. } => {
                assert_eq!(status, Some(2));
                assert!(stderr.contains("refusing"));
            }
            other => panic!("expected Exit, got {other:?}"),
        }
    }

    // --- cb-vyp.2: the aggregate fleet read ------------------------------------------------------

    /// A roster, a REAL state file and a `ps` table that agree, read in one call: the row for a
    /// state file whose pid carries this consumer's marker is the state file's own, and the row
    /// for an agent with neither is dead.
    ///
    /// The state file stays a real file in a `TempDir`: `read_states` reads files and starts no
    /// process, so no fake covers it and it was never part of the defect cb-x3u removed. The
    /// marker is built by `model::marker_sentence`, never typed - which is also why this case
    /// stays a UNIT test: that function is `pub(crate)`, and this crate spells the sentence in
    /// one file, which `scripts/marker-readers` holds it to.
    #[test]
    fn fleet_reader_composes_roster_states_and_processes() {
        let dir = tempfile::tempdir().unwrap();
        let shared = dir.path().join("shared");
        std::fs::create_dir_all(shared.join(".cerebro/state")).unwrap();
        std::fs::write(
            shared.join(".cerebro/state/Xavier.state.json"),
            r#"{"state":"working","phase":"plan","bead":"cb-kcs","since":"2026-01-01T00:00:00Z","phase_since":"2026-01-01T00:10:00Z","pid":4242}"#,
        )
        .unwrap();

        let marker = format!("claude {}", model::marker_sentence("Xavier", &shared));
        let ps_table = format!(" 4242     1 {marker}\n");
        let fake = FakeCommands::new(move |call: &Call| {
            if call.program.ends_with("roster") {
                Ok(b"Xavier\tplanner\tinteractive\nStorm\timplementer\timplementer\n".to_vec())
            } else {
                Ok(ps_table.clone().into_bytes())
            }
        });

        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: shared,
            scripts_dir: dir.path().join("scripts"),
        };
        let rows = read_fleet(&paths, &Programs::default(), &fake).unwrap();

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name, "Xavier");
        assert_eq!(rows[0].state, model::RowState::Working);
        assert_eq!(rows[0].phase.as_deref(), Some("plan"));
        assert_eq!(rows[0].bead.as_deref(), Some("cb-kcs"));
        assert_eq!(rows[0].sessions, 1);
        assert_eq!(rows[1].name, "Storm");
        assert_eq!(rows[1].state, model::RowState::Dead);
    }

    /// Every way the aggregate read can fail comes back as a failure. `Ok(vec![])` would render
    /// as a fleet in which every agent is dead - the most alarming screen this view can draw, and
    /// a lie.
    #[test]
    fn fleet_reader_failure_is_not_an_empty_snapshot() {
        let paths = paths_at(Path::new("/consumer"));

        // `ps` fails: the roster read succeeded, and the fleet is still unavailable rather than a
        // roster's worth of dead rows.
        let ps_broken = FakeCommands::new(|call: &Call| {
            if call.program.ends_with("roster") {
                Ok(b"Xavier\tplanner\tinteractive\n".to_vec())
            } else {
                Err(ReadError::Exit {
                    source: "ps".into(),
                    status: Some(3),
                    stderr: "ps: boom".into(),
                    stdout: String::new(),
                })
            }
        });
        match read_fleet(&paths, &Programs::default(), &ps_broken) {
            Err(ReadError::Exit { status, stderr, .. }) => {
                assert_eq!(status, Some(3));
                assert!(stderr.contains("boom"));
            }
            other => panic!("expected the ps failure, got {other:?}"),
        }

        // The roster fails: the same, and the error still names the roster.
        let roster_broken = FakeCommands::new(|call: &Call| {
            if call.program.ends_with("roster") {
                Err(ReadError::Exit {
                    source: call.program.display().to_string(),
                    status: Some(2),
                    stderr: "roster: refusing".into(),
                    stdout: String::new(),
                })
            } else {
                Ok(Vec::new())
            }
        });
        match read_fleet(&paths, &Programs::default(), &roster_broken) {
            Err(ReadError::Exit { status, source, .. }) => {
                assert_eq!(status, Some(2));
                assert!(source.ends_with("roster"), "expected the roster to be named: {source}");
            }
            other => panic!("expected the roster failure, got {other:?}"),
        }
    }

    // --- cb-vyp.3: the aggregate work read -------------------------------------------------------

    /// One bead per bucket, from the one answer the panel gets.
    const BUCKETED_BEADS: &str = r#"[
      {"id":"cb-claimed","title":"being built","status":"in_progress","issue_type":"feature","labels":[],"priority":1,"updated_at":null,"assignee":"Cyclops"},
      {"id":"cb-planned","title":"ready","status":"open","issue_type":"feature","labels":["planned"],"priority":2,"updated_at":null,"assignee":null},
      {"id":"cb-held","title":"mid-plan","status":"open","issue_type":"feature","labels":["planning:Xavier"],"priority":2,"updated_at":null,"assignee":null},
      {"id":"cb-new","title":"filed","status":"open","issue_type":"bug","labels":[],"priority":4,"updated_at":null,"assignee":null},
      {"id":"cb-human","title":"parked","status":"open","issue_type":"feature","labels":["human"],"priority":2,"updated_at":null,"assignee":null},
      {"id":"cb-merged","title":"landed","status":"closed","issue_type":"feature","labels":[],"priority":1,"updated_at":"2026-01-01T00:00:00Z","assignee":null},
      {"id":"cb-epic","title":"a family","status":"open","issue_type":"epic","labels":[],"priority":1,"updated_at":null,"assignee":null}]"#;

    #[test]
    fn work_reader_returns_the_partitioned_single_bd_answer() {
        let fake = FakeCommands::always(BUCKETED_BEADS);
        let paths = paths_at(Path::new("/consumer"));

        let work = read_work(&paths, &Programs::default(), &fake).unwrap();
        assert_eq!(ids(&work.claimed), ["cb-claimed"]);
        assert_eq!(ids(&work.planned), ["cb-planned"]);
        assert_eq!(ids(&work.being_planned), ["cb-held"]);
        assert_eq!(ids(&work.unplanned), ["cb-new"]);
        assert_eq!(ids(&work.paused), ["cb-human"]);
        assert_eq!(ids(&work.merged), ["cb-merged"]);

        // Exactly one `bd` run, with the panel's whole argv - the shared root, every status,
        // `--readonly` and `--brief`.
        let calls = fake.calls();
        assert_eq!(calls.len(), 1, "one `bd` answer, not one per bucket");
        assert_eq!(calls[0].args, bd_argv(&paths.shared_root));
    }

    /// A `bd` that exits non-zero is a failure, not six empty queues: an empty board and an
    /// unreadable one are opposite screens.
    #[test]
    fn work_reader_preserves_bd_failure() {
        let paths = paths_at(Path::new("/consumer"));
        let fake = FakeCommands::failing(|| exit(1, "bd list failed: database is locked"));
        match read_work(&paths, &Programs::default(), &fake) {
            Err(ReadError::Exit { status, stderr, .. }) => {
                assert_eq!(status, Some(1));
                assert!(stderr.contains("database is locked"), "{stderr}");
            }
            other => panic!("expected the bd failure, got {other:?}"),
        }
    }

    #[test]
    fn work_reader_rejects_invalid_json() {
        let paths = paths_at(Path::new("/consumer"));
        assert!(matches!(
            read_work(&paths, &Programs::default(), &FakeCommands::always("bd: nothing to list\n")),
            Err(ReadError::Invalid { .. })
        ));
    }

    /// A `bd` that never answers surfaces as the timeout it was, not as an empty board: without
    /// the bound the Work pane would say `refreshing...` forever, since the request is in flight
    /// and no later tick replaces it. That the timed-out child is also KILLED AND REAPED is the
    /// runner's own contract, proved in `tests/command_runner.rs`.
    #[test]
    fn work_reader_timeout_kills_and_reaps_bd() {
        let paths = paths_at(Path::new("/consumer"));
        let fake = FakeCommands::failing(|| ReadError::Timeout {
            source: "/somewhere/bd".into(),
            seconds: 5,
        });
        match read_work(&paths, &Programs::default(), &fake) {
            Err(ReadError::Timeout { seconds, source }) => {
                assert_eq!(seconds, 5);
                assert!(source.ends_with("bd"), "the failure names the program: {source}");
            }
            other => panic!("expected Timeout, got {other:?}"),
        }
    }

    // --- the roster's declaration and the project's spacing (cb-kcs.4.1) -----------------------

    #[test]
    fn the_roster_declares_what_to_start_and_what_to_arm() {
        let paths = paths_at(Path::new("/consumer"));
        let fake = FakeCommands::new(|call: &Call| match call.args.first().map(String::as_str) {
            Some("--autostart") => Ok(b"Cyclops\nRogue\n".to_vec()),
            Some("--standby") => Ok(b"Xavier\nBeast\n".to_vec()),
            _ => Ok(b"Cyclops\timplementer\timplementer\n".to_vec()),
        });

        assert_eq!(
            read_autostart_names(&paths, &fake).unwrap(),
            vec!["Cyclops".to_string(), "Rogue".to_string()]
        );
        assert_eq!(
            read_standby_names(&paths, &fake).unwrap(),
            vec!["Xavier".to_string(), "Beast".to_string()]
        );

        // One flag each, and nothing else: two reads of one declaration.
        let calls = fake.calls();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].args, vec!["--autostart"]);
        assert_eq!(calls[1].args, vec!["--standby"]);
    }

    #[test]
    fn project_conf_declares_the_role_spacing_and_names_a_bad_one() {
        let paths = paths_at(Path::new("/consumer"));
        let fake = FakeCommands::new(|call: &Call| match call.args.first().map(String::as_str) {
            Some("role_start_spacing_planner") => Ok(b"45\n".to_vec()),
            Some("role_start_spacing_implementer") => Ok(b"30s\n".to_vec()),
            Some("role_start_spacing_verifier") => Err(ReadError::Exit {
                source: "project-conf".into(),
                status: Some(1),
                stderr: String::new(),
                stdout: String::new(),
            }),
            _ => Ok(b"\n".to_vec()),
        });

        let (declared, complaints) = read_role_spacing(
            &paths,
            &["planner", "implementer", "verifier", "orchestrator"],
            &fake,
        );
        assert_eq!(declared.get("planner"), Some(&45));
        // A non-zero exit is "declared nothing", not an error.
        assert_eq!(declared.get("verifier"), None);
        assert_eq!(declared.get("orchestrator"), None);
        // A value that is not a whole number of seconds is a third answer, said out loud once.
        assert_eq!(declared.get("implementer"), None);
        assert_eq!(
            complaints,
            vec![
                "project.conf: role_start_spacing_implementer is not a whole number of seconds (\"30s\"); using 30.".to_string()
            ]
        );
    }

    // --- the gh reader (cb-kcs.4.3) ------------------------------------------------------------

    /// A fake `gh`, dispatching on the argv the reader passed. Nothing here may reach the
    /// network, which nothing here could: no process is started at all.
    fn fake_gh(me_fails: bool) -> FakeCommands {
        FakeCommands::new(move |call: &Call| {
            if call.args == GH_ISSUES_ARGV {
                Ok(br#"[{"number":212,"updatedAt":"2026-09-01T10:00:00Z"}]"#.to_vec())
            } else if call.args == GH_PRS_ARGV {
                Ok(br#"[{"number":244,"updatedAt":"2026-09-01T10:00:00Z","isDraft":false,"author":{"login":"someone"}}]"#.to_vec())
            } else if call.args == GH_ME_ARGV {
                if me_fails {
                    Err(ReadError::Exit {
                        source: "gh".into(),
                        status: Some(4),
                        stderr: "gh: not logged in".into(),
                        stdout: String::new(),
                    })
                } else {
                    Ok(b"navigator\n".to_vec())
                }
            } else {
                panic!("unexpected gh argv: {:?}", call.args)
            }
        })
    }

    #[test]
    fn gh_answers_with_what_is_open_and_who_you_are() {
        let fake = fake_gh(false);
        let paths = paths_at(Path::new("/consumer"));
        let mut me = None;

        let snapshot = read_gh(&paths, &Programs::default(), &mut me, &fake).unwrap();
        assert_eq!(snapshot.issues[0].number, 212);
        assert_eq!(snapshot.prs[0].number, 244);
        assert_eq!(snapshot.me.as_deref(), Some("navigator"));

        let calls = fake.calls();
        assert_eq!(calls[0].args, GH_ISSUES_ARGV);
        assert_eq!(calls[1].args, GH_PRS_ARGV);
        assert_eq!(calls[2].args, GH_ME_ARGV);

        // Thirty seconds, not `COMMAND_TIMEOUT`'s five: these are network calls, and a slow
        // answer read as a failure would put `gh?` on two rows. A bash fixture cannot see the
        // bound it was run under, so until cb-x3u this constant was asserted by nothing.
        for call in &calls {
            assert_eq!(call.timeout, Duration::from_secs(30), "{:?}", call.args);
            assert_eq!(call.cwd.as_deref(), Some(paths.consumer_root.as_path()));
        }

        // The login answers the same thing for the life of the process, so it is asked for until
        // it answers and then never again.
        read_gh(&paths, &Programs::default(), &mut me, &fake).unwrap();
        assert_eq!(
            fake.calls().iter().filter(|c| c.args == GH_ME_ARGV).count(),
            1,
            "the learnt login is not asked for again"
        );
    }

    #[test]
    fn a_failed_issue_list_is_a_failed_read() {
        let fake = FakeCommands::failing(|| exit(1, "gh: rate limited"));
        let paths = paths_at(Path::new("/consumer"));
        let mut me = None;
        let err = read_gh(&paths, &Programs::default(), &mut me, &fake).unwrap_err();
        match err {
            ReadError::Exit { stderr, .. } => assert!(stderr.contains("rate limited")),
            other => panic!("expected Exit, got {other:?}"),
        }
    }

    #[test]
    fn a_failed_login_leaves_the_lists_answering() {
        let fake = fake_gh(true);
        let paths = paths_at(Path::new("/consumer"));
        let mut me = None;
        let snapshot = read_gh(&paths, &Programs::default(), &mut me, &fake)
            .expect("the two lists answered");
        assert_eq!(snapshot.issues.len(), 1);
        assert_eq!(snapshot.me, None, "and the login is still unknown");
    }
    // --- the six sweeps ------------------------------------------------------------------

    /// Every sweep answers `[]`, the roster and `ps` answer nothing interesting. The scripts are
    /// run in `Sweep::ALL` order, with `--json`, from the consumer root, under `SWEEP_TIMEOUT`.
    #[test]
    fn an_empty_sweep_is_an_answer() {
        let paths = paths_at(Path::new("/repo"));
        let commands = FakeCommands::new(|call: &Call| {
            let program = call.program.file_name().unwrap().to_string_lossy().into_owned();
            match program.as_str() {
                "roster" => Ok(b"Cyclops\timplementer\timplementer\n".to_vec()),
                "ps" => Ok(Vec::new()),
                _ => Ok(b"[]".to_vec()),
            }
        });
        assert_eq!(read_sweeps(&paths, &Programs::default(), &commands).unwrap(), Vec::new());
        let sweeps: Vec<(String, Vec<String>, Duration)> = commands
            .calls()
            .into_iter()
            .filter(|call| call.program.to_string_lossy().contains("sweep-"))
            .map(|call| {
                (
                    call.program.file_name().unwrap().to_string_lossy().into_owned(),
                    call.args.clone(),
                    call.timeout,
                )
            })
            .collect();
        assert_eq!(
            sweeps.iter().map(|(name, ..)| name.as_str()).collect::<Vec<_>>(),
            vec![
                "sweep-claims.sh",
                "sweep-epics.sh",
                "sweep-stalled.sh",
                "sweep-assignees.sh",
                "sweep-verdicts.sh",
                "sweep-paused.sh",
            ]
        );
        for (name, args, timeout) in &sweeps {
            assert_eq!(args, &vec!["--json".to_string()], "{name}");
            // Not `COMMAND_TIMEOUT`: three of the six `git fetch`, and five seconds would print
            // `sweep-claims failed` on any slow network.
            assert_eq!(*timeout, Duration::from_secs(120), "{name}");
        }
    }

    /// The chain stops at the first script that does not answer, names it in the one word the
    /// header shows, and starts no later script - which is what lets the header name exactly one.
    #[test]
    fn a_sweep_that_does_not_answer_stops_the_chain_and_names_itself() {
        let paths = paths_at(Path::new("/repo"));
        let commands = FakeCommands::new(|call: &Call| {
            let program = call.program.file_name().unwrap().to_string_lossy().into_owned();
            match program.as_str() {
                "sweep-stalled.sh" => Err(exit(1, "bd is not on PATH")),
                "roster" => Ok(b"Cyclops\timplementer\timplementer\n".to_vec()),
                "ps" => Ok(Vec::new()),
                _ => Ok(b"[]".to_vec()),
            }
        });
        let error = read_sweeps(&paths, &Programs::default(), &commands).unwrap_err();
        assert!(matches!(&error, ReadError::Sweep { script, .. } if script == "sweep-stalled"));
        assert_eq!(error.to_string(), "sweep-stalled failed");
        // One word on the header, the whole failure in the log: the navigator chose the first,
        // and the second is what makes a red section diagnosable at all.
        let cause = error.cause().expect("a sweep failure carries its cause");
        assert!(cause.contains("bd is not on PATH"), "{cause:?}");
        let ran: Vec<String> = commands
            .calls()
            .into_iter()
            .map(|call| call.program.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert!(!ran.iter().any(|name| name == "sweep-assignees.sh"), "{ran:?}");
        // And no snapshot was taken either: a chain that stopped has nothing to judge.
        assert!(!ran.iter().any(|name| name == "roster"), "{ran:?}");
    }

    /// Exit zero and a body that is not the JSON array it promised. Falling back to an empty
    /// vector here would draw a clean fleet for a script nobody could read.
    #[test]
    fn a_sweep_that_prints_garbage_is_a_failure_not_an_empty_answer() {
        let paths = paths_at(Path::new("/repo"));
        let commands = FakeCommands::new(|call: &Call| {
            let program = call.program.file_name().unwrap().to_string_lossy().into_owned();
            match program.as_str() {
                "sweep-claims.sh" => Ok(b"not json".to_vec()),
                _ => Ok(b"[]".to_vec()),
            }
        });
        let error = read_sweeps(&paths, &Programs::default(), &commands).unwrap_err();
        assert_eq!(error.to_string(), "sweep-claims failed");
        // And the parse error is kept too, which is the one cause a re-run cannot show you.
        let cause = error.cause().expect("a sweep failure carries its cause");
        assert!(cause.contains("sweep-claims.sh"), "{cause:?}");
    }

    /// Two sweeps list the same bead - `sweep-claims` and `sweep-stalled` both emit one object per
    /// `in_progress` bead - so a candidate looked up by id after the judging is the wrong sweep's
    /// as often as the right one, and the evidence the label prints comes out `nil`
    /// (`no start for nilm`). The shared table cannot catch this: every row of it feeds exactly
    /// one sweep.
    #[test]
    fn a_finding_is_labelled_from_its_own_sweeps_candidate() {
        let paths = ReaderPaths {
            shared_root: PathBuf::from("/repo/shared"),
            ..paths_at(Path::new("/repo"))
        };
        let commands = FakeCommands::new(|call: &Call| {
            let program = call.program.file_name().unwrap().to_string_lossy().into_owned();
            match program.as_str() {
                "roster" => Ok(b"Storm\timplementer\timplementer\n".to_vec()),
                // Storm is running, which is what makes the stalled sweep the one with something
                // to say about this bead and the claims sweep the one with nothing.
                "ps" => Ok(format!(
                    "{pid} 1 claude This session is Storm of the cerebro fleet rooted at /repo/shared/.\n",
                    pid = std::process::id()
                )
                .into_bytes()),
                // The same bead, from both sweeps, exactly as the two scripts emit it.
                "sweep-claims.sh" => Ok(br#"[{"id":"cb-x","assignee":"Storm","on_main":false,
                    "lease_age_min":300}]"#
                    .to_vec()),
                "sweep-stalled.sh" => Ok(br#"[{"id":"cb-x","assignee":"Storm",
                    "progress_age_min":300,"progress_source":"commit"}]"#
                    .to_vec()),
                _ => Ok(b"[]".to_vec()),
            }
        });
        let findings = read_sweeps(&paths, &Programs::default(), &commands).unwrap();
        assert_eq!(findings.len(), 1, "{findings:#?}");
        assert_eq!(
            findings[0].label,
            "unclaim cb-x — Storm stalled, no commit for 300m",
            "the claims candidate carries neither the age nor the source"
        );
    }

    /// The snapshot's names are the roster's IMPLEMENTERS alone. An interactive agent's name on a
    /// bead was put there by hand, and undoing that is not this view's to do.
    #[test]
    fn the_snapshot_counts_only_implementers() {
        let paths = paths_at(Path::new("/repo"));
        let commands = FakeCommands::new(|call: &Call| {
            let program = call.program.file_name().unwrap().to_string_lossy().into_owned();
            match program.as_str() {
                "roster" => Ok(b"Xavier\tplanner\tinteractive\nCyclops\timplementer\timplementer\n".to_vec()),
                "ps" => Ok(Vec::new()),
                "sweep-assignees.sh" => Ok(br#"[{"id":"cb-a","assignee":"Xavier","age_min":300,
                    "priority":0},{"id":"cb-b","assignee":"Cyclops","age_min":300,"priority":0}]"#
                    .to_vec()),
                _ => Ok(b"[]".to_vec()),
            }
        });
        let findings = read_sweeps(&paths, &Programs::default(), &commands).unwrap();
        assert_eq!(
            findings.iter().map(|j| j.finding.id()).collect::<Vec<_>>(),
            vec!["cb-b"]
        );
        // And the label is the one the shared table pins, built from the candidate this finding
        // was judged from rather than from any other.
        assert_eq!(findings[0].label, "unassign cb-b — Cyclops is not running");
    }
}
