# Architecture

Decided design: a Claude Squad-style app. Each provider's **official, unmodified CLI** runs locally, one session per
worker, each in its own git worktree, signed in through the provider's own login. A **lead AI** coordinates the sessions.
BYO API keys are an optional fallback; Gemini is API key only. All of this is bound by `docs/HARD_RULES.md`.

## Components

```
Desktop shell (Tauri 2 + xterm.js, or SwiftUI + SwiftTerm: see ADR 0001)
  │  lead chat · plan approval · session grid · usage meter
  ▼
Lead loop ──(plan for approval)──► UI ──(approval token bound to plan hash)──► Scheduler + guardrails
                                                                                │  task graph, roles, fallback chains,
                                                                                │  compiled ceilings, pacing (rules 1, 2, 9, 10, 11)
                                                                                ▼
                                                                         Session manager (one per CLI session)
                                                                                │  start · attach(view) · pause · resume · kill
                                                                                ▼
                                                                         CLI adapters: headless JSON or ACP only (rule 3)
                                                                                │
                                                                                ▼
                                                    Official CLIs: claude, codex, grok, kimi, gemini(API key)
                                                                                │ edits
                                                                                ▼
                                                    Worktree per worker ──► Review + merge step ──(evidence)──► Lead
Event log + usage store (SQLite): every event, token count, diff, cost
File-access layer with credential denylist (rule 4) · Binary verifier (rule 6) · Kill-switch config (rule 12)
```

## Session manager

Each worker is one session: a provider, a role, a worktree, and a live terminal the user can watch or take over. The
session manager:

- starts the **verified** official CLI (rule 6) with `cwd` set to the worker's worktree and the CLI's **default config
  home only** (rule 2);
- checks install and sign-in using only the CLI's own documented status output, never its files (rule 4). If not signed
  in, it opens the CLI's own login in that terminal for the **user** to complete;
- restarts crashed sessions, pauses/resumes them, and starts child processes with auto-update off (for example
  `grok --no-auto-update`) so versions stay pinned;
- passes child CLIs only the environment they need (no inherited secrets).

## Adapters

| Mode | How the lead sends work | How results come back | Use for |
|---|---|---|---|
| Headless JSON | Start the CLI per task with the prompt: `claude -p --output-format stream-json`, `codex exec --json`, `grok -p --output-format streaming-json`, `gemini -p --output-format stream-json`; resume by session ID for follow-ups | Newline-delimited JSON events: tool calls, messages, a final result with token counts | Default for MVP workers (Claude Code, Codex) |
| ACP | One long-running process (`grok agent stdio`, `kimi acp`, `gemini --acp`) receiving prompts as JSON-RPC requests | Streamed session updates, permission requests, end-of-turn signals | Grok, Kimi, Gemini (native ACP); long multi-turn work |
| PTY (view only) | **Never used by the lead or scheduler** (rule 3). Only the user's own keystrokes reach the TUI | Nothing is parsed from it | Watching a worker and human take-over |

A CLI with no documented headless or ACP mode is not automated at all.

Adapter interface (same for every provider):

```
start(task, worktree) -> SessionId
send(prompt)          -> ()            // headless/ACP only
events()              -> Stream<Event> // tool_call, message, result{tokens}, rate_limited, error, exited
cancel()              -> ()
authStatus()          -> SignedIn | SignedOut | Unknown   // via the CLI's documented status output only
capabilities()        -> { transport: Headless|Acp, resume, mcp, hooks }
usage()               -> { tokens, requests, estimated_share }  // estimates labeled as such
```

For Claude, run the `claude` binary itself rather than the Agent SDK-based ACP adapter: running the unmodified binary is
the most clearly allowed route.

## How the lead works

1. **Plan.** The lead (a headless session of the provider the user chose) turns the request into a structured plan:
   tasks, role, provider, files owned, acceptance criteria, dependencies, estimated usage, fallback providers.
2. **Approve.** The UI shows the plan and estimated usage per provider. Nothing runs until the user approves or edits it.
   Approval creates a token bound to the plan hash (rule 9).
3. **Dispatch.** The scheduler creates a worktree per task and sends each worker a brief: the task, owned files,
   acceptance criteria, and an instruction to write `HANDOFF.md` in a fixed format. Dispatch respects ceilings and pacing.
4. **Collect.** The adapter reads the final result event plus `git diff`, test output and `HANDOFF.md`.
5. **Verify.** Tests and lint run in the worktree. A reviewer from a **different vendor** checks the diff against the
   acceptance criteria. The lead never grades its own assignments.
6. **Summarize.** The lead returns a summary under the user's token budget (default 200), with links to each diff, test
   log and handoff.

## Worktrees and the merge step

- Each worker gets `git worktree add` on its own branch named after the task. Workers never touch the main checkout.
- The plan assigns which files each task owns. Tasks needing the same file run one after the other.
- Finished branches enter a merge queue: rebase onto target, run tests, show the diff. The user approves each merge (or a batch).
- Failed or rejected branches stay so the lead can send them back with feedback or reassign them.

## Failover

When a CLI reports a rate limit or usage-exhausted error, the scheduler pauses that session (backoff, rule 10) and moves
the same brief and branch to the next provider in the role's fallback list, **only if that provider is different and is
listed in the approved plan** (rules 2, 9). Examples: GLM through official Claude Code with Z.ai's base URL, or the Kimi CLI.

## Shared notes (Phase 2)

One local MCP server (localhost only, rule 5) gives all agents the same `read_brief`, `post_note`, `ask_lead` tools,
registered in each CLI's own config. It never exposes CLI home directories (rule 4).

## Security

- Inter-agent messages are labeled untrusted data. Researchers are read-only with no shell.
- Workers run with sandbox defaults (Codex sandbox, `grok --sandbox`), network off for code workers by default.
- Auto-approve flags only inside worktrees, never in the user's main checkout. Destructive commands always ask.
- API keys only in Keychain (Credential Manager on Windows). Redacted from logs. Briefs scanned for secrets before
  they go to another vendor.

## Stack

> **TODO (human):** record Tauri 2 vs Swift in `docs/adr/0001-stack.md`. Plan recommendation: Tauri 2 (Rust core,
> `portable-pty`, xterm.js, Keychain access). Note: one project's macOS build broke on portable-pty 0.9.0; pin it.
