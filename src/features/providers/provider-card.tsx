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

import { blockerSentence, nextStep, subscriptionAllowed, type NextStep } from "./next-step";
import { useProviderStep, type IpcStepKind } from "./use-providers";

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <dt className="text-sm text-muted-foreground">{label}</dt>
      <dd className="flex min-w-0 flex-col items-end gap-1 text-right">{children}</dd>
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
  return { tone: "neutral", label: "Not usable yet" };
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
      {installed && install.path !== undefined && (
        <UntrustedText text={install.path} mono className="text-muted-foreground" />
      )}
    </Row>
  );
}

function BinaryRow({ status }: { status: ProviderStatus }) {
  const { binary } = status;
  const chip: { tone: StatusTone; label: string } =
    binary.state === "verified"
      ? { tone: "success", label: "Verified" }
      : binary.state === "failed"
        ? { tone: "danger", label: "Failed verification" }
        : { tone: "warning", label: "Not verified yet" };
  return (
    <>
      <Row label="Binary">
        <StatusChip {...chip} />
      </Row>
      {binary.state === "failed" && binary.checks.length > 0 && (
        <ul aria-label="Verification checks" className="flex flex-col gap-1.5">
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
    </>
  );
}

function SignInRows({ status }: { status: ProviderStatus }) {
  if (!status.auth_modes.includes("subscription")) {
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
      </Row>
      <Row label="Personal use">
        {status.personal_use_confirmed ? (
          <StatusChip tone="success" label="Confirmed as your account" />
        ) : (
          <StatusChip tone="warning" label="Not confirmed yet" />
        )}
      </Row>
    </>
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
  onRun,
}: {
  step: NextStep;
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
      onClick={onRun}
    >
      {step.label}
    </Button>
  );
}

export function ProviderCard({ status, primary }: { status: ProviderStatus; primary: boolean }) {
  const titleId = useId();
  const navigate = useNavigate();
  const step = nextStep(status);
  const mutation = useProviderStep(status);
  const available = status.adapter_available && status.killswitch !== "disabled";
  const installed = status.install.state === "installed";
  const usable = usableLabel(status);
  const run = (kind: IpcStepKind) => () => {
    mutation.mutate(kind);
  };
  const showKeyRow = !subscriptionAllowed(status) && status.api_key !== null;

  return (
    <Card
      role="group"
      aria-labelledby={titleId}
      data-provider={status.provider}
      className="h-full gap-4"
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
      <CardContent className="flex flex-1 flex-col gap-3">
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
        {status.usable.blockers.length > 0 && (
          <ul aria-label="What blocks it" className="flex flex-col gap-1 text-sm">
            {status.usable.blockers.map((blocker) => (
              <li key={blocker} className="text-muted-foreground">
                {blockerSentence(blocker)}
              </li>
            ))}
          </ul>
        )}
        {mutation.isError && <ErrorAlert error={mutation.error} />}
      </CardContent>
      <CardFooter className="flex flex-wrap items-center gap-2">
        {step !== null && step.kind !== "go_to_lead" && (
          <StepButton
            step={step}
            primary={primary}
            pending={mutation.isPending}
            onRun={run(step.kind)}
          />
        )}
        {step?.kind === "go_to_lead" && (
          <StepButton
            step={step}
            primary={primary}
            pending={false}
            onRun={() => {
              void navigate(paths.lead());
            }}
          />
        )}
        {step?.kind === "confirm" && status.sign_in.state !== "signed_in" && (
          <Button type="button" variant="outline" disabled>
            Sign in in terminal
          </Button>
        )}
        {available && !subscriptionAllowed(status) && (
          <Button asChild variant="outline" size="sm">
            <Link to={paths.settings()}>Open Settings</Link>
          </Button>
        )}
      </CardFooter>
    </Card>
  );
}
