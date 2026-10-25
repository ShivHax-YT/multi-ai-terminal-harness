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

# jq prelude for filters: fb("codex") builds a subscription fallback entry
FB='def fb($p): {provider: $p, auth_mode: "subscription"}; def fbk($p): {provider: $p, auth_mode: "api_key"}; '

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
  jq "$FB$filter" "$EX/plan-valid.json" > "$TMP/mut$i.json"
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
.tasks[0].fallback_providers = [fb("kimi")]
.tasks[1].title = "other"
.tasks += [.tasks[0]]
.request_summary = "other"
.summary_budget_tokens = 201
EOF

# ---- check.jq ---------------------------------------------------------------------------------------------------
expect_pass "plan-valid.json passes check.jq" "$EX/plan-valid.json"
expect_pass "plan-approved.json (approval matches hash) passes" "$EX/plan-approved.json"
expect_reject "rule 2: plan-dup-fallback.json rejected" "$EX/plan-dup-fallback.json" "rule 2:"
expect_reject "rule 2: plan-dup-fallback.json names the own-provider fallback" "$EX/plan-dup-fallback.json" "rule 2: .*lists its own provider"
expect_reject "rule 7: plan-gemini-subscription.json rejected" "$EX/plan-gemini-subscription.json" "rule 7:"
expect_reject "rule 7: plan-gemini-subscription.json says api_key only" "$EX/plan-gemini-subscription.json" "rule 7: .*gemini is api_key only"
expect_reject "rule 1: plan-over-turns.json rejected" "$EX/plan-over-turns.json" "rule 1:"
expect_reject "rule 1: plan-over-turns.json names the ceiling" "$EX/plan-over-turns.json" "rule 1: .*estimates 41 turns, ceiling is 40"
expect_reject "rule 9: plan-stale-approval.json rejected" "$EX/plan-stale-approval.json" "rule 9:"
expect_reject "rule 9: plan-stale-approval.json hash mismatch" "$EX/plan-stale-approval.json" "rule 9: .*does not match computed plan hash"

# rule 9: edit one field of an approved plan -> rejected
jq "$FB"'.tasks[2].fallback_providers = [fb("codex")]' "$EX/plan-approved.json" > "$TMP/edited.json"
expect_reject "rule 9: edited approved plan (fallback) rejected" "$TMP/edited.json" "rule 9: .*does not match computed plan hash"
jq '.tasks[3].estimated_usage.prompts = 13' "$EX/plan-approved.json" > "$TMP/edited2.json"
expect_reject "rule 9: edited approved plan (usage) rejected" "$TMP/edited2.json" "rule 9: .*does not match computed plan hash"
jq '.approval.approved_via = "api"' "$EX/plan-approved.json" > "$TMP/notui.json"
expect_reject "rule 9: approval not via ui rejected" "$TMP/notui.json" "rule 9: approval approved_via must be"
jq 'del(.approval.plan_hash)' "$EX/plan-approved.json" > "$TMP/nohash.json"
expect_reject "rule 9: approval without plan_hash rejected" "$TMP/nohash.json" "rule 9: approval.plan_hash must be 64 lowercase hex"

# re-approving an edited plan binds to the new hash and passes
"$HASH" --approve "$TMP/edited.json" > "$TMP/reapproved.json"
expect_pass "re-approved edited plan passes" "$TMP/reapproved.json"

# rule 2: own provider as fallback, and a repeat
jq "$FB"'.tasks[0].fallback_providers = [fb("claude")]' "$EX/plan-valid.json" > "$TMP/own.json"
expect_reject "rule 2: own provider as fallback rejected" "$TMP/own.json" "rule 2: .*lists its own provider"
jq "$FB"'.tasks[1].fallback_providers = [fb("kimi"), fb("kimi")]' "$EX/plan-valid.json" > "$TMP/repeat.json"
expect_reject "rule 2: repeated fallback rejected" "$TMP/repeat.json" "rule 2: .*repeats fallback provider kimi"

# rule 9: fallback provider not used anywhere in the plan
jq "$FB"'.tasks[0].fallback_providers = [fb("grok")]' "$EX/plan-valid.json" > "$TMP/unused.json"
expect_reject "rule 9: fallback provider not in plan rejected" "$TMP/unused.json" "rule 9: .*not used by any task in the plan"

