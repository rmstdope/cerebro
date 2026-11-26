import { type CSSProperties, type PointerEvent, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { cn } from "@/lib/utils";
import { typingInto } from "./actions";

/// Where the fleet's time went (cb-koio.2): a treemap of roles, then a role's agents, then an
/// agent's phases, read from /api/time once a minute. Every number is seconds.

export type TimeActivity = { name: string; seconds: number };
export type TimePhase = { name: string; working: number; waiting: number; activities: TimeActivity[]; undetailed_before: number; undetailed: number };
export type TimeAgent = { name: string; working: number; waiting: number; sessions: number; phases: TimePhase[] };
export type TimeRole = { name: string; working: number; waiting: number; sessions: number; agents: TimeAgent[] };
export type TimeReport = { read_at: string; detail_from: string | null; roles: TimeRole[] };

export type Period = "24h" | "7d" | "30d" | "all";
const periods: [Period, string][] = [["24h", "24 hours"], ["7d", "7 days"], ["30d", "30 days"], ["all", "All"]];
const lastWords: Record<Period, string> = { "24h": "24 hours", "7d": "7 days", "30d": "30 days", all: "" };

type Kind = "role" | "agent" | "phase" | "other";
/// One tile: a role, an agent, a phase, or the `Other` gathering of the small ones at a level.
type Node = {
  name: string;
  label: string;
  kind: Kind;
  working: number;
  waiting: number;
  colour: string;
  sessions?: number;
  children: Node[];
  /// What the children are, for an `Other` tile's name and for the hint.
  childKind?: "roles" | "agents" | "phases";
  phase?: TimePhase;
};

const OTHER = "Other";
const SMALL = 0.02;
const MINUTE = 60_000;

const roleColours: Record<string, string> = {
  producer: "#6d28d9", orchestrator: "#2563eb", ux: "#0891b2", bugfixer: "#059669", verifier: "#d97706", qa: "#db2777",
  architect: "#4b5563", "user-feedback": "#c026d3", reviewer: "#0f766e", planner: "#4338ca", implementer: "#0369a1", "build-design": "#0d9488",
};
const phaseColours: Record<string, string> = {
  design: "#6d28d9", plan: "#6d28d9", build: "#2563eb", ci: "#0891b2", review: "#059669", merge: "#d97706", rebase: "#4b5563",
  gate: "#4f46e5", triage: "#db2777", sweep: "#0d9488", ux: "#c026d3", agree: "#e11d48", verify: "#ea580c", prepare: "#4d7c0f",
  bead: "#9333ea", daily: "#0e7490", index: "#475569",
};
const spare = ["#7c3aed", "#0369a1", "#0f766e", "#b45309", "#be185d", "#4338ca", "#15803d", "#9f1239"];
const OTHER_COLOUR = "#a1a1aa";
const hashed = (name: string) => spare[[...name].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) >>> 0, 7) % spare.length];
const colourOf = (table: Record<string, string>, name: string) => table[name] ?? hashed(name);
const phaseLabel = (name: string) => name === "ci" ? "waiting on CI" : name;

/// Hours as the page writes them: whole from 10 up, else to one decimal, never a trailing `.0`.
export const hours = (seconds: number) => {
  const value = seconds / 3600;
  return value >= 10 ? String(Math.round(value)) : String(Math.round(value * 10) / 10);
};
const dayMonth = (iso: string) => new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
const clock = (iso: string) => new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
const total = (node: { working: number; waiting: number }) => node.working + node.waiting;

/// The report as tiles. Without WAITING, the time waiting on the navigator counts for nothing: the
/// tiles are sized by working time alone, and one that only waited is gone.
function tree(report: TimeReport, waiting: boolean): Node {
  const kept = (seconds: number) => waiting ? seconds : 0;
  const roles = report.roles.map((role): Node => ({
    name: role.name, label: role.name, kind: "role", working: role.working, waiting: kept(role.waiting), sessions: role.sessions,
    colour: colourOf(roleColours, role.name), childKind: "agents",
    children: role.agents.map((agent): Node => ({
      name: agent.name, label: agent.name, kind: "agent", working: agent.working, waiting: kept(agent.waiting), sessions: agent.sessions,
      colour: colourOf(roleColours, role.name), childKind: "phases",
      children: agent.phases.map((phase): Node => ({
        name: phase.name, label: phaseLabel(phase.name), kind: "phase", working: phase.working, waiting: kept(phase.waiting),
        colour: colourOf(phaseColours, phase.name), children: [], phase,
      })),
    })),
  }));
  const sum = (key: "working" | "waiting") => roles.reduce((value, role) => value + role[key], 0);
  return { name: "", label: "All roles", kind: "role", working: sum("working"), waiting: sum("waiting"), colour: "", children: roles, childKind: "roles" };
}

