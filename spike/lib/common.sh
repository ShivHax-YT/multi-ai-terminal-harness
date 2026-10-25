#!/usr/bin/env bash
# Shared helpers for the Phase 0 spikes. Source this file from scripts only, never from an interactive shell (the live
# gate can terminate the shell that sourced it). Do not execute it.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Works on macOS /bin/bash 3.2 (no associative arrays, no mapfile, no case-conversion expansions).
# It never changes the caller's shell options (no set -e / -u here). It does install one TERM trap (see
# spike_require_live) unless the caller already has its own.
#
# Hard-rule notes:
#   - spike_run_timeout / spike_run_live / spike_run_status are the only helpers that start a command. They run it with
#     a scrubbed environment, in its own process group (killed on timeout and on any signal to the caller). The
#     default is deny: only a short allowlist, or a provider CLI with exactly --version / auth status / login status,
#     runs without SPIKE_LIVE=1 (spike_require_live). Real prompts use spike_run_live.
#   - SPIKE_LIVE=1 is a guard against accidents, not an approval. Only the human sets it.
#   - Nothing here reads or names any CLI credential location or config-home override.

if [ -n "${SPIKE_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
SPIKE_COMMON_LOADED=1

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# spike_require_live ends the whole calling script by sending TERM to it; this trap turns that into exit status 3.
if [ -z "$(trap -p TERM)" ]; then
  trap 'exit 3' TERM
fi

spike_err() { printf 'spike: %s\n' "$*" >&2; }

# Root under which every scratch repo lives. Physical path, so comparisons are not fooled by /var -> /private/var.
spike_root() {
  local base="${TMPDIR:-/tmp}"
  base="${base%/}"
  [ -n "$base" ] || base="/tmp"
  if [ -d "$base" ]; then
    base="$(cd "$base" && pwd -P)"
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
  root="$(spike_root)"
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
  root="$(spike_root)"
  lroot="${TMPDIR:-/tmp}"
  lroot="${lroot%/}/harness-spike"
  if [ -z "$target" ]; then
    spike_err "cleanup: no path given"
    return 2
  fi
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
  phys="$(cd "$target" 2>/dev/null && pwd -P)" || { spike_err "cleanup refused (not a directory): $target"; return 2; }
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
  rm -rf "$phys"
}

# spike_require_live -> stop the calling SCRIPT (exit status 3) unless SPIKE_LIVE is exactly "1".
# Call it first in every script that starts a real CLI session. SPIKE_LIVE=1 is set by the human, never by an agent.
# It also works from inside $(...), pipes and subshells: those only end their own subshell with `exit`, so it first
# sends TERM to the top-level script ($$), whose trap (installed above) exits 3. Call it at the top level of the script,
# as the first statement, and never override the TERM trap. As a fail-safe, a detached watchdog sends KILL to the
# top-level script 0.3 s later if it is somehow still running (for example because it replaced the TERM trap).
spike_require_live() {
  if [ "${SPIKE_LIVE:-}" != "1" ]; then
    spike_err "refusing to run: this step calls a real CLI. Re-run with SPIKE_LIVE=1 to opt in (human only)."
    kill -s TERM "$$" 2>/dev/null
    ( sleep 0.3; if kill -0 "$$" 2>/dev/null; then kill -s KILL "$$" 2>/dev/null; fi ) >/dev/null 2>&1 &
    exit 3
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
  SPIKE_R_ROOT1="$(spike_root)" SPIKE_R_ROOT2="${TMPDIR:-/tmp}" SPIKE_R_HOME="${HOME:-}" awk '
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

# spike_resolve_path <path> -> absolute path with every symlink followed (portable; macOS 3.2-era tools).
spike_resolve_path() {
  local p="${1:-}" n=0 t d
  [ -n "$p" ] || return 1
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t="$(readlink "$p")"
    case "$t" in
      /*) p="$t" ;;
      *) p="$(dirname "$p")/$t" ;;
    esac
    n=$((n + 1))
  done
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$d" "$(basename "$p")"
}

# --- command runner ---------------------------------------------------------------------------------------------------
# Default-deny: spike_run_timeout runs only a short allowlist of harmless tools, and a provider CLI only for the exact
# status shapes. Everything else (shells, env, xargs, interpreters, unknown names, anything that mentions a provider
# name in its arguments) needs the live gate. Real prompts go through spike_run_live, which always checks the gate.

_spike_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _spike_base <path> -> lower-cased basename with a trailing .exe removed (macOS file systems are case-insensitive).
_spike_base() {
  local b
  b="$(basename -- "$1" 2>/dev/null)"
  b="$(_spike_lower "$b")"
  printf '%s' "${b%.exe}"
}

_spike_is_provider_name() {
  case "$1" in claude|codex|grok|gemini|kimi) return 0 ;; esac
  return 1
}

_spike_is_allowlisted() {
  case "$1" in git|jq|codesign|file|true|false|sleep|echo|cat|printf) return 0 ;; esac
  return 1
}

# Programs that run other programs: never acceptable as the resolved target of an allowlisted name.
_spike_is_launcher_name() {
  case "$1" in
    env|sh|bash|zsh|dash|ksh|csh|tcsh|fish|xargs|nohup|command|exec|time|nice|perl|python|python3|node|ruby|script|expect|osascript|open) return 0 ;;
  esac
  return 1
}

# Exactly the status shapes: --version | auth status | login status (the arguments after the command).
_spike_status_shape() {
  if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then return 0; fi
  if [ "$#" -eq 2 ] && { [ "$1 $2" = "auth status" ] || [ "$1 $2" = "login status" ]; }; then return 0; fi
  return 1
}

# codesign reading a binary: --verify --strict <path> | -dv --verbose=2 <path> (the path may name a provider CLI).
_spike_codesign_shape() {
  if [ "$#" -eq 3 ] && [ "$1 $2" = "--verify --strict" ]; then return 0; fi
  if [ "$#" -eq 3 ] && [ "$1 $2" = "-dv --verbose=2" ]; then return 0; fi
  if [ "$#" -eq 4 ] && [ "$1 $2" = "--verify --strict" ]; then
    case "$3" in -R=anchor\ apple\ generic\ and\ certificate\ leaf\[subject.OU\]\ =\ \"*\") return 0 ;; esac
  fi
  return 1
}

# 0 if any argument contains a provider name as a whole word, in any letter case.
_spike_args_mention_provider() {
  local a
  for a in "$@"; do
    if printf '%s\n' "$a" | grep -Eiq '(^|[^A-Za-z0-9])(claude|codex|grok|gemini|kimi)([^A-Za-z0-9]|$)'; then
      return 0
    fi
  done
  return 1
}

# _spike_needs_live <cmd> [args...] -> 0 if running this needs SPIKE_LIVE=1, 1 if it may run without it.
_spike_needs_live() {
  local cmd="$1" full res b1 b2
  shift
  full="$(command -v -- "$cmd" 2>/dev/null)" || full=""
  res=""
  if [ -n "$full" ]; then res="$(spike_resolve_path "$full" 2>/dev/null)" || res=""; fi
  b1="$(_spike_base "$cmd")"
  b2=""
  if [ -n "$res" ]; then b2="$(_spike_base "$res")"; fi

  if _spike_is_provider_name "$b1" || _spike_is_provider_name "$b2"; then
    if _spike_status_shape "$@"; then return 1; fi
    return 0
  fi
  if _spike_is_allowlisted "$b1"; then
    if [ -n "$b2" ] && _spike_is_launcher_name "$b2"; then return 0; fi
    if [ "$b1" = "git" ] && ! { [ "$#" -eq 1 ] && [ "$1" = "--version" ]; }; then return 0; fi
    if [ "$b1" = "codesign" ] && _spike_codesign_shape "$@"; then return 1; fi
    if _spike_args_mention_provider "$@"; then return 0; fi
    return 1
  fi
  return 0
}

# Kill the command's whole process group: TERM, a moment to exit, then KILL.
_spike_kill_group() {
  local p="${_SPIKE_CHILD_PID:-}"
  [ -n "$p" ] || return 0
  kill -s TERM -- "-$p" 2>/dev/null
  kill -s TERM "$p" 2>/dev/null
  sleep 0.3
  kill -s KILL -- "-$p" 2>/dev/null
  kill -s KILL "$p" 2>/dev/null
  return 0
}

# Runs inside a subshell (see _spike_exec). Starts the command in its own process group with a scrubbed environment.
# Any signal or exit path of this subshell kills that group, so nothing is left running.
_spike_run_timeout_body() {
  local secs="$1" out="$2" ticks=0 limit rc envargs
  shift 2
  limit=$((secs * 10))
  # USER/LOGNAME are passed because a CLI looks up its own stored login under the account name; without them
  # "auth status" wrongly reports signed out. They carry no credentials.
  envargs=(PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/}" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C}" TERM="${TERM:-dumb}")
  if [ -n "${USER:-}" ]; then envargs[${#envargs[@]}]="USER=$USER"; fi
  if [ -n "${LOGNAME:-}" ]; then envargs[${#envargs[@]}]="LOGNAME=$LOGNAME"; fi
  _SPIKE_CHILD_PID=""
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap '_spike_kill_group' EXIT
  perl -e 'setpgrp(0, 0); exec @ARGV' -- env -i "${envargs[@]}" "$@" </dev/null >>"$out" 2>&1 &
  _SPIKE_CHILD_PID=$!
  while kill -0 "$_SPIKE_CHILD_PID" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      _spike_kill_group
      { wait "$_SPIKE_CHILD_PID"; } 2>/dev/null
      _SPIKE_CHILD_PID=""
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$_SPIKE_CHILD_PID"
  rc=$?
  trap - EXIT TERM INT HUP
  # Sweep anything the command left running in its group.
  kill -s KILL -- "-$_SPIKE_CHILD_PID" 2>/dev/null
  return "$rc"
}

# In the caller: forward TERM/INT/HUP to the runner subshell (which kills the process group), then exit.
_spike_forward() {
  if [ -n "${_SPIKE_BG:-}" ]; then
    kill -s TERM "$_SPIKE_BG" 2>/dev/null
    wait "$_SPIKE_BG" 2>/dev/null
  fi
  exit "$1"
}

# _spike_exec <seconds> <outfile> <cmd> [args...] -- no gate here; callers decide. Returns the command's exit code,
# or 124 if it was killed for taking too long. stdin is closed, stdout+stderr append to <outfile>.
_spike_exec() {
  local rc old_int old_term old_hup
  if ! command -v perl >/dev/null 2>&1; then
    spike_err "perl is required (used to put the command in its own process group)"
    return 2
  fi
  old_int="$(trap -p INT)"
  old_term="$(trap -p TERM)"
  old_hup="$(trap -p HUP)"
  _SPIKE_BG=""
  trap '_spike_forward 130' INT
  trap '_spike_forward 143' TERM
  trap '_spike_forward 129' HUP
  # The subshell keeps the shell's own "Terminated" job notice out of the caller's stderr.
  ( _spike_run_timeout_body "$@" ) 2>/dev/null &
  _SPIKE_BG=$!
  wait "$_SPIKE_BG"
  rc=$?
  _SPIKE_BG=""
  trap - INT TERM HUP
  if [ -n "$old_int" ]; then eval "$old_int"; fi
  if [ -n "$old_term" ]; then eval "$old_term"; fi
  if [ -n "$old_hup" ]; then eval "$old_hup"; fi
  return "$rc"
}

_spike_run_args_ok() { # usage check shared by the three entry points: needs seconds, outfile, cmd
  if [ "$#" -lt 3 ]; then
    spike_err "usage: <seconds> <outfile> <cmd> [args...]"
    return 2
  fi
  case "$1" in ""|*[!0-9]*) spike_err "bad timeout: $1"; return 2 ;; esac
  return 0
}

# spike_run_timeout <seconds> <outfile> <cmd> [args...]
# Non-live runner for harmless tools: git --version, jq, codesign, file, true, false, sleep, echo, cat, printf, and a
# provider CLI with exactly --version / auth status / login status. Anything else needs SPIKE_LIVE=1.
spike_run_timeout() {
  local secs out cmd
  _spike_run_args_ok "$@" || return 2
  secs="$1" out="$2" cmd="$3"
  shift 3
  if _spike_needs_live "$cmd" "$@"; then
    spike_require_live
  fi
  _spike_exec "$secs" "$out" "$cmd" "$@"
}

# spike_run_live <seconds> <outfile> <cmd> [args...]
# The runner for every real prompt or session. Always checks the live gate first (SPIKE_LIVE=1, set by the human).
spike_run_live() {
  _spike_run_args_ok "$@" || return 2
  spike_require_live
  _spike_exec "$@"
}

# spike_run_status <seconds> <outfile> <bin> [args...]
# For a binary the caller has ALREADY verified (preflight): any file name, but only the exact status shapes
# (--version, auth status, login status); anything else needs the live gate.
spike_run_status() {
  local secs out cmd
  _spike_run_args_ok "$@" || return 2
  secs="$1" out="$2" cmd="$3"
  shift 3
  if ! _spike_status_shape "$@"; then
    spike_require_live
  fi
  _spike_exec "$secs" "$out" "$cmd" "$@"
}
