// Motion Primitives: Text Shimmer (vendored, typed for strict mode). Use only through src/components/motion/Shimmer.
// It animates background-position, the one documented exception to transform/opacity motion, and waits for the
// human's OK (docs/tasks/T-101.md notes). Until then Shimmer renders an opacity pulse and does not use this file.
// Colors come from the Harness tokens (no hard-coded hues, rule 8).
import React, { useMemo } from "react";
import { motion } from "motion/react";
import { cn } from "@/lib/utils";

export type TextShimmerProps = {
  children: string;
  className?: string;
  duration?: number;
  spread?: number;
};

function TextShimmerComponent({ children, className, duration = 2, spread = 2 }: TextShimmerProps) {
  const dynamicSpread = useMemo(() => children.length * spread, [children, spread]);

  return (
    <motion.span
      className={cn(
        "relative inline-block bg-[length:250%_100%,auto] bg-clip-text text-transparent",
        "[--base-color:var(--muted-foreground)] [--base-gradient-color:var(--foreground)]",
        "[background-repeat:no-repeat,padding-box]",
        className,
      )}
      initial={{ backgroundPosition: "100% center" }}
      animate={{ backgroundPosition: "0% center" }}
      transition={{ repeat: Infinity, duration, ease: "linear" }}
      style={
        {
          "--spread": `${String(dynamicSpread)}px`,
          backgroundImage:
            "linear-gradient(90deg, transparent calc(50% - var(--spread)), var(--base-gradient-color), transparent calc(50% + var(--spread))), linear-gradient(var(--base-color), var(--base-color))",
        } as React.CSSProperties
      }
    >
      {children}
    </motion.span>
  );
}

export const TextShimmer = React.memo(TextShimmerComponent);
