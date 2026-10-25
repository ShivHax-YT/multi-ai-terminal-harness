# Plan format and approval binding

Spec for the plan the lead produces and the user approves (docs/ARCHITECTURE.md, "How the lead works", steps 1 and 2).
Machine-readable shape: `plan.schema.json`. Examples: `examples/`. Offline checker: `spike/plan/` (T-005).
`spike/plan/check.jq` enforces exactly the keys, types and patterns in the schema; unknown keys are violations.

## Fields

Every field is required except `approval`. **Defaults are never filled in before hashing**: a plan missing a field is
malformed, not defaulted, so the hash always covers exactly what the user saw.

| Field | Type | Notes |
|---|---|---|
| `format_version` | integer, currently `1` | Any other value is rejected. A future format bumps this. |
| `plan_id` | non-empty string | Unique per plan. |
| `created_at` | RFC 3339 string | |
| `lead` | `{provider, auth_mode}` | Provider and auth mode of the headless session that produced the plan. Rule 7 applies: a `gemini` lead must be `api_key`. |
| `request_summary` | string | The user's request, summarized. Untrusted text when displayed. |
| `summary_budget_tokens` | integer > 0 | Token budget for the lead's final summary. The UI proposes 200; the plan always states it. |
| `tasks[]` | non-empty array | See below. |
| `approval` | object, optional | Absent until the user approves. Excluded from the hash. |

Task fields (all required): `id` (matches `[A-Za-z0-9_-]+`, unique in the plan), `title` and `role` (non-empty strings),
`provider`, `auth_mode` (`subscription` or `api_key`), `owned_files[]` and `acceptance[]` (arrays of strings),
`depends_on[]` (array of task ids), `estimated_usage {prompts, turns}` (integers >= 0), `fallback_providers[]`.

A `fallback_providers` entry is an object `{provider, auth_mode}`. Rule 7 applies to each entry: a `gemini` fallback must
be `api_key`. Rules 2 and 9 look at `.provider`. A fallback is a permission to fail over, not a reservation: actual
failover usage is enforced by the live per-provider counters at dispatch, never by the estimates in the plan.

`depends_on` must describe a DAG (the scheduler needs one): ids must exist in the plan, no task depends on itself, no id
is listed twice, and there are no cycles.

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
same bytes. The spike's `jq -S -c` is close to JCS only for the restricted shape the checker enforces: a fixed set of
ASCII keys (unknown keys rejected), strings, and **canonical integers** (below). For that subset both forms sort keys and
drop insignificant whitespace. Known gaps:

- **Number literals.** jq 1.7 preserves number literals, so `20.0` and `20` are different bytes and hash differently, and
  the result depends on the jq version's number handling. JCS would print both as `20`. The spike therefore rejects
  any integer field not written as canonical integer text (`0` or `[1-9][0-9]*`: no `20.0`, `2e1`, `-0`, no sign, no
  leading zero), so the hash never depends on that behaviour. The app must parse integers into an integer type
  and hash the JCS form of the value.
- **U+007F.** `jq` escapes U+007F as `\u007f` where JCS emits the raw character.
- The app must not use `jq` output as its canonical form and needs its own JCS test vectors.

### Rules for the app's parser (the spike does not enforce these)

- **Reject duplicate keys.** The canonicalizer and plan parser must reject any JSON object with duplicate keys, before
  hashing and before validation. Parsers disagree on duplicates (the spike's `jq` keeps the last value; others keep the
  first or error), so a plan with `"provider"` twice could be hashed and checked by one parser and executed by another
  (parser-differential attack).
- **Reject invalid UTF-8 and lone surrogates** (raw or as `\ud800` escapes). `jq` maps them to U+FFFD, so different
  bytes can share one hash.
- **One parse of one byte buffer.** Read the plan bytes once, then hash, validate and dispatch from that single parse.
  Never re-read the file or re-parse for a later step. The spike's `hash.sh` copies the file once into a private temp
  file and runs every step on the copy, and requires exactly one JSON document (a file of concatenated documents is
  rejected; `jq` without `-s` would only look at the last one).

## Approval token

```json
{ "plan_hash": "<64 hex>", "approved_at": "<RFC 3339>", "approved_via": "ui", "nonce": "<random, >= 16 chars>" }
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
1 on any violation, unparsable or multi-document input, or checker failure (fail closed).

**Shape validation runs first**, before any default value is applied, and never crashes: a wrong type, a missing field
or an unknown key is itself a violation. `approval: false`, `0` and `""` count as a present, malformed approval (only
absent or `null` means "no approval"). Only a well-shaped plan reaches the rule checks below.

| Rule | Rejects |
|---|---|
| 9 | Unknown keys at any level (plan, `lead`, task, `estimated_usage`, fallback entry, `approval`); a missing or wrong-typed `format_version`, `plan_id`, `created_at`, `request_summary`, `summary_budget_tokens`, task `title`, `role`, `owned_files`, `acceptance`; a task `id` not matching `[A-Za-z0-9_-]+`. |
| 7 | A `provider` (task, fallback or lead) that is not exactly `claude`, `codex`, `grok`, `kimi`, `gemini` or `glm`. No case folding or trimming: `Gemini` and `gemini ` are rejected. |
| 7 | An `auth_mode` (lead, task or fallback) that is not exactly `subscription` or `api_key`. |
| 1 | `estimated_usage` missing or not an object, or `turns` / `prompts` that are not canonical integers >= 0 (booleans, null, strings, negatives, fractions, `20.0`, `2e1`). |
| 2 | `fallback_providers` that is not an array of `{provider, auth_mode}` objects with exact provider names. |
| 9 | `tasks` that is not a non-empty array, a task that is not an object, a missing or non-string task `id`, duplicate task ids. |
| 9 | `depends_on` that is not an array of strings, lists an id twice, references an unknown id, depends on its own task, or forms a cycle. |
| 9 | An `approval` that is not an object with the four keys: `plan_hash` (64 lowercase hex), `approved_at` (RFC 3339 string), `approved_via` (string), `nonce` (string of at least 16 characters). |
| 2 | A task whose `fallback_providers` contains its own `provider`, or repeats a provider. |
| 9 | A fallback provider that no task in the plan uses (failover only to providers in the approved plan). |
| 7 | A `gemini` lead, task or fallback whose `auth_mode` is not `api_key`. |
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
