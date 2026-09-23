import { Fragment, type ReactNode, useMemo, useState } from "react";
import { Bug, CircleDot, ClipboardCheck, Inbox, Layers, Loader, MessageCircleQuestion, PenTool, Search, ShieldQuestion, Sparkles, SquareCheck, Wrench, type LucideIcon } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import { type Agent, type Bead, type Work, epicOf, stateOf } from "./api";

export type Lane = { name: string; icon: LucideIcon; beads: Bead[] };
export const lanesOf = (work: Work): Lane[] => [
  { name: "Backlog", icon: Inbox, beads: [...work.unplanned, ...work.paused] },
  { name: "Designing UX", icon: PenTool, beads: work.being_planned },
  { name: "UX designed", icon: ClipboardCheck, beads: [...work.ux_agreed, ...work.planned] },
  { name: "In progress", icon: Loader, beads: work.claimed },
  { name: "Unverified", icon: ShieldQuestion, beads: work.merged },
];

const types: Record<string, [LucideIcon, string]> = {
  feature: [Sparkles, "text-violet-500 dark:text-violet-300"],
  bug: [Bug, "text-red-500 dark:text-red-300"],
  task: [SquareCheck, "text-sky-600 dark:text-sky-300"],
  chore: [Wrench, "text-zinc-500 dark:text-zinc-400"],
  epic: [Layers, "text-fuchsia-500 dark:text-fuchsia-300"],
};
const priorities = ["bg-red-500/15 text-red-700 border-red-500/30 dark:text-red-300", "bg-orange-500/15 text-orange-700 border-orange-500/30 dark:text-orange-300", "bg-yellow-500/15 text-yellow-800 border-yellow-500/30 dark:text-yellow-300", "bg-muted text-foreground/80 border-border", "bg-transparent text-muted-foreground border-border"];

export function TypeIcon({ type }: { type: string }) {
  const [Icon, colour] = types[type] ?? [CircleDot, "text-muted-foreground"];
  return <Icon aria-label={type} className={cn("size-3.5 shrink-0", colour)} />;
}
export function PriorityBadge({ priority }: { priority?: number | null }) {
  return priority === undefined || priority === null
    ? <span className="rounded border border-dashed px-1.5 text-[11px] text-muted-foreground">unranked</span>
    : <span className={cn("rounded border px-1.5 text-[11px] font-medium", priorities[Math.min(priority, 4)])}>P{priority}</span>;
}

const byPriority = (a: Bead, b: Bead) => (a.priority ?? 99) - (b.priority ?? 99);
type PriorityFilter = "all" | "0" | "1" | "2+" | "unranked";
const matchesPriority = (bead: Bead, filter: PriorityFilter) => filter === "all" ? true
  : filter === "unranked" ? bead.priority === undefined || bead.priority === null
  : filter === "2+" ? (bead.priority ?? -1) >= 2 : bead.priority === Number(filter);

