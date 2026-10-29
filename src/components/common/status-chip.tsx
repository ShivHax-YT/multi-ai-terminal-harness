// Icon-plus-label status (shared by T-102, T-104, T-105, T-107). Color is never the only signal: every tone has its own
// icon and the label is always visible text.
import {
  CircleCheck,
  CircleDashed,
  CircleX,
  Info,
  TriangleAlert,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";

export type StatusTone = "success" | "warning" | "danger" | "info" | "neutral";

const TONES: Record<StatusTone, { icon: LucideIcon; className: string }> = {
  success: { icon: CircleCheck, className: "border-success/40 text-success" },
  warning: { icon: TriangleAlert, className: "border-warning/40 text-warning" },
  danger: { icon: CircleX, className: "border-destructive/40 text-destructive" },
  info: { icon: Info, className: "border-border text-foreground" },
  neutral: { icon: CircleDashed, className: "border-border text-muted-foreground" },
};

export interface StatusChipProps {
  tone: StatusTone;
  label: string;
  className?: string;
}

export function StatusChip({ tone, label, className }: StatusChipProps) {
  const { icon: Icon, className: toneClass } = TONES[tone];
  return (
    <span
      data-tone={tone}
      className={cn(
        "inline-flex w-fit shrink-0 items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium whitespace-nowrap",
        toneClass,
        className,
      )}
    >
      <Icon aria-hidden="true" className="size-3" />
      {label}
    </span>
  );
}
