import { StrictMode, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { BrainCircuit, Command, Eye, MessageCircleQuestion, Moon, RefreshCw, ShieldCheck, Sun, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { type Agent, type Work, epicOf, running, since, stateOf, useNow, useSnapshot, valueOf } from "./api";
import { AgentPane, FleetSidebar } from "./fleet";
import { Palette, offersFor, typingInto, unsupervised, useLifecycle } from "./actions";
import { BeadDialog, WorkBoard, lanesOf } from "./work";
import "./index.css";

type Tab = "fleet" | "work";
const notice = "This page lets you inspect the fleet and its work. " + unsupervised;
const controlling = "Start, finish and kill (s, f, k, or ⌘K) are done by the fleet view supervising this checkout. Assign and priority controls stay in the terminal console.";

/// Whether a fleet view supervises this checkout and takes the console's start, finish and kill.
function useSupervised() {
  const [supervised, setSupervised] = useState(false);
  const retry = useRef<ReturnType<typeof setTimeout>>(undefined);
  const refresh = async () => {
    clearTimeout(retry.current);
    let known = false;
    try {
      const response = await fetch("/api/control");
      const state = response.ok ? await response.json() as { supervised?: boolean; error?: string } : undefined;
      // An answer that could not be read says nothing either way, so the last one stands and it
      // is asked again until one can.
      if (state && !state.error) { setSupervised(state.supervised === true); known = true; }
    } catch { /* asked again below */ }
    if (!known) retry.current = setTimeout(() => void refresh(), 3000);
  };
  return [supervised, refresh] as const;
}

function useTheme() {
  const [dark, setDark] = useState(() => document.documentElement.classList.contains("dark"));
  useEffect(() => {
    document.documentElement.classList.toggle("dark", dark);
    localStorage.setItem("cerebro-theme", dark ? "dark" : "light");
  }, [dark]);
  return [dark, () => setDark(value => !value)] as const;
}

/// The agent to show when nobody has chosen one: whoever is asking, else working, else running.
const firstAgent = (agents: Agent[]) => agents.find(agent => stateOf(agent) === "asking")
  ?? agents.find(agent => stateOf(agent) === "working") ?? agents.find(running) ?? agents[0];

function App() {
  const [tab, setTab] = useState<Tab>(() => sessionStorage.getItem("cerebro-tab") === "work" ? "work" : "fleet");
  const fleet = useSnapshot<Agent[]>("/api/fleet");
  const work = useSnapshot<Work>("/api/work");
  const [refreshing, setRefreshing] = useState(false);
  const [chosen, setChosen] = useState<string | undefined>(() => sessionStorage.getItem("cerebro-agent") ?? undefined);
  const [openBead, setOpenBead] = useState<string>();
  const [dark, toggleTheme] = useTheme();
  const now = useNow();
  const [supervised, refreshControl] = useSupervised();
  const [palette, setPalette] = useState(false);
  const lifecycle = useLifecycle(supervised, () => { void fleet.refresh(); void work.refresh(); });
  const refresh = async () => { setRefreshing(true); await Promise.all([fleet.refresh(), work.refresh(), refreshControl()]); setRefreshing(false); };
  useEffect(() => {
    void refresh();
    const events = new EventSource("/api/events");
    events.addEventListener("fleet", () => void fleet.refresh());
    events.addEventListener("work", () => void work.refresh());
    events.addEventListener("control", () => void refreshControl());
    return () => events.close();
  }, []);
  const show = (next: Tab) => { setTab(next); sessionStorage.setItem("cerebro-tab", next); };
  const choose = (name: string) => { setChosen(name); sessionStorage.setItem("cerebro-agent", name); show("fleet"); };

  const agents = valueOf(fleet.snapshot) ?? [];
  const board = valueOf(work.snapshot);
  const lanes = board ? lanesOf(board) : [];
  const beads = lanes.flatMap(lane => lane.beads);
  const agent = agents.find(item => item.name === chosen) ?? firstAgent(agents);
  const bead = openBead ? beads.find(item => item.id === openBead) : undefined;
  // The fleet view's keys: s, f and k on the chosen agent while nobody is typing, and ⌘K for
  // every action on every agent - from anywhere, since no session binds ⌘.
  const keys = useRef({ agent, tab, lifecycle, open: false });
  keys.current = { agent, tab, lifecycle, open: palette || lifecycle.asking || bead !== undefined };
  useEffect(() => {
    const press = (event: KeyboardEvent) => {
      const { agent, tab, lifecycle, open } = keys.current;
      if (event.key.toLowerCase() === "k" && (event.metaKey || (event.ctrlKey && !typingInto(event.target)))) {
        event.preventDefault();
        event.stopPropagation();
        setPalette(true);
        return;
      }
      if (open || tab !== "fleet" || !agent || event.metaKey || event.ctrlKey || event.altKey || typingInto(event.target)) return;
      const offer = offersFor(agent).find(item => item.key === event.key);
      if (!offer) return;
      event.preventDefault();
      lifecycle.perform(agent, offer);
    };
    window.addEventListener("keydown", press, true);
    return () => window.removeEventListener("keydown", press, true);
  }, []);
  useEffect(() => { if (openBead && board && !bead) setOpenBead(undefined); }, [board]);

  const asking = agents.filter(item => stateOf(item) === "asking");
  const blocked = board?.paused.filter(item => item.labels.includes("human")) ?? [];
  const stale = fleet.snapshot?.state === "stale" || work.snapshot?.state === "stale";
  const updated = Math.max(fleet.updated ?? 0, work.updated ?? 0) || undefined;
  const oldest = Math.min(...[fleet.snapshot?.state === "stale" && fleet.updated, work.snapshot?.state === "stale" && work.updated].filter((time): time is number => typeof time === "number"));

  return <TooltipProvider>
    <div className="flex h-screen flex-col">
      <header className="flex h-14 shrink-0 items-center gap-4 border-b px-5 md:gap-6">
        <h1 className="flex items-center gap-2 text-base font-semibold"><BrainCircuit className="size-5 text-primary" />Cerebro</h1>
        <nav aria-label="Console sections" className="flex items-center gap-1 rounded-lg border bg-muted/50 p-1 text-sm">
          {(["fleet", "work"] as const).map(name => <button key={name} onClick={() => show(name)} aria-current={tab === name ? "page" : undefined}
            className={cn("rounded-md px-3 py-1 capitalize transition-colors", tab === name ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground")}>{name}</button>)}
        </nav>
        <div className="ml-auto flex items-center gap-3 text-sm text-muted-foreground">
          <Tooltip>
            <TooltipTrigger render={<span className="hidden items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs sm:inline-flex" />}>
              {supervised ? <><ShieldCheck className="size-3.5 text-emerald-500" />Supervised</> : <><Eye className="size-3.5" />Read-only</>}
            </TooltipTrigger>
            <TooltipContent side="bottom">{supervised ? controlling : notice}</TooltipContent>
          </Tooltip>
          <Button variant="outline" size="sm" onClick={() => setPalette(true)} aria-label="Actions" className="hidden text-muted-foreground sm:inline-flex"><Command />K</Button>
          <span className="hidden items-center gap-1.5 sm:inline-flex">
            <span className={cn("size-1.5 rounded-full", stale ? "bg-amber-400" : updated ? "bg-emerald-500" : "bg-zinc-400")} />
            {updated ? `${stale ? "Stale" : "Live"} · updated ${since(now, updated)} ago` : "Connecting…"}
          </span>
          <Button variant="outline" size="icon" onClick={() => void refresh()} disabled={refreshing} aria-label="Refresh"><RefreshCw className={cn(refreshing && "animate-spin")} /></Button>
          <Button variant="outline" size="icon" onClick={toggleTheme} aria-label={dark ? "Use the light theme" : "Use the dark theme"}>{dark ? <Sun /> : <Moon />}</Button>
        </div>
      </header>

      {(asking.length > 0 || blocked.length > 0 || stale) && <div className="shrink-0 space-y-2 px-5 pt-4">
        {stale && <div role="status" className="flex items-center gap-3 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm">
          <TriangleAlert className="size-4 text-amber-500" />Showing information from {Number.isFinite(oldest) ? `${since(now, oldest)} ago` : "earlier"}. Refresh to try again.
        </div>}
        {asking.map(item => <div key={item.name} className="flex items-center gap-3 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm">
          <MessageCircleQuestion className="size-4 text-amber-500" />
          <span><b>{item.name}</b> is asking you a question{item.bead && <> on <span className="font-mono">{item.bead}</span></>}. Answer it in the terminal console.</span>
          <Button variant="link" size="sm" className="ml-auto text-amber-700 dark:text-amber-300" onClick={() => choose(item.name)}>View session</Button>
        </div>)}
        {blocked.map(item => <div key={item.id} className="flex items-center gap-3 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm">
          <MessageCircleQuestion className="size-4 text-amber-500" />
          <span><span className="font-mono">{item.id}</span> {item.title} is waiting for human input.</span>
          <Button variant="link" size="sm" className="ml-auto text-amber-700 dark:text-amber-300" onClick={() => setOpenBead(item.id)}>Open</Button>
        </div>)}
      </div>}

      {tab === "fleet" && <div className="flex min-h-0 flex-1 flex-col md:flex-row">
        {!fleet.snapshot ? <p className="p-5 text-sm text-muted-foreground">Loading fleet…</p>
          : fleet.snapshot.state === "unavailable" ? <p className="p-5 text-sm">Couldn’t load fleet. Try refreshing this page.</p>
          : agents.length === 0 ? <p className="p-5 text-sm text-muted-foreground">No agents are in the fleet yet.</p>
          : <>
            <FleetSidebar agents={agents} selected={agent?.name} now={now} onSelect={choose} />
            <main className="flex min-h-0 min-w-0 flex-1 flex-col p-5">
              {agent && <AgentPane agent={agent} bead={agent.bead ? beads.find(item => item.id === agent.bead) : undefined} now={now}
                controls={{ supervised, busy: lifecycle.busy, said: lifecycle.said, onAct: offer => lifecycle.perform(agent, offer) }} />}
            </main>
          </>}
      </div>}

      {tab === "work" && (!work.snapshot ? <p className="p-5 text-sm text-muted-foreground">Loading work…</p>
        : !board ? <p className="p-5 text-sm">Couldn’t load work. Try refreshing this page.</p>
        : <WorkBoard work={board} agents={agents} onOpen={setOpenBead} />)}

      {lifecycle.dialog}
      <Palette open={palette} agents={agents} selected={agent?.name} supervised={supervised} onClose={() => setPalette(false)}
        onAct={(target, offer) => { choose(target.name); lifecycle.perform(target, offer); }} />
      {bead && <BeadDialog bead={bead} lane={lanes.find(lane => lane.beads.some(item => item.id === bead.id))?.name}
        epic={epicOf(bead.id, board?.epics)?.title} onClose={() => setOpenBead(undefined)} />}
    </div>
  </TooltipProvider>;
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
