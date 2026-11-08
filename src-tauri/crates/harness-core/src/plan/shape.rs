//! Schema-exact shape validation (`docs/spec/plan.schema.json`), run before any rule check and before any default could
//! apply: there are no defaults. A wrong type, a missing field or an unknown key is a violation, never a panic and
//! never silently `0` or `[]`. The messages and rule numbers are a port of the shape half of `spike/plan/check.jq`.

use crate::plan::check::{diagnostic_id, Violation, Violations};
use crate::plan::jcs::write_string;
use crate::plan::model::{
    Approval, AuthMode, EstimatedUsage, PlanModel, ProviderChoice, Task, Value,
};
use crate::provider::ProviderId;

const MAX_ESTIMATE: u64 = 1_000_000;
const PLAN_KEYS: [&str; 8] = [
    "format_version",
    "plan_id",
    "created_at",
    "lead",
    "request_summary",
    "summary_budget_tokens",
    "tasks",
    "approval",
];
const TASK_KEYS: [&str; 10] = [
    "id",
    "title",
    "role",
    "provider",
    "auth_mode",
    "owned_files",
    "acceptance",
    "depends_on",
    "estimated_usage",
    "fallback_providers",
];
const APPROVAL_KEYS: [&str; 4] = ["plan_hash", "approved_at", "approved_via", "nonce"];

/// Validate `root`. `Ok` means every field is present with the right type and no key is unknown.
pub(crate) fn validate(root: &Value) -> Result<PlanModel, Vec<Violation>> {
    let Some(entries) = root.as_object() else {
        return Err(vec![Violation::new(9, "plan must be a JSON object")]);
    };
    let mut out = Out::default();
    out.unknown_keys("plan", entries, &PLAN_KEYS);

    let format_version = match root.get("format_version") {
        Some(Value::Int(1)) => Some(1u32),
        _ => {
            out.rule9("format_version must be the integer 1");
            None
        }
    };
    let plan_id = match root.get("plan_id").and_then(Value::as_str) {
        Some(s) if !s.is_empty() => Some(s.to_owned()),
        _ => {
            out.rule9("plan_id must be a non-empty string");
            None
        }
    };
    let created_at = match root.get("created_at").and_then(Value::as_str) {
        Some(s) if is_rfc3339(s) => Some(s.to_owned()),
        _ => {
            out.rule9("created_at must be an RFC 3339 timestamp");
            None
        }
    };
    let request_summary = match root.get("request_summary").and_then(Value::as_str) {
        Some(s) => Some(s.to_owned()),
        None => {
            out.rule9("request_summary must be a string");
            None
        }
    };
    let summary_budget_tokens = match root.get("summary_budget_tokens").and_then(Value::as_int) {
        Some(n) if (1..=MAX_ESTIMATE).contains(&n) => u32::try_from(n).ok(),
        _ => {
            out.rule9(
                "summary_budget_tokens is required and must be an integer from 1 to 1000000 \
                 (defaults are never filled in)",
            );
            None
        }
    };
    let lead = lead(root.get("lead"), &mut out);
    let tasks = tasks(root.get("tasks"), &mut out);
    let approval = approval(root, &mut out);

    // Every `None` above pushed a violation, so a model is built only from a clean pass. If that invariant ever broke,
    // fail closed with a violation instead of an empty (passing) list.
    let model = (|| {
        Some(PlanModel {
            format_version: format_version?,
            plan_id: plan_id?,
            created_at: created_at?,
            lead: lead?,
            request_summary: request_summary?,
            summary_budget_tokens: summary_budget_tokens?,
            tasks: tasks?,
            approval: approval?,
        })
    })();
    match model {
        Some(model) if out.0.is_empty() => Ok(model),
        _ => {
            if out.0.is_empty() {
                out.rule9("plan shape could not be validated");
            }
            Err(out.0.into_vec())
        }
    }
}

#[derive(Default)]
struct Out(Violations);

impl Out {
    fn push(&mut self, rule: u8, message: String, task_id: Option<&str>) {
        let mut v = Violation::new(rule, message);
        if let Some(id) = task_id {
            v = v.with_task(id);
        }
        self.0.push(v);
    }

    fn rule9(&mut self, message: &str) {
        self.push(9, message.to_owned(), None);
    }

    fn unknown_keys(&mut self, place: &str, entries: &[(String, Value)], allowed: &[&str]) {
        let mut unknown: Vec<&str> = entries
            .iter()
            .map(|(k, _)| k.as_str())
            .filter(|k| !allowed.contains(k))
            .collect();
        unknown.sort_unstable();
        for key in unknown {
            let shown: String = key.chars().take(40).collect();
            let mut quoted = String::new();
            write_string(&shown, &mut quoted);
            self.rule9(&format!("{place} has unknown key {quoted}"));
        }
    }
}

