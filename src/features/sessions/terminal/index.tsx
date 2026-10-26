// Placeholder from T-101; T-106 owns the terminal view and replaces this file. The props are fixed (T-105 renders
// it). Rule 3: the terminal is view-only plus human take-over; only this folder may use the PTY input port.

export interface SessionTerminalProps {
  sessionId: string;
  kind: "worker" | "login";
}

export function SessionTerminal(props: SessionTerminalProps) {
  return (
    <div
      role="region"
      aria-label="Terminal"
      data-session-id={props.sessionId}
      data-kind={props.kind}
      className="bg-terminal-bg text-terminal-fg min-h-48 rounded-xl p-4 font-mono text-[13px] leading-[1.5]"
    >
      The terminal view arrives with T-106.
    </div>
  );
}
