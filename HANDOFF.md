# HANDOFF T-005
## Summary
Defined the plan format (docs/spec/plan.md plus a JSON Schema), the plan hash (`jq -S -c 'del(.approval)'` then sha256) and
the approval token bound to it. An offline checker (`check.jq`) rejects plans that break rules 1, 2, 7 and 9, and a test
script proves the hash is stable under key reordering, changes on any task field edit, and that an edited approved plan
is rejected. After the compliance gate, check.jq was hardened: strict shape/type validation runs first so crafted or
malformed plans are rejected with a `rule N:` line and never crash or slip through, and a scheduler mode requires approval.

## Files changed
- docs/spec/plan.md - field list, hash definition, JCS note (incl. duplicate-key rejection requirement), approval token, check modes and table
- docs/spec/plan.schema.json - JSON Schema (2020-12), structural checks only; ceilings not encoded
- docs/spec/examples/plan-valid.json - passes all checks
- docs/spec/examples/plan-dup-fallback.json - rule 2 violation
- docs/spec/examples/plan-gemini-subscription.json - rule 7 violation
- docs/spec/examples/plan-over-turns.json - rule 1 violation
- docs/spec/examples/plan-stale-approval.json - approved, then a task title edited (rule 9)
- docs/spec/examples/plan-approved.json - extra: valid plan with a matching approval (do not edit plan-valid.json without regenerating this)
- spike/plan/hash.sh - `FILE` prints hash; `--check [--require-approval] FILE` runs check.jq and fails closed on bad JSON or any jq error; `--approve FILE` is labeled SPIKE TEST FIXTURE ONLY
- spike/plan/check.jq - shape validation first, then rule checks; one output line per violation prefixed `rule N:`
- spike/tests/test_plan.sh - 159 offline assertions

## Tests run
- `jq empty docs/spec/plan.schema.json docs/spec/examples/*.json` - OK
- `/bin/bash spike/tests/test_plan.sh` - passed=159 failed=0 (bash 3.2)
- `make check-fast` - PASS (compliance clean; no app stack yet)

## Hard rules touched
- Rule 9: stale-approval example, edited approved plan, approval missing/malformed (string, array, true, {}, missing fields), approval not via ui, unused fallback provider, `--require-approval` rejects unapproved and approval:null, tasks null/[]/{}/string, duplicate task ids
- Rule 2: plan-dup-fallback.json, own provider as fallback, repeated fallback, case/whitespace variant fallbacks, fallback_providers string/null/missing/object
- Rule 7: plan-gemini-subscription.json, provider "Gemini" / "gemini " / null / missing / unknown, lead provider variants, auth_mode variants/null/missing (fail closed)
- Rule 1: plan-over-turns.json, subscription prompt sum over 30, 40 turns allowed, api_key prompts not counted, turns/prompts true/null/string/negative/fractional/missing, estimated_usage missing/null/array, negative prompts hiding an overrun

## Open risks / questions
- The spike cannot detect duplicate JSON keys (jq is last-wins). plan.md requires the app canonicalizer/parser to reject them (parser-differential risk).
- `hash.sh --approve` mints `approved_via:"ui"` from any shell; it is labeled a spike test fixture only (hash.sh, plan.md) and must not exist in the app.
- The schema was only checked as valid JSON; no JSON Schema validator ran (none available offline). Examples are not validated against it mechanically.
- `glm` is in the provider list; confirm it.
- Rule 1 prompt ceiling is 30 per hour; the spike sums per plan as a conservative warning. The scheduler must still enforce hourly pacing at dispatch.
- `jq` differs from RFC 8785 on U+007F escaping; documented in plan.md. The app needs real JCS test vectors.
- Follow-ups for shared files: none required. Optionally, a Makefile hook to run `spike/tests/test_plan.sh` in check-fast (Makefile not owned by this brief).

## Confidence
High for the spike scope: all tests pass offline, each rejected input names its rule, and malformed shapes are covered by direct no-crash tests. Medium on schema fidelity since it is not machine-validated.