/// NODE's children as tiles: largest first, with two or more under 2% of the level gathered into
/// one `Other`. Inside an `Other` nothing is gathered again.
function tilesOf(node: Node): Node[] {
  const items = node.children.filter(item => total(item) > 0).sort((a, b) => total(b) - total(a));
  if (node.kind === "other") return items;
  const whole = items.reduce((sum, item) => sum + total(item), 0);
  const small = items.filter(item => total(item) < whole * SMALL);
  if (small.length < 2) return items;
  const kind = node.childKind ?? "agents";
  return [...items.filter(item => !small.includes(item)), {
    name: OTHER, label: `${OTHER} · ${small.length} ${kind}`, kind: "other", childKind: kind, colour: OTHER_COLOUR, children: small,
    working: small.reduce((sum, item) => sum + item.working, 0), waiting: small.reduce((sum, item) => sum + item.waiting, 0),
  }];
}

/// The deepest node PATH reaches from ROOT, and the names that reached it: a name the period no
/// longer has ends the walk there.
function walk(root: Node, path: string[]) {
  const trail: Node[] = [root];
  for (const name of path) {
    const next = tilesOf(trail[trail.length - 1]).find(item => item.name === name);
    if (!next || next.kind === "phase") break;
    trail.push(next);
  }
  return trail;
}

type Rect = { x: number; y: number; w: number; h: number };
/// A squarified treemap: VALUES (largest first) laid into W by H, each rectangle's area its share.
export function squarify(values: number[], w: number, h: number): Rect[] {
  const sum = values.reduce((a, b) => a + b, 0);
  if (!sum || w <= 0 || h <= 0) return values.map(() => ({ x: 0, y: 0, w: 0, h: 0 }));
  const areas = values.map(value => value * w * h / sum);
  const out: Rect[] = [];
  let x = 0, y = 0, width = w, height = h, i = 0;
  while (i < areas.length) {
    const side = Math.min(width, height);
    const worst = (row: number[]) => {
      const s = row.reduce((a, b) => a + b, 0);
      return Math.max(side * side * Math.max(...row) / (s * s), s * s / (side * side * Math.min(...row)));
    };
    const row = [areas[i]];
    let j = i + 1;
    while (j < areas.length && worst([...row, areas[j]]) <= worst(row)) row.push(areas[j++]);
    const s = row.reduce((a, b) => a + b, 0);
    if (width >= height) {
      const across = s / height;
      let at = y;
      for (const a of row) { out.push({ x, y: at, w: across, h: a / across }); at += a / across; }
      x += across; width -= across;
    } else {
      const down = s / width;
      let at = x;
      for (const a of row) { out.push({ x: at, y, w: a / down, h: down }); at += a / down; }
      y += down; height -= down;
    }
    i = j;
  }
  return out;
}

const storage = {
  get(key: string) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key: string, value: string) { try { localStorage.setItem(key, value); } catch { /* a convenience only */ } },
};
const savedPeriod = (): Period => { const value = storage.get("cerebro-time-period"); return periods.some(([key]) => key === value) ? value as Period : "7d"; };
const savedWaiting = () => storage.get("cerebro-time-waiting") === "1";
const savedPath = (): string[] => {
  try { const value = JSON.parse(storage.get("cerebro-time-path") ?? "[]"); return Array.isArray(value) ? value.filter(item => typeof item === "string") : []; } catch { return []; }
};

/// A read fails as `outdated` when the service has no /api/time at all: a newer one answers 404,
/// one built before the Time tab answers with the page itself. Retrying cannot mend either.
type Failure = false | "read" | "outdated";

