import { useState } from "react";
import { Search } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { type Agent, type Bead, running, since, stateOf } from "./api";
import { SessionScreen } from "./session";

const tones: Record<string, { dot: string; text: string; badge: string }> = {
  working: { dot: "bg-emerald-500 animate-breathe", text: "text-muted-foreground", badge: "bg-emerald-500/15 text-emerald-700 dark:text-emerald-400" },
  asking: { dot: "bg-amber-400", text: "text-amber-700 dark:text-amber-300", badge: "bg-amber-500/15 text-amber-700 dark:text-amber-300" },
  idle: { dot: "bg-sky-400", text: "text-muted-foreground", badge: "bg-sky-500/15 text-sky-700 dark:text-sky-300" },
  waiting: { dot: "bg-zinc-400", text: "text-muted-foreground", badge: "bg-zinc-500/15 text-zinc-700 dark:text-zinc-300" },
};
const offline = { dot: "border border-zinc-400 dark:border-zinc-600", text: "text-muted-foreground", badge: "bg-muted text-muted-foreground" };
const tone = (agent: Agent) => running(agent) ? tones[stateOf(agent)] ?? tones.waiting : offline;

export function StatusDot({ agent, className }: { agent: Agent; className?: string }) {
  return <span aria-hidden className={cn("inline-block size-2.5 shrink-0 rounded-full", tone(agent).dot, className)} />;
}

const activity = (agent: Agent) => stateOf(agent) === "asking" ? "asking you" : agent.phase ?? stateOf(agent);

export function FleetSidebar({ agents, selected, now, onSelect }: { agents: Agent[]; selected?: string; now: number; onSelect: (name: string) => void }) {
  const [filter, setFilter] = useState("");
  const shown = agents.filter(agent => `${agent.name} ${agent.role} ${agent.bead ?? ""}`.toLowerCase().includes(filter.toLowerCase()));
  const live = shown.filter(running);
  const gone = shown.filter(agent => !running(agent));
  const row = (agent: Agent) => {
    const active = agent.name === selected;
    return <button key={agent.name} onClick={() => onSelect(agent.name)} aria-current={active || undefined}
      className={cn("flex w-full items-center gap-3 rounded-lg px-2 py-2 text-left transition-colors hover:bg-muted", active && "bg-muted ring-1 ring-border", !running(agent) && "py-1.5 opacity-60")}>
      <StatusDot agent={agent} />
      <span className="min-w-0 flex-1">
        <span className="block font-medium">{agent.name}</span>
        {running(agent) && <span className={cn("block truncate text-xs", tone(agent).text)}>{agent.role} · {activity(agent)}</span>}
      </span>
      {running(agent)
        ? <span className="text-right text-[11px]">
            {agent.bead && <span className="block font-mono text-foreground/80">{agent.bead}</span>}
            <span className="block text-muted-foreground">{since(now, agent.phase_since ?? agent.since)}</span>
          </span>
        : <span className="text-xs text-muted-foreground">{agent.role}</span>}
    </button>;
  };
  const heading = (text: string) => <p className="px-2 pt-3 pb-1 text-[11px] font-medium tracking-wider text-muted-foreground uppercase">{text}</p>;
  return <aside aria-label="Fleet" className="flex w-full shrink-0 flex-col border-b md:w-80 md:border-r md:border-b-0">
    <div className="p-3">
      <div className="relative">
        <Search className="absolute top-2 left-2.5 size-4 text-muted-foreground" />
        <Input value={filter} onChange={event => setFilter(event.target.value)} placeholder="Filter agents…" aria-label="Filter agents" className="pl-8" />
      </div>
    </div>
    <nav className="flex-1 overflow-auto px-2 pb-3 text-sm">
      {heading(`Live · ${live.length}`)}
      {live.map(row)}
      {live.length === 0 && <p className="px-2 py-1 text-xs text-muted-foreground">No agent is running.</p>}
      {gone.length > 0 && <>{heading(`Offline · ${gone.length}`)}{gone.map(row)}</>}
    </nav>
    <footer className="flex flex-wrap gap-x-3 gap-y-1 border-t p-3 text-[11px] text-muted-foreground">
      {Object.entries(tones).map(([state, { dot }]) => <span key={state} className="inline-flex items-center gap-1"><span className={cn("size-2 rounded-full", dot.replace("animate-breathe", ""))} />{state}</span>)}
    </footer>
  </aside>;
}

export function AgentPane({ agent, bead, now }: { agent: Agent; bead?: Bead; now: number }) {
  const phaseAge = since(now, agent.phase_since ?? agent.since);
  return <section aria-label={`${agent.name} details`} className="flex min-h-0 min-w-0 flex-1 flex-col gap-4">
    <div className="flex flex-wrap items-start justify-between gap-4">
      <div className="min-w-0">
        <div className="flex items-center gap-2.5">
          <h2 className="text-xl font-semibold">{agent.name}</h2>
          <Badge variant="outline">{agent.role}</Badge>
          <Badge className={tone(agent).badge}><StatusDot agent={agent} className="size-1.5" />{stateOf(agent)}</Badge>
        </div>
        <p className="mt-1 truncate text-sm text-muted-foreground">
          {agent.bead ? <><span className="font-mono text-foreground/80">{agent.bead}</span>{bead && ` · ${bead.title}`}</> : "No bead"}
          {agent.phase && <> · <span className="text-foreground/80">{agent.phase}</span></>}
          {phaseAge && ` for ${phaseAge}`}
        </p>
        {agent.diagnostic && <p className="mt-1 text-sm text-amber-700 dark:text-amber-300">{agent.diagnostic}</p>}
      </div>
      <dl className="grid grid-cols-3 gap-6 text-xs">
        <div><dt className="text-muted-foreground">Since</dt><dd className="mt-0.5">{agent.since ? new Date(agent.since).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "—"}</dd></div>
        <div><dt className="text-muted-foreground">Sessions</dt><dd className="mt-0.5">{agent.sessions ?? "—"}</dd></div>
        <div><dt className="text-muted-foreground">PID</dt><dd className="mt-0.5 font-mono">{agent.pid ?? "—"}</dd></div>
      </dl>
    </div>
    {running(agent)
      ? <SessionScreen key={agent.name} name={agent.name} />
      : <div className="grid flex-1 place-items-center rounded-xl border border-dashed text-sm text-muted-foreground">{agent.name} is not running, so there is no session to show.</div>}
  </section>;
}
