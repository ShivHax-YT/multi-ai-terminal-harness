// Placeholder from T-101; T-109 owns this screen and replaces this file.
import { Settings } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function SettingsScreen() {
  return (
    <EmptyState
      icon={Settings}
      title="Settings"
      description="Theme, stricter limits, API keys with spend caps, and kill-switch status. This screen arrives with T-109."
    />
  );
}