# rule 1: summed subscription prompts over 30 (each task is under the turn ceiling)
jq '.tasks[0].estimated_usage.prompts = 31' "$EX/plan-valid.json" > "$TMP/prompts.json"
expect_reject "rule 1: subscription prompts over 30 rejected" "$TMP/prompts.json" "rule 1: .*ceiling is 30"
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
  jq "$FB$filter" "$base" > "$f"
  expect_reject "$name" "$f" "$rule"
  rc=0
  out="$(jq -r --arg hash x --argjson require_approval false -f "$CHECKJQ" "$f" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "^$rule"; then ok "no crash: $name"; else bad "no crash: $name (rc=$rc, out=$out)"; fi
}
# mut_pass NAME FILTER [BASE]
mut_pass() {
  local name="$1" filter="$2" base="${3:-$EX/plan-valid.json}" f
  f="$TMP/mutp-$(printf '%s' "$name" | cksum | cut -d' ' -f1).json"
  jq "$FB$filter" "$base" > "$f"
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
mut 'rule 2: fallback provider "Gemini" (case variant)' '.tasks[0].fallback_providers = [{provider: "Gemini", auth_mode: "api_key"}]' "rule 2:"
mut 'rule 2: fallback provider "claude " (trailing space)' '.tasks[0].fallback_providers = [fb("codex"), {provider: "claude ", auth_mode: "subscription"}]' "rule 2:"
mut 'rule 2: case-variant fallback "Kimi" next to "kimi"' '.tasks[1].fallback_providers = [fb("kimi"), fb("Kimi")]' "rule 2:"
mut 'rule 2: fallback null element' '.tasks[0].fallback_providers = [null]' "rule 2:"
mut 'rule 2: legacy string fallback entry' '.tasks[0].fallback_providers = ["codex"]' "rule 2:"
mut 'rule 2: fallback entry with extra key' '.tasks[0].fallback_providers = [fb("codex") + {max_turns: 999}]' "rule 9: .*unknown key"

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
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^rule 9: approval must be an object' && ok "--require-approval rejects approval:null (present key, malformed)" \
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
mut_pass "zero usage allowed" '.tasks[2].estimated_usage = {prompts: 0, turns: 0}'

# ---- round 2: single document, schema-exact shape, numbers, spec gaps --------------------------------------------

# mut_sed NAME SED_EXPR RULE_PATTERN: edit the raw text of plan-valid.json (jq would normalise number literals)
mut_sed() {
  local name="$1" expr="$2" rule="$3" f out rc
  f="$TMP/sed-$(printf '%s' "$name" | cksum | cut -d' ' -f1).json"
  sed -e "$expr" "$EX/plan-valid.json" > "$f"
  if cmp -s "$f" "$EX/plan-valid.json"; then bad "$name (sed expression changed nothing)"; return; fi
  expect_reject "$name" "$f" "$rule"
  rc=0
  out="$(jq -r --arg hash x --argjson require_approval false -f "$CHECKJQ" "$f" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "^$rule"; then ok "no crash: $name"; else bad "no crash: $name (rc=$rc, out=$out)"; fi
}

# 1. exactly one JSON document (a concatenated pair must never pass, even with a hash covering both)
cat "$EX/plan-valid.json" "$EX/plan-valid.json" > "$TMP/cat-same.json"
expect_reject "rule 9: two concatenated plans rejected" "$TMP/cat-same.json" "rule 9: plan file must contain exactly one JSON document"
jq '.plan_id = "plan-other" | .tasks[0].provider = "grok"' "$EX/plan-valid.json" > "$TMP/planB.json"
cat "$EX/plan-valid.json" "$TMP/planB.json" > "$TMP/combo.json"
att_hash="$(jq -S -c 'del(.approval)' "$TMP/combo.json" | shasum -a 256 | cut -d' ' -f1)"
jq --arg h "$att_hash" '.approval = {plan_hash: $h, approved_at: "2026-10-25T10:00:00Z", approved_via: "ui", nonce: "0123456789abcdef0123"}' \
  "$TMP/planB.json" > "$TMP/planB-approved.json"
cat "$EX/plan-valid.json" "$TMP/planB-approved.json" > "$TMP/attack.json"
out="$("$HASH" --check --require-approval "$TMP/attack.json" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^rule 9: plan file must contain exactly one JSON document'; then
  ok "rule 9: concatenated plans + one approval covering both rejected in scheduler mode"
else
  bad "rule 9: concatenated plans + one approval covering both rejected in scheduler mode (rc=$rc, out=$out)"
fi
"$HASH" "$TMP/attack.json" >/dev/null 2>&1; [ $? -ne 0 ] && ok "hash of a concatenated file is refused" || bad "hash of a concatenated file is refused"
"$HASH" --approve "$TMP/attack.json" >/dev/null 2>&1; [ $? -ne 0 ] && ok "--approve of a concatenated file is refused" || bad "--approve of a concatenated file is refused"

# 2. schema-exact shape: unknown keys
mut 'rule 9: unknown top-level key ceiling_override' '.ceiling_override = 1000' "rule 9: .*unknown key"
mut 'rule 9: unknown lead key' '.lead.max_turns = 1000' "rule 9: .*unknown key"
mut 'rule 9: unknown task key max_turns' '.tasks[0].max_turns = 1000' "rule 9: .*unknown key"
mut 'rule 9: unknown estimated_usage key' '.tasks[0].estimated_usage.hours = 99' "rule 9: .*unknown key"
mut 'rule 9: unknown approval key' '.approval.scope = "all"' "rule 9: .*unknown key" "$EX/plan-approved.json"

# 2. schema-exact shape: required fields and types
mut 'rule 9: plan_id missing' 'del(.plan_id)' "rule 9: plan_id"
mut 'rule 9: plan_id number' '.plan_id = 5' "rule 9: plan_id"
mut 'rule 9: plan_id empty' '.plan_id = ""' "rule 9: plan_id"
mut 'rule 9: created_at missing' 'del(.created_at)' "rule 9: created_at"
mut 'rule 9: created_at not a timestamp' '.created_at = "yesterday"' "rule 9: created_at"
mut 'rule 9: created_at trailing newline' '.created_at = "2026-10-25T09:00:00Z\n"' "rule 9: created_at"
mut 'rule 9: request_summary missing' 'del(.request_summary)' "rule 9: request_summary"
mut 'rule 9: request_summary number' '.request_summary = 1' "rule 9: request_summary"
mut 'rule 9: title missing' 'del(.tasks[0].title)' "rule 9: tasks\[0\]\.title"
mut 'rule 9: title empty' '.tasks[0].title = ""' "rule 9: tasks\[0\]\.title"
mut 'rule 9: role missing' 'del(.tasks[0].role)' "rule 9: tasks\[0\]\.role"
mut 'rule 9: role number' '.tasks[0].role = 1' "rule 9: tasks\[0\]\.role"
mut 'rule 9: acceptance string' '.tasks[0].acceptance = "all"' "rule 9: tasks\[0\]\.acceptance"
mut 'rule 9: acceptance missing' 'del(.tasks[0].acceptance)' "rule 9: tasks\[0\]\.acceptance"
mut 'rule 9: acceptance with non-string' '.tasks[0].acceptance = [1]' "rule 9: tasks\[0\]\.acceptance"
mut 'rule 9: owned_files string "**"' '.tasks[0].owned_files = "**"' "rule 9: tasks\[0\]\.owned_files"
mut 'rule 9: owned_files missing' 'del(.tasks[0].owned_files)' "rule 9: tasks\[0\]\.owned_files"
mut 'rule 9: owned_files with null' '.tasks[0].owned_files = [null]' "rule 9: tasks\[0\]\.owned_files"
mut 'rule 9: task id "../x y"' '.tasks[0].id = "../x y"' "rule 9: tasks\[0\]\.id"
mut 'rule 9: task id with space' '.tasks[0].id = "t 1"' "rule 9: tasks\[0\]\.id"
mut 'rule 9: task id empty' '.tasks[0].id = ""' "rule 9: tasks\[0\]\.id"
mut 'rule 9: task id trailing newline' '.tasks[0].id = "t1\n"' "rule 9: tasks\[0\]\.id"
mut 'rule 9: summary_budget_tokens missing' 'del(.summary_budget_tokens)' "rule 9: summary_budget_tokens"
mut 'rule 9: summary_budget_tokens 0' '.summary_budget_tokens = 0' "rule 9: summary_budget_tokens"
mut 'rule 9: summary_budget_tokens negative' '.summary_budget_tokens = -1' "rule 9: summary_budget_tokens"
mut 'rule 9: summary_budget_tokens string' '.summary_budget_tokens = "200"' "rule 9: summary_budget_tokens"
mut 'rule 9: summary_budget_tokens bool' '.summary_budget_tokens = true' "rule 9: summary_budget_tokens"
mut 'rule 9: summary_budget_tokens fractional' '.summary_budget_tokens = 200.5' "rule 9: summary_budget_tokens"
mut 'rule 9: format_version missing' 'del(.format_version)' "rule 9: format_version"
mut 'rule 9: format_version 2' '.format_version = 2' "rule 9: format_version"
mut 'rule 9: format_version "1"' '.format_version = "1"' "rule 9: format_version"
mut 'rule 9: approval.plan_hash uppercase' '.approval.plan_hash |= ascii_upcase' "rule 9: approval.plan_hash" "$EX/plan-approved.json"
mut 'rule 9: approval.plan_hash short' '.approval.plan_hash = "abc123"' "rule 9: approval.plan_hash" "$EX/plan-approved.json"
mut 'rule 9: approval.plan_hash trailing newline' '.approval.plan_hash += "\n"' "rule 9: approval.plan_hash" "$EX/plan-approved.json"
mut 'rule 9: approval.nonce too short' '.approval.nonce = "abc"' "rule 9: approval.nonce" "$EX/plan-approved.json"
mut 'rule 9: approval.nonce number' '.approval.nonce = 12345678901234567890' "rule 9: approval.nonce" "$EX/plan-approved.json"
mut 'rule 9: approval.approved_at empty' '.approval.approved_at = ""' "rule 9: approval.approved_at" "$EX/plan-approved.json"
mut 'rule 9: approval.approved_at not a timestamp' '.approval.approved_at = "now"' "rule 9: approval.approved_at" "$EX/plan-approved.json"

# 3. approval present-but-falsy is still malformed in pre-approval mode (jq's // treats false like null)
mut 'rule 9: approval false (pre-approval mode)' '.approval = false' "rule 9: approval must be an object"
mut 'rule 9: approval 0 (pre-approval mode)' '.approval = 0' "rule 9: approval must be an object"
mut 'rule 9: approval empty string (pre-approval mode)' '.approval = ""' "rule 9: approval must be an object"
out="$("$HASH" --check --require-approval <(jq '.approval = false' "$EX/plan-valid.json") 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^rule 9:' && ok "approval:false rejected in scheduler mode" \
  || bad "approval:false rejected in scheduler mode (rc=$rc, out=$out)"

# 4. numbers: only canonical integer text (jq 1.7 keeps literals, so 20.0 and 20 would hash differently)
mut_sed 'rule 1: turns written 20.0' 's/"turns": 20$/"turns": 20.0/' "rule 1: .*turns must be an integer"
mut_sed 'rule 1: turns written 2e1' 's/"turns": 20$/"turns": 2e1/' "rule 1: .*turns must be an integer"
mut_sed 'rule 1: prompts written 10.0' 's/"prompts": 10,/"prompts": 10.0,/' "rule 1: .*prompts must be an integer"
mut_sed 'rule 1: prompts written -0' 's/"prompts": 10,/"prompts": -0,/' "rule 1: .*prompts must be an integer"
mut_sed 'rule 9: summary_budget_tokens written 200.0' 's/"summary_budget_tokens": 200/"summary_budget_tokens": 200.0/' "rule 9: summary_budget_tokens"
mut_sed 'rule 9: format_version written 1.0' 's/"format_version": 1/"format_version": 1.0/' "rule 9: format_version"

# 5. lead.auth_mode and fallback {provider, auth_mode}: rule 7 applies to every gemini use
mut 'rule 7: lead.auth_mode missing' 'del(.lead.auth_mode)' "rule 7: lead.auth_mode"
mut 'rule 7: lead.auth_mode invalid' '.lead.auth_mode = "oauth"' "rule 7: lead.auth_mode"
mut 'rule 7: gemini lead on subscription' '.lead = {provider: "gemini", auth_mode: "subscription"}' "rule 7: .*gemini is api_key only"
mut_pass 'gemini lead on api_key passes' '.lead = {provider: "gemini", auth_mode: "api_key"}'
mut 'rule 7: gemini fallback on subscription' '.tasks[0].fallback_providers = [fb("gemini")]' "rule 7: .*gemini fallback.*api_key only"
mut 'rule 7: fallback auth_mode missing' 'del(.tasks[0].fallback_providers[0].auth_mode)' "rule 7: .*fallback_providers.*auth_mode"
mut 'rule 7: fallback auth_mode invalid' '.tasks[0].fallback_providers[0].auth_mode = "oauth"' "rule 7: .*fallback_providers.*auth_mode"
mut_pass 'gemini fallback on api_key passes' '.tasks[0].fallback_providers = [fbk("gemini")]'
mut 'rule 2: fallback entry provider equals own provider (object form)' '.tasks[1].fallback_providers = [fbk("codex")]' "rule 2: .*lists its own provider"
mut 'rule 2: repeated fallback provider with different auth_mode' '.tasks[1].fallback_providers = [fb("kimi"), fbk("kimi")]' "rule 2: .*repeats fallback provider kimi"
mut 'rule 9: fallback provider not used (object form)' '.tasks[0].fallback_providers = [fb("grok")]' "rule 9: .*not used by any task"

# 6. depends_on must form a DAG over ids in the plan
mut 'rule 9: depends_on dangling id' '.tasks[0].depends_on = ["nope"]' "rule 9: .*unknown task"
mut 'rule 9: depends_on self-dependency' '.tasks[0].depends_on = ["t1"]' "rule 9: .*depends on itself"
mut 'rule 9: depends_on duplicate entry' '.tasks[2].depends_on = ["t1", "t1"]' "rule 9: .*more than once"
mut 'rule 9: depends_on 2-cycle' '.tasks[0].depends_on = ["t2"] | .tasks[1].depends_on = ["t1"]' "rule 9: tasks blocked by a dependency cycle"
mut 'rule 9: depends_on 3-cycle' '.tasks[0].depends_on = ["t3"]' "rule 9: tasks blocked by a dependency cycle"
mut 'rule 9: depends_on non-string entry' '.tasks[0].depends_on = [1]' "rule 9: .*depends_on must be an array of strings"
mut_pass 'diamond depends_on (a DAG) passes' '.tasks[3].depends_on = ["t2", "t3"]'
# a task downstream of a cycle is blocked too, and is named
mut 'rule 9: task downstream of a cycle is reported as blocked' '.tasks[0].depends_on = ["t2"] | .tasks[1].depends_on = ["t1"] | .tasks[3].depends_on = ["t3"]' "rule 9: tasks blocked by a dependency cycle: t1, t2, t3, t4"
# a long acyclic chain listed in reverse order (each task depends on the next one in the array) must pass
CHAIN='.tasks = [range(0; 25) as $i | .tasks[0] + {id: "c\($i)", depends_on: (if $i < 24 then ["c\($i + 1)"] else [] end), fallback_providers: [], estimated_usage: {prompts: 1, turns: 1}}]'
mut_pass 'long reverse-order acyclic chain (25 tasks) passes' "$CHAIN"
mut 'rule 9: same long chain closed into a cycle is rejected' "$CHAIN | .tasks[24].depends_on = [\"c0\"]" "rule 9: tasks blocked by a dependency cycle"

# 7. approval: a present key must hold an object (null is malformed, in both modes); only an absent key means unapproved
mut 'rule 9: approval null (pre-approval mode)' '.approval = null' "rule 9: approval must be an object"
mut 'rule 9: approval null on an otherwise approved plan' '.approval = null' "rule 9: approval must be an object" "$EX/plan-approved.json"

# 8. timestamps need real ranges (created_at and approval.approved_at)
for ts_case in \
  'month 00|2026-00-10T10:00:00Z' 'month 13|2026-13-10T10:00:00Z' 'day 00|2026-10-00T10:00:00Z' \
  'day 32|2026-10-32T10:00:00Z' 'Apr 31|2026-04-31T10:00:00Z' 'Feb 30|2024-02-30T10:00:00Z' \
  'Feb 29 2026 (not leap)|2026-02-29T10:00:00Z' 'Feb 29 1900 (not leap)|1900-02-29T10:00:00Z' \
  'Feb 29 2100 (not leap)|2100-02-29T10:00:00Z' 'hour 24|2026-10-10T24:00:00Z' 'minute 60|2026-10-10T10:60:00Z' \
  'second 61|2026-10-10T10:00:61Z' 'offset hour 24|2026-10-10T10:00:00+24:00' 'offset minute 60|2026-10-10T10:00:00-05:60' \
  'all out of range|2026-99-99T99:99:99Z' 'missing zone|2026-10-10T10:00:00' 'lowercase t|2026-10-10t10:00:00Z'; do
  ts_name="${ts_case%%|*}"
  ts_val="${ts_case#*|}"
  mut "rule 9: created_at $ts_name" ".created_at = \"$ts_val\"" "rule 9: created_at"
  mut "rule 9: approved_at $ts_name" ".approval.approved_at = \"$ts_val\"" "rule 9: approval.approved_at" "$EX/plan-approved.json"
done
for ts_case in \
  'Feb 29 2024 (leap)|2024-02-29T10:00:00Z' 'Feb 29 2000 (leap, divisible by 400)|2000-02-29T10:00:00Z' \
  'Feb 28 2026|2026-02-28T23:59:59Z' 'leap second|2016-12-31T23:59:60Z' 'fraction and offset|2026-10-10T10:00:00.123456+05:30' \
  'offset 23:59|2026-10-10T10:00:00-23:59' 'Dec 31|2026-12-31T00:00:00Z'; do
  ts_name="${ts_case%%|*}"
  ts_val="${ts_case#*|}"
  mut_pass "timestamp ok: created_at $ts_name" ".created_at = \"$ts_val\""
done

# 9. integer bounds: estimates and summary_budget_tokens are capped at 1000000, every integer at 2^53-1
mut_pass 'prompts 1000000 on an api_key task is within bounds' '.tasks[3].estimated_usage.prompts = 1000000'
mut 'rule 1: prompts 1000001' '.tasks[3].estimated_usage.prompts = 1000001' "rule 1: .*prompts must be an integer from 0 to 1000000"
mut 'rule 1: prompts 2^53-1 (above the estimate cap)' '.tasks[3].estimated_usage.prompts = 9007199254740991' "rule 1: .*prompts must be an integer"
mut_sed 'rule 1: prompts 2^53+1' 's/"prompts": 12,/"prompts": 9007199254740993,/' "rule 1: .*prompts must be an integer"
mut_sed 'rule 1: turns 2^53+1' 's/"turns": 20$/"turns": 9007199254740993/' "rule 1: .*turns must be an integer"
mut_sed 'rule 1: turns 2^53-1' 's/"turns": 20$/"turns": 9007199254740991/' "rule 1: .*turns must be an integer"
mut_sed 'rule 1: turns with 400 digits' "s/\"turns\": 20\$/\"turns\": 1$(printf '0%.0s' $(seq 1 399))/" "rule 1: .*turns must be an integer"
mut_pass 'summary_budget_tokens 1000000 passes' '.summary_budget_tokens = 1000000'
mut 'rule 9: summary_budget_tokens 1000001' '.summary_budget_tokens = 1000001' "rule 9: summary_budget_tokens"
mut_sed 'rule 9: summary_budget_tokens 2^53+1' 's/"summary_budget_tokens": 200/"summary_budget_tokens": 9007199254740993/' "rule 9: summary_budget_tokens"
mut_sed 'rule 9: summary_budget_tokens 2^53-1' 's/"summary_budget_tokens": 200/"summary_budget_tokens": 9007199254740991/' "rule 9: summary_budget_tokens"
mut_sed 'rule 9: format_version 2^53+1' 's/"format_version": 1/"format_version": 9007199254740993/' "rule 9: format_version"

# schema/examples are valid JSON
for f in "$EX"/*.json "$ROOT/docs/spec/plan.schema.json"; do
  if jq empty "$f" 2>/dev/null; then ok "valid JSON: ${f#"$ROOT"/}"; else bad "valid JSON: ${f#"$ROOT"/}"; fi
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
