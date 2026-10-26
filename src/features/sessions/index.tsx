// Placeholder from T-101; T-105 owns this screen and replaces this file.
import { SquareTerminal } from "lucide-react";

import { EmptyState } from "@/components/common";

export default function SessionsScreen() {
  return (
    <EmptyState
      icon={SquareTerminal}
      title="Sessions"
      description="Worker and sign-in sessions, their state, and the view-only terminal. This screen arrives with T-105."
    />
  );
}
