#!/usr/bin/env bash
# Tests for spike/lib/common.sh. Run: /bin/bash spike/tests/test_common.sh  (exit 0 = all passed)
# Uses a private TMPDIR so it never touches a real spike run.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
COMMON="$HERE/../lib/common.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <name> <command...>
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
has() { # has <name> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing [$3] in [$2])" ;; esac
}
lacks() { # lacks <name> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1 (found [$3] in [$2])" ;; *) ok "$1" ;; esac
}

# child <code>: run code in a fresh /bin/bash with common.sh sourced and SPIKE_LIVE unset unless the caller exported it.
child() {
  /bin/bash -c '. "$1"; eval "$2"' _ "$COMMON" "$1"
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/spiketest.XXXXXX")" || exit 1
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export TMPDIR="$SANDBOX"
unset SPIKE_LIVE
trap 'rm -rf "$SANDBOX"' EXIT

# shellcheck disable=SC1090
. "$COMMON"

ROOT="$(spike_root)"
eq "spike_root is under the private TMPDIR" "$SANDBOX/harness-spike" "$ROOT"

# --- scratch repo, worktree, branch, cleanup -------------------------------------------------------------------------
REPO="$(spike_scratch_repo)"
check "scratch repo exists" test -d "$REPO/.git"
check "scratch repo lives under the spike root" test "${REPO#"$ROOT"/}" != "$REPO"
check "scratch repo has README.md and notes.txt" test -f "$REPO/README.md" -a -f "$REPO/notes.txt"
eq "scratch repo has exactly one commit" "1" "$(git -C "$REPO" rev-list --count HEAD)"
RUN="$(dirname "$REPO")"

WT="$(spike_worktree_add "$REPO" alpha)"
eq "worktree path is <repo>-wt/<name>" "$REPO-wt/alpha" "$WT"
check "worktree dir exists" test -d "$WT"
eq "worktree is on branch spike/alpha" "spike/alpha" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
check "worktree add rejects a bad name" bash -c '. "$1"; ! spike_worktree_add "$2" "../evil"' _ "$COMMON" "$REPO"

spike_cleanup "$RUN"
check "cleanup removed the run dir" test ! -e "$RUN"
check "cleanup left no worktree dir" test ! -e "$REPO-wt"

# --- odd TMPDIR values -----------------------------------------------------------------------------------------------
PHYS_TMP="$(cd /tmp && pwd -P)"
eq "empty TMPDIR falls back to /tmp" "$PHYS_TMP/harness-spike" "$(TMPDIR='' spike_root)"
eq "unset TMPDIR falls back to /tmp" "$PHYS_TMP/harness-spike" "$(unset TMPDIR; spike_root)"

mkdir -p "$SANDBOX/with space"
(
  export TMPDIR="$SANDBOX/with space"
  R="$(spike_scratch_repo)" || exit 1
  W="$(spike_worktree_add "$R" beta)" || exit 1
  [ "$(git -C "$W" rev-parse --abbrev-ref HEAD)" = "spike/beta" ] || exit 1
  spike_cleanup "$(dirname "$R")" || exit 1
  [ ! -e "$(dirname "$R")" ] || exit 1
)
eq "TMPDIR with spaces: repo, worktree and cleanup work" "0" "$?"

mkdir -p "$SANDBOX/real-tmp"
ln -s "$SANDBOX/real-tmp" "$SANDBOX/link-tmp"
(
  export TMPDIR="$SANDBOX/link-tmp"
  [ "$(spike_root)" = "$SANDBOX/real-tmp/harness-spike" ] || exit 1
  R="$(spike_scratch_repo)" || exit 1
  case "$R" in "$SANDBOX/real-tmp/harness-spike/"*) ;; *) exit 1 ;; esac
  LOGICAL="$SANDBOX/link-tmp/harness-spike/$(basename "$(dirname "$R")")"
  spike_cleanup "$LOGICAL" || exit 1
  [ ! -e "$(dirname "$R")" ] || exit 1
)
eq "symlinked TMPDIR: root is physical, cleanup accepts the logical spelling" "0" "$?"

