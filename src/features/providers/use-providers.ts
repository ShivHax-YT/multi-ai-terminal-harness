// Data hooks for the Providers screen. Only the four status commands are issued: list_providers,
// refresh_provider_status, confirm_personal_use and open_provider_login (rule 4: no CLI files, no other commands).
import { useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router";

import { paths } from "@/app/paths";
import { useIpc, useIpcEvent, type ProviderStatus } from "@/lib/ipc";

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

/** The provider list. Events push full snapshots into the cache; there is no polling and no automatic retry. */
export function useProviders() {
  const client = useIpc();
  const queryClient = useQueryClient();
  useIpcEvent("provider_changed", (status) => {
    putStatus(queryClient, status);
  });
  return useQuery({
    queryKey: PROVIDERS_KEY,
    queryFn: () => client.list_providers(),
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
      switch (kind) {
        case "check_again":
          putStatus(queryClient, await client.refresh_provider_status(args));
          return undefined;
        case "confirm":
          putStatus(queryClient, await client.confirm_personal_use(args));
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
