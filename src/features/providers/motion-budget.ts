// The entrance budget (docs/design/tokens.md): the whole stagger lasts at most MOTION_MS.staggerMax.
import { MOTION_MS } from "@/components/motion";

/** How many cards fit the budget: the last one starts at (n - 1) * step and then takes one item duration. */
export const STAGGERED_CARDS =
  Math.floor((MOTION_MS.staggerMax - MOTION_MS.staggerItem) / MOTION_MS.staggerStep) + 1;
