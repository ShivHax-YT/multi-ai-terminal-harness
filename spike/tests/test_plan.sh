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

# ---- hardening: crafted plans must not bypass or crash the checker ------------------------------------------------
CHECKJQ="$ROOT/spike/plan/check.jq"

# mut NAME FILTER RULE [BASE]: apply FILTER to BASE (default plan-valid), expect hash.sh --check to reject with RULE,
# and expect check.jq run directly to neither crash (rc 0) nor print nothing.
mut() {
  local name="$1" filter="$2" rule="$3" base="${4:-$EX/plan-valid.json}" f out rc
  f="$TMP/mut-$(printf '%s' "$name" | cksum | cut -d' ' -f1).json"
  jq "$filter" "$base" > "$f"
  expect_reject "$name" "$f" "$rule"
  rc=0
  out="$(jq -r --arg hash x --argjson require_approval false -f "$CHECKJQ" "$f" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "^$rule"; then ok "no crash: $name"; else bad "no crash: $name (rc=$rc, out=$out)"; fi
}
# mut_pass NAME FILTER [BASE]
mut_pass() {
  local name="$1" filter="$2" base="${3:-$EX/plan-valid.json}" f
  f="$TMP/mutp-$(printf '%s' "$name" | cksum | cut -d' ' -f1).json"
  jq "$filter" "$base" > "$f"
  expect_pass "$name" "$f"
}

# 1. rule 7: provider allow-list (case and whitespace variants, null)
mut 'rule 7: provider "Gemini" with subscription' '.tasks[3].provider = "Gemini" | .tasks[3].auth_mode = "subscription"' "rule 7:"
mut 'rule 7: provider "gemini " with subscription' '.tasks[3].provider = "gemini " | .tasks[3].auth_mode = "subscription"' "rule 7:"
mut 'rule 7: provider null' '.tasks[3].provider = null' "rule 7:"
mut 'rule 7: provider missing' 'del(.tasks[0].provider)' "rule 7:"
mut 'rule 7: provider number' '.tasks[0].provider = 5' "rule 7:"
mut 'rule 7: unknown provider' '.tasks[0].provider = "other"' "rule 7:"
mut 'rule 7: lead provider "Claude"' '.lead.provider = "Claude"' "rule 7:"
mut 'rule 7: lead missing' 'del(.lead)' "rule 7:"
mut 'rule 7: fallback "Gemini"' '.tasks[0].fallback_providers = ["Gemini"]' "rule 2:"
mut 'rule 2: fallback "claude " (trailing space)' '.tasks[0].fallback_providers = ["codex", "claude "]' "rule 2:"
mut 'rule 2: case-variant fallback "Kimi" next to "kimi"' '.tasks[1].fallback_providers = ["kimi", "Kimi"]' "rule 2:"
mut 'rule 2: fallback null element' '.tasks[0].fallback_providers = [null]' "rule 2:"

# 2. rule 1: type bypasses and fail-closed auth_mode
mut 'rule 1: turns true' '.tasks[0].estimated_usage.turns = true' "rule 1:"
mut 'rule 1: turns null' '.tasks[0].estimated_usage.turns = null' "rule 1:"
mut 'rule 1: turns string' '.tasks[0].estimated_usage.turns = "99"' "rule 1:"
mut 'rule 1: turns negative' '.tasks[0].estimated_usage.turns = -1' "rule 1:"
mut 'rule 1: turns fractional' '.tasks[0].estimated_usage.turns = 1.5' "rule 1:"
mut 'rule 1: turns missing' 'del(.tasks[0].estimated_usage.turns)' "rule 1:"
mut 'rule 1: prompts true' '.tasks[0].estimated_usage.prompts = true' "rule 1:"
mut 'rule 1: prompts negative' '.tasks[0].estimated_usage.prompts = -100' "rule 1:"
mut 'rule 1: prompts null' '.tasks[0].estimated_usage.prompts = null' "rule 1:"
mut 'rule 1: estimated_usage missing' 'del(.tasks[0].estimated_usage)' "rule 1:"
mut 'rule 1: estimated_usage null' '.tasks[0].estimated_usage = null' "rule 1:"
mut 'rule 1: estimated_usage array' '.tasks[0].estimated_usage = []' "rule 1:"
mut 'rule 7: auth_mode "API_KEY"' '.tasks[3].auth_mode = "API_KEY"' "rule 7:"
mut 'rule 7: auth_mode null' '.tasks[0].auth_mode = null' "rule 7:"
mut 'rule 7: auth_mode missing' 'del(.tasks[0].auth_mode)' "rule 7:"
# negative prompts cannot cancel out a real subscription total (and are rejected outright)
mut 'rule 1: negative prompts hiding an overrun' '.tasks[0].estimated_usage.prompts = 40 | .tasks[3].auth_mode = "subscription" | .tasks[3].provider = "claude" | .tasks[3].estimated_usage.prompts = -20' "rule 1:"

