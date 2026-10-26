// Placeholder from T-101; T-108 owns this screen and replaces this file.
import { Gauge } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function UsageScreen() {
  return (
    <EmptyState
      icon={Gauge}
      title="Usage"
      description="Usage against the compiled ceilings, pacing and spend. This screen arrives with T-108."
    />
  );
}