# --- cleanup refuses anything outside the spike root -----------------------------------------------------------------
OUTSIDE="$SANDBOX/outside"
mkdir -p "$OUTSIDE/keep"
printf 'x\n' > "$OUTSIDE/keep/file"
spike_cleanup "$OUTSIDE" 2>/dev/null
eq "cleanup refuses a path outside the spike root (rc)" "2" "$?"
check "outside path is untouched" test -f "$OUTSIDE/keep/file"
spike_cleanup "$ROOT" 2>/dev/null
eq "cleanup refuses the spike root itself (rc)" "2" "$?"
spike_cleanup "" 2>/dev/null
eq "cleanup refuses an empty path (rc)" "2" "$?"
spike_cleanup "/" 2>/dev/null
eq "cleanup refuses / (rc)" "2" "$?"
spike_cleanup "$HOME" 2>/dev/null
eq "cleanup refuses \$HOME (rc)" "2" "$?"
mkdir -p "$ROOT/run-x"
spike_cleanup "$ROOT/run-x/../../outside" 2>/dev/null
eq "cleanup refuses .. traversal (rc)" "2" "$?"
check "traversal target is untouched" test -f "$OUTSIDE/keep/file"
ln -s "$OUTSIDE" "$ROOT/run-link"
spike_cleanup "$ROOT/run-link" 2>/dev/null
eq "cleanup refuses a symlink under the root (rc)" "2" "$?"
check "symlink target is untouched" test -f "$OUTSIDE/keep/file"
rm -f "$ROOT/run-link"
spike_cleanup "$ROOT/run-x"
check "cleanup removes a plain run dir under the root" test ! -e "$ROOT/run-x"

# --- spike_require_live (rule 1): must stop the whole calling script, not just its own subshell -----------------------
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live exits 3 when SPIKE_LIVE is unset (rc)" "3" "$?"
lacks "require_live stops the script when unset" "$out" "CONTINUED"
for v in "0" "1 " " 1" "true" "yes" "" "01"; do
  out="$(SPIKE_LIVE="$v" /bin/bash -c '. "$1"; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
  rc=$?
  eq "require_live exits 3 for SPIKE_LIVE=[$v]" "3" "$rc"
  lacks "require_live stops the script for SPIKE_LIVE=[$v]" "$out" "CONTINUED"
done
out="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live passes when SPIKE_LIVE=1 is in the environment (rc)" "0" "$?"
has "require_live lets the script continue when SPIKE_LIVE=1" "$out" "CONTINUED"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; export SPIKE_LIVE=1; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
has "require_live passes when SPIKE_LIVE=1 is exported later" "$out" "CONTINUED"

out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; x="$(spike_require_live)"; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live inside \$(...) stops the caller (rc)" "3" "$?"
lacks "require_live inside \$(...) stops the caller" "$out" "CONTINUED"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_require_live | cat; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live in a pipe stops the caller (rc)" "3" "$?"
lacks "require_live in a pipe stops the caller" "$out" "CONTINUED"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; ( spike_require_live ); echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live in a subshell stops the caller (rc)" "3" "$?"
lacks "require_live in a subshell stops the caller" "$out" "CONTINUED"

# spike_run_timeout refuses a provider CLI for anything but version/status unless SPIKE_LIVE=1.
FAKE="$SANDBOX/fakecli"
mkdir -p "$FAKE"
for n in claude codex; do
  printf '#!/bin/sh\ntouch "%s/ran-$$"\nexit 0\n' "$FAKE" > "$FAKE/$n"
  chmod +x "$FAKE/$n"
done
cat > "$FAKE/claude.exe" <<EOF
#!/bin/sh
touch "$FAKE/ran-exe-\$\$"
EOF
chmod +x "$FAKE/claude.exe"
ran() { ls "$FAKE" | grep -c '^ran-'; }
rm -f "$FAKE"/ran-*
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" -p hi; echo CONTINUED' _ "$COMMON" "$FAKE" 2>/dev/null)"
eq "run_timeout refuses a provider CLI prompt without SPIKE_LIVE (rc)" "3" "$?"
lacks "run_timeout refusal stops the caller" "$out" "CONTINUED"
eq "refused provider CLI was not started" "0" "$(ran)"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude.exe" -p hi; echo CONTINUED' _ "$COMMON" "$FAKE" 2>/dev/null)"
eq "run_timeout also guards a claude.exe name (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/codex" exec hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses codex exec without SPIKE_LIVE (rc)" "3" "$?"
eq "refused CLIs were not started" "0" "$(ran)"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" --version' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout allows claude --version without SPIKE_LIVE" "0" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" auth status' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout allows claude auth status without SPIKE_LIVE" "0" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/codex" login status' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout allows codex login status without SPIKE_LIVE" "0" "$?"
eq "allowed calls did start the CLIs" "3" "$(ran)"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" --version extra' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses --version with extra args (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" auth login' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses auth login (rc)" "3" "$?"
rm -f "$FAKE"/ran-*
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" -p hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout runs a provider CLI prompt with SPIKE_LIVE=1" "0" "$?"
eq "live provider CLI was started" "1" "$(ran)"

