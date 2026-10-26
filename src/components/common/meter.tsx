// "x of y" usage meter. Warning at 80 % of the limit, danger at 100 %; status is an icon plus text, never color alone.
import { CircleAlert, CircleCheck, OctagonX } from "lucide-react";

import { cn } from "@/lib/utils";

export type MeterLevel = "ok" | "warning" | "danger";

export function meterLevel(current: number, limit: number): MeterLevel {
  if (limit <= 0) return current > 0 ? "danger" : "ok";
  const ratio = current / limit;
  if (ratio >= 1) return "danger";
  if (ratio >= 0.8) return "warning";
  return "ok";
}

const LEVEL = {
  ok: { icon: CircleCheck, text: "Within limit", bar: "bg-primary", tone: "text-muted-foreground" },
  warning: { icon: CircleAlert, text: "Near limit", bar: "bg-warning", tone: "text-warning" },
  danger: { icon: OctagonX, text: "At limit", bar: "bg-destructive", tone: "text-destructive" },
} as const;

export interface MeterProps {
  label: string;
  current: number;
  limit: number;
  /** Formats both numbers, e.g. formatMinutes. */
  format?: (value: number) => string;
  className?: string;
}

export function Meter({ label, current, limit, format = String, className }: MeterProps) {
  const level = meterLevel(current, limit);
  const { icon: Icon, text, bar, tone } = LEVEL[level];
  const pct = limit > 0 ? Math.min(100, Math.max(0, (current / limit) * 100)) : 100;
  const valueText = `${format(current)} of ${format(limit)}`;
  return (
    <div className={cn("flex flex-col gap-1.5", className)} data-level={level}>
      <div className="flex items-baseline justify-between gap-3 text-sm">
        <span className="font-medium">{label}</span>
        <span className="font-mono text-[13px] tabular-nums">{valueText}</span>
      </div>
      <div
        role="meter"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={limit}
        aria-valuenow={Math.min(current, Math.max(limit, 0))}
        aria-valuetext={`${valueText}, ${text.toLowerCase()}`}
        className="h-2 w-full overflow-hidden rounded-full bg-muted"
      >
        <div className={cn("h-full rounded-full", bar)} style={{ width: `${String(pct)}%` }} />
      </div>
      <span className={cn("flex items-center gap-1 text-xs", tone)}>
        <Icon aria-hidden="true" className="size-3.5" />
        {text}
      </span>
    </div>
  );
}
