// Clock helpers for countdowns (backoff retry, pause-until, lead thinking). Times in the contract are RFC 3339 UTC.
import { useEffect, useState } from "react";

/** Current time in ms, re-rendering every `intervalMs` (default 1 s). */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => {
      setNow(Date.now());
    }, intervalMs);
    return () => {
      clearInterval(id);
    };
  }, [intervalMs]);
  return now;
}

/** Milliseconds from `now` until the RFC 3339 time `until` (negative once passed; NaN-safe: 0). */
export function msUntil(until: string, now: number): number {
  const at = Date.parse(until);
  return Number.isNaN(at) ? 0 : at - now;
}

/** "m:ss" under an hour, "h:mm:ss" above; "0:00" once the time has passed. Rounds up to whole seconds. */
export function formatCountdown(ms: number): string {
  const total = Number.isFinite(ms) && ms > 0 ? Math.ceil(ms / 1000) : 0;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const ss = String(s).padStart(2, "0");
  if (h > 0) return `${String(h)}:${String(m).padStart(2, "0")}:${ss}`;
  return `${String(m)}:${ss}`;
}
