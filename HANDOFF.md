# HANDOFF T-005
## Summary
Defined the plan format (docs/spec/plan.md plus a JSON Schema), the plan hash (`jq -S -c 'del(.approval)'` then sha256) and
the approval token bound to it. An offline checker (`check.jq`, wrapped by `hash.sh --check`) rejects plans that break
rules 1, 2, 7 and 9. Two gate rounds hardened it: schema-exact shape validation (unknown keys, types, patterns), exactly
one JSON document read once into a private copy, canonical-integer-only numbers, `--require-approval` scheduler mode,
and spec additions for Phase 1 (format_version, lead.auth_mode, fallback objects, depends_on DAG, required summary budget).

## Files changed
- docs/spec/plan.md - fields, hash, JCS gaps, parser rules for the app, approval token, check modes and table
- docs/spec/plan.schema.json - JSON Schema (2020-12); the checker enforces exactly these keys, types and patterns
- docs/spec/examples/plan-valid.json - passes all checks
- docs/spec/examples/plan-dup-fallback.json - rule 2 violation
- docs/spec/examples/plan-gemini-subscription.json - rule 7 violation
- docs/spec/examples/plan-over-turns.json - rule 1 violation
- docs/spec/examples/plan-stale-approval.json - approved, then a task title edited (rule 9)
- docs/spec/examples/plan-approved.json - extra: valid plan with a matching approval (regenerate with `hash.sh --approve` after any edit to plan-valid.json)
- spike/plan/hash.sh - `FILE` prints hash; `--check [--require-approval] FILE`; `--approve FILE` (SPIKE TEST FIXTURE ONLY). Reads the file once into a private temp copy, requires exactly one JSON object document, fails closed on any jq error
- spike/plan/check.jq - shape validation first, then rule checks; one output line per violation prefixed `rule N:`
- spike/tests/test_plan.sh - 414 offline assertions

## Tests run
- `jq empty docs/spec/plan.schema.json docs/spec/examples/*.json` - OK
- `/bin/bash spike/tests/test_plan.sh` - passed=414 failed=0 (bash 3.2)
- `make check-fast` - PASS (compliance clean; no app stack yet)

## Hard rules touched
- Rule 9: stale-approval and edited-approved-plan tests assert "does not match computed plan hash"; concatenated plans plus one approval covering both are rejected in scheduler mode; unknown keys; malformed/falsy approvals (false, 0, "", [], {}); `--require-approval`; depends_on dangling/self/duplicate/cycle; non-empty tasks, unique ids, id pattern; unused fallback provider
- Rule 2: plan-dup-fallback.json ("lists its own provider"), repeated fallback (also with differing auth_mode), case/whitespace variants, legacy string fallbacks
- Rule 7: plan-gemini-subscription.json ("api_key only"), gemini lead and gemini fallback on subscription rejected (api_key passes), provider/auth_mode allow-lists
- Rule 1: plan-over-turns.json ("ceiling is 40"), subscription prompts over 30 ("ceiling is 30"), 40 turns allowed, api_key prompts not counted, non-integer / non-canonical numbers (20.0, 2e1, -0, true, null, negative)

## Codex-gate round (third commit)
- `approval: null` is now malformed (rule 9, "approval must be an object") in both modes; only an absent `approval` key means unapproved. Matches the schema. plan.md and tests updated.
- Timestamps (`created_at`, `approval.approved_at`) get real range checks: month 01-12, day valid for the month (Feb 29 only in leap years, incl. 1900/2100 not leap and 2000 leap), hour 00-23, minute 00-59, second 00-60, offset hours 00-23 and minutes 00-59. Each bad component has a test, plus passing boundaries (leap second, 23:59 offset, fraction).
- Integers: every integer is capped at 2^53-1 by text length and value; `turns`, `prompts` and `summary_budget_tokens` are capped at 1000000 (schema `maximum` added, rule 1 / rule 9 lines say the range). Tests at 1000000 (pass), 1000001, 2^53-1 and 2^53+1 (rejected), and a 400-digit number. Because the tighter field caps sit below 2^53-1, 2^53-1 itself passes nowhere; the generic cap is only reachable through `format_version`, which must equal 1.
- Cycle message is now "tasks blocked by a dependency cycle: ..." (cycle members plus downstream tasks). Added a downstream-of-cycle test and a 25-task reverse-order acyclic chain (passes) plus the same chain closed into a cycle (rejected).

## Open risks / questions
- Not enforced by the spike, only stated in plan.md for the app: duplicate JSON keys (jq is last-wins), invalid UTF-8 and lone surrogates (jq maps to U+FFFD), single parse of a single byte buffer for hash, validate and dispatch. The spike copies the file once and checks one-document-ness, but it is still several jq invocations on that copy.
- JCS: jq escapes U+007F as `\u007f`, and jq 1.7 keeps number literals, so the spike hash is only well defined for canonical-integer plans (enforced). The app needs real JCS test vectors.
- `hash.sh --approve` mints `approved_via:"ui"` from any shell; labeled spike test fixture only (hash.sh, plan.md); must not exist in the app.
- The schema was only checked as valid JSON; no JSON Schema validator ran (none offline). check.jq mirrors it by hand and the tests exercise the mirror, but examples are not validated against the schema mechanically.
- The rule 1 prompt ceiling is 30 per hour; the spike sums per provider across the plan as a conservative warning. Scheduler must enforce hourly pacing and failover usage with live counters at dispatch (stated in plan.md).
- `glm` is in the provider list; confirm it.
- Follow-up for shared files (not mine): wire `spike/tests/test_plan.sh` into make check-fast / check (the lead does it).

## Confidence
High for the spike scope: all tests pass offline, rejected inputs name their rule and a specific message substring, and malformed shapes have direct no-crash tests. Medium on schema fidelity since the schema is not machine-validated.
