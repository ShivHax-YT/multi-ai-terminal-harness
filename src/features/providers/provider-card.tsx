// One provider's card: what blocks it and the one next step. Everything the CLI or host reported (version, install
// path, install text, check details) is untrusted and renders only through UntrustedText (never a link, never HTML).
import { useId, type ReactNode } from "react";
import { Link, useNavigate } from "react-router";

import { paths } from "@/app/paths";
import {
  CopyButton,
  ErrorAlert,
  ProviderName,
  StatusChip,
  UntrustedText,
  type StatusTone,
} from "@/components/common";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardFooter, CardHeader, CardTitle } from "@/components/ui/card";
import type { BinaryCheck, ProviderStatus } from "@/lib/ipc";
import { cn } from "@/lib/utils";
import { providerLabel } from "@/strings/providers";

import {
  blockerSentence,
  executionUnavailable,
  keyOnly,
  nextStep,
  subscriptionAllowed,
  visibleBlockers,
  type NextStep,
} from "./next-step";
import { useProviderStep, type IpcStepKind } from "./use-providers";

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex min-w-0 items-start justify-between gap-3">
      <dt className="shrink-0 text-sm text-muted-foreground">{label}</dt>
      <dd className="flex min-w-0 flex-1 flex-col items-end gap-1 text-right">{children}</dd>
    </div>
  );
}

const CHECK_TONE: Record<BinaryCheck["result"], { tone: StatusTone; label: string }> = {
  pass: { tone: "success", label: "Passed" },
  fail: { tone: "danger", label: "Failed" },
  not_applicable: { tone: "neutral", label: "Not applicable" },
};

const CHECK_NAME: Record<BinaryCheck["kind"], string> = {
  codesign: "Code signature",
  checksum: "Checksum",
  install_source: "Install source",
};

function usableLabel(status: ProviderStatus): { tone: StatusTone; label: string } {
  const { lead, worker } = status.usable;
  if (lead && worker) return { tone: "success", label: "Usable as lead and worker" };
  if (lead) return { tone: "success", label: "Usable as lead" };
  if (worker) return { tone: "success", label: "Usable as worker" };
  return { tone: "neutral", label: "Tasks unavailable" };
}

function InstallRows({ status }: { status: ProviderStatus }) {
  const { install } = status;
  const installed = install.state === "installed";
  return (
    <Row label="Install">
      <StatusChip
        tone={installed ? "success" : "danger"}
        label={installed ? "Installed" : "Not installed"}
      />
      {installed && install.version !== undefined && (
        <UntrustedText text={install.version} mono className="text-muted-foreground" />
      )}
    </Row>
  );
}

function BinaryRow({ status }: { status: ProviderStatus }) {
  const { binary } = status;
  const chip: { tone: StatusTone; label: string } =
    binary.state === "verified"
      ? {
          tone: "success",
          label: binary.verification_scope === "kernel_identity" ? "Identity checked" : "Verified",
        }
      : binary.state === "failed"
        ? { tone: "danger", label: "Failed verification" }
        : { tone: "warning", label: "Not verified yet" };
  return (
    <Row label="Verification">
      <StatusChip {...chip} />
      {binary.state === "failed" && binary.checks.length > 0 && (
        <ul
          aria-label="Verification checks"
          className="flex flex-col gap-1.5 self-stretch text-left"
        >
          {binary.checks.map((check) => {
            const result = CHECK_TONE[check.result];
            return (
              <li key={check.kind} className="flex flex-col gap-0.5 text-sm">
                <span className="flex flex-wrap items-center gap-2">
                  <span>{CHECK_NAME[check.kind]}</span>
                  <StatusChip tone={result.tone} label={result.label} />
                </span>
                <UntrustedText text={check.detail} mono className="text-muted-foreground" />
              </li>
            );
          })}
        </ul>
      )}
    </Row>
  );
}

