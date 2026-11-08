//! The plan rule checker: a port of `spike/plan/check.jq` (rule numbers and message wording are the spike's).
//!
//! Advisory for the UI (warn before approval). The scheduler re-runs it in [`Mode::Scheduler`] and also enforces the
//! same ceilings at dispatch regardless of what a plan says (T-125). Approval binding and signatures are T-117; this
//! module only reports whether an `approval` is present, well-shaped, bound to the computed hash and `ui`-sourced.

use crate::compliance::ceilings::{MAX_PROMPTS_PER_HOUR, MAX_TURNS_PER_TASK};
use crate::plan::model::{AuthMode, PlanModel};
use crate::plan::Plan;
use crate::provider::ProviderId;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fmt;

const MAX_REPORTED_VIOLATIONS: usize = 128;
const MAX_DIAGNOSTIC_BYTES: usize = 1024;
const MAX_DIAGNOSTIC_ID_BYTES: usize = 256;

/// One finding. Maps to `PlanViolation` in the IPC contract (`PlanView.violations`); all violations block approval in
/// Phase 1, so there is no severity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Violation {
    /// The hard rule number the finding falls under (1, 2, 7 or 9).
    pub rule: u8,
    /// Human-readable text without the `rule N:` prefix. It can echo plan text, so the UI treats it as untrusted.
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_id: Option<String>,
}

impl Violation {
    pub fn new(rule: u8, message: impl Into<String>) -> Self {
        let mut message = message.into();
        if message.len() > MAX_DIAGNOSTIC_BYTES {
            message.truncate(message.floor_char_boundary(MAX_DIAGNOSTIC_BYTES - '…'.len_utf8()));
            message.push('…');
        }
        Self {
            rule,
            message,
            task_id: None,
        }
    }

    pub(super) fn with_task(mut self, task_id: &str) -> Self {
        if task_id.len() <= MAX_DIAGNOSTIC_ID_BYTES {
            self.task_id = Some(task_id.to_owned());
        }
        self
    }

    fn for_task(rule: u8, message: String, task_id: &str) -> Self {
        Self::new(rule, message).with_task(task_id)
    }
}

/// Bound the text echoed into diagnostics without changing the plan or its hash.
pub(super) fn diagnostic_id(id: &str) -> &str {
    &id[..id.floor_char_boundary(MAX_DIAGNOSTIC_ID_BYTES)]
}

#[derive(Default)]
pub(super) struct Violations(Vec<Violation>);

impl Violations {
    pub(super) fn push(&mut self, violation: Violation) {
        if self.0.len() < MAX_REPORTED_VIOLATIONS {
            self.0.push(violation);
        } else if self.0.len() == MAX_REPORTED_VIOLATIONS {
            self.0
                .push(Violation::new(9, "additional plan violations omitted"));
        }
    }

    pub(super) fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub(super) fn into_vec(self) -> Vec<Violation> {
        self.0
    }
}

/// The spike's output line: `rule N: message`.
impl fmt::Display for Violation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "rule {}: {}", self.rule, self.message)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// The UI warning before the user approves: a plan with no approval is fine.
    Pre,
    /// The scheduler path: additionally rejects a plan with no approval.
    Scheduler,
}

/// Bounded violations in spike order (shape first; rule checks only for a well-shaped plan). Empty means the plan passes.
/// Callers decide on `is_empty()` of this result, never on a missing call.
pub fn check(plan: &Plan, mode: Mode) -> Vec<Violation> {
    let mut out = match plan.model() {
        Ok(model) => rule_violations(model, plan.hash()),
        Err(shape) => shape.clone(),
    };
    let is_object = plan.value().as_object().is_some();
    if mode == Mode::Scheduler && is_object && plan.value().get("approval").is_none() {
        out.push(Violation::new(9, "plan has no approval"));
    }
    out
}

fn is_gemini_without_api_key(provider: ProviderId, auth_mode: AuthMode) -> bool {
    provider == ProviderId::Gemini && auth_mode != AuthMode::ApiKey
}

