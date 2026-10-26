// Motion Primitives: In View (vendored, typed for strict mode). Use only through src/components/motion/Reveal.
import { useRef, useState, type ReactNode } from "react";
import {
  motion,
  useInView,
  type Transition,
  type UseInViewOptions,
  type Variant,
} from "motion/react";

export type InViewProps = {
  children: ReactNode;
  className?: string;
  variants?: {
    hidden: Variant;
    visible: Variant;
  };
  transition?: Transition;
  viewOptions?: UseInViewOptions;
  once?: boolean;
};

const defaultVariants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1 },
};

export function InView({
  children,
  className,
  variants = defaultVariants,
  transition,
  viewOptions,
  once,
}: InViewProps) {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, viewOptions);
  const [isViewed, setIsViewed] = useState(false);

  return (
    <motion.div
      ref={ref}
      className={className}
      initial="hidden"
      onAnimationComplete={() => {
        if (once === true) setIsViewed(true);
      }}
      animate={isInView || isViewed ? "visible" : "hidden"}
      variants={variants}
      {...(transition === undefined ? {} : { transition })}
    >
      {children}
    </motion.div>
  );
}
