import { useEffect, useMemo, useRef, useState } from "react";
import { Command, Flag, OctagonX, Play, PowerOff } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { type Agent, running, stateOf } from "./api";

export type Action = "start" | "finish" | "resume" | "kill" | "disarm" | "stop";

/// One thing that can be done to an agent: what the TUI's `s`, `f` or `k` would do on its row.
export type Offer = { action: Action; verb: string; label: string; title: string; key: "s" | "f" | "k"; danger?: boolean; ask?: { title: string; body: string } };

export const unsupervised = "No fleet view is supervising this checkout, so nothing can be started, finished or killed from here. Start one with cerebro-tui.";

/// What can be done to AGENT, by the same rules as the fleet view's keys. The fleet view has the
/// last word: a refusal comes back as its own sentence.
export function offersFor(agent: Agent): Offer[] {
  const { name } = agent;
  const state = stateOf(agent);
  const offers: Offer[] = [];
  if (!running(agent)) offers.push({ action: "start", verb: "Start", label: "Start", title: `Start ${name}`, key: "s" });
  if (agent.finishing) offers.push({ action: "resume", verb: "Keep", label: "Keep going", title: `Keep ${name} going`, key: "f" });
  else if (running(agent) && state !== "starting") offers.push({ action: "finish", verb: "Finish", label: "Finish after this pass", title: `Finish ${name} after this pass`, key: "f" });
  if (state === "standby") offers.push({ action: "disarm", verb: "Disarm", label: "Disarm", title: `Disarm ${name}`, key: "k", danger: true, ask: {
    title: `Disarm ${name}?`, body: `The fleet view won’t start ${name} when there is work for it, until you start it again.` } });
  else if (state === "starting") offers.push({ action: "stop", verb: "Stop", label: "Stop starting", title: `Stop ${name}’s start`, key: "k", danger: true, ask: {
    title: `Stop ${name}’s start?`, body: `The session being started is stopped, ${name} is disarmed, and the bead it was handed goes back to the board.` } });
  else if (running(agent)) offers.push({ action: "kill", verb: "Kill", label: "Kill", title: `Kill ${name}`, key: "k", danger: true, ask: {
    title: `Kill ${name}?`, body: `The session ends now, mid-pass, and ${name} is disarmed: the fleet view won’t start it again until you do.${agent.bead ? ` Its bead ${agent.bead} stays claimed.` : ""}` } });
  return offers;
}

const icons: Record<Action, typeof Play> = { start: Play, finish: Flag, resume: Flag, kill: OctagonX, disarm: PowerOff, stop: OctagonX };
export const iconFor = (offer: Offer) => icons[offer.action];

export type Said = { text: string; done: boolean; at: number };

/// Doing offers: asking first where the offer says to, and saying what the fleet view answered.
export function useLifecycle(supervised: boolean, onDone: () => void) {
  const [asking, setAsking] = useState<{ agent: Agent; offer: Offer }>();
  const [said, setSaid] = useState<Said>();
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!said) return;
    const timer = setTimeout(() => setSaid(undefined), 6000);
    return () => clearTimeout(timer);
  }, [said]);
  const send = async (agent: Agent, offer: Offer) => {
    setBusy(true);
    try {
      const response = await fetch(`/api/agents/${encodeURIComponent(agent.name)}/${offer.action}`, { method: "POST", headers: { "x-cerebro-input": "1" } });
      const reply = await response.json().catch(() => undefined) as { done: boolean; text: string } | undefined;
      setSaid({ text: reply?.text ?? `Couldn’t reach the console (${response.status}).`, done: reply?.done ?? false, at: Date.now() });
    } catch {
      setSaid({ text: "Couldn’t reach the console.", done: false, at: Date.now() });
    } finally {
      setBusy(false);
      onDone();
    }
  };
  const perform = (agent: Agent, offer: Offer) => {
    if (!supervised) return setSaid({ text: unsupervised, done: false, at: Date.now() });
    if (offer.ask) return setAsking({ agent, offer });
    void send(agent, offer);
  };
  const confirm = () => {
    if (!asking) return;
    setAsking(undefined);
    void send(asking.agent, asking.offer);
  };
  const dialog = asking && <Dialog open onOpenChange={open => { if (!open) setAsking(undefined); }}>
    <DialogContent showCloseButton={false} onKeyDown={event => { if (event.key === "y" && !event.metaKey && !event.ctrlKey) { event.preventDefault(); confirm(); } }}>
      <DialogHeader>
        <DialogTitle className="flex items-center gap-2">{(() => { const Icon = iconFor(asking.offer); return <Icon className="size-5 text-destructive" />; })()}{asking.offer.ask!.title}</DialogTitle>
        <DialogDescription>{asking.offer.ask!.body}</DialogDescription>
      </DialogHeader>
      <DialogFooter>
        <Button variant="outline" onClick={() => setAsking(undefined)}>Cancel <kbd className="ml-1 text-[10px] text-muted-foreground">esc</kbd></Button>
        <Button variant="destructive" autoFocus onClick={confirm}>{asking.offer.verb} {asking.agent.name} <kbd className="ml-1 text-[10px] opacity-70">y</kbd></Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>;
  return { perform, dialog, said, busy, asking: asking !== undefined };
}

const Kbd = ({ children, className }: { children: React.ReactNode; className?: string }) =>
  <kbd className={cn("rounded border border-b-2 px-1 font-mono text-[10px] text-muted-foreground", className)}>{children}</kbd>;

