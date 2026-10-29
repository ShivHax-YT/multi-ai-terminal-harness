// Data hooks for the Providers screen. Only the four status commands are issued: list_providers,
// refresh_provider_status, confirm_personal_use and open_provider_login (rule 4: no CLI files, no other commands).
import { useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router";

import { paths } from "@/app/paths";
import { useIpc, useIpcEvent, type ProviderStatus } from "@/lib/ipc";
import type { ProviderId } from "@/strings/providers";

import type { StepKind } from "./next-step";

export const PROVIDERS_KEY = ["providers"] as const;

function replaceStatus(
  list: ProviderStatus[] | undefined,
  next: ProviderStatus,
): ProviderStatus[] | undefined {
  if (list === undefined) return list;
  return list.map((p) => (p.provider === next.provider ? next : p));
}

function putStatus(queryClient: QueryClient, next: ProviderStatus): void {
  queryClient.setQueryData<ProviderStatus[]>(PROVIDERS_KEY, (old) => replaceStatus(old, next));
}

// The contract has no sequence field on ProviderStatus, so the screen numbers the events it sees. A response to a
// request that started before a newer provider_changed event for the same provider is stale and is dropped.
interface EventLog {
  seq: number;
  latest: Map<ProviderId, { seq: number; status: ProviderStatus }>;
}

const EVENT_LOGS = new WeakMap<QueryClient, EventLog>();

function eventLog(queryClient: QueryClient): EventLog {
  let log = EVENT_LOGS.get(queryClient);
  if (log === undefined) {
    log = { seq: 0, latest: new Map() };
    EVENT_LOGS.set(queryClient, log);
  }
  return log;
}

function recordEvent(queryClient: QueryClient, status: ProviderStatus): void {
  const log = eventLog(queryClient);
  log.seq += 1;
  log.latest.set(status.provider, { seq: log.seq, status });
  putStatus(queryClient, status);
}

/** The newer event's status when one arrived after `startedAt`, else undefined. */
function newerEvent(
  queryClient: QueryClient,
  provider: ProviderId,
  startedAt: number,
): ProviderStatus | undefined {
  const entry = eventLog(queryClient).latest.get(provider);
  return entry !== undefined && entry.seq > startedAt ? entry.status : undefined;
}

/**
 * The provider list. Events push full snapshots into the cache; there is no polling and no automatic retry.
 * Events are heard only while this screen is mounted, so every mount revalidates (a login finished or a kill-switch
 * change made elsewhere shows up on return). A global subscription in the app shell would be the lead's later change.
 */
export function useProviders() {
  const client = useIpc();
  const queryClient = useQueryClient();
  useIpcEvent("provider_changed", (status) => {
    recordEvent(queryClient, status);
  });
  return useQuery({
    queryKey: PROVIDERS_KEY,
    refetchOnMount: "always",
    queryFn: async () => {
      const startedAt = eventLog(queryClient).seq;
      const list = await client.list_providers();
      return list.map((p) => newerEvent(queryClient, p.provider, startedAt) ?? p);
    },
  });
}

export type IpcStepKind = Exclude<StepKind, "go_to_lead">;

/**
 * The card's one action. `sign_in` only opens the CLI's own login (rule 5: refused here unless the status already
 * says personal use is confirmed), then moves to that login session's terminal, which the human completes.
 */
export function useProviderStep(status: ProviderStatus) {
  const client = useIpc();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  return useMutation<undefined, unknown, IpcStepKind>({
    mutationFn: async (kind) => {
      const args = { provider: status.provider };
      const startedAt = eventLog(queryClient).seq;
      // A response is dropped when a newer provider_changed event for this provider arrived while it was in flight.
      const keep = (next: ProviderStatus) => {
        if (newerEvent(queryClient, status.provider, startedAt) === undefined) {
          putStatus(queryClient, next);
        }
      };
      switch (kind) {
        case "check_again":
          keep(await client.refresh_provider_status(args));
          return undefined;
        case "confirm":
          keep(await client.confirm_personal_use(args));
          return undefined;
        case "sign_in": {
          if (!status.personal_use_confirmed) return undefined;
          const { session_id } = await client.open_provider_login(args);
          void navigate(paths.session(session_id));
          return undefined;
        }
      }
    },
  });
}
