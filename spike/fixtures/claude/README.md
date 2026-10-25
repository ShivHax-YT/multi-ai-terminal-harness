# Claude fixtures

Hand-written from the official Claude Code docs (no live capture, no real account data). See `spike/claude/EVENTS.md`.

- `sample.jsonl`: a normal run (init, status, one retry, a usage warning, a Write tool call, result success).
- `limits.jsonl`: limit and error shapes (retry on 429, rejected rate-limit events, permission denial, assistant error, error_max_turns).
- `observed.jsonl`: NOT YET PRESENT. After the human's live run, add the `spike_redact` output of the real capture here, reviewed by the human before commit.

Rule: no at-sign and no macOS user-home path in any fixture (`spike/tests/test_claude_parse.sh` greps for both).