/// The chosen agent's actions, above its session.
export function ActionBar({ agent, supervised, busy, onAct }: { agent: Agent; supervised: boolean; busy: boolean; onAct: (offer: Offer) => void }) {
  const offers = offersFor(agent);
  if (offers.length === 0) return null;
  const buttons = <div role="toolbar" aria-label={`${agent.name} actions`} className="flex items-center gap-2">
    {offers.map(offer => {
      const Icon = iconFor(offer);
      return <Button key={offer.action} variant={offer.danger ? "destructive" : "outline"} disabled={!supervised || busy} onClick={() => onAct(offer)}
        aria-keyshortcuts={offer.key} title={`${offer.label} (${offer.key})`}>
        <Icon />{offer.label}<Kbd className={offer.danger ? "border-destructive/40 text-destructive/80" : undefined}>{offer.key}</Kbd>
      </Button>;
    })}
  </div>;
  return supervised ? buttons
    : <Tooltip><TooltipTrigger render={<span />}>{buttons}</TooltipTrigger><TooltipContent side="bottom">{unsupervised}</TooltipContent></Tooltip>;
}

/// The strip that says an agent will stop after this pass, with the way to take it back.
export function FinishingStrip({ agent, supervised, onResume }: { agent: Agent; supervised: boolean; onResume: () => void }) {
  if (!agent.finishing) return null;
  return <div role="status" className="flex items-center gap-2 rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">
    <Flag className="size-4" />
    {running(agent) ? `${agent.name} will stop when this pass ends; the fleet view won’t start it again until you start it.`
      : `${agent.name} has a stop flag set, so the fleet view won’t start it.`}
    <Button variant="link" size="sm" className="ml-auto text-amber-800 dark:text-amber-200" disabled={!supervised} onClick={onResume}>Keep it running</Button>
  </div>;
}

/// What the fleet view said about the last action.
export function SaidLine({ said }: { said?: Said }) {
  if (!said) return null;
  return <p role="status" aria-label="Action result" className={cn("text-sm", said.done ? "text-muted-foreground" : "text-amber-700 dark:text-amber-300")}>{said.text}</p>;
}

/// ⌘K: every action on every agent, found by typing.
export function Palette({ open, agents, selected, supervised, onClose, onAct }: {
  open: boolean; agents: Agent[]; selected?: string; supervised: boolean; onClose: () => void; onAct: (agent: Agent, offer: Offer) => void;
}) {
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const list = useRef<HTMLDivElement>(null);
  useEffect(() => { if (open) { setQuery(""); setCursor(0); } }, [open]);
  const entries = useMemo(() => {
    const all = [...agents].sort((a, b) => Number(b.name === selected) - Number(a.name === selected))
      .flatMap(agent => offersFor(agent).map(offer => ({ agent, offer, text: offer.title })));
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    return all.filter(({ agent, text }) => words.every(word => `${text} ${agent.role} ${agent.bead ?? ""}`.toLowerCase().includes(word)));
  }, [agents, selected, query]);
  useEffect(() => setCursor(0), [query]);
  useEffect(() => { list.current?.querySelector("[aria-selected=true]")?.scrollIntoView({ block: "nearest" }); }, [cursor]);
  const choose = (index: number) => {
    const entry = entries[index];
    if (!entry) return;
    onClose();
    onAct(entry.agent, entry.offer);
  };
  return <Dialog open={open} onOpenChange={next => { if (!next) onClose(); }}>
    <DialogContent showCloseButton={false} className="top-24 translate-y-0 gap-0 p-0 sm:max-w-lg">
      <DialogTitle className="sr-only">Actions</DialogTitle>
      <div className="flex items-center gap-2 border-b px-3">
        <Command className="size-4 text-muted-foreground" />
        <input autoFocus value={query} onChange={event => setQuery(event.target.value)} placeholder="Start, finish or kill an agent…" aria-label="Find an action"
          role="combobox" aria-expanded aria-controls="palette-list"
          onKeyDown={event => {
            if (event.key === "ArrowDown") { event.preventDefault(); setCursor(at => Math.min(at + 1, entries.length - 1)); }
            else if (event.key === "ArrowUp") { event.preventDefault(); setCursor(at => Math.max(at - 1, 0)); }
            else if (event.key === "Enter") { event.preventDefault(); choose(cursor); }
          }}
          className="h-11 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground" />
      </div>
      {!supervised && <p className="border-b px-3 py-2 text-xs text-amber-700 dark:text-amber-300">{unsupervised}</p>}
      <div ref={list} id="palette-list" role="listbox" aria-label="Actions" className="max-h-80 overflow-auto p-1">
        {entries.length === 0 && <p className="px-3 py-6 text-center text-sm text-muted-foreground">No action matches.</p>}
        {entries.map(({ agent, offer, text }, index) => {
          const Icon = iconFor(offer);
          return <div key={text} role="option" aria-selected={index === cursor} onMouseMove={() => setCursor(index)} onClick={() => choose(index)}
            className={cn("flex cursor-pointer items-center gap-3 rounded-md px-3 py-2 text-sm", index === cursor && "bg-muted", offer.danger && "text-destructive")}>
            <Icon className="size-4" />{text}
            <span className="ml-auto flex items-center gap-2 text-xs text-muted-foreground">
              {agent.bead && <span className="font-mono">{agent.bead}</span>}
              {agent.name === selected && <Kbd>{offer.key}</Kbd>}
            </span>
          </div>;
        })}
      </div>
    </DialogContent>
  </Dialog>;
}

/// Whether a keystroke is somebody typing - into a field, or into a session's screen - rather
/// than a key for the page.
export const typingInto = (target: EventTarget | null) =>
  target instanceof HTMLElement && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName) || target.closest(".xterm") !== null);
