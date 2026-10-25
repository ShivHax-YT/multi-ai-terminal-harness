# Offline plan checker (T-005). Usage:
#   jq -r --arg hash "$(spike/plan/hash.sh plan.json)" --argjson require_approval false \
#      -f spike/plan/check.jq plan.json
# Prints one line per violation, each starting with the hard-rule number. No output = plan passes.
#
# Callers MUST NOT trust empty output alone: check the jq exit code too and treat any non-zero exit as a rejection
# (fail closed). This program is written to never crash on malformed input, but a parse error in the input file or a jq
# failure still produces empty stdout with a non-zero exit. `spike/plan/hash.sh --check` does both and exits 1 on any
# violation or checker failure.
#
#   require_approval=false  pre-approval mode: the UI warns before the user approves. A missing approval is fine.
#   require_approval=true   scheduler mode: a plan without a valid approval bound to the hash is rejected (rule 9).
#
# Structure: (1) strict shape/type validation runs first, before any default value is applied, so a wrong type is a
# violation and never silently becomes 0 or []. (2) Only a well-shaped plan reaches the rule checks.
#
# Ceilings are copied from docs/HARD_RULES.md rule 1 for the spike only. In the app they are compile-time constants
# in one module.

def max_turns_per_task: 40;
def max_prompts_per_subscription_provider: 30;

# Exact, lowercase, no whitespace. "Gemini" and "gemini " are NOT providers.
def providers: ["claude", "codex", "grok", "kimi", "gemini", "glm"];
def auth_modes: ["subscription", "api_key"];

def one_of($list): . as $v | any($list[]; . == $v);
def is_provider: type == "string" and one_of(providers);
def is_count: type == "number" and . >= 0 and . == floor;

# ---- (1) shape validation. Input: the plan (an object). Output: array of violation lines. -----------------------

def task_shape_errors($i):
  if type != "object" then ["rule 9: tasks[\($i)] is not an object"]
  else
    [ (if (.id | type) != "string" or .id == "" then "rule 9: tasks[\($i)] has a missing or non-string id" else empty end),
      (if (.provider | is_provider | not)
       then "rule 7: tasks[\($i)] provider must be exactly one of claude|codex|grok|kimi|gemini|glm"
       else empty end),
      (if (.auth_mode | one_of(auth_modes) | not)
       then "rule 7: tasks[\($i)] auth_mode must be exactly subscription or api_key"
       else empty end),
      (if (.fallback_providers | type) != "array"
       then "rule 2: tasks[\($i)] fallback_providers must be an array"
       elif (.fallback_providers | all(.[]; is_provider) | not)
       then "rule 2: tasks[\($i)] fallback_providers must contain only exact provider names"
       else empty end),
      (if (.depends_on | type) != "array" or (.depends_on | all(.[]; type == "string") | not)
       then "rule 9: tasks[\($i)] depends_on must be an array of strings"
       else empty end),
      (if (.estimated_usage | type) != "object"
       then "rule 1: tasks[\($i)] estimated_usage must be an object with prompts and turns"
       else
         (if (.estimated_usage.turns | is_count | not)
          then "rule 1: tasks[\($i)] estimated_usage.turns must be an integer >= 0" else empty end),
         (if (.estimated_usage.prompts | is_count | not)
          then "rule 1: tasks[\($i)] estimated_usage.prompts must be an integer >= 0" else empty end)
       end)
    ]
  end;

def approval_shape_errors:
  if (.approval // null) == null then []
  elif (.approval | type) != "object" then ["rule 9: approval must be an object"]
  else
    [ ("plan_hash", "approved_at", "approved_via", "nonce") as $k
      | select((.approval[$k] | type) != "string")
      | "rule 9: approval.\($k) must be a string" ]
  end;

def shape_errors:
  [ (if (.lead | type) != "object" or (.lead.provider | is_provider | not)
     then "rule 7: lead.provider must be exactly one of claude|codex|grok|kimi|gemini|glm"
     else empty end),
    (if (.tasks | type) != "array" or (.tasks | length) == 0
     then "rule 9: tasks must be a non-empty array"
     else
       ( .tasks | to_entries[] | .key as $i | .value | task_shape_errors($i) | .[] ),
       ( [ .tasks[] | select(type == "object") | .id | select(type == "string") ]
         | group_by(.)[] | select(length > 1)
         | "rule 9: duplicate task id \(.[0])" )
     end),
    approval_shape_errors[]
  ];

# ---- (2) rule checks. Input: a plan that passed shape_errors. ----------------------------------------------------

def rule_errors:
  .tasks as $tasks
  | ($tasks | map(.provider)) as $used
  | [
      # Rule 2: a fallback is never the task's own provider, and never repeats (exact names, so no case variants).
      ( $tasks[] | . as $t | $t.fallback_providers as $fb
        | ( if any($fb[]; . == $t.provider)
            then "rule 2: task \($t.id) lists its own provider \($t.provider) as a fallback"
            else empty end ),
          ( $fb | group_by(.)[] | select(length > 1)
            | "rule 2: task \($t.id) repeats fallback provider \(.[0])" ) ),

      # Rule 9: failover only to providers listed in the plan, so a fallback must be used by some task.
      ( $tasks[] | . as $t | $t.fallback_providers[]
        | select(. as $p | any($used[]; . == $p) | not)
        | "rule 9: task \($t.id) fallback provider \(.) is not used by any task in the plan" ),

      # Rule 7: Gemini on API key only.
      ( $tasks[] | select(.provider == "gemini" and .auth_mode != "api_key")
        | "rule 7: task \(.id) uses gemini with auth_mode \(.auth_mode); gemini is api_key only" ),

      # Rule 1: per-task turn ceiling.
      ( $tasks[] | select(.estimated_usage.turns > max_turns_per_task)
        | "rule 1: task \(.id) estimates \(.estimated_usage.turns) turns, ceiling is \(max_turns_per_task)" ),

      # Rule 1: summed prompts per provider for everything that is not api_key (fail closed: anything not exactly
      # "api_key" counts as subscription).
      ( $tasks | map(select(.auth_mode != "api_key")) | group_by(.provider)[]
        | { p: .[0].provider, n: (map(.estimated_usage.prompts) | add) }
        | select(.n > max_prompts_per_subscription_provider)
        | "rule 1: subscription provider \(.p) plan estimates \(.n) prompts, ceiling is \(max_prompts_per_subscription_provider)" ),

      # Rule 9: an approval must be a UI approval bound to the hash of exactly this plan.
      ( if (.approval // null) == null then empty
        else
          ( if .approval.plan_hash != ($ARGS.named.hash // "")
            then "rule 9: approval plan_hash \(.approval.plan_hash) does not match computed plan hash \($ARGS.named.hash // "(none)"); plan was edited after approval"
            else empty end ),
          ( if .approval.approved_via != "ui"
            then "rule 9: approval approved_via must be \"ui\""
            else empty end )
        end )
    ];

def main:
  if type != "object" then ["rule 9: plan must be a JSON object"]
  else
    shape_errors as $shape
    | (if ($shape | length) == 0 then rule_errors else [] end) as $rules
    | (if ($ARGS.named.require_approval == true) and ((.approval // null) == null)
       then ["rule 9: plan has no approval"] else [] end) as $req
    | $shape + $rules + $req
  end;

main | .[]
