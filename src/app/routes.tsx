// Route registry. Each screen is a lazily loaded feature index; this is the only file that imports features.
import { lazy } from "react";
import { Navigate, type RouteObject } from "react-router";

import { HOME_PATH, ROUTE_PATTERNS } from "./paths";
import { Shell } from "./shell";

const ProvidersScreen = lazy(() => import("@/features/providers"));
const LeadScreen = lazy(() => import("@/features/lead"));
const PlansScreen = lazy(() => import("@/features/plan"));
const SessionsScreen = lazy(() => import("@/features/sessions"));
const ReviewScreen = lazy(() => import("@/features/review"));
const UsageScreen = lazy(() => import("@/features/usage"));
const SettingsScreen = lazy(() => import("@/features/settings"));
const AboutScreen = lazy(() => import("@/features/about"));

export const routes: RouteObject[] = [
  {
    path: "/",
    element: <Shell />,
    children: [
      { index: true, element: <Navigate to={HOME_PATH} replace /> },
      { path: ROUTE_PATTERNS.providers, element: <ProvidersScreen /> },
      { path: ROUTE_PATTERNS.lead, element: <LeadScreen /> },
      { path: ROUTE_PATTERNS.plans, element: <PlansScreen /> },
      { path: ROUTE_PATTERNS.plan, element: <PlansScreen /> },
      { path: ROUTE_PATTERNS.sessions, element: <SessionsScreen /> },
      { path: ROUTE_PATTERNS.session, element: <SessionsScreen /> },
      { path: ROUTE_PATTERNS.reviews, element: <ReviewScreen /> },
      { path: ROUTE_PATTERNS.review, element: <ReviewScreen /> },
      { path: ROUTE_PATTERNS.usage, element: <UsageScreen /> },
      { path: ROUTE_PATTERNS.settings, element: <SettingsScreen /> },
      { path: ROUTE_PATTERNS.about, element: <AboutScreen /> },
      { path: "*", element: <Navigate to={HOME_PATH} replace /> },
    ],
  },
];
