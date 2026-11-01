/** One attach is in flight. An older generation, or a snapshot behind bytes already shown, is not applied. */
export function createAttachGeneration() {
  let latest = 0;
  let inFlight = false;
  return {
    /** False when an attach is already running. The caller should ask again when it finishes. */
    begin(): number | null {
      if (inFlight) return null;
      inFlight = true;
      latest += 1;
      return latest;
    },
    finish() {
      inFlight = false;
    },
    /**
     * The ticket must be the newest attach, and its seq must not rewind past output already on screen.
     * `shown` is the newest seq written so far, or null before the first snapshot.
     */
    shouldApply(ticket: number, seq: number, shown: number | null): boolean {
      if (ticket !== latest) return false;
      if (shown !== null && seq < shown) return false;
      return true;
    },
  };
}
