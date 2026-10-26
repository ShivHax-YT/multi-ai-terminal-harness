// Motion Primitives: Transition Panel (vendored, typed for strict mode). Use only through
// src/components/motion/PanelSwitch.
import type { ReactNode } from "react";
import { AnimatePresence, motion, type Transition, type Variant } from "motion/react";
import { cn } from "@/lib/utils";

export type TransitionPanelProps = {
  children: ReactNode[];
  className?: string;
  transition?: Transition;
  activeIndex: number;
  variants?: { enter: Variant; center: Variant; exit: Variant };
};

export function TransitionPanel({
  children,
  className,
  transition,
  variants,
  activeIndex,
}: TransitionPanelProps) {
  return (
    <div className={cn("relative", className)}>
      <AnimatePresence initial={false} mode="popLayout">
        <motion.div
          key={activeIndex}
          {...(variants === undefined ? {} : { variants })}
          {...(transition === undefined ? {} : { transition })}
          initial="enter"
          animate="center"
          exit="exit"
        >
          {children[activeIndex]}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}
