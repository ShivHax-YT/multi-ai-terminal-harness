#!/usr/bin/env bash
# Shared helpers for the hook scripts. Sourced, not executed.
# Hard rule 4: provider CLI credential stores are off limits to every agent and to app code.

# Directories under $HOME that belong to provider CLIs (credentials, sessions, tokens).
# shellcheck disable=SC2034  # used by scripts that source this file
CRED_DIRS=(".claude/.credentials.json" ".claude.json" ".codex" ".grok" ".gemini" ".kimi-code" ".kimi")

# Normalize a path: expand ~, make absolute against $2 (cwd), collapse /./ and /../ segments.
normalize_path() {
  local p="$1" cwd="${2:-$PWD}"
  p="${p//\\//}"                       # Windows separators -> /
  # shellcheck disable=SC2088  # matching a literal "~/" prefix on purpose
  case "$p" in
    "~")    p="$HOME" ;;
    "~/"*)  p="$HOME/${p#\~/}" ;;
    /*)     ;;
    *)      p="$cwd/$p" ;;
  esac
  local IFS='/' part out=()
  read -r -a parts <<<"$p"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|".") ;;
      "..")   [ "${#out[@]}" -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
      *)      out+=("$part") ;;
    esac
  done
  local joined
  joined="$(printf '/%s' "${out[@]}")"
  printf '%s\n' "${joined:-/}"
}

# Return 0 if the (absolute, normalized) path is inside a provider credential store.
is_cred_path() {
  local p="$1" d
  for d in "${CRED_DIRS[@]}"; do
    if [ "$p" = "$HOME/$d" ] || [[ "$p" == "$HOME/$d/"* ]]; then
      return 0
    fi
  done
  # Same stores for any user home, in case HOME differs (e.g. /Users/x or /home/x).
  if printf '%s' "$p" | grep -Eq '^/(Users|home)/[^/]+/(\.claude/\.credentials\.json|\.claude\.json|\.(codex|grok|gemini|kimi-code|kimi)(/|$))'; then
    return 0
  fi
  return 1
}

# Return 0 if the path is $HOME itself or an ancestor of it (a search root that would sweep the stores).
is_home_or_ancestor() {
  local p="$1"
  [ "$p" = "/" ] && return 0
  [ "$p" = "$HOME" ] && return 0
  [[ "$HOME" == "$p/"* ]] && return 0
  return 1
}

block() {
  echo "BLOCKED by hard rule 4 hook: $1" >&2
  echo "Provider CLI credential stores (~/.claude credentials, ~/.claude.json, ~/.codex, ~/.grok, ~/.gemini, ~/.kimi-code, ~/.kimi) and the macOS Keychain are off limits. See docs/HARD_RULES.md. Ask the human if you think you need this." >&2
  exit 2
}