fn provider_list() -> String {
    ProviderId::ALL
        .iter()
        .map(|p| p.as_str())
        .collect::<Vec<_>>()
        .join("|")
}

/// Exact names only: no case folding, no trimming.
fn provider_of(v: Option<&Value>) -> Option<ProviderId> {
    v.and_then(Value::as_str).and_then(|s| s.parse().ok())
}

fn auth_mode_of(v: Option<&Value>) -> Option<AuthMode> {
    v.and_then(Value::as_str).and_then(AuthMode::parse)
}

fn string_array(v: Option<&Value>) -> Option<Vec<String>> {
    v?.as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect()
}

fn lead(v: Option<&Value>, out: &mut Out) -> Option<ProviderChoice> {
    let Some(entries) = v.and_then(Value::as_object) else {
        out.push(
            7,
            "lead must be an object with provider and auth_mode".into(),
            None,
        );
        return None;
    };
    out.unknown_keys("lead", entries, &["provider", "auth_mode"]);
    let provider = provider_of(v.and_then(|l| l.get("provider")));
    if provider.is_none() {
        out.push(
            7,
            format!("lead.provider must be exactly one of {}", provider_list()),
            None,
        );
    }
    let auth_mode = auth_mode_of(v.and_then(|l| l.get("auth_mode")));
    if auth_mode.is_none() {
        out.push(
            7,
            "lead.auth_mode must be exactly subscription or api_key".into(),
            None,
        );
    }
    Some(ProviderChoice {
        provider: provider?,
        auth_mode: auth_mode?,
    })
}

fn fallback(
    i: usize,
    j: usize,
    v: &Value,
    id: Option<&str>,
    out: &mut Out,
) -> Option<ProviderChoice> {
    let place = format!("tasks[{i}].fallback_providers[{j}]");
    let Some(entries) = v.as_object() else {
        out.push(
            2,
            format!("{place} must be an object {{provider, auth_mode}}"),
            id,
        );
        return None;
    };
    out.unknown_keys(&place, entries, &["provider", "auth_mode"]);
    let provider = provider_of(v.get("provider"));
    if provider.is_none() {
        out.push(
            2,
            format!(
                "{place}.provider must be exactly one of {}",
                provider_list()
            ),
            id,
        );
    }
    let auth_mode = auth_mode_of(v.get("auth_mode"));
    if auth_mode.is_none() {
        out.push(
            7,
            format!("{place}.auth_mode must be exactly subscription or api_key"),
            id,
        );
    }
    Some(ProviderChoice {
        provider: provider?,
        auth_mode: auth_mode?,
    })
}

