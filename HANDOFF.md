# HANDOFF T-006

## Summary
Defined the fixed worker HANDOFF.md format (mirrors the AGENTS.md format) in docs/spec/handoff.md.
Added spike/handoff/parse.sh, a bash 3.2 compatible parser that emits the JSON shape from the brief and fails closed.
All file content is treated as untrusted: no eval/source/expansion, text reaches JSON only via jq --arg or stdin.
Offline tests cover the good, missing-section, bad-confidence, oversize and injection cases plus many edge cases.

## Files changed
- docs/spec/handoff.md - format spec: sections, allowed content, size caps, error messages, exit codes
- spike/handoff/parse.sh - parser, JSON on stdout, exit 1 on invalid handoff, 2 on usage error
- spike/fixtures/handoff/good.md - valid handoff
- spike/fixtures/handoff/missing-section.md - lacks Tests run
- spike/fixtures/handoff/bad-confidence.md - level is "certain"
- spike/fixtures/handoff/injection.md - instruction-like text, command substitution and backtick payloads (__MARKER__ placeholder)
- spike/tests/test_handoff.sh - 124 offline checks, oversize files are generated at test time
- HANDOFF.md - this file

## Tests run
/bin/bash spike/tests/test_handoff.sh - 124 passed, 0 failed (also run under macOS /bin/bash 3.2.57)
make check-fast - PASS

## Hard rules touched
- Security (ARCHITECTURE.md, worker output is untrusted) - test_handoff.sh injection section: injection.md parses, payloads appear verbatim in the JSON, marker file never created, hostile file name does not execute, source has no eval/source
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
- The format is strict (exact headings, no suffix text such as "## Summary (3-5 lines)", reason required after the confidence level). AGENTS.md's template shows hint text in parentheses; workers must write bare headings. If the lead prompt should tolerate hints, the spec needs a v2.
- File paths are limited to a conservative charset (no spaces, no non-ASCII); a worker that changes such a file must list it another way or the handoff is rejected.
- Consumers (lead, scheduler) must still check task_id against the dispatched task and treat all strings as untrusted; the parser cannot do that for them.
- No shared-file changes needed. Optional follow-up for the lead: add `/bin/bash spike/tests/test_handoff.sh` to a Makefile target (Makefile is not owned by this task).

## Confidence
high, every acceptance criterion has a test and the suite passes offline under both bash 3.2 and the default bash.
