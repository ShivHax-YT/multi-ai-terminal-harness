#!/usr/bin/env bash
# Hard-rule static compliance scan (docs/HARD_RULES.md). Exit 0 = clean, 1 = violations, 2 = usage error.
#
#   scripts/ci/compliance-scan.sh                     # scan the whole repo
#   scripts/ci/compliance-scan.sh --root DIR          # scan another checkout (used by the self-test)
#   scripts/ci/compliance-scan.sh --files a.rs b.ts   # scan only these files (used by the PostToolUse hook)
#
# Checks:
#   R4  credential-store paths and Keychain queries in app code
#   R2  provider config-home overrides (second-account enablers)
#   R6  bundled provider CLIs (npm deps, Tauri externalBin, binaries committed to the repo)
#   R8  provider logos / trademark-named image assets; trademarks in app name or bundle ID
#   R3  PTY write symbols referenced from scheduler/lead code (configurable in compliance/pty-boundary.conf)
#
# Paths where these strings are allowed to appear (rules docs, hooks, this scanner, its self-test, the runtime denylist):
#   docs/ .claude/ scripts/ci/ tests/compliance/ compliance/ .github/ AGENTS.md CLAUDE.md README.md
set -uo pipefail

ROOT=""
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)  ROOT="$2"; shift 2 ;;
    --files) shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do FILES+=("$1"); shift; done ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
ROOT="$(cd "$ROOT" && pwd)" || { echo "bad --root" >&2; exit 2; }
cd "$ROOT" || exit 2

