# Offline plan checker (T-005). Usage:
#   jq -r --arg hash "$(spike/plan/hash.sh plan.json)" --argjson require_approval false \
#      -f spike/plan/check.jq plan.json
# Prints one line per violation, each starting with the hard-rule number. No output = plan passes.
#
# Callers MUST NOT trust empty output alone: check the jq exit code too and treat any non-zero exit as a rejection
# (fail closed). This program is written to never crash on malformed input, but a parse error in the input file or a jq
# failure still produces empty stdout with a non-zero exit. The input must be exactly ONE JSON document; this program
# cannot see that (jq streams concatenated documents through it one by one), so `spike/plan/hash.sh --check` verifies
# it first, validates from a single private copy of the file, and exits 1 on any violation or checker failure.
#
#   require_approval=false  pre-approval mode: the UI warns before the user approves. A missing approval is fine.
#   require_approval=true   scheduler mode: a plan without a valid approval bound to the hash is rejected (rule 9).
#
# Structure: (1) strict shape/type validation, matching docs/spec/plan.schema.json exactly (allowed keys, types,
# patterns), runs first and before any default value is applied; a wrong type is a violation and never silently
# becomes 0 or []. Defaults are never filled in: every field is required. (2) Only a well-shaped plan reaches the
# rule checks.
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
def is_auth_mode: type == "string" and one_of(auth_modes);
def is_nonempty_str: type == "string" and length > 0;
def is_str_array: type == "array" and all(.[]; type == "string");
# Canonical integer text only: jq 1.7 keeps number literals, so 20.0 and 1e1 would otherwise hash differently from 20.
# The regex also rejects negatives and "-0". \A..\z (not ^..$) so a trailing newline cannot slip through.
# Every integer is also capped at 2^53-1 (the largest integer a double holds exactly), by text length and by value, so
# no consumer parsing numbers as doubles can see a different value. Estimates and the summary budget are capped lower.
def max_safe_int: 9007199254740991;
def max_estimate: 1000000;
def is_count: type == "number" and (tojson | length <= 16 and test("\\A(0|[1-9][0-9]*)\\z")) and . <= max_safe_int;
def is_count_max($max): is_count and . <= $max;
def is_pos_count_max($max): is_count_max($max) and . > 0;

def days_in_month($y; $m):
  if $m == 2 then (if ($y % 4 == 0 and $y % 100 != 0) or $y % 400 == 0 then 29 else 28 end)
  elif $m == 4 or $m == 6 or $m == 9 or $m == 11 then 30
  else 31 end;
def ts_re:
  "\\A(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(?:\\.[0-9]+)?(?:Z|[+-](?<oh>[0-9]{2}):(?<om>[0-9]{2}))\\z";
# RFC 3339 text with real ranges: month 01-12, day valid for the month (leap years), hour 00-23, minute 00-59,
# second 00-60 (leap second), offset hours 00-23 and minutes 00-59.
def is_rfc3339:
  type == "string"
  and test(ts_re)
  and ( capture(ts_re)
        | (.y | tonumber) as $y | (.mo | tonumber) as $mo
        | $mo >= 1 and $mo <= 12
          and (.d | tonumber) >= 1 and (.d | tonumber) <= days_in_month($y; $mo)
          and (.h | tonumber) <= 23 and (.mi | tonumber) <= 59 and (.s | tonumber) <= 60
          and (.oh == null or ((.oh | tonumber) <= 23 and (.om | tonumber) <= 59)) );
def has_approval: has("approval");   # the key is present; a present value must be an object (null is malformed)

def unknown_keys($where; $allowed):
  (keys - $allowed)[] | "rule 9: \($where) has unknown key \(.[0:40] | @json)";

# ---- (1) shape validation. Input: the plan (an object). Output: array of violation lines. -----------------------

def fallback_shape_errors($i; $j):
  if type != "object" then ["rule 2: tasks[\($i)].fallback_providers[\($j)] must be an object {provider, auth_mode}"]
  else
    [ unknown_keys("tasks[\($i)].fallback_providers[\($j)]"; ["provider", "auth_mode"]),
      (if (.provider | is_provider | not)
       then "rule 2: tasks[\($i)].fallback_providers[\($j)].provider must be exactly one of claude|codex|grok|kimi|gemini|glm"
       else empty end),
      (if (.auth_mode | is_auth_mode | not)
       then "rule 7: tasks[\($i)].fallback_providers[\($j)].auth_mode must be exactly subscription or api_key"
       else empty end) ]
  end;

