// Placeholder from T-101; T-102 owns this screen and replaces this file.
import { PlugZap } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function ProvidersScreen() {
  return (
    <EmptyState
      icon={PlugZap}
      title="Providers"
      description="Install status, binary checks and sign-in for each command-line tool. This screen arrives with T-102."
    />
  );
}
