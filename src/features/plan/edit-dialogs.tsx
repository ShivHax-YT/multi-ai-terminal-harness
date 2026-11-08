// The four plan edits. Each dialog sends exactly one PlanEdit when the human presses its save button. Nothing here
// approves anything: editing can only void an approval (rule 9), never grant one.
import { useState, type ReactNode, type SubmitEvent } from "react";

import { ProviderName } from "@/components/common";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import type { AuthMode, PlanEdit, PlanView, ProviderAuth, ProviderStatus, Task } from "@/lib/ipc";
import { providerLabel, type ProviderId } from "@/strings/providers";

import {
  acceptanceFromText,
  authModeLabel,
  authModesFor,
  fallbacksOutsidePlan,
  providerOptions,
} from "./plan-logic";

const SELECT_CLASS =
  "h-10 w-full rounded-md border bg-background px-3 text-sm focus-visible:ring-2 focus-visible:ring-ring";

interface EditProps {
  view: PlanView;
  task: Task;
  statuses: readonly ProviderStatus[] | undefined;
  disabled: boolean;
  onEdit: (edit: PlanEdit) => void;
}

function EditDialog({
  trigger,
  title,
  description,
  children,
}: {
  trigger: string;
  title: string;
  description: string;
  children: (close: () => void) => ReactNode;
}) {
  const [open, setOpen] = useState(false);
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm" type="button">
          {trigger}
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>
        {children(() => {
          setOpen(false);
        })}
      </DialogContent>
    </Dialog>
  );
}

export function EditProviderDialog({ view, task, statuses, disabled, onEdit }: EditProps) {
  return (
    <EditDialog
      trigger="Edit provider"
      title={`Edit provider for ${task.id}`}
      description="Only the provider and sign-in mode change. Other fields stay as the lead wrote them."
    >
      {(close) => (
        <ProviderForm
          view={view}
          task={task}
          statuses={statuses}
          disabled={disabled}
          onEdit={(edit) => {
            onEdit(edit);
            close();
          }}
        />
      )}
    </EditDialog>
  );
}

