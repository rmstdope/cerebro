import { useCallback, useEffect, useRef, useState } from "react";

export type Agent = {
  name: string;
  role: string;
  state: string;
  phase?: string | null;
  bead?: string | null;
  since?: string | null;
  phase_since?: string | null;
  pid?: number | null;
  sessions?: number;
  diagnostic?: string | null;
};
export type Bead = { id: string; title: string; status: string; issue_type: string; labels: string[]; priority?: number | null; assignee?: string | null };
export type Work = {
  claimed: Bead[];
  planned: Bead[];
  being_planned: Bead[];
  ux_agreed: Bead[];
  unplanned: Bead[];
  paused: Bead[];
  merged: Bead[];
  epics?: Record<string, string>;
};
export type Snapshot<T> = { state: "fresh"; value: T } | { state: "stale"; value: T; error: string; updated_at: string } | { state: "unavailable"; error: string };

export const valueOf = <T,>(snapshot?: Snapshot<T>) => snapshot && snapshot.state !== "unavailable" ? snapshot.value : undefined;

/// One endpoint's snapshot. A failed read keeps what was last read, marked stale, rather than
/// replacing it with nothing: an empty fleet and an unreadable one are different answers.
export function useSnapshot<T>(path: string) {
  const [snapshot, setSnapshot] = useState<Snapshot<T>>();
  const [updated, setUpdated] = useState<number>();
  const last = useRef<number>(undefined);
  const refresh = useCallback(async () => {
    try {
      const response = await fetch(path);
      if (!response.ok) throw new Error(response.statusText);
      const value = await response.json() as Snapshot<T>;
      setSnapshot(value);
      if (value.state === "fresh") last.current = Date.now();
      else if (value.state === "stale") last.current = Date.parse(value.updated_at);
      setUpdated(last.current);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setSnapshot(previous => previous && previous.state !== "unavailable"
        ? { state: "stale", value: previous.value, error: message, updated_at: new Date(last.current ?? Date.now()).toISOString() }
        : { state: "unavailable", error: message });
    }
  }, [path]);
  return { snapshot, updated, refresh };
}

/// Now, once a second, so every age on the page counts up on its own.
export function useNow() {
  const [now, setNow] = useState(Date.now);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  return now;
}

export const since = (now: number, time?: string | number | null) => {
  if (time === undefined || time === null) return undefined;
  const seconds = Math.max(0, Math.floor((now - (typeof time === "number" ? time : Date.parse(time))) / 1000));
  if (Number.isNaN(seconds)) return undefined;
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
};

export const stateOf = (agent: Agent) => agent.state.toLowerCase();
export const running = (agent: Agent) => !["dead", "standby"].includes(stateOf(agent));

/// A bead's epic is its nearest ancestor by id (`cb-1.2.3` under `cb-1.2`, then `cb-1`) that the
/// board names, else its direct parent's id, else none.
export function epicOf(id: string, epics: Record<string, string> = {}) {
  let parent = id;
  while (parent.includes(".")) {
    parent = parent.slice(0, parent.lastIndexOf("."));
    if (epics[parent]) return { id: parent, title: epics[parent] };
  }
  return id.includes(".") ? { id: id.slice(0, id.lastIndexOf(".")), title: id.slice(0, id.lastIndexOf(".")) } : undefined;
}
