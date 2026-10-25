#!/usr/bin/env bash
# SubagentStop hook: append one line per finished subagent to .claude/subagents.jsonl (gitignored) so you can see which
# roles ran and how often. Hooks receive the subagent's name as agent_type. Never blocks.
command -v jq >/dev/null 2>&1 || exit 0
log="${CLAUDE_PROJECT_DIR:-.}/.claude/subagents.jsonl"
jq -c '{t: (now | todate), agent: .agent_type, agent_id: .agent_id, session: .session_id}' >> "$log" 2>/dev/null
exit 0