fn rule_violations(plan: &PlanModel, computed_hash: &str) -> Vec<Violation> {
    let mut out = Violations::default();
    let used: HashSet<ProviderId> = plan.tasks.iter().map(|t| t.provider).collect();

    // Rule 7: Gemini on API key only, for the lead too.
    if is_gemini_without_api_key(plan.lead.provider, plan.lead.auth_mode) {
        out.push(Violation::new(
            7,
            format!(
                "lead uses gemini with auth_mode {}; gemini is api_key only",
                plan.lead.auth_mode.as_str()
            ),
        ));
    }

    // Rule 2: a fallback is never the task's own provider, and never repeats.
    for t in &plan.tasks {
        if t.fallback_providers
            .iter()
            .any(|f| f.provider == t.provider)
        {
            out.push(Violation::for_task(
                2,
                format!(
                    "task {} lists its own provider {} as a fallback",
                    diagnostic_id(&t.id),
                    t.provider
                ),
                &t.id,
            ));
        }
        let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
        for f in &t.fallback_providers {
            *counts.entry(f.provider.as_str()).or_default() += 1;
        }
        for (name, n) in counts {
            if n > 1 {
                out.push(Violation::for_task(
                    2,
                    format!(
                        "task {} repeats fallback provider {name}",
                        diagnostic_id(&t.id)
                    ),
                    &t.id,
                ));
            }
        }
    }

    // Rule 9: failover only to providers listed in the plan, so a fallback must be used by some task. Which limits it
    // may use is enforced by the live per-provider counters at dispatch, not here.
    for t in &plan.tasks {
        for f in &t.fallback_providers {
            if !used.contains(&f.provider) {
                out.push(Violation::for_task(
                    9,
                    format!(
                        "task {} fallback provider {} is not used by any task in the plan",
                        diagnostic_id(&t.id),
                        f.provider
                    ),
                    &t.id,
                ));
            }
        }
    }

    // Rule 7: Gemini on API key only, for tasks and for each fallback.
    for t in &plan.tasks {
        if is_gemini_without_api_key(t.provider, t.auth_mode) {
            out.push(Violation::for_task(
                7,
                format!(
                    "task {} uses gemini with auth_mode {}; gemini is api_key only",
                    diagnostic_id(&t.id),
                    t.auth_mode.as_str()
                ),
                &t.id,
            ));
        }
    }
    for t in &plan.tasks {
        for f in &t.fallback_providers {
            if is_gemini_without_api_key(f.provider, f.auth_mode) {
                out.push(Violation::for_task(
                    7,
                    format!(
                        "task {} has a gemini fallback with auth_mode {}; gemini is api_key only",
                        diagnostic_id(&t.id),
                        f.auth_mode.as_str()
                    ),
                    &t.id,
                ));
            }
        }
    }

    // Rule 1: per-task turn ceiling.
    for t in &plan.tasks {
        if t.estimated_usage.turns > MAX_TURNS_PER_TASK {
            out.push(Violation::for_task(
                1,
                format!(
                    "task {} estimates {} turns, ceiling is {MAX_TURNS_PER_TASK}",
                    diagnostic_id(&t.id),
                    t.estimated_usage.turns
                ),
                &t.id,
            ));
        }
    }

    // Rule 1: summed prompts per provider for everything that is not api_key. Only an exact `api_key` is exempt, so
    // anything else counts as a subscription. Failover usage is enforced by live counters at dispatch, not here.
    let mut prompts: BTreeMap<&str, u64> = BTreeMap::new();
    for t in plan
        .tasks
        .iter()
        .filter(|t| t.auth_mode != AuthMode::ApiKey)
    {
        *prompts.entry(t.provider.as_str()).or_default() += u64::from(t.estimated_usage.prompts);
    }
    for (name, total) in prompts {
        if total > u64::from(MAX_PROMPTS_PER_HOUR) {
            out.push(Violation::new(
                1,
                format!(
                    "subscription provider {name} plan estimates {total} prompts, ceiling is {MAX_PROMPTS_PER_HOUR}"
                ),
            ));
        }
    }

    // Rule 9: the scheduler needs a DAG.
    let stuck = stuck_tasks(plan);
    if !stuck.is_empty() {
        out.push(Violation::new(
            9,
            format!(
                "tasks blocked by a dependency cycle: {}",
                stuck
                    .into_iter()
                    .map(diagnostic_id)
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        ));
    }

    // Rule 9: an approval must be a UI approval bound to the hash of exactly this plan.
    if let Some(approval) = &plan.approval {
        if approval.plan_hash != computed_hash {
            out.push(Violation::new(
                9,
                format!(
                    "approval plan_hash {} does not match computed plan hash {computed_hash}; plan was edited after approval",
                    approval.plan_hash
                ),
            ));
        }
        if approval.approved_via != "ui" {
            out.push(Violation::new(9, "approval approved_via must be \"ui\""));
        }
    }
    out.into_vec()
}

/// Tasks whose `depends_on` can never be satisfied: part of, or downstream of, a cycle (Kahn's algorithm).
fn stuck_tasks(plan: &PlanModel) -> Vec<&str> {
    let indices: HashMap<&str, usize> = plan
        .tasks
        .iter()
        .enumerate()
        .map(|(i, task)| (task.id.as_str(), i))
        .collect();
    let mut dependents = vec![Vec::new(); plan.tasks.len()];
    let mut pending = Vec::with_capacity(plan.tasks.len());
    let mut ready = VecDeque::new();
    for (i, task) in plan.tasks.iter().enumerate() {
        pending.push(task.depends_on.len());
        if task.depends_on.is_empty() {
            ready.push_back(i);
        }
        for dependency in &task.depends_on {
            dependents[indices[dependency.as_str()]].push(i);
        }
    }
    while let Some(i) = ready.pop_front() {
        for &dependent in &dependents[i] {
            pending[dependent] -= 1;
            if pending[dependent] == 0 {
                ready.push_back(dependent);
            }
        }
    }
    plan.tasks
        .iter()
        .zip(pending)
        .filter(|(_, count)| *count != 0)
        .map(|(task, _)| task.id.as_str())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn base() -> Value {
        let task = |id: &str, provider: &str, auth: &str, deps: Value, fb: Value| {
            json!({
                "id": id, "title": "t", "role": "r", "provider": provider, "auth_mode": auth,
                "owned_files": [], "acceptance": [], "depends_on": deps,
                "estimated_usage": {"prompts": 5, "turns": 10}, "fallback_providers": fb
            })
        };
        json!({
            "format_version": 1, "plan_id": "p", "created_at": "2026-10-25T09:00:00Z",
            "lead": {"provider": "claude", "auth_mode": "subscription"},
            "request_summary": "s", "summary_budget_tokens": 200,
            "tasks": [
                task("a", "claude", "subscription", json!([]),
                     json!([{"provider": "codex", "auth_mode": "subscription"}])),
                task("b", "codex", "subscription", json!(["a"]), json!([])),
            ]
        })
    }

    fn lines(v: &Value, mode: Mode) -> Vec<String> {
        let plan = Plan::from_bytes(&serde_json::to_vec(v).unwrap()).unwrap();
        check(&plan, mode)
            .iter()
            .map(Violation::to_string)
            .collect()
    }

    fn has(out: &[String], prefix: &str, part: &str) -> bool {
        out.iter()
            .any(|l| l.starts_with(prefix) && l.contains(part))
    }

    #[test]
    fn well_formed_plan_passes() {
        assert!(lines(&base(), Mode::Pre).is_empty());
    }

    #[test]
    fn rule_checks_fire() {
        let mut v = base();
        v["tasks"][0]["fallback_providers"] =
            json!([{"provider": "claude", "auth_mode": "subscription"}]);
        assert!(has(
            &lines(&v, Mode::Pre),
            "rule 2:",
            "lists its own provider"
        ));

        let mut v = base();
        v["tasks"][0]["fallback_providers"] = json!([
            {"provider": "codex", "auth_mode": "subscription"},
            {"provider": "codex", "auth_mode": "api_key"}
        ]);
        assert!(has(
            &lines(&v, Mode::Pre),
            "rule 2:",
            "repeats fallback provider codex"
        ));

        let mut v = base();
        v["tasks"][0]["fallback_providers"] =
            json!([{"provider": "grok", "auth_mode": "subscription"}]);
        assert!(has(
            &lines(&v, Mode::Pre),
            "rule 9:",
            "not used by any task"
        ));

        let mut v = base();
        v["lead"] = json!({"provider": "gemini", "auth_mode": "subscription"});
        assert!(has(
            &lines(&v, Mode::Pre),
            "rule 7:",
            "gemini is api_key only"
        ));

        let mut v = base();
        v["tasks"][0]["estimated_usage"]["turns"] = json!(41);
        assert!(has(
            &lines(&v, Mode::Pre),
            "rule 1:",
            "estimates 41 turns, ceiling is 40"
        ));

        let mut v = base();
        v["tasks"][0]["estimated_usage"]["prompts"] = json!(31);
        assert!(has(&lines(&v, Mode::Pre), "rule 1:", "ceiling is 30"));
        // The same prompts on an api_key task are not counted.
        v["tasks"][0]["auth_mode"] = json!("api_key");
        assert!(lines(&v, Mode::Pre).is_empty());

        let mut v = base();
        v["tasks"][0]["depends_on"] = json!(["b"]);
        assert!(lines(&v, Mode::Pre)
            .contains(&"rule 9: tasks blocked by a dependency cycle: a, b".to_owned()));
    }

    #[test]
    fn shape_errors_come_first_and_stop_rule_checks() {
        let mut v = base();
        v["tasks"][0]["estimated_usage"]["turns"] = json!(41);
        v["tasks"][1]["provider"] = json!("Codex");
        v["extra"] = json!(1);
        let out = lines(&v, Mode::Pre);
        assert!(has(&out, "rule 9:", "plan has unknown key \"extra\""));
        assert!(has(
            &out,
            "rule 7:",
            "tasks[1] provider must be exactly one of"
        ));
        assert!(!has(&out, "rule 1:", "ceiling is 40"));
    }

    #[test]
    fn scheduler_mode_requires_an_approval() {
        assert_eq!(
            lines(&base(), Mode::Scheduler),
            ["rule 9: plan has no approval"]
        );
        let plan = Plan::from_bytes(&serde_json::to_vec(&base()).unwrap()).unwrap();
        let mut v = base();
        v["approval"] = json!({
            "plan_hash": plan.hash(), "approved_at": "2026-10-25T10:00:00Z",
            "approved_via": "ui", "nonce": "0123456789abcdef"
        });
        assert!(lines(&v, Mode::Scheduler).is_empty());
        v["approval"]["approved_via"] = json!("cli");
        assert!(has(
            &lines(&v, Mode::Scheduler),
            "rule 9:",
            "approved_via must be"
        ));
        v["approval"] = Value::Null;
        let out = lines(&v, Mode::Scheduler);
        assert!(out.contains(&"rule 9: approval must be an object".to_owned()));
        assert!(!out.contains(&"rule 9: plan has no approval".to_owned()));
    }
}
