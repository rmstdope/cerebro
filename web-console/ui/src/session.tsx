import { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { Check, Copy, Maximize2, SquareTerminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";

type Output = { state: "live"; log: string; reset: boolean; data: string; offset: number; more: boolean } | { state: "absent" };

// A line a full-screen CLI scrolled away, as `fleet-view/src/history.rs` writes it into the log
// under OSC `HISTORY_OSC`, a literal twin of the constant there.
type Run = { t: string; fg?: number | string; bg?: number | string; bold?: boolean; dim?: boolean; italic?: boolean; underline?: boolean; inverse?: boolean };
const HISTORY_OSC = 7717;
const SCROLLBACK = 10000;
const font = "Menlo, Monaco, 'Courier New', monospace";
const FONT = 12;
const MIN_FONT = 6;
// xterm's own default colours, so history reads the same as the screen below it.
const ansi = ["#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf", "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"];
const levels = [0, 95, 135, 175, 215, 255];
const hex = (value: number) => value.toString(16).padStart(2, "0");
const palette = [...ansi, ...Array.from({ length: 216 }, (_, i) => `#${hex(levels[Math.floor(i / 36)])}${hex(levels[Math.floor(i / 6) % 6])}${hex(levels[i % 6])}`), ...Array.from({ length: 24 }, (_, i) => `#${hex(8 + i * 10).repeat(3)}`)];
const tint = (colour: number | string | undefined, fallback: string) => typeof colour === "number" ? palette[colour] ?? fallback : colour ?? fallback;

function historyLine(runs: Run[]) {
  const line = document.createElement("div");
  for (const run of runs) {
    const span = document.createElement("span");
    span.textContent = run.t;
    // xterm draws bold text in the bright colours, and so does this.
    const fg = tint(typeof run.fg === "number" && run.bold && run.fg < 8 ? run.fg + 8 : run.fg, "#ffffff");
    const bg = tint(run.bg, "");
    span.style.color = run.inverse ? bg || "#000000" : fg;
    span.style.backgroundColor = run.inverse ? fg : bg;
    if (run.bold) span.style.fontWeight = "bold";
    if (run.dim) span.style.opacity = "0.5";
    if (run.italic) span.style.fontStyle = "italic";
    if (run.underline) span.style.textDecoration = "underline";
    line.append(span);
  }
  if (!runs.length) line.textContent = " ";
  return line;
}

type Controls = { follow: (on: boolean) => void; text: () => string };

export function SessionScreen({ name }: { name: string }) {
  const frame = useRef<HTMLDivElement>(null);
  const card = useRef<HTMLElement>(null);
  const bar = useRef<HTMLElement>(null);
  const host = useRef<HTMLDivElement>(null);
  const screen = useRef<HTMLDivElement>(null);
  const past = useRef<HTMLDivElement>(null);
  const controls = useRef<Controls>(undefined);
  const [status, setStatus] = useState<"loading" | "live" | "absent" | "failed">("loading");
  const [following, setFollowing] = useState(true);
  const [size, setSize] = useState<string>();
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    // `setWinSizeChars` is what lets CSI 8 ; rows ; cols t reach the handler below: the log
    // carries each pty resize that way, in order with the output.
    const terminal = new Terminal({ disableStdin: true, cursorBlink: false, fontFamily: font, fontSize: FONT, scrollback: SCROLLBACK, windowOptions: { setWinSizeChars: true } });
    const scroller = screen.current!;
    const history = past.current!;
    // Follow the bottom while the reader is there; leave them be once they scroll back. The
    // bottom is the outer scroller's and, on the normal screen, xterm's own viewport's too.
    let tracking = true;
    const track = (on: boolean) => { tracking = on; setFollowing(on); };
    const atBottom = () => {
      const buffer = terminal.buffer.active;
      return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 4 && (buffer.type === "alternate" || buffer.viewportY >= buffer.baseY);
    };
    // Follow off with no scrollback yet has no line to step up to; step on the first there is.
    let stepPending = false;
    const holdStill = () => {
      const buffer = terminal.buffer.active;
      stepPending = buffer.type === "normal" && buffer.baseY === 0;
      if (buffer.type === "normal" && buffer.baseY > 0 && buffer.viewportY >= buffer.baseY) terminal.scrollLines(-1);
    };
    // Only the reader turns Follow off, by scrolling up. Output that grows the page before
    // `follow` has run - a resize mid-write fires xterm's scroll - leaves it on.
    let lastTop = 0;
    const onScroll = () => {
      const buffer = terminal.buffer.active;
      if (stepPending && buffer.type === "normal" && buffer.baseY > 0) { holdStill(); return; }
      const up = scroller.scrollTop < lastTop;
      lastTop = scroller.scrollTop;
      if (atBottom()) track(true);
      else if (up || (buffer.type === "normal" && buffer.viewportY < buffer.baseY)) track(false);
    };
    // Moves of our own are where the next scroll is measured from, since a reader's scroll in
    // the same frame arrives in one event with them.
    const follow = () => { if (tracking) { scroller.scrollTop = scroller.scrollHeight; lastTop = scroller.scrollTop; } };
    scroller.addEventListener("scroll", onScroll);
    terminal.onScroll(onScroll);
    controls.current = {
      follow: on => {
        track(on);
        // xterm follows while its viewport is at the bottom, and holds the text still (trimming
        // included) once the reader is a line above it, so Follow off puts them there.
        if (on) { stepPending = false; terminal.scrollToBottom(); follow(); } else holdStill();
      },
      text: () => {
        const buffer = terminal.buffer.active;
        const screenLines = Array.from({ length: buffer.length }, (_, i) => buffer.getLine(i)?.translateToString(true) ?? "");
        const pastLines = history.hidden ? [] : Array.from(history.children, line => line.textContent ?? "");
        return [...pastLines, ...screenLines].join("\n").replace(/\s+$/, "") + "\n";
      },
    };
    terminal.parser.registerOscHandler(HISTORY_OSC, data => {
      let runs: Run[];
      try { runs = JSON.parse(data) as Run[]; } catch { return true; }
      if (!Array.isArray(runs)) return true;
      history.append(historyLine(runs));
      return true;
    });
    // Once per write rather than per line: measuring a line before removing it lays the page out.
    // The screen turns scroll anchoring off, so this correction is the only one, in every browser.
    const trim = () => {
      const excess = history.childElementCount - SCROLLBACK;
      if (excess <= 0) return;
      const before = history.offsetHeight;
      const oldest = document.createRange();
      oldest.setStartBefore(history.firstElementChild!);
      oldest.setEndAfter(history.children[excess - 1]);
      oldest.deleteContents();
      if (!tracking) { scroller.scrollTop -= before - history.offsetHeight; lastTop = scroller.scrollTop; }
    };
    // History belongs to the alternate screen; on the normal one xterm keeps its own scrollback.
    const showHistory = () => { history.hidden = terminal.buffer.active.type !== "alternate"; follow(); };
    terminal.buffer.onBufferChange(showHistory);
    showHistory();
    // xterm turns the wheel into keys on the alternate screen; here it scrolls the history.
    const onWheel = (event: WheelEvent) => {
      if (terminal.buffer.active.type !== "alternate") return;
      event.preventDefault();
      event.stopPropagation();
      scroller.scrollTop += event.deltaMode === WheelEvent.DOM_DELTA_LINE ? event.deltaY * 16 : event.deltaY;
    };
    scroller.addEventListener("wheel", onWheel, { capture: true, passive: false });
    terminal.parser.registerCsiHandler({ final: "t" }, params => {
      const [op, rows, cols] = params.map(param => Array.isArray(param) ? param[0] : param);
      if (op === 8 && rows > 0 && cols > 0) { terminal.resize(cols, rows); setSize(`${cols}×${rows}`); }
      return true;
    });
    terminal.open(host.current!);
    // The box is the size of the screen, as the terminal console's pane is. A screen taller or
    // wider than the room there is is drawn in a smaller font, never a larger one than `FONT`,
    // so all of it shows. In a font, not a CSS scale: xterm maps the pointer to cells in its own
    // unscaled measurements. Each size is judged once xterm has drawn it, stepping down until
    // the screen fits; a size that did not fit is not tried again until the room or the screen
    // changes.
    const drawn = host.current!.querySelector<HTMLElement>(".xterm-screen")!;
    let judged = "";
    let tooBig = Infinity;
    const fit = () => {
      const room = frame.current!, box = card.current!;
      const style = getComputedStyle(scroller);
      const padY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
      const padX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight) + scroller.offsetWidth - scroller.clientWidth;
      const tall = room.clientHeight - bar.current!.offsetHeight - (box.offsetHeight - box.clientHeight);
      const wide = room.clientWidth - (box.offsetWidth - box.clientWidth);
      const down = tall - padY, across = wide - padX;
      if (!drawn.offsetHeight || !drawn.offsetWidth || down <= 0 || across <= 0) return;
      const key = `${down}x${across}x${terminal.rows}x${terminal.cols}`;
      if (key !== judged) { judged = key; tooBig = Infinity; }
      const size = terminal.options.fontSize ?? FONT;
      const estimate = Math.floor(size * Math.min(down / drawn.offsetHeight, across / drawn.offsetWidth) * 2) / 2;
      const fits = drawn.offsetHeight <= down && drawn.offsetWidth <= across;
      if (!fits) tooBig = Math.min(tooBig, size);
      const next = fits
        ? Math.max(size, Math.min(FONT, tooBig - 0.5, estimate))
        : Math.max(MIN_FONT, Math.min(size - 0.5, estimate));
      if (next !== size) {
        terminal.options.fontSize = next;
        history.style.fontSize = `${next}px`;
      }
      scroller.style.height = `${Math.min(tall, drawn.offsetHeight + padY)}px`;
      scroller.style.width = `${Math.min(wide, drawn.offsetWidth + padX)}px`;
      follow();
    };
    const fitting = new ResizeObserver(fit);
    fitting.observe(frame.current!);
    fitting.observe(drawn);
    let log: string | undefined;
    let offset = 0;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async () => {
      let again = 500;
      try {
        const query = log === undefined ? "" : `?log=${encodeURIComponent(log)}&from=${offset}`;
        const response = await fetch(`/api/sessions/${encodeURIComponent(name)}${query}`);
        if (!response.ok) throw new Error(response.statusText);
        const output = await response.json() as Output;
        if (stopped) return;
        if (output.state === "absent") { setStatus("absent"); log = undefined; offset = 0; }
        else {
          setStatus("live");
          // In order with the writes still queued, or the old log's last lines would land after it.
          if (output.reset) terminal.write("", () => { terminal.reset(); history.replaceChildren(); if (!tracking) holdStill(); });
          if (output.data) terminal.write(output.data, () => { trim(); follow(); });
          log = output.log;
          offset = output.offset;
          if (output.more) again = 0;
        }
      } catch { if (!stopped) setStatus(current => current === "live" ? current : "failed"); again = 2000; }
      if (!stopped) timer = setTimeout(() => void poll(), again);
    };
    void poll();
    return () => {
      stopped = true;
      clearTimeout(timer);
      fitting.disconnect();
      scroller.removeEventListener("scroll", onScroll);
      scroller.removeEventListener("wheel", onWheel, { capture: true });
      terminal.dispose();
      history.replaceChildren();
      controls.current = undefined;
    };
  }, [name]);
  const copy = async () => {
    const text = controls.current?.text();
    if (text === undefined) return;
    await navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };
  const message = status === "loading" ? "Loading session…"
    : status === "absent" ? "No screen for this session. It shows here only while the terminal console hosts it."
    : status === "failed" ? "Couldn’t load the session. Retrying…" : undefined;
  // The room is what the box may grow to. The header never sets the box's width, but keeps
  // enough of it for the name and the controls.
  return <div ref={frame} className="flex min-h-0 flex-1 flex-col items-start bg-background">
   <section ref={card} aria-label={`${name} session`} className="relative flex max-h-full max-w-full min-w-[min(26rem,100%)] flex-col overflow-hidden rounded-xl border bg-card shadow-lg shadow-black/10 dark:shadow-black/40">
    <header ref={bar} className="flex h-10 shrink-0 items-center gap-2 overflow-hidden border-b px-3 text-xs text-muted-foreground [contain:inline-size]">
      <SquareTerminal className="size-3.5 shrink-0" />
      <span className="truncate font-mono">{name}{size ? ` · ${size}` : ""}</span>
      <div className="ml-auto flex shrink-0 items-center gap-1">
        <label className="mr-2 flex cursor-pointer items-center gap-2">Follow
          <Switch size="sm" checked={following} onCheckedChange={on => controls.current?.follow(on)} aria-label="Follow new output" />
        </label>
        <Button variant="ghost" size="xs" onClick={() => void copy()} aria-label="Copy session text">{copied ? <Check /> : <Copy />}{copied ? "Copied" : "Copy"}</Button>
        <Button variant="ghost" size="icon-xs" onClick={() => void frame.current?.requestFullscreen?.()} aria-label="Full screen"><Maximize2 /></Button>
      </div>
    </header>
    {/* Over the box and outside its scroll, so it covers a screen that is no longer there. */}
    {message && <p className="absolute inset-x-0 top-10 bottom-0 bg-black px-3 py-2 text-xs text-white/80">{message}</p>}
    {/* Always laid out, even before the first output: xterm drawing into an element with no
        layout, or off-screen, leaves its viewport stuck where the first write put it. */}
    <div ref={screen} className="screen min-w-full shrink-0 overflow-auto bg-black px-3 py-2 [overflow-anchor:none] [scrollbar-gutter:stable]">
      <div ref={past} className="history text-[12px] leading-normal whitespace-pre text-white" style={{ fontFamily: font }} />
      <div ref={host} className="terminal overflow-hidden" />
    </div>
   </section>
  </div>;
}
