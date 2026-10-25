#!/usr/bin/env bash
# SessionStart hook: stdout becomes context Claude sees at the start of every session.
cat <<'TXT'
Project reminder: this repo builds the Multi-AI Terminal Harness. docs/HARD_RULES.md has 12 non-negotiable rules.
Key ones: never read provider CLI credential stores (~/.claude credentials, ~/.claude.json, ~/.codex, ~/.grok,
~/.gemini, ~/.kimi-code) or the Keychain; automation only via documented headless/ACP modes, never typing into a TUI;
compiled-in usage ceilings and plan approval; official unmodified CLIs only; Gemini API key only; no provider logos.
Workflow: brief in docs/tasks/ -> human approval -> worktree -> make check-fast -> HANDOFF.md -> reviewer +
compliance-auditor + /xreview -> human merges.
TXT
if grep -q 'TODO (HUMAN MUST CHOOSE' "${CLAUDE_PROJECT_DIR:-.}/CLAUDE.md" 2>/dev/null; then
  echo "Stack decision (Tauri 2 vs Swift) is still open: do not scaffold app code until docs/adr/0001-stack.md exists."
fi
exit 0
