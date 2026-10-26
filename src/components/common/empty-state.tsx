import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";

import { cn } from "@/lib/utils";

export interface EmptyStateProps {
  title: string;
  description?: string;
  icon?: LucideIcon;
  /** At most one action; it is the screen's primary action only if the screen has nothing else. */
  action?: ReactNode;
  className?: string;
}

export function EmptyState({ title, description, icon: Icon, action, className }: EmptyStateProps) {
  return (
    <section
      aria-label={title}
      className={cn(
        "bg-card text-card-foreground flex flex-col items-center gap-3 rounded-xl border px-6 py-12 text-center",
        className,
      )}
    >
      {Icon !== undefined && <Icon aria-hidden="true" className="text-muted-foreground size-6" />}
      <h2 className="text-base font-semibold">{title}</h2>
      {description !== undefined && (
        <p className="text-muted-foreground max-w-[65ch] text-sm">{description}</p>
      )}
      {action}
    </section>
  );
}
