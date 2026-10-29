// T-102: the Providers screen. Shows, for each provider, whether its CLI is installed, binary-verified, signed in and
// usable, from the backend's ProviderStatus only (rule 4), and offers the one next step. Sign-in happens in the CLI's
// own terminal, which the human completes.
import { PlugZap } from "lucide-react";

import { Stagger } from "@/components/motion";
import { EmptyState, ErrorAlert, LoadingSkeleton } from "@/components/common";
import { Button } from "@/components/ui/button";
import { toIpcRejection } from "@/lib/ipc";

import { STAGGERED_CARDS } from "./motion-budget";
import { primaryProvider } from "./next-step";
import { ProviderCard } from "./provider-card";
import { useProviders } from "./use-providers";

export default function ProvidersScreen() {
  const providers = useProviders();

  return (
    <div className="flex flex-col gap-6">
      <p className="max-w-[65ch] text-sm text-muted-foreground">
        Each tool runs on this Mac. You sign in to each one yourself, in its own terminal. This app
        never sees or stores your password.
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
  const primary = primaryProvider(list);

  return (
    <>
      {nothingUsable && (
        <EmptyState
          icon={PlugZap}
          title="Nothing is ready yet"
          description="No tool is usable yet. Each card below shows what blocks it and the one next step."
          className="py-8"
        />
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
