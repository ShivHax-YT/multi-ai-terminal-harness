# HANDOFF T-006

## Summary
Defined the worker HANDOFF.md format (docs/spec/handoff.md) and spike/handoff/parse.sh, a bash 3.2 parser that fails closed.
File content is untrusted: no eval/source/expansion; one bounded read into a private copy; ASCII-only JSON output (jq -a).
Round 3: symlink inputs refused, exit 3 for internal errors, UTF-8 validated, wider invisible-character blocklist,
case-insensitive confidence (lowercased), 2000-byte lines, blank lines between bullets, NBSP counts as blank.
260 offline tests cover the brief cases plus every gate finding.

## Files changed
- docs/spec/handoff.md - format spec: exact parse rules, limits, character table, symlink and timeout notes, exit codes
- spike/handoff/parse.sh - parser, JSON on stdout; exit 1 invalid handoff, 2 usage or missing tool, 3 internal error
- spike/fixtures/handoff/good.md - valid handoff
- spike/fixtures/handoff/missing-section.md - lacks Tests run
- spike/fixtures/handoff/bad-confidence.md - level is "certain"
- spike/fixtures/handoff/injection.md - instruction-like text, command substitution and backtick payloads (__MARKER__ placeholder)
- spike/tests/test_handoff.sh - 260 offline checks (oversize files generated at test time)
- HANDOFF.md - this file

## Tests run
/bin/bash spike/tests/test_handoff.sh - 260 passed, 0 failed (also under the default bash)
make check-fast - PASS

## Hard rules touched
- Rule 4 (never touch CLI credentials) - symlink tests: a symlink to a canary file is refused before any read, nothing is copied to TMPDIR, canary text never appears in output
- Security (ARCHITECTURE.md, worker output is untrusted) - injection tests: payloads kept verbatim, marker file never created, hostile file names do not execute, source has no eval/source; ESC, C1, bidi, tag, invisible and invalid-UTF-8 input rejected
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
- Callers must run parse.sh under a timeout (a FIFO swapped in after the regular-file check blocks the open) and pass a canonical path inside the worktree; symlinked parent directories are the caller's job. Both are in the spec.
- Headings stay strict (bare, no hint text) and extra sections are rejected; the lead is removing the hint text from the AGENTS.md template.
- Paths in Files changed use a conservative charset (no spaces or non-ASCII), so a worker touching such a file gets its handoff rejected.
- iconv is a new required tool (present on macOS and Linux); a missing iconv exits 2 like a missing jq.
- Consumers must still check task_id against the dispatched task and treat all strings as untrusted.
- No shared-file changes needed. Optional: add /bin/bash spike/tests/test_handoff.sh to a Makefile target.

## Confidence
high, every gate finding has a test, and the suite passes offline under bash 3.2 and the default bash.
