#!/usr/bin/env bash
# Self-test for scripts/ci/compliance-scan.sh and the hook scripts.
# Phase 0 "done when": the compliance CI fails on a planted violation of each check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCAN="$REPO/scripts/ci/compliance-scan.sh"
HOOKS="$REPO/.claude/hooks"
pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL - $1"; fail=$((fail + 1)); }

new_repo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q 2>/dev/null || true
  mkdir -p "$d/src" "$d/docs"
  echo "$d"
}
expect_scan() {  # expect_scan <want: clean|dirty> <name> <dir>
  local want="$1" name="$2" dir="$3"
  if "$SCAN" --root "$dir" >/dev/null 2>&1; then got=clean; else got=dirty; fi
  [ "$got" = "$want" ] && ok "scan $name -> $want" || bad "scan $name: wanted $want, got $got"
  rm -rf "$dir"
}

echo "compliance-scan.sh"
d="$(new_repo)"; echo 'fn main() {}' > "$d/src/main.rs"; echo 'Never read ~/.codex/auth.json' > "$d/docs/rules.md"
expect_scan clean "clean repo (docs may name paths)" "$d"
d="$(new_repo)"; echo 'let p = home.join(".codex/auth.json");' > "$d/src/auth.rs";       expect_scan dirty "R4 credential path" "$d"
d="$(new_repo)"; echo 'const f = "~/.claude/.credentials.json";' > "$d/src/a.ts";        expect_scan dirty "R4 claude credentials" "$d"
d="$(new_repo)"; echo 'run("security find-generic-password -s x")' > "$d/src/k.py";      expect_scan dirty "R4 keychain query" "$d"
d="$(new_repo)"; echo 'cmd.env("CODEX_HOME", "/tmp/acct2");' > "$d/src/s.rs";            expect_scan dirty "R2 config-home override" "$d"
d="$(new_repo)"; printf '{ "dependencies": { "@openai/codex": "1.0.0" } }\n' > "$d/package.json"; expect_scan dirty "R6 bundled npm CLI" "$d"
d="$(new_repo)"; mkdir -p "$d/bin"; printf '\x7fELF\x00\x01' > "$d/bin/claude"; chmod +x "$d/bin/claude"; expect_scan dirty "R6 committed binary" "$d"
d="$(new_repo)"; mkdir -p "$d/assets"; echo '<svg/>' > "$d/assets/openai-logo.svg";      expect_scan dirty "R8 provider logo" "$d"
d="$(new_repo)"; mkdir -p "$d/src-tauri"; printf '{ "productName": "GrokSquad", "identifier": "dev.x.app" }\n' > "$d/src-tauri/tauri.conf.json"; expect_scan dirty "R8 trademark app name" "$d"
d="$(new_repo)"; mkdir -p "$d/src/scheduler"; echo 'use crate::pty::pty_write;' > "$d/src/scheduler/mod.rs"; expect_scan dirty "R3 PTY write from scheduler" "$d"
d="$(new_repo)"; mkdir -p "$d/src/pty"; echo 'pub fn pty_write() {}' > "$d/src/pty/mod.rs"; expect_scan clean "R3 PTY module itself is fine" "$d"

