# Claude fixtures

Hand-written from the official Claude Code docs (no live capture, no real account data). See `spike/claude/EVENTS.md`.

- `sample.jsonl`: a normal run (init, status, one retry, a usage warning, a Write tool call, result success).
- `limits.jsonl`: limit and error shapes (retry on 429, rejected rate-limit events, permission denial, assistant error, error_max_turns).
- `observed.jsonl`: NOT YET PRESENT. After the human's live run, add the scrubbed and redacted capture here, reviewed by the human before commit:
  `jq -c -f spike/claude/scrub-init.jq raw.jsonl | spike_redact > observed.jsonl`. `scrub-init.jq` replaces the `system/init` lists of MCP servers,
  plugins, skills, slash commands, agents and tools (personal configuration) with `["<redacted>"]` plus a count; `spike_redact` then handles paths, e-mail addresses and ids.
  The test fails if an `observed.jsonl` still has real names in those lists.

Rule: no at-sign and no macOS user-home path in any fixture (`spike/tests/test_claude_parse.sh` greps for both).