def task_shape_errors($i):
  if type != "object" then ["rule 9: tasks[\($i)] is not an object"]
  else
    [ unknown_keys("tasks[\($i)]";
        ["id", "title", "role", "provider", "auth_mode", "owned_files", "acceptance", "depends_on",
         "estimated_usage", "fallback_providers"]),
      (if (.id | type) != "string" or (.id | test("\\A[A-Za-z0-9_-]+\\z") | not)
       then "rule 9: tasks[\($i)].id must be a string matching [A-Za-z0-9_-]+" else empty end),
      (if (.title | is_nonempty_str | not) then "rule 9: tasks[\($i)].title must be a non-empty string" else empty end),
      (if (.role | is_nonempty_str | not) then "rule 9: tasks[\($i)].role must be a non-empty string" else empty end),
      (if (.provider | is_provider | not)
       then "rule 7: tasks[\($i)] provider must be exactly one of claude|codex|grok|kimi|gemini|glm"
       else empty end),
      (if (.auth_mode | is_auth_mode | not)
       then "rule 7: tasks[\($i)] auth_mode must be exactly subscription or api_key"
       else empty end),
      (if (.owned_files | is_str_array | not) then "rule 9: tasks[\($i)].owned_files must be an array of strings" else empty end),
      (if (.acceptance | is_str_array | not) then "rule 9: tasks[\($i)].acceptance must be an array of strings" else empty end),
      (if (.depends_on | is_str_array | not) then "rule 9: tasks[\($i)].depends_on must be an array of strings" else empty end),
      (if (.fallback_providers | type) != "array"
       then "rule 2: tasks[\($i)] fallback_providers must be an array"
       else (.fallback_providers | to_entries[] | .key as $j | .value | fallback_shape_errors($i; $j)[]) end),
      (if (.estimated_usage | type) != "object"
       then "rule 1: tasks[\($i)] estimated_usage must be an object with prompts and turns"
       else
         (.estimated_usage | unknown_keys("tasks[\($i)].estimated_usage"; ["prompts", "turns"])),
         (if (.estimated_usage.turns | is_count_max(max_estimate) | not)
          then "rule 1: tasks[\($i)] estimated_usage.turns must be an integer from 0 to 1000000" else empty end),
         (if (.estimated_usage.prompts | is_count_max(max_estimate) | not)
          then "rule 1: tasks[\($i)] estimated_usage.prompts must be an integer from 0 to 1000000" else empty end)
       end)
    ]
  end;

# depends_on references: no duplicates, no self-dependency, no dangling ids. (Cycles are checked in rule_errors.)
def dep_shape_errors:
  [ .tasks[] | select(type == "object") | .id | select(type == "string") ] as $ids
  | .tasks | to_entries[] | .key as $i | .value
  | select(type == "object" and (.depends_on | type) == "array")
  | . as $t
  | [ $t.depends_on[] | select(type == "string") ] as $deps
  | ( $deps | group_by(.)[] | select(length > 1) | "rule 9: tasks[\($i)] depends_on lists \(.[0] | @json) more than once" ),
    ( $deps[] | select(. == $t.id) | "rule 9: tasks[\($i)] depends on itself" ),
    ( $deps[] | select(. != $t.id and (. as $d | any($ids[]; . == $d) | not))
      | "rule 9: tasks[\($i)] depends_on references unknown task \(. | @json)" );

def approval_shape_errors:
  if has_approval | not then []
  elif (.approval | type) != "object" then ["rule 9: approval must be an object"]
  else
    [ (.approval | unknown_keys("approval"; ["plan_hash", "approved_at", "approved_via", "nonce"])),
      (if (.approval.plan_hash | type) != "string" or (.approval.plan_hash | test("\\A[0-9a-f]{64}\\z") | not)
       then "rule 9: approval.plan_hash must be 64 lowercase hex characters" else empty end),
      (if (.approval.approved_at | is_rfc3339 | not)
       then "rule 9: approval.approved_at must be an RFC 3339 timestamp" else empty end),
      (if (.approval.approved_via | type) != "string" then "rule 9: approval.approved_via must be a string" else empty end),
      (if (.approval.nonce | type) != "string" or (.approval.nonce | length) < 16
       then "rule 9: approval.nonce must be a string of at least 16 characters" else empty end) ]
  end;

def lead_shape_errors:
  if (.lead | type) != "object" then ["rule 7: lead must be an object with provider and auth_mode"]
  else
    [ (.lead | unknown_keys("lead"; ["provider", "auth_mode"])),
      (if (.lead.provider | is_provider | not)
       then "rule 7: lead.provider must be exactly one of claude|codex|grok|kimi|gemini|glm" else empty end),
      (if (.lead.auth_mode | is_auth_mode | not)
       then "rule 7: lead.auth_mode must be exactly subscription or api_key" else empty end) ]
  end;

