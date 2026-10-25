#!/usr/bin/env bash
# Shared helpers for the Phase 0 spikes. Source this file; do not execute it.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Works on macOS /bin/bash 3.2 (no associative arrays, no mapfile, no case-conversion expansions).
# It never changes the caller's shell options (no set -e / -u here). It does install one TERM trap (see
# spike_require_live) unless the caller already has its own.
#
# Hard-rule notes:
#   - spike_run_timeout is the only helper that starts an arbitrary command. It runs the command with a scrubbed
#     environment, in its own process group, and refuses to start a provider CLI (claude, codex, grok, gemini, kimi)
#     for anything except --version / auth status / login status unless SPIKE_LIVE=1 (spike_require_live).
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
# sends TERM to the top-level script ($$), whose trap (installed above) exits 3.
spike_require_live() {
  if [ "${SPIKE_LIVE:-}" != "1" ]; then
    spike_err "refusing to run: this step calls a real CLI. Re-run with SPIKE_LIVE=1 to opt in (human only)."
    kill -s TERM "$$" 2>/dev/null
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

# _spike_provider_cli_name <command> -> 0 if the command (or what it resolves to) is a provider CLI binary name.
_spike_provider_cli_name() {
  local cmd="$1" full base p
  full="$(command -v -- "$cmd" 2>/dev/null)" || full="$cmd"
  for p in "$cmd" "$full" "$(spike_resolve_path "$full" 2>/dev/null)"; do
    base="$(basename -- "$p" 2>/dev/null)"
    base="${base%.exe}"
    case "$base" in
      claude|codex|grok|gemini|kimi) return 0 ;;
    esac
  done
  return 1
}

# spike_run_timeout <seconds> <outfile> <cmd> [args...]
# Runs cmd with stdin closed, a scrubbed environment (PATH HOME TMPDIR LANG TERM USER LOGNAME only), in its own process group,
# stdout+stderr appended to <outfile> (use /dev/null to discard). The whole group is killed on timeout.
# Returns the command's exit code, or 124 if it was killed for taking too long.
# A provider CLI may be started only for --version / auth status / login status unless SPIKE_LIVE=1.
_spike_run_timeout_body() {
  local secs="$1" out="$2" pid ticks=0 limit rc
  local envargs
  shift 2
  limit=$((secs * 10))
  # USER/LOGNAME are passed because a CLI looks up its own stored login under the account name; without them
  # "auth status" wrongly reports signed out. They carry no credentials.
  envargs=(PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/}" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C}" TERM="${TERM:-dumb}")
  if [ -n "${USER:-}" ]; then envargs[${#envargs[@]}]="USER=$USER"; fi
  if [ -n "${LOGNAME:-}" ]; then envargs[${#envargs[@]}]="LOGNAME=$LOGNAME"; fi
  perl -e 'setpgrp(0, 0); exec @ARGV' -- env -i "${envargs[@]}" "$@" </dev/null >>"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      kill -s TERM -- "-$pid" 2>/dev/null
      kill -s TERM "$pid" 2>/dev/null
      sleep 0.3
      kill -s KILL -- "-$pid" 2>/dev/null
      kill -s KILL "$pid" 2>/dev/null
      { wait "$pid"; } 2>/dev/null
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
  rc=$?
  # Sweep anything the command left running in its group.
  kill -s KILL -- "-$pid" 2>/dev/null
  return "$rc"
}

# The subshell keeps the shell's own "Terminated" job notice out of the caller's stderr.
spike_run_timeout() {
  local secs="${1:-}" out="${2:-}"
  if [ "$#" -lt 3 ]; then
    spike_err "usage: spike_run_timeout <seconds> <outfile> <cmd> [args...]"
    return 2
  fi
  case "$secs" in ""|*[!0-9]*) spike_err "bad timeout: $secs"; return 2 ;; esac
  if ! command -v perl >/dev/null 2>&1; then
    spike_err "perl is required (used to put the command in its own process group)"
    return 2
  fi
  if _spike_provider_cli_name "$3"; then
    if [ "$#" -eq 4 ] && [ "$4" = "--version" ]; then
      :
    elif [ "$#" -eq 5 ] && { [ "$4 $5" = "auth status" ] || [ "$4 $5" = "login status" ]; }; then
      :
    else
      spike_require_live
    fi
  fi
  ( _spike_run_timeout_body "$@" ) 2>/dev/null
}
