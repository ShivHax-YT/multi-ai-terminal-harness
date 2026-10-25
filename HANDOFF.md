# HANDOFF T-005
## Summary
Defined the plan format (docs/spec/plan.md plus a JSON Schema), the plan hash (`jq -S -c 'del(.approval)'` then sha256) and
the approval token bound to it. An offline checker (`check.jq`) rejects plans that break rules 1, 2, 7 and 9, and a test
script proves the hash is stable under key reordering, changes on any task field edit, and that an edited approved plan
is rejected.

## Files changed
- docs/spec/plan.md - field list, hash definition, JCS note, approval token, check table
- docs/spec/plan.schema.json - JSON Schema (2020-12), structural checks only; ceilings not encoded
- docs/spec/examples/plan-valid.json - passes all checks
- docs/spec/examples/plan-dup-fallback.json - rule 2 violation
- docs/spec/examples/plan-gemini-subscription.json - rule 7 violation
- docs/spec/examples/plan-over-turns.json - rule 1 violation
- docs/spec/examples/plan-stale-approval.json - approved, then a task title edited (rule 9)
- docs/spec/examples/plan-approved.json - extra: valid plan with a matching approval (do not edit plan-valid.json without regenerating this)
- spike/plan/hash.sh - `FILE` prints hash; `--check FILE` runs check.jq; `--approve FILE` binds a token (spike only)
- spike/plan/check.jq - rule checks, one output line per violation prefixed `rule N:`
- spike/tests/test_plan.sh - 44 offline assertions

## Tests run
- `jq empty docs/spec/plan.schema.json docs/spec/examples/*.json` - OK
- `/bin/bash spike/tests/test_plan.sh` - passed=44 failed=0
- `make check-fast` - PASS (compliance clean; no app stack yet)

## Hard rules touched
- Rule 9: stale-approval example, edited approved plan (fallback and usage edits), approval without hash, approval not via ui, unused fallback provider
- Rule 2: plan-dup-fallback.json, own provider as fallback, repeated fallback
- Rule 7: plan-gemini-subscription.json
- Rule 1: plan-over-turns.json, subscription prompt sum over 30, 40 turns allowed, api_key prompts not counted

## Open risks / questions
- The schema was only checked as valid JSON; no JSON Schema validator ran (none available offline in the spike). Examples are not validated against it mechanically.
- `glm` is in the provider enum and treated as a subscription/api_key provider like the others; confirm the provider list.
- Rule 1 prompt ceiling is 30 per hour; the spike sums per plan as a conservative warning. The scheduler must still enforce hourly pacing at dispatch.
- `jq` differs from RFC 8785 on U+007F escaping; documented in plan.md. The app needs real JCS test vectors.
- Follow-ups for shared files: none required. Optionally, a Makefile hook to run `spike/tests/test_plan.sh` in check-fast (Makefile not owned by this brief).

## Confidence
High for the spike scope: all tests pass offline and each rejected example names its rule. Medium on schema fidelity since it is not machine-validated.
