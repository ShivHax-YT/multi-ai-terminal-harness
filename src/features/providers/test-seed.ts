// Test helper: changes the mock backend's own provider state, so its refusals and results stay the real ones.
// Structural types only: the mock itself is imported by tests, never by this file.
import type { ProviderStatus } from "@/lib/ipc";
import type { ProviderId } from "@/strings/providers";

interface SeedableMock {
  control: { backend: unknown };
}

interface SeedableBackend {
  providers: Map<ProviderId, ProviderStatus>;
}

export function seedProvider(
  mock: SeedableMock,
  id: ProviderId,
  patch: Partial<ProviderStatus>,
): void {
  const status = (mock.control.backend as SeedableBackend).providers.get(id);
  if (status === undefined) throw new Error("provider missing");
  Object.assign(status, patch);
}