export function WorkBoard({ work, agents, onOpen }: { work: Work; agents: Agent[]; onOpen: (id: string) => void }) {
  const [query, setQuery] = useState("");
  const [type, setType] = useState("all");
  const [priority, setPriority] = useState<PriorityFilter>("all");
  const [grouped, setGrouped] = useState(() => localStorage.getItem("cerebro-group-epics") !== "false");
  const lanes = useMemo(() => lanesOf(work), [work]);
  const present = useMemo(() => [...new Set(lanes.flatMap(lane => lane.beads.map(bead => bead.issue_type)))].sort(), [lanes]);
  const asking = new Set(agents.filter(agent => stateOf(agent) === "asking").map(agent => agent.name));
  const keep = (bead: Bead) => (type === "all" || bead.issue_type === type) && matchesPriority(bead, priority)
    && `${bead.id} ${bead.title}`.toLowerCase().includes(query.toLowerCase());
  const card = (bead: Bead) => {
    const needsYou = bead.labels.includes("human") || (bead.assignee !== undefined && bead.assignee !== null && asking.has(bead.assignee));
    return <button key={bead.id} onClick={() => onOpen(bead.id)}
      className={cn("mb-2 w-full rounded-lg border bg-card p-3 text-left shadow-xs transition hover:border-foreground/20 hover:bg-muted/50", needsYou && "border-amber-500/50")}>
      <div className="flex items-center gap-2 text-[11px]">
        <TypeIcon type={bead.issue_type} />
        <span className="font-mono text-muted-foreground">{bead.id}</span>
        <span className="ml-auto"><PriorityBadge priority={bead.priority} /></span>
      </div>
      <p className="mt-1.5 text-sm leading-snug">{bead.title}</p>
      {(bead.assignee || needsYou) && <div className="mt-2 flex items-center gap-1.5 text-xs text-muted-foreground">
        {bead.assignee && <><span className="grid size-5 place-items-center rounded-full bg-primary/15 text-[10px] font-semibold text-primary">{bead.assignee[0]}</span>{bead.assignee}</>}
        {needsYou && <span className="ml-auto inline-flex items-center gap-1 text-amber-700 dark:text-amber-300"><MessageCircleQuestion className="size-3" />{bead.labels.includes("human") ? "needs you" : "asking"}</span>}
      </div>}
    </button>;
  };
  const groups = (beads: Bead[]) => {
    if (!grouped) return beads.map(card);
    const order: string[] = [];
    const members = new Map<string, { title: string; beads: Bead[] }>();
    for (const bead of beads) {
      const epic = epicOf(bead.id, work.epics);
      const key = epic?.id ?? "";
      if (!members.has(key)) { order.push(key); members.set(key, { title: epic?.title ?? "No epic", beads: [] }); }
      members.get(key)!.beads.push(bead);
    }
    // Loose beads last, so the epics read first.
    order.sort((a, b) => Number(a === "") - Number(b === ""));
    return order.map(key => <div key={key || "none"}>
      <p className="mt-3 mb-1.5 flex items-center gap-1.5 text-[11px] tracking-wider text-muted-foreground uppercase"><Layers className="size-3" /><span className="truncate" title={members.get(key)!.title}>{members.get(key)!.title}</span></p>
      {members.get(key)!.beads.map(card)}
    </div>);
  };
  return <div className="flex min-h-0 flex-1 flex-col">
    <div className="flex shrink-0 flex-wrap items-center gap-x-4 gap-y-2 border-b px-5 py-3 text-xs">
      <div className="relative w-72">
        <Search className="absolute top-2 left-2.5 size-4 text-muted-foreground" />
        <Input value={query} onChange={event => setQuery(event.target.value)} placeholder="Search beads by id or title…" aria-label="Search beads" className="pl-8" />
      </div>
      <div className="flex items-center gap-2"><span className="text-muted-foreground">Type</span>
        <ToggleGroup aria-label="Type" variant="outline" size="sm" value={[type]} onValueChange={(value: string[]) => setType(value[0] ?? "all")}>
          <ToggleGroupItem value="all">All</ToggleGroupItem>
          {present.map(name => <ToggleGroupItem key={name} value={name} className="capitalize">{name}</ToggleGroupItem>)}
        </ToggleGroup>
      </div>
      <div className="flex items-center gap-2"><span className="text-muted-foreground">Priority</span>
        <ToggleGroup aria-label="Priority" variant="outline" size="sm" value={[priority]} onValueChange={(value: string[]) => setPriority((value[0] ?? "all") as PriorityFilter)}>
          {(["all", "0", "1", "2+", "unranked"] as const).map(value => <ToggleGroupItem key={value} value={value}>{value === "all" ? "All" : value === "unranked" ? "Unranked" : `P${value}`}</ToggleGroupItem>)}
        </ToggleGroup>
      </div>
      <label className="ml-auto flex cursor-pointer items-center gap-2 text-muted-foreground">Group by epic
        <Switch size="sm" checked={grouped} onCheckedChange={on => { setGrouped(on); localStorage.setItem("cerebro-group-epics", String(on)); }} />
      </label>
    </div>
    <div className="grid min-h-0 flex-1 auto-cols-[minmax(250px,1fr)] grid-flow-col content-start gap-4 overflow-auto p-5">
      {lanes.map(lane => {
        const beads = lane.beads.filter(keep).sort(lane.name === "Backlog" ? byPriority : () => 0);
        return <section key={lane.name} aria-label={lane.name} className="min-h-60 rounded-xl border bg-muted/30 p-3">
          <h2 className="mb-1 flex items-center gap-2 text-sm font-medium"><lane.icon className="size-4 text-muted-foreground" />{lane.name}
            <span className="ml-auto rounded-full bg-muted px-2 text-xs text-muted-foreground">{beads.length}</span></h2>
          {groups(beads)}
          {beads.length === 0 && <p className="mt-3 text-xs text-muted-foreground">{lane.beads.length ? "Nothing here matches the filters." : "No work is in this column."}</p>}
        </section>;
      })}
    </div>
  </div>;
}

export function BeadDialog({ bead, lane, epic, onClose }: { bead: Bead; lane?: string; epic?: string; onClose: () => void }) {
  const rows: [string, ReactNode][] = [
    ["Workflow", lane ?? bead.status],
    ["Priority", <PriorityBadge priority={bead.priority} />],
    ["Type", <span className="inline-flex items-center gap-1.5 capitalize"><TypeIcon type={bead.issue_type} />{bead.issue_type}</span>],
    ["Epic", epic ?? "—"],
    ["Current owner", bead.assignee ?? "—"],
    ["Attention", bead.labels.includes("human") ? "Awaiting human input" : "—"],
    ["Status", bead.status],
    ["Labels", bead.labels.length ? <span className="flex flex-wrap gap-1">{bead.labels.map(label => <Badge key={label} variant="secondary">{label}</Badge>)}</span> : "—"],
  ];
  return <Dialog open onOpenChange={open => { if (!open) onClose(); }}>
    <DialogContent className="sm:max-w-lg">
      <DialogHeader>
        <DialogDescription className="font-mono">{bead.id} · read-only</DialogDescription>
        <DialogTitle className="text-lg">{bead.title}</DialogTitle>
      </DialogHeader>
      <dl className="grid grid-cols-[120px_1fr] gap-x-4 gap-y-2.5 text-sm">
        {rows.map(([term, value]) => <Fragment key={term}><dt className="text-muted-foreground">{term}</dt><dd>{value}</dd></Fragment>)}
      </dl>
    </DialogContent>
  </Dialog>;
}
