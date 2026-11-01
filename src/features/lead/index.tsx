import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState, type SubmitEvent } from "react";
import { Link, useNavigate } from "react-router";

import { paths } from "@/app/paths";
import { ErrorAlert, LoadingSkeleton } from "@/components/common";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { useIpc } from "@/lib/ipc";
import { SIMULATION_KEY, useSimulation } from "@/lib/use-simulation";

export default function LeadScreen() {
  const ipc = useIpc();
  const query = useSimulation();
  const cache = useQueryClient();
  const navigate = useNavigate();
  const [project, setProject] = useState("sample");
  const [task, setTask] = useState("");
  const submit = useMutation({
    mutationFn: () => ipc.sim_submit({ project_id: project, task }),
    onSuccess: async (plan) => {
      await cache.invalidateQueries({ queryKey: SIMULATION_KEY });
      await navigate(paths.plan(plan.id));
    },
  });
  function onSubmit(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!submit.isPending) submit.mutate();
  }
  if (query.isPending) return <LoadingSkeleton label="Loading sample project" />;
  if (query.isError) return <ErrorAlert error={query.error} />;
  return (
    <div className="max-w-3xl space-y-8">
      <div className="space-y-2">
        <h2 className="text-xl font-semibold">Sample workflow preview</h2>
        <p className="text-sm text-muted-foreground">
          {query.data.runtime === "browser"
            ? "This demo creates a plan and illustrative diff in memory. It does not call AI tools or change files."
            : "You can preview a sample plan. Running workers and selecting local repositories are unavailable."}
        </p>
      </div>
      <form onSubmit={onSubmit} className="space-y-5">
        <div className="space-y-2">
          <Label htmlFor="sample-project">Project</Label>
          <select
            id="sample-project"
            value={project}
            onChange={(e) => {
              setProject(e.target.value);
            }}
            className="h-10 w-full rounded-md border bg-background px-3 text-sm focus-visible:ring-2 focus-visible:ring-ring"
          >
            {query.data.projects.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
          <p className="text-sm text-muted-foreground">
            Only the sample project is available. Local repository selection is not implemented.
          </p>
        </div>
        <div className="space-y-2">
          <Label htmlFor="sample-task">Task</Label>
          <Textarea
            id="sample-task"
            value={task}
            maxLength={4000}
            rows={5}
            placeholder="Describe a small change to try…"
            onChange={(e) => {
              setTask(e.target.value);
            }}
          />
          <p className="text-sm text-muted-foreground">
            {query.data.runtime === "browser"
              ? "The preview shows how task text would be added to README.md. It does not change files."
              : "This creates a plan preview only. No files change and no worker starts."}
          </p>
        </div>
        {submit.isError && <ErrorAlert error={submit.error} />}
        <Button type="submit" disabled={task.trim() === "" || submit.isPending}>
          {submit.isPending ? "Preparing plan…" : "Prepare simulated plan"}
        </Button>
      </form>
      {query.data.plans.length > 0 && (
        <div className="space-y-3 border-t pt-5">
          <h3 className="font-semibold">Recent sample tasks</h3>
          <ul className="space-y-2">
            {query.data.plans.toReversed().map((p) => (
              <li key={p.id}>
                <Link className="underline underline-offset-4" to={paths.plan(p.id)}>
                  {p.id} · {p.status}
                </Link>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
