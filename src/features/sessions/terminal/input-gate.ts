// Rule 3: the only code that sends text to a PTY. Text passes only while take-over is on and a real user event on the
// terminal happened in this same turn. xterm also emits onData for its own replies to output escape codes; with no
// user event behind them, those are dropped.

/** Longest chunk the backend accepts in one write (a paste is split). */
export const MAX_CHUNK_BYTES = 4 * 1024;

// Keys, paste and text input. Pointer events count too: in a full-screen CLI, xterm turns wheel and clicks into input.
const USER_EVENTS = [
  "keydown",
  "keypress",
  "beforeinput",
  "input",
  "compositionend",
  "paste",
  "wheel",
  "mousedown",
  "mouseup",
] as const;

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

export function createInputGate(element: HTMLElement, options: InputGateOptions): InputGate {
  const isUserEvent = options.isUserEvent ?? ((event: Event) => event.isTrusted);
  let userTurn = false;
  let clear: ReturnType<typeof setTimeout> | undefined;
  // One at a time, so keystrokes reach the CLI in the order they were typed.
  let queue: Promise<void> = Promise.resolve();

  const mark = (event: Event) => {
    if (!isUserEvent(event)) return;
    userTurn = true;
    if (clear !== undefined) clearTimeout(clear);
    clear = setTimeout(() => {
      userTurn = false;
    }, 0);
  };
  for (const type of USER_EVENTS) element.addEventListener(type, mark, true);

  return {
    onData(data) {
      if (!userTurn || !options.takeoverOn()) return;
      for (const chunk of splitChunks(data)) {
        queue = queue
          .then(() => options.write(chunk))
          .catch((error: unknown) => {
            options.onRefused(error);
          });
      }
    },
    dispose() {
      if (clear !== undefined) clearTimeout(clear);
      for (const type of USER_EVENTS) element.removeEventListener(type, mark, true);
    },
  };
}
