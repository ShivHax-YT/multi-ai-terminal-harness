// Placeholder from T-101; T-109 owns this screen and replaces this file.
import { Settings } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function SettingsScreen() {
  return (
    <EmptyState
      icon={Settings}
      title="Settings"
      description="Saved limits, API keys and provider policy settings are not available in this build. You can change the theme from the menu above."
    />
  );
}
