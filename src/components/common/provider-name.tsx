// A provider's plain-text name (rule 8): no icon, logo or brand color, from src/strings/providers.ts only.
import { providerLabel, type ProviderId } from "@/strings/providers";

export function ProviderName({ id, className }: { id: ProviderId; className?: string }) {
  return (
    <span className={className} data-provider={id}>
      {providerLabel(id)}
    </span>
  );
}
