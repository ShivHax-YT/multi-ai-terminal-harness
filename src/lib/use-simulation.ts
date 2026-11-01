import { useQuery } from "@tanstack/react-query";
import { useIpc } from "@/lib/ipc";

export const SIMULATION_KEY = ["sample-workflow"] as const;
export function useSimulation() {
  const ipc = useIpc();
  return useQuery({ queryKey: SIMULATION_KEY, queryFn: () => ipc.sim_snapshot() });
}
