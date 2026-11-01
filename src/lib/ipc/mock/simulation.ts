// Browser-only demonstration: no files, provider sessions or Git worktrees are created.
import { IpcRejection, type SimPlan, type SimSnapshot } from "../contract";

export class BrowserSimulation {
  private plans: SimPlan[] = [];
  private nextId = 0;
  private tokens = new Map<string, string>();

  snapshot(): SimSnapshot {
    return structuredClone({
      runtime: "browser",
      projects: [{ id: "sample", name: "Harness sample project" }],
      plans: this.plans,
    });
  }

  async submit(project: string, task: string): Promise<SimPlan> {
    if (
      project !== "sample" ||
      task.trim() === "" ||
      new TextEncoder().encode(task).length > 4000 ||
      this.nextId >= 50
    ) {
      throw new IpcRejection({
        kind: "invalid_input",
        message: "Select the sample project and enter a task of 1–4000 bytes (50 plans per demo).",
      });
    }
    const id = `sim-${String(++this.nextId)}`;
    const bytes = new TextEncoder().encode(
      JSON.stringify(["sample-workflow-v1", id, project, task, "simulated", "README.md"]),
    );
    const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
      .map((x) => x.toString(16).padStart(2, "0"))
      .join("");
    const plan: SimPlan = {
      id,
      project_id: project,
      task,
      hash,
      status: "pending",
      result: null,
      error: null,
    };
    this.plans.push(plan);
    return structuredClone(plan);
  }

  approve(id: string, hash: string): { token: string } {
    const plan = this.find(id);
    if (plan.hash !== hash || plan.status !== "pending") this.refuse();
    const token = crypto.randomUUID();
    this.tokens.set(id, token);
    plan.status = "approved";
    return { token };
  }

  run(id: string, hash: string, token: string): SimPlan {
    const plan = this.find(id);
    if (plan.hash !== hash || plan.status !== "approved" || this.tokens.get(id) !== token)
      this.refuse();
    this.tokens.delete(id);
    plan.status = "completed";
    plan.result = {
      isolation: "browser_memory",
      worktree: "No worktree: browser memory only",
      output:
        "Browser simulation complete. No files were changed and no AI provider was called. Native worktree execution is currently blocked by the safety guard.",
      diff: `Illustrative change — no filesystem write\n--- a/README.md\n+++ b/README.md\n@@ -1 +1,3 @@\n # Harness sample project\n+## Simulated worker output\n+${plan.task.replaceAll("\n", "\n+")}\n`,
      source_unchanged: true,
    };
    return structuredClone(plan);
  }

  private find(id: string): SimPlan {
    const plan = this.plans.find((p) => p.id === id);
    if (plan === undefined)
      throw new IpcRejection({ kind: "not_found", message: "Plan not found" });
    return plan;
  }

  private refuse(): never {
    throw new IpcRejection({
      kind: "rule_blocked",
      rule: 9,
      message: "A matching, unused UI approval is required",
    });
  }
}