echo "hooks"
hook() {  # hook <script> <want exit> <name> <json>
  local script="$1" want="$2" name="$3" json="$4" code
  printf '%s' "$json" | HOME="${FAKE_HOME:-$HOME}" "$HOOKS/$script" >/dev/null 2>&1; code=$?
  [ "$code" = "$want" ] && ok "$script $name -> exit $want" || bad "$script $name: wanted exit $want, got $code"
}
FAKE_HOME="$(mktemp -d)"; export FAKE_HOME
hook guard-files.sh 2 "Read ~/.codex/auth.json"   "{\"tool_name\":\"Read\",\"cwd\":\"/tmp\",\"tool_input\":{\"file_path\":\"$FAKE_HOME/.codex/auth.json\"}}"
hook guard-files.sh 2 "Read claude credentials"   "{\"tool_name\":\"Read\",\"cwd\":\"/tmp\",\"tool_input\":{\"file_path\":\"$FAKE_HOME/.claude/.credentials.json\"}}"
hook guard-files.sh 2 "Read via ../ traversal"    "{\"tool_name\":\"Read\",\"cwd\":\"$FAKE_HOME/proj\",\"tool_input\":{\"file_path\":\"../.gemini/oauth_creds.json\"}}"
hook guard-files.sh 2 "Read ~ tilde path"         '{"tool_name":"Read","cwd":"/tmp","tool_input":{"file_path":"~/.grok/auth.json"}}'
hook guard-files.sh 2 "Glob into kimi store"      '{"tool_name":"Glob","cwd":"/tmp","tool_input":{"pattern":"~/.kimi-code/**"}}'
hook guard-files.sh 2 "Grep rooted at HOME"       "{\"tool_name\":\"Grep\",\"cwd\":\"/tmp\",\"tool_input\":{\"pattern\":\"token\",\"path\":\"$FAKE_HOME\"}}"
hook guard-files.sh 0 "Read project .claude/settings.json" "{\"tool_name\":\"Read\",\"cwd\":\"$FAKE_HOME/proj\",\"tool_input\":{\"file_path\":\"$FAKE_HOME/proj/.claude/settings.json\"}}"
hook guard-files.sh 0 "Edit src file"             "{\"tool_name\":\"Edit\",\"cwd\":\"$FAKE_HOME/proj\",\"tool_input\":{\"file_path\":\"$FAKE_HOME/proj/src/main.rs\"}}"
hook guard-bash.sh 2 "cat codex auth"             '{"tool_name":"Bash","tool_input":{"command":"cat ~/.codex/auth.json"}}'
hook guard-bash.sh 2 "ls gemini dir"              '{"tool_name":"Bash","tool_input":{"command":"ls -la $HOME/.gemini"}}'
hook guard-bash.sh 2 "keychain query"             '{"tool_name":"Bash","tool_input":{"command":"security find-generic-password -s foo -w"}}'
hook guard-bash.sh 2 "config-home override"       '{"tool_name":"Bash","tool_input":{"command":"CODEX_HOME=/tmp/b codex exec hi"}}'
hook guard-bash.sh 2 "force push"                 '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
hook guard-bash.sh 2 "rm -rf home"                '{"tool_name":"Bash","tool_input":{"command":"rm -rf ~"}}'
hook guard-bash.sh 0 "cargo test"                 '{"tool_name":"Bash","tool_input":{"command":"cargo test --lib"}}'
hook guard-bash.sh 0 "codex exec review"          '{"tool_name":"Bash","tool_input":{"command":"codex exec --sandbox read-only \"review the diff\""}}'
hook guard-bash.sh 0 "rm -rf build dir"           '{"tool_name":"Bash","tool_input":{"command":"rm -rf ./target/debug"}}'
hook stop-checks.sh 0 "stop_hook_active loop guard" '{"stop_hook_active":true,"cwd":"/tmp"}'
hook guard-docs-only.sh 0 "docs agent edits README" '{"tool_name":"Edit","tool_input":{"file_path":"/repo/README.md"}}'
hook guard-docs-only.sh 2 "docs agent edits Rust"   '{"tool_name":"Write","tool_input":{"file_path":"/repo/src-tauri/src/lib.rs"}}'
hook guard-docs-only.sh 2 "docs agent edits HARD_RULES" '{"tool_name":"Edit","tool_input":{"file_path":"/repo/docs/HARD_RULES.md"}}'
mkdir -p "$FAKE_HOME/.claude"; CLAUDE_PROJECT_DIR="$FAKE_HOME" hook log-subagent.sh 0 "SubagentStop logger never blocks" '{"agent_type":"scout","agent_id":"a1","session_id":"s1"}'
rm -rf "$FAKE_HOME"

echo
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
