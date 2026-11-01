// Rule 3: the only code that sends text to a PTY. Text passes only while take-over is on and a real user event on the
// terminal happened in this same turn. xterm also emits onData for its own replies to output escape codes; those
// sequences are dropped even when a composition window is still open.
//
// Ordinary keys are synchronous: xterm emits them inside the key event, and the window closes when that dispatch
// ends, before any timer. Composed text (IME, dead keys) is different. xterm 6 commits it from its own
// setTimeout(0), queued during the event, after a capture-phase timer would already have been queued. For those
// events the window stays open until a nested setTimeout(0): the outer timer is queued with xterm's flush, and the
// inner one clears only after that flush has run.

/** Longest chunk the backend accepts in one write (a paste is split). */
export const MAX_CHUNK_BYTES = 4 * 1024;

const USER_EVENTS = [
  "keydown",
  "keypress",
  "beforeinput",
  "input",
  "compositionstart",
  "compositionupdate",
  "compositionend",
  "paste",
  "wheel",
  "mousedown",
  "mouseup",
] as const;

/** Cursor-position reports, device-attribute replies, and focus reports. */
const QUERY_REPLY = /^(?:\u001b\[\d+(?:;\d+)*R|\u001b\[(?:\?|>)?[\d;]*c|\u001b\[[IO])$/;

export function isTerminalQueryReply(data: string): boolean {
  return QUERY_REPLY.test(data);
}

export interface InputGateOptions {
  write(data: string): Promise<void>;
  takeoverOn(): boolean;
  /** A refusal is shown to the human and never retried. */
  onRefused(error: unknown): void;
  /** Tests stand in here: simulated events are never trusted by the browser. */
  isUserEvent?: (event: Event) => boolean;
}

export interface InputGate {
  onData(data: string): void;
  dispose(): void;
}

/** Splits text into chunks of at most `limit` UTF-8 bytes, never inside a character. */
export function splitChunks(text: string, limit = MAX_CHUNK_BYTES): string[] {
  const encoder = new TextEncoder();
  if (encoder.encode(text).length <= limit) return [text];
  const chunks: string[] = [];
  let current = "";
  let size = 0;
  for (const char of text) {
    const bytes = encoder.encode(char).length;
    if (size + bytes > limit) {
      chunks.push(current);
      current = "";
      size = 0;
    }
    current += char;
    size += bytes;
  }
  if (current !== "") chunks.push(current);
  return chunks;
}

/** Composition, dead keys, and IME (keyCode 229) are the events whose text xterm flushes on a timer. */
function deferredUserEvent(event: Event): boolean {
  if (
    event.type === "compositionstart" ||
    event.type === "compositionupdate" ||
    event.type === "compositionend" ||
    event.type === "beforeinput"
  ) {
    return true;
  }
  if (event.type === "keydown" || event.type === "keypress") {
    const key = event as KeyboardEvent;
    return key.key === "Dead" || key.key === "Process" || key.keyCode === 229;
  }
  return false;
}

export function createInputGate(element: HTMLElement, options: InputGateOptions): InputGate {
  const isUserEvent = options.isUserEvent ?? ((event: Event) => event.isTrusted);
  let userTurn = false;
  let disposed = false;
  let outer: ReturnType<typeof setTimeout> | undefined;
  let inner: ReturnType<typeof setTimeout> | undefined;
  // One at a time, so keystrokes reach the CLI in the order they were typed.
  let queue: Promise<void> = Promise.resolve();

  const clearDeferred = () => {
    if (outer !== undefined) clearTimeout(outer);
    if (inner !== undefined) clearTimeout(inner);
    outer = undefined;
    inner = undefined;
  };

  // Queued from the composition event, ahead of xterm's target-phase setTimeout(0). The inner timer is queued
  // when the outer one runs, so it clears only after that flush.
  const armDeferred = () => {
    userTurn = true;
    clearDeferred();
    outer = setTimeout(() => {
      inner = setTimeout(() => {
        userTurn = false;
      }, 0);
    }, 0);
  };

  const mark = (event: Event) => {
    if (disposed || !isUserEvent(event)) return;
    if (deferredUserEvent(event)) {
      armDeferred();
      return;
    }
    userTurn = true;
  };
  const endDispatch = (event: Event) => {
    if (disposed || !isUserEvent(event) || deferredUserEvent(event)) return;
    userTurn = false;
  };
  for (const type of USER_EVENTS) {
    element.addEventListener(type, mark, true);
    element.addEventListener(type, endDispatch, false);
  }

  const enqueue = (data: string) => {
    for (const chunk of splitChunks(data)) {
      queue = queue
        .then(() => {
          if (disposed || !options.takeoverOn()) return;
          return options.write(chunk);
        })
        .catch((error: unknown) => {
          if (disposed) return;
          options.onRefused(error);
        });
    }
  };

  return {
    onData(data) {
      if (disposed || data.length === 0 || isTerminalQueryReply(data)) return;
      if (!userTurn || !options.takeoverOn()) return;
      enqueue(data);
    },
    dispose() {
      disposed = true;
      userTurn = false;
      clearDeferred();
      for (const type of USER_EVENTS) {
        element.removeEventListener(type, mark, true);
        element.removeEventListener(type, endDispatch, false);
      }
    },
  };
}
