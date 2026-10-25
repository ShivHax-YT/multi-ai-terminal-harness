# Plan format and approval binding

Spec for the plan the lead produces and the user approves (docs/ARCHITECTURE.md, "How the lead works", steps 1 and 2).
Machine-readable shape: `plan.schema.json`. Examples: `examples/`. Offline checker: `spike/plan/` (T-005).

## Fields

| Field | Type | Notes |
|---|---|---|
| `plan_id` | string | Unique per plan. |
| `created_at` | RFC 3339 string | |
| `lead` | `{provider}` | Provider whose headless session produced the plan. |
| `request_summary` | string | The user's request, summarized. Untrusted text when displayed. |
| `summary_budget_tokens` | integer, default 200 | Token budget for the lead's final summary. |
| `tasks[]` | array | See below. |
| `approval` | object, optional | Absent until the user approves. Excluded from the hash. |

Task fields: `id`, `title`, `role`, `provider`, `auth_mode` (`subscription` or `api_key`), `owned_files[]`,
`acceptance[]`, `depends_on[]` (task ids), `estimated_usage {prompts, turns}`, `fallback_providers[]`.

Providers: `claude`, `codex`, `grok`, `kimi`, `gemini`, `glm`.

## Plan hash

```
hash = sha256( canonical_json( plan without "approval" ) ), lowercase hex
spike: jq -S -c 'del(.approval)' plan.json | shasum -a 256
```

Everything except `approval` is covered: provider, scope (`owned_files`, `acceptance`), usage estimates, fallbacks and
dependencies. Changing any of them changes the hash and so voids the approval (rule 9: "any change of provider, scope or
estimated usage beyond the approved plan needs new approval").

### JCS in the app, `jq -S -c` in the spike

The app will use RFC 8785 (JSON Canonicalization Scheme) so any implementation (Rust, Swift, TypeScript) yields the
same bytes. The spike's `jq -S -c` is close enough because a plan contains only: ASCII object keys we define, strings,
non-negative integers and arrays. For that subset both forms sort keys, drop insignificant whitespace, print integers
the same way and escape strings the same way, with one known gap: `jq` escapes U+007F as `\u007f` where JCS emits the
raw character. The schema forbids floats (`integer` only) and unknown keys, which removes the other JCS pitfalls
(number formatting, UTF-16 key ordering of non-ASCII keys). The app must not use `jq` output as its canonical form and
needs its own JCS test vectors.

**Duplicate keys.** The app's canonicalizer and plan parser must reject any JSON object with duplicate keys, before
hashing and before validation. Parsers disagree on duplicates (the spike's `jq` keeps the last value; others keep the
first or error), so a plan with `"provider"` twice could be hashed and checked by one parser and executed by another
(parser-differential attack). The spike does not detect duplicates and must not be taken as evidence they are safe.

## Approval token

```json
{ "plan_hash": "<64 hex>", "approved_at": "<RFC 3339>", "approved_via": "ui", "nonce": "<random>" }
```

- Created only by a user click in the UI. Lead, scheduler and workers have no code path that builds one.
- In the app the token is signed with a per-install key held in the Keychain (the app's own item, never a CLI's).
  The spike has no signing; it only proves the binding between token and hash.
- The scheduler recomputes the hash of the plan it is about to run and compares it with `approval.plan_hash`. A missing
  token, a non-`ui` source or a mismatch means the plan is rejected. Failover only moves work to providers that appear
  as a task provider in the approved plan.
- **`hash.sh --approve` is a spike test fixture only.** It mints `approved_via: "ui"` from any shell, which is exactly
  what must never be possible in the app. It exists so tests can build approved plans and must not be ported to the app.
  In the app only a UI click handler creates a token, and it is signed with the per-install key.

## Checks (`spike/plan/check.jq`)

Each violation prints one line starting with its rule number. Two modes:

- **Pre-approval** (`hash.sh --check FILE`): the UI warning before the user approves. A plan with no approval is fine.
- **Scheduler** (`hash.sh --check --require-approval FILE`): additionally rejects a plan with no approval
  (`rule 9: plan has no approval`). The scheduler path always uses this mode.

Callers must check the exit code, not just whether output is empty. `hash.sh --check` exits 0 only when the plan passes,
1 on any violation, unparsable input or checker failure (fail closed).

**Shape validation runs first**, before any default value is applied, and never crashes: a wrong type is itself a
violation. Only a well-shaped plan reaches the rule checks below.

| Rule | Rejects |
|---|---|
| 7 | A `provider` (task, fallback or lead) that is not exactly `claude`, `codex`, `grok`, `kimi`, `gemini` or `glm`. No case folding or trimming: `Gemini` and `gemini ` are rejected. |
| 7 | An `auth_mode` that is not exactly `subscription` or `api_key`. |
| 1 | `estimated_usage` missing or not an object, or `turns` / `prompts` that are not integers >= 0 (booleans, null, strings, negatives, fractions). |
| 2 | `fallback_providers` that is not an array of exact provider names. |
| 9 | `tasks` that is not a non-empty array, a task that is not an object, a missing or non-string task `id`, duplicate task ids, `depends_on` that is not an array of strings. |
| 9 | An `approval` that is not an object with string `plan_hash`, `approved_at`, `approved_via`, `nonce`. |
| 2 | A task whose `fallback_providers` contains its own `provider`, or repeats a provider. |
| 9 | A fallback provider that no task in the plan uses (failover only to providers in the approved plan). |
| 7 | A `gemini` task whose `auth_mode` is not `api_key`. |
| 1 | A task with `estimated_usage.turns` over 40, or a provider whose summed `prompts` exceed 30 across every task not exactly `api_key` (fail closed), so the UI can warn before approval. |
| 9 | An `approval` whose `plan_hash` does not match the computed hash, or whose `approved_via` is not `ui`. |
| 9 | Scheduler mode only: no approval at all. |

The ceilings are copied from docs/HARD_RULES.md rule 1 for the spike only. In the app they are compile-time constants
in one module. The checker is advisory for the UI (warn before approval); the scheduler enforces the same ceilings at
dispatch regardless of what a plan says.

## Running the spike

```
spike/plan/hash.sh docs/spec/examples/plan-valid.json            # print hash
spike/plan/hash.sh --check docs/spec/examples/plan-valid.json    # exit 0 = passes (pre-approval)
spike/plan/hash.sh --check --require-approval docs/spec/examples/plan-approved.json   # scheduler mode
/bin/bash spike/tests/test_plan.sh                               # full offline test
```
