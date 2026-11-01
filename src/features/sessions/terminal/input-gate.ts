// Rule 3: the only code that sends text to a PTY. Text passes only while take-over is on and a real user event on the
// terminal happened in this same turn. xterm also emits onData for its own replies to output escape codes; those
// sequences are dropped even when a composition window is still open.
//
// Ordinary keys are synchronous: xterm emits them inside the key event, and the window closes when that dispatch
// ends, before any timer. Composed text is different. xterm 6 queues the character on setTimeout(0) during
// compositionend, and the browser then dispatches beforeinput, input, and keypress before that timer. Those later
// events must not close the window while that flush is still outstanding. The clear timer is nested so it runs
// after a composition timer that was already queued.

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

/**
 * Cursor-position reports (`CSI r;c R` and xterm's private `CSI ?r;c R`), device attributes,
 * focus reports, and status reports (`CSI 0n`). Dropped even while a composition flush is open.
 */
const ESC = "\u001b";
const QUERY_REPLY = new RegExp(
  `^(?:${ESC}\\[\\??\\d+(?:;\\d+)*R|${ESC}\\[(?:\\?|>)?[\\d;]*c|${ESC}\\[[IO]|${ESC}\\[\\d*n)$`,
);

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
    event.type === "compositionend"
  ) {
    return true;
  }
  if (event.type === "beforeinput" || event.type === "input") {
    const inputType = (event as InputEvent).inputType;
    return (
      inputType === "insertCompositionText" ||
      inputType === "insertFromComposition" ||
      inputType === "deleteCompositionText" ||
      inputType === "deleteByComposition"
    );
  }
  if (event.type === "keydown" || event.type === "keypress") {
    const key = event as KeyboardEvent;
    // keyCode 229 is the IME "processing" code. The property is legacy; read it without naming the deprecated field.
    const legacyCode = Reflect.get(key, "keyCode");
    return key.key === "Dead" || key.key === "Process" || legacyCode === 229;
  }
  return false;
}

export function createInputGate(element: HTMLElement, options: InputGateOptions): InputGate {
  const isUserEvent = options.isUserEvent ?? ((event: Event) => event.isTrusted);
  let userTurn = false;
  let disposed = false;
  // True from a composition or dead key until the nested clear runs, after xterm's flush.
  let flushPending = false;
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

  // The inner timer is queued when the outer one runs, so it lands after a composition flush already on the queue.
  const armDeferred = () => {
    userTurn = true;
    flushPending = true;
    clearDeferred();
    outer = setTimeout(() => {
      outer = undefined;
      inner = setTimeout(() => {
        inner = undefined;
        userTurn = false;
        flushPending = false;
      }, 0);
    }, 0);
  };

  const mark = (event: Event) => {
    if (disposed || !isUserEvent(event)) return;
    if (deferredUserEvent(event)) {
      armDeferred();
      return;
    }
    // beforeinput/input/keypress follow compositionend and must not open or close a sync window.
    if (flushPending) return;
    userTurn = true;
  };
  const endDispatch = (event: Event) => {
    if (disposed || !isUserEvent(event) || deferredUserEvent(event)) return;
    // xterm queues the composed character on setTimeout(0) during compositionend. The browser then
    // dispatches input and keypress before that timer. Those must not close the turn. An ordinary
    // keydown still closes when its own dispatch ends.
    if (
      flushPending &&
      (event.type === "input" || event.type === "keypress" || event.type === "beforeinput")
    ) {
      return;
    }
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
      flushPending = false;
      clearDeferred();
      for (const type of USER_EVENTS) {
        element.removeEventListener(type, mark, true);
        element.removeEventListener(type, endDispatch, false);
      }
    },
  };
}
