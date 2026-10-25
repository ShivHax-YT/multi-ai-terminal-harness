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
#   - Resolve once, physically, execute the resolved path (round 6). A command is resolved ONCE to its absolute real
#     path (PATH lookup, then every symlink, with '..' applied the way the kernel applies it). The identity checks and
#     the exec both use that same path. The runner never executes the name it was given, and env never searches PATH.
#   - spike_run_timeout / spike_run_live / spike_run_status are the only helpers that start a command. They run it with
#     a scrubbed environment, in its own process group. The group is killed on timeout, on TERM/INT/HUP to the caller,
#     and when the caller disappears (SIGKILL included, within about 0.5 s). Identity, not name: without SPIKE_LIVE=1,
#     spike_run_timeout runs only a short list of harmless programs whose resolved path is in a system directory. A
#     copy of a provider CLI named cat, printf or claude is refused, and so is every provider CLI (spike_require_live).
#     Real prompts use spike_run_live. spike_run_status runs only a private copy that preflight verified, and only the
#     three status shapes.
#   - Children run headless: stdin is /dev/null, output goes to the outfile, and they are not in a new session. A CLI
#     that opens the terminal device is out of scope (rule 3).
#   - SPIKE_LIVE=1 is a guard against accidents, not an approval. Only the human sets it.
#   - Registration (spike_mark_verified) runs the pinned-signer check and a Mach-O magic check itself (rule 6). Only
#     preflight may register. Codesign read-only shapes run without the gate only on a path inside the private verify
#     directory (rule 4). Preflight refuses paths inside the CLI home directories before it reads them (rule 4).

