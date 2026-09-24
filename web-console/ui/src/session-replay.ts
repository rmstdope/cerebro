import { type Terminal } from "@xterm/xterm";

export type SessionOutput =
  | { state: "live"; log: string; reset: boolean; data: string; offset: number; more: boolean }
  | { state: "absent" };

type ReplayPolicy = {
  reset: () => void;
  wrote: () => void;
};

export function replay(terminal: Terminal, output: Extract<SessionOutput, { state: "live" }>, policy: ReplayPolicy) {
  if (output.reset) terminal.write("", () => {
    terminal.reset();
    policy.reset();
  });
  if (output.data) terminal.write(output.data, policy.wrote);
}

export function registerResize(terminal: Terminal, setSize: (size: string) => void) {
  return terminal.parser.registerCsiHandler({ final: "t" }, params => {
    const [op, rows, cols] = params.map(param => Array.isArray(param) ? param[0] : param);
    if (op === 8 && rows > 0 && cols > 0) {
      terminal.resize(cols, rows);
      setSize(`${cols}×${rows}`);
    }
    return true;
  });
}
