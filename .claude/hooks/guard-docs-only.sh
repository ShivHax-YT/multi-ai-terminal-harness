#!/usr/bin/env bash
# PreToolUse hook scoped to the `docs` subagent (Haiku): it may only write Markdown files. Exit 2 blocks.
set -u
command -v jq >/dev/null 2>&1 || { echo "BLOCKED: jq is required by guard-docs-only.sh" >&2; exit 2; }
input="$(cat)"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty')"
[ -z "$path" ] && exit 0
case "$path" in
  *.md|*.mdx|*.markdown) ;;
  *) echo "BLOCKED: the docs agent may only edit Markdown files (got: $path). Report the needed code/doc-comment change to the lead instead." >&2; exit 2 ;;
esac
case "$path" in
  *docs/HARD_RULES.md) echo "BLOCKED: only the human edits docs/HARD_RULES.md." >&2; exit 2 ;;
esac
exit 0