# --- the gate is default-deny: indirect launches of a provider CLI are refused (rule 1) ------------------------------
cp "$FAKE/claude" "$FAKE/renamed"
cp "$FAKE/claude" "$FAKE/mytool"
rm -f "$FAKE"/ran-*
# denied <name> <code>: with SPIKE_LIVE unset and the fake claude first on PATH, <code> must exit 3, never reach the
# line after it, and never start the fake.
denied() {
  local name="$1" code="$2" o rc
  o="$(env -u SPIKE_LIVE PATH="$FAKE:$PATH" /bin/bash -c '. "$1"; eval "$2"; echo CONTINUED' _ "$COMMON" "$code" 2>/dev/null)"
  rc=$?
  eq "gate: $name (rc 3)" "3" "$rc"
  lacks "gate: $name (caller stopped)" "$o" "CONTINUED"
  eq "gate: $name (CLI not started)" "0" "$(ran)"
}
denied "env claude -p hi" 'spike_run_timeout 5 /dev/null env claude -p hi'
denied "/usr/bin/env claude -p hi" 'spike_run_timeout 5 /dev/null /usr/bin/env claude -p hi'
denied "sh -c 'claude -p hi'" "spike_run_timeout 5 /dev/null sh -c 'claude -p hi'"
denied "bash -c 'claude -p hi'" "spike_run_timeout 5 /dev/null bash -c 'claude -p hi'"
denied "/bin/bash -c with a path" "spike_run_timeout 5 /dev/null /bin/bash -c '$FAKE/claude -p hi'"
denied "renamed copy of claude" "spike_run_timeout 5 /dev/null '$FAKE/renamed' -p hi"
denied "renamed copy with --version" "spike_run_timeout 5 /dev/null '$FAKE/renamed' --version"
denied "unknown tool name" "spike_run_timeout 5 /dev/null '$FAKE/mytool' -p hi"
denied "upper-case CLAUDE path" "spike_run_timeout 5 /dev/null '$FAKE/CLAUDE' -p hi"
denied "upper-case Codex exec" "spike_run_timeout 5 /dev/null '$FAKE/Codex' exec hi"
denied "provider name in the args of an allowed tool (echo)" "spike_run_timeout 5 /dev/null echo CLAUDE"
denied "provider name as a path component in cat" "spike_run_timeout 5 /dev/null cat /x/codex/y"
denied "git with an alias that runs claude" "spike_run_timeout 5 /dev/null git -c 'alias.x=!claude -p hi' x"
denied "git with anything but --version" "spike_run_timeout 5 /dev/null git status"
for w in zsh dash ksh xargs nohup command exec time nice perl python python3 node ruby script expect osascript open; do
  denied "launcher '$w'" "spike_run_timeout 5 /dev/null $w claude -p hi"
done
denied "spike_run_live without SPIKE_LIVE" "spike_run_live 5 /dev/null '$FAKE/claude' -p hi"
denied "spike_run_status with a prompt" "spike_run_status 5 /dev/null '$FAKE/renamed' -p hi"
denied "spike_run_status with --version and extra args" "spike_run_status 5 /dev/null '$FAKE/renamed' --version -p"

