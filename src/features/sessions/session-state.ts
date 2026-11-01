import type { SessionState, SessionView } from "@/lib/ipc";

export function isLiveSession(state: SessionState): boolean {
  return (
    state.kind === "spawning" ||
    state.kind === "running" ||
    state.kind === "idle" ||
    state.kind === "stopping"
  );
}

/** A later snapshot wins. An older revision cannot revive a session the backend has already moved on from. */
export function applySessionSnapshot(list: SessionView[], next: SessionView): SessionView[] {
  const current = list.find((session) => session.session_id === next.session_id);
  if (current !== undefined && revisionOf(current) > revisionOf(next)) return list;
  if (current === undefined) return [...list, next];
  return list.map((session) => (session.session_id === next.session_id ? next : session));
}

function revisionOf(session: SessionView): number {
  return session.revision ?? 0;
}
