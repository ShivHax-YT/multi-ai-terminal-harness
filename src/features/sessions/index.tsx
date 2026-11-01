// T-105: the Sessions screen. The list route opens a CLI in a folder the human chose and lists sessions; the detail
// route shows one terminal. Every session here starts from a human click. No prompt or task text ever reaches a CLI
// from this screen, and worker automation stays unavailable (see the Providers screen).
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, FolderOpen, SquareTerminal } from "lucide-react";
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router";

import { paths } from "@/app/paths";
import {
  EmptyState,
  ErrorAlert,
  LoadingSkeleton,
  ProviderName,
  StatusChip,
  UntrustedText,
  type StatusTone,
} from "@/components/common";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useIpc, useIpcEvent, type SessionState, type SessionView } from "@/lib/ipc";
import { MVP_PROVIDER_IDS, providerLabel, type ProviderId } from "@/strings/providers";

import { SessionTerminal } from "./terminal";

const SESSIONS_KEY = ["sessions"] as const;
const PROVIDERS_KEY = ["providers"] as const;
const FOLDER_STORAGE_KEY = "harness.terminal.folder";

function isLive(state: SessionState): boolean {
  return state.kind === "spawning" || state.kind === "running" || state.kind === "idle";
}

function stateChip(state: SessionState): { tone: StatusTone; label: string } {
  switch (state.kind) {
    case "spawning":
      return { tone: "neutral", label: "Starting" };
    case "running":
      return { tone: "success", label: "Running" };
    case "idle":
      return { tone: "neutral", label: "Idle" };
    case "rate_limited":
      return { tone: "warning", label: "Rate limited" };
    case "exited":
      return state.code === undefined || state.code === 0
        ? { tone: "neutral", label: "Exited" }
        : { tone: "danger", label: `Exited with code ${String(state.code)}` };
    case "killed":
      return { tone: "danger", label: "Stopped" };
  }
}

function useSessions() {
  const client = useIpc();
  const queryClient = useQueryClient();
  // Events are full snapshots: replace the row, never merge.
  useIpcEvent("session_changed", (session) => {
    queryClient.setQueryData<SessionView[]>(SESSIONS_KEY, (old) => {
      if (old === undefined) return old;
      const known = old.some((s) => s.session_id === session.session_id);
      return known
        ? old.map((s) => (s.session_id === session.session_id ? session : s))
        : [...old, session];
    });
  });
  return useQuery({
    queryKey: SESSIONS_KEY,
    refetchOnMount: "always",
    queryFn: () => client.list_sessions(),
  });
}

function rememberedFolder(): string {
  try {
    return localStorage.getItem(FOLDER_STORAGE_KEY) ?? "";
  } catch {
    return "";
  }
}

function rememberFolder(folder: string): void {
  try {
    localStorage.setItem(FOLDER_STORAGE_KEY, folder);
  } catch {
    // A convenience only: the field just starts empty next time.
  }
}

