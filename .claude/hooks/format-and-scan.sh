#!/usr/bin/env bash
# PostToolUse hook for Edit|Write|MultiEdit.
# 1) Formats the edited file with whatever formatter is installed (never fails the edit for a missing formatter).
# 2) Runs the hard-rule compliance scan on that file; exit 2 shows the violation to Claude so it fixes it now.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
f="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
[ -n "$f" ] && [ -f "$f" ] || exit 0

case "$f" in
  *.rs)
    command -v rustfmt >/dev/null 2>&1 && rustfmt --edition 2021 "$f" >/dev/null 2>&1 ;;
  *.swift)
    command -v swift >/dev/null 2>&1 && swift format --in-place "$f" >/dev/null 2>&1 ;;
  *.ts|*.tsx|*.js|*.jsx|*.css|*.json|*.md)
    if [ -x "${CLAUDE_PROJECT_DIR:-.}/node_modules/.bin/prettier" ]; then
      "${CLAUDE_PROJECT_DIR:-.}/node_modules/.bin/prettier" --write --log-level warn "$f" >/dev/null 2>&1
    fi ;;
esac

root="${CLAUDE_PROJECT_DIR:-$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null || pwd)}"
# In a worktree, scan relative to the worktree root that contains the file.
wt_root="$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null || echo "$root")"
scan="$root/scripts/ci/compliance-scan.sh"
[ -x "$scan" ] || scan="$wt_root/scripts/ci/compliance-scan.sh"
[ -x "$scan" ] || exit 0

if ! out="$("$scan" --root "$wt_root" --files "$f" 2>&1)"; then
  echo "Compliance scan flagged the file you just edited. Fix it before continuing (docs/HARD_RULES.md):" >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
exit 0
