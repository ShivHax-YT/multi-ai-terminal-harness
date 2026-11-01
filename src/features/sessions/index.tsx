// Placeholder from T-101; T-105 owns this screen and replaces this file.
import { SquareTerminal } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function SessionsScreen() {
  return (
    <EmptyState
      icon={SquareTerminal}
      title="Sessions"
      description="Worker sessions and terminal viewing are not available in this build. CLI sign-in happens in your own Terminal."
    />
  );
}
