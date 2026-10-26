// The only door to motion (docs/design/README.md "Motion"). ESLint blocks `motion` and the Motion Primitives
// everywhere else. Transform and opacity only, 150-300 ms for UI, up to 600 ms for one-time entrances. Every wrapper
// renders static content under prefers-reduced-motion (src/components/motion/motion.test.tsx).
import { Children, type ReactNode } from "react";
import { MotionConfig, motion, type Transition } from "motion/react";

import { AnimatedGroup } from "@/components/motion-primitives/animated-group";
import { InView } from "@/components/motion-primitives/in-view";
import { TransitionPanel } from "@/components/motion-primitives/transition-panel";

import { useReducedMotion } from "./reduced-motion";

export { useReducedMotion };

/** Motion timing limits (ms), mirrored in docs/design/tokens.md. */
export const MOTION_MS = {
  staggerItem: 220,
  staggerStep: 40,
  staggerMax: 300,
  panel: 220,
  panelMax: 250,
  entrance: 600,
} as const;

const EASE_OUT = [0.16, 1, 0.3, 1] as const;

/** Root config: Motion itself also honours the OS setting. */
export function MotionRoot({ children }: { children: ReactNode }) {
  return <MotionConfig reducedMotion="user">{children}</MotionConfig>;
}

/** Stagger for cards and rows (Animated Group): 40 ms step, each item at most 300 ms. */
export function Stagger({ children, className }: { children: ReactNode; className?: string }) {
  const reduced = useReducedMotion();
  if (reduced) {
    return (
      <div className={className} data-motion="static">
        {Children.map(children, (child) => (
          <div>{child}</div>
        ))}
      </div>
    );
  }
  const transition: Transition = { duration: MOTION_MS.staggerItem / 1000, ease: EASE_OUT };
  return (
    <div data-motion="stagger" className="contents">
      <AnimatedGroup
        {...(className === undefined ? {} : { className })}
        variants={{
          container: { visible: { transition: { staggerChildren: MOTION_MS.staggerStep / 1000 } } },
          item: {
            hidden: { opacity: 0, y: 6 },
            visible: { opacity: 1, y: 0, transition },
          },
        }}
      >
        {children}
      </AnimatedGroup>
    </div>
  );
}

/**
 * The lead's "thinking" line. Text Shimmer (background-position) waits for the human's OK, so this is an opacity
 * pulse on one line of text until then (docs/tasks/T-101.md notes).
 */
export function Shimmer({ children, className }: { children: string; className?: string }) {
  const reduced = useReducedMotion();
  if (reduced) {
    return (
      <span className={className} data-motion="static">
        {children}
      </span>
    );
  }
  return (
    <motion.span
      className={className}
      data-motion="shimmer"
      initial={{ opacity: 1 }}
      animate={{ opacity: [1, 0.55, 1] }}
      transition={{ duration: 1.6, repeat: Infinity, ease: "easeInOut" }}
    >
      {children}
    </motion.span>
  );
}

/** One-time entrance (In View): fade and rise, at most 600 ms, once. */
export function Reveal({ children, className }: { children: ReactNode; className?: string }) {
  const reduced = useReducedMotion();
  if (reduced) {
    return (
      <div className={className} data-motion="static">
        {children}
      </div>
    );
  }
  return (
    <div data-motion="reveal" className="contents">
      <InView
        once
        {...(className === undefined ? {} : { className })}
        variants={{ hidden: { opacity: 0, y: 8 }, visible: { opacity: 1, y: 0 } }}
        transition={{ duration: MOTION_MS.entrance / 1000, ease: EASE_OUT }}
      >
        {children}
      </InView>
    </div>
  );
}

/** Switching panels or tabs (Transition Panel): opacity and a small shift, at most 250 ms. */
export function PanelSwitch({
  activeIndex,
  children,
  className,
}: {
  activeIndex: number;
  children: ReactNode[];
  className?: string;
}) {
  const reduced = useReducedMotion();
  if (reduced) {
    return (
      <div className={className} data-motion="static">
        {children[activeIndex]}
      </div>
    );
  }
  return (
    <div data-motion="panel" className="contents">
      <TransitionPanel
        activeIndex={activeIndex}
        {...(className === undefined ? {} : { className })}
        transition={{ duration: MOTION_MS.panel / 1000, ease: EASE_OUT }}
        variants={{
          enter: { opacity: 0, y: 4 },
          center: { opacity: 1, y: 0 },
          exit: { opacity: 0, y: -4 },
        }}
      >
        {children}
      </TransitionPanel>
    </div>
  );
}
