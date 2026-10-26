// Sidebar, page titles, ⌘1-⌘7 and the palette's "Go to" group all come from this one list.
import {
  ClipboardList,
  Gauge,
  Info,
  MessageSquare,
  PlugZap,
  ScanSearch,
  Settings,
  SquareTerminal,
  type LucideIcon,
} from "lucide-react";

import { paths } from "./paths";

export interface NavItem {
  id: "providers" | "lead" | "plans" | "sessions" | "review" | "usage" | "settings" | "about";
  label: string;
  path: string;
  icon: LucideIcon;
  /** ⌘<digit> shortcut, 1-7; About has none. */
  digit?: number;
}

export const NAV_ITEMS: readonly NavItem[] = [
  { id: "providers", label: "Providers", path: paths.providers(), icon: PlugZap, digit: 1 },
  { id: "lead", label: "Lead", path: paths.lead(), icon: MessageSquare, digit: 2 },
  { id: "plans", label: "Plans", path: paths.plans(), icon: ClipboardList, digit: 3 },
  { id: "sessions", label: "Sessions", path: paths.sessions(), icon: SquareTerminal, digit: 4 },
  { id: "review", label: "Review", path: paths.reviews(), icon: ScanSearch, digit: 5 },
  { id: "usage", label: "Usage", path: paths.usage(), icon: Gauge, digit: 6 },
  { id: "settings", label: "Settings", path: paths.settings(), icon: Settings, digit: 7 },
];

export const ABOUT_ITEM: NavItem = {
  id: "about",
  label: "About",
  path: paths.about(),
  icon: Info,
};

/** The nav item whose path is the pathname or a prefix of it. */
export function navItemFor(pathname: string): NavItem | undefined {
  return [...NAV_ITEMS, ABOUT_ITEM].find(
    (item) => pathname === item.path || pathname.startsWith(`${item.path}/`),
  );
}

/** "⌘" on macOS, "Ctrl+" elsewhere (labels only; both modifiers work). */
export function modKeyLabel(): string {
  return typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform)
    ? "⌘"
    : "Ctrl+";
}
