#!/bin/bash
# Shared helpers for the Phase 0 spikes. Source this file from scripts only, never from an interactive shell (the live
# gate can terminate the shell that sourced it). Do not execute it.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Works on macOS /bin/bash 3.2 (no associative arrays, no mapfile, no case-conversion expansions).
# It never changes the caller's shell options (no set -e / -u here). It does install one TERM trap (see
# spike_require_live) unless the caller already has its own.
#
# Hard-rule notes (round 7: one helper, by absolute path, deciding by file identity):
#   - Every security decision is made by lib/runner.pl, which this file starts ONLY as
#       /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_x=... /usr/bin/perl runner.pl <subcommand> ...
#     Interpreter, env and helper are constant absolute paths. The helper's arguments come after the interpreter path, so
#     env cannot read any of them as VAR=value; the caller's PERL* variables are dropped by env -i; the caller's PATH,
#     HOME, TMPDIR, LANG, TERM, USER, LOGNAME and SPIKE_LIVE reach the helper as SPIKE_IN_* values. No security decision
#     uses a program found on PATH (jq and git for display probes run through the helper with a closed environment).
#   - A command is resolved ONCE, physically (lstat walk, at most 40 links), refusing any control character, and the
#     resolved path is what runs. The helper compares (device, inode), not strings, for the CLI homes (rule 4).
#   - spike_run_timeout / spike_run_live / spike_run_status / spike_run_timed are the only helpers that start a command.
#     The helper puts itself at the head of a NEW process group, forks the command into that group and watches it: it
#     kills the group on timeout, on TERM/INT/HUP, and when the caller disappears (the helper's parent pid changes). A
#     SIGKILL to the caller or to the caller's whole process group therefore cannot orphan the command; a SIGKILL to the
#     helper's own group kills the command with it. A SIGKILL sent to the helper process alone (by pid) is the one case
#     that can leave the command running: nothing is left to sweep it. Identity, not name: without SPIKE_LIVE=1,
#     spike_run_timeout runs only a short list of harmless programs whose resolved path is in a system directory.
#   - Children run headless: stdin is /dev/null, output goes to the outfile, and they are not in a new session. A CLI
#     that opens the terminal device is out of scope (rule 3).
#   - SPIKE_LIVE=1 is a guard against accidents, not an approval. Only the human sets it.
#   - Registration (spike_mark_verified / spike_register_cli) opens the file once, copies from that descriptor into a
#     private 0700 directory the helper creates, runs the fixed codesign on the COPY and records the copy's sha256.
#     spike_run_status re-hashes the copy before it runs it (rule 6). The verify directory cannot be chosen by the caller.
#   - Round 8 policy: the CLI-home names come from compliance/denylist.txt at run time (every operation fails closed, rc 121,
#     if it is unusable). A run refuses (rc 125) unless HOME is the account's password-database home, and the child's HOME
#     is always that home. The outfile is opened O_NOFOLLOW|O_APPEND, mode 0600, and a symlink, a hard link, a non-regular
#     file (the null device excepted) or a parent inside a CLI home is refused. spike_run_timed runs exactly `jq --version`
#     or `git --version`. A pinned CLI name (claude, codex) runs live only as the registered, hash-verified copy.

# Load-once guard (round 8): the library is "loaded" only if its own function exists in THIS shell. An inherited variable
# cannot make a fresh shell skip loading (and so skip the live gate and the TERM trap).
if declare -F spike_require_live >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

# ---- FIXED PATHS (rule 6) -------------------------------------------------------------------------------------------
# Constants, not overridable. The codesign path is a constant inside lib/runner.pl (CODESIGN_BIN); the tests make a sandbox
# copy of runner.pl with only that line rewritten, and the shipped file is checked to keep /usr/bin/codesign.
readonly SPIKE_PERL="/usr/bin/perl"
readonly SPIKE_ENVBIN="/usr/bin/env"

