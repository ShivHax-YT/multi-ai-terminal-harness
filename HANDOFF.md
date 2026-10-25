# HANDOFF T-006

## Summary
Defined the worker HANDOFF.md format (docs/spec/handoff.md) and spike/handoff/parse.sh, a bash 3.2 parser that fails closed.
File content is untrusted: no eval/source/expansion; text reaches JSON only via jq --arg or stdin; output is ASCII-only (jq -a).
Gate fixes: one bounded read into a private copy, every check via stdin (no fail-open grep, awk assignment or TOCTOU).
C1, bidi, zero-width and BOM characters are rejected; `parse.sh [--] <file>` rejects option-looking first args.
172 offline tests cover good, missing-section, bad-confidence, oversize, injection and the gate cases.

## Files changed
- docs/spec/handoff.md - format spec: sections, allowed content, size caps, error messages, exit codes
- spike/handoff/parse.sh - parser, JSON on stdout, exit 1 on invalid handoff, 2 on usage error; single bounded read, stdin-only checks, fail-closed grep, jq -a
- spike/fixtures/handoff/good.md - valid handoff
- spike/fixtures/handoff/missing-section.md - lacks Tests run
- spike/fixtures/handoff/bad-confidence.md - level is "certain"
- spike/fixtures/handoff/injection.md - instruction-like text, command substitution and backtick payloads (__MARKER__ placeholder)
- spike/tests/test_handoff.sh - 172 offline checks (oversize files generated at test time; dash-named, max=1-named, ESC, C1, bidi, BOM cases)
- HANDOFF.md - this file

## Tests run
/bin/bash spike/tests/test_handoff.sh - 172 passed, 0 failed (also run under macOS /bin/bash 3.2.57)
make check-fast - PASS

## Hard rules touched
- Security (ARCHITECTURE.md, worker output is untrusted) - test_handoff.sh injection section: injection.md parses, payloads appear verbatim in the JSON, marker file never created, hostile file name does not execute, source has no eval/source; files named -n.md/-q.md/./-n.md with ESC content and max=1 with a 600-byte line are rejected; U+009B and U+202E rejected
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
- The format is strict (exact headings, no suffix text such as "## Summary (3-5 lines)", reason required after the confidence level). AGENTS.md's template shows hint text in parentheses; workers must write bare headings. If the lead prompt should tolerate hints, the spec needs a v2.
- The old parser failed open on option-looking file names and awk-assignment names; the new tests fail against the old parser (39 failures) and pass against the fix.
- File paths are limited to a conservative charset (no spaces, no non-ASCII); a worker that changes such a file must list it another way or the handoff is rejected.
- Consumers (lead, scheduler) must still check task_id against the dispatched task and treat all strings as untrusted; the parser cannot do that for them.
- No shared-file changes needed. Optional follow-up for the lead: add `/bin/bash spike/tests/test_handoff.sh` to a Makefile target (Makefile is not owned by this task).

## Confidence
high, every acceptance criterion has a test and the suite passes offline under both bash 3.2 and the default bash.
