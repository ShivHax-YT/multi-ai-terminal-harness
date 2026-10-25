# Pre-launch compliance checklist

Status as of Oct 24, 2026: **not started.** Every box must be checked, with evidence linked, before any public or
commercial release. This is not legal advice.

- [ ] Compliance CI suite (rules 1-12) green on the **signed release build**. Evidence: CI run link
- [ ] Credential canary test passed: app process never opened any CLI credential file or Keychain item
- [ ] 24-hour simulated-clock test passed: no subscription activity past the ceilings, while idle, or on a schedule
- [ ] Account switch and restart tests passed: counters never reset
- [ ] No PTY write path reachable from scheduler or lead (dependency rule passes)
- [ ] App bundle contains no provider binaries; tampered and unsigned binaries refused for automation
- [ ] Gemini requires an API key; no Google sign-in path exists
- [ ] No provider logos, icons or trademarks in the app name, bundle ID, assets or marketing; not-affiliated statement in About and website
- [ ] Every provider's terms re-read and signed off for this release (list in `docs/HARD_RULES.md`); weekly snapshot job running
- [ ] Kill switch tested on the release build for every adapter, including force-API-key mode
- [ ] Spend caps required for every API-key provider; no unlimited value accepted
- [ ] App listens on localhost only; no remote or multi-seat access to subscription sessions
- [ ] Onboarding shows each provider's own login and asks the user to confirm personal, single-user use
- [ ] Lawyer has reviewed the hard rules, provider terms and the app's own terms of use

## Per-release terms sign-off (rule 12)

| Provider | Terms pages re-read (date) | Changes found | Action taken | Signed off by |
|---|---|---|---|---|
| Anthropic (Claude Code) | | | | |
| OpenAI (Codex) | | | | |
| xAI (Grok Build) | | | | |
| Google (Gemini CLI) | | | | |
| Moonshot (Kimi Code) | | | | |
| Z.ai (GLM Coding Plan) | | | | |
