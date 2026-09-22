import { StrictMode, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

type Agent = { name: string; role: string; state: string; phase?: string; bead?: string; since?: string; diagnostic?: string };
type Bead = { id: string; title: string; status: string; issue_type: string; labels: string[]; priority?: number; assignee?: string };
type Work = { claimed: Bead[]; planned: Bead[]; being_planned: Bead[]; ux_agreed: Bead[]; unplanned: Bead[]; paused: Bead[]; merged: Bead[] };
type Snapshot<T> = { state: "fresh"; value: T } | { state: "stale"; value: T; error: string } | { state: "unavailable"; error: string };
type Tab = "fleet" | "work";

const notice = "This page lets you inspect the fleet and its work. Start, stop, assign, and priority controls stay in the terminal console.";
const read = async <T,>(path: string) => {
  const response = await fetch(path);
  if (!response.ok) throw new Error(response.statusText);
  return response.json() as Promise<Snapshot<T>>;
};
const age = (since?: string) => since ? `${Math.max(0, Math.floor((Date.now() - Date.parse(since)) / 60000))} minutes ago` : "—";

function Dialog({ item, onClose }: { item: Agent | Bead; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { dialog.current?.showModal(); return () => dialog.current?.close(); }, []);
  const agent = "role" in item;
  return <dialog ref={dialog} className="dialog" aria-label="Read-only details" onClose={onClose} onCancel={onClose}>
    <header><div><h2>{agent ? item.name : item.title}</h2><p>Read-only details</p></div><button autoFocus onClick={onClose}>Close</button></header>
    <dl>{agent ? <><dt>Role</dt><dd>{item.role}</dd><dt>Status</dt><dd>{item.state}</dd><dt>Current work</dt><dd>{item.bead ?? item.phase ?? "—"}</dd><dt>Since</dt><dd>{age(item.since)}</dd><dt>Waiting for</dt><dd>{item.state === "asking" ? item.diagnostic ?? "An answer" : "—"}</dd></> :
      <><dt>Workflow</dt><dd>{item.status}</dd><dt>Priority</dt><dd>{item.priority ?? "Unranked"}</dd><dt>Current owner</dt><dd>{item.assignee ?? "—"}</dd><dt>Attention</dt><dd>{item.labels.includes("human") ? "Awaiting human input" : "—"}</dd><dt>Progress</dt><dd>{item.status}</dd></>}</dl>
  </dialog>;
}

function App() {
  const [tab, setTab] = useState<Tab>(() => sessionStorage.getItem("cerebro-tab") === "work" ? "work" : "fleet");
  const [fleet, setFleet] = useState<Snapshot<Agent[]>>();
  const [work, setWork] = useState<Snapshot<Work>>();
  const [refreshing, setRefreshing] = useState(false);
  const [fleetUpdated, setFleetUpdated] = useState<number>();
  const [workUpdated, setWorkUpdated] = useState<number>();
  const [selected, setSelected] = useState<{ type: "agent" | "bead"; id: string }>();
  const origin = useRef<HTMLElement | null>(null);
  const refresh = async () => { setRefreshing(true); const [f, w] = await Promise.allSettled([read<Agent[]>("/api/fleet"), read<Work>("/api/work")]); if (f.status === "fulfilled") { setFleet(f.value); if (f.value.state !== "unavailable") setFleetUpdated(Date.now()); } else setFleet(previous => previous && previous.state !== "unavailable" ? { state: "stale", value: previous.value, error: f.reason.message } : { state: "unavailable", error: f.reason.message }); if (w.status === "fulfilled") { setWork(w.value); if (w.value.state !== "unavailable") setWorkUpdated(Date.now()); } else setWork(previous => previous && previous.state !== "unavailable" ? { state: "stale", value: previous.value, error: w.reason.message } : { state: "unavailable", error: w.reason.message }); setRefreshing(false); };
  useEffect(() => { void refresh(); const timer = setInterval(() => void refresh(), 15000); return () => clearInterval(timer); }, []);
  const choose = (item: Agent | Bead, event: React.MouseEvent<HTMLButtonElement>) => { origin.current = event.currentTarget; setSelected("role" in item ? { type: "agent", id: item.name } : { type: "bead", id: item.id }); };
  const close = () => { setSelected(undefined); origin.current?.focus(); };
  const stale = fleet?.state === "stale" || work?.state === "stale";
  const lanes: [string, Bead[]][] = work && work.state !== "unavailable" ? [["Backlog", [...work.value.unplanned, ...work.value.paused]], ["Designing UX", work.value.being_planned], ["UX designed", [...work.value.ux_agreed, ...work.value.planned]], ["In progress", work.value.claimed], ["Unverified", work.value.merged]] : [];
  const attention = [...(fleet?.state !== "unavailable" ? fleet?.value.filter(agent => agent.state === "asking") ?? [] : []), ...(work?.state !== "unavailable" ? work?.value.paused.filter(bead => bead.labels.includes("human")) ?? [] : [])];
  const selectedItem = selected?.type === "agent" ? fleet && fleet.state !== "unavailable" ? fleet.value.find(item => item.name === selected.id) : undefined : selected && work && work.state !== "unavailable" ? lanes.flatMap(([, items]) => items).find(item => item.id === selected.id) : undefined;
  useEffect(() => { if (selected && !selectedItem) close(); }, [fleet, work]);
  const updatedAge = (time?: number) => time ? age(new Date(time).toISOString()) : "—";
  const staleAge = fleet?.state === "stale" ? updatedAge(fleetUpdated) : work?.state === "stale" ? updatedAge(workUpdated) : "—";
  return <main><header className="masthead"><div><h1>Cerebro</h1><p>Fleet and work · read-only</p></div><div><p>Updated {updatedAge(Math.max(fleetUpdated ?? 0, workUpdated ?? 0) || undefined)}</p><button onClick={() => void refresh()} disabled={refreshing}>{refreshing ? "Refreshing…" : "Refresh"}</button></div></header>
    <p className="notice">{notice}</p><nav aria-label="Console sections"><button className={tab === "fleet" ? "active" : ""} onClick={() => { setTab("fleet"); sessionStorage.setItem("cerebro-tab", "fleet"); }}>Fleet</button><button className={tab === "work" ? "active" : ""} onClick={() => { setTab("work"); sessionStorage.setItem("cerebro-tab", "work"); }}>Work</button></nav>
    {stale && <p className="stale">Showing information from {staleAge}. Refresh to try again.</p>}
    {tab === "fleet" && <section>{!fleet ? <p>Loading fleet…</p> : fleet.state === "unavailable" ? <p>Couldn’t load fleet. Try refreshing this page.</p> : fleet.value.length === 0 ? <p>No agents are in the fleet yet.</p> : <div className="fleet">{fleet.value.map(agent => <button key={agent.name} onClick={event => choose(agent, event)}><strong>{agent.name}</strong><span>{agent.role}</span><span>{agent.state}</span><span>{agent.bead ?? agent.phase ?? agent.diagnostic ?? "—"}</span></button>)}</div>}</section>}
    {tab === "work" && <section>{!work ? <p>Loading work…</p> : work.state === "unavailable" ? <p>Couldn’t load work. Try refreshing this page.</p> : <><div className="board">{lanes.map(([name, beads]) => <section className="lane" key={name}><h2>{name}</h2>{name === "Backlog" && <><h3>Ranked</h3>{beads.filter(bead => bead.priority !== undefined).map(bead => <button className="card" key={bead.id} onClick={event => choose(bead, event)}>{bead.title}</button>)}<h3>Unranked</h3>{beads.filter(bead => bead.priority === undefined).map(bead => <button className="card" key={bead.id} onClick={event => choose(bead, event)}>{bead.title}</button>)}</>}{name !== "Backlog" && beads.map(bead => <button className="card" key={bead.id} onClick={event => choose(bead, event)}>{bead.title}</button>)}{beads.length === 0 && <p>No work is in this column.</p>}</section>)}</div><section className="spotlight"><h2>Needs attention</h2>{attention.map(item => <button className="card" key={"role" in item ? item.name : item.id} onClick={event => choose(item, event)}>{"role" in item ? `${item.name} is waiting` : item.title}</button>)}</section></>}</section>}
    {selectedItem && <Dialog item={selectedItem} onClose={close} />}
  </main>;
}
createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
