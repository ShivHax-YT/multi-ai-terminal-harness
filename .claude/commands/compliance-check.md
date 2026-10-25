---
description: Run the hard-rule compliance scan, self-test, and an audit of the current branch
argument-hint: [base-branch]
allowed-tools: Bash(scripts/ci/compliance-scan.sh *), Bash(tests/compliance/selftest.sh), Bash(git diff *)
---
1. Run `scripts/ci/compliance-scan.sh` and `tests/compliance/selftest.sh`. Quote any failure lines exactly.
2. Base branch: "$ARGUMENTS" if given, otherwise main. Use the compliance-auditor subagent on `git diff <base>...HEAD`.
3. Report a table of rules 1-12: not touched / satisfied (test name) / violated / test missing, then PASS or BLOCK.
Never weaken a check to make this pass. If a rule looks wrong, flag it for me.