# ...while the harmless shapes still work without SPIKE_LIVE.
okrun() { # okrun <name> <code>: must not be stopped by the gate
  local name="$1" code="$2" o
  o="$(env -u SPIKE_LIVE PATH="$FAKE:$PATH" /bin/bash -c '. "$1"; eval "$2"; echo CONTINUED' _ "$COMMON" "$code" 2>/dev/null)"
  has "gate allows: $name" "$o" "CONTINUED"
}
okrun "true" 'spike_run_timeout 5 /dev/null true'
okrun "echo hello" 'spike_run_timeout 5 /dev/null echo hello'
okrun "sleep" 'spike_run_timeout 5 /dev/null sleep 0'
okrun "jq --version" 'spike_run_timeout 5 /dev/null jq --version'
okrun "git --version" 'spike_run_timeout 5 /dev/null git --version'
okrun "codesign --verify --strict <provider path>" "spike_run_timeout 5 /dev/null codesign --verify --strict '$FAKE/claude'"
okrun "codesign -dv --verbose=2 <provider path>" "spike_run_timeout 5 /dev/null codesign -dv --verbose=2 '$FAKE/claude'"
okrun "spike_run_status of a renamed binary with --version" "spike_run_status 5 /dev/null '$FAKE/renamed' --version"
okrun "spike_run_status of a renamed binary with login status" "spike_run_status 5 /dev/null '$FAKE/renamed' login status"
okrun "upper-case CLAUDE with --version" "spike_run_timeout 5 /dev/null '$FAKE/CLAUDE' --version"
rm -f "$FAKE"/ran-*
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2/renamed" -p hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "spike_run_live runs when SPIKE_LIVE=1 (rc)" "0" "$?"
eq "spike_run_live started the command" "1" "$(ran)"
rm -f "$FAKE"/ran-*

# --- require_live: documented top-level use, and the fail-safe for a caller that overrode TERM ---------------------
cat > "$SANDBOX/toplevel.sh" <<EOF
#!/bin/bash
. "$COMMON"
spike_require_live
echo RAN
EOF
out="$(env -u SPIKE_LIVE /bin/bash "$SANDBOX/toplevel.sh" 2>/dev/null)"
eq "documented top-level use stops with rc 3" "3" "$?"
lacks "documented top-level use prints nothing after the gate" "$out" "RAN"
out="$(SPIKE_LIVE=1 /bin/bash "$SANDBOX/toplevel.sh" 2>/dev/null)"
has "documented top-level use continues when SPIKE_LIVE=1" "$out" "RAN"
# A caller that ignores TERM is still stopped shortly after (watchdog sends KILL), even from inside $(...).
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; trap "" TERM; x="$(spike_require_live)"; sleep 1; echo LATE' _ "$COMMON" 2>/dev/null)"
lacks "a caller that ignores TERM is killed by the fail-safe" "$out" "LATE"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; trap "echo CAUGHT" TERM; ( spike_require_live ); sleep 1; echo LATE' _ "$COMMON" 2>/dev/null)"
lacks "a caller with its own TERM trap is killed by the fail-safe" "$out" "LATE"

# --- spike_capture_dir -----------------------------------------------------------------------------------------------
export SPIKE_CAPTURES_ROOT="$SANDBOX/captures"
CAP="$(spike_capture_dir demo)"
check "capture dir exists" test -d "$CAP"
case "$CAP" in
  "$SANDBOX/captures/demo/"2*Z/) ok "capture dir is <root>/<cli>/<UTC timestamp>/" ;;
  *) bad "capture dir shape: $CAP" ;;
esac
spike_capture_dir "../x" >/dev/null 2>&1
eq "capture dir rejects a bad cli name (rc)" "2" "$?"

CAPREPO="$SANDBOX/caprepo"
mkdir -p "$CAPREPO"
git -C "$CAPREPO" init -q
SPIKE_CAPTURES_ROOT="$CAPREPO/captures" spike_capture_dir demo >/dev/null 2>&1
eq "capture dir refuses a root inside a repo that does not ignore it (rc)" "2" "$?"
check "refused capture root was not created" test ! -e "$CAPREPO/captures"
printf 'captures/\n' > "$CAPREPO/.gitignore"
CAP2="$(SPIKE_CAPTURES_ROOT="$CAPREPO/captures" spike_capture_dir demo)"
eq "capture dir accepts a root inside a repo when git ignores it (rc)" "0" "$?"
check "ignored capture dir exists" test -d "$CAP2"
CAP3="$(unset SPIKE_CAPTURES_ROOT; spike_capture_dir selftest)"
eq "default capture root (spike/captures) is accepted (ignored by spike/.gitignore)" "0" "$?"
case "$CAP3" in "$HERE/../captures/selftest/"*|"$(cd "$HERE/.." && pwd -P)/captures/selftest/"*) rm -rf "$CAP3" ;; esac
rmdir "$(cd "$HERE/.." && pwd -P)/captures/selftest" 2>/dev/null
rmdir "$(cd "$HERE/.." && pwd -P)/captures" 2>/dev/null
unset SPIKE_CAPTURES_ROOT

