// Typed route helpers (hash router). Screens link with these, never with hand-written strings.
// Spec: docs/tasks/T-101-ipc-contract.md "Routes".

export const REVIEW_TABS = ["diff", "tests", "handoff"] as const;
export type ReviewTab = (typeof REVIEW_TABS)[number];

export function isReviewTab(value: unknown): value is ReviewTab {
  return typeof value === "string" && (REVIEW_TABS as readonly string[]).includes(value);
}

const seg = (value: string): string => encodeURIComponent(value);

export const paths = {
  root: () => "/",
  providers: () => "/providers",
  lead: () => "/lead",
  plans: () => "/plans",
  plan: (planId: string) => `/plans/${seg(planId)}`,
  sessions: () => "/sessions",
  session: (sessionId: string) => `/sessions/${seg(sessionId)}`,
  reviews: () => "/review",
  review: (taskId: string, tab?: ReviewTab) =>
    `/review/${seg(taskId)}${tab === undefined ? "" : `?tab=${tab}`}`,
  usage: () => "/usage",
  settings: () => "/settings",
  about: () => "/about",
} as const;

/** The screen `/` redirects to. */
export const HOME_PATH = paths.lead();

/** Route patterns for routes.tsx (relative to the shell route). */
export const ROUTE_PATTERNS = {
  providers: "providers",
  lead: "lead",
  plans: "plans",
  plan: "plans/:planId",
  sessions: "sessions",
  session: "sessions/:sessionId",
  reviews: "review",
  review: "review/:taskId",
  usage: "usage",
  settings: "settings",
  about: "about",
} as const;