# ---- file list (paths relative to ROOT) --------------------------------------------------------------------------
list_files() {
  if [ "${#FILES[@]}" -gt 0 ]; then
    local f
    for f in "${FILES[@]}"; do
      case "$f" in "$ROOT"/*) f="${f#"$ROOT"/}" ;; esac
      [ -f "$f" ] && printf '%s\n' "$f"
    done
  elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -co --exclude-standard
  else
    find . -type f \
      -not -path './.git/*' -not -path '*/node_modules/*' -not -path '*/target/*' \
      -not -path './.claude/worktrees/*' -not -path './.build/*' | sed 's|^\./||'
  fi
}

ALLOW_RE='^(docs/|\.claude/|scripts/ci/|tests/compliance/|compliance/|\.github/|AGENTS\.md$|CLAUDE\.md$|README\.md$)'
TEXT_EXT_RE='\.(rs|ts|tsx|js|jsx|mjs|cjs|swift|m|mm|h|c|cc|cpp|py|pl|pm|sh|bash|zsh|toml|json|jsonl|jq|yaml|yml|plist|xml|html|css|md|txt|env|conf|ini)$'
IMG_EXT_RE='\.(png|jpe?g|gif|svg|webp|icns|ico|pdf|ai|eps|heic|tiff?)$'
BRAND_RE='(anthropic|claude|openai|chatgpt|codex|gpt|xai|grok|gemini|google|moonshot|kimi|zhipu|z-ai|zai|glm)'

CRED_RE='(^|[^A-Za-z0-9_])\.(codex|grok|gemini|kimi-code|kimi)(/|"|'"'"'|$)|\.claude/\.credentials|\.claude\.json|oauth_creds\.json|Claude Code-credentials'
KEYCHAIN_RE='security[[:space:]]+(find-generic-password|find-internet-password|dump-keychain|export)'
CONFIG_HOME_RE='(CLAUDE_CONFIG_DIR|CODEX_HOME|GROK_HOME|KIMI_CODE_HOME)'
NPM_CLI_RE='"(@anthropic-ai/claude-code|@openai/codex|@google/gemini-cli)"[[:space:]]*:'
CLI_NAMES_RE='^(claude|codex|grok|gemini|kimi)(\.exe)?$'

PTY_SYMBOLS_RE='(pty_write|write_to_pty|PtyWriter|ptyWrite|writeToPty)'
PTY_DIRS_RE='(^|/)(scheduler|lead|orchestrator)(/|\.)'
if [ -f compliance/pty-boundary.conf ]; then
  # shellcheck disable=SC1091
  . compliance/pty-boundary.conf
fi

violations=0
report() { echo "$1"; violations=$((violations + 1)); }

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  lower="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"

  # R8: trademark-named images anywhere in the repo (no allowlist).
  if printf '%s' "$lower" | grep -Eq "$IMG_EXT_RE" && printf '%s' "$(basename "$lower")" | grep -Eq "$BRAND_RE"; then
    report "RULE 8 (logos): $f: image asset named after a provider"
  fi

  # R6: provider CLI binaries committed to the repo.
  if printf '%s' "$base" | grep -Eq "$CLI_NAMES_RE"; then
    if [ -x "$f" ] || ! grep -Iq . "$f" 2>/dev/null; then
      report "RULE 6 (bundling): $f: looks like a provider CLI binary committed to the repo"
    fi
  fi

  if printf '%s' "$f" | grep -Eq "$ALLOW_RE"; then
    continue
  fi
  printf '%s' "$lower" | grep -Eq "$TEXT_EXT_RE" || [ "$base" = "Makefile" ] || [ "$base" = "Dockerfile" ] || continue

  # R4: credential stores / Keychain.
  while IFS= read -r hit; do report "RULE 4 (credentials): $f:$hit"; done < <(grep -nE "$CRED_RE" "$f" 2>/dev/null | cut -c1-200)
  while IFS= read -r hit; do report "RULE 4 (keychain): $f:$hit"; done < <(grep -nE "$KEYCHAIN_RE" "$f" 2>/dev/null | cut -c1-200)

  # R2: config-home overrides.
  while IFS= read -r hit; do report "RULE 2 (config home): $f:$hit"; done < <(grep -nE "$CONFIG_HOME_RE" "$f" 2>/dev/null | cut -c1-200)

  # R6: bundled CLIs via package manifests or Tauri sidecars.
  if [ "$base" = "package.json" ]; then
    while IFS= read -r hit; do report "RULE 6 (bundling): $f:$hit (users install provider CLIs themselves)"; done < <(grep -nE "$NPM_CLI_RE" "$f" | cut -c1-200)
  fi
  if printf '%s' "$base" | grep -Eq '^tauri(\..+)?\.conf\.json$'; then
    while IFS= read -r hit; do report "RULE 6 (bundling): $f:$hit (no provider CLI sidecars)"; done < <(grep -nEi "externalBin.*$BRAND_RE|\"[^\"]*/(claude|codex|grok|gemini|kimi)\"" "$f" | cut -c1-200)
    # R8: product name / identifier.
    while IFS= read -r hit; do report "RULE 8 (trademark): $f:$hit"; done < <(grep -nEi "\"(productName|identifier|mainBinaryName)\"[[:space:]]*:[[:space:]]*\"[^\"]*$BRAND_RE" "$f" | cut -c1-200)
  fi
  if [ "$base" = "Info.plist" ]; then
    while IFS= read -r hit; do report "RULE 8 (trademark): $f:$hit"; done < <(grep -nEi -A1 'CFBundle(Name|DisplayName|Identifier)' "$f" | grep -Ei "<string>[^<]*$BRAND_RE" | cut -c1-200)
  fi

  # R3: scheduler/lead code must not reference PTY write functions.
  if printf '%s' "$f" | grep -Eq "$PTY_DIRS_RE"; then
    while IFS= read -r hit; do report "RULE 3 (PTY boundary): $f:$hit"; done < <(grep -nE "$PTY_SYMBOLS_RE" "$f" | cut -c1-200)
  fi
done < <(list_files)

if [ "$violations" -gt 0 ]; then
  echo "compliance-scan: $violations violation(s). See docs/HARD_RULES.md. Do not weaken this scan; fix the code." >&2
  exit 1
fi
echo "compliance-scan: clean"
exit 0
