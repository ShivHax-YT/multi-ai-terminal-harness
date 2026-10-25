#!/bin/bash
# Plan hashing and approval-binding helper (T-005, docs/spec/plan.md).
#
#   hash.sh FILE            print the plan hash: sha256 of `jq -S -c 'del(.approval)'`
#   hash.sh --check FILE    run check.jq against FILE; print one line per violation; exit 1 if any
#   hash.sh --approve FILE  print FILE with an approval token bound to its current hash (spike only;
#                           in the app the token is signed with a per-install key and created by a UI click)
#
# Offline: needs only jq and shasum.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

plan_hash() {
  jq -S -c 'del(.approval)' "$1" | shasum -a 256 | cut -d' ' -f1
}

case "${1:-}" in
  --check)
    [ $# -eq 2 ] || { echo "usage: hash.sh --check FILE" >&2; exit 2; }
    out="$(jq -r --arg hash "$(plan_hash "$2")" -f "$HERE/check.jq" "$2")"
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      exit 1
    fi
    ;;
  --approve)
    [ $# -eq 2 ] || { echo "usage: hash.sh --approve FILE" >&2; exit 2; }
    nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    jq --arg h "$(plan_hash "$2")" --arg n "$nonce" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.approval = {plan_hash: $h, approved_at: $t, approved_via: "ui", nonce: $n}' "$2"
    ;;
  ""|-h|--help)
    sed -n '2,9p' "$0"
    [ -n "${1:-}" ] || exit 2
    ;;
  *)
    [ $# -eq 1 ] || { echo "usage: hash.sh FILE" >&2; exit 2; }
    plan_hash "$1"
    ;;
esac