function SignInRows({ status }: { status: ProviderStatus }) {
  if (keyOnly(status)) {
    // Rule 7: key-only tools have no sign-in control anywhere, only this label.
    return (
      <Row label="Sign-in">
        <StatusChip tone="info" label="API key only" />
      </Row>
    );
  }
  if (status.killswitch === "api_key_only") {
    return (
      <Row label="Sign-in">
        <StatusChip tone="warning" label="Subscription use is off. API key only." />
      </Row>
    );
  }
  const state = status.sign_in.state;
  const chip: { tone: StatusTone; label: string } =
    state === "signed_in"
      ? { tone: "success", label: "Signed in" }
      : state === "signed_out"
        ? { tone: "warning", label: "Signed out" }
        : { tone: "neutral", label: "Sign-in state unknown" };
  return (
    <>
      <Row label="Sign-in">
        <StatusChip {...chip} />
        {state === "unknown" && status.sign_in.detail !== undefined && (
          <UntrustedText
            text={status.sign_in.detail}
            className="max-w-[32ch] text-sm text-muted-foreground"
          />
        )}
      </Row>
      <Row label="Personal use">
        {status.personal_use_confirmed ? (
          <StatusChip tone="success" label="Confirmed as your account" />
        ) : executionUnavailable(status) ? (
          <StatusChip tone="neutral" label="Required before tasks" />
        ) : (
          <StatusChip tone="warning" label="Not confirmed yet" />
        )}
      </Row>
      {status.sign_in.login_command !== undefined && status.binary.state === "verified" && (
        <Row label="CLI sign-in">
          <div className="flex flex-col gap-2 rounded-md border p-3 text-sm">
            <p>
              Run this command in Terminal, finish any browser prompts, then choose Check again.
            </p>
            <UntrustedText
              text={status.sign_in.login_command}
              mono
              block
              className="max-w-full text-left break-all"
            />
            <CopyButton value={status.sign_in.login_command} label="Copy login command" />
          </div>
        </Row>
      )}
    </>
  );
}

function TechnicalDetails({ status }: { status: ProviderStatus }) {
  const blockers = visibleBlockers(status);
  if (
    status.install.path === undefined &&
    status.sign_in.detail === undefined &&
    status.binary.verification_scope !== "kernel_identity" &&
    !executionUnavailable(status)
  )
    return null;
  return (
    <details className="min-w-0 border-t pt-3 text-sm text-muted-foreground">
      <summary className="cursor-pointer text-foreground select-none">Technical details</summary>
      <div className="mt-3 flex min-w-0 flex-col gap-3 text-left">
        {status.install.path !== undefined && (
          <div className="min-w-0 space-y-1">
            <p>Install location</p>
            <UntrustedText text={status.install.path} mono block className="max-w-full break-all" />
          </div>
        )}
        {status.binary.verification_scope === "kernel_identity" && (
          <p>
            macOS checked the CLI identity. Full-file integrity is still unverified, so this is not
            clearance to run tasks.
          </p>
        )}
        {status.binary.release_reviewed === false && (
          <p>
            This vendor-signed release is newer than the one reviewed for this build. Terminals
            work, and tasks stay off for it.
          </p>
        )}
        {status.sign_in.detail !== undefined && status.sign_in.state !== "unknown" && (
          <UntrustedText text={status.sign_in.detail} block />
        )}
        {executionUnavailable(status) && blockers.length > 0 && (
          <ul aria-label="Execution requirements" className="flex flex-col gap-1">
            {blockers.map((blocker) => (
              <li key={blocker}>{blockerSentence(blocker)}</li>
            ))}
          </ul>
        )}
      </div>
    </details>
  );
}

function InstallText({ status }: { status: ProviderStatus }) {
  const hint = status.install.install_hint;
  if (hint === undefined || hint === "") {
    return <p className="text-sm text-muted-foreground">No install text is available yet.</p>;
  }
  return (
    <div className="flex items-start gap-2">
      <div className="min-w-0 flex-1 rounded-md border bg-muted px-3 py-2">
        <UntrustedText text={hint} mono block />
      </div>
      <CopyButton value={hint} label={`Copy install text for ${providerLabel(status.provider)}`} />
    </div>
  );
}

