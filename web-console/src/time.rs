//! Where the fleet's time went: the Time tab's read (cb-koio.2).
//!
//! A pure core over plain records - transitions, session marks and transcript events - and a
//! small reading edge below it. Only `working` and `asking` time counts: `idle` and `waiting` are
//! a session with nothing in hand. `asking` is the time spent waiting on the navigator.

use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::SystemTime,
};

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use serde_json::Value;

/// The four periods the tab offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Period {
    Day,
    Week,
    Month,
    All,
}

impl Period {
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "24h" => Some(Self::Day),
            "7d" => Some(Self::Week),
            "30d" => Some(Self::Month),
            "all" => Some(Self::All),
            _ => None,
        }
    }

    /// When the period starts, counted back from NOW; `All` has no start.
    pub fn start(self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        match self {
            Self::Day => Some(now - Duration::hours(24)),
            Self::Week => Some(now - Duration::days(7)),
            Self::Month => Some(now - Duration::days(30)),
            Self::All => None,
        }
    }
}

/// One line of `transitions.jsonl`: AGENT went into state TO, in PHASE.
#[derive(Clone, Debug, PartialEq)]
pub struct Transition {
    pub ts: DateTime<Utc>,
    pub agent: String,
    pub to: String,
    pub phase: Option<String>,
}

/// A session boundary from `decisions*.jsonl`: a start, carrying the role it was started as, or
/// an end (`end`, `exit`, `retire`).
#[derive(Clone, Debug, PartialEq)]
pub struct Mark {
    pub ts: DateTime<Utc>,
    pub agent: String,
    /// `Some(role)` for a start, `None` for an end.
    pub start: Option<String>,
}