fn is_task_id(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn task(i: usize, v: &Value, out: &mut Out) -> Option<Task> {
    let Some(entries) = v.as_object() else {
        out.rule9(&format!("tasks[{i}] is not an object"));
        return None;
    };
    let raw_id = v.get("id").and_then(Value::as_str);
    let tid = raw_id;
    out.unknown_keys(&format!("tasks[{i}]"), entries, &TASK_KEYS);

    let id = match raw_id {
        Some(s) if is_task_id(s) => Some(s.to_owned()),
        _ => {
            out.push(
                9,
                format!("tasks[{i}].id must be a string matching [A-Za-z0-9_-]+"),
                tid,
            );
            None
        }
    };
    let nonempty = |key: &str, out: &mut Out| -> Option<String> {
        match v.get(key).and_then(Value::as_str) {
            Some(s) if !s.is_empty() => Some(s.to_owned()),
            _ => {
                out.push(
                    9,
                    format!("tasks[{i}].{key} must be a non-empty string"),
                    tid,
                );
                None
            }
        }
    };
    let title = nonempty("title", out);
    let role = nonempty("role", out);
    let provider = provider_of(v.get("provider"));
    if provider.is_none() {
        out.push(
            7,
            format!(
                "tasks[{i}] provider must be exactly one of {}",
                provider_list()
            ),
            tid,
        );
    }
    let auth_mode = auth_mode_of(v.get("auth_mode"));
    if auth_mode.is_none() {
        out.push(
            7,
            format!("tasks[{i}] auth_mode must be exactly subscription or api_key"),
            tid,
        );
    }
    let strings = |key: &str, out: &mut Out| -> Option<Vec<String>> {
        let r = string_array(v.get(key));
        if r.is_none() {
            out.push(
                9,
                format!("tasks[{i}].{key} must be an array of strings"),
                tid,
            );
        }
        r
    };
    let owned_files = strings("owned_files", out);
    let acceptance = strings("acceptance", out);
    let depends_on = strings("depends_on", out);

    let fallback_providers = match v.get("fallback_providers").and_then(Value::as_array) {
        None => {
            out.push(
                2,
                format!("tasks[{i}] fallback_providers must be an array"),
                tid,
            );
            None
        }
        Some(items) => {
            let parsed: Vec<ProviderChoice> = items
                .iter()
                .enumerate()
                .filter_map(|(j, item)| fallback(i, j, item, tid, out))
                .collect();
            (parsed.len() == items.len()).then_some(parsed)
        }
    };
    let estimated_usage = usage(i, v.get("estimated_usage"), tid, out);

    Some(Task {
        id: id?,
        title: title?,
        role: role?,
        provider: provider?,
        auth_mode: auth_mode?,
        owned_files: owned_files?,
        acceptance: acceptance?,
        depends_on: depends_on?,
        estimated_usage: estimated_usage?,
        fallback_providers: fallback_providers?,
    })
}

fn usage(i: usize, v: Option<&Value>, id: Option<&str>, out: &mut Out) -> Option<EstimatedUsage> {
    let Some(entries) = v.and_then(Value::as_object) else {
        out.push(
            1,
            format!("tasks[{i}] estimated_usage must be an object with prompts and turns"),
            id,
        );
        return None;
    };
    out.unknown_keys(
        &format!("tasks[{i}].estimated_usage"),
        entries,
        &["prompts", "turns"],
    );
    let count = |key: &str, out: &mut Out| -> Option<u32> {
        let n = v
            .and_then(|u| u.get(key))
            .and_then(Value::as_int)
            .filter(|n| *n <= MAX_ESTIMATE)
            .and_then(|n| u32::try_from(n).ok());
        if n.is_none() {
            out.push(
                1,
                format!("tasks[{i}] estimated_usage.{key} must be an integer from 0 to 1000000"),
                id,
            );
        }
        n
    };
    let turns = count("turns", out);
    let prompts = count("prompts", out);
    Some(EstimatedUsage {
        prompts: prompts?,
        turns: turns?,
    })
}

fn tasks(v: Option<&Value>, out: &mut Out) -> Option<Vec<Task>> {
    let items = match v.and_then(Value::as_array) {
        Some(items) if !items.is_empty() => items,
        _ => {
            out.rule9("tasks must be a non-empty array");
            return None;
        }
    };
    let parsed: Vec<Task> = items
        .iter()
        .enumerate()
        .filter_map(|(i, item)| task(i, item, out))
        .collect();

    // Ids of every task object that has a string id, even a malformed one.
    let mut ids: Vec<&str> = items
        .iter()
        .filter_map(|t| t.get("id").and_then(Value::as_str))
        .collect();
    ids.sort_unstable();
    let mut last_dup = None;
    for pair in ids.windows(2) {
        if pair[0] == pair[1] && last_dup != Some(pair[0]) {
            out.push(
                9,
                format!("duplicate task id {}", diagnostic_id(pair[0])),
                Some(pair[0]),
            );
            last_dup = Some(pair[0]);
        }
    }
    for (i, item) in items.iter().enumerate() {
        dependency_shape(i, item, &ids, out);
    }
    (parsed.len() == items.len()).then_some(parsed)
}

/// `depends_on` references: no duplicates, no self-dependency, no dangling ids. Cycles are a rule check.
fn dependency_shape(i: usize, item: &Value, ids: &[&str], out: &mut Out) {
    let Some(deps) = item.get("depends_on").and_then(Value::as_array) else {
        return;
    };
    if item.as_object().is_none() {
        return;
    }
    let own = item.get("id").and_then(Value::as_str);
    let deps: Vec<&str> = deps.iter().filter_map(Value::as_str).collect();
    let quote = |s: &str| {
        let mut q = String::new();
        write_string(diagnostic_id(s), &mut q);
        q
    };
    let mut sorted = deps.clone();
    sorted.sort_unstable();
    let mut last_dup = None;
    for pair in sorted.windows(2) {
        if pair[0] == pair[1] && last_dup != Some(pair[0]) {
            out.push(
                9,
                format!(
                    "tasks[{i}] depends_on lists {} more than once",
                    quote(pair[0])
                ),
                own,
            );
            last_dup = Some(pair[0]);
        }
    }
    for d in &deps {
        if Some(*d) == own {
            out.push(9, format!("tasks[{i}] depends on itself"), own);
        }
    }
    for d in &deps {
        if Some(*d) != own && ids.binary_search(d).is_err() {
            out.push(
                9,
                format!("tasks[{i}] depends_on references unknown task {}", quote(d)),
                own,
            );
        }
    }
}

/// `Some(None)` is a valid absent approval; `None` means a present but malformed one.
fn approval(root: &Value, out: &mut Out) -> Option<Option<Approval>> {
    let Some(v) = root.get("approval") else {
        return Some(None);
    };
    let Some(entries) = v.as_object() else {
        out.rule9("approval must be an object");
        return None;
    };
    out.unknown_keys("approval", entries, &APPROVAL_KEYS);
    let plan_hash = match v.get("plan_hash").and_then(Value::as_str) {
        Some(s) if s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) => {
            Some(s.to_owned())
        }
        _ => {
            out.rule9("approval.plan_hash must be 64 lowercase hex characters");
            None
        }
    };
    let approved_at = match v.get("approved_at").and_then(Value::as_str) {
        Some(s) if is_rfc3339(s) => Some(s.to_owned()),
        _ => {
            out.rule9("approval.approved_at must be an RFC 3339 timestamp");
            None
        }
    };
    let approved_via = match v.get("approved_via").and_then(Value::as_str) {
        Some(s) => Some(s.to_owned()),
        None => {
            out.rule9("approval.approved_via must be a string");
            None
        }
    };
    let nonce = match v.get("nonce").and_then(Value::as_str) {
        Some(s) if s.chars().count() >= 16 => Some(s.to_owned()),
        _ => {
            out.rule9("approval.nonce must be a string of at least 16 characters");
            None
        }
    };
    Some((|| {
        Some(Approval {
            plan_hash: plan_hash?,
            approved_at: approved_at?,
            approved_via: approved_via?,
            nonce: nonce?,
        })
    })())
}