function ProviderForm({ task, statuses, disabled, onEdit }: EditProps) {
  const [provider, setProvider] = useState<ProviderId>(task.provider);
  const modes = authModesFor(statuses, provider);
  const [mode, setMode] = useState<AuthMode>(task.auth_mode);
  // Rule 7: only modes the provider's own status lists. An API-key-only provider lists only "api_key".
  const effective: AuthMode | undefined = modes.includes(mode) ? mode : modes[0];
  function submit(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault();
    if (effective === undefined) return;
    onEdit({ kind: "set_provider", task_id: task.id, provider, auth_mode: effective });
  }
  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor={`prov-${task.id}`}>Provider</Label>
        <select
          id={`prov-${task.id}`}
          className={SELECT_CLASS}
          value={provider}
          onChange={(e) => {
            setProvider(e.target.value as ProviderId);
          }}
        >
          {providerOptions(task).map((id) => (
            <option key={id} value={id}>
              {providerLabel(id)}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-2">
        <Label htmlFor={`mode-${task.id}`}>Sign-in mode</Label>
        <select
          id={`mode-${task.id}`}
          className={SELECT_CLASS}
          value={effective ?? ""}
          disabled={modes.length === 0}
          onChange={(e) => {
            setMode(e.target.value as AuthMode);
          }}
        >
          {modes.map((m) => (
            <option key={m} value={m}>
              {authModeLabel(m)}
            </option>
          ))}
        </select>
        {modes.length === 1 && modes[0] === "api_key" && (
          <p className="text-sm text-muted-foreground">
            <ProviderName id={provider} /> runs on an API key only.
          </p>
        )}
        {modes.length === 0 && (
          <p className="text-sm text-muted-foreground">
            This provider&apos;s status is not available, so it cannot be chosen.
          </p>
        )}
      </div>
      <DialogFooter>
        <Button type="submit" variant="outline" disabled={disabled || effective === undefined}>
          Save provider
        </Button>
      </DialogFooter>
    </form>
  );
}

export function EditFallbacksDialog(props: EditProps) {
  return (
    <EditDialog
      trigger="Edit fallbacks"
      title={`Edit fallbacks for ${props.task.id}`}
      description="Fallbacks are tried in this order, only on a different provider."
    >
      {(close) => (
        <FallbacksForm
          {...props}
          onEdit={(edit) => {
            props.onEdit(edit);
            close();
          }}
        />
      )}
    </EditDialog>
  );
}

function FallbacksForm({ view, task, statuses, disabled, onEdit }: EditProps) {
  const candidates = providerOptions(task).filter((p) => p !== task.provider);
  const initial = new Map<ProviderId, AuthMode>();
  for (const f of task.fallback_providers) {
    if (!initial.has(f.provider)) initial.set(f.provider, f.auth_mode);
  }
  const [selected, setSelected] = useState(initial);
  const [error, setError] = useState<string | null>(null);

  function build(): ProviderAuth[] {
    const out: ProviderAuth[] = [];
    // Existing order first, then newly added providers in option order.
    const order = [...initial.keys(), ...candidates.filter((c) => !initial.has(c))];
    for (const provider of order) {
      const mode = selected.get(provider);
      if (mode === undefined) continue;
      out.push({ provider, auth_mode: mode });
    }
    return out;
  }
  const next = build();
  const outside = fallbacksOutsidePlan(view, task, next);

  function toggle(provider: ProviderId, checked: boolean) {
    const copy = new Map(selected);
    if (!checked) copy.delete(provider);
    else {
      const modes = authModesFor(statuses, provider);
      const keep = initial.get(provider);
      const mode = keep !== undefined && modes.includes(keep) ? keep : modes[0];
      if (mode === undefined) {
        setError(`${providerLabel(provider)}: status is not available, so it cannot be chosen.`);
        return;
      }
      copy.set(provider, mode);
    }
    setError(null);
    setSelected(copy);
  }
  function setMode(provider: ProviderId, mode: AuthMode) {
    const copy = new Map(selected);
    copy.set(provider, mode);
    setSelected(copy);
  }
  function submit(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault();
    onEdit({ kind: "set_fallbacks", task_id: task.id, fallback_providers: next });
  }
  return (
    <form onSubmit={submit} className="space-y-4">
      <fieldset className="space-y-3">
        <legend className="text-sm font-medium">Fallback providers</legend>
        {candidates.map((provider) => {
          const mode = selected.get(provider);
          const modes = authModesFor(statuses, provider);
          const id = `fb-${task.id}-${provider}`;
          return (
            <div key={provider} className="flex flex-wrap items-center gap-3">
              <input
                id={id}
                type="checkbox"
                className="size-4"
                checked={mode !== undefined}
                onChange={(e) => {
                  toggle(provider, e.target.checked);
                }}
              />
              <Label htmlFor={id}>{providerLabel(provider)}</Label>
              {mode !== undefined && (
                <select
                  aria-label={`Sign-in mode for ${providerLabel(provider)}`}
                  className={`${SELECT_CLASS} w-auto`}
                  value={mode}
                  onChange={(e) => {
                    setMode(provider, e.target.value as AuthMode);
                  }}
                >
                  {(modes.includes(mode) ? modes : [mode]).map((m) => (
                    <option key={m} value={m}>
                      {authModeLabel(m)}
                    </option>
                  ))}
                </select>
              )}
            </div>
          );
        })}
      </fieldset>
      {error !== null && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {outside.length > 0 && (
        <p role="status" className="max-w-[65ch] text-sm text-warning">
          This needs a new approval. {outside.map((p) => providerLabel(p)).join(", ")} does not run
          any task in this plan.
        </p>
      )}
      <DialogFooter>
        <Button type="submit" variant="outline" disabled={disabled}>
          Save fallbacks
        </Button>
      </DialogFooter>
    </form>
  );
}

export function EditAcceptanceDialog({ task, disabled, onEdit }: EditProps) {
  return (
    <EditDialog
      trigger="Edit acceptance"
      title={`Edit acceptance for ${task.id}`}
      description="One check per line."
    >
      {(close) => (
        <AcceptanceForm
          task={task}
          disabled={disabled}
          onEdit={(edit) => {
            onEdit(edit);
            close();
          }}
        />
      )}
    </EditDialog>
  );
}

function AcceptanceForm({
  task,
  disabled,
  onEdit,
}: Pick<EditProps, "task" | "disabled" | "onEdit">) {
  const [text, setText] = useState(task.acceptance.join("\n"));
  const lines = acceptanceFromText(text);
  function submit(event: SubmitEvent<HTMLFormElement>) {
    event.preventDefault();
    if (lines.length === 0) return;
    onEdit({ kind: "set_acceptance", task_id: task.id, acceptance: lines });
  }
  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor={`acc-${task.id}`}>Acceptance checks</Label>
        <Textarea
          id={`acc-${task.id}`}
          rows={5}
          value={text}
          onChange={(e) => {
            setText(e.target.value);
          }}
        />
      </div>
      <DialogFooter>
        <Button type="submit" variant="outline" disabled={disabled || lines.length === 0}>
          Save acceptance
        </Button>
      </DialogFooter>
    </form>
  );
}

/** Destructive confirmation (discard a plan, remove a task). The action is never filled as the primary. */
export function ConfirmDestructive({
  trigger,
  title,
  description,
  confirm,
  disabled,
  onConfirm,
}: {
  trigger: string;
  title: string;
  description: string;
  confirm: string;
  disabled: boolean;
  onConfirm: () => void;
}) {
  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button
          variant="outline"
          size="sm"
          type="button"
          disabled={disabled}
          className="text-destructive"
        >
          {trigger}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>{description}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Keep it</AlertDialogCancel>
          <AlertDialogAction variant="outline" className="text-destructive" onClick={onConfirm}>
            {confirm}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
