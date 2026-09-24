import { Fragment, type ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { Bug, CircleDot, ClipboardCheck, Inbox, Layers, Loader, MessageCircleQuestion, PenTool, Search, ShieldQuestion, Sparkles, SquareCheck, Wrench, type LucideIcon } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
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

/// What the board said about the last ranking: pending while `bd` runs, then its answer.
type Ranked = { text: string; tone: "pending" | "done" | "failed" };

/// Rank ID at P TO through the service, which writes and pushes it as the fleet view's own keys do.
async function rank(id: string, from: number | null | undefined, to: number): Promise<Ranked> {
  try {
    const response = await fetch(`/api/beads/${encodeURIComponent(id)}/priority`, {
      method: "POST", headers: { "content-type": "application/json", "x-cerebro-input": "1" }, body: JSON.stringify({ to, from: from ?? null }) });
    const reply = await response.json().catch(() => undefined) as { done?: boolean; text?: string } | undefined;
    if (typeof reply?.text !== "string") return { text: `Couldn’t set ${id} to P${to}: ${response.statusText || "no answer"}`, tone: "failed" };
    return { text: reply.text, tone: reply.done ? "done" : "failed" };
  } catch (error) {
    return { text: `Couldn’t set ${id} to P${to}: ${error instanceof Error ? error.message : String(error)}`, tone: "failed" };
  }
}

export function WorkBoard({ work, agents, onOpen, onChanged, keys = true }: { work: Work; agents: Agent[]; onOpen: (id: string) => void; onChanged?: () => Promise<unknown>; keys?: boolean }) {
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
  const [ranked, setRanked] = useState<Ranked>();
  // One write at a time, in the order pressed, as the fleet view's write worker runs them.
  const writes = useRef(Promise.resolve());
  // What the last press still on its way asked for, and how many are, so the sentence for the next
  // press starts from there rather than from a board that has not caught up. Wording only: `bd` is
  // given the new number alone, and every press is written.
  const intended = useRef(new Map<string, { to: number; queued: number }>());
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
  const priorityOf = new Map(lanes.flatMap(lane => lane.beads.map(bead => [bead.id, bead.priority] as const)));
  const board = useRef({ columns, selected, keys, onOpen, onChanged, priorityOf });
  board.current = { columns, selected, keys, onOpen, onChanged, priorityOf };
  useEffect(() => {
    const press = (event: KeyboardEvent) => {
      const { columns, selected, keys, onOpen, onChanged, priorityOf } = board.current;
      if (!keys || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || typingInto(event.target)) return;
      if (event.key === "Enter") {
        // A focused control - a card included, whose own click opens it once chosen - takes
        // its Enter itself; only with nothing focused does Enter mean the chosen card.
        if (event.target !== document.body || !selected || !columns.some(ids => ids.includes(selected))) return;
        event.preventDefault();
        onOpen(selected);
      } else if (/^[0-4]$/.test(event.key)) {
        if (!selected || !columns.some(ids => ids.includes(selected))) return;
        event.preventDefault();
        const to = Number(event.key);
        const before = intended.current.get(selected);
        const from = before?.to ?? priorityOf.get(selected);
        setRanked({ text: `${selected}: P${from ?? "?"} → P${to}…`, tone: "pending" });
        intended.current.set(selected, { to, queued: (before?.queued ?? 0) + 1 });
        writes.current = writes.current.then(async () => {
          try {
            setRanked(await rank(selected, from, to));
            await onChanged?.();
          } finally {
            const now = intended.current.get(selected);
            if (now && --now.queued === 0) intended.current.delete(selected);
          }
        }).catch(() => undefined);
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
      {ranked && <p role="status" aria-label="Ranking" className={cn("ml-auto", ranked.tone === "pending" ? "text-muted-foreground" : ranked.tone === "failed" ? "text-destructive" : "text-foreground")}>{ranked.text}</p>}
      <label className={cn("flex cursor-pointer items-center gap-2 text-muted-foreground", !ranked && "ml-auto")}>Group by epic
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

function Facts({ record, summary }: { record?: BeadRecord; summary: [string, ReactNode][] }) {
  const present = (key: string) => record?.[key] !== undefined && record[key] !== null && record[key] !== "";
  const metadata = record?.metadata && typeof record.metadata === "object" ? Object.entries(record.metadata as object) : [];
  const rest = Object.entries(record ?? {}).filter(([key, value]) => !shownElsewhere.has(key) && value !== null && value !== undefined && value !== "");
  const rows: [string, ReactNode][] = [
    ...summary,
    ...facts.filter(([key]) => present(key)).map(([key, name]): [string, string] => [name, key.endsWith("_at") ? when(record![key]) : plain(record![key])]),
    ...metadata.map(([key, value]): [string, string] => [key, key.endsWith("_at") ? when(value) : plain(value)]),
    ...rest.map(([key, value]): [string, string] => [key.replaceAll("_", " "), plain(value)]),
  ];
  return <div className="space-y-5">
    <dl className="grid grid-cols-[140px_1fr] gap-x-4 gap-y-2.5 text-sm">
      {rows.map(([term, value]) => <Fragment key={term}><dt className="text-muted-foreground">{term}</dt><dd className="break-words">{value}</dd></Fragment>)}
    </dl>
    {record?.dependencies?.length ? <Related title="Depends on" beads={record.dependencies} /> : null}
    {record?.dependents?.length ? <Related title="Needed by" beads={record.dependents} /> : null}
  </div>;
}

/// A bead's text as markdown. Raw HTML in it is shown as text, never rendered: beads carry what
/// GitHub issues and agents wrote.
function Text({ source }: { source: string }) {
  return <div className="bead-text text-sm leading-relaxed break-words">
    <Markdown remarkPlugins={[remarkGfm]} components={{ a: ({ node: _, ...props }) => <a {...props} target="_blank" rel="noreferrer" /> }}>{source}</Markdown>
  </div>;
}

export function BeadDialog({ bead, lane, epic, onClose }: { bead: Bead; lane?: string; epic?: string; onClose: () => void }) {
  const read = useBeadRecord(bead.id);
  const record = read.state === "read" ? read.record : undefined;
  const summary: [string, ReactNode][] = [
    ["Workflow", lane ?? bead.status],
    ["Epic", epic ?? "—"],
    ["Current owner", bead.assignee ?? "—"],
    ["Attention", bead.labels.includes("human") ? "Awaiting human input" : "—"],
  ];
  const tabs: [string, string][] = [["overview", "Overview"],
    ...texts.filter(([key]) => typeof record?.[key] === "string" && record[key] !== ""), ...(record ? [["raw", "Raw"] as [string, string]] : [])];
  const [tab, setTab] = useState("overview");
  const buttons = useRef(new Map<string, HTMLButtonElement>());
  const step = (event: React.KeyboardEvent, at: number) => {
    const to = event.key === "ArrowRight" ? at + 1 : event.key === "ArrowLeft" ? at - 1 : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : undefined;
    if (to === undefined) return;
    event.preventDefault();
    const key = tabs[(to + tabs.length) % tabs.length][0];
    setTab(key);
    buttons.current.get(key)?.focus();
  };
  const labels = record && Array.isArray(record.labels) ? record.labels.map(plain) : bead.labels;
  const status = typeof record?.status === "string" ? record.status : bead.status;
  const type = typeof record?.issue_type === "string" ? record.issue_type : bead.issue_type;
  return <Dialog open onOpenChange={open => { if (!open) onClose(); }}>
    <DialogContent className="flex h-[85vh] flex-col gap-3 sm:max-w-3xl">
      <DialogHeader>
        <DialogDescription className="font-mono">{bead.id} · read-only</DialogDescription>
        <DialogTitle className="text-lg">{bead.title}</DialogTitle>
        <div className="flex flex-wrap items-center gap-1.5 text-xs">
          <Badge variant="outline">{status}</Badge>
          <PriorityBadge priority={bead.priority} />
          <Badge variant="outline" className="capitalize"><TypeIcon type={type} />{type}</Badge>
          {labels.map(label => <Badge key={label} variant="secondary">{label}</Badge>)}
        </div>
      </DialogHeader>
      <div role="tablist" aria-label="Bead" className="-mx-4 flex gap-1 overflow-x-auto border-b px-4">
        {tabs.map(([key, name], at) => <button key={key} role="tab" id={`bead-tab-${key}`} aria-selected={tab === key} aria-controls="bead-panel"
          tabIndex={tab === key ? 0 : -1} ref={element => { if (element) buttons.current.set(key, element); else buttons.current.delete(key); }}
          onClick={() => setTab(key)} onKeyDown={event => step(event, at)}
          className={cn("-mb-px shrink-0 border-b-2 px-3 py-2 text-sm transition-colors", tab === key ? "border-primary text-foreground" : "border-transparent text-muted-foreground hover:text-foreground")}>{name}</button>)}
      </div>
      <div role="tabpanel" id="bead-panel" aria-labelledby={`bead-tab-${tab}`} tabIndex={0} className="-mx-4 min-h-0 flex-1 overflow-y-auto px-4 pb-2 outline-none">
        {tab === "overview" && <>
          <Facts record={record} summary={summary} />
          {read.state === "loading" && <p className="mt-4 text-sm text-muted-foreground">Loading the rest of this bead…</p>}
          {read.state === "failed" && <p role="alert" className="mt-4 text-sm text-destructive">Couldn’t load the rest of this bead: {read.error}</p>}
        </>}
        {tab === "raw" && record && <pre className="font-mono text-xs break-words whitespace-pre-wrap text-muted-foreground">{JSON.stringify(record, null, 2)}</pre>}
        {tab !== "overview" && tab !== "raw" && typeof record?.[tab] === "string" && <Text source={record[tab] as string} />}
      </div>
    </DialogContent>
  </Dialog>;
}
