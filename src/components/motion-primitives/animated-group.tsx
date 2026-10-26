// Motion Primitives: Animated Group (vendored, typed for strict mode). Use only through src/components/motion/Stagger.
import React, { type ReactNode } from "react";
import { motion, type Variants } from "motion/react";

export type PresetType = "fade" | "slide" | "scale";

export type AnimatedGroupProps = {
  children: ReactNode;
  className?: string;
  variants?: {
    container?: Variants;
    item?: Variants;
  };
  preset?: PresetType;
};

const defaultContainerVariants: Variants = {
  visible: {
    transition: {
      staggerChildren: 0.1,
    },
  },
};

const defaultItemVariants: Variants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1 },
};

// Transform and opacity only (docs/design/README.md): no blur, rotate or spring presets.
const presetVariants: Record<PresetType, Variants> = {
  fade: {},
  slide: {
    hidden: { y: 8 },
    visible: { y: 0 },
  },
  scale: {
    hidden: { scale: 0.98 },
    visible: { scale: 1 },
  },
};

const addDefaultVariants = (variants: Variants): Variants => ({
  hidden: { ...(defaultItemVariants.hidden as object), ...(variants.hidden as object) },
  visible: { ...(defaultItemVariants.visible as object), ...(variants.visible as object) },
});

function AnimatedGroup({ children, className, variants, preset }: AnimatedGroupProps) {
  const containerVariants = variants?.container ?? addDefaultVariants(defaultContainerVariants);
  const itemVariants = variants?.item ?? addDefaultVariants(preset ? presetVariants[preset] : {});

  return (
    <motion.div
      initial="hidden"
      animate="visible"
      variants={containerVariants}
      className={className}
    >
      {React.Children.map(children, (child, index) => (
        <motion.div key={index} variants={itemVariants}>
          {child}
        </motion.div>
      ))}
    </motion.div>
  );
}

export { AnimatedGroup };
