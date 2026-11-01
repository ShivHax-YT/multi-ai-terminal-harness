// T-102: the Providers screen. Shows, for each provider, whether its CLI is installed, binary-verified, signed in and
// usable, from the backend's ProviderStatus only (rule 4), and offers the one next step. Sign-in happens in the CLI's
// own terminal, which the human completes.
import { PlugZap } from "lucide-react";

import { Stagger } from "@/components/motion";
import { EmptyState, ErrorAlert, LoadingSkeleton } from "@/components/common";
import { Button } from "@/components/ui/button";
import { toIpcRejection } from "@/lib/ipc";

import { STAGGERED_CARDS } from "./motion-budget";
import { executionUnavailable, primaryProvider } from "./next-step";
import { ProviderCard } from "./provider-card";
import { useProviders } from "./use-providers";

export default function ProvidersScreen() {
  const providers = useProviders();

  return (
    <div className="flex flex-col gap-6">
      <p className="max-w-[65ch] text-sm text-muted-foreground">
        Check your installed tools and sign-in status. Each CLI keeps its own passwords and sign-in
        tokens.
      </p>
      <ProvidersBody providers={providers} />
    </div>
  );
}

function ProvidersBody({ providers }: { providers: ReturnType<typeof useProviders> }) {
  if (providers.isPending) return <LoadingSkeleton rows={3} label="Loading providers" />;
  if (providers.isError) {
    // No automatic retry. A manual retry is offered unless the backend refused or rate-limited us.
    const kind = toIpcRejection(providers.error).kind;
    const retryable = kind !== "rule_blocked" && kind !== "rate_limited";
    return (
      <ErrorAlert
        error={providers.error}
        action={
          retryable ? (
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="mt-2"
              onClick={() => {
                void providers.refetch();
              }}
            >
              Try again
            </Button>
          ) : undefined
        }
      />
    );
  }

  const list = providers.data;
  const nothingUsable = list.every((s) => !s.usable.lead && !s.usable.worker);
  const executionBlocked = nothingUsable && list.some(executionUnavailable);
  const primary = primaryProvider(list);

  return (
    <>
      {executionBlocked ? (
        <div role="status" className="space-y-1 rounded-md border bg-muted/40 px-4 py-3 text-sm">
          <p className="font-medium">Sign-in works. Task execution is still being built.</p>
          <p className="text-muted-foreground">
            The app cannot safely create isolated worktrees yet. Account confirmation will not
            enable tasks.
          </p>
        </div>
      ) : (
        nothingUsable && (
          <EmptyState
            icon={PlugZap}
            title="No tools can run tasks yet"
            description="Sign-in status and task readiness are separate. Each card explains what prevents task execution."
            className="py-8"
          />
        )
      )}
      <div className="grid grid-cols-1 gap-4 min-[900px]:grid-cols-2 min-[1280px]:grid-cols-3">
        {/* Only the first cards stagger, so the whole entrance stays within the 300 ms budget; the rest are static. */}
        <Stagger className="contents">
          {list.slice(0, STAGGERED_CARDS).map((status) => (
            <ProviderCard
              key={status.provider}
              status={status}
              primary={status.provider === primary}
            />
          ))}
        </Stagger>
        {list.slice(STAGGERED_CARDS).map((status) => (
          <ProviderCard
            key={status.provider}
            status={status}
            primary={status.provider === primary}
          />
        ))}
      </div>
    </>
  );
}
