//! Filesystem and subprocess I/O, kept apart from `crate::model`'s pure parsing/derivation.
//!
//! Read-only by construction: every function here reads a file or runs a read-only external
//! program (`scripts/roster`, `ps`, `bd --readonly`) and returns data for `crate::model` to
//! parse. Nothing here writes a file, launches, stops, triggers, supervises, or cleans up state -
//! Emacs remains the sole supervisor (cb-vyp.1's own scope).

use std::path::{Path, PathBuf};
use std::process::Command;


use crate::model::{self, Bead, ProcessRow, RosterEntry, StateInputs, StateObservation, StateRecord};

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
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Spawn { source, message } => write!(f, "could not run {source}: {message}"),
            Self::Exit { source, status, stderr } =>
                write!(f, "{source} exited with status {status:?}: {stderr}"),
            Self::Invalid { source, message } =>
                write!(f, "{source} produced invalid output: {message}"),
        }
    }
}

impl std::error::Error for ReadError {}

fn run(program: &Path, args: &[&str], cwd: Option<&Path>) -> Result<Vec<u8>, ReadError> {
    let program_name = program.display().to_string();
    let mut command = Command::new(program);
    command.args(args);
    if let Some(dir) = cwd {
        command.current_dir(dir);
    }
    let output = command.output().map_err(|e| ReadError::Spawn {
        source: program_name.clone(),
        message: e.to_string(),
    })?;
    if !output.status.success() {
        return Err(ReadError::Exit {
            source: program_name,
            status: output.status.code(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    Ok(output.stdout)
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
    let root = paths.shared_root.to_string_lossy().into_owned();
    let stdout = run(
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
    )?;
    serde_json::from_slice(&stdout).map_err(|e| ReadError::Invalid {
        source: programs.bd.display().to_string(),
        message: e.to_string(),
    })
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
        let roster = read_roster(&paths).expect("this checkout's scripts/roster must run");
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
        let rows = read_processes(&programs).unwrap();
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
        let err = read_processes(&programs).unwrap_err();
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
        assert!(matches!(read_processes(&programs), Err(ReadError::Spawn { .. })));
        let dir = tempfile::tempdir().unwrap();
        let bad_ps = write_executable(dir.path(), "ps", "#!/usr/bin/env bash\nprintf '\\377'\n");
        let programs = Programs { ps: bad_ps, bd: PathBuf::from("bd") };
        assert!(matches!(read_processes(&programs), Err(ReadError::Invalid { .. })));
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
        let beads = read_beads(&paths, &programs).unwrap();
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
        assert!(matches!(read_beads(&paths, &programs), Err(ReadError::Invalid { .. })));
    }

    #[test]
    fn bd_reader_refuses_without_the_expected_argv() {
        let dir = tempfile::tempdir().unwrap();
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
        let err = read_beads(&paths, &programs).unwrap_err();
        match err {
            ReadError::Exit { status, stderr, .. } => {
                assert_eq!(status, Some(2));
                assert!(stderr.contains("refusing"));
            }
            other => panic!("expected Exit, got {other:?}"),
        }
    }
}