fn digits(b: &[u8]) -> Option<u32> {
    if b.is_empty() || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    b.iter().try_fold(0u32, |acc, d| {
        acc.checked_mul(10)?.checked_add(u32::from(d - b'0'))
    })
}

fn days_in_month(year: u32, month: u32) -> u32 {
    let leap = (year.is_multiple_of(4) && !year.is_multiple_of(100)) || year.is_multiple_of(400);
    match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// RFC 3339 text with real ranges: month 01-12, day valid for the month (leap years), hour 00-23, minute 00-59, second
/// 00-60 (leap second), offset hours 00-23 and minutes 00-59. Upper-case `T` and `Z` only.
pub(crate) fn is_rfc3339(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
    {
        return false;
    }
    let (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(sec)) = (
        digits(&b[0..4]),
        digits(&b[5..7]),
        digits(&b[8..10]),
        digits(&b[11..13]),
        digits(&b[14..16]),
        digits(&b[17..19]),
    ) else {
        return false;
    };
    if !((1..=12).contains(&mo)
        && d >= 1
        && d <= days_in_month(y, mo)
        && h <= 23
        && mi <= 59
        && sec <= 60)
    {
        return false;
    }
    let mut pos = 19;
    if b[pos] == b'.' {
        let start = pos + 1;
        pos = start;
        while pos < b.len() && b[pos].is_ascii_digit() {
            pos += 1;
        }
        if pos == start {
            return false;
        }
    }
    match &b[pos..] {
        [b'Z'] => true,
        [b'+' | b'-', rest @ ..] if rest.len() == 5 && rest[2] == b':' => {
            matches!((digits(&rest[0..2]), digits(&rest[3..5])), (Some(oh), Some(om)) if oh <= 23 && om <= 59)
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::is_rfc3339;

    #[test]
    fn timestamps() {
        for ok in [
            "2026-10-25T09:00:00Z",
            "2026-10-25T09:00:00.123+05:30",
            "2024-02-29T23:59:60Z",
            "2000-02-29T00:00:00-23:59",
        ] {
            assert!(is_rfc3339(ok), "{ok}");
        }
        for bad in [
            "",
            "yesterday",
            "2026-10-25T09:00:00Z\n",
            "2026-10-25t09:00:00Z",
            "2026-10-25T09:00:00z",
            "2026-13-01T00:00:00Z",
            "2026-00-01T00:00:00Z",
            "2026-02-29T00:00:00Z",
            "1900-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-10-25T24:00:00Z",
            "2026-10-25T09:60:00Z",
            "2026-10-25T09:00:61Z",
            "2026-10-25T09:00:00",
            "2026-10-25T09:00:00.Z",
            "2026-10-25T09:00:00+24:00",
            "2026-10-25T09:00:00+05:60",
            "2026-10-25T09:00:00+0530",
            "+026-10-25T09:00:00Z",
        ] {
            assert!(!is_rfc3339(bad), "{bad:?}");
        }
    }
}
