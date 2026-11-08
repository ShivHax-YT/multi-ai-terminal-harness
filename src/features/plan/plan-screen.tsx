// The plan review screen (T-104). Approval (rule 9): the one button below calls approve_plan only from a human click,
// with the hash of the PlanView on screen, once per click. It is never called on mount, on plan_changed, on Enter in
// a form, from the palette or after an edit, and a stale-hash refusal is shown, never retried.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ClipboardList } from "lucide-react";
import { useState } from "react";
import { Link, useNavigate } from "react-router";

import { paths } from "@/app/paths";
import { EmptyState, ErrorAlert, LoadingSkeleton } from "@/components/common";
import { Stagger } from "@/components/motion";
import { Button } from "@/components/ui/button";
import {
  toIpcRejection,
  useIpc,
  useIpcEvent,
  type PlanEdit,
  type PlanListItem,
  type PlanView,
} from "@/lib/ipc";
import { useApproval } from "@/lib/ipc/approval";

import {
  ConfirmDestructive,
  EditAcceptanceDialog,
  EditFallbacksDialog,
  EditProviderDialog,
} from "./edit-dialogs";
import { canApprove, canEdit, shortHash } from "./plan-logic";
import { Estimates, PlanHeader, TaskCard, Violations } from "./plan-parts";

const PLANS_KEY = ["plans"] as const;
const PROVIDERS_KEY = ["providers"] as const;
const LIMITS_KEY = ["limits"] as const;
const planKey = (id: string) => ["plan", id] as const;

const STALE_MESSAGE = "This plan changed. Review it again.";

function newestFirst(list: PlanListItem[]): PlanListItem[] {
  return [...list].sort((a, b) =>
    a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0,
  );
}

export function PlanScreen({ planId }: { planId: string | undefined }) {
  const ipc = useIpc();
  const cache = useQueryClient();
  const list = useQuery({ queryKey: PLANS_KEY, queryFn: () => ipc.list_plans() });
  const selectedId =
    planId ?? (list.data === undefined ? undefined : newestFirst(list.data)[0]?.plan_id);

  // Events are full snapshots: replace the cached view, never merge. They never approve anything.
  useIpcEvent("plan_changed", (view) => {
    cache.setQueryData<PlanView>(planKey(view.plan.plan_id), view);
    void cache.invalidateQueries({ queryKey: PLANS_KEY });
  });

  if (planId === undefined) {
    if (list.isPending) return <LoadingSkeleton label="Loading plans" />;
    if (list.isError) return <ErrorAlert error={list.error} />;
    if (selectedId === undefined) return <NoPlans />;
  }
  if (selectedId === undefined) return <LoadingSkeleton label="Loading plan" />;
  const others = (list.data ?? []).filter((p) => p.plan_id !== selectedId);
  return (
    <div data-screen="plan" className="max-w-[1200px] space-y-6">
      <PlanDetail key={selectedId} planId={selectedId} />
      {others.length > 0 && (
        <nav aria-label="Other plans" className="space-y-1 text-sm">
          <h3 className="font-semibold">Other plans</h3>
          <ul className="space-y-1">
            {newestFirst(others).map((p) => (
              <li key={p.plan_id}>
                <Link className="font-mono text-[13px] underline" to={paths.plan(p.plan_id)}>
                  {p.plan_id}
                </Link>{" "}
                <span className="text-muted-foreground">
                  {String(p.task_count)} {p.task_count === 1 ? "task" : "tasks"}, {p.status}
                </span>
              </li>
            ))}
          </ul>
        </nav>
      )}
    </div>
  );
}

function NoPlans() {
  return (
    <EmptyState
      icon={ClipboardList}
      title="No plans yet. Ask the lead for one."
      action={
        <Button asChild variant="outline">
          <Link to={paths.lead()}>Open Lead</Link>
        </Button>
      }
    />
  );
}

