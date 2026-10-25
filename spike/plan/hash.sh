#!/bin/bash
# Plan hashing and approval-binding helper (T-005, docs/spec/plan.md).
#
#   hash.sh FILE                          print the plan hash: sha256 of `jq -S -c 'del(.approval)'`
#   hash.sh --check FILE                  pre-approval check (the UI warning): exit 1 on any violation
#   hash.sh --check --require-approval FILE
#                                         scheduler check: also rejects a plan with no approval (rule 9)
#   hash.sh --approve FILE                SPIKE TEST FIXTURE ONLY, see below
#
# Exit codes for --check: 0 = plan passes, 1 = rejected (violation lines on stdout), 2 = usage error.
# Any checker failure (bad JSON, jq error) is also a rejection: fail closed, never "empty output means ok".
#
# The source file is read ONCE into a private temp copy; everything (single-document test, hash, checks) uses that
# copy, so the bytes that are hashed are the bytes that are checked. The file must hold exactly one JSON document.
#
# Offline: needs only jq and shasum.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLAN="$WORK/plan.json"

usage() {
  echo "usage: hash.sh FILE | --check [--require-approval] FILE | --approve FILE" >&2
  exit 2
}

# load_plan FILE: single read of FILE into $PLAN, then require exactly one JSON document that is an object.
# (`jq -e 'type == "object"'` without -s only tests the LAST of several concatenated documents.)
load_plan() {
  cat "$1" > "$PLAN" 2>/dev/null || { echo "rule 9: cannot read plan file"; return 1; }
  if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$PLAN" >/dev/null 2>&1; then
    echo "rule 9: plan file must contain exactly one JSON document, and it must be an object"
    return 1
  fi
}

plan_hash() {
  jq -S -c 'del(.approval)' "$PLAN" | shasum -a 256 | cut -d' ' -f1
}

check_plan() {
  local file="$1" require="$2" hash out rc=0
  load_plan "$file" || return 1
  hash="$(plan_hash)" || { echo "rule 9: could not hash plan"; return 1; }
  out="$(jq -r --arg hash "$hash" --argjson require_approval "$require" -f "$HERE/check.jq" "$PLAN")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "rule 9: checker failed (jq exit $rc); plan rejected"
    return 1
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 1
  fi
  return 0
}

case "${1:-}" in
  --check)
    shift
    require=false
    if [ "${1:-}" = "--require-approval" ]; then
      require=true
      shift
    fi
    [ $# -eq 1 ] || usage
    check_plan "$1" "$require" || exit 1
    ;;
  --approve)
    # SPIKE TEST FIXTURE ONLY. This mints an approval token with approved_via "ui" from any shell, which is exactly
    # what the app must never allow (rule 9). It exists so the tests can build approved plans. It must not be ported
    # to the app: there, only a UI click handler creates a token, signed with a per-install Keychain key.
    [ $# -eq 2 ] || usage
    load_plan "$2" >&2 || exit 1
    nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    jq --arg h "$(plan_hash)" --arg n "$nonce" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.approval = {plan_hash: $h, approved_at: $t, approved_via: "ui", nonce: $n}' "$PLAN"
    ;;
  ""|-h|--help)
    usage
    ;;
  *)
    [ $# -eq 1 ] || usage
    load_plan "$1" >&2 || exit 1
    plan_hash
    ;;
esac
