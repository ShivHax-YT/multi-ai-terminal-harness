import { Link, useParams } from "react-router";

import { paths } from "@/app/paths";
import { ErrorAlert, LoadingSkeleton, UntrustedText } from "@/components/common";
import { useSimulation } from "@/lib/use-simulation";

export default function ReviewScreen() {
  const query = useSimulation();
  const { taskId } = useParams();
  if (query.isPending) return <LoadingSkeleton label="Loading sample review" />;
  if (query.isError) return <ErrorAlert error={query.error} />;
  const plan =
    taskId === undefined
      ? query.data.plans.findLast((p) => p.result !== null)
      : query.data.plans.find((p) => p.id === taskId);
  if (plan?.result === null || plan === undefined)
    return (
      <div className="space-y-3">
        <p>No completed sample run selected.</p>
        <Link className="underline" to={paths.plans()}>
          View sample plans
        </Link>
      </div>
    );
  const result = plan.result;
  const native = result.isolation === "git_worktree";
  return (
    <div className="space-y-6">
      <div className="space-y-2">
        <h2 className="text-xl font-semibold">Simulated worker review · {plan.id}</h2>
        <p className="text-sm text-muted-foreground">
          {native
            ? "This result reports a Git worktree. Native execution and independent file verification are unavailable in this build."
            : "Browser simulation: this diff is illustrative. No files or worktrees were created."}
        </p>
      </div>
      <section aria-labelledby="sample-output" className="space-y-3 border-t pt-5">
        <h3 id="sample-output" className="font-semibold">
          Worker output
        </h3>
        <UntrustedText text={result.output} block />
        <UntrustedText text={result.worktree} block mono />
        {native && (
          <p className="text-sm">
            Reported source state: {result.source_unchanged ? "unchanged" : "changed"}. This app has
            not independently verified that report.
          </p>
        )}
      </section>
      <section aria-labelledby="sample-diff" className="space-y-3 border-t pt-5">
        <h3 id="sample-diff" className="font-semibold">
          README.md changes
        </h3>
        <UntrustedText
          text={result.diff}
          mono
          block
          className="max-h-[32rem] overflow-auto rounded-md bg-muted p-4"
        />
      </section>
      <p className="text-sm text-muted-foreground">
        No AI review or generated-code tests were run. This preview stays in memory and is lost when
        the app closes.
      </p>
      <Link className="underline underline-offset-4" to={paths.lead()}>
        Create another task
      </Link>
    </div>
  );
}