function PlanDetail({ planId }: { planId: string }) {
  const ipc = useIpc();
  const approval = useApproval();
  const cache = useQueryClient();
  const navigate = useNavigate();
  const [stale, setStale] = useState(false);

  const plan = useQuery({
    queryKey: planKey(planId),
    queryFn: () => ipc.get_plan({ plan_id: planId }),
  });
  const limits = useQuery({ queryKey: LIMITS_KEY, queryFn: () => ipc.get_limits() });
  const providers = useQuery({ queryKey: PROVIDERS_KEY, queryFn: () => ipc.list_providers() });

  const edit = useMutation({
    mutationFn: (e: PlanEdit) => ipc.update_plan({ plan_id: planId, edit: e }),
    onSuccess: (view) => {
      cache.setQueryData(planKey(planId), view);
      setStale(false);
      void cache.invalidateQueries({ queryKey: PLANS_KEY });
    },
  });
  const discard = useMutation({
    mutationFn: () => ipc.discard_plan({ plan_id: planId }),
    onSuccess: async () => {
      cache.removeQueries({ queryKey: planKey(planId) });
      cache.setQueryData<PlanListItem[]>(PLANS_KEY, (old) =>
        old?.filter((p) => p.plan_id !== planId),
      );
      await cache.invalidateQueries({ queryKey: PLANS_KEY });
      await navigate(paths.plans());
    },
  });
  const approve = useMutation({
    // The hash is the one on screen when the human clicked; the screen never computes or substitutes a hash.
    mutationFn: (args: { plan_id: string; plan_hash: string }) => approval.approve_plan(args),
    onSuccess: (view) => {
      cache.setQueryData(planKey(planId), view);
      void cache.invalidateQueries({ queryKey: PLANS_KEY });
    },
    onError: (error) => {
      if (toIpcRejection(error).kind === "plan_hash_mismatch") {
        setStale(true);
        // Show the new plan. The human decides whether to approve it; nothing is retried.
        void cache.invalidateQueries({ queryKey: planKey(planId) });
      }
    },
  });

  if (plan.isPending) return <LoadingSkeleton label="Loading plan" />;
  if (plan.isError) return <ErrorAlert error={plan.error} />;
  const view = plan.data;
  const editable = canEdit(view);
  const busy = edit.isPending || approve.isPending || discard.isPending;
  const mismatch = approve.isError && toIpcRejection(approve.error).kind === "plan_hash_mismatch";

  function sendEdit(e: PlanEdit) {
    approve.reset();
    edit.mutate(e);
  }

  return (
    <div className="space-y-6">
      <PlanHeader view={view} />
      {view.needs_reapproval && (
        <p role="status" className="text-sm font-medium text-warning">
          Edited after approval. Approve again.
        </p>
      )}
      <Violations violations={view.violations} />
      <Stagger className="flex flex-col gap-3">
        {view.plan.tasks.map((task) => (
          <TaskCard
            key={task.id}
            task={task}
            violations={view.violations}
            controls={
              editable ? (
                <>
                  <EditProviderDialog
                    view={view}
                    task={task}
                    statuses={providers.data}
                    disabled={busy}
                    onEdit={sendEdit}
                  />
                  <EditFallbacksDialog
                    view={view}
                    task={task}
                    statuses={providers.data}
                    disabled={busy}
                    onEdit={sendEdit}
                  />
                  <EditAcceptanceDialog
                    view={view}
                    task={task}
                    statuses={providers.data}
                    disabled={busy}
                    onEdit={sendEdit}
                  />
                  <ConfirmDestructive
                    trigger="Remove task"
                    title={`Remove task ${task.id}?`}
                    description="The task is dropped from this plan. The plan needs a new review afterwards."
                    confirm="Remove task"
                    disabled={busy || view.plan.tasks.length === 1}
                    onConfirm={() => {
                      sendEdit({ kind: "remove_task", task_id: task.id });
                    }}
                  />
                </>
              ) : null
            }
          />
        ))}
      </Stagger>
      <Estimates estimates={view.estimates} limits={limits.data} />
      {limits.isError && <ErrorAlert error={limits.error} />}
      {edit.isError && <ErrorAlert error={edit.error} />}
      {discard.isError && <ErrorAlert error={discard.error} />}
      {approve.isError && !mismatch && <ErrorAlert error={approve.error} />}
      {(stale || mismatch) && (
        <p role="alert" className="text-sm font-medium text-destructive">
          {STALE_MESSAGE}
        </p>
      )}
      <ReadOnlyNote view={view} />
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          {editable && (
            <ConfirmDestructive
              trigger="Discard plan..."
              title="Discard this plan?"
              description="The plan is deleted. Ask the lead for a new one afterwards."
              confirm="Discard plan"
              disabled={busy}
              onConfirm={() => {
                discard.mutate();
              }}
            />
          )}
        </div>
        {canApprove(view) && (
          <Button
            type="button"
            className="min-h-11"
            disabled={busy}
            onClick={() => {
              setStale(false);
              approve.mutate({ plan_id: view.plan.plan_id, plan_hash: view.plan_hash });
            }}
          >
            Approve plan {shortHash(view.plan_hash)}
          </Button>
        )}
      </div>
    </div>
  );
}

function ReadOnlyNote({ view }: { view: PlanView }) {
  if (view.status === "draft") return null;
  const text: Record<Exclude<PlanView["status"], "draft">, string> = {
    approved: "This plan is approved and read-only.",
    running: "This plan is running and read-only.",
    done: "This plan is done and read-only.",
    superseded: "This plan was superseded and is read-only.",
  };
  return <p className="text-sm text-muted-foreground">{text[view.status]}</p>;
}
