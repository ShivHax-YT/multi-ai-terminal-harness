#!/usr/bin/env bash
# Stop hook: runs `make check-fast` in the directory Claude is working in (the worktree, if any).
# Exit 2 sends Claude back to fix failures. stop_hook_active prevents an endless loop.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
[ "$(jq -r '.stop_hook_active // false' <<<"$input")" = "true" ] && exit 0

dir="$(jq -r '.cwd // empty' <<<"$input")"
[ -n "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$PWD}"
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")"
cd "$root" || exit 0

# Skip if nothing changed in this checkout (pure Q&A turns).
if git rev-parse --git-dir >/dev/null 2>&1 && [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  exit 0
fi

if [ -f Makefile ] && grep -q '^check-fast:' Makefile; then
  if ! out="$(make -s check-fast 2>&1)"; then
    echo "make check-fast failed. Fix it before you stop:" >&2
    printf '%s\n' "$out" | tail -40 >&2
    exit 2
  fi
elif [ -x scripts/ci/compliance-scan.sh ]; then
  if ! out="$(scripts/ci/compliance-scan.sh 2>&1)"; then
    echo "Compliance scan failed. Fix it before you stop:" >&2
    printf '%s\n' "$out" | tail -40 >&2
    exit 2
  fi
fi
exit 0
