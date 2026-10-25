# Offline plan checker (T-005). Usage:
#   jq -r --arg hash "$(spike/plan/hash.sh plan.json)" -f spike/plan/check.jq plan.json
# Prints one line per violation, each starting with the hard-rule number. No output = plan passes.
# `spike/plan/hash.sh --check plan.json` wraps this and exits 1 on any violation.
#
# Ceilings are copied from docs/HARD_RULES.md rule 1 for the spike only. In the app they are
# compile-time constants in one module.

def max_turns_per_task: 40;
def max_prompts_per_subscription_provider: 30;

(.tasks // []) as $tasks
| ($tasks | map(.provider)) as $used
| [
    # Rule 2: a fallback is never the task's own provider, and never repeats.
    ( $tasks[] | . as $t | ($t.fallback_providers // []) as $fb
      | ( if any($fb[]; . == $t.provider)
          then "rule 2: task \($t.id) lists its own provider \($t.provider) as a fallback"
          else empty end ),
        ( $fb | group_by(.)[] | select(length > 1)
          | "rule 2: task \($t.id) repeats fallback provider \(.[0])" ) ),

    # Rule 9: failover only to providers listed in the plan, so a fallback must be used by some task.
    ( $tasks[] | . as $t | ($t.fallback_providers // [])[]
      | select(. as $p | ($used | index($p)) == null)
      | "rule 9: task \($t.id) fallback provider \(.) is not used by any task in the plan" ),

    # Rule 7: Gemini on API key only.
    ( $tasks[] | select(.provider == "gemini" and .auth_mode != "api_key")
      | "rule 7: task \(.id) uses gemini with auth_mode \(.auth_mode // "missing"); gemini is api_key only" ),

    # Rule 1: per-task turn ceiling.
    ( $tasks[] | select((.estimated_usage.turns // 0) > max_turns_per_task)
      | "rule 1: task \(.id) estimates \(.estimated_usage.turns) turns, ceiling is \(max_turns_per_task)" ),

    # Rule 1: summed prompts per subscription provider.
    ( $tasks | map(select(.auth_mode == "subscription")) | group_by(.provider)[]
      | { p: .[0].provider, n: (map(.estimated_usage.prompts // 0) | add) }
      | select(.n > max_prompts_per_subscription_provider)
      | "rule 1: subscription provider \(.p) plan estimates \(.n) prompts, ceiling is \(max_prompts_per_subscription_provider)" ),

    # Rule 9: an approval must be a UI approval bound to the hash of exactly this plan.
    ( if (.approval // null) == null then empty
      else
        ( if .approval.plan_hash == null
          then "rule 9: approval has no plan_hash"
          elif .approval.plan_hash != ($ARGS.named.hash // "")
          then "rule 9: approval plan_hash \(.approval.plan_hash) does not match computed plan hash \($ARGS.named.hash // "(none)"); plan was edited after approval"
          else empty end ),
        ( if .approval.approved_via != "ui"
          then "rule 9: approval approved_via must be \"ui\""
          else empty end )
      end )
  ]
| .[]
