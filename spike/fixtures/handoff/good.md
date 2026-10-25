# HANDOFF T-006

## Summary
Defined the HANDOFF.md format for harness workers and a parser that turns it into JSON.
The parser treats every byte of the file as untrusted data.
It fails closed on any structural problem.

## Files changed
- docs/spec/handoff.md - format specification and size caps
- spike/handoff/parse.sh - parser, JSON on stdout
- spike/fixtures/handoff/good.md
- spike/tests/test_handoff.sh - offline tests

## Tests run
/bin/bash spike/tests/test_handoff.sh - all checks passed
make check-fast - PASS

## Hard rules touched
- Security (ARCHITECTURE.md) - injection.md test: payload kept verbatim, marker file never created
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
None.

## Confidence
high, every acceptance criterion has a test and the tests pass offline.
