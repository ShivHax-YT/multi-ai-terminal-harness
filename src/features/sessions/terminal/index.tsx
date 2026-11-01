// T-106: one session's raw PTY bytes in xterm.js. Rule 3: only this folder may use the PTY input port, and every
// keystroke goes through ./input-gate. Output enters only through xterm's write; nothing from the screen is parsed,
// stored or logged (rule 4), and links never open (rule 5).
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { useEffect, useRef, useState } from "react";

import { ErrorAlert } from "@/components/common";
import { useIpc, type TerminalChunk } from "@/lib/ipc";
import { usePtyInput } from "@/lib/ipc/pty-input";

import { createAttachGeneration } from "./attach-generation";
import { createInputGate } from "./input-gate";

export interface SessionTerminalProps {
  sessionId: string;
  kind: "worker" | "login" | "interactive";
  /** The latest take-over state; keystrokes pass only while it is true. */
  takeover: boolean;
}

function decode(base64: string): Uint8Array {
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function token(name: string): string {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

export function SessionTerminal({ sessionId, kind, takeover }: SessionTerminalProps) {
  const client = useIpc();
  const ptyInput = usePtyInput();
  const host = useRef<HTMLDivElement>(null);
  const takeoverRef = useRef(takeover);
  const [error, setError] = useState<unknown>(null);
  const [connecting, setConnecting] = useState(true);

  useEffect(() => {
    takeoverRef.current = takeover;
  }, [takeover]);

  useEffect(() => {
    const element = host.current;
    if (element === null) return;
    const term = new Terminal({
      allowProposedApi: false,
      cursorBlink: true,
      fontFamily: token("--font-mono") || "monospace",
      fontSize: 13,
      lineHeight: 1.2,
      scrollback: 5000,
      theme: { background: token("--terminal-bg"), foreground: token("--terminal-fg") },
      linkHandler: { activate: () => undefined },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(element);
    // ⌘ combinations stay with the app (palette, navigation, copy, paste). Everything else goes to the terminal.
    term.attachCustomKeyEventHandler((event) => !event.metaKey);

    const gate = createInputGate(element, {
      write: (data) => ptyInput.pty_write({ session_id: sessionId, data }),
      takeoverOn: () => takeoverRef.current,
      onRefused: setError,
    });
    const inputs = [
      term.onData((data) => {
        gate.onData(data);
      }),
      // Rule 3 (T-106): binary input is dropped.
      term.onBinary(() => undefined),
      term.onResize(({ cols, rows }) => {
        client.resize_terminal({ session_id: sessionId, cols, rows }).catch(setError);
      }),
    ];

    let disposed = false;
    let unlisten: (() => void) | undefined;
    let lastSeq: number | null = null;
    const pending: TerminalChunk[] = [];
    const attaches = createAttachGeneration();
    let attachAgain = false;

    const attach = async () => {
      const ticket = attaches.begin();
      if (ticket === null) {
        attachAgain = true;
        return;
      }
      try {
        const attached = await client.attach_terminal({ session_id: sessionId });
        // A slower or older snapshot must not reset the view over bytes already shown.
        if (disposed || !attaches.shouldApply(ticket, attached.seq, lastSeq)) return;
        term.reset();
        term.write(decode(attached.scrollback_b64));
        lastSeq = attached.seq;
        setConnecting(false);
        for (const chunk of pending.splice(0)) receive(chunk);
      } finally {
        attaches.finish();
        if (attachAgain && !disposed) {
          attachAgain = false;
          void attach().catch(setError);
        }
      }
    };

    const receive = (chunk: TerminalChunk) => {
      if (chunk.session_id !== sessionId) return;
      if (lastSeq === null) {
        pending.push(chunk);
      } else if (chunk.seq === lastSeq + 1) {
        lastSeq = chunk.seq;
        term.write(decode(chunk.data_b64));
      } else if (chunk.seq > lastSeq) {
        // A gap: replace the buffer with the backend's copy.
        attach().catch(setError);
      }
    };

    const fitToHost = () => {
      if (element.clientWidth > 0 && element.clientHeight > 0) fit.fit();
    };
    const observer = new ResizeObserver(fitToHost);
    observer.observe(element);

    // Subscribe first, so nothing printed during the attach is lost.
    client
      .listen("terminal_output", receive)
      .then((stop) => {
        if (disposed) {
          stop();
          return;
        }
        unlisten = stop;
        fitToHost();
        term.focus();
        return attach();
      })
      .catch(setError);

    return () => {
      disposed = true;
      observer.disconnect();
      unlisten?.();
      gate.dispose();
      for (const input of inputs) input.dispose();
      term.dispose();
    };
  }, [client, ptyInput, sessionId]);

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-2">
      {error !== null && <ErrorAlert error={error} />}
      <div
        role="region"
        aria-label="Terminal"
        data-session-id={sessionId}
        data-kind={kind}
        className="relative min-h-0 flex-1 overflow-hidden rounded-xl bg-terminal-bg p-3"
      >
        {connecting && (
          <p className="absolute top-3 left-3 font-mono text-[13px] text-terminal-fg">
            Connecting to the session
          </p>
        )}
        <div ref={host} className="h-full w-full" />
      </div>
    </div>
  );
}