/// One session's transcript: whose it is, and each event with the activity that follows it.
#[derive(Clone, Debug, PartialEq)]
pub struct Transcript {
    pub agent: String,
    pub events: Vec<(DateTime<Utc>, &'static str)>,
}

#[derive(Clone, Debug, Default)]
pub struct Records {
    pub transitions: Vec<Transition>,
    pub marks: Vec<Mark>,
    pub transcripts: Vec<Arc<Transcript>>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct TimeReport {
    pub read_at: DateTime<Utc>,
    /// The earliest moment any transcript covers; what an agent did inside a phase is known only
    /// from here on. `None` when no transcript was read.
    pub detail_from: Option<DateTime<Utc>>,
    pub roles: Vec<RoleTime>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct RoleTime {
    pub name: String,
    pub working: f64,
    pub waiting: f64,
    pub sessions: usize,
    pub agents: Vec<AgentTime>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct AgentTime {
    pub name: String,
    pub working: f64,
    pub waiting: f64,
    pub sessions: usize,
    pub phases: Vec<PhaseTime>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct PhaseTime {
    pub name: String,
    pub working: f64,
    pub waiting: f64,
    pub activities: Vec<ActivityTime>,
    /// Working time before `detail_from`, when nothing says what the agent was doing.
    pub undetailed_before: f64,
    /// Working time since `detail_from` that no transcript covers (a Copilot session, say).
    pub undetailed: f64,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct ActivityTime {
    pub name: String,
    pub seconds: f64,
}

const NO_PHASE: &str = "no phase";

/// The most one unbroken stretch of `working` counts for. Nothing writes a transition while an
/// agent works inside one phase, but a stretch of days is a session that died without its end
/// being recorded. An `asking` stretch has no ceiling: a question waits until it is answered.
pub const WORKING_CEILING_HOURS: i64 = 8;
const UNKNOWN_ROLE: &str = "unknown";

fn timestamp(value: &Value) -> Option<DateTime<Utc>> {
    value.as_str()?.parse::<DateTime<Utc>>().ok()
}

/// Every line of `transitions.jsonl` that parses; one that does not is skipped.
pub fn parse_transitions(text: &str) -> Vec<Transition> {
    text.lines()
        .filter_map(|line| {
            let value: Value = serde_json::from_str(line).ok()?;
            Some(Transition {
                ts: timestamp(&value["ts"])?,
                agent: value["agent"].as_str()?.to_string(),
                to: value["to"].as_str()?.to_string(),
                phase: value["phase"].as_str().map(str::to_string),
            })
        })
        .collect()
}

/// The session starts and ends in one `decisions*.jsonl`. Those logs run to tens of megabytes of
/// `evaluate` lines, so a line is parsed only once it names one of the four events.
pub fn parse_marks(text: &str) -> Vec<Mark> {
    const EVENTS: [&str; 4] = [
        "\"event\":\"start\"",
        "\"event\":\"end\"",
        "\"event\":\"exit\"",
        "\"event\":\"retire\"",
    ];
    text.lines()
        .filter(|line| EVENTS.iter().any(|event| line.contains(event)))
        .filter_map(|line| {
            let value: Value = serde_json::from_str(line).ok()?;
            let start = match value["event"].as_str()? {
                "start" => Some(value["role"].as_str().unwrap_or(UNKNOWN_ROLE).to_string()),
                "end" | "exit" | "retire" => None,
                _ => return None,
            };
            Some(Mark {
                ts: timestamp(&value["ts"])?,
                agent: value["agent"].as_str()?.to_string(),
                start,
            })
        })
        .collect()
}

/// What a tool call is spent on.
pub fn activity_of_tool(name: &str, input: &Value) -> &'static str {
    match name {
        "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => "editing code",
        "Read" | "Grep" | "Glob" | "LS" | "WebFetch" | "WebSearch" | "Skill" => "reading",
        "Agent" | "Task" => "sub-agents",
        "Bash" => activity_of_command(input["command"].as_str().unwrap_or("")),
        _ => "other tools",
    }
}

fn activity_of_command(command: &str) -> &'static str {
    let words: Vec<&str> = command
        .split(|c: char| c.is_whitespace() || matches!(c, ';' | '&' | '|' | '(' | ')'))
        .filter(|word| !word.is_empty())
        .collect();
    let has = |word: &str| words.contains(&word);
    let mentions = |needles: &[&str]| needles.iter().any(|needle| command.contains(needle));
    if has("sleep") {
        "waiting"
    } else if mentions(&[
        "tests/", "cargo test", "playwright", "suite-runner", "test:e2e", "pytest", "go test", "npm test", "pnpm test",
        "vitest", "jest",
    ]) {
        "running tests"
    } else if mentions(&["cargo build", "cargo check", "cargo clippy", "pnpm build", "vite build", "tsc "]) || has("tsc") || has("make") {
        "building"
    } else if has("git") || has("gh") {
        "git and GitHub"
    } else if has("bd") {
        "the board"
    } else {
        "running commands"
    }
}

/// The transcript in TEXT, if it is a fleet session rooted at ROOT: its agent, from the marker
/// sentence, and an event for each of its own (not a sub-agent's) user and assistant lines.
pub fn parse_transcript(text: &str, root: &Path) -> Option<Transcript> {
    let mut agent = None;
    let mut events = Vec::new();
    for line in text.lines() {
        let is_user = line.contains("\"type\":\"user\"");
        if !is_user && !line.contains("\"type\":\"assistant\"") {
            continue;
        }
        if agent.is_none() && is_user {
            agent = cerebro_tui::marker_agent(line, root);
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else { continue };
        if value["isSidechain"].as_bool() == Some(true) {
            continue;
        }
        let Some(ts) = timestamp(&value["timestamp"]) else { continue };
        let activity = match value["type"].as_str() {
            Some("assistant") => value["message"]["content"]
                .as_array()
                .and_then(|blocks| blocks.iter().find(|block| block["type"] == "tool_use"))
                .map(|block| activity_of_tool(block["name"].as_str().unwrap_or(""), &block["input"]))
                .unwrap_or("thinking"),
            Some("user") => "thinking",
            _ => continue,
        };
        events.push((ts, activity));
    }
    events.sort_by_key(|(ts, _)| *ts);
    Some(Transcript { agent: agent?, events })
}

#[derive(Default)]
struct PhaseSum {
    working: f64,
    waiting: f64,
    activities: BTreeMap<&'static str, f64>,
    undetailed_before: f64,
    undetailed: f64,
}

#[derive(Default)]
struct AgentSum {
    phases: BTreeMap<String, PhaseSum>,
    sessions: BTreeSet<Option<DateTime<Utc>>>,
}

fn seconds(from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    (to - from).num_milliseconds().max(0) as f64 / 1000.0
}

/// Where the time went between PERIOD_START (none: all of it) and NOW.
pub fn account(records: &Records, period_start: Option<DateTime<Utc>>, now: DateTime<Utc>) -> TimeReport {
    let detail_from = records.transcripts.iter().filter_map(|t| t.events.first().map(|(ts, _)| *ts)).min();

    // Each agent's transcript segments, in time order: event i's activity runs to event i+1.
    let mut segments: HashMap<&str, Vec<(DateTime<Utc>, DateTime<Utc>, &'static str)>> = HashMap::new();
    for transcript in &records.transcripts {
        let list = segments.entry(transcript.agent.as_str()).or_default();
        for pair in transcript.events.windows(2) {
            if pair[1].0 > pair[0].0 {
                list.push((pair[0].0, pair[1].0, pair[0].1));
            }
        }
    }
    for list in segments.values_mut() {
        list.sort_by_key(|(from, _, _)| *from);
    }

    let mut by_agent: BTreeMap<&str, Vec<&Transition>> = BTreeMap::new();
    for transition in &records.transitions {
        by_agent.entry(transition.agent.as_str()).or_default().push(transition);
    }
    let mut marks: HashMap<&str, Vec<&Mark>> = HashMap::new();
    for mark in &records.marks {
        marks.entry(mark.agent.as_str()).or_default().push(mark);
    }
    for list in marks.values_mut() {
        list.sort_by_key(|mark| mark.ts);
    }

    let mut tree: BTreeMap<String, BTreeMap<String, AgentSum>> = BTreeMap::new();
    for (agent, mut transitions) in by_agent {
        transitions.sort_by_key(|transition| transition.ts);
        let agent_marks = marks.get(agent).map(Vec::as_slice).unwrap_or(&[]);
        let mut last_working: Option<(Option<DateTime<Utc>>, String)> = None;
        for (index, transition) in transitions.iter().enumerate() {
            let begin = transition.ts;
            let mut end = transitions.get(index + 1).map(|next| next.ts).unwrap_or(now).min(now);
            if let Some(mark) = agent_marks.iter().find(|mark| mark.ts > begin) {
                end = end.min(mark.ts);
            }
            if transition.to == "working" {
                end = end.min(begin + Duration::hours(WORKING_CEILING_HOURS));
            }
            let session = agent_marks.iter().rev().find(|mark| mark.start.is_some() && mark.ts <= begin);
            let session_key = session.map(|mark| mark.ts);
            let phase = match transition.to.as_str() {
                "working" => {
                    let phase = transition.phase.clone().unwrap_or_else(|| NO_PHASE.to_string());
                    last_working = Some((session_key, phase.clone()));
                    phase
                }
                "asking" => transition.phase.clone().unwrap_or_else(|| match &last_working {
                    Some((key, phase)) if *key == session_key => phase.clone(),
                    _ => NO_PHASE.to_string(),
                }),
                _ => continue,
            };
            let from = period_start.map_or(begin, |start| begin.max(start));
            if end <= from {
                continue;
            }
            let role = session
                .or_else(|| agent_marks.iter().find(|mark| mark.start.is_some()))
                .and_then(|mark| mark.start.clone())
                .unwrap_or_else(|| UNKNOWN_ROLE.to_string());
            let sum = tree.entry(role).or_default().entry(agent.to_string()).or_default();
            sum.sessions.insert(session_key);
            let slot = sum.phases.entry(phase).or_default();
            if transition.to == "asking" {
                slot.waiting += seconds(from, end);
                continue;
            }
            slot.working += seconds(from, end);
            // What the transcripts say about [from, end); the rest is undetailed.
            let mut cursor = from;
            let mut uncovered = Vec::new();
            for &(seg_from, seg_to, activity) in segments.get(agent).map(Vec::as_slice).unwrap_or(&[]) {
                if seg_to <= cursor || seg_from >= end {
                    continue;
                }
                let a = seg_from.max(cursor);
                let b = seg_to.min(end);
                if a > cursor {
                    uncovered.push((cursor, a));
                }
                *slot.activities.entry(activity).or_default() += seconds(a, b);
                cursor = b;
            }
            if cursor < end {
                uncovered.push((cursor, end));
            }
            for (a, b) in uncovered {
                match detail_from {
                    Some(detail) if a < detail => {
                        slot.undetailed_before += seconds(a, b.min(detail));
                        slot.undetailed += seconds(detail.max(a), b);
                    }
                    Some(_) => slot.undetailed += seconds(a, b),
                    None => slot.undetailed += seconds(a, b),
                }
            }
        }
    }

    let total = |working: f64, waiting: f64| working + waiting;
    let mut roles: Vec<RoleTime> = tree
        .into_iter()
        .map(|(role, agents)| {
            let mut agents: Vec<AgentTime> = agents
                .into_iter()
                .map(|(name, sum)| {
                    let mut phases: Vec<PhaseTime> = sum
                        .phases
                        .into_iter()
                        .map(|(name, phase)| {
                            let mut activities: Vec<ActivityTime> = phase
                                .activities
                                .into_iter()
                                .map(|(name, seconds)| ActivityTime { name: name.to_string(), seconds })
                                .collect();
                            activities.sort_by(|a, b| b.seconds.total_cmp(&a.seconds));
                            PhaseTime {
                                name,
                                working: phase.working,
                                waiting: phase.waiting,
                                activities,
                                undetailed_before: phase.undetailed_before,
                                undetailed: phase.undetailed,
                            }
                        })
                        .collect();
                    phases.sort_by(|a, b| total(b.working, b.waiting).total_cmp(&total(a.working, a.waiting)));
                    AgentTime {
                        name,
                        working: phases.iter().map(|p| p.working).sum(),
                        waiting: phases.iter().map(|p| p.waiting).sum(),
                        sessions: sum.sessions.len(),
                        phases,
                    }
                })
                .collect();
            agents.sort_by(|a, b| total(b.working, b.waiting).total_cmp(&total(a.working, a.waiting)));
            RoleTime {
                name: role,
                working: agents.iter().map(|a| a.working).sum(),
                waiting: agents.iter().map(|a| a.waiting).sum(),
                sessions: agents.iter().map(|a| a.sessions).sum(),
                agents,
            }
        })
        .collect();
    roles.sort_by(|a, b| total(b.working, b.waiting).total_cmp(&total(a.working, a.waiting)));
    TimeReport { read_at: now, detail_from, roles }
}

/// Parsed files, kept while a file's length and modification time say it is unchanged: the
/// rotated decision logs and the transcripts run to hundreds of megabytes, read once a minute.
pub struct FileCache<T> {
    entries: Mutex<HashMap<PathBuf, (u64, Option<SystemTime>, Arc<T>)>>,
}

impl<T> Default for FileCache<T> {
    fn default() -> Self {
        Self { entries: Mutex::new(HashMap::new()) }
    }
}

impl<T> FileCache<T> {
    /// PATH parsed by PARSE, or `Ok(None)` when it does not exist.
    fn get(&self, path: &Path, parse: impl FnOnce(&str) -> T) -> Result<Option<Arc<T>>, String> {
        let metadata = match std::fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(format!("{}: {error}", path.display())),
        };
        let key = (metadata.len(), metadata.modified().ok());
        if let Some((len, modified, value)) = self.entries.lock().unwrap().get(path) {
            if (*len, *modified) == key {
                return Ok(Some(Arc::clone(value)));
            }
        }
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(format!("{}: {error}", path.display())),
        };
        let value = Arc::new(parse(&String::from_utf8_lossy(&bytes)));
        self.entries.lock().unwrap().insert(path.to_path_buf(), (key.0, key.1, Arc::clone(&value)));
        Ok(Some(value))
    }
}

#[derive(Default)]
pub struct TimeCaches {
    marks: FileCache<Vec<Mark>>,
    transcripts: FileCache<Option<Arc<Transcript>>>,
}

/// The `*.jsonl` files directly in DIR, or none when it does not exist.
fn jsonl_files(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("{}: {error}", dir.display())),
    };
    let mut files = Vec::new();
    for entry in entries {
        let path = entry.map_err(|error| format!("{}: {error}", dir.display()))?.path();
        if path.extension().is_some_and(|ext| ext == "jsonl") && path.is_file() {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

/// Everything recorded for the consumer at SHARED_ROOT, with transcripts from TRANSCRIPT_DIRS. A
/// missing file is no records; any other failure is an error, never an empty answer.
pub fn read_records(shared_root: &Path, transcript_dirs: &[PathBuf], caches: &TimeCaches) -> Result<Records, String> {
    let state = shared_root.join(".cerebro/state");
    let transitions_path = state.join("transitions.jsonl");
    let transitions = match std::fs::read(&transitions_path) {
        Ok(bytes) => parse_transitions(&String::from_utf8_lossy(&bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(format!("{}: {error}", transitions_path.display())),
    };
    let mut marks = Vec::new();
    for path in jsonl_files(&state)? {
        let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("");
        if name.starts_with("decisions") {
            if let Some(parsed) = caches.marks.get(&path, parse_marks)? {
                marks.extend(parsed.iter().cloned());
            }
        }
    }
    // One session can be in more than one directory (Claude Code's own and the consumer's kept
    // copy); the larger file is the more complete.
    let mut by_session: BTreeMap<String, (u64, PathBuf)> = BTreeMap::new();
    for dir in transcript_dirs {
        for path in jsonl_files(dir)? {
            let len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            if by_session.get(&stem).is_none_or(|(kept, _)| len > *kept) {
                by_session.insert(stem, (len, path));
            }
        }
    }
    let mut transcripts = Vec::new();
    for (_, path) in by_session.values() {
        if let Some(parsed) = caches.transcripts.get(path, |text| parse_transcript(text, shared_root).map(Arc::new))? {
            if let Some(transcript) = parsed.as_ref() {
                transcripts.push(Arc::clone(transcript));
            }
        }
    }
    Ok(Records { transitions, marks, transcripts })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(hhmm: &str) -> DateTime<Utc> {
        format!("2026-11-20T{hhmm}:00Z").parse().unwrap()
    }

    fn go(agent: &str, hhmm: &str, to: &str, phase: Option<&str>) -> Transition {
        Transition { ts: at(hhmm), agent: agent.into(), to: to.into(), phase: phase.map(str::to_string) }
    }

    fn start(agent: &str, hhmm: &str, role: &str) -> Mark {
        Mark { ts: at(hhmm), agent: agent.into(), start: Some(role.into()) }
    }

    fn end(agent: &str, hhmm: &str) -> Mark {
        Mark { ts: at(hhmm), agent: agent.into(), start: None }
    }

    fn phase<'a>(report: &'a TimeReport, role: &str, agent: &str, name: &str) -> &'a PhaseTime {
        let role = report.roles.iter().find(|r| r.name == role).expect("role");
        let agent = role.agents.iter().find(|a| a.name == agent).expect("agent");
        agent.phases.iter().find(|p| p.name == name).expect("phase")
    }

    #[test]
    fn counts_working_and_asking_per_role_agent_phase() {
        let records = Records {
            transitions: vec![
                go("Storm", "10:00", "working", Some("build")),
                go("Storm", "11:00", "asking", Some("build")),
                go("Storm", "11:30", "working", Some("review")),
                go("Storm", "12:00", "waiting", None),
                go("Rogue", "10:00", "idle", None),
                go("Rogue", "10:30", "working", Some("triage")),
                go("Rogue", "10:45", "waiting", None),
            ],
            marks: vec![start("Storm", "09:59", "producer"), start("Rogue", "09:59", "orchestrator")],
            transcripts: vec![],
        };
        let report = account(&records, None, at("13:00"));
        assert_eq!(report.roles.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(), ["producer", "orchestrator"]);
        let build = phase(&report, "producer", "Storm", "build");
        assert_eq!((build.working, build.waiting), (3600.0, 1800.0));
        assert_eq!(phase(&report, "producer", "Storm", "review").working, 1800.0);
        assert_eq!(phase(&report, "orchestrator", "Rogue", "triage").working, 900.0);
        let producer = &report.roles[0];
        assert_eq!((producer.working, producer.waiting, producer.sessions), (5400.0, 1800.0, 1));
        assert_eq!(report.detail_from, None);
        assert_eq!(build.undetailed, 3600.0, "with no transcript, all working time is undetailed");
    }

    #[test]
    fn a_working_stretch_counts_at_most_the_ceiling_and_asking_has_none() {
        let records = Records {
            transitions: vec![
                go("Forge", "00:00", "working", Some("index")),
                go("Cerebro", "00:00", "asking", Some("triage")),
            ],
            ..Default::default()
        };
        let report = account(&records, None, at("23:00"));
        assert_eq!(phase(&report, "unknown", "Forge", "index").working, WORKING_CEILING_HOURS as f64 * 3600.0);
        assert_eq!(phase(&report, "unknown", "Cerebro", "triage").waiting, 23.0 * 3600.0);
    }

    #[test]
    fn clips_to_the_period() {
        let records = Records {
            transitions: vec![go("Storm", "10:00", "working", Some("build")), go("Storm", "12:00", "waiting", None)],
            marks: vec![start("Storm", "09:00", "producer")],
            transcripts: vec![],
        };
        let report = account(&records, Some(at("11:30")), at("13:00"));
        assert_eq!(phase(&report, "producer", "Storm", "build").working, 1800.0);
        assert!(account(&records, Some(at("12:30")), at("13:00")).roles.is_empty());
    }

    #[test]
    fn an_open_interval_runs_to_now() {
        let records = Records { transitions: vec![go("Storm", "10:00", "working", Some("ci"))], ..Default::default() };
        assert_eq!(phase(&account(&records, None, at("10:10")), "unknown", "Storm", "ci").working, 600.0);
    }

    #[test]
    fn asking_without_phase_takes_the_last_working_phase() {
        let records = Records {
            transitions: vec![
                go("Storm", "10:00", "working", Some("gate")),
                go("Storm", "10:10", "asking", None),
                go("Storm", "10:20", "waiting", None),
            ],
            marks: vec![start("Storm", "09:00", "producer")],
            transcripts: vec![],
        };
        assert_eq!(phase(&account(&records, None, at("11:00")), "producer", "Storm", "gate").waiting, 600.0);
    }

    #[test]
    fn role_comes_from_the_session_start() {
        let records = Records {
            transitions: vec![
                go("Cyclops", "08:00", "working", None),
                go("Cyclops", "08:30", "waiting", None),
                go("Cyclops", "10:00", "working", Some("plan")),
                go("Cyclops", "10:30", "waiting", None),
                go("Cyclops", "12:00", "working", Some("build")),
                go("Cyclops", "12:30", "waiting", None),
            ],
            marks: vec![start("Cyclops", "09:00", "planner"), start("Cyclops", "11:00", "producer")],
            transcripts: vec![],
        };
        let report = account(&records, None, at("13:00"));
        assert_eq!(phase(&report, "planner", "Cyclops", "plan").working, 1800.0);
        assert_eq!(phase(&report, "planner", "Cyclops", NO_PHASE).working, 1800.0, "before any start: the first one's role");
        assert_eq!(phase(&report, "producer", "Cyclops", "build").working, 1800.0);
        assert_eq!(report.roles.iter().find(|r| r.name == "planner").unwrap().sessions, 2);
    }

    #[test]
    fn an_interval_ends_at_the_session_end() {
        let records = Records {
            transitions: vec![go("Storm", "10:00", "working", Some("build")), go("Storm", "12:00", "idle", None)],
            marks: vec![start("Storm", "09:00", "producer"), end("Storm", "10:20")],
            transcripts: vec![],
        };
        assert_eq!(phase(&account(&records, None, at("13:00")), "producer", "Storm", "build").working, 1200.0);
    }

    #[test]
    fn activities_divide_working_time_by_transcript_segments() {
        let records = Records {
            transitions: vec![go("Storm", "10:00", "working", Some("build")), go("Storm", "11:00", "waiting", None)],
            marks: vec![start("Storm", "09:00", "producer")],
            transcripts: vec![Arc::new(Transcript {
                agent: "Storm".into(),
                events: vec![
                    (at("09:30"), "reading"),
                    (at("10:20"), "editing code"),
                    (at("10:40"), "running tests"),
                    (at("10:50"), "thinking"),
                ],
            })],
        };
        let report = account(&records, None, at("12:00"));
        let build = phase(&report, "producer", "Storm", "build");
        let got: Vec<(&str, f64)> = build.activities.iter().map(|a| (a.name.as_str(), a.seconds)).collect();
        assert_eq!(got, [("editing code", 1200.0), ("reading", 1200.0), ("running tests", 600.0)]);
        assert_eq!((build.undetailed_before, build.undetailed), (0.0, 600.0));
        assert_eq!(report.detail_from, Some(at("09:30")));
    }

    #[test]
    fn time_before_the_first_transcript_is_undetailed_before() {
        let records = Records {
            transitions: vec![go("Storm", "10:00", "working", Some("build")), go("Storm", "11:00", "waiting", None)],
            marks: vec![start("Storm", "09:00", "producer")],
            transcripts: vec![Arc::new(Transcript {
                agent: "Rogue".into(),
                events: vec![(at("10:40"), "reading"), (at("10:50"), "thinking")],
            })],
        };
        let build = phase(&account(&records, None, at("12:00")), "producer", "Storm", "build").clone();
        assert_eq!((build.undetailed_before, build.undetailed), (2400.0, 1200.0));
        assert!(build.activities.is_empty());
    }

    #[test]
    fn activity_of_tool_classifies_bash_commands() {
        let bash = |command: &str| activity_of_tool("Bash", &json!({ "command": command }));
        assert_eq!(bash("cargo test --workspace --locked"), "running tests");
        assert_eq!(bash("bash tests/gate"), "running tests");
        assert_eq!(bash("cargo build -p cerebro-web"), "building");
        assert_eq!(bash("cd x && git push -u origin HEAD"), "git and GitHub");
        assert_eq!(bash("gh pr view 12"), "git and GitHub");
        assert_eq!(bash("bd show cb-1 --json | jq ."), "the board");
        assert_eq!(bash("until gh pr checks 1; do bd heartbeat x; sleep 30; done"), "waiting");
        assert_eq!(bash("ls -la"), "running commands");
        assert_eq!(activity_of_tool("Edit", &json!({})), "editing code");
        assert_eq!(activity_of_tool("Grep", &json!({})), "reading");
        assert_eq!(activity_of_tool("Agent", &json!({})), "sub-agents");
        assert_eq!(activity_of_tool("AskUserQuestion", &json!({})), "other tools");
    }

    #[test]
    fn parse_transcript_names_the_agent_from_the_marker() {
        let root = Path::new("/r/cerebro");
        let marker = cerebro_tui::fixture_marker_sentence("Storm", root);
        let lines = [
            json!({"type": "attachment", "timestamp": "2026-11-20T09:59:00Z"}),
            json!({"type": "user", "timestamp": "2026-11-20T10:00:00Z", "message": {"content": marker}}),
            json!({"type": "assistant", "timestamp": "2026-11-20T10:01:00Z",
                   "message": {"content": [{"type": "text", "text": "hi"}, {"type": "tool_use", "name": "Edit", "input": {}}]}}),
            json!({"type": "assistant", "isSidechain": true, "timestamp": "2026-11-20T10:02:00Z", "message": {"content": []}}),
            json!({"type": "user", "timestamp": "2026-11-20T10:03:00Z", "message": {"content": [{"type": "tool_result"}]}}),
        ];
        let text = lines.iter().map(Value::to_string).collect::<Vec<_>>().join("\n") + "\nnot json\n";
        let transcript = parse_transcript(&text, root).expect("a fleet transcript");
        assert_eq!(transcript.agent, "Storm");
        assert_eq!(
            transcript.events,
            [(at("10:00"), "thinking"), (at("10:01"), "editing code"), (at("10:03"), "thinking")]
        );
        assert_eq!(parse_transcript(&text, Path::new("/r/cerebro-hud")), None);
    }

    #[test]
    fn marks_and_transitions_skip_what_does_not_parse() {
        let marks = parse_marks(concat!(
            "{\"event\":\"evaluate\",\"ts\":\"2026-11-20T10:00:00Z\",\"agent\":\"A\"}\n",
            "{\"event\":\"start\",\"ts\":\"2026-11-20T10:00:00Z\",\"agent\":\"A\",\"role\":\"qa\"}\n",
            "{\"event\":\"exit\",\"ts\":\"2026-11-20T10:05:00Z\",\"agent\":\"A\",\"code\":\"1\"}\n",
            "{\"event\":\"start\" broken\n",
        ));
        assert_eq!(marks, [start("A", "10:00", "qa"), end("A", "10:05")]);
        let transitions = parse_transitions("{\"ts\":\"2026-11-20T10:00:00Z\",\"agent\":\"A\",\"to\":\"working\",\"phase\":null}\n{}\n");
        assert_eq!(transitions, [go("A", "10:00", "working", None)]);
    }
}
