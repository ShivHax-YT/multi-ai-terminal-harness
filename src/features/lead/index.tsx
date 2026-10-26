// Placeholder from T-101; T-103 owns this screen and replaces this file.
import { MessageSquare } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function LeadScreen() {
  return (
    <EmptyState
      icon={MessageSquare}
      title="Lead"
      description="Describe what you want built; the lead turns it into a plan for you to review. This screen arrives with T-103."
    />
  );
}
