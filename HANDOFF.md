# HANDOFF T-001
## Summary
Added the Phase 0 spike scaffold under spike/: sourced bash helpers (scratch repo outside this repo, worktree add,
guarded cleanup, `SPIKE_LIVE=1` gate, capture dir, redaction, symlink resolver, timeout runner), a preflight that
tabulates install path, version, code signature and sign-in state for claude and codex, offline tests, and a README with
the wave order and script index. Works on macOS /bin/bash 3.2 (tests run under it).

## Files changed
- spike/lib/common.sh - helpers: spike_root, spike_scratch_repo, spike_worktree_add, spike_cleanup, spike_require_live, spike_capture_dir, spike_redact, spike_resolve_path, spike_run_timeout
- spike/preflight.sh - report table (TOOL, FOUND, VERSION, KIND, SIGNATURE, SIGNED-IN, PATH); exit 0 unless jq or git is missing
- spike/tests/test_common.sh - 42 offline assertions in a private TMPDIR
- spike/README.md - purpose, SPIKE_LIVE rule, wave order, script index
- spike/.gitignore - ignores captures/

## Tests run
- `make check-fast` - PASS (compliance scan clean; no app stack yet)
- `/bin/bash spike/tests/test_common.sh` - 42 passed, 0 failed (bash 3.2)
- `spike/preflight.sh` (also under /bin/bash) - exit 0, rows for claude and codex, both "valid" signature and "signed in"
- `spike/preflight.sh | grep -c @` - 0
- `bash -n` via the sandbox was blocked for me; the scripts executed cleanly under both /bin/bash and env bash, so syntax is fine
- shellcheck: not installed, not run

## Hard rules touched (rule numbers + the test that proves each)
- 1: `spike_require_live` exits 3 unless SPIKE_LIVE=1 (test_common.sh asserts unset, 0 and "yes" all exit 3)
- 2: no config-home variable named or set anywhere in spike/ (compliance scan clean)
- 4: sign-in via `claude auth status` / `codex login status`, exit code only, output sent to /dev/null; no credential paths (scan clean; `grep -c @` is 0)
- 6: preflight records version and `codesign --verify --strict` result per CLI (SIGNATURE column)

## Open risks / questions
- Both CLIs on this Mac resolve to Mach-O binaries (claude via the npm package dir, codex under the user's home). If a CLI resolves to a script launcher, preflight prints a note that the signature covers only the launcher.
- Displayed paths replace `@` with `%` (scoped npm dirs) so the table can never be mistaken for containing an email; this is display only.
- `spike_redact` collapses any `$HOME` path to `$HOME/...` (drops the tail), per the brief. Only the logical and physical `$TMPDIR/harness-spike/<run>` forms are mapped to `<WORKTREE>`.
- `spike_require_live` calls `exit` (not `return`), by design, so it ends the calling script.
- Preflight's `--version` and status calls run without SPIKE_LIVE (they send no prompt); the brief requires preflight to run unflagged.

## Follow-ups for shared files (lead)
- Makefile: add a `spike-test` target running `spike/tests/*.sh` (each via `/bin/bash`) and make it part of `check-fast`.
- .github/workflows/ci.yml: extend the shellcheck step to spike/ (shellcheck -S warning spike/lib/common.sh spike/preflight.sh spike/tests/*.sh).
- Root .gitignore: optional; spike/.gitignore already covers captures/.

## Confidence
High on helpers and tests (all pass on bash 3.2). Medium on shellcheck cleanliness, since it could not be run here (the `printf "$ROW_FMT"` pattern may raise an info-level SC2059, below the -S warning threshold).
