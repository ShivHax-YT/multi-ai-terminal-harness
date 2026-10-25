#!/usr/bin/env bash
# PreToolUse hook for Bash.
# Blocks (exit 2): access to provider CLI credential stores or the Keychain (rule 4), config-home overrides that
# would enable a second account (rule 2), and destructive git/rm commands.
set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HOOK_DIR/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "guard-bash.sh: jq is required (brew install jq)" >&2; exit 2; }

cmd="$(jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0

has() { printf '%s' "$cmd" | grep -Eq -- "$1"; }

# Rule 4: credential stores and Keychain.
if has '(^|[^A-Za-z0-9_])\.(codex|grok|gemini|kimi-code|kimi)(/|[^A-Za-z0-9_-]|$)'; then
  block "shell command references a provider CLI home directory"
fi
if has '\.claude/\.credentials|\.claude\.json|oauth_creds\.json'; then
  block "shell command references a provider credential file"
fi
if has '(^|[^A-Za-z0-9_])security[[:space:]]+(find-generic-password|find-internet-password|dump-keychain|export|unlock-keychain)'; then
  block "shell command queries the macOS Keychain"
fi

# Rule 2: no alternate config homes (would allow a second account per provider).
if has '(^|[^A-Za-z0-9_])(CLAUDE_CONFIG_DIR|CODEX_HOME|GROK_HOME|KIMI_CODE_HOME)[[:space:]]*='; then
  echo "BLOCKED by hard rule 2 hook: setting a provider config-home override enables multiple accounts. See docs/HARD_RULES.md." >&2
  exit 2
fi

# Destructive commands: ask the human instead.
if has 'git[[:space:]]+push([[:space:]].*)?[[:space:]](-f|--force|--force-with-lease)([[:space:]]|$)' \
   || has 'git[[:space:]]+reset[[:space:]]+--hard' \
   || has 'rm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f?[A-Za-z]*[[:space:]]+(/|~|\$HOME|\$\{HOME\})([[:space:]]|/?$)'; then
  echo "BLOCKED: destructive command. Ask the human to run it if it is really needed." >&2
  exit 2
fi
exit 0
