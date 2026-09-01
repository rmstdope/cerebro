//! Filesystem and subprocess I/O, kept apart from `crate::model`'s pure parsing/derivation.
//!
//! Read-only by construction: every function here reads a file or runs a read-only external
//! program (`scripts/roster`, `ps`, `bd --readonly`) and returns data for `crate::model` to
//! parse. Nothing here writes a file, launches, stops, triggers, supervises, or cleans up state -
//! Emacs remains the sole supervisor (cb-vyp.1's own scope).

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use wait_timeout::ChildExt;

use crate::model::{
    self, Bead, FleetRow, ProcessRow, RosterEntry, StateInputs, StateObservation, StateRecord,
    WorkBuckets,
};

/// How long a reader's child may run before it is killed and reported as a failure.
///
/// A `roster` that blocks on a lock, or a `ps` that never returns, would otherwise leave the
/// screen saying `refreshing...` forever: the request is in flight, so no later tick can replace
/// it, and nothing on screen says anything is wrong. Five seconds is far longer than either
/// program has ever taken and short enough that the next five-second tick is the recovery.
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
}

impl Default for Programs {
    fn default() -> Self {
        Self {
            bd: PathBuf::from("bd"),
            ps: PathBuf::from("ps"),
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
    },
    Invalid { source: String, message: String },
    Timeout { source: String, seconds: u64 },
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Spawn { source, message } => write!(f, "could not run {source}: {message}"),
            Self::Exit { source, status, stderr } =>
                write!(f, "{source} exited with status {status:?}: {stderr}"),
            Self::Invalid { source, message } =>
                write!(f, "{source} produced invalid output: {message}"),
            Self::Timeout { source, seconds } =>
                write!(f, "{source} did not answer within {seconds}s"),
        }
    }
}

impl std::error::Error for ReadError {}

fn run(program: &Path, args: &[&str], cwd: Option<&Path>) -> Result<Vec<u8>, ReadError> {
    run_with_timeout(program, args, cwd, COMMAND_TIMEOUT)
}

/// `run`, with the wall-clock bound as a parameter so a test can prove the kill-and-reap path in
/// milliseconds rather than in the five production seconds.
///
/// Both pipes are drained on their own threads *before* anything waits: a child that fills a pipe
/// blocks writing while the parent blocks waiting, which is a deadlock no timeout can see, since
/// the child is not idle - it is running, waiting on us. A timed-out child is killed and then
/// waited for, so no zombie is left behind.
fn run_with_timeout(
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
        });
    }
    Ok(stdout)
}

