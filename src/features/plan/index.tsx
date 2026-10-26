// Placeholder from T-101; T-104 owns this screen and replaces this file.
import { ClipboardList } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function PlansScreen() {
  return (
    <EmptyState
      icon={ClipboardList}
      title="Plans"
      description="Review each plan, edit it, and approve it before any worker starts. This screen arrives with T-104."
    />
  );
}
