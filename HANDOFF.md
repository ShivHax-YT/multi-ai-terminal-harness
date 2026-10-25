# HANDOFF T-001
## Summary
Phase 0 spike scaffold under spike/: sourced bash helpers (scratch repo outside this repo, worktree add, guarded cleanup,
`SPIKE_LIVE=1` gate, capture dir, redaction, symlink resolver, hardened timeout runner), a preflight that verifies each
CLI's code signature before executing it, offline tests, and a README. Revised after the compliance gate (BLOCK): the
live gate now stops the whole calling script, children run with a scrubbed environment in their own process group,
preflight verifies before it executes, and redaction was widened. Runs on macOS /bin/bash 3.2.

## Files changed
- spike/lib/common.sh - helpers; spike_require_live (kills the top-level script), spike_run_timeout (env scrub, process group, provider-CLI guard), spike_redact (rewritten), spike_capture_dir (refuses non-ignored in-repo roots), spike_cleanup (accepts logical TMPDIR spelling)
- spike/preflight.sh - verify-then-execute report table; SIGNATURE shows signer + team, or "launcher only"
- spike/tests/test_common.sh - 128 offline assertions
- spike/tests/test_preflight.sh - 42 offline assertions using fake claude/codex/codesign/file on a private PATH
- spike/README.md - rules (guard not approval, scrubbed env, verify-before-run), wave order, script index
- spike/.gitignore - ignores captures/

## Tests run
- `make check-fast` - PASS (compliance scan clean; no app stack yet)
- `/bin/bash spike/tests/test_common.sh` - 128 passed, 0 failed
- `/bin/bash spike/tests/test_preflight.sh` - 42 passed, 0 failed
- `/bin/bash -n` on all four scripts - clean
- `/bin/bash spike/preflight.sh` on this Mac - exit 0; claude and codex: mach-o, valid, Developer ID signer + team shown, signed in; `| grep -c @` is 0
- shellcheck: not installed, not run

## Gate items and how each is handled
1. Rule 1 bypass: `spike_require_live` sends TERM to `$$` (top-level script) and a TERM trap installed when common.sh is sourced turns that into exit 3; tests cover unset, `0`, `"1 "`, `" 1"`, `true`, `yes`, empty, `01`, exported 1, and use inside `$(...)`, a pipe and a subshell (caller never prints CONTINUED). `spike_run_timeout` calls it for claude|codex|grok|gemini|kimi (also `claude.exe`, and by resolved name) unless args are exactly `--version`, `auth status`, `login status`; the refused CLI is not started (marker file test). README says an agent never sets SPIKE_LIVE=1.
2. Rule 6: preflight runs `codesign --verify --strict` on the resolved binary first; an unverified Mach-O is never executed (marker-file test), cells say `skipped (unverified)`; version and status run on the same resolved binary. SIGNATURE shows first Authority + TeamIdentifier. Script launchers: "launcher only (...)" in the column plus a note.
3. Redaction: file:// URLs, JSON-escaped `\n` before a path and `\/` slashes, trailing punctuation, quotes/brackets, paths with spaces, any `/Users/<name>` and `/home/<name>`, any `@` between two tokens (localhost, bare host, a@b.c, non-ASCII), 32-hex ids (shared number with the dashed form; 40-hex git shas left alone). One test per case. `spike_capture_dir` refuses an in-repo root git does not ignore.
4. Env scrub: children run under `env -i` with PATH HOME TMPDIR LANG TERM. I also pass USER and LOGNAME: with them removed, `claude auth status` exits 1 on this Mac (it looks up its stored login under the account name), so preflight wrongly reported "not signed in". They carry no credentials. Tell me if you want them dropped.
5. Orphans: perl `setpgrp` puts the command in its own group; timeout sends TERM then KILL to the group; a normal exit also sweeps the group. Tests: launcher with a grandchild, and a command that leaves a background child.
6. Tests: test_preflight.sh as specified (status prints `SECRET jane@example.com`; neither leaks), unsigned look-alike not executed, script launcher note, missing CLI rc 0, missing jq / git rc 1. test_common.sh adds empty/unset TMPDIR, TMPDIR with spaces, symlinked TMPDIR.
7. Display: `@` -> `%` in paths is stated in the footer and README; version text filtered with `tr -cd '[:print:]'`.

## Hard rules touched (rule numbers + the test that proves each)
- 1: test_common.sh (require_live cases, run_timeout provider guard)
- 2: no config-home variable named in spike/ (compliance scan); children get a scrubbed environment (env test)
- 4: sign-in by exit code only, output discarded (test_preflight.sh scenario 1); no credential paths in code (scan)
- 6: test_preflight.sh scenarios 1-3 (signature first, unsigned not executed, resolved binary executed)

## Open risks / questions
- Changed an existing test: "redact leaves a lookalike path prefix alone" (`$HOME` + `x/not-home`) now asserts the opposite privacy-preserving outcome (`not-home` must not appear), because the brief now requires generic `/Users/<name>` redaction. The lookalike becomes `/Users/<USER>/...`.
- Redaction over-redacts by design: `/Users/x/a.txt for /etc/foo` can swallow the following words when a slash appears within two words (needed for paths with spaces). An `@` between two tokens (e.g. `node_modules/@scope/pkg`) becomes `<EMAIL>`.
- `spike_require_live` installs a TERM trap on source unless the caller already has one; a caller with its own TERM trap must exit 3 itself. It would terminate an interactive shell that sources common.sh and calls it.
- Needs perl (present on macOS) for the process-group start.
- The codex binary resolves under its CLI home directory (the lead is recording that the file-access layer needs a narrow allowlist for installed binaries there). Preflight only displays that path (`~/...`) and executes the binary after verification; it does not read the directory.
- Preflight still runs `--version` and the status command without SPIKE_LIVE (allowed by the guard's explicit exception).

## Follow-ups for shared files (lead)
- Makefile: add a `spike-test` target running `/bin/bash` on each `spike/tests/*.sh` and include it in `check-fast`.
- .github/workflows/ci.yml: extend the shellcheck step to spike/ (`shellcheck -S warning spike/lib/common.sh spike/preflight.sh spike/tests/*.sh`). Possible SC2059 (printf with a format variable) is info level only.

## Confidence
High on behaviour (170 assertions pass on bash 3.2). Medium on shellcheck cleanliness (not run).