/// The roster, via `<scripts_dir>/roster` - the one place the fleet is declared
/// (`emacs/cerebro.el:117-129`).
pub fn read_roster(paths: &ReaderPaths) -> Result<Vec<RosterEntry>, ReadError> {
    let program = paths.scripts_dir.join("roster");
    let stdout = run(&program, &[], Some(&paths.consumer_root))?;
    let text = String::from_utf8(stdout).map_err(|e| ReadError::Invalid {
        source: program.display().to_string(),
        message: e.to_string(),
    })?;
    model::parse_roster(&text).map_err(|e| ReadError::Invalid {
        source: program.display().to_string(),
        message: e.to_string(),
    })
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
        let path = paths
            .shared_root
            .join(".cerebro/state")
            .join(format!("{}.state.json", entry.name));
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
pub fn read_processes(programs: &Programs) -> Result<Vec<ProcessRow>, ReadError> {
    let stdout = run(&programs.ps, &["-axo", "pid=,ppid=,args="], None)?;
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
pub fn read_beads(paths: &ReaderPaths, programs: &Programs) -> Result<Vec<Bead>, ReadError> {
    read_beads_with_timeout(paths, programs, COMMAND_TIMEOUT)
}

/// `read_beads`, with the wall-clock bound as a parameter. Crate-private: production reads go
/// through the five-second boundary above, and only a test injects a shorter one so the
/// kill-and-reap path costs a second rather than five.
fn read_beads_with_timeout(
    paths: &ReaderPaths,
    programs: &Programs,
    timeout: Duration,
) -> Result<Vec<Bead>, ReadError> {
    let root = paths.shared_root.to_string_lossy().into_owned();
    let stdout = run_with_timeout(
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
        timeout,
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
pub fn read_work(paths: &ReaderPaths, programs: &Programs) -> Result<WorkBuckets, ReadError> {
    read_work_with_timeout(paths, programs, COMMAND_TIMEOUT)
}

fn read_work_with_timeout(
    paths: &ReaderPaths,
    programs: &Programs,
    timeout: Duration,
) -> Result<WorkBuckets, ReadError> {
    Ok(model::partition_beads(read_beads_with_timeout(
        paths, programs, timeout,
    )?))
}

/// The whole fleet in one read: roster, every state file, the process table - fed to
/// `model::derive_fleet` against the SHARED root, which is both where the state files live and
/// what `scripts/launch` roots every session's marker sentence at (`scripts/agent-alive:61-107`).
///
/// One call rather than three, because a screen showing rows read at three different moments is a
/// screen that can show a bead in a row whose process scan predates the claim. A failure in
/// either subprocess is returned as itself: a fleet that could not be read is never an empty
/// fleet, which would read as "every agent is dead".
pub fn read_fleet(paths: &ReaderPaths, programs: &Programs) -> Result<Vec<FleetRow>, ReadError> {
    let roster = read_roster(paths)?;
    let states = read_states(paths, &roster);
    let processes = read_processes(programs)?;
    Ok(model::derive_fleet(
        &roster,
        &states,
        &processes,
        &paths.shared_root,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::partition_beads;
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("fleet-view has a parent directory")
            .to_path_buf()
    }

    /// Linux's ETXTBSY, and why every fixture spawn below goes through this.
    ///
    /// `exec` of a file fails with `ETXTBSY` while ANY process still holds a writable descriptor
    /// for it. Cargo runs these tests as threads of one process, so the window is not this test's
    /// own write - `write_executable` closes its handle before it returns - but any OTHER test
    /// that forks during it: `fork` duplicates every descriptor, so a child sitting between fork
    /// and exec is holding our write handle open on its behalf. It closes a moment later
    /// (`O_CLOEXEC`), which is what makes this transient and worth retrying rather than a defect
    /// in the code under test.
    ///
    /// Observed on main as a red `Rust tests` job on ubuntu-latest, 2026-09-01: `Spawn { source:
    /// "/tmp/.tmpIsHhre/bd", message: "Text file busy (os error 26)" }`. macOS does not enforce
    /// ETXTBSY the same way, which is why the whole local gate was green.
    ///
    /// The retry is on the *error*, not on the operation: a genuine spawn failure still fails,
    /// and a test whose fixture sleeps is never re-run, because a timeout is not this error.
    fn retry_if_text_busy<T>(mut call: impl FnMut() -> Result<T, ReadError>) -> Result<T, ReadError> {
        const TEXT_FILE_BUSY: &str = "os error 26";
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            match call() {
                Err(ReadError::Spawn { source, message })
                    if message.contains(TEXT_FILE_BUSY) && std::time::Instant::now() < deadline =>
                {
                    let _ = source;
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                other => return other,
            }
        }
    }

    fn write_executable(dir: &Path, name: &str, script: &str) -> PathBuf {
        let path = dir.join(name);
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(script.as_bytes()).unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        path
    }

    #[test]
    fn real_roster_output_feeds_fleet_derivation() {
        let root = repo_root();
        let paths = ReaderPaths {
            consumer_root: root.clone(),
            shared_root: root.clone(),
            scripts_dir: root.join("scripts"),
        };
        let roster = retry_if_text_busy(|| read_roster(&paths)).expect("this checkout's scripts/roster must run");
        assert!(!roster.is_empty(), "this repository's roster must declare at least one agent");

        // Pure consumption: feed the impure read straight into the pure deriver, with no state
        // and no processes, and prove every row comes back Dead in roster order - the read
        // produced data the model layer can actually consume, without touching a real process
        // table or state file.
        let rows = model::derive_fleet(
            &roster,
            &StateInputs::new(),
            &[],
            &root,
        );
        assert_eq!(rows.len(), roster.len());
        for (row, entry) in rows.iter().zip(roster.iter()) {
            assert_eq!(row.name, entry.name);
            assert_eq!(row.state, model::RowState::Dead);
        }
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
        let dir = tempfile::tempdir().unwrap();
        let fake_ps = write_executable(
            dir.path(),
            "ps",
            "#!/usr/bin/env bash\nprintf '%s\\n' '    1     0 /sbin/launchd' '  123     1 some prog --flag a  b'\n",
        );
        let programs = Programs { ps: fake_ps, bd: PathBuf::from("bd") };
        let rows = retry_if_text_busy(|| read_processes(&programs)).unwrap();
        assert_eq!(
            rows,
            vec![
                ProcessRow { pid: 1, ppid: Some(0), args: "/sbin/launchd".into() },
                ProcessRow { pid: 123, ppid: Some(1), args: "some prog --flag a  b".into() },
            ]
        );
    }

    #[test]
    fn ps_exit_failure_preserves_stderr() {
        let dir = tempfile::tempdir().unwrap();
        let fake_ps = write_executable(
            dir.path(),
            "ps",
            "#!/usr/bin/env bash\necho 'ps: boom' >&2\nexit 3\n",
        );
        let programs = Programs { ps: fake_ps, bd: PathBuf::from("bd") };
        let err = retry_if_text_busy(|| read_processes(&programs)).unwrap_err();
        match err {
            ReadError::Exit { status, stderr, .. } => {
                assert_eq!(status, Some(3));
                assert!(stderr.contains("boom"));
            }
            other => panic!("expected Exit, got {other:?}"),
        }
    }

    #[test]
    fn readers_report_spawn_and_decode_failures() {
        let programs = Programs { ps: PathBuf::from("/does/not/exist/ps"), bd: PathBuf::from("bd") };
        assert!(matches!(retry_if_text_busy(|| read_processes(&programs)), Err(ReadError::Spawn { .. })));
        let dir = tempfile::tempdir().unwrap();
        let bad_ps = write_executable(dir.path(), "ps", "#!/usr/bin/env bash\nprintf '\\377'\n");
        let programs = Programs { ps: bad_ps, bd: PathBuf::from("bd") };
        assert!(matches!(retry_if_text_busy(|| read_processes(&programs)), Err(ReadError::Invalid { .. })));
    }

    #[test]
    fn bd_reader_uses_shared_root_all_statuses_and_readonly() {
        let dir = tempfile::tempdir().unwrap();
        let capture = dir.path().join("argv.txt");
        let fake_bd = write_executable(
            dir.path(),
            "bd",
            &format!(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > {}\n\
                 want='--readonly -C {}/shared list --status open,in_progress,blocked,deferred,closed --json --brief'\n\
                 got=\"$*\"\n\
                 if [ \"$got\" != \"$want\" ]; then echo \"unexpected argv: $got\" >&2; exit 2; fi\n\
                 cat <<'JSON'\n\
                 [{{\"id\":\"cb-1\",\"title\":\"t\",\"status\":\"open\",\"issue_type\":\"feature\",\"labels\":[],\"priority\":1,\"updated_at\":null,\"assignee\":null}}]\n\
                 JSON\n",
                capture.display(),
                dir.path().display(),
            ),
        );
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().join("shared"),
            scripts_dir: dir.path().to_path_buf(),
        };
        let programs = Programs { bd: fake_bd, ps: PathBuf::from("ps") };
        let beads = retry_if_text_busy(|| read_beads(&paths, &programs)).unwrap();
        assert_eq!(beads.len(), 1);
        assert_eq!(beads[0].id, "cb-1");
        assert_eq!(partition_beads(beads).unplanned.len(), 1);

        let recorded = std::fs::read_to_string(&capture).unwrap();
        assert!(recorded.contains("--readonly"));
        assert!(recorded.contains("--brief"));
        assert!(recorded.contains("open,in_progress,blocked,deferred,closed"));
    }

    #[test]
    fn bd_reader_reports_invalid_json() {
        let dir = tempfile::tempdir().unwrap();
        let fake_bd = write_executable(dir.path(), "bd", "#!/usr/bin/env bash\nexit 0\n");
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().join("shared"),
            scripts_dir: dir.path().to_path_buf(),
        };
        let programs = Programs { bd: fake_bd, ps: PathBuf::from("ps") };
        assert!(matches!(retry_if_text_busy(|| read_beads(&paths, &programs)), Err(ReadError::Invalid { .. })));
    }

    #[test]
    fn bd_reader_refuses_without_the_expected_argv() {        let dir = tempfile::tempdir().unwrap();
        let fake_bd = write_executable(
            dir.path(),
            "bd",
            "#!/usr/bin/env bash\necho 'bd: refusing' >&2\nexit 2\n",
        );
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().join("shared"),
            scripts_dir: dir.path().to_path_buf(),
        };
        let programs = Programs { bd: fake_bd, ps: PathBuf::from("ps") };
        let err = retry_if_text_busy(|| read_beads(&paths, &programs)).unwrap_err();
        match err {
            ReadError::Exit { status, stderr, .. } => {
                assert_eq!(status, Some(2));
                assert!(stderr.contains("refusing"));
            }
            other => panic!("expected Exit, got {other:?}"),
        }
    }

    // --- cb-vyp.2: the aggregate fleet read, and the wall-clock bound under it -------------------

    /// A roster script, a state file and a `ps` table that agree, read in one call: the row for a
    /// state file whose pid carries this consumer's marker is the state file's own, and the row
    /// for an agent with neither is dead.
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

        let scripts = dir.path().join("scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        write_executable(
            &scripts,
            "roster",
            "#!/usr/bin/env bash\nprintf '%s\\n' 'Xavier\tplanner\tinteractive' 'Storm\timplementer\timplementer'\n",
        );
        // Built by `model::marker_sentence`, never typed: this crate spells the marker sentence
        // in one file, which is what `scripts/marker-readers` holds it to.
        let marker = format!("claude {}", model::marker_sentence("Xavier", &shared));
        write_executable(
            dir.path(),
            "ps",
            &format!(
                "#!/usr/bin/env bash\nprintf '%s\\n' ' 4242     1 {marker}'\n"
            ),
        );

        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: shared.clone(),
            scripts_dir: scripts,
        };
        let programs = Programs { ps: dir.path().join("ps"), bd: PathBuf::from("bd") };
        let rows = retry_if_text_busy(|| read_fleet(&paths, &programs)).unwrap();

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name, "Xavier");
        assert_eq!(rows[0].state, model::RowState::Working);
        assert_eq!(rows[0].phase.as_deref(), Some("plan"));
        assert_eq!(rows[0].bead.as_deref(), Some("cb-kcs"));
        assert_eq!(rows[0].sessions, 1);
        assert_eq!(rows[1].name, "Storm");
        assert_eq!(rows[1].state, model::RowState::Dead);
    }

    /// A child that never returns is killed, reaped and reported - never waited on forever, and
    /// never left behind as a zombie. The bound is injected so this costs a second rather than
    /// the five the screen uses.
    #[test]
    fn command_timeout_kills_and_reaps_the_child() {
        let dir = tempfile::tempdir().unwrap();
        // `exec' so the process this crate spawns IS the sleeping one: a bash that forked `sleep'
        // would be reaped here while its child lived on. It writes a pipe-buffer's worth first,
        // so a runner that waited before draining would deadlock rather than time out.
        let slow = write_executable(
            dir.path(),
            "slow",
            "#!/usr/bin/env bash\nhead -c 200000 /dev/zero | tr '\\0' 'x'\nexec sleep 30\n",
        );

        let started = std::time::Instant::now();
        let err = run_with_timeout(&slow, &[], None, Duration::from_secs(1)).unwrap_err();
        let elapsed = started.elapsed();

        match err {
            ReadError::Timeout { seconds, source } => {
                assert_eq!(seconds, 1);
                assert!(source.ends_with("slow"), "the failure names the program: {source}");
            }
            other => panic!("expected Timeout, got {other:?}"),
        }
        assert!(elapsed < Duration::from_secs(10), "it waited for the child to finish: {elapsed:?}");

        // Killed AND waited for: a kill without a wait leaves a zombie, and this process outlives
        // every refresh it makes. Asked of the process table rather than of a recorded pid, so a
        // loaded machine cannot make the assertion itself flaky.
        let mine = std::process::id().to_string();
        let table = Command::new("ps").args(["-axo", "stat=,ppid="]).output().unwrap();
        let table = String::from_utf8_lossy(&table.stdout);
        let zombies: Vec<&str> = table
            .lines()
            .filter(|line| {
                let mut fields = line.split_whitespace();
                let stat = fields.next().unwrap_or("");
                let ppid = fields.next().unwrap_or("");
                stat.starts_with('Z') && ppid == mine
            })
            .collect();
        assert!(zombies.is_empty(), "the timed-out child was left as a zombie: {zombies:?}");
    }

    /// A child that writes more than one pipe buffer and then exits is read whole: both pipes are
    /// drained while it runs, so a large roster or process table is not a deadlock.
    #[test]
    fn large_output_is_read_without_deadlocking() {
        let dir = tempfile::tempdir().unwrap();
        let loud = write_executable(
            dir.path(),
            "loud",
            "#!/usr/bin/env bash\nhead -c 200000 /dev/zero | tr '\\0' 'x'\nhead -c 200000 /dev/zero | tr '\\0' 'e' >&2\n",
        );
        let stdout = run_with_timeout(&loud, &[], None, Duration::from_secs(5)).unwrap();
        assert_eq!(stdout.len(), 200_000);
    }

    /// Every way the aggregate read can fail comes back as a failure. `Ok(vec![])` would render
    /// as a fleet in which every agent is dead - the most alarming screen this view can draw, and
    /// a lie.
    #[test]
    fn fleet_reader_failure_is_not_an_empty_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let scripts = dir.path().join("scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        write_executable(
            &scripts,
            "roster",
            "#!/usr/bin/env bash\nprintf '%s\\n' 'Xavier\tplanner\tinteractive'\n",
        );
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().to_path_buf(),
            scripts_dir: scripts.clone(),
        };

        // `ps' fails: the roster read succeeded, and the fleet is still unavailable rather than
        // a roster's worth of dead rows.
        write_executable(
            dir.path(),
            "ps",
            "#!/usr/bin/env bash\necho 'ps: boom' >&2\nexit 3\n",
        );
        let programs = Programs { ps: dir.path().join("ps"), bd: PathBuf::from("bd") };
        match retry_if_text_busy(|| read_fleet(&paths, &programs)) {
            Err(ReadError::Exit { status, stderr, .. }) => {
                assert_eq!(status, Some(3));
                assert!(stderr.contains("boom"));
            }
            other => panic!("expected the ps failure, got {other:?}"),
        }

        // The roster fails: the same, and the error still names the roster.
        write_executable(
            &scripts,
            "roster",
            "#!/usr/bin/env bash\necho 'roster: refusing' >&2\nexit 2\n",
        );
        write_executable(dir.path(), "ps", "#!/usr/bin/env bash\nprintf ''\n");
        match retry_if_text_busy(|| read_fleet(&paths, &programs)) {
            Err(ReadError::Exit { status, source, .. }) => {
                assert_eq!(status, Some(2));
                assert!(source.ends_with("roster"), "expected the roster to be named: {source}");
            }
            other => panic!("expected the roster failure, got {other:?}"),
        }
    }

    // --- cb-vyp.3: the aggregate work read -------------------------------------------------------

    /// A `bd` that refuses any argv but the panel's own, and answers with one bead per bucket.
    /// The shape is deliberately exhaustive: the argv assertion and the partition assertion are
    /// the whole contract of `read_work`.
    fn bucketed_bd(dir: &Path, capture: &Path, shared: &Path) -> PathBuf {
        write_executable(
            dir,
            "bd",
            &format!(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > {}\n\
                 want='--readonly -C {} list --status open,in_progress,blocked,deferred,closed --json --brief'\n\
                 got=\"$*\"\n\
                 if [ \"$got\" != \"$want\" ]; then echo \"unexpected argv: $got\" >&2; exit 2; fi\n\
                 cat <<'JSON'\n\
                 [{{\"id\":\"cb-claimed\",\"title\":\"being built\",\"status\":\"in_progress\",\"issue_type\":\"feature\",\"labels\":[],\"priority\":1,\"updated_at\":null,\"assignee\":\"Cyclops\"}},\n\
                  {{\"id\":\"cb-planned\",\"title\":\"ready\",\"status\":\"open\",\"issue_type\":\"feature\",\"labels\":[\"planned\"],\"priority\":2,\"updated_at\":null,\"assignee\":null}},\n\
                  {{\"id\":\"cb-held\",\"title\":\"mid-plan\",\"status\":\"open\",\"issue_type\":\"feature\",\"labels\":[\"planning:Xavier\"],\"priority\":2,\"updated_at\":null,\"assignee\":null}},\n\
                  {{\"id\":\"cb-new\",\"title\":\"filed\",\"status\":\"open\",\"issue_type\":\"bug\",\"labels\":[],\"priority\":4,\"updated_at\":null,\"assignee\":null}},\n\
                  {{\"id\":\"cb-human\",\"title\":\"parked\",\"status\":\"open\",\"issue_type\":\"feature\",\"labels\":[\"human\"],\"priority\":2,\"updated_at\":null,\"assignee\":null}},\n\
                  {{\"id\":\"cb-merged\",\"title\":\"landed\",\"status\":\"closed\",\"issue_type\":\"feature\",\"labels\":[],\"priority\":1,\"updated_at\":\"2026-01-01T00:00:00Z\",\"assignee\":null}},\n\
                  {{\"id\":\"cb-epic\",\"title\":\"a family\",\"status\":\"open\",\"issue_type\":\"epic\",\"labels\":[],\"priority\":1,\"updated_at\":null,\"assignee\":null}}]\n\
                 JSON\n",
                capture.display(),
                shared.display(),
            ),
        )
    }

    #[test]
    fn work_reader_returns_the_partitioned_single_bd_answer() {
        let dir = tempfile::tempdir().unwrap();
        let capture = dir.path().join("argv.txt");
        let shared = dir.path().join("shared");
        let fake_bd = bucketed_bd(dir.path(), &capture, &shared);
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: shared,
            scripts_dir: dir.path().to_path_buf(),
        };
        let programs = Programs { bd: fake_bd, ps: PathBuf::from("ps") };

        let work = retry_if_text_busy(|| read_work(&paths, &programs)).expect("the fixture bd answers the panel's argv");
        assert_eq!(ids(&work.claimed), ["cb-claimed"]);
        assert_eq!(ids(&work.planned), ["cb-planned"]);
        assert_eq!(ids(&work.being_planned), ["cb-held"]);
        assert_eq!(ids(&work.unplanned), ["cb-new"]);
        assert_eq!(ids(&work.paused), ["cb-human"]);
        assert_eq!(ids(&work.merged), ["cb-merged"]);

        // Exactly one `bd` run, with the panel's whole argv - the shared root, every status,
        // `--readonly' and `--brief'.
        let recorded = std::fs::read_to_string(&capture).unwrap();
        let recorded: Vec<&str> = recorded.lines().collect();
        assert_eq!(
            recorded,
            vec![
                "--readonly",
                "-C",
                paths.shared_root.to_string_lossy().as_ref(),
                "list",
                "--status",
                "open,in_progress,blocked,deferred,closed",
                "--json",
                "--brief",
            ]
        );
    }

    fn ids(beads: &[Bead]) -> Vec<&str> {
        beads.iter().map(|b| b.id.as_str()).collect()
    }

    /// A `bd` that exits non-zero is a failure, not six empty queues: an empty board and an
    /// unreadable one are opposite screens.
    #[test]
    fn work_reader_preserves_bd_failure() {
        let dir = tempfile::tempdir().unwrap();
        let fake_bd = write_executable(
            dir.path(),
            "bd",
            "#!/usr/bin/env bash\necho 'bd list failed: database is locked' >&2\nexit 1\n",
        );
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().join("shared"),
            scripts_dir: dir.path().to_path_buf(),
        };
        let programs = Programs { bd: fake_bd, ps: PathBuf::from("ps") };
        match retry_if_text_busy(|| read_work(&paths, &programs)) {
            Err(ReadError::Exit { status, stderr, .. }) => {
                assert_eq!(status, Some(1));
                assert!(stderr.contains("database is locked"), "{stderr}");
            }
            other => panic!("expected the bd failure, got {other:?}"),
        }
    }

    #[test]
    fn work_reader_rejects_invalid_json() {
        let dir = tempfile::tempdir().unwrap();
        let fake_bd = write_executable(
            dir.path(),
            "bd",
            "#!/usr/bin/env bash\nprintf 'bd: nothing to list\\n'\n",
        );
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().join("shared"),
            scripts_dir: dir.path().to_path_buf(),
        };
        let programs = Programs { bd: fake_bd, ps: PathBuf::from("ps") };
        assert!(matches!(retry_if_text_busy(|| read_work(&paths, &programs)), Err(ReadError::Invalid { .. })));
    }

    /// A `bd` that never answers is killed, reaped and reported. Without the bound the Work pane
    /// would say `refreshing...` forever: the request is in flight, so no later tick replaces it.
    #[test]
    fn work_reader_timeout_kills_and_reaps_bd() {
        let dir = tempfile::tempdir().unwrap();
        let slow_bd = write_executable(
            dir.path(),
            "bd",
            "#!/usr/bin/env bash\nexec sleep 30\n",
        );
        let paths = ReaderPaths {
            consumer_root: dir.path().to_path_buf(),
            shared_root: dir.path().join("shared"),
            scripts_dir: dir.path().to_path_buf(),
        };
        let programs = Programs { bd: slow_bd, ps: PathBuf::from("ps") };

        let started = std::time::Instant::now();
        let err = read_work_with_timeout(&paths, &programs, Duration::from_secs(1)).unwrap_err();
        let elapsed = started.elapsed();
        match err {
            ReadError::Timeout { seconds, source } => {
                assert_eq!(seconds, 1);
                assert!(source.ends_with("bd"), "the failure names the program: {source}");
            }
            other => panic!("expected Timeout, got {other:?}"),
        }
        assert!(elapsed < Duration::from_secs(10), "it waited for the child: {elapsed:?}");

        let mine = std::process::id().to_string();
        let table = Command::new("ps").args(["-axo", "stat=,ppid="]).output().unwrap();
        let table = String::from_utf8_lossy(&table.stdout);
        let zombies: Vec<&str> = table
            .lines()
            .filter(|line| {
                let mut fields = line.split_whitespace();
                let stat = fields.next().unwrap_or("");
                let ppid = fields.next().unwrap_or("");
                stat.starts_with('Z') && ppid == mine
            })
            .collect();
        assert!(zombies.is_empty(), "the timed-out bd was left as a zombie: {zombies:?}");
    }
}