def shape_errors:
  [ unknown_keys("plan";
      ["format_version", "plan_id", "created_at", "lead", "request_summary", "summary_budget_tokens", "tasks",
       "approval"]),
    (if (.format_version | is_count | not) or .format_version != 1
     then "rule 9: format_version must be the integer 1" else empty end),
    (if (.plan_id | is_nonempty_str | not) then "rule 9: plan_id must be a non-empty string" else empty end),
    (if (.created_at | is_rfc3339 | not) then "rule 9: created_at must be an RFC 3339 timestamp" else empty end),
    (if (.request_summary | type) != "string" then "rule 9: request_summary must be a string" else empty end),
    (if (.summary_budget_tokens | is_pos_count_max(max_estimate) | not)
     then "rule 9: summary_budget_tokens is required and must be an integer from 1 to 1000000 (defaults are never filled in)"
     else empty end),
    lead_shape_errors[],
    (if (.tasks | type) != "array" or (.tasks | length) == 0
     then "rule 9: tasks must be a non-empty array"
     else
       ( .tasks | to_entries[] | .key as $i | .value | task_shape_errors($i)[] ),
       ( [ .tasks[] | select(type == "object") | .id | select(type == "string") ]
         | group_by(.)[] | select(length > 1)
         | "rule 9: duplicate task id \(.[0])" ),
       dep_shape_errors
     end),
    approval_shape_errors[]
  ];

# ---- (2) rule checks. Input: a plan that passed shape_errors. ----------------------------------------------------

# Tasks whose depends_on can never be satisfied (part of, or downstream of, a cycle). Kahn's algorithm.
def stuck_tasks:
  (.tasks | map({id: .id, deps: .depends_on})) as $g
  | (reduce range(0; $g | length) as $k ([];
       . as $done
       | ( $done + [ $g[] | select(.deps | all(.[]; . as $x | any($done[]; . == $x))) | .id ] ) | unique)) as $order
  | [ $g[] | .id | select(. as $i | any($order[]; . == $i) | not) ];

def rule_errors:
  .tasks as $tasks
  | ($tasks | map(.provider)) as $used
  | [
      # Rule 7: Gemini on API key only, for the lead too.
      ( if .lead.provider == "gemini" and .lead.auth_mode != "api_key"
        then "rule 7: lead uses gemini with auth_mode \(.lead.auth_mode); gemini is api_key only"
        else empty end ),

      # Rule 2: a fallback is never the task's own provider, and never repeats (exact names, so no case variants).
      ( $tasks[] | . as $t | $t.fallback_providers as $fb
        | ( if any($fb[]; .provider == $t.provider)
            then "rule 2: task \($t.id) lists its own provider \($t.provider) as a fallback"
            else empty end ),
          ( $fb | group_by(.provider)[] | select(length > 1)
            | "rule 2: task \($t.id) repeats fallback provider \(.[0].provider)" ) ),

      # Rule 9: failover only to providers listed in the plan, so a fallback must be used by some task.
      # (Which account/limits it may use is enforced by the live per-provider counters at dispatch, not here.)
      ( $tasks[] | . as $t | $t.fallback_providers[]
        | select(.provider as $p | any($used[]; . == $p) | not)
        | "rule 9: task \($t.id) fallback provider \(.provider) is not used by any task in the plan" ),

      # Rule 7: Gemini on API key only, for tasks and for each fallback.
      ( $tasks[] | select(.provider == "gemini" and .auth_mode != "api_key")
        | "rule 7: task \(.id) uses gemini with auth_mode \(.auth_mode); gemini is api_key only" ),
      ( $tasks[] | . as $t | $t.fallback_providers[] | select(.provider == "gemini" and .auth_mode != "api_key")
        | "rule 7: task \($t.id) has a gemini fallback with auth_mode \(.auth_mode); gemini is api_key only" ),

      # Rule 1: per-task turn ceiling.
      ( $tasks[] | select(.estimated_usage.turns > max_turns_per_task)
        | "rule 1: task \(.id) estimates \(.estimated_usage.turns) turns, ceiling is \(max_turns_per_task)" ),

      # Rule 1: summed prompts per provider for everything that is not api_key (fail closed: anything not exactly
      # "api_key" counts as subscription). Failover usage is enforced by live counters at dispatch, not by this estimate.
      ( $tasks | map(select(.auth_mode != "api_key")) | group_by(.provider)[]
        | { p: .[0].provider, n: (map(.estimated_usage.prompts) | add) }
        | select(.n > max_prompts_per_subscription_provider)
        | "rule 1: subscription provider \(.p) plan estimates \(.n) prompts, ceiling is \(max_prompts_per_subscription_provider)" ),

      # Rule 9: the scheduler needs a DAG.
      ( stuck_tasks | select(length > 0)
        | "rule 9: tasks blocked by a dependency cycle: \(join(", "))" ),

      # Rule 9: an approval must be a UI approval bound to the hash of exactly this plan.
      ( if has_approval | not then empty
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
    | (if ($ARGS.named.require_approval == true) and (has_approval | not)
       then ["rule 9: plan has no approval"] else [] end) as $req
    | $shape + $rules + $req
  end;

main | .[]
