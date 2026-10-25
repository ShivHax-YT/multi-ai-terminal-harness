#!/bin/bash
# Offline test for T-005: plan hash, approval binding and check.jq.  Run: /bin/bash spike/tests/test_plan.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HASH="$ROOT/spike/plan/hash.sh"
EX="$ROOT/docs/spec/examples"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# expect_reject NAME FILE RULE_PREFIX: --check must exit 1 and output a line starting with RULE_PREFIX
expect_reject() {
  local out rc
  out="$("$HASH" --check "$2" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q "^$3"; then ok "$1"; else bad "$1 (rc=$rc, out=$out)"; fi
}
expect_pass() {
  local out rc
  out="$("$HASH" --check "$2" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "$1"; else bad "$1 (rc=$rc, out=$out)"; fi
}

# ---- hash stability -------------------------------------------------------------------------------------------
base="$("$HASH" "$EX/plan-valid.json")"
case "$base" in
  *[!0-9a-f]*|"") bad "hash is 64 lowercase hex" ;;
  *) [ "${#base}" -eq 64 ] && ok "hash is 64 lowercase hex" || bad "hash is 64 lowercase hex" ;;
esac

jq 'walk(if type == "object" then to_entries | reverse | from_entries else . end)' \
  "$EX/plan-valid.json" > "$TMP/reordered.json"
if cmp -s <(jq -c . "$EX/plan-valid.json") <(jq -c . "$TMP/reordered.json"); then
  bad "reordered copy really has a different key order"
else
  ok "reordered copy really has a different key order"
fi
[ "$("$HASH" "$TMP/reordered.json")" = "$base" ] && ok "hash identical for key-reordered copy" \
  || bad "hash identical for key-reordered copy"

jq '.' "$EX/plan-valid.json" > "$TMP/pretty.json"
[ "$("$HASH" "$TMP/pretty.json")" = "$base" ] && ok "hash independent of whitespace" || bad "hash independent of whitespace"

[ "$("$HASH" "$EX/plan-approved.json")" = "$base" ] && ok "approval block excluded from hash" \
  || bad "approval block excluded from hash"

# ---- hash changes when any task field changes --------------------------------------------------------------------
i=0
while IFS= read -r filter; do
  i=$((i + 1))
  jq "$filter" "$EX/plan-valid.json" > "$TMP/mut$i.json"
  h="$("$HASH" "$TMP/mut$i.json")"
  if [ "$h" != "$base" ]; then ok "hash changes: $filter"; else bad "hash changes: $filter"; fi
done <<'EOF'
.tasks[0].id = "t1x"
.tasks[0].title = "other"
.tasks[0].role = "reviewer"
.tasks[0].provider = "grok"
.tasks[0].auth_mode = "api_key"
.tasks[0].owned_files += ["extra.ts"]
.tasks[0].acceptance += ["extra"]
.tasks[0].depends_on = ["t2"]
.tasks[0].estimated_usage.prompts += 1
.tasks[0].estimated_usage.turns += 1
.tasks[0].fallback_providers = ["kimi"]
.tasks[1].title = "other"
.tasks += [.tasks[0]]
.request_summary = "other"
.summary_budget_tokens = 201
EOF

# ---- check.jq ---------------------------------------------------------------------------------------------------
expect_pass "plan-valid.json passes check.jq" "$EX/plan-valid.json"
expect_pass "plan-approved.json (approval matches hash) passes" "$EX/plan-approved.json"
expect_reject "rule 2: plan-dup-fallback.json rejected" "$EX/plan-dup-fallback.json" "rule 2:"
expect_reject "rule 7: plan-gemini-subscription.json rejected" "$EX/plan-gemini-subscription.json" "rule 7:"
expect_reject "rule 1: plan-over-turns.json rejected" "$EX/plan-over-turns.json" "rule 1:"
expect_reject "rule 9: plan-stale-approval.json rejected" "$EX/plan-stale-approval.json" "rule 9:"

# rule 9: edit one field of an approved plan -> rejected
jq '.tasks[2].fallback_providers = ["codex"]' "$EX/plan-approved.json" > "$TMP/edited.json"
expect_reject "rule 9: edited approved plan (fallback) rejected" "$TMP/edited.json" "rule 9:"
jq '.tasks[3].estimated_usage.prompts = 13' "$EX/plan-approved.json" > "$TMP/edited2.json"
expect_reject "rule 9: edited approved plan (usage) rejected" "$TMP/edited2.json" "rule 9:"
jq '.approval.approved_via = "api"' "$EX/plan-approved.json" > "$TMP/notui.json"
expect_reject "rule 9: approval not via ui rejected" "$TMP/notui.json" "rule 9:"
jq 'del(.approval.plan_hash)' "$EX/plan-approved.json" > "$TMP/nohash.json"
expect_reject "rule 9: approval without plan_hash rejected" "$TMP/nohash.json" "rule 9:"

# re-approving an edited plan binds to the new hash and passes
"$HASH" --approve "$TMP/edited.json" > "$TMP/reapproved.json"
expect_pass "re-approved edited plan passes" "$TMP/reapproved.json"

# rule 2: own provider as fallback, and a repeat
jq '.tasks[0].fallback_providers = ["claude"]' "$EX/plan-valid.json" > "$TMP/own.json"
expect_reject "rule 2: own provider as fallback rejected" "$TMP/own.json" "rule 2:"
jq '.tasks[1].fallback_providers = ["kimi", "kimi"]' "$EX/plan-valid.json" > "$TMP/repeat.json"
expect_reject "rule 2: repeated fallback rejected" "$TMP/repeat.json" "rule 2:"

# rule 9: fallback provider not used anywhere in the plan
jq '.tasks[0].fallback_providers = ["grok"]' "$EX/plan-valid.json" > "$TMP/unused.json"
expect_reject "rule 9: fallback provider not in plan rejected" "$TMP/unused.json" "rule 9:"

# rule 1: summed subscription prompts over 30 (each task is under the turn ceiling)
jq '.tasks[0].estimated_usage.prompts = 31' "$EX/plan-valid.json" > "$TMP/prompts.json"
expect_reject "rule 1: subscription prompts over 30 rejected" "$TMP/prompts.json" "rule 1:"
jq '.tasks[0].estimated_usage.turns = 40' "$EX/plan-valid.json" > "$TMP/turns40.json"
expect_pass "rule 1: exactly 40 turns allowed" "$TMP/turns40.json"
# api_key prompts do not count against the subscription ceiling
jq '.tasks[3].estimated_usage.prompts = 500' "$EX/plan-valid.json" > "$TMP/apikey.json"
expect_pass "api_key prompts not counted against subscription ceiling" "$TMP/apikey.json"

# rule 7: gemini api_key passes (plan-valid has one), covered above; schema/examples are valid JSON
for f in "$EX"/*.json "$ROOT/docs/spec/plan.schema.json"; do
  if jq empty "$f" 2>/dev/null; then ok "valid JSON: ${f#"$ROOT"/}"; else bad "valid JSON: ${f#"$ROOT"/}"; fi
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