function StepButton({
  step,
  primary,
  pending,
  titleId,
  onRun,
}: {
  step: NextStep;
  titleId: string;
  primary: boolean;
  pending: boolean;
  onRun: () => void;
}) {
  return (
    <Button
      type="button"
      variant={primary ? "default" : "outline"}
      className={cn(primary && "min-h-11 px-5")}
      disabled={pending}
      aria-busy={pending}
      aria-describedby={titleId}
      onClick={onRun}
    >
      {step.label}
    </Button>
  );
}

export function ProviderCard({ status, primary }: { status: ProviderStatus; primary: boolean }) {
  const titleId = useId();
  const hintId = useId();
  const navigate = useNavigate();
  const step = nextStep(status);
  const mutation = useProviderStep(status);
  const available = status.adapter_available && status.killswitch !== "disabled";
  const installed = status.install.state === "installed";
  const usable = usableLabel(status);
  const run = (kind: IpcStepKind) => () => {
    mutation.mutate(kind);
  };
  const appBlocked = executionUnavailable(status);
  const blockers = visibleBlockers(status).filter(
    (blocker) =>
      !appBlocked ||
      ![
        "execution_boundary_unavailable",
        "runtime_controls_unavailable",
        "provider_policy_unverified",
        "personal_use_unconfirmed",
      ].includes(blocker),
  );
  const showKeyRow = !subscriptionAllowed(status) && status.api_key !== null;

  return (
    <Card
      role="group"
      aria-labelledby={titleId}
      data-provider={status.provider}
      className="h-full min-w-0 gap-4"
    >
      <CardHeader>
        <CardTitle>
          <h2 id={titleId} className="text-base font-semibold">
            <ProviderName id={status.provider} />
          </h2>
        </CardTitle>
        <div>
          <StatusChip {...usable} />
        </div>
      </CardHeader>
      <CardContent className="flex min-w-0 flex-1 flex-col gap-4">
        {status.killswitch === "disabled" && (
          <StatusChip tone="danger" label="Turned off by remote config" />
        )}
        {available && (
          <dl className="flex flex-col gap-3">
            <InstallRows status={status} />
            {installed && <BinaryRow status={status} />}
            {(installed || !subscriptionAllowed(status)) && <SignInRows status={status} />}
            {showKeyRow && (
              <Row label="API key">
                {status.api_key?.present === true ? (
                  <StatusChip tone="success" label="API key saved" />
                ) : (
                  <StatusChip tone="warning" label="No API key yet" />
                )}
              </Row>
            )}
          </dl>
        )}
        {!status.adapter_available && (
          <StatusChip tone="neutral" label="Not available yet" className="w-fit" />
        )}
        {available && !installed && <InstallText status={status} />}
        {blockers.length > 0 && (
          <ul aria-label="What blocks it" className="flex flex-col gap-1 text-sm">
            {blockers.map((blocker) => (
              <li key={blocker} className="text-muted-foreground">
                {blockerSentence(blocker)}
              </li>
            ))}
          </ul>
        )}
        {available && installed && <TechnicalDetails status={status} />}
        {mutation.isError && <ErrorAlert error={mutation.error} />}
      </CardContent>
      <CardFooter className="flex flex-wrap items-center gap-2">
        {step !== null && step.kind !== "go_to_lead" && (
          <StepButton
            step={step}
            primary={primary}
            pending={mutation.isPending}
            titleId={titleId}
            onRun={run(step.kind)}
          />
        )}
        {step?.kind === "go_to_lead" && (
          <StepButton
            step={step}
            primary={primary}
            pending={false}
            titleId={titleId}
            onRun={() => {
              void navigate(paths.lead());
            }}
          />
        )}
        {step?.kind === "confirm" && status.sign_in.state !== "signed_in" && (
          <>
            <Button
              type="button"
              variant="outline"
              disabled
              aria-describedby={`${titleId} ${hintId}`}
            >
              Sign in using Terminal
            </Button>
            <span id={hintId} className="sr-only">
              Confirm your account first
            </span>
          </>
        )}
        {available && !subscriptionAllowed(status) && (
          <Button asChild variant="outline" size="sm">
            <Link to={paths.settings()} aria-describedby={titleId}>
              Open Settings
            </Link>
          </Button>
        )}
      </CardFooter>
    </Card>
  );
}
