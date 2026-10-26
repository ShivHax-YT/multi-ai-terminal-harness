// Time left until an RFC 3339 instant (backoff retry, pause-until). Mono digits so the width stays steady.
import { formatCountdown, msUntil, useNow } from "@/lib/time";
import { cn } from "@/lib/utils";

export interface CountdownProps {
  /** RFC 3339 UTC time. */
  until: string;
  /** Fixed "now" in ms (tests, or a parent clock); otherwise ticks every second. */
  now?: number;
  /** Shown once the time has passed. */
  doneLabel?: string;
  className?: string;
}

export function Countdown({ until, now, doneLabel = "now", className }: CountdownProps) {
  const ticking = useNow();
  const left = msUntil(until, now ?? ticking);
  return (
    <time dateTime={until} className={cn("font-mono tabular-nums", className)}>
      {left > 0 ? formatCountdown(left) : doneLabel}
    </time>
  );
}