# --- spike_redact ----------------------------------------------------------------------------------------------------
U1="3f2b8c1e-9a4d-4e7b-8c55-0123456789ab"
U2="AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee"
LINE="session $U1 and $U2 and $U1 again at $HOME/projects/secret/file.txt, mail jane.doe+x@example.com; wt $ROOT/run-1/repo-wt/a/file"
OUT="$(printf '%s\n' "$LINE" | spike_redact)"
lacks "redact removes UUID 1" "$OUT" "$U1"
lacks "redact removes UUID 2" "$OUT" "$U2"
has "redact numbers ids stably (same id, same number)" "$OUT" "session <ID-1> and <ID-2> and <ID-1> again"
has 'redact rewrites a $HOME path to $HOME/...' "$OUT" 'at $HOME/...,'
lacks "redact hides the home path tail" "$OUT" "projects/secret"
has "redact rewrites an email to <EMAIL>" "$OUT" "mail <EMAIL>;"
has "redact rewrites the scratch run dir to <WORKTREE>" "$OUT" "wt <WORKTREE>/repo-wt/a/file"
lacks "redacted output has no @" "$OUT" "@"
OUT2="$(printf '%s\n' "id $U2 only" | spike_redact)"
eq "redact numbering restarts per invocation" "id <ID-1> only" "$OUT2"

# Cases below use a fixed fake home so they behave the same on every machine.
red() { printf '%s\n' "$1" | HOME=/Users/tester spike_redact; }
redcase() { # redcase <name> <input> <leaked-substring>
  local o
  o="$(red "$2")"
  lacks "redact: $1" "$o" "$3"
}
redcase "file:// URL" 'see file:///Users/tester/a.txt now' 'a.txt'
has "redact: file:// URL keeps the scheme" "$(red 'see file:///Users/tester/a.txt now')" 'file://$HOME/... now'
redcase "JSON-escaped newline before the path" 'x\n/Users/tester/secret\nnext' 'secret'
has "redact: JSON-escaped newline keeps the escapes" "$(red 'x\n/Users/tester/secret\nnext')" 'x\n$HOME/...\nnext'
redcase "JSON-escaped slashes" '{"cwd":"\/Users\/tester\/secret"}' 'secret'
redcase "stream-json line" '{"type":"system","cwd":"/Users/tester/work/proj","session_id":"x"}' 'work/proj'
has "redact: stream-json line stays parseable JSON" "$(red '{"type":"system","cwd":"/Users/tester/work/proj","k":1}' | jq -c .cwd)" '"$HOME/..."'
eq "redact: home at end of sentence" 'cwd is $HOME/....' "$(red 'cwd is /Users/tester.')"
eq "redact: single-quoted home" "q '\$HOME/...' end" "$(red "q '/Users/tester' end")"
eq "redact: bracketed home" 'in [$HOME/...] end' "$(red 'in [/Users/tester] end')"
eq "redact: paren home path" 'at ($HOME/...) end' "$(red 'at (/Users/tester/a/b) end')"
redcase "path with a space" 'open /Users/tester/My Docs/secret now' 'secret'
redcase "path with two spaces" 'open /Users/tester/My Big Docs/secret.txt, then' 'secret'
has "redact: path with a space keeps the rest of the line" "$(red 'open /Users/tester/My Docs/secret now')" 'open $HOME/... now'
redcase "another user's home" 'see /Users/other/private/key.pem' 'private'
has "redact: another user's home is generic" "$(red 'see /Users/other/private/key.pem')" '/Users/<USER>/...'
redcase "lookalike of my home (different user name)" 'x /Users/testerx/not-home y' 'not-home'
redcase "linux-style home" 'x /home/alice/.ssh/id y' 'alice'
redcase "email at localhost" 'mail jane@localhost now' 'jane'
redcase "email at a bare host" 'mail bob@corp now' 'bob'
redcase "email with one-letter parts" 'mail a@b.c now' 'a@b.c'
redcase "email with non-ASCII local part" 'mail josé@exämple.org now' 'jos'
redcase "user@host" 'ssh deploy@build-box now' 'deploy'
has "redact: email becomes <EMAIL>" "$(red 'mail jane@localhost now')" 'mail <EMAIL> now'
eq "redact: hyphenless 32-hex id" 'id <ID-1> and <ID-1> and <ID-2>' "$(red 'id 0123456789abcdef0123456789ABCDEF and 0123456789abcdef0123456789abcdef and 3f2b8c1e9a4d4e7b8c550123456789ab')"
eq "redact: dashed and hyphenless forms of one id share a number" 'a <ID-1> b <ID-1>' "$(red 'a 3f2b8c1e-9a4d-4e7b-8c55-0123456789ab b 3f2b8c1e9a4d4e7b8c550123456789ab')"
SHA40="0123456789abcdef0123456789abcdef01234567"
eq "redact: a 40-hex git sha is not an id" "commit $SHA40" "$(red "commit $SHA40")"
eq "redact: plain text is untouched" "hello world: 3 files changed" "$(red 'hello world: 3 files changed')"
eq "redact: a lone @ is untouched" "use @ sign" "$(red 'use @ sign')"
eq "redact: redacting twice changes nothing more" "$(red 'a /Users/other/x b jane@x.io')" "$(red 'a /Users/other/x b jane@x.io' | spike_redact)"