if [ -n "${SPIKE_COMMON_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
SPIKE_COMMON_LOADED=1

# ---- FIXED CODESIGN PATH (rule 6) -----------------------------------------------------------------------------------
# Every signature check calls this absolute path. It is a readonly constant: no environment variable, flag or PATH entry
# changes it. The tests make a sandbox copy with only this line rewritten; the shipped script has no override hook.
readonly CODESIGN_BIN="/usr/bin/codesign"

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

# ---- resolution (round 6, item 1) -----------------------------------------------------------------------------------
# Resolve once, physically: the same file the kernel would open. A '..' that follows a symlink is applied to the real
# directory the symlink points to (cd -P), never lexically. Runs of '/' are collapsed. A relative path is made absolute
# from the current directory. A final '.' or '..' component (or a trailing slash) is refused. At most 40 symlinks.
_spike_norm_slashes() { printf '%s' "$1" | tr -s /; }

# spike_resolve_path <path> -> echoes the absolute physical path of the final component, following every symlink.
spike_resolve_path() {
  local p="${1:-}" n=0 d b t
  [ -n "$p" ] || return 1
  p="$(_spike_norm_slashes "$p")"
  case "$p" in
    /*) ;;
    *) p="$(pwd -P)/$p" ;;
  esac
  p="$(_spike_norm_slashes "$p")"
  while :; do
    d="${p%/*}"
    b="${p##*/}"
    [ -n "$d" ] || d="/"
    case "$b" in ""|.|..) return 1 ;; esac
    d="$(CDPATH= cd -P -- "$d" 2>/dev/null && pwd -P)" || return 1
    if [ -L "$d/$b" ]; then
      n=$((n + 1))
      [ "$n" -le 40 ] || return 1
      t="$(readlink "$d/$b")" || return 1
      case "$t" in
        /*) p="$t" ;;
        *) p="$d/$t" ;;
      esac
      p="$(_spike_norm_slashes "$p")"
      continue
    fi
    break
  done
  if [ "$d" = "/" ]; then
    printf '/%s\n' "$b"
  else
    printf '%s/%s\n' "$d" "$b"
  fi
}

# spike_run_timed <seconds> <outfile> <cmd> [args...]: a direct call for the fixed tools only (codesign, file, git, jq,
# perl). stdin is /dev/null and output is appended to <outfile>. Returns 124 on timeout. Never used for a provider CLI.
spike_run_timed() {
  local secs="$1" out="$2" rc
  shift 2
  perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@" </dev/null >>"$out" 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then return 124; fi
  return "$rc"
}

# spike_magic_ok <file>: 0 if <file> is a regular, non-symlink file whose first four bytes are a Mach-O or universal
# (fat) magic. Reads exactly four bytes (dd bs=4 count=1). The six values are the byte sequences of MH_MAGIC_64,
# MH_MAGIC and FAT_MAGIC in both byte orders (cf fa ed fe, fe ed fa cf, ce fa ed fe, fe ed fa ce, ca fe ba be, be ba fe ca).
spike_magic_ok() {
  local f="${1:-}" m
  [ -n "$f" ] || return 1
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  m="$(dd if="$f" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \t\n')"
  case "$m" in
    feedfacf|cffaedfe|feedface|cefaedfe|cafebabe|bebafeca) return 0 ;;
  esac
  return 1
}

# spike_under_cli_home <resolved-path>: 0 (refuse; rule 4) if the path is inside any dot-entry directly under the physical
# $HOME, or inside the physical target of such an entry (a symlinked CLI home). This covers every CLI home that rule 4
# lists, and more. The explicit names are deliberately NOT written here: the compliance scan forbids them outside its
# allowlist, and the explicit list belongs in compliance/ (follow-up for the lead). HOME unset, "/" or unresolvable: 0.
spike_under_cli_home() {
  local p="${1:-}" home e t
  [ -n "$p" ] || return 0
  home="${HOME:-}"
  [ -n "$home" ] && [ "$home" != "/" ] || return 0
  home="$(CDPATH= cd -P -- "$home" 2>/dev/null && pwd -P)" || return 0
  [ "$home" != "/" ] || return 0
  case "$p" in
    "$home"/.?*) return 0 ;;
  esac
  for e in "$home"/.?*; do
    [ -L "$e" ] || continue
    t="$(spike_resolve_path "$e" 2>/dev/null)" || return 0
    case "$p" in
      "$t"|"$t"/?*) return 0 ;;
    esac
  done
  return 1
}

# spike_set_verify_dir <dir>: records the private verify directory preflight created (physical path, shell state).
# Ungated codesign read-only shapes are accepted only for a path that resolves inside it (rule 4).
_SPIKE_VERIFY_DIR=""
spike_set_verify_dir() {
  local d="${1:-}" phys
  [ -n "$d" ] || return 2
  phys="$(CDPATH= cd -P -- "$d" 2>/dev/null && pwd -P)" || return 2
  _SPIKE_VERIFY_DIR="$phys"
}

# ---- pinned signer (rule 6) -----------------------------------------------------------------------------------------
# Apple Developer Team IDs that the official CLI binaries must be signed by. Taken from the binaries installed on the
# developer's Mac on 2026-10-25 (claude: Anthropic PBC, codex: OpenAI). THE HUMAN MUST CONFIRM THESE AGAINST
# VENDOR-PUBLISHED VALUES BEFORE ANY RELEASE; until then they only prove "same signer as the binary I installed".
SPIKE_PINNED_AUTHORITY_PREFIX="Developer ID Application"
spike_pinned_team() {
  case "$1" in
    claude) printf 'Q6L2SF6YDW' ;;  # Anthropic PBC
    codex) printf '2DC432GLL2' ;;   # OpenAI
    *) printf '' ;;
  esac
}

# SPIKE_SIG_TEXT: the signature column text of the last spike_verify_signer / spike_mark_verified call.
SPIKE_SIG_TEXT=""

# _spike_verify_body <path> <cli> <outfile>: the pinned-signer checks. Sets SPIKE_SIG_TEXT; 0 only for a copy that passes
# every check. Runs only CODESIGN_BIN, and only on <path>, which the caller passes as a resolved path.
_spike_verify_body() {
  local bin="$1" name="$2" out="$3" rc auth team want sigkind firstauth
  if [ ! -x "$CODESIGN_BIN" ]; then
    SPIKE_SIG_TEXT="NOT VERIFIED (codesign unavailable)"
    return 1
  fi
  : > "$out"
  spike_run_timed 20 "$out" "$CODESIGN_BIN" --verify --strict "$bin"
  rc=$?
  if [ "$rc" -eq 124 ]; then
    SPIKE_SIG_TEXT="NOT VERIFIED (codesign timed out)"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    if grep -qi 'not signed at all' "$out"; then
      SPIKE_SIG_TEXT="NOT SIGNED"
    else
      SPIKE_SIG_TEXT="NOT VERIFIED (codesign rc=$rc)"
    fi
    return 1
  fi

  # The signature is intact. Now identify the signer.
  : > "$out"
  spike_run_timed 20 "$out" "$CODESIGN_BIN" -dv --verbose=2 "$bin"
  firstauth="$(grep -m1 '^Authority=' "$out" | cut -d= -f2-)"
  team="$(grep -m1 '^TeamIdentifier=' "$out" | cut -d= -f2-)"
  auth="$(printf '%s' "$firstauth" | _spike_clean | sed 's/ ([A-Z0-9]*)$//' | spike_redact | cut -c1-46)"
  team="$(printf '%s' "$team" | _spike_clean | cut -c1-12)"
  sigkind=""
  if grep -q '^Signature=adhoc' "$out"; then sigkind="ad-hoc, "; fi
  want="$(spike_pinned_team "$name")"

  case "$firstauth" in
    "$SPIKE_PINNED_AUTHORITY_PREFIX"*) ;;
    *)
      SPIKE_SIG_TEXT="UNTRUSTED (valid but ${sigkind}${auth:-no authority}; not Developer ID)"
      return 1
      ;;
  esac
  if [ -z "$want" ] || [ "$team" != "$want" ]; then
    SPIKE_SIG_TEXT="UNTRUSTED (valid but team ${team:-not set} is not the pinned team)"
    return 1
  fi
  # The text above can be forged by a self-made certificate; this asks codesign to check the chain to Apple's root.
  : > "$out"
  spike_run_timed 20 "$out" "$CODESIGN_BIN" --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$want\"" "$bin"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    SPIKE_SIG_TEXT="UNTRUSTED (signer text matches but the certificate chain does not satisfy the pinned team)"
    return 1
  fi
  SPIKE_SIG_TEXT="valid; ${auth}; team ${team}"
  return 0
}

# spike_verify_signer <resolved-path> <cli>: the pinned-signer check on its own (registers nothing). Sets SPIKE_SIG_TEXT.
spike_verify_signer() {
  local out rc
  SPIKE_SIG_TEXT=""
  out="$(mktemp "${TMPDIR:-/tmp}/spike-verify.XXXXXX" 2>/dev/null)" || { SPIKE_SIG_TEXT="NOT VERIFIED (no temp file)"; return 1; }
  _spike_verify_body "$1" "$2" "$out"
  rc=$?
  rm -f "$out"
  return "$rc"
}

_spike_clean() { tr -cd '[:print:]'; }

# ---- command runner -------------------------------------------------------------------------------------------------
# Three entry points start a command. Each either runs it with a scrubbed environment in its own process group, or
# refuses with rc 3 and starts nothing:
#   spike_run_timeout  non-live. Runs only a command whose IDENTITY is on the harmless list (_spike_ungated_ok).
#                      Anything else needs SPIKE_LIVE=1, including every provider CLI, whatever its name.
#   spike_run_live     always needs SPIKE_LIVE=1. Every real prompt or session goes through here.
#   spike_run_status   only a private verified copy that preflight registered with spike_mark_verified, and only the
#                      three status shapes. SPIKE_LIVE does not lift this refusal.
# Round 6: every entry point resolves the command ONCE (_spike_resolve_cmd: PATH lookup, then every symlink, physically)
# and executes that resolved path through /usr/bin/env -i, never the name it was given and never a PATH re-search.
# Identity, not name: a program named cat, printf or claude is not harmless because of its name. An ungated command's
# resolved real path must be inside /bin, /usr/bin, /usr/sbin or /sbin. A relative path with a slash (./x, ../x) is
# refused. Children get stdin from /dev/null and stdout+stderr appended to the outfile. They run in their own process
# group, not in a new session: a CLI that opens the terminal device (/dev/tty) is out of scope, since the spikes are
# headless only. The runner watches its caller (the shell's $$ at start) and kills the command's group about 0.5 s after
# the caller disappears, including after SIGKILL, when no trap can run.

_spike_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _spike_base <path> -> lower-cased basename with a trailing .exe removed (macOS file systems are case-insensitive).
_spike_base() {
  local b
  b="$(basename -- "$1" 2>/dev/null)"
  b="$(_spike_lower "$b")"
  printf '%s' "${b%.exe}"
}

# Harmless programs that may run without the gate, by the basename of both argv[0] and the resolved target.
_spike_is_allowlisted() {
  case "$1" in git|codesign|true|false|sleep|echo|printf) return 0 ;; esac
  return 1
}

# Programs that run other programs. Never acceptable as the resolved target of an allowed command or of a status run.
_spike_is_launcher_name() {
  case "$1" in
    env|sh|bash|zsh|dash|ksh|csh|tcsh|fish|xargs|nohup|command|exec|time|nice|perl|python|python3|node|ruby|script|expect|osascript|open) return 0 ;;
  esac
  return 1
}

# A resolved path inside a system directory. Only these may run without the gate.
_spike_system_path() {
  case "$1" in
    /bin/?*|/usr/bin/?*|/usr/sbin/?*|/sbin/?*) return 0 ;;
  esac
  return 1
}

# Exactly the status shapes: --version | auth status | login status (the arguments after the command).
_spike_status_shape() {
  if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then return 0; fi
  if [ "$#" -eq 2 ] && { [ "$1 $2" = "auth status" ] || [ "$1 $2" = "login status" ]; }; then return 0; fi
  return 1
}

# A file-name argument: non-empty and not an option.
_spike_arg_is_path() {
  case "$1" in ""|-*) return 1 ;; esac
  return 0
}

# codesign read-only verify shapes only: --verify --strict <path> | -dv --verbose=2 <path> |
# --verify --strict -R=<requirement> <path>. Anything else (--sign, --remove-signature, ...) needs the gate. The path is
# also checked by _spike_codesign_rooted (it must resolve inside the private verify directory).
_spike_codesign_shape() {
  if [ "$#" -eq 3 ] && [ "$1 $2" = "--verify --strict" ]; then _spike_arg_is_path "$3" && return 0; fi
  if [ "$#" -eq 3 ] && [ "$1 $2" = "-dv --verbose=2" ]; then _spike_arg_is_path "$3" && return 0; fi
  if [ "$#" -eq 4 ] && [ "$1 $2" = "--verify --strict" ]; then
    case "$3" in -R=anchor\ apple\ generic\ and\ certificate\ leaf\[subject.OU\]\ =\ \"*) _spike_arg_is_path "$4" && return 0 ;; esac
  fi
  return 1
}

# _spike_last_arg <args...> -> echoes the last argument (empty when there are none).
_spike_last_arg() {
  local a=""
  for a in "$@"; do :; done
  printf '%s' "$a"
}

# _spike_codesign_rooted <path>: 0 only if the PHYSICAL path is strictly inside the private verify directory set by
# spike_set_verify_dir (rule 4). A credential file, a symlink that leaves the directory, or a '..' escape: 1. With no
# verify directory set, nothing is rooted.
_spike_codesign_rooted() {
  local rp
  [ -n "${_SPIKE_VERIFY_DIR:-}" ] || return 1
  [ -n "${1:-}" ] || return 1
  rp="$(spike_resolve_path "$1" 2>/dev/null)" || return 1
  case "$rp" in
    "$_SPIKE_VERIFY_DIR"/?*) return 0 ;;
  esac
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

# _spike_resolve_cmd <cmd> -> echoes the resolved absolute real path of <cmd>, or returns 1 (round 6, item 1). A bare name
# is looked up on PATH once (type -P, which ignores functions and aliases). An absolute path is taken as it is. A
# relative path with a slash, a leading dash, or an empty name is refused. The result is physical (spike_resolve_path).
_spike_resolve_cmd() {
  local cmd="${1:-}" full
  case "$cmd" in
    "") return 1 ;;
    /*) full="$cmd" ;;
    */*|-*) return 1 ;;
    *) full="$(type -P "$cmd" 2>/dev/null)" || return 1 ;;
  esac
  [ -n "$full" ] || return 1
  spike_resolve_path "$full"
}

