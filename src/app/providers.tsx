// Root providers: QueryClient, IPC, theme, motion config, tooltips and toasts.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";

import { MotionRoot } from "@/components/motion";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { IpcProvider, type IpcBundle } from "@/lib/ipc";

import { ThemeProvider } from "./theme";

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      // Events push full snapshots (setQueryData); no polling or refetch on focus, and IPC errors are not retried
      // (a retry storm would fight rule 10's pacing).
      queries: { retry: false, refetchOnWindowFocus: false, staleTime: Infinity },
      mutations: { retry: false },
    },
  });
}

export function AppProviders({
  bundle,
  queryClient,
  children,
}: {
  bundle: IpcBundle;
  queryClient?: QueryClient;
  children: ReactNode;
}) {
  const [client] = useState(() => queryClient ?? createQueryClient());
  return (
    <QueryClientProvider client={client}>
      <IpcProvider bundle={bundle}>
        <ThemeProvider>
          <MotionRoot>
            <TooltipProvider delayDuration={300}>
              {children}
              <Toaster />
            </TooltipProvider>
          </MotionRoot>
        </ThemeProvider>
      </IpcProvider>
    </QueryClientProvider>
  );
}