# 3. rule 9: --require-approval (scheduler path)
out="$("$HASH" --check --require-approval "$EX/plan-valid.json" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^rule 9: plan has no approval'; then
  ok "rule 9: --require-approval rejects unapproved plan"
else
  bad "rule 9: --require-approval rejects unapproved plan (rc=$rc, out=$out)"
fi
out="$("$HASH" --check --require-approval "$EX/plan-approved.json" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "--require-approval accepts a correctly approved plan" \
  || bad "--require-approval accepts a correctly approved plan (rc=$rc, out=$out)"
out="$("$HASH" --check --require-approval "$EX/plan-stale-approval.json" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^rule 9:' && ok "--require-approval rejects stale approval" \
  || bad "--require-approval rejects stale approval (rc=$rc, out=$out)"
jq '.approval = null' "$EX/plan-valid.json" > "$TMP/null-approval.json"
out="$("$HASH" --check --require-approval "$TMP/null-approval.json" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^rule 9: plan has no approval' && ok "--require-approval rejects approval:null" \
  || bad "--require-approval rejects approval:null (rc=$rc, out=$out)"
expect_pass "plain --check still accepts unapproved plan (pre-approval UI warning)" "$EX/plan-valid.json"
"$HASH" --check --bogus "$EX/plan-valid.json" >/dev/null 2>&1; [ $? -ne 0 ] && ok "unknown --check flag is an error" || bad "unknown --check flag is an error"

# 4. rule 9: malformed approval / fallbacks / tasks never crash and never pass
mut 'rule 9: approval "yes"' '.approval = "yes"' "rule 9:"
mut 'rule 9: approval []' '.approval = []' "rule 9:"
mut 'rule 9: approval true' '.approval = true' "rule 9:"
mut 'rule 9: approval {} (no fields)' '.approval = {}' "rule 9:"
mut 'rule 9: approval.plan_hash number' '.approval.plan_hash = 7' "rule 9:" "$EX/plan-approved.json"
mut 'rule 9: approval.nonce missing' 'del(.approval.nonce)' "rule 9:" "$EX/plan-approved.json"
mut 'rule 9: approval.approved_at null' '.approval.approved_at = null' "rule 9:" "$EX/plan-approved.json"
mut 'rule 9: approval.approved_via missing' 'del(.approval.approved_via)' "rule 9:" "$EX/plan-approved.json"
mut 'rule 2: fallback_providers "codex" (string)' '.tasks[0].fallback_providers = "codex"' "rule 2:"
mut 'rule 2: fallback_providers null' '.tasks[0].fallback_providers = null' "rule 2:"
mut 'rule 2: fallback_providers missing' 'del(.tasks[0].fallback_providers)' "rule 2:"
mut 'rule 2: fallback_providers object' '.tasks[0].fallback_providers = {}' "rule 2:"
mut 'rule 9: task is a string' '.tasks[0] = "x"' "rule 9:"
mut 'rule 9: task is null' '.tasks[0] = null' "rule 9:"
mut 'rule 9: depends_on string' '.tasks[0].depends_on = "t2"' "rule 9:"

# a non-object or unparsable plan file is rejected by the wrapper
printf '[]' > "$TMP/arr.json"
expect_reject "rule 9: top-level array rejected" "$TMP/arr.json" "rule 9:"
printf '"x"' > "$TMP/str.json"
expect_reject "rule 9: top-level string rejected" "$TMP/str.json" "rule 9:"
printf '{not json' > "$TMP/broken.json"
expect_reject "rule 9: unparsable JSON rejected" "$TMP/broken.json" "rule 9:"
: > "$TMP/empty.json"
expect_reject "rule 9: empty file rejected" "$TMP/empty.json" "rule 9:"

# 5. rules 2/9: tasks shape and duplicate ids
mut 'rule 9: tasks null' '.tasks = null' "rule 9:"
mut 'rule 9: tasks []' '.tasks = []' "rule 9:"
mut 'rule 9: tasks {}' '.tasks = {}' "rule 9:"
mut 'rule 9: tasks string' '.tasks = "x"' "rule 9:"
mut 'rule 9: tasks missing' 'del(.tasks)' "rule 9:"
mut 'rule 9: duplicate task ids' '.tasks[1].id = .tasks[0].id' "rule 9:"
mut 'rule 9: task id missing' 'del(.tasks[0].id)' "rule 9:"
mut 'rule 9: task id number' '.tasks[0].id = 1' "rule 9:"

# the original good plans still pass after all the hardening
expect_pass "plan-valid.json still passes" "$EX/plan-valid.json"
mut_pass "integer-valued float turns (20.0) is an integer" '.tasks[0].estimated_usage.turns = 20.0'
mut_pass "zero usage allowed" '.tasks[2].estimated_usage = {prompts: 0, turns: 0}'

# schema/examples are valid JSON
for f in "$EX"/*.json "$ROOT/docs/spec/plan.schema.json"; do
  if jq empty "$f" 2>/dev/null; then ok "valid JSON: ${f#"$ROOT"/}"; else bad "valid JSON: ${f#"$ROOT"/}"; fi
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