# _spike_ungated_ok <resolved> <argv0> [args...] -> 0 if this command may run without SPIKE_LIVE, 1 if it needs the gate.
# <resolved> is the path _spike_resolve_cmd returned, which is the path that will be executed. <argv0> is the name the
# caller typed; its basename must be allowlisted too. The resolved target must be in a system directory and allowlisted.
_spike_ungated_ok() {
  local res="${1:-}" cmd="${2:-}" ab rb
  shift 2
  [ -n "$res" ] || return 1
  _spike_system_path "$res" || return 1
  ab="$(_spike_base "$cmd")"
  rb="$(_spike_base "$res")"
  if ! _spike_is_allowlisted "$ab" || ! _spike_is_allowlisted "$rb"; then return 1; fi
  if _spike_is_launcher_name "$rb"; then return 1; fi
  case "$rb" in
    git)
      if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then return 0; fi
      return 1
      ;;
    codesign)
      _spike_codesign_shape "$@" || return 1
      _spike_codesign_rooted "$(_spike_last_arg "$@")" || return 1
      return 0
      ;;
    *)
      if _spike_args_mention_provider "$@"; then return 1; fi
      return 0
      ;;
  esac
}

# Verified private copies. preflight.sh registers a copy only through spike_mark_verified, which runs the pinned-signer
# check and the Mach-O magic check itself (round 6, item 2). The registry holds RESOLVED paths; spike_run_status resolves
# its argument and compares. The list is shell state, not environment.
_SPIKE_VERIFIED=""

