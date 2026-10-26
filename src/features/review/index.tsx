// Placeholder from T-101; T-107 owns this screen and replaces this file.
import { ScanSearch } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function ReviewScreen() {
  return (
    <EmptyState
      icon={ScanSearch}
      title="Review"
      description="Diffs, test logs, handoffs and the lead's summary for finished tasks. This screen arrives with T-107."
    />
  );
}
