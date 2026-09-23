import { Fragment, type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { Bug, CircleDot, ClipboardCheck, Inbox, Layers, Loader, MessageCircleQuestion, PenTool, Search, ShieldQuestion, Sparkles, SquareCheck, Wrench, type LucideIcon } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import { typingInto } from "./actions";
import { type Agent, type Bead, type BeadRecord, type Work, epicOf, stateOf, useBeadRecord } from "./api";

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

/// Where an arrow key takes the selection on a board whose lanes show COLUMNS, top to bottom.
/// Up and down stay in the lane; left and right go to the nearest lane with anything in it, at
/// the same height or its last card. Nothing chosen yet, or chosen and filtered away, starts at
/// the first card there is.
export function moveOn(columns: string[][], selected: string | undefined, key: string): string | undefined {
  const lane = columns.findIndex(ids => selected !== undefined && ids.includes(selected));
  if (lane < 0) return columns.find(ids => ids.length)?.[0];
  const row = columns[lane].indexOf(selected!);
  if (key === "ArrowUp") return columns[lane][Math.max(row - 1, 0)];
  if (key === "ArrowDown") return columns[lane][Math.min(row + 1, columns[lane].length - 1)];
  const step = key === "ArrowLeft" ? -1 : 1;
  for (let next = lane + step; next >= 0 && next < columns.length; next += step)
    if (columns[next].length) return columns[next][Math.min(row, columns[next].length - 1)];
  return selected;
}

const arrows = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"];

export function WorkBoard({ work, agents, onOpen, keys = true }: { work: Work; agents: Agent[]; onOpen: (id: string) => void; keys?: boolean }) {
  const [query, setQuery] = useState("");
  const [type, setType] = useState("all");
  const [priority, setPriority] = useState<PriorityFilter>("all");
  const [grouped, setGrouped] = useState(() => localStorage.getItem("cerebro-group-epics") !== "false");
  const lanes = useMemo(() => lanesOf(work), [work]);
  const present = useMemo(() => [...new Set(lanes.flatMap(lane => lane.beads.map(bead => bead.issue_type)))].sort(), [lanes]);
  const asking = new Set(agents.filter(agent => stateOf(agent) === "asking").map(agent => agent.name));
  const keep = (bead: Bead) => (type === "all" || bead.issue_type === type) && matchesPriority(bead, priority)
    && `${bead.id} ${bead.title}`.toLowerCase().includes(query.toLowerCase());
  const [selected, setSelected] = useState<string>();
  const cards = useRef(new Map<string, HTMLButtonElement>());
  const card = (bead: Bead) => {
    const needsYou = bead.labels.includes("human") || (bead.assignee !== undefined && bead.assignee !== null && asking.has(bead.assignee));
    const chosen = bead.id === selected;
    return <button key={bead.id} aria-current={chosen || undefined}
      ref={element => { if (element) cards.current.set(bead.id, element); else cards.current.delete(bead.id); }}
      onClick={() => chosen ? onOpen(bead.id) : setSelected(bead.id)}
      className={cn("mb-2 w-full rounded-lg border bg-card p-3 text-left shadow-xs transition hover:border-foreground/20 hover:bg-muted/50", needsYou && "border-amber-500/50",
        chosen && "border-primary ring-2 ring-primary/40 hover:border-primary")}>
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
  /// BEADS as the lane shows them: in epics, epics first, when grouping is on.
  const sections = (beads: Bead[]) => {
    if (!grouped) return [{ key: "", title: undefined as string | undefined, beads }];
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
    return order.map(key => ({ key, title: members.get(key)!.title as string | undefined, beads: members.get(key)!.beads }));
  };
  const shown = lanes.map(lane => {
    const beads = lane.beads.filter(keep).sort(lane.name === "Backlog" ? byPriority : () => 0);
    return { lane, count: beads.length, sections: sections(beads) };
  });
  const columns = shown.map(({ sections }) => sections.flatMap(section => section.beads.map(bead => bead.id)));
  const board = useRef({ columns, selected, keys, onOpen });
  board.current = { columns, selected, keys, onOpen };
  useEffect(() => {
    const press = (event: KeyboardEvent) => {
      const { columns, selected, keys, onOpen } = board.current;
      if (!keys || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || typingInto(event.target)) return;
      if (event.key === "Enter") {
        // A focused control - a card included, whose own click opens it once chosen - takes
        // its Enter itself; only with nothing focused does Enter mean the chosen card.
        if (event.target !== document.body || !selected || !columns.some(ids => ids.includes(selected))) return;
        event.preventDefault();
        onOpen(selected);
      } else if (arrows.includes(event.key)) {
        const next = moveOn(columns, selected, event.key);
        if (!next) return;
        event.preventDefault();
        setSelected(next);
        const element = cards.current.get(next);
        element?.focus({ preventScroll: true });
        element?.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
    };
    window.addEventListener("keydown", press);
    return () => window.removeEventListener("keydown", press);
  }, []);
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
      {shown.map(({ lane, count, sections }) => {
        return <section key={lane.name} aria-label={lane.name} className="min-h-60 rounded-xl border bg-muted/30 p-3">
          <h2 className="mb-1 flex items-center gap-2 text-sm font-medium"><lane.icon className="size-4 text-muted-foreground" />{lane.name}
            <span className="ml-auto rounded-full bg-muted px-2 text-xs text-muted-foreground">{count}</span></h2>
          {sections.map(section => section.title === undefined ? <Fragment key="all">{section.beads.map(card)}</Fragment>
            : <div key={section.key || "none"}>
              <p className="mt-3 mb-1.5 flex items-center gap-1.5 text-[11px] tracking-wider text-muted-foreground uppercase"><Layers className="size-3" /><span className="truncate" title={section.title}>{section.title}</span></p>
              {section.beads.map(card)}
            </div>)}
          {count === 0 && <p className="mt-3 text-xs text-muted-foreground">{lane.beads.length ? "Nothing here matches the filters." : "No work is in this column."}</p>}
        </section>;
      })}
    </div>
  </div>;
}

const texts: [string, string][] = [["description", "Description"], ["design", "Design"], ["acceptance_criteria", "Acceptance criteria"], ["notes", "Notes"]];
const facts: [string, string][] = [["owner", "Owner"], ["created_by", "Created by"], ["created_at", "Created"], ["updated_at", "Updated"], ["started_at", "Started"],
  ["closed_at", "Closed"], ["close_reason", "Close reason"], ["parent", "Parent"], ["external_ref", "External ref"]];
/// Fields shown by name above, or not worth a line: what is left is shown as it came.
const shownElsewhere = new Set(["id", "title", "status", "issue_type", "labels", "priority", "assignee", "dependencies", "dependents", "metadata", "revision",
  ...texts.map(([key]) => key), ...facts.map(([key]) => key)]);

const plain = (value: unknown) => typeof value === "string" ? value : JSON.stringify(value);
const when = (value: unknown) => {
  const time = typeof value === "string" ? Date.parse(value) : NaN;
  return Number.isNaN(time) ? plain(value) : new Date(time).toLocaleString();
};

function Related({ title, beads }: { title: string; beads: BeadRecord[] }) {
  return <section aria-label={title}>
    <h3 className="mb-1.5 text-xs font-medium tracking-wider text-muted-foreground uppercase">{title}</h3>
    <ul className="space-y-1 text-sm">{beads.map(bead => <li key={bead.id} className="flex items-center gap-2">
      <TypeIcon type={plain(bead.issue_type ?? "")} /><span className="font-mono text-xs text-muted-foreground">{bead.id}</span>
      <span className="min-w-0 flex-1 truncate">{plain(bead.title ?? "")}</span>
      {bead.dependency_type !== undefined && <Badge variant="outline">{plain(bead.dependency_type)}</Badge>}
      <Badge variant="secondary">{plain(bead.status ?? "")}</Badge>
    </li>)}</ul>
  </section>;
}

function BeadDetails({ record }: { record: BeadRecord }) {
  const present = (key: string) => record[key] !== undefined && record[key] !== null && record[key] !== "";
  const metadata = record.metadata && typeof record.metadata === "object" ? Object.entries(record.metadata as object) : [];
  const rest = Object.entries(record).filter(([key, value]) => !shownElsewhere.has(key) && value !== null && value !== undefined && value !== "");
  const rows: [string, string][] = [
    ...facts.filter(([key]) => present(key)).map(([key, name]): [string, string] => [name, key.endsWith("_at") ? when(record[key]) : plain(record[key])]),
    ...metadata.map(([key, value]): [string, string] => [key, key.endsWith("_at") ? when(value) : plain(value)]),
    ...rest.map(([key, value]): [string, string] => [key.replaceAll("_", " "), plain(value)]),
  ];
  return <>
    <dl className="grid grid-cols-[120px_1fr] gap-x-4 gap-y-2.5 text-sm">
      {rows.map(([term, value]) => <Fragment key={term}><dt className="text-muted-foreground">{term}</dt><dd className="break-words">{value}</dd></Fragment>)}
    </dl>
    {record.dependencies?.length ? <Related title="Depends on" beads={record.dependencies} /> : null}
    {record.dependents?.length ? <Related title="Needed by" beads={record.dependents} /> : null}
    {texts.filter(([key]) => present(key)).map(([key, name]) => <section key={key} aria-label={name}>
      <h3 className="mb-1.5 text-xs font-medium tracking-wider text-muted-foreground uppercase">{name}</h3>
      <div className="rounded-lg border bg-muted/30 p-3 text-sm leading-relaxed break-words whitespace-pre-wrap">{plain(record[key])}</div>
    </section>)}
  </>;
}

export function BeadDialog({ bead, lane, epic, onClose }: { bead: Bead; lane?: string; epic?: string; onClose: () => void }) {
  const read = useBeadRecord(bead.id);
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
    <DialogContent className="flex max-h-[90vh] flex-col sm:max-w-3xl">
      <DialogHeader>
        <DialogDescription className="font-mono">{bead.id} · read-only</DialogDescription>
        <DialogTitle className="text-lg">{bead.title}</DialogTitle>
      </DialogHeader>
      <div className="-mx-4 min-h-0 space-y-5 overflow-y-auto px-4">
        <dl className="grid grid-cols-[120px_1fr] gap-x-4 gap-y-2.5 text-sm">
          {rows.map(([term, value]) => <Fragment key={term}><dt className="text-muted-foreground">{term}</dt><dd>{value}</dd></Fragment>)}
        </dl>
        {read.state === "loading" && <p className="text-sm text-muted-foreground">Loading the rest of this bead…</p>}
        {read.state === "failed" && <p role="alert" className="text-sm text-destructive">Couldn’t load the rest of this bead: {read.error}</p>}
        {read.state === "read" && <BeadDetails record={read.record} />}
      </div>
    </DialogContent>
  </Dialog>;
}