_spike_is_verified() {
  local p="${1:-}" line
  [ -n "$p" ] || return 1
  [ -n "$_SPIKE_VERIFIED" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = "$p" ]; then return 0; fi
  done <<EOF
$_SPIKE_VERIFIED
EOF
  return 1
}

# spike_mark_verified <path> <cli>: register one private, regular, non-symlink, executable Mach-O copy whose signer passes
# the pinned check for <cli> (claude or codex). Returns 2 and registers nothing otherwise. Preflight only.
spike_mark_verified() {
  local p="${1:-}" name="${2:-}" rp
  case "$p" in
    /*) ;;
    *) spike_err "mark_verified: not an absolute path"; return 2 ;;
  esac
  case "$p" in *[[:cntrl:]]*) spike_err "mark_verified: control character in path"; return 2 ;; esac
  if [ -L "$p" ] || [ ! -f "$p" ] || [ ! -x "$p" ]; then
    spike_err "mark_verified: not a regular executable file: $p"
    return 2
  fi
  rp="$(spike_resolve_path "$p")" || { spike_err "mark_verified: cannot resolve: $p"; return 2; }
  SPIKE_SIG_TEXT=""
  if ! spike_magic_ok "$rp"; then
    SPIKE_SIG_TEXT="NOT VERIFIED (not a Mach-O file)"
    spike_err "mark_verified: not a Mach-O file: $p"
    return 2
  fi
  if [ -z "$(spike_pinned_team "$name")" ]; then
    SPIKE_SIG_TEXT="NOT VERIFIED (no pinned team for this name)"
    spike_err "mark_verified: no pinned team for: $name"
    return 2
  fi
  if ! spike_verify_signer "$rp" "$name"; then
    spike_err "mark_verified: signer check failed: $SPIKE_SIG_TEXT"
    return 2
  fi
  if _spike_is_verified "$rp"; then return 0; fi
  _SPIKE_VERIFIED="$_SPIKE_VERIFIED$rp
"
  return 0
}

# Kill the command's whole process group: TERM, a moment to exit, then KILL. Clears the pid once done.
_spike_kill_group() {
  local p="${_SPIKE_CHILD_PID:-}"
  [ -n "$p" ] || return 0
  kill -s TERM -- "-$p" 2>/dev/null
  kill -s TERM "$p" 2>/dev/null
  sleep 0.3
  kill -s KILL -- "-$p" 2>/dev/null
  kill -s KILL "$p" 2>/dev/null
  _SPIKE_CHILD_PID=""
  return 0
}

# A TERM, INT or HUP reached the runner. If the command's pid is known, kill its group and exit with the signal status.
# If not (the signal landed between `&` and `$!`), record it; the runner handles it right after the assignment.
_spike_signal() {
  if [ -n "${_SPIKE_CHILD_PID:-}" ]; then
    _spike_kill_group
    exit "$1"
  fi
  _SPIKE_PENDING="$1"
}

# 0 if the process exists and is not a zombie. A zombie has exited. If ps reports no state, it counts as alive (fail closed).
_spike_pid_alive() {
  local st
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  st="$(ps -o stat= -p "$1" 2>/dev/null)"
  case "$st" in Z*) return 1 ;; esac
  return 0
}

# 0 when the caller recorded at start has exited (or was never recorded: then nothing is judged gone).
_spike_caller_gone() {
  [ -n "${_SPIKE_CALLER_PID:-}" ] || return 1
  if _spike_pid_alive "$_SPIKE_CALLER_PID"; then return 1; fi
  return 0
}

# The scrubbed-environment launcher. Absolute, so the runner never searches PATH for it (round 6, item 1).
SPIKE_ENV_BIN="/usr/bin/env"

# Runs inside a subshell (see _spike_exec). Starts the RESOLVED command in its own process group with a scrubbed
# environment. Any signal or exit path of this subshell kills that group, and so does the caller going away.
_spike_run_timeout_body() {
  # The FIRST statement (round 6, item 6): replace the caller's inherited traps before anything else, so a signal that
  # lands during this subshell's start-up is recorded by the runner's own logic (_spike_signal), never by a caller trap.
  trap '_spike_signal 143' TERM
  trap '_spike_signal 130' INT
  trap '_spike_signal 129' HUP
  trap '_spike_kill_group' EXIT
  local secs="$1" out="$2" ticks=0 limit rc envargs pid
  shift 2
  limit=$((secs * 10))
  # USER/LOGNAME are passed because a CLI looks up its own stored login under the account name; they carry no credentials.
  envargs=(PATH="${PATH:-/usr/bin:/bin}" HOME="${HOME:-/}" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C}" TERM="${TERM:-dumb}")
  if [ -n "${USER:-}" ]; then envargs[${#envargs[@]}]="USER=$USER"; fi
  if [ -n "${LOGNAME:-}" ]; then envargs[${#envargs[@]}]="LOGNAME=$LOGNAME"; fi
  # "$@" is the resolved absolute path followed by the arguments: env execs that path directly (no PATH search).
  perl -e 'setpgrp(0, 0); exec @ARGV' -- "$SPIKE_ENV_BIN" -i "${envargs[@]}" "$@" </dev/null >>"$out" 2>&1 &
  _SPIKE_CHILD_PID=$!
  if [ -n "${_SPIKE_PENDING:-}" ]; then
    _spike_kill_group
    exit "$_SPIKE_PENDING"
  fi
  while kill -0 "$_SPIKE_CHILD_PID" 2>/dev/null; do
    if [ $((ticks % 5)) -eq 0 ] && _spike_caller_gone; then
      pid="$_SPIKE_CHILD_PID"
      _spike_kill_group
      wait "$pid" 2>/dev/null
      return 143
    fi
    if [ "$ticks" -ge "$limit" ]; then
      pid="$_SPIKE_CHILD_PID"
      _spike_kill_group
      wait "$pid" 2>/dev/null
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

# In the caller: a TERM, INT or HUP. If the runner exists, forward TERM to it and wait, then exit. If it does not yet
# (the signal landed between `&` and `$!`), record it; _spike_exec handles it right after the assignment.
_spike_forward() {
  if [ -z "${_SPIKE_BG:-}" ]; then
    _SPIKE_BG_PENDING="$1"
    return 0
  fi
  kill -s TERM "$_SPIKE_BG" 2>/dev/null
  wait "$_SPIKE_BG" 2>/dev/null
  exit "$1"
}

# _spike_exec <seconds> <outfile> <resolved-cmd> [args...] -- no gate here; callers decide. Returns the command's exit
# code, or 124 if it was killed for taking too long. stdin is closed, stdout+stderr append to <outfile>.
_spike_exec() {
  local rc old_int old_term old_hup
  if ! command -v perl >/dev/null 2>&1; then
    spike_err "perl is required (used to put the command in its own process group)"
    return 2
  fi
  if ! command -v ps >/dev/null 2>&1; then
    spike_err "ps is required (the runner watches its caller)"
    return 2
  fi
  if [ ! -x "$SPIKE_ENV_BIN" ]; then
    spike_err "$SPIKE_ENV_BIN is required (it sets the scrubbed environment)"
    return 2
  fi
  old_int="$(trap -p INT)"
  old_term="$(trap -p TERM)"
  old_hup="$(trap -p HUP)"
  # Reset here, in the caller, before the subshell exists: the subshell must not clear a signal it recorded.
  _SPIKE_BG=""
  _SPIKE_BG_PENDING=""
  _SPIKE_CHILD_PID=""
  _SPIKE_PENDING=""
  _SPIKE_CALLER_PID="$$"
  trap '_spike_forward 130' INT
  trap '_spike_forward 143' TERM
  trap '_spike_forward 129' HUP
  # The subshell keeps the shell's own "Terminated" job notice out of the caller's stderr.
  ( _spike_run_timeout_body "$@" ) 2>/dev/null &
  _SPIKE_BG=$!
  if [ -n "$_SPIKE_BG_PENDING" ]; then
    kill -s TERM "$_SPIKE_BG" 2>/dev/null
    wait "$_SPIKE_BG" 2>/dev/null
    exit "$_SPIKE_BG_PENDING"
  fi
  wait "$_SPIKE_BG"
  rc=$?
  _SPIKE_BG=""
  trap - INT TERM HUP
  if [ -n "$old_int" ]; then eval "$old_int"; fi
  if [ -n "$old_term" ]; then eval "$old_term"; fi
  if [ -n "$old_hup" ]; then eval "$old_hup"; fi
  if [ -n "$_SPIKE_BG_PENDING" ]; then exit "$_SPIKE_BG_PENDING"; fi
  return "$rc"
}

_spike_run_args_ok() { # usage check shared by the entry points: needs seconds, outfile, cmd
  if [ "$#" -lt 3 ]; then
    spike_err "usage: <seconds> <outfile> <cmd> [args...]"
    return 2
  fi
  case "$1" in ""|*[!0-9]*) spike_err "bad timeout: $1"; return 2 ;; esac
  return 0
}

# _spike_stop_script <message>: refuse and end the calling SCRIPT with status 3, whatever SPIKE_LIVE says. It sends TERM
# to the top-level script ($$), whose TERM trap exits 3; a detached watchdog sends KILL 0.3 s later as a fail-safe.
_spike_stop_script() {
  [ -z "${1:-}" ] || spike_err "$1"
  kill -s TERM "$$" 2>/dev/null
  ( sleep 0.3; if kill -0 "$$" 2>/dev/null; then kill -s KILL "$$" 2>/dev/null; fi ) >/dev/null 2>&1 &
  exit 3
}

# spike_run_timeout <seconds> <outfile> <cmd> [args...]
# Non-live runner. Runs only the harmless identities listed in _spike_ungated_ok (git --version, the codesign read-only
# shapes on a path inside the private verify directory, true, false, sleep, echo, printf, each only from a system
# directory). Everything else needs SPIKE_LIVE=1. The command is resolved once and the resolved path is what runs.
spike_run_timeout() {
  local secs out cmd res
  _spike_run_args_ok "$@" || return 2
  secs="$1" out="$2" cmd="$3"
  shift 3
  res="$(_spike_resolve_cmd "$cmd")" || res=""
  if [ -z "$res" ] || ! _spike_ungated_ok "$res" "$cmd" "$@"; then
    spike_require_live
  fi
  if [ -z "$res" ]; then
    spike_err "cannot resolve command: $cmd"
    return 2
  fi
  _spike_exec "$secs" "$out" "$res" "$@"
}

# spike_run_live <seconds> <outfile> <cmd> [args...]
# The runner for every real prompt or session. Always checks the live gate first (SPIKE_LIVE=1, set by the human).
spike_run_live() {
  local secs out cmd res
  _spike_run_args_ok "$@" || return 2
  secs="$1" out="$2" cmd="$3"
  shift 3
  spike_require_live
  res="$(_spike_resolve_cmd "$cmd")" || res=""
  if [ -z "$res" ]; then
    spike_err "cannot resolve command: $cmd"
    return 2
  fi
  _spike_exec "$secs" "$out" "$res" "$@"
}

# spike_run_status <seconds> <outfile> <bin> [args...]
# Only a copy that preflight verified and registered with spike_mark_verified, and only --version, auth status or
# login status. The argument is resolved and compared with the registry (physical paths). Any other shape is refused
# (rc 3, nothing started), with or without SPIKE_LIVE.
spike_run_status() {
  local secs out cmd res
  _spike_run_args_ok "$@" || return 2
  secs="$1" out="$2" cmd="$3"
  shift 3
  res="$(_spike_resolve_cmd "$cmd")" || res=""
  if [ -z "$res" ] || ! _spike_is_verified "$res"; then
    _spike_stop_script "refusing: $cmd is not a verified copy registered by preflight; spike_run_status runs only those"
  fi
  if ! _spike_status_shape "$@"; then
    _spike_stop_script "refusing: spike_run_status runs only --version, auth status and login status; use spike_run_live"
  fi
  if _spike_is_launcher_name "$(_spike_base "$res")"; then
    _spike_stop_script "refusing: $cmd is a launcher name"
  fi
  _spike_exec "$secs" "$out" "$res" "$@"
}