function OpenTerminal() {
  const client = useIpc();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [folder, setFolder] = useState(rememberedFolder);
  const [confirming, setConfirming] = useState<ProviderId | null>(null);
  const providers = useQuery({
    queryKey: PROVIDERS_KEY,
    queryFn: () => client.list_providers(),
  });
  const choose = useMutation({
    mutationFn: () => client.choose_terminal_folder(),
    onSuccess: (chosen) => {
      if (chosen !== null) setFolder(chosen);
    },
  });
  const start = useMutation({
    mutationFn: (args: { provider: ProviderId; confirm: boolean }) =>
      client.start_terminal({
        provider: args.provider,
        folder: folder.trim(),
        confirm_personal_use: args.confirm,
      }),
    onSuccess: (session) => {
      rememberFolder(folder.trim());
      void queryClient.invalidateQueries({ queryKey: PROVIDERS_KEY });
      void navigate(paths.session(session.session_id));
    },
  });

  const open = (provider: ProviderId) => {
    const status = providers.data?.find((p) => p.provider === provider);
    if (status?.personal_use_confirmed === true) start.mutate({ provider, confirm: false });
    else setConfirming(provider);
  };
  const noFolder = folder.trim() === "";

  return (
    <section aria-label="Open a terminal" className="flex flex-col gap-4 rounded-xl border p-4">
      <div className="flex flex-col gap-2">
        <Label htmlFor="terminal-folder">Project folder</Label>
        <div className="flex gap-2">
          <Input
            id="terminal-folder"
            className="min-w-0 flex-1 font-mono"
            value={folder}
            placeholder="/path/to/your/project"
            spellCheck={false}
            onChange={(event) => {
              setFolder(event.target.value);
            }}
          />
          <Button
            type="button"
            variant="outline"
            disabled={choose.isPending}
            onClick={() => {
              choose.mutate();
            }}
          >
            <FolderOpen aria-hidden />
            Choose
          </Button>
        </div>
      </div>
      <div className="flex flex-wrap gap-2">
        {MVP_PROVIDER_IDS.map((provider, index) => (
          <Button
            key={provider}
            type="button"
            className="min-h-11"
            variant={index === 0 ? "default" : "outline"}
            disabled={noFolder || start.isPending}
            onClick={() => {
              open(provider);
            }}
          >
            <SquareTerminal aria-hidden />
            Open {providerLabel(provider)}
          </Button>
        ))}
      </div>
      <p className="max-w-[65ch] text-sm text-muted-foreground">
        The CLI runs in this folder under your own account, the same as in your own terminal. It can
        change files there. Up to 2 terminals per tool.
      </p>
      {start.isError && <ErrorAlert error={start.error} />}
      {choose.isError && <ErrorAlert error={choose.error} />}
      <AlertDialog
        open={confirming !== null}
        onOpenChange={(next) => {
          if (!next) setConfirming(null);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Is this your own account?</AlertDialogTitle>
            <AlertDialogDescription>
              {confirming !== null && providerLabel(confirming)} will run with the account signed in
              on this Mac. Subscriptions are personal, so use only your own, on this machine.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                if (confirming !== null) start.mutate({ provider: confirming, confirm: true });
              }}
            >
              It is my own account
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}

function SessionRow({ session }: { session: SessionView }) {
  const chip = stateChip(session.state);
  return (
    <li>
      <Link
        to={paths.session(session.session_id)}
        className="flex flex-wrap items-center justify-between gap-2 rounded-xl border bg-card p-4 transition-transform duration-150 motion-safe:hover:-translate-y-0.5"
      >
        <span className="flex min-w-0 flex-col gap-1">
          <ProviderName id={session.provider} className="font-medium" />
          {session.worktree !== undefined && (
            <UntrustedText
              mono
              text={session.worktree}
              className="break-all text-muted-foreground"
            />
          )}
        </span>
        <StatusChip tone={chip.tone} label={chip.label} />
      </Link>
    </li>
  );
}

function SessionList() {
  const sessions = useSessions();
  const list = sessions.data ?? [];
  return (
    <div className="flex flex-col gap-6">
      <OpenTerminal />
      {sessions.isPending && <LoadingSkeleton rows={2} label="Loading sessions" />}
      {sessions.isError && <ErrorAlert error={sessions.error} />}
      {sessions.isSuccess && list.length === 0 && (
        <EmptyState
          icon={SquareTerminal}
          title="No terminals open"
          description="Choose a folder and open a CLI. Automated task workers are not available in this build."
          className="py-8"
        />
      )}
      {list.length > 0 && (
        <ul aria-label="Sessions" className="flex flex-col gap-2">
          {[...list].reverse().map((session) => (
            <SessionRow key={session.session_id} session={session} />
          ))}
        </ul>
      )}
    </div>
  );
}

function SessionDetail({ sessionId }: { sessionId: string }) {
  const client = useIpc();
  const queryClient = useQueryClient();
  const sessions = useSessions();
  const [stopping, setStopping] = useState(false);
  const put = (next: SessionView) => {
    queryClient.setQueryData<SessionView[]>(SESSIONS_KEY, (old) =>
      old?.map((s) => (s.session_id === next.session_id ? next : s)),
    );
  };
  const stop = useMutation({
    mutationFn: () => client.kill_session({ session_id: sessionId }),
    onSuccess: put,
  });
  const takeover = useMutation({
    mutationFn: (enabled: boolean) => client.set_takeover({ session_id: sessionId, enabled }),
    onSuccess: put,
  });

  if (sessions.isPending) return <LoadingSkeleton rows={3} label="Connecting to the session" />;
  if (sessions.isError) return <ErrorAlert error={sessions.error} />;
  const session = sessions.data.find((s) => s.session_id === sessionId);
  if (session === undefined) {
    return (
      <EmptyState
        icon={SquareTerminal}
        title="Session not found"
        description="Terminals end when the app quits."
      />
    );
  }
  const live = isLive(session.state);
  const chip = stateChip(session.state);
  const others = sessions.data.filter((s) => s.session_id !== sessionId && isLive(s.state));

  return (
    // Fills the shell's main area below its header, banner and 24 px padding.
    <div className="flex h-[calc(100vh-9.5rem)] min-h-96 w-full min-w-0 flex-col gap-3">
      <header className="flex min-w-0 items-center gap-3">
        <Button variant="ghost" size="sm" className="shrink-0" asChild>
          <Link to={paths.sessions()}>
            <ArrowLeft aria-hidden />
            Sessions
          </Link>
        </Button>
        <ProviderName id={session.provider} className="shrink-0 font-medium" />
        <StatusChip tone={chip.tone} label={chip.label} />
        {session.worktree !== undefined && (
          <UntrustedText
            mono
            text={session.worktree}
            className="min-w-0 flex-1 truncate whitespace-nowrap text-muted-foreground"
          />
        )}
        <span className="ml-auto flex shrink-0 items-center gap-2">
          {others.map((other) => (
            <Button key={other.session_id} variant="outline" size="sm" asChild>
              <Link to={paths.session(other.session_id)}>{providerLabel(other.provider)}</Link>
            </Button>
          ))}
          {live && !session.takeover && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => {
                takeover.mutate(true);
              }}
            >
              Take over
            </Button>
          )}
          {live && session.takeover && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => {
                takeover.mutate(false);
              }}
            >
              Lock keyboard
            </Button>
          )}
          {live && (
            <Button
              variant="outline"
              size="sm"
              onClick={() => {
                setStopping(true);
              }}
            >
              Stop
            </Button>
          )}
        </span>
      </header>
      {live && !session.takeover && (
        <p role="status" className="text-sm text-muted-foreground">
          Read only. Keystrokes do not reach this session.
        </p>
      )}
      {!live && (
        <p role="status" className="text-sm text-muted-foreground">
          Session ended.
        </p>
      )}
      {stop.isError && <ErrorAlert error={stop.error} />}
      {takeover.isError && <ErrorAlert error={takeover.error} />}
      <SessionTerminal
        key={session.session_id}
        sessionId={session.session_id}
        kind={session.kind}
        takeover={live && session.takeover}
      />
      <AlertDialog open={stopping} onOpenChange={setStopping}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Stop this session?</AlertDialogTitle>
            <AlertDialogDescription>
              The CLI process ends. Files in the folder stay.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep running</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                stop.mutate();
              }}
            >
              Stop
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

export default function SessionsScreen() {
  const { sessionId } = useParams();
  return sessionId === undefined ? <SessionList /> : <SessionDetail sessionId={sessionId} />;
}