/// The report for PERIOD, read now and once a minute. A failed read keeps what was last read; a
/// new period keeps the old report on screen until its own arrives.
function useTimeReport(period: Period) {
  const [report, setReport] = useState<TimeReport>();
  const [failed, setFailed] = useState<Failure>(false);
  const [shownPeriod, setShownPeriod] = useState<Period>();
  useEffect(() => {
    let live = true;
    const read = async () => {
      let failure: Failure = "read";
      try {
        const response = await fetch(`/api/time?period=${period}`);
        if (response.status === 404 || (response.ok && response.headers.get("content-type")?.startsWith("text/html"))) failure = "outdated";
        if (!response.ok || failure === "outdated") throw new Error(response.statusText);
        const body = await response.json() as TimeReport;
        if (!Array.isArray(body?.roles)) throw new Error("not a time report");
        if (live) { setReport(body); setShownPeriod(period); setFailed(false); }
      } catch {
        if (live) setFailed(failure);
      }
    };
    void read();
    const timer = setInterval(() => void read(), MINUTE);
    return () => { live = false; clearInterval(timer); };
  }, [period]);
  return { report, failed, shownPeriod };
}

function useNarrow() {
  const query = "(max-width: 599px)";
  const [narrow, setNarrow] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const list = window.matchMedia(query);
    const change = () => setNarrow(list.matches);
    list.addEventListener("change", change);
    return () => list.removeEventListener("change", change);
  }, []);
  return narrow;
}

/// The size of the element the returned ref is given, kept as it resizes.
function useSize<T extends HTMLElement>() {
  const [element, ref] = useState<T | null>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    if (!element) return;
    const measure = () => setSize(size => size.w === element.clientWidth && size.h === element.clientHeight ? size : { w: element.clientWidth, h: element.clientHeight });
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [element]);
  return [ref, size, element] as const;
}

/// Where an arrow key takes the selection among RECTS: the nearest tile whose centre lies that way.
function nearest(rects: Rect[], from: number, key: string) {
  const centre = (r: Rect) => [r.x + r.w / 2, r.y + r.h / 2];
  const [cx, cy] = centre(rects[from]);
  let best = from, bestScore = Infinity;
  rects.forEach((rect, index) => {
    if (index === from) return;
    const [x, y] = centre(rect);
    const dx = x - cx, dy = y - cy;
    const ahead = key === "ArrowRight" ? dx : key === "ArrowLeft" ? -dx : key === "ArrowDown" ? dy : -dy;
    const aside = key === "ArrowRight" || key === "ArrowLeft" ? Math.abs(dy) : Math.abs(dx);
    if (ahead <= 1) return;
    const score = ahead + aside * 2;
    if (score < bestScore) { bestScore = score; best = index; }
  });
  return best;
}

const hatch = "repeating-linear-gradient(45deg,#a1a1aa 0 6px,#d4d4d8 6px 12px)";

/// The waiting band's label, as long as WIDTH pixels allow.
function bandLabel(waiting: number, width: number) {
  const n = hours(waiting);
  const fits = (text: string) => text.length * 6.6 + 16 <= width;
  return [`${n} h waiting on you`, `${n} h waiting`, `${n} h`].find(fits) ?? "";
}

/// The lines inside a phase tile: what the agent was doing, largest first, then the time nothing
/// says anything about.
function activityLines(phase: TimePhase, detailFrom: string | null, roomy: boolean) {
  const lines = phase.activities.filter(item => item.seconds >= 360).map(item => `· ${item.name} ${hours(item.seconds)} h`);
  const before = phase.undetailed_before >= 360 ? phase.undetailed_before : 0;
  const after = phase.undetailed >= 360 ? phase.undetailed : 0;
  if (roomy && before && detailFrom) {
    lines.push(`· no detail (before ${dayMonth(detailFrom)}) ${hours(before)} h`);
    if (after) lines.push(`· no detail ${hours(after)} h`);
  } else if (before + after) {
    lines.push(`· no detail ${hours(before + after)} h`);
  }
  return lines;
}

function PointingBox({ node, whole, waiting, style }: { node: Node; whole: number; waiting: boolean; style: CSSProperties }) {
  const share = whole ? Math.round(total(node) / whole * 100) : 0;
  // Only the agents that have a tile: without the waiting time, one that only waited has none.
  const shown = node.children.filter(item => total(item) > 0);
  const hint = node.kind === "role" ? "Click to see its agents" : node.kind === "agent" ? "Click to see its phases" : node.kind === "other" ? "Click to see them" : undefined;
  return <div role="tooltip" style={style} className="pointer-events-none absolute z-20 w-56 rounded-md bg-zinc-900 px-3 py-2 text-xs leading-relaxed text-white shadow-lg">
    <div className="font-semibold break-words">{node.label}</div>
    <div>{hours(total(node))} h · {share}% of all time</div>
    {waiting && <div>{hours(node.working)} h working · {hours(node.waiting)} h waiting on you</div>}
    {node.kind === "role" && <div>{shown.length} agents · {shown.reduce((sum, item) => sum + (item.sessions ?? 0), 0)} sessions</div>}
    {node.kind === "agent" && <div>{node.sessions ?? 0} sessions</div>}
    {hint && <div className="opacity-70">{hint}</div>}
  </div>;
}

