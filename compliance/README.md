# compliance/

Runtime compliance data lives here and is the **only** place in app code allowed to name provider credential paths:

- `denylist.*` (create in Phase 1 in your stack's format): the credential-store paths and Keychain service names the
  file-access layer refuses (hard rule 4). Start from `.claude/hooks/lib.sh` `CRED_DIRS`.
- `ceilings.*`: the compiled-in subscription ceilings from hard rule 1 (2 sessions, 30 prompts/h, 40 turns/task,
  8 h/day, 30 min idle pause), pacing from rule 10 (5 s gap, 60 s backoff base, pause after 3 limit errors).
- `pty-boundary.conf`: symbols and paths for the rule 3 static check.
- `killswitch.pub`: public key for verifying the signed kill-switch config (rule 12).
