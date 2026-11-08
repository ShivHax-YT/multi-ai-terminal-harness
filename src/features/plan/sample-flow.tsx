import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "react-router";

import { paths } from "@/app/paths";
import { ErrorAlert, LoadingSkeleton, UntrustedText } from "@/components/common";
import { Button } from "@/components/ui/button";
import { useIpc } from "@/lib/ipc";
import { useApproval } from "@/lib/ipc/approval";
import { SIMULATION_KEY, useSimulation } from "@/lib/use-simulation";

/** The labelled sample workflow (T-133). Memory-only in the browser demo; native execution stays unavailable. */
export function SampleFlow() {
  const query = useSimulation();
  const cache = useQueryClient();
  const { planId } = useParams();
  const ipc = useIpc();
  const approval = useApproval();
  const plan =
    planId === undefined
      ? query.data?.plans.at(-1)
      : query.data?.plans.find((p) => p.id === planId);
  const run = useMutation({
    mutationFn: async () => {
      if (plan === undefined) throw new Error("Plan not found");
      const { token } = await approval.sim_approve_plan({ plan_id: plan.id, plan_hash: plan.hash });
      return ipc.sim_run({ plan_id: plan.id, plan_hash: plan.hash, token });
    },
    onSettled: async () => {
      await cache.invalidateQueries({ queryKey: SIMULATION_KEY });
    },
  });
  if (query.isPending) return <LoadingSkeleton label="Loading simulated plan" />;
  if (query.isError) return <ErrorAlert error={query.error} />;
  if (plan === undefined)
    return (
      <div className="space-y-3">
        <p>No sample plan selected.</p>
        <Link className="underline" to={paths.lead()}>
          Create a sample task
        </Link>
      </div>
    );
  return (
    <div className="max-w-3xl space-y-6">
      <div className="space-y-2">
        <h2 className="text-xl font-semibold">Simulated plan · {plan.id}</h2>
        <p className="text-sm text-muted-foreground">
          {query.data.runtime === "native"
            ? "This is a sample plan. Native worker execution is unavailable."
            : "Review the scope before approving the memory-only preview. No AI tool is called and no files change."}
        </p>
      </div>
      <div className="space-y-3 border-y py-5">
        <h3 className="font-semibold">Requested task</h3>
        <UntrustedText text={plan.task} block />
        <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
          <dt className="text-muted-foreground">Project</dt>
          <dd>Harness sample project</dd>
          <dt className="text-muted-foreground">Worker</dt>
          <dd>Deterministic simulation</dd>
          <dt className="text-muted-foreground">Proposed change</dt>
          <dd>Append task text to README.md</dd>
          <dt className="text-muted-foreground">Isolation</dt>
          <dd>
            {query.data.runtime === "native"
              ? "Worktree creation blocked by the safety guard; native execution will refuse"
              : "Browser memory only; no files or worktrees"}
          </dd>
          <dt className="text-muted-foreground">Validation</dt>
          <dd>
            {query.data.runtime === "native"
              ? "Execution blocked; no file comparison or tests"
              : "Memory preview only; no file comparison or tests"}
          </dd>
          <dt className="text-muted-foreground">Status</dt>
          <dd role="status">{run.isPending ? "Running simulated worker…" : plan.status}</dd>
        </dl>
        <p className="text-xs text-muted-foreground">Approval is tied to this plan hash.</p>
        <UntrustedText text={plan.hash} mono block className="break-all" />
      </div>
      {plan.error !== null && <p role="alert">{plan.error}</p>}
      {run.isError && <ErrorAlert error={run.error} />}
      {plan.status === "pending" && (
        <Button
          disabled={run.isPending || query.data.runtime === "native"}
          onClick={() => {
            run.mutate();
          }}
        >
          {query.data.runtime === "native"
            ? "Worker execution unavailable"
            : "Approve and run simulated worker"}
        </Button>
      )}
      {plan.status === "completed" && (
        <Button asChild>
          <Link to={paths.review(plan.id)}>Review output and file changes</Link>
        </Button>
      )}
      {(plan.status === "approved" || plan.status === "running") && !run.isPending && (
        <p>
          The run may have been interrupted. Approval cannot be replayed; create a new sample task.
        </p>
      )}
      <p>
        <Link className="text-sm underline underline-offset-4" to={paths.lead()}>
          Create another task
        </Link>
      </p>
    </div>
  );
}
