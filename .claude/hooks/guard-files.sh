#!/usr/bin/env bash
# PreToolUse hook for Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob.
# Blocks (exit 2) any file tool call that touches a provider CLI credential store (hard rule 4).
set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HOOK_DIR/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "guard-files.sh: jq is required (brew install jq)" >&2; exit 2; }

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"
[ -n "$cwd" ] || cwd="$PWD"

check_one() {
  local raw="$1" abs
  [ -n "$raw" ] || return 0
  abs="$(normalize_path "$raw" "$cwd")"
  if is_cred_path "$abs"; then
    block "$tool on $raw"
  fi
}

# Path-bearing fields across the file tools.
while IFS= read -r p; do
  check_one "$p"
done < <(jq -r '.tool_input | (.file_path, .path, .notebook_path) // empty | select(type=="string")' <<<"$input")

# Glob/Grep: the pattern itself may point into a store (e.g. "~/.codex/**"), and a search rooted at $HOME
# or above would sweep the stores.
pattern="$(jq -r '.tool_input.pattern // .tool_input.glob // empty' <<<"$input")"
if [ "$tool" = "Glob" ] && [ -n "$pattern" ]; then
  root="$(jq -r '.tool_input.path // empty' <<<"$input")"
  [ -n "$root" ] || root="$cwd"
  case "$pattern" in
    /*|"~"*) check_one "${pattern%%[\*\?\[]*}" ;;
    *)       check_one "$(normalize_path "$root" "$cwd")/${pattern%%[\*\?\[]*}" ;;
  esac
  if printf '%s' "$pattern" | grep -Eq '(^|/)\.(codex|grok|gemini|kimi-code|kimi)(/|$)|\.claude/\.credentials|\.claude\.json'; then
    block "Glob pattern $pattern"
  fi
fi
if [ "$tool" = "Grep" ] || [ "$tool" = "Glob" ]; then
  root="$(jq -r '.tool_input.path // empty' <<<"$input")"
  if [ -n "$root" ]; then
    abs_root="$(normalize_path "$root" "$cwd")"
    if is_home_or_ancestor "$abs_root"; then
      block "$tool rooted at $root would search provider credential stores; search inside the repo instead"
    fi
  fi
fi
exit 0
