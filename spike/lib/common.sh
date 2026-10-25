#!/usr/bin/env bash
# Shared helpers for the Phase 0 spikes. Source this file; do not execute it.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Works on macOS /bin/bash 3.2 (no associative arrays, no mapfile, no case-conversion expansions).
# It never changes the caller's shell options (no set -e / -u here).
#
# Hard-rule notes:
#   - No helper here launches a provider CLI except spike_run_timeout, which runs whatever command the caller passes.
#     Scripts that start a real CLI session must call spike_require_live first (SPIKE_LIVE=1 is the opt-in).
#   - Nothing here reads or names any CLI credential location or config-home override.

if [ -n "${SPIKE_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
SPIKE_COMMON_LOADED=1

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

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
# Refuses (returns 2) anything that is not strictly inside <TMPDIR>/harness-spike/.
spike_cleanup() {
  local target="${1:-}" root phys wt line
  root="$(spike_root)"
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
    "$root"/?*) ;;
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

# spike_require_live -> exit 3 unless SPIKE_LIVE=1. Call first in every script that starts a real CLI session.
spike_require_live() {
  if [ "${SPIKE_LIVE:-}" != "1" ]; then
    spike_err "refusing to run: this step calls a real CLI. Re-run with SPIKE_LIVE=1 to opt in."
    exit 3
  fi
}

# spike_capture_dir <cli> -> echoes spike/captures/<cli>/<UTC timestamp>/ (created; gitignored).
spike_capture_dir() {
  local cli="${1:-}" dir
  case "$cli" in
    ""|*[!A-Za-z0-9._-]*|.*) spike_err "bad capture name: $cli"; return 2 ;;
  esac
  dir="${SPIKE_CAPTURES_ROOT:-$SPIKE_DIR/captures}/$cli/$(date -u +%Y%m%dT%H%M%SZ)/"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# spike_redact -> stdin to stdout. Rewrites, in this order:
#   scratch run dir      -> <WORKTREE>
#   absolute $HOME paths -> $HOME/...
#   email-shaped text    -> <EMAIL>
#   UUID-like ids        -> <ID-n>   (n is stable within one invocation, i.e. within one file)
spike_redact() {
  SPIKE_R_ROOT1="$(spike_root)" SPIKE_R_ROOT2="${TMPDIR:-/tmp}" SPIKE_R_HOME="${HOME:-}" awk '
    function rep(s, n,   o, i) { o = ""; for (i = 0; i < n; i++) o = o s; return o }
    function scratch(s, root,   out, i, rest) {
      if (root == "") return s
      out = ""
      while ((i = index(s, root)) > 0) {
        rest = substr(s, i + length(root))
        if (match(rest, /^\/[^\/[:space:]"]+/)) {
          out = out substr(s, 1, i - 1) "<WORKTREE>"
          s = substr(rest, RLENGTH + 1)
        } else {
          out = out substr(s, 1, i + length(root) - 1)
          s = rest
        }
      }
      return out s
    }
    function homes(s, home,   out, i, rest, c, p) {
      if (home == "" || home == "/") return s
      out = ""
      while ((i = index(s, home)) > 0) {
        p = (i > 1) ? substr(s, i - 1, 1) : ""
        rest = substr(s, i + length(home))
        c = substr(rest, 1, 1)
        if (p ~ /[A-Za-z0-9_.\/-]/) {
          out = out substr(s, 1, i + length(home) - 1)
          s = rest
        } else if (c == "/") {
          match(rest, /^\/[^[:space:]"<>,;)]*/)
          out = out substr(s, 1, i - 1) "$HOME/..."
          s = substr(rest, RLENGTH + 1)
        } else if (c == "" || c ~ /[[:space:]"<>,;):]/) {
          out = out substr(s, 1, i - 1) "$HOME/..."
          s = rest
        } else {
          out = out substr(s, 1, i + length(home) - 1)
          s = rest
        }
      }
      return out s
    }
    function emails(s,   out) {
      out = ""
      while (match(s, /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z][A-Za-z]+/)) {
        out = out substr(s, 1, RSTART - 1) "<EMAIL>"
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    function uuids(s,   out, m, k) {
      out = ""
      while (match(s, uuid_re)) {
        m = tolower(substr(s, RSTART, RLENGTH))
        if (!(m in ids)) { nids++; ids[m] = nids }
        out = out substr(s, 1, RSTART - 1) "<ID-" ids[m] ">"
        s = substr(s, RSTART + RLENGTH)
      }
      return out s
    }
    BEGIN {
      h = "[0-9a-fA-F]"
      uuid_re = rep(h, 8) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 4) "-" rep(h, 12)
      root1 = ENVIRON["SPIKE_R_ROOT1"]
      root2 = ENVIRON["SPIKE_R_ROOT2"]; sub(/\/+$/, "", root2); if (root2 != "") root2 = root2 "/harness-spike"
      home = ENVIRON["SPIKE_R_HOME"]; sub(/\/+$/, "", home)
      nids = 0
    }
    {
      line = scratch($0, root1)
      if (root2 != root1) line = scratch(line, root2)
      line = homes(line, home)
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

# spike_run_timeout <seconds> <outfile> <cmd> [args...]
# Runs cmd with stdin closed, stdout+stderr appended to <outfile> (use /dev/null to discard).
# Returns the command's exit code, or 124 if it was killed for taking too long.
_spike_run_timeout_body() {
  local secs="$1" out="$2" pid ticks=0 limit rc
  shift 2
  limit=$((secs * 10))
  "$@" </dev/null >>"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      kill "$pid" 2>/dev/null
      sleep 0.2
      kill -9 "$pid" 2>/dev/null
      { wait "$pid"; } 2>/dev/null
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

# The subshell keeps the shell's own "Terminated" job notice out of the caller's stderr.
spike_run_timeout() {
  ( _spike_run_timeout_body "$@" ) 2>/dev/null
}