export function TimeTab({ keys }: { keys: boolean }) {
  const [period, setPeriod] = useState<Period>(savedPeriod);
  const [path, setPath] = useState<string[]>(savedPath);
  const [waiting, setWaiting] = useState(savedWaiting);
  const { report, failed, shownPeriod } = useTimeReport(period);
  const narrow = useNarrow();
  const [selectedName, setSelectedName] = useState<string>();
  const [pointed, setPointed] = useState<string>();
  const [keyed, setKeyed] = useState(false);
  const [mapRef, size, tilesElement] = useSize<HTMLElement>();
  // The tiles take the keyboard when the tab opens, as the tab's first stop, and only then.
  const focused = useRef(false);
  useEffect(() => {
    if (tilesElement && !focused.current) { focused.current = true; tilesElement.focus({ preventScroll: true }); }
  }, [tilesElement]);
  const pressTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const pressed = useRef(false);

  const root = useMemo(() => report && tree(report, waiting), [report, waiting]);
  const trail = root ? walk(root, path) : [];
  const here = trail[trail.length - 1];
  const tiles = here ? tilesOf(here) : [];
  const rects = useMemo(() => squarify(tiles.map(total), size.w, size.h), [tiles.map(total).join(), size.w, size.h]);
  const selected = Math.max(0, tiles.findIndex(item => item.name === selectedName));
  const whole = root ? total(root) : 0;
  const detailGap = !!report?.detail_from && report.roles.some(role => role.agents.some(agent => agent.phases.some(phase => phase.undetailed_before > 0)));

  const go = (next: string[], select?: string) => {
    setPath(next);
    storage.set("cerebro-time-path", JSON.stringify(next));
    setSelectedName(select);
    setPointed(undefined);
    setKeyed(false);
  };
  const down = (node: Node) => { if (node.kind !== "phase") go([...trail.slice(1).map(item => item.name), node.name]); };
  const up = () => { if (trail.length > 1) go(trail.slice(1, -1).map(item => item.name), here.name); };
  const choosePeriod = (next: Period) => { setPeriod(next); storage.set("cerebro-time-period", next); };
  const chooseWaiting = (next: boolean) => { setWaiting(next); storage.set("cerebro-time-waiting", next ? "1" : "0"); };

  const state = useRef({ keys, tiles, rects, selected, narrow, down, up });
  state.current = { keys, tiles, rects, selected, narrow, down, up };
  useEffect(() => {
    const press = (event: KeyboardEvent) => {
      const { keys, tiles, rects, selected, narrow, down, up } = state.current;
      if (!keys || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || typingInto(event.target)) return;
      if (event.key === "Escape" || event.key === "Backspace") { event.preventDefault(); up(); return; }
      if (!tiles.length) return;
      if (event.key === "Enter") {
        // A focused period button or path link does its own work; Enter goes into a tile only
        // from the tiles, from nothing in particular or from the checkbox, which has none.
        const target = event.target instanceof Element ? event.target : null;
        if (target?.closest("button, a, input:not([type=checkbox]), select, textarea") && !target.closest("[data-time-tiles]")) return;
        event.preventDefault();
        down(tiles[selected]);
        return;
      }
      if (!event.key.startsWith("Arrow")) return;
      event.preventDefault();
      const next = narrow
        ? event.key === "ArrowDown" ? Math.min(selected + 1, tiles.length - 1) : event.key === "ArrowUp" ? Math.max(selected - 1, 0) : selected
        : nearest(rects, selected, event.key);
      setSelectedName(tiles[next].name);
      setKeyed(true);
    };
    window.addEventListener("keydown", press);
    return () => window.removeEventListener("keydown", press);
  }, []);

  const pointNode = tiles.find(item => item.name === pointed) ?? (keyed ? tiles[selected] : undefined);
  const touchStart = (node: Node) => (event: PointerEvent) => {
    if (event.pointerType !== "touch") return;
    pressed.current = false;
    clearTimeout(pressTimer.current);
    pressTimer.current = setTimeout(() => { pressed.current = true; setPointed(node.name); }, 500);
  };
  const touchEnd = () => clearTimeout(pressTimer.current);
  const click = (node: Node) => () => { if (pressed.current) { pressed.current = false; return; } down(node); };

  const empty = !!report && !!here && tiles.length === 0;
  // With the box unticked, a level can be empty only because all its time was waiting on you.
  const onlyWaiting = empty && !waiting && total(walk(tree(report, true), path).at(-1)!) > 0;
  const emptyWords = onlyWaiting
    ? [shownPeriod === "all" ? "Only time waiting on you has been recorded." : `Only time waiting on you in the last ${lastWords[shownPeriod ?? period]}.`, "Tick Waiting on you to see it."]
    : shownPeriod === "all"
    ? ["Nothing has been recorded for this project yet. Time shows here once an agent has run."]
    : [`No agent ran in the last ${lastWords[shownPeriod ?? period]}.`, "Pick a longer period above."];

  return <div className="flex min-h-0 flex-1 flex-col px-5 pb-5">
    <div className="flex flex-wrap items-center gap-3 py-3">
      <nav aria-label="Path" className="flex flex-wrap items-center gap-1 text-[15px]">
        {(trail.length ? trail : [{ label: "All roles" } as Node]).map((node, index, all) => index === all.length - 1
          ? <span key={index} className="font-medium">{index > 0 && <span aria-hidden className="px-1 text-muted-foreground">›</span>}{node.kind === "other" ? OTHER : node.label}</span>
          : <span key={index}>{index > 0 && <span aria-hidden className="px-1 text-muted-foreground">›</span>}<button type="button" onClick={() => go(trail.slice(1, index + 1).map(item => item.name), trail[index + 1]?.name)}
              className="text-primary hover:underline">{node.kind === "other" ? OTHER : node.label}</button></span>)}
      </nav>
      <label className="ml-auto flex cursor-pointer items-center gap-1.5 text-[13px]">
        <input type="checkbox" checked={waiting} onChange={event => chooseWaiting(event.target.checked)} className="size-3.5 accent-foreground" />
        Waiting on you
      </label>
      <div role="radiogroup" aria-label="Period" className="flex overflow-hidden rounded-md border text-[13px]">
        {periods.map(([key, label]) => <button key={key} type="button" role="radio" aria-checked={period === key} onClick={() => choosePeriod(key)}
          className={cn("border-l px-2.5 py-1 first:border-l-0", period === key ? "bg-foreground text-background" : "hover:bg-muted")}>{label}</button>)}
      </div>
    </div>

    {failed && <div role="alert" className="mb-2.5 rounded-md border border-red-300 bg-red-50 px-3 py-2 text-[13px] text-red-950 dark:border-red-500/40 dark:bg-red-500/10 dark:text-red-200">
      {failed === "outdated" ? "The console's service is older than this page and has no time report. Restart cerebro-web; this tab reads it within a minute."
        : report ? `Couldn't read the fleet's records just now. Showing what was read at ${clock(report.read_at)}. Trying again every minute.` : "Couldn't read the fleet's records just now. Trying again every minute."}
    </div>}
    {detailGap && report?.detail_from && <div role="note" className="mb-2.5 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-[13px] text-amber-950 dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200">
      Full detail from {dayMonth(report.detail_from)}. Before that, only which phase each agent was in is known.
    </div>}
    {here && !empty && <p className="pb-2.5 text-[13px] text-muted-foreground">{waiting ? `${hours(total(here))} h in all · ${hours(here.waiting)} h of it waiting on you (grey)` : `${hours(here.working)} h working`}</p>}

    {empty ? <div className="flex h-52 flex-col items-center justify-center rounded-lg border-2 border-dashed text-center text-sm text-muted-foreground">
      {emptyWords.map(line => <span key={line}>{line}</span>)}
    </div>
    : narrow ? <ul ref={mapRef} tabIndex={-1} aria-label="Time list" data-time-tiles aria-busy={!report && !failed} className={cn("rounded-lg border outline-none", failed && "opacity-60")}>
      {!report && !failed && [0, 1, 2].map(index => <li key={index} className="h-10 animate-pulse border-t bg-muted first:border-t-0" />)}
      {tiles.map((node, index) => {
        const scale = tiles.length ? total(tiles[0]) : 1;
        return <li key={node.name} className="relative border-t first:border-t-0">
          <button type="button" aria-current={index === selected ? "true" : undefined} onClick={click(node)} onPointerDown={touchStart(node)} onPointerUp={touchEnd} onPointerLeave={touchEnd}
            onMouseEnter={() => setPointed(node.name)} onMouseLeave={() => setPointed(undefined)}
            className={cn("flex w-full items-center gap-2 px-2.5 py-2 text-left text-[13px]", index === selected && "bg-muted")}>
            <span className="w-24 shrink-0 truncate">{node.label}</span>
            <span className="flex min-w-0 flex-1">
              <span className={cn("h-3.5 rounded-l-sm", node.waiting === 0 && "rounded-r-sm")} style={{ width: `${node.working / scale * 100}%`, background: node.colour }} />
              {node.waiting > 0 && <span className="band h-3.5 rounded-r-sm" style={{ width: `${node.waiting / scale * 100}%`, background: hatch }} />}
            </span>
            <span className="shrink-0 tabular-nums">{hours(total(node))} h</span>
          </button>
          {pointNode?.name === node.name && <PointingBox node={node} whole={whole} waiting={waiting} style={{ right: 8, top: "100%" }} />}
        </li>;
      })}
    </ul>
    : <div ref={mapRef} tabIndex={-1} role="group" aria-label="Time map" data-time-tiles aria-busy={!report && !failed} className={cn("relative min-h-80 flex-1 outline-none", failed && "opacity-60")}>
      {!report && !failed && [[0, 48], [48, 30], [78, 22]].map(([left, width]) => <div key={left} className="absolute top-0 h-full animate-pulse rounded-md border-2 border-background bg-muted" style={{ left: `${left}%`, width: `${width}%` }} />)}
      {tiles.map((node, index) => {
        const rect = rects[index];
        if (!rect) return null;
        const lines = node.phase ? activityLines(node.phase, report?.detail_from ?? null, rect.w >= 220) : [];
        const banded = hours(node.waiting) !== "0";
        const band = banded ? bandLabel(node.waiting, rect.w) : undefined;
        const share = total(node) ? node.waiting / total(node) * 100 : 0;
        return <button key={node.name} type="button" aria-label={`${node.label}, ${hours(total(node))} h`} aria-current={index === selected ? "true" : undefined}
          onClick={click(node)} onPointerDown={touchStart(node)} onPointerUp={touchEnd} onPointerLeave={touchEnd}
          onMouseEnter={() => setPointed(node.name)} onMouseLeave={() => setPointed(undefined)}
          className={cn("absolute flex flex-col items-stretch justify-start overflow-hidden rounded-md border-2 border-background p-2 text-left text-white transition-all duration-500",
            node.kind === "other" && "text-zinc-950", index === selected && "z-10 ring-2 ring-foreground ring-offset-1")}
          style={{ left: rect.x, top: rect.y, width: rect.w, height: rect.h, background: node.colour, cursor: node.kind === "phase" ? "default" : "pointer" }}>
          <span className="relative z-[1] block truncate text-[15px] font-semibold">{node.label}</span>
          <span className="relative z-[1] block text-[13px] opacity-90">{hours(total(node))} h</span>
          {lines.map(line => <span key={line} className={cn("relative z-[1] block truncate text-[13px] opacity-90", line.startsWith("· no detail") && "opacity-75")}>{line}</span>)}
          {banded && <span className="band absolute inset-x-0 bottom-0 flex items-end truncate px-2 pb-0.5 text-xs text-zinc-950"
            style={{ background: hatch, height: `max(18px, min(calc(100% - 52px), ${share}%))` }}>{band}</span>}
        </button>;
      })}
      {pointNode && rects[tiles.indexOf(pointNode)] && (() => {
        const rect = rects[tiles.indexOf(pointNode)];
        const left = Math.min(rect.x + 12, Math.max(0, size.w - 232));
        return <PointingBox node={pointNode} whole={whole} waiting={waiting} style={{ left, top: Math.min(rect.y + 40, Math.max(0, size.h - 120)) }} />;
      })()}
    </div>}
  </div>;
}