# --- spike_resolve_path / spike_run_timeout --------------------------------------------------------------------------
mkdir -p "$SANDBOX/rp/real"
printf 'x\n' > "$SANDBOX/rp/real/target"
ln -s real/target "$SANDBOX/rp/link1"
ln -s "$SANDBOX/rp/link1" "$SANDBOX/rp/link2"
eq "resolve_path follows a symlink chain" "$SANDBOX/rp/real/target" "$(spike_resolve_path "$SANDBOX/rp/link2")"

spike_run_timeout 5 /dev/null true
eq "run_timeout returns 0 for true" "0" "$?"
spike_run_timeout 5 /dev/null false
eq "run_timeout returns the command exit code" "1" "$?"
START="$(date +%s)"
spike_run_timeout 1 /dev/null sleep 5
eq "run_timeout returns 124 on timeout" "124" "$?"
check "run_timeout returned promptly" test "$(($(date +%s) - START))" -lt 4

# Environment is scrubbed (rules 2 and 4): only PATH HOME TMPDIR LANG TERM reach the child.
ENVOUT="$SANDBOX/env.out"
: > "$ENVOUT"
SPIKE_TEST_SECRET=hunter2 SPIKE_LIVE=1 USER=tu LOGNAME=tu spike_run_live 5 "$ENVOUT" env
has "run_timeout passes PATH" "$(cat "$ENVOUT")" "PATH="
has "run_timeout passes HOME" "$(cat "$ENVOUT")" "HOME="
has "run_timeout passes USER (CLIs look up their own login by account name)" "$(cat "$ENVOUT")" "USER=tu"
lacks "run_timeout drops other variables" "$(cat "$ENVOUT")" "hunter2"
lacks "run_timeout drops SPIKE_LIVE" "$(cat "$ENVOUT")" "SPIKE_LIVE"
eq "run_timeout passes exactly 7 variables" "7" "$(wc -l < "$ENVOUT" | tr -d ' ')"

# Closed set: whatever is exported in the caller (generic probes shaped like keys, homes and config dirs), the child sees
# only HOME LANG LOGNAME PATH TERM TMPDIR USER (plus PWD SHLVL _ when a shell starts it).
closed_set_check() { # closed_set_check <label> <file>
  local label="$1" f="$2" line name stray=""
  while IFS= read -r line; do
    name="${line%%=*}"
    case "$name" in
      HOME|LANG|LOGNAME|PATH|TERM|TMPDIR|USER|PWD|SHLVL|_) ;;
      *) stray="$stray $name" ;;
    esac
  done < "$f"
  if [ -z "$stray" ]; then ok "$label: child environment is inside the closed set"; else bad "$label: stray variables:$stray"; fi
}
export FOO_API_KEY=k1 FOO_HOME=/h FOO_CONFIG_DIR=/c BAR_TOKEN=t2 HTTPS_PROXY=http://p SSH_AUTH_SOCK=/s XDG_CONFIG_HOME=/x
: > "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" env
closed_set_check "env" "$ENVOUT"
lacks "probe FOO_API_KEY is not passed" "$(cat "$ENVOUT")" "FOO_API_KEY"
lacks "probe FOO_HOME is not passed" "$(cat "$ENVOUT")" "FOO_HOME"
lacks "probe FOO_CONFIG_DIR is not passed" "$(cat "$ENVOUT")" "FOO_CONFIG_DIR"
: > "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" /bin/sh -c env
closed_set_check "sh -c env" "$ENVOUT"
: > "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" /bin/bash -c env
closed_set_check "bash -c env" "$ENVOUT"
unset FOO_API_KEY FOO_HOME FOO_CONFIG_DIR BAR_TOKEN HTTPS_PROXY SSH_AUTH_SOCK XDG_CONFIG_HOME