# SPIKE_DIR without command substitution tricks that strip bytes: the directory holding this file's parent.
_spike_src="${BASH_SOURCE[0]}"
case "$_spike_src" in
  */*) _spike_src="${_spike_src%/*}" ;;
  *) _spike_src="." ;;
esac
SPIKE_DIR="$(CDPATH= cd -P -- "$_spike_src/.." 2>/dev/null && pwd -P)"
unset _spike_src
SPIKE_HELPER="$SPIKE_DIR/lib/runner.pl"

# spike_require_live ends the whole calling script by sending TERM to it; this trap turns that into exit status 3.
if [ -z "$(trap -p TERM)" ]; then
  trap 'exit 3' TERM
fi

spike_err() { printf 'spike: %s\n' "$*" >&2; }

# Root under which every scratch repo lives. Physical path, so comparisons are not fooled by /var -> /private/var.
spike_root() {
  local base="${TMPDIR:-/tmp}"
  case "$base" in *[[:cntrl:]]*) base="/tmp" ;; esac
  base="${base%/}"
  [ -n "$base" ] || base="/tmp"
  if [ -d "$base" ]; then
    base="$(cd "$base" && pwd -P)"
  fi
  # Rule 4: a scratch root inside a CLI home is refused (nothing printed, rc 1). Judged by identity, and also when the
  # directory does not exist yet.
  if ! _spike_dir_outside_cli_homes "$base/harness-spike"; then
    spike_err "refusing a scratch root inside a CLI home directory (or one that cannot be checked): $base"
    return 1
  fi
  printf '%s/harness-spike\n' "$base"
}

# git with a fixed identity and no hooks, so a scratch repo never depends on (or reads) the user's git setup.
_spike_git() {
  git -c user.name="spike" -c user.email="spike@example.invalid" \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# spike_scratch_repo -> creates <root>/<run-id>/repo with one commit, echoes the repo path.
spike_scratch_repo() {
  local root run repo stamp
  root="$(spike_root)" || return 1
  [ -n "$root" ] || return 1
  mkdir -p "$root" || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  run="$(mktemp -d "$root/run-$stamp-XXXXXX")" || return 1
  repo="$run/repo"
  mkdir -p "$repo" || return 1
  _spike_git -C "$repo" init -q -b main || return 1
  printf '# scratch repo for a harness spike\n' > "$repo/README.md"
  printf 'notes for the spike\n' > "$repo/notes.txt"
  _spike_git -C "$repo" add README.md notes.txt || return 1
  _spike_git -C "$repo" commit -q -m "initial commit" || return 1
  printf '%s\n' "$repo"
}

# spike_worktree_add <repo> <name> -> git worktree add -b spike/<name> <repo>-wt/<name>; echoes the worktree path.
spike_worktree_add() {
  local repo="${1:-}" name="${2:-}" wt
  if [ -z "$repo" ] || [ -z "$name" ]; then
    spike_err "usage: spike_worktree_add <repo> <name>"
    return 2
  fi
  case "$name" in
    *[!A-Za-z0-9._-]*|.*) spike_err "bad worktree name: $name"; return 2 ;;
  esac
  [ -d "$repo/.git" ] || { spike_err "not a repo: $repo"; return 2; }
  wt="$repo-wt/$name"
  mkdir -p "$repo-wt" || return 1
  _spike_git -C "$repo" worktree add -q -b "spike/$name" "$wt" >/dev/null || return 1
  printf '%s\n' "$wt"
}

# spike_cleanup <run-dir> -> remove spike worktrees, prune, delete the run dir.
# Refuses (returns 2) anything that is not strictly inside <TMPDIR>/harness-spike/ (physical or logical spelling).
spike_cleanup() {
  local target="${1:-}" root lroot phys line
  root="$(spike_root)" || { spike_err "cleanup refused (no safe scratch root)"; return 2; }
  [ -n "$root" ] || { spike_err "cleanup refused (no scratch root)"; return 2; }
  lroot="${TMPDIR:-/tmp}"
  lroot="${lroot%/}/harness-spike"
  if [ -z "$target" ]; then
    spike_err "cleanup: no path given"
    return 2
  fi
  case "$target" in
    *[[:cntrl:]]*) spike_err "cleanup refused (control character in path)"; return 2 ;;
  esac
  while [ "${target%/}" != "$target" ]; do target="${target%/}"; done
  case "$target" in
    /*) ;;
    *) spike_err "cleanup refused (not absolute): $target"; return 2 ;;
  esac
  case "$target/" in
    */../*|*/./*|*//*) spike_err "cleanup refused (unsafe path): $target"; return 2 ;;
  esac
  case "$target" in
    "$root"/?*|"$lroot"/?*) ;;
    *) spike_err "cleanup refused (outside $root): $target"; return 2 ;;
  esac
  if [ -L "$target" ]; then
    spike_err "cleanup refused (symlink): $target"
    return 2
  fi
  if [ ! -e "$target" ]; then
    return 0
  fi
  # The helper resolves physically and refuses control characters, so the string compared below is the path that is removed.
  phys="$(spike_resolve_path "$target")" || { spike_err "cleanup refused (cannot resolve): $target"; return 2; }
  [ -d "$phys" ] || { spike_err "cleanup refused (not a directory): $target"; return 2; }
  case "$phys" in
    "$root"/?*) ;;
    *) spike_err "cleanup refused (resolves outside $root): $target"; return 2 ;;
  esac

  if [ -d "$phys/repo/.git" ]; then
    # First entry of the porcelain list is the main worktree; every later one is a spike worktree.
    git -C "$phys/repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | sed 1d |
      while IFS= read -r line; do
        case "$line" in
          "$phys"/?*) git -C "$phys/repo" worktree remove --force "$line" >/dev/null 2>&1 ;;
        esac
      done
    git -C "$phys/repo" worktree prune >/dev/null 2>&1
  fi
  rm -rf -- "$phys"
}

# spike_require_live -> stop the calling SCRIPT (exit status 3) unless SPIKE_LIVE is exactly "1".
# Call it first in every script that starts a real CLI session. SPIKE_LIVE=1 is set by the human, never by an agent.
# It also works from inside $(...), pipes and subshells: those only end their own subshell with `exit`, so it first
# sends TERM to the top-level script ($$), whose trap (installed above) exits 3. Call it at the top level of the script,
# as the first statement, and never override the TERM trap. As a fail-safe, a detached watchdog sends KILL to the
# top-level script 0.3 s later if it is somehow still running (for example because it replaced the TERM trap).
spike_require_live() {
  if [ "${SPIKE_LIVE:-}" != "1" ]; then
    _spike_stop_script "refusing to run: this step calls a real CLI. Re-run with SPIKE_LIVE=1 to opt in (human only)."
  fi
}

# spike_capture_dir <cli> -> echoes <captures root>/<cli>/<UTC timestamp>/ (created). The default root is
# spike/captures, which spike/.gitignore ignores. A root inside any git repo is refused unless git ignores it.
spike_capture_dir() {
  local cli="${1:-}" root dir anc
  case "$cli" in
    ""|*[!A-Za-z0-9._-]*|.*) spike_err "bad capture name: $cli"; return 2 ;;
  esac
  root="${SPIKE_CAPTURES_ROOT:-$SPIKE_DIR/captures}"
  case "$root" in /*) ;; *) root="$PWD/$root" ;; esac
  case "$root" in *[[:cntrl:]]*) spike_err "capture root refused (control character in path)"; return 2 ;; esac
  while [ "${root%/}" != "$root" ] && [ "$root" != "/" ]; do root="${root%/}"; done
  # Rule 4: a capture root inside a CLI home is refused (judged by identity, also when it does not exist yet).
  if ! _spike_dir_outside_cli_homes "$root"; then
    spike_err "capture root is inside a CLI home directory (or cannot be checked): $root"
    return 2
  fi
  dir="$root/$cli/$(date -u +%Y%m%dT%H%M%SZ)/"
  anc="$root"
  while [ ! -d "$anc" ] && [ "$anc" != "/" ]; do anc="$(dirname "$anc")"; done
  if git -C "$anc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$anc" check-ignore -q -- "$dir" 2>/dev/null; then
      spike_err "capture root is inside a git repo and not ignored by it: $root"
      return 2
    fi
  fi
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# spike_redact -> stdin to stdout. Rewrites, in this order (n in <ID-n> is stable within one invocation):
#   JSON-escaped slashes (\/)   -> /
#   scratch run dir             -> <WORKTREE>
#   $HOME paths (incl. spaces)  -> $HOME/...
#   any /Users/<name> or /home/<name> path -> /Users/<USER>/...
#   any @ between two non-space tokens (emails, user@host) -> <EMAIL>
#   UUIDs, dashed or 32 hex     -> <ID-n>
# Over-redacting is the intended failure mode.
spike_redact() {
  SPIKE_R_ROOT1="$(spike_root 2>/dev/null)" SPIKE_R_ROOT2="${TMPDIR:-/tmp}" SPIKE_R_HOME="${HOME:-}" awk '
    function rep(s, n,   o, i) { o = ""; for (i = 0; i < n; i++) o = o s; return o }
    function isdelim(c) { return (c == " " || c == "\t" || index(DELIMS, c) > 0) }

    # First index after a path that starts just before position j. A path stops at a quote, backslash, angle or
    # closing bracket, at a , ; : followed by a space, and at a space unless one of the next two words has a slash
    # (so "My Docs/secret" stays one path).
    function tail_end(s, j,   n, c, rest, k, tok, found) {
      n = length(s)
      while (j <= n) {
        c = substr(s, j, 1)
        if (index(TERMS, c) > 0) break
        if (c == " " || c == "\t") {
          rest = substr(s, j + 1)
          found = 0
          for (k = 0; k < 2; k++) {
            if (!match(rest, /^[^ \t]+/)) break
            tok = substr(rest, 1, RLENGTH)
            if (index(TERMS, substr(tok, 1, 1)) > 0) break
            if (index(tok, "/") > 0) { found = 1; break }
            rest = substr(rest, RLENGTH + 1)
            if (substr(rest, 1, 1) != " ") break
            rest = substr(rest, 2)
          }
          if (!found) break
          j++
          continue
        }
        if ((c == "," || c == ";" || c == ":") && (j == n || substr(s, j + 1, 1) ~ /[ \t]/)) break
        j++
      }
      return j
    }

    function scratch(s, root,   out, i, rest) {
      if (root == "") return s
      out = ""
      while ((i = index(s, root)) > 0) {
        rest = substr(s, i + length(root))
        if (match(rest, /^\/[^\/ \t"]+/)) {
          out = out substr(s, 1, i - 1) "<WORKTREE>"
          s = substr(rest, RLENGTH + 1)
        } else {
          out = out substr(s, 1, i + length(root) - 1)
          s = rest
        }
      }
      return out s
    }

    # Replace every occurrence of head (an absolute path such as the home dir) plus the path below it.
    function homes(s, head,   out, i, j, c) {
      if (head == "" || head == "/") return s
      out = ""
      while ((i = index(s, head)) > 0) {
        j = i + length(head)
        c = substr(s, j, 1)
        if (c == "/") {
          j = tail_end(s, j + 1)
          out = out substr(s, 1, i - 1) "$HOME/..."
          s = substr(s, j)
        } else if (c == "" || (c !~ /[A-Za-z0-9_-]/ && !(c == "." && substr(s, j + 1, 1) ~ /[A-Za-z0-9]/))) {
          out = out substr(s, 1, i - 1) "$HOME/..."
          s = substr(s, j)
        } else {
          out = out substr(s, 1, j - 1)
          s = substr(s, j)
        }
      }
      return out s
    }

    # Any other user home: base is "/Users/" or "/home/".
    function users(s, base,   out, i, j, k) {
      out = ""
      while ((i = index(s, base)) > 0) {
        j = i + length(base)
        k = j
        while (k <= length(s) && index(DELIMS ":/ \t", substr(s, k, 1)) == 0) k++
        if (k == j) {
          out = out substr(s, 1, j - 1)
          s = substr(s, j)
          continue
        }
        if (substr(s, k, 1) == "/") k = tail_end(s, k + 1)
        out = out substr(s, 1, i - 1) base "<USER>/..."
        s = substr(s, k)
      }
      return out s
    }

    function emails(s,   out, p, l, r, n) {
      out = ""
      while ((p = index(s, "@")) > 0) {
        l = p - 1
        while (l >= 1 && !isdelim(substr(s, l, 1))) l--
        n = length(s)
        r = p + 1
        while (r <= n && !isdelim(substr(s, r, 1))) r++
        if (p - 1 > l && r - 1 > p) {
          out = out substr(s, 1, l) "<EMAIL>"
          s = substr(s, r)
        } else {
          out = out substr(s, 1, p)
          s = substr(s, p + 1)
        }
      }
      return out s
    }

    function uuids(s,   pass, re, out, st, ln, m, key, pre, post) {
      for (pass = 1; pass <= 2; pass++) {
        re = (pass == 1) ? uuid_re : hex32_re
        out = ""
        while (match(s, re)) {
          st = RSTART; ln = RLENGTH
          m = substr(s, st, ln)
          pre = (st > 1) ? substr(s, st - 1, 1) : substr(out, length(out), 1)
          post = substr(s, st + ln, 1)
          if (pass == 2 && (pre ~ /[0-9a-fA-F]/ || post ~ /[0-9a-fA-F]/)) {
            out = out substr(s, 1, st + ln - 1)
          } else {
            key = tolower(m)
            gsub(/-/, "", key)
            if (!(key in ids)) { nids++; ids[key] = nids }
            out = out substr(s, 1, st - 1) "<ID-" ids[key] ">"
          }
          s = substr(s, st + ln)
        }
        s = out s
      }
      return s
    }

    BEGIN {
      h = "[0-9a-fA-F]"
      uuid_re = rep(h, 8) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 12)
      hex32_re = rep(h, 32)
      TERMS = "\"\047\\<>`)]}"
      DELIMS = TERMS "(,;[{"
      root1 = ENVIRON["SPIKE_R_ROOT1"]
      root2 = ENVIRON["SPIKE_R_ROOT2"]; sub(/\/+$/, "", root2); if (root2 != "") root2 = root2 "/harness-spike"
      home = ENVIRON["SPIKE_R_HOME"]; sub(/\/+$/, "", home)
      nids = 0
    }
    {
      line = $0
      gsub("\\\\/", "/", line)
      line = scratch(line, root1)
      if (root2 != root1) line = scratch(line, root2)
      line = homes(line, home)
      line = users(line, "/Users/")
      line = users(line, "/home/")
      line = emails(line)
      line = uuids(line)
      print line
    }
  '
}

# ---- the helper (round 7) ---------------------------------------------------------------------------------------------
# _spike_inputs fills _SPIKE_IN with the SPIKE_IN_* assignments the helper reads. The array is never empty (bash 3.2 with
# set -u fails on an empty array). Values are data: they come after the constant interpreter path, so env never parses them.
_SPIKE_IN=()
_spike_inputs() {
  _SPIKE_IN=("SPIKE_IN_MARK=1")
  if [ "${PATH+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_PATH=$PATH"; fi
  if [ "${HOME+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_HOME=$HOME"; fi
  if [ "${TMPDIR+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_TMPDIR=$TMPDIR"; fi
  if [ "${LANG+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_LANG=$LANG"; fi
  if [ "${TERM+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_TERM=$TERM"; fi
  if [ "${USER+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_USER=$USER"; fi
  if [ "${LOGNAME+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_LOGNAME=$LOGNAME"; fi
  if [ "${SPIKE_LIVE+set}" = "set" ]; then _SPIKE_IN[${#_SPIKE_IN[@]}]="SPIKE_IN_LIVE=$SPIKE_LIVE"; fi
}

# _spike_have_helper: the constant interpreter, env and the helper file all exist.
_spike_have_helper() {
  if [ -x "$SPIKE_PERL" ] && [ -x "$SPIKE_ENVBIN" ] && [ -f "$SPIKE_HELPER" ]; then return 0; fi
  spike_err "needs $SPIKE_PERL, $SPIKE_ENVBIN and $SPIKE_HELPER"
  return 1
}

# _spike_helper <subcommand> [args...]: the one way to run the helper in the foreground. Interpreter and env are constant
# absolute paths; every argument after them is data.
_spike_helper() {
  _spike_inputs
  "$SPIKE_ENVBIN" -i PATH=/usr/bin:/bin LC_ALL=C "${_SPIKE_IN[@]}" "$SPIKE_PERL" "$SPIKE_HELPER" "$@"
}

# spike_resolve_path <path> -> echoes the physical path (lstat walk, at most 40 links, runs of / collapsed, a relative path
# made absolute from the cwd). Refuses an empty path, a trailing slash, a final . or .., and any control character.
spike_resolve_path() {
  [ -n "${1:-}" ] || return 1
  _spike_have_helper || return 1
  _spike_helper resolve "$1" 2>/dev/null
}

# spike_magic_ok <file>: 0 if <file> is a regular, non-symlink, singly linked file whose first four bytes are a Mach-O or
# universal (fat) magic. The helper opens it once (O_NOFOLLOW) and reads exactly four bytes from that descriptor.
spike_magic_ok() {
  [ -n "${1:-}" ] || return 1
  _spike_have_helper || return 1
  _spike_helper magic "$1" >/dev/null 2>&1
}

# spike_under_cli_home <path>: 0 (refuse; rule 4) if the path is, or lies inside, one of the CLI homes of the account's
# password-database home or of an absolute $HOME (compared by device and inode), if it is a hard-linked regular file, or
# if it cannot be resolved. 1 if it is outside every CLI home.
spike_under_cli_home() {
  local rc
  [ -n "${1:-}" ] || return 0
  _spike_have_helper || return 0
  _spike_helper clihome "$1" >/dev/null 2>&1
  rc=$?
  # Fail closed: only the helper's own "outside every CLI home" answer (1) lifts the refusal. Any other status (a crashed
  # helper, the unusable-denylist status) means refuse.
  [ "$rc" -eq 1 ] && return 1
  return 0
}

# _spike_dir_outside_cli_homes <path>: 0 only if the directory (which may not exist yet) is outside every CLI home. Any other
# answer, including an unusable CLI-home denylist, is "not outside".
_spike_dir_outside_cli_homes() {
  local rc
  [ -n "${1:-}" ] || return 1
  _spike_have_helper || return 1
  _spike_helper clihome-new "$1" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ]
}

# spike_tool_path <name> -> echoes the physical path of a probe tool (jq or git) found on PATH, only if it is a native
# executable in a system or package-manager prefix (a wrapper script or a copy in a user directory is refused); rc 1 if none.
spike_tool_path() {
  [ -n "${1:-}" ] || return 1
  _spike_have_helper || return 1
  _spike_helper tool-path "$1" 2>/dev/null
}

# ---- the private verify directory ---------------------------------------------------------------------------------------
# Only the helper creates it (mode 0700, in a safe temporary directory that is not inside a CLI home, with a registry file
# of its own). There is no setter: a caller cannot point the library at another directory, and the helper re-validates the
# recorded name on every use, so assigning the variable below by hand gains nothing.
_SPIKE_VERIFY_DIR=""

# spike_verify_init: sweeps stale verify directories (dead owner pid) and creates this process's directory. Sets the
# recorded directory (shell state: do not call it inside $(...)). Returns 5 if the temporary directory is unsafe (writable
# by others without the sticky bit, or inside a CLI home): needs human review. Other failures return 1.
spike_verify_init() {
  local d rc
  [ -z "$_SPIKE_VERIFY_DIR" ] || return 0
  _spike_have_helper || return 1
  _spike_helper vdir-sweep "$$" >/dev/null 2>&1
  d="$(_spike_helper vdir-create "$$" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$d" ]; then
    if [ "$rc" -eq 5 ]; then return 5; fi
    if [ "$rc" -eq 121 ]; then _spike_denylist_fail; fi
    return 1
  fi
  _SPIKE_VERIFY_DIR="$d"
  return 0
}

# spike_verify_dir: echoes the recorded directory (empty before spike_verify_init).
spike_verify_dir() { printf '%s\n' "$_SPIKE_VERIFY_DIR"; }

# spike_verify_cleanup: removes the directory (the helper validates it first). Safe to call twice.
spike_verify_cleanup() {
  if [ -n "$_SPIKE_VERIFY_DIR" ]; then
    _spike_helper vdir-remove "$_SPIKE_VERIFY_DIR" >/dev/null 2>&1
    _SPIKE_VERIFY_DIR=""
  fi
  return 0
}

# ---- registration (rule 6) ---------------------------------------------------------------------------------------------------
# SPIKE_SIG_TEXT          signature column text of the last registration
# SPIKE_VERIFIED_COPY     path of the registered private copy (the ONLY path spike_run_status accepts)
# SPIKE_REG_STATUS        verified | notfound | unresolvable | clihome | hardlink | script | other | signer | copyfail | badpath | badcli | error
# SPIKE_REG_KIND          mach-o | script | other | refused | -
# SPIKE_REG_PATH          the resolved original (or the PATH hit when it could not be resolved)
SPIKE_SIG_TEXT=""
SPIKE_VERIFIED_COPY=""
SPIKE_REG_STATUS=""
SPIKE_REG_KIND=""
SPIKE_REG_PATH=""

# _spike_register <cli> <path|name> <src>: one helper call. Returns 0 verified, 4 not found on PATH, 2 anything else.
_spike_register() {
  local cli="$1" mode="$2" src="$3" out rc rest tab
  tab="$(printf '\t')"
  SPIKE_SIG_TEXT=""
  SPIKE_VERIFIED_COPY=""
  SPIKE_REG_STATUS="error"
  SPIKE_REG_KIND="-"
  SPIKE_REG_PATH=""
  if ! spike_verify_init; then
    SPIKE_SIG_TEXT="NOT VERIFIED (no private verify directory)"
    return 2
  fi
  out="$(_spike_helper register "$_SPIKE_VERIFY_DIR" "$cli" "$mode" "$src" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    SPIKE_SIG_TEXT="NOT VERIFIED (registration helper failed)"
    return 2
  fi
  SPIKE_REG_STATUS="${out%%"$tab"*}"
  rest="${out#*"$tab"}"
  SPIKE_REG_KIND="${rest%%"$tab"*}"
  rest="${rest#*"$tab"}"
  SPIKE_REG_PATH="${rest%%"$tab"*}"
  rest="${rest#*"$tab"}"
  SPIKE_VERIFIED_COPY="${rest%%"$tab"*}"
  SPIKE_SIG_TEXT="${rest#*"$tab"}"
  case "$SPIKE_REG_STATUS" in
    verified) return 0 ;;
    notfound) return 4 ;;
  esac
  SPIKE_VERIFIED_COPY=""
  return 2
}

# spike_mark_verified <absolute path> <cli>: copy a regular executable Mach-O into the private verify directory, check the
# COPY with the pinned signer of <cli> (claude or codex), and register it. Sets SPIKE_VERIFIED_COPY: pass THAT path to
# spike_run_status. Returns 2 and registers nothing for anything else (relative path, symlink, directory, control character,
# hard link, CLI-home file that is not a Mach-O, non-Mach-O, wrong signer). Preflight only.
spike_mark_verified() {
  local p="${1:-}" name="${2:-}"
  SPIKE_SIG_TEXT=""
  SPIKE_VERIFIED_COPY=""
  case "$p" in
    /*) ;;
    *) spike_err "mark_verified: not an absolute path"; return 2 ;;
  esac
  case "$p" in *[[:cntrl:]]*) spike_err "mark_verified: control character in path"; return 2 ;; esac
  if ! _spike_register "$name" path "$p"; then
    spike_err "mark_verified: refused: ${SPIKE_SIG_TEXT:-$SPIKE_REG_STATUS}"
    return 2
  fi
  return 0
}

# spike_register_cli <name>: preflight's entry. Looks <name> up on PATH inside the helper (first match wins), classifies and
# registers it in one pass. Returns 0 verified, 4 not installed, 2 otherwise; SPIKE_REG_STATUS/KIND/PATH/SIG_TEXT say why.
spike_register_cli() {
  case "${1:-}" in ""|*[!A-Za-z0-9._-]*) return 2 ;; esac
  _spike_register "$1" name "$1"
}

# ---- command runner -------------------------------------------------------------------------------------------------
# Four entry points start a command. Each either runs it with a closed environment under the helper's in-group watchdog,
# or refuses and starts nothing:
#   spike_run_timeout  non-live. Runs only a command whose IDENTITY is on the harmless list (checked by the helper on the
#                      resolved path). Anything else needs SPIKE_LIVE=1, including every provider CLI, whatever its name.
#   spike_run_live     always needs SPIKE_LIVE=1. Every real prompt or session goes through here. A command whose basename (or
#                      resolved basename) is a pinned CLI name (claude, codex) runs ONLY as the current registered,
#                      hash-verified copy (SPIKE_VERIFIED_COPY); SPIKE_LIVE does not lift that (rule 6).
#   spike_run_status   only a private verified copy that registration produced (SPIKE_VERIFIED_COPY), only if its content
#                      still has the recorded sha256, and only the three status shapes. SPIKE_LIVE does not lift this.
#   spike_run_timed    exactly `jq --version` and `git --version` (display only), nothing else: closed environment.
# Exit codes: the command's own; 124 timeout; 2 usage / cannot resolve; 3 refused by the gate (the calling SCRIPT is
# stopped, see spike_require_live); 121 the CLI-home denylist file is unusable (nothing runs); 125 the helper refused at exec
# time (HOME is not the account home, the output file is refused, or the policy was not met). The helper's own codes are
# also the command's: 126 cannot execute, 127 not found, 143/130/129 after TERM/INT/HUP. A command that itself exits with
# 121, 124, 125, 126, 127 or 143 is therefore indistinguishable from the helper's code of that number; callers that must tell
# them apart check the output file, not the status alone.

# _spike_secs <digits> -> echoes the decimal value (leading zeros are not octal), 1..3600; rc 1 otherwise.
_spike_secs() {
  local s="${1:-}"
  case "$s" in ""|*[!0-9]*) return 1 ;; esac
  s="${s#"${s%%[!0]*}"}"
  [ -n "$s" ] || return 1
  [ "${#s}" -le 4 ] || return 1
  if [ "$s" -ge 1 ] && [ "$s" -le 3600 ]; then printf '%s' "$s"; return 0; fi
  return 1
}

_SPIKE_SECS=""
_spike_run_args_ok() { # usage check shared by the entry points: needs seconds, outfile, cmd
  if [ "$#" -lt 3 ]; then
    spike_err "usage: <seconds> <outfile> <cmd> [args...]"
    return 2
  fi
  _SPIKE_SECS="$(_spike_secs "$1")" || { spike_err "bad timeout (digits only, 1 to 3600): $1"; return 2; }
  case "$2" in "") spike_err "bad outfile"; return 2 ;; esac
  _spike_have_helper || return 2
  return 0
}

# In the caller: a TERM, INT or HUP. If the helper exists, forward TERM to it, wait for it to sweep the group, then exit. If
# it does not yet (the signal landed between `&` and `$!`), record it; _spike_exec handles it right after the assignment.
_spike_forward() {
  if [ -z "${_SPIKE_BG:-}" ]; then
    _SPIKE_BG_PENDING="$1"
    return 0
  fi
  kill -s TERM "$_SPIKE_BG" 2>/dev/null
  wait "$_SPIKE_BG" 2>/dev/null
  exit "$1"
}

# _spike_exec <mode> <seconds> <outfile> <vdir|-> <resolved-path> [args...] -- no gate here; callers decide. The helper is
# started as a plain background command (its parent is THIS shell, whose death it watches). Returns the command's exit code
# (124 on timeout, 128+n when the helper swept the group after a signal).
_spike_exec() {
  local rc old_int old_term old_hup
  old_int="$(trap -p INT)"
  old_term="$(trap -p TERM)"
  old_hup="$(trap -p HUP)"
  _spike_inputs
  _SPIKE_BG=""
  _SPIKE_BG_PENDING=""
  trap '_spike_forward 130' INT
  trap '_spike_forward 143' TERM
  trap '_spike_forward 129' HUP
  "$SPIKE_ENVBIN" -i PATH=/usr/bin:/bin LC_ALL=C "${_SPIKE_IN[@]}" "$SPIKE_PERL" "$SPIKE_HELPER" run "$@" </dev/null &
  _SPIKE_BG=$!
  if [ -n "$_SPIKE_BG_PENDING" ]; then
    kill -s TERM "$_SPIKE_BG" 2>/dev/null
    wait "$_SPIKE_BG" 2>/dev/null
    exit "$_SPIKE_BG_PENDING"
  fi
  { wait "$_SPIKE_BG"; } 2>/dev/null
  rc=$?
  _SPIKE_BG=""
  trap - INT TERM HUP
  if [ -n "$old_int" ]; then eval "$old_int"; fi
  if [ -n "$old_term" ]; then eval "$old_term"; fi
  if [ -n "$old_hup" ]; then eval "$old_hup"; fi
  if [ -n "$_SPIKE_BG_PENDING" ]; then exit "$_SPIKE_BG_PENDING"; fi
  return "$rc"
}

# _spike_stop_script <message>: refuse and end the calling SCRIPT with status 3, whatever SPIKE_LIVE says. It sends TERM
# to the top-level script ($$), whose TERM trap exits 3; a detached watchdog sends KILL 0.3 s later as a fail-safe.
_spike_stop_script() {
  [ -z "${1:-}" ] || spike_err "$1"
  kill -s TERM "$$" 2>/dev/null
  ( sleep 0.3; if kill -0 "$$" 2>/dev/null; then kill -s KILL "$$" 2>/dev/null; fi ) >/dev/null 2>&1 &
  exit 3
}

# _spike_denylist_fail: the helper could not use compliance/denylist.txt (rc 121). Nothing was started.
_spike_denylist_fail() {
  spike_err "the CLI-home denylist (compliance/denylist.txt) is missing, empty or malformed; every operation is refused"
}

# _spike_run_live_policy <seconds> <outfile> <cmd> [args...]: the live path shared by spike_run_timeout (after its gate) and
# spike_run_live. SPIKE_LIVE=1 is already required. The helper refuses (rc 3) a command whose basename or resolved basename is
# a pinned CLI name (claude, codex) unless it is the current registered, hash-verified copy; that stops the calling SCRIPT.
_spike_run_live_policy() {
  local secs="$1" out="$2" cmd="$3" res rc
  shift 3
  res="$(_spike_helper gate live "${_SPIKE_VERIFY_DIR:--}" "$cmd" "$@" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 121 ]; then _spike_denylist_fail; return 121; fi
  if [ "$rc" -eq 3 ]; then
    _spike_stop_script "refusing: $cmd is named like a pinned CLI and is not the current registered, hash-verified copy (rule 6); pass \"\$SPIKE_VERIFIED_COPY\" after preflight registration"
  fi
  if [ "$rc" -ne 0 ]; then
    spike_err "cannot resolve command: $cmd"
    return 2
  fi
  _spike_exec live "$secs" "$out" "${_SPIKE_VERIFY_DIR:--}" "$res" "$@"
}

# spike_run_timeout <seconds> <outfile> <cmd> [args...]
# Non-live runner. Runs only the harmless identities the helper lists (git --version, the codesign read-only shapes on a
# path inside the private verify directory, true, false, sleep, echo, printf, each only from a system directory). The words
# in the ARGUMENTS of those commands are not examined (they cannot launch anything once the identity is enforced); a provider
# word in the program name is never ungated. Everything else needs SPIKE_LIVE=1, and a pinned CLI name needs the registered
# copy even then. The command is resolved once and the resolved path is what runs.
spike_run_timeout() {
  local secs out cmd res rc
  _spike_run_args_ok "$@" || return 2
  secs="$_SPIKE_SECS" out="$2" cmd="$3"
  shift 3
  res="$(_spike_helper gate ungated "${_SPIKE_VERIFY_DIR:--}" "$cmd" "$@" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    _spike_exec ungated "$secs" "$out" "${_SPIKE_VERIFY_DIR:--}" "$res" "$@"
    return $?
  fi
  if [ "$rc" -eq 121 ]; then _spike_denylist_fail; return 121; fi
  if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; then
    spike_require_live
  fi
  if [ "$rc" -ne 1 ]; then
    spike_err "cannot resolve command: $cmd"
    return 2
  fi
  _spike_run_live_policy "$secs" "$out" "$cmd" "$@"
}

# spike_run_live <seconds> <outfile> <cmd> [args...]
# The runner for every real prompt or session. Always checks the live gate first (SPIKE_LIVE=1, set by the human). A command
# named like a pinned CLI (claude, codex; by argv[0] or by the resolved target) runs only as the current registered,
# hash-verified copy: pass "$SPIKE_VERIFIED_COPY" (rule 6).
spike_run_live() {
  local secs out cmd
  _spike_run_args_ok "$@" || return 2
  secs="$_SPIKE_SECS" out="$2" cmd="$3"
  shift 3
  spike_require_live
  _spike_run_live_policy "$secs" "$out" "$cmd" "$@"
}

# spike_run_status <seconds> <outfile> <copy> [args...]
# Only the copy that registration produced (pass "$SPIKE_VERIFIED_COPY"), only while its content still has the sha256
# recorded at registration, and only --version, auth status or login status. Any other path, any changed content and any
# other shape is refused (rc 3, nothing started), with or without SPIKE_LIVE.
spike_run_status() {
  local secs out cmd res rc
  _spike_run_args_ok "$@" || return 2
  secs="$_SPIKE_SECS" out="$2" cmd="$3"
  shift 3
  res="$(_spike_helper gate status "${_SPIKE_VERIFY_DIR:--}" "$cmd" "$@" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _spike_stop_script "refusing: $cmd is not an unchanged verified copy registered by preflight, or the arguments are not a status shape; spike_run_status runs only those"
  fi
  _spike_exec status "$secs" "$out" "$_SPIKE_VERIFY_DIR" "$res" "$@"
}

# spike_run_timed <seconds> <outfile> jq --version | git --version
# A display probe of a fixed tool, and nothing else: exactly `jq --version` or `git --version` (no other argument at all). The
# tool is found on PATH by the helper and must be a native executable in a system or package-manager prefix; a wrapper script
# or a copy in a user directory that is first on PATH is refused and never run. Closed environment, same watchdog. Refused: rc 2.
spike_run_timed() {
  local secs out cmd res rc
  _spike_run_args_ok "$@" || return 2
  secs="$_SPIKE_SECS" out="$2" cmd="$3"
  shift 3
  res="$(_spike_helper gate tool - "$cmd" "$@" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    spike_err "not a probe: only 'jq --version' and 'git --version' (a native tool in a system prefix) are allowed: $cmd"
    return 2
  fi
  _spike_exec tool "$secs" "$out" - "$res" "$@"
}