# The whole process group dies on timeout: a launcher that spawns a grandchild leaves no orphan.
cat > "$SANDBOX/launcher.sh" <<EOF
#!/bin/sh
sleep 30 &
echo \$! > "$SANDBOX/grandchild.pid"
wait
EOF
chmod +x "$SANDBOX/launcher.sh"
rm -f "$SANDBOX/grandchild.pid"
SPIKE_LIVE=1 spike_run_live 1 /dev/null "$SANDBOX/launcher.sh"
eq "run_timeout times out a launcher (rc)" "124" "$?"
sleep 0.3
GC="$(cat "$SANDBOX/grandchild.pid" 2>/dev/null)"
check "launcher wrote its grandchild pid" test -n "$GC"
if [ -n "$GC" ] && kill -0 "$GC" 2>/dev/null; then
  bad "grandchild was killed with the launcher"
  kill -9 "$GC" 2>/dev/null
else
  ok "grandchild was killed with the launcher"
fi

# A command that exits normally but leaves a background child is swept too.
cat > "$SANDBOX/leaver.sh" <<EOF
#!/bin/sh
sleep 30 </dev/null >/dev/null 2>&1 &
echo \$! > "$SANDBOX/leftover.pid"
exit 0
EOF
chmod +x "$SANDBOX/leaver.sh"
SPIKE_LIVE=1 spike_run_live 5 /dev/null "$SANDBOX/leaver.sh"
eq "run_timeout returns the leaver's exit code" "0" "$?"
sleep 0.3
LO="$(cat "$SANDBOX/leftover.pid" 2>/dev/null)"
if [ -n "$LO" ] && kill -0 "$LO" 2>/dev/null; then
  bad "leftover background child was swept"
  kill -9 "$LO" 2>/dev/null
else
  ok "leftover background child was swept"
fi

# Signals sent to the caller must not leave the command (or its grandchild) running.
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
for sig in TERM HUP; do
  rm -f "$SANDBOX/sig.pids"
  cat > "$SANDBOX/siglauncher.sh" <<EOF
#!/bin/sh
sleep 33 &
echo "\$\$ \$!" > "$SANDBOX/sig.pids.tmp"
mv "$SANDBOX/sig.pids.tmp" "$SANDBOX/sig.pids"
wait
EOF
  chmod +x "$SANDBOX/siglauncher.sh"
  SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 60 /dev/null "$2"; echo AFTER' _ "$COMMON" "$SANDBOX/siglauncher.sh" > "$SANDBOX/sig.out" 2>/dev/null &
  CALLER=$!
  n=0
  while [ ! -s "$SANDBOX/sig.pids" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  read -r LPID GPID < "$SANDBOX/sig.pids"
  if alive "$LPID" && alive "$GPID"; then ok "SIG$sig: launcher and grandchild are running before the signal"; else bad "SIG$sig: launcher and grandchild are running before the signal"; fi
  kill -s "$sig" "$CALLER"
  wait "$CALLER" 2>/dev/null
  RC=$?
  sleep 0.8
  if alive "$LPID"; then bad "SIG$sig to the caller: launcher is gone"; kill -9 "$LPID" 2>/dev/null; else ok "SIG$sig to the caller: launcher is gone"; fi
  if alive "$GPID"; then bad "SIG$sig to the caller: grandchild is gone"; kill -9 "$GPID" 2>/dev/null; else ok "SIG$sig to the caller: grandchild is gone"; fi
  if alive "$CALLER"; then bad "SIG$sig to the caller: caller exited"; kill -9 "$CALLER" 2>/dev/null; else ok "SIG$sig to the caller: caller exited"; fi
  lacks "SIG$sig to the caller: nothing ran afterwards" "$(cat "$SANDBOX/sig.out")" "AFTER"
  check "SIG$sig to the caller: exit status is a signal status" test "$RC" -gt 128
done

# The caller's own TERM trap is restored after a run.
out="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; trap "echo MYTRAP" TERM; spike_run_live 5 /dev/null true; trap -p TERM' _ "$COMMON" 2>/dev/null)"
has "caller TERM trap is restored after spike_run_live" "$out" "echo MYTRAP"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
