#!/bin/bash
# Tests for spike/preflight.sh using fake claude/codex/jq on a private PATH. Offline; never runs a real CLI.
# Run: /bin/bash spike/tests/test_preflight.sh  (exit 0 = all passed)
#
# Round 7 SANDBOX GUARD (a round-6 fixture once overwrote /usr/bin/cp through a symlink):
#   - set -o noclobber; mkbin writes small wrapper scripts (exec /usr/bin/X "$@") instead of symlinks to host tools;
#     every fixture write goes through sbx_put, which refuses a relative path, a physical parent outside $SANDBOX, an
#     existing symlink and a file with more than one link; symlinks are made with sbx_ln (ln -sfn); a refusal fails the suite.
#   - an EXIT tripwire hashes every host tool mkbin wraps and fails the suite if any of them changed.
# The fake provider binaries are Mach-O-headed fixtures (four magic bytes, then a shell body). Preflight registers only a
# Mach-O copy that passes the pinned-signer check, so every "registered" fixture needs the header. On Linux exec hands a file
# it cannot load to /bin/sh (execvp's ENOEXEC fallback), so the bodies run; this is test-only.

set -o noclobber

HERE="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PREFLIGHT="$HERE/../preflight.sh"
COMMON_REAL="$HERE/../lib/common.sh"
RUNNER_REAL="$HERE/../lib/runner.pl"

# Host tools are found once with the caller's PATH; then PATH is pinned so a provider CLI directory is never on it.
JQ_BIN="$(command -v jq)"
if [ -z "$JQ_BIN" ]; then echo "jq is required to run this suite" >&2; exit 1; fi
PATH="/usr/bin:/bin:$(dirname -- "$JQ_BIN")"
export PATH

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing [$3] in:
$2)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (found [$3] in:
$2)" ;; *) ok "$1" ;; esac; }
row() { printf '%s\n' "$1" | grep "^$2 " | head -n 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/spikepre.XXXXXX")" || exit 1
SANDBOX="$(CDPATH= cd -P -- "$SANDBOX" && pwd -P)"
VIOLATIONS="$SANDBOX/.violations"
TRIP_LIST=""

sha_of() { /usr/bin/perl -MDigest::SHA -e 'open my $f, "<", $ARGV[0] or exit 1; binmode $f; print Digest::SHA->new(256)->addfile($f)->hexdigest' -- "$1"; }
link_count() { /usr/bin/perl -e 'my @s = stat($ARGV[0]); print $s[3]' -- "$1"; }
trip_add() { # trip_add <absolute host path>: remember its hash
  case "$1" in /*) ;; *) return 0 ;; esac
  case "$TRIP_LIST" in *"$1 "*) return 0 ;; esac
  TRIP_LIST="$TRIP_LIST$1 $(sha_of "$1")
"
}
trip_check() {
  local line p h now bad_n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="${line% *}"
    h="${line##* }"
    now="$(sha_of "$p")"
    if [ "$now" != "$h" ]; then
      printf 'FAIL host tool changed during the run: %s\n' "$p"
      bad_n=$((bad_n + 1))
    fi
  done <<EOF
$TRIP_LIST
EOF
  return "$bad_n"
}
for t in bash env perl jq git sed awk tr cut head cat grep sleep touch ls dirname ln chmod mkdir rm mv cp mktemp kill ps; do trip_add "$(command -v "$t")"; done

finish() {
  local rc=$? viol=0
  trip_check
  local trc=$?
  if [ -s "$VIOLATIONS" ]; then viol=1; printf 'FAIL the sandbox guard refused a write:\n'; cat "$VIOLATIONS"; fi
  rm -rf "$SANDBOX"
  if [ "$trc" -ne 0 ] || [ "$viol" -ne 0 ]; then
    [ "$rc" -ne 0 ] || exit 1
  fi
}
trap finish EXIT

# A refusal is recorded in a file because sbx_put usually runs in a pipeline (a subshell).
sbx_refuse() { printf 'sandbox guard refused: %s\n' "$1" >> "$VIOLATIONS"; return 1; }
sbx_parent_ok() { # the PHYSICAL parent directory must be inside the sandbox
  local f="$1" dir phys
  case "$f" in /*) ;; *) sbx_refuse "relative path $f"; return 1 ;; esac
  dir="${f%/*}"
  [ -n "$dir" ] || dir="/"
  phys="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)" || { sbx_refuse "no parent for $f"; return 1; }
  case "$phys/" in "$SANDBOX"/*) ;; *) sbx_refuse "parent of $f is outside the sandbox ($phys)"; return 1 ;; esac
  return 0
}
sbx_put() { # sbx_put <file>: stdin -> file (inside the sandbox only; never through a symlink or a hard link)
  local f="$1"
  sbx_parent_ok "$f" || { cat >/dev/null; return 1; }
  if [ -L "$f" ]; then sbx_refuse "$f is a symlink"; cat >/dev/null; return 1; fi
  if [ -e "$f" ] && [ "$(link_count "$f")" != "1" ]; then sbx_refuse "$f has more than one link"; cat >/dev/null; return 1; fi
  cat >| "$f"
}
sbx_ln() { sbx_parent_ok "$2" || return 1; ln -sfn -- "$1" "$2"; }
sbx_cp() { sbx_put "$2" < "$1" || return 1; chmod +x "$2"; }
sbx_mkdir() { # sbx_mkdir <dir>...: mkdir -p, but the nearest EXISTING ancestor must physically be inside the sandbox
  local d anc phys
  for d in "$@"; do
    case "$d" in /*) ;; *) sbx_refuse "relative directory $d"; return 1 ;; esac
    anc="$d"
    while [ ! -d "$anc" ] && [ "$anc" != "/" ]; do
      anc="${anc%/*}"
      [ -n "$anc" ] || anc="/"
    done
    phys="$(CDPATH= cd -P -- "$anc" 2>/dev/null && pwd -P)" || { sbx_refuse "no ancestor for $d"; return 1; }
    case "$phys/" in "$SANDBOX"/*) ;; *) sbx_refuse "directory $d resolves outside the sandbox ($phys)"; return 1 ;; esac
    mkdir -p -- "$d"
  done
}

# mkmacho <path> < body: a Mach-O-headed fixture (cf fa ed fe, a newline, then the shell body from stdin). Executable.
mkmacho() {
  { printf '\317\372\355\376\n'; cat; } | sbx_put "$1"
  chmod +x "$1"
}

# Real helper tools that preflight and common.sh need. Each private bin dir gets a small WRAPPER SCRIPT per tool
# (exec /usr/bin/X "$@"), never a symlink: a write through a link could reach a system file. jq and git get wrappers too,
# unless the test leaves them out on purpose. codesign is never wrapped: each test supplies its own fake.
TOOLS="tr cut head awk sed cat grep sleep touch ls dirname env"

# mkwrap <bindir> <tool>: wrapper for a host tool; the tool's hash is remembered by the tripwire.
mkwrap() {
  local real
  real="$(command -v "$2")" || return 0
  trip_add "$real"
  printf '#!/bin/sh\nexec %s "$@"\n' "$real" | sbx_put "$1/$2"
  chmod +x "$1/$2"
}
# mkbin <dir> [with-jq] [with-git]: private bin dir with wrapper scripts for the helper tools.
mkbin() {
  local d="$1" t
  sbx_mkdir "$d"
  for t in $TOOLS; do mkwrap "$d" "$t"; done
  if [ "${2:-yes}" = yes ]; then mkwrap "$d" jq; fi
  if [ "${3:-yes}" = yes ]; then mkwrap "$d" git; fi
}

sbx_mkdir "$SANDBOX/home"

# The codesign constant lives in one line of runner.pl. These tests run a SANDBOX COPY of common.sh, runner.pl and
# preflight.sh with only that line rewritten to a fake, so the shipped scripts have no override hook and the tests never
# depend on a codesign shim on PATH (rule 6). The shipped runner.pl is checked below to keep the real absolute path.
CS="$SANDBOX/fakebin/codesign"
sbx_mkdir "$SANDBOX/fakebin" "$SANDBOX/spike/lib"
sbx_cp "$COMMON_REAL" "$SANDBOX/spike/lib/common.sh"
sed "s|^use constant CODESIGN_BIN => .*|use constant CODESIGN_BIN => \"$CS\";|" "$RUNNER_REAL" | sbx_put "$SANDBOX/spike/lib/runner.pl"
sbx_cp "$PREFLIGHT" "$SANDBOX/spike/preflight.sh"
PREFLIGHT_UT="$SANDBOX/spike/preflight.sh"
has "the shipped runner.pl keeps the fixed codesign path" "$(cat "$RUNNER_REAL")" 'use constant CODESIGN_BIN => "/usr/bin/codesign";'
lacks "the shipped common.sh defines no codesign constant" "$(cat "$COMMON_REAL")" "readonly CODESIGN_BIN"
lacks "the shipped preflight.sh defines no codesign constant of its own" "$(cat "$PREFLIGHT")" "CODESIGN_BIN="
has "the sandbox runner.pl points the codesign constant at the fake" "$(cat "$SANDBOX/spike/lib/runner.pl")" "use constant CODESIGN_BIN => \"$CS\";"
eq "the sandbox runner.pl differs from the shipped one only in the codesign constant (2 changed lines)" "2" "$(diff "$RUNNER_REAL" "$SANDBOX/spike/lib/runner.pl" | grep -c '^[<>]')"
eq "the sandbox common.sh is the shipped common.sh" "" "$(diff "$COMMON_REAL" "$SANDBOX/spike/lib/common.sh")"
eq "preflight.sh starts with the /bin/bash shebang" "#!/bin/bash" "$(head -n 1 "$PREFLIGHT")"

# run_preflight <bindir>: runs the sandbox copy with PATH = that dir only.
run_preflight() {
  env -i PATH="$1" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT_UT" 2>&1
}

# mkcodesign <file> <mode> [logfile]: a fake codesign. Pinned team ids are the ones in runner.pl. The fake decides the team
# from the BASENAME of its last argument (the target), never from the rest of the command line: the sandbox path itself
# contains the word claude.
#   good      Developer ID Application, pinned team, chain check passes
#   unsigned  verify fails: not signed at all
#   adhoc     verify passes, ad-hoc signature, no authority, team not set
#   wrongteam Developer ID Application but another team
#   notdev    pinned team but an "Apple Development" authority
#   forged    text looks right, but the -R chain requirement fails
#   weird     verify fails with rc 3
mkcodesign() {
  local f="$1" mode="$2" log="${3:-/dev/null}"
  if [ -e "$f" ]; then rm -f "$f"; fi
  sbx_put "$f" <<EOF
#!/bin/sh
echo "\$*" >> "$log"
MODE="$mode"
for a in "\$@"; do last="\$a"; done
base="\${last##*/}"
TEAM=UNKNOWN
case "\$base" in claude*) TEAM=Q6L2SF6YDW ;; codex*) TEAM=2DC432GLL2 ;; esac
case "\$MODE" in
  unsigned) echo "code object is not signed at all" >&2; exit 1 ;;
  weird) echo "weird failure" >&2; exit 3 ;;
esac
case "\$1" in
  --verify)
    case "\$3" in -R=*) [ "\$MODE" = forged ] && { echo "failed to satisfy requirement" >&2; exit 3; } ;; esac
    exit 0 ;;
  -dv)
    case "\$MODE" in
      good) printf 'Executable=/x\nAuthority=Developer ID Application: Fake Dev (%s)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=%s\n' "\$TEAM" "\$TEAM" >&2 ;;
      forged) printf 'Authority=Developer ID Application: Fake Dev (%s)\nTeamIdentifier=%s\n' "\$TEAM" "\$TEAM" >&2 ;;
      adhoc) printf 'Signature=adhoc\nTeamIdentifier=not set\n' >&2 ;;
      wrongteam) printf 'Authority=Developer ID Application: Evil Corp (WRONGTEAM1)\nTeamIdentifier=WRONGTEAM1\n' >&2 ;;
      notdev) printf 'Authority=Apple Development: someone (%s)\nTeamIdentifier=%s\n' "\$TEAM" "\$TEAM" >&2 ;;
    esac
    exit 0 ;;
esac
exit 1
EOF
  chmod +x "$f"
}

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 1: both CLIs are Mach-O (fixtures) with a valid signature. Their status commands print secrets: none may leak.
B1="$SANDBOX/b1"
mkbin "$B1"
LOG1="$SANDBOX/log1"
mkcodesign "$CS" good "$SANDBOX/codesign1.log"
for n in claude codex; do
  mkmacho "$B1/$n" <<EOF
echo "\$0 \$*" >> "$LOG1"
case "\$1" in
  --version) printf 'v9.9.9 (Fake)\033[31mRED\033]0;title\007\n'; exit 0 ;;
  auth|login) echo "SECRET jane@example.com token=abc123"; echo "SECRET2 on stderr" >&2; [ "$n" = claude ] && exit 0; exit 1 ;;
esac
exit 9
EOF
done
OUT1="$(run_preflight "$B1")"
RC1=$?
eq "scenario 1: preflight exits 0" "0" "$RC1"
has "scenario 1: header has a SIGNATURE column" "$OUT1" "SIGNATURE"
has "scenario 1: claude row is valid and shows the signer and team" "$(row "$OUT1" claude)" "valid; Developer ID Application: Fake Dev; team Q6L2SF6YDW"
has "scenario 1: codex row is valid and shows the OpenAI team (the fake keys the team on the target basename)" "$(row "$OUT1" codex)" "team 2DC432GLL2"
has "scenario 1: claude is signed in (exit code 0)" "$(row "$OUT1" claude)" "signed in"
has "scenario 1: codex is not signed in (exit code 1)" "$(row "$OUT1" codex)" "not signed in (rc=1)"
has "scenario 1: the version run reached the fixture body (its log line; the version column cannot show a fixture's first line on Linux, see the header note)" "$(cat "$LOG1")" "claude --version"
has "scenario 1: the jq row shows a version" "$(row "$OUT1" jq)" "jq"
lacks "scenario 1: status output text does not leak (SECRET)" "$OUT1" "SECRET"
lacks "scenario 1: status output email does not leak" "$OUT1" "jane"
lacks "scenario 1: status output token does not leak" "$OUT1" "abc123"
lacks "scenario 1: output has no @" "$OUT1" "@"
case "$OUT1" in *"$(printf '\033')"*) bad "scenario 1: terminal escape removed from version" ;; *) ok "scenario 1: terminal escape removed from version" ;; esac
case "$OUT1" in *"$(printf '\007')"*) bad "scenario 1: BEL removed from version" ;; *) ok "scenario 1: BEL removed from version" ;; esac
has "scenario 1: footer explains the path display" "$OUT1" "any at-sign in a path shown as %"
has "scenario 1: claude was run with --version" "$(cat "$LOG1")" "claude --version"
has "scenario 1: claude was run with auth status" "$(cat "$LOG1")" "claude auth status"
has "scenario 1: codex was run with login status" "$(cat "$LOG1")" "codex login status"
has "scenario 1: the commands ran from the private copy directory (not the original)" "$(cat "$LOG1")" "$SANDBOX/spike-verify."
lacks "scenario 1: the original path was never executed" "$(cat "$LOG1")" "$B1/claude"
has "scenario 1: the chain-to-Apple requirement for the pinned team was checked" "$(cat "$SANDBOX/codesign1.log")" 'anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
lacks "scenario 1: no prompt was ever sent" "$(cat "$LOG1")" " -p "
lacks "scenario 1: no exec subcommand was run" "$(cat "$LOG1")" "codex exec"
eq "scenario 1: the private copy directory is removed on exit" "" "$(ls -d "$SANDBOX"/spike-verify.* 2>/dev/null)"
eq "scenario 1: no scratch file is left in the temporary directory" "" "$(ls -d "$SANDBOX"/spike-preflight* 2>/dev/null)"

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 2: an unsigned look-alike Mach-O. It must be reported unsigned and NEVER executed.
B2="$SANDBOX/b2"
mkbin "$B2"
MARK2="$SANDBOX/marker2"
for n in claude codex; do
  mkmacho "$B2/$n" <<EOF
touch "$MARK2"
echo "SECRET jane@example.com"
exit 0
EOF
done
mkcodesign "$CS" unsigned
OUT2="$(run_preflight "$B2")"
RC2=$?
eq "scenario 2: preflight exits 0" "0" "$RC2"
has "scenario 2: claude is reported NOT SIGNED" "$(row "$OUT2" claude)" "NOT SIGNED"
has "scenario 2: codex is reported NOT SIGNED" "$(row "$OUT2" codex)" "NOT SIGNED"
has "scenario 2: version is skipped" "$(row "$OUT2" claude)" "skipped (unverified)"
if [ -e "$MARK2" ]; then bad "scenario 2: unsigned look-alike was NOT executed"; else ok "scenario 2: unsigned look-alike was NOT executed"; fi
lacks "scenario 2: nothing leaked" "$OUT2" "SECRET"
has "scenario 2: a note says it was not executed" "$OUT2" "NOT executed"

# Scenario 2b: codesign itself fails in some other way -> also not executed.
B2B="$SANDBOX/b2b"
mkbin "$B2B"
sbx_cp "$B2/claude" "$B2B/claude"
sbx_cp "$B2/codex" "$B2B/codex"
mkcodesign "$CS" weird
rm -f "$MARK2"
OUT2B="$(run_preflight "$B2B")"
has "scenario 2b: other codesign failures are NOT VERIFIED" "$(row "$OUT2B" claude)" "NOT VERIFIED (codesign rc=3)"
if [ -e "$MARK2" ]; then bad "scenario 2b: unverified binary was NOT executed"; else ok "scenario 2b: unverified binary was NOT executed"; fi

# Scenarios 2c-2f: the signature verifies, but it is not the pinned vendor signature. Never executed.
for mode in adhoc wrongteam notdev forged; do
  BX="$SANDBOX/b2-$mode"
  mkbin "$BX"
  sbx_cp "$B2/claude" "$BX/claude"
  sbx_cp "$B2/codex" "$BX/codex"
  mkcodesign "$CS" "$mode"
  rm -f "$MARK2"
  OUTX="$(run_preflight "$BX")"
  eq "scenario 2 ($mode): preflight exits 0" "0" "$?"
  has "scenario 2 ($mode): claude is UNTRUSTED" "$(row "$OUTX" claude)" "UNTRUSTED"
  has "scenario 2 ($mode): codex is UNTRUSTED" "$(row "$OUTX" codex)" "UNTRUSTED"
  has "scenario 2 ($mode): version is skipped" "$(row "$OUTX" claude)" "skipped (unverified)"
  if [ -e "$MARK2" ]; then bad "scenario 2 ($mode): binary was NOT executed"; else ok "scenario 2 ($mode): binary was NOT executed"; fi
  lacks "scenario 2 ($mode): nothing leaked" "$OUTX" "SECRET"
  case "$mode" in
    adhoc) has "scenario 2 (adhoc): reported as ad-hoc, not Developer ID" "$(row "$OUTX" claude)" "ad-hoc" ;;
    wrongteam) has "scenario 2 (wrongteam): reported as not the pinned team" "$(row "$OUTX" claude)" "not the pinned team" ;;
    forged) has "scenario 2 (forged): reported as chain mismatch" "$(row "$OUTX" claude)" "certificate chain" ;;
  esac
done

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 3: script launchers are NOT executed; the SIGNATURE cell and a note say so. The helper classifies by the first
# bytes of the opened file (a #! line), not by file(1).
B3="$SANDBOX/b3"
mkbin "$B3"
LOG3="$SANDBOX/log3"
mkcodesign "$CS" unsigned
for n in claude codex; do
  sbx_put "$B3/$n" <<EOF
#!/bin/sh
echo "\$0 \$*" >> "$LOG3"
case "\$1" in
  --version) echo "launcher 1.0"; exit 0 ;;
  auth|login) exit 0 ;;
esac
exit 9
EOF
done
chmod +x "$B3/claude" "$B3/codex"
OUT3="$(run_preflight "$B3")"
RC3=$?
eq "scenario 3: preflight exits 0" "0" "$RC3"
has "scenario 3: SIGNATURE cell says launcher only, not executed" "$(row "$OUT3" claude)" "launcher only, not executed (needs human approval)"
has "scenario 3: kind is script" "$(row "$OUT3" claude)" "script"
has "scenario 3: version is skipped" "$(row "$OUT3" claude)" "skipped (unverified)"
has "scenario 3: note says the launcher was NOT executed" "$OUT3" "script launcher and was NOT executed"
if [ -s "$LOG3" ]; then bad "scenario 3: no launcher was executed"; else ok "scenario 3: no launcher was executed"; fi

# Scenario 3b: a symlinked CLI is resolved ONCE. The RESOLVED file is copied, the COPY is verified, and only the copy runs.
B3B="$SANDBOX/b3b"
mkbin "$B3B"
CS3B="$SANDBOX/codesign3b.log"
mkcodesign "$CS" good "$CS3B"
sbx_mkdir "$SANDBOX/real3b"
LOG3B="$SANDBOX/log3b"
DIR3B="$SANDBOX/dir3b"
mkmacho "$SANDBOX/real3b/claude-real" <<EOF
echo "RAN \$0 \$*" >> "$LOG3B"
ls -ld "\$(dirname "\$0")" > "$DIR3B"
exit 0
EOF
sbx_ln "$SANDBOX/real3b/claude-real" "$B3B/claude"
OUT3B="$(run_preflight "$B3B")"
has "scenario 3b: codesign was asked about the private copy (verify the copy, not the original)" "$(cat "$CS3B")" "--verify --strict $SANDBOX/spike-verify."
lacks "scenario 3b: codesign was never asked about the original" "$(cat "$CS3B")" "claude-real"
lacks "scenario 3b: codesign was never asked about the symlink path" "$(cat "$CS3B")" "$B3B/claude"
case "$(cat "$LOG3B")" in
  *"RAN $SANDBOX/spike-verify."*"/claude --version"*) ok "scenario 3b: the private copy is what ran (version)" ;;
  *) bad "scenario 3b: the private copy is what ran (version)" ;;
esac
case "$(cat "$LOG3B")" in
  *"RAN $SANDBOX/spike-verify."*"/claude auth status"*) ok "scenario 3b: the private copy is what ran (status)" ;;
  *) bad "scenario 3b: the private copy is what ran (status)" ;;
esac
lacks "scenario 3b: the original was never executed (its marker is absent)" "$(cat "$LOG3B")" "claude-real"
case "$(cat "$DIR3B")" in
  drwx------*) ok "scenario 3b: the private copy directory is mode 700" ;;
  *) bad "scenario 3b: the private copy directory is mode 700 (got: $(cat "$DIR3B"))" ;;
esac
has "scenario 3b: the resolved path is shown" "$(row "$OUT3B" claude)" "claude-real"

# Scenario 3c: a copy that cannot run (its interpreter is missing) is reported "needs human review". The original path is
# never used as a fallback.
B3C="$SANDBOX/b3c"
mkbin "$B3C"
mkcodesign "$CS" good
for n in claude codex; do
  mkmacho "$B3C/$n" <<EOF
exec /nonexistent/interpreter
EOF
done
OUT3C="$(run_preflight "$B3C")"
has "scenario 3c: a copy that cannot run is 'needs human review' for the version" "$(row "$OUT3C" claude)" "needs human review"
has "scenario 3c: a copy that cannot run is 'needs human review' for sign-in" "$(row "$OUT3C" claude)" "needs human review"
has "scenario 3c: a note says the original path was NOT used" "$OUT3C" "the original path was NOT used"

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 4: no CLIs installed -> still exit 0, rows say not installed.
B4="$SANDBOX/b4"
mkbin "$B4"
OUT4="$(run_preflight "$B4")"
RC4=$?
eq "scenario 4: missing CLIs -> exit 0" "0" "$RC4"
has "scenario 4: claude row says not installed" "$(row "$OUT4" claude)" "not installed"
has "scenario 4: codex row says not installed" "$(row "$OUT4" codex)" "not installed"

# Scenario 5: missing jq or git -> exit 1.
B5="$SANDBOX/b5"
mkbin "$B5" no yes
OUT5="$(run_preflight "$B5")"
eq "scenario 5: missing jq -> exit 1" "1" "$?"
has "scenario 5: jq row says MISSING" "$(row "$OUT5" jq)" "MISSING"
B6="$SANDBOX/b6"
mkbin "$B6" yes no
OUT6="$(run_preflight "$B6")"
eq "scenario 5: missing git -> exit 1" "1" "$?"
has "scenario 5: git row says MISSING" "$(row "$OUT6" git)" "MISSING"

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 6: no codesign at the fixed path (Linux, or a Mac without the tool). The SHIPPED scripts, unmodified, report
# every CLI as skipped (unverified) and execute nothing.
B7="$SANDBOX/b7"
mkbin "$B7"
MARK7="$SANDBOX/marker7"
for n in claude codex; do
  mkmacho "$B7/$n" <<EOF
touch "$MARK7"
exit 0
EOF
done
OUT7="$(env -i PATH="$B7" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT" 2>&1)"
has "scenario 6: the shipped script reports claude as skipped (unverified)" "$(row "$OUT7" claude)" "skipped (unverified)"
has "scenario 6: the shipped script reports codex as skipped (unverified)" "$(row "$OUT7" codex)" "skipped (unverified)"
if [ ! -x /usr/bin/codesign ]; then
  has "scenario 6: without /usr/bin/codesign the signature cell says codesign unavailable" "$(row "$OUT7" claude)" "NOT VERIFIED (codesign unavailable)"
fi
if [ -e "$MARK7" ]; then bad "scenario 6: no CLI was executed"; else ok "scenario 6: no CLI was executed"; fi

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 7: the codesign path cannot be changed from the environment. An exported fake codesign, on PATH and in the
# CODESIGN and CODESIGN_BIN variables, is never called by the SHIPPED scripts.
B8="$SANDBOX/b8"
mkbin "$B8"
MARK8="$SANDBOX/marker8"
for n in claude codex; do
  mkmacho "$B8/$n" <<EOF
touch "$MARK8"
exit 0
EOF
done
ENVCS="$SANDBOX/envcs"
sbx_mkdir "$ENVCS"
mkcodesign "$ENVCS/codesign" good "$SANDBOX/envcs.log"
OUT8="$(env -i PATH="$ENVCS:$B8" CODESIGN="$ENVCS/codesign" CODESIGN_BIN="$ENVCS/codesign" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT" 2>&1)"
if [ -s "$SANDBOX/envcs.log" ]; then bad "scenario 7: an exported codesign (PATH and env) is never called"; else ok "scenario 7: an exported codesign (PATH and env) is never called"; fi
has "scenario 7: with the exported fake, claude is still skipped (unverified)" "$(row "$OUT8" claude)" "skipped (unverified)"
if [ -e "$MARK8" ]; then bad "scenario 7: no CLI was executed"; else ok "scenario 7: no CLI was executed"; fi

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 8 (rule 4): a canary under a fake home, reached through a provider-named symlink. The canary is never read,
# copied or printed. Logging wrappers for file, dd and cp sit first on PATH: preflight no longer calls any of them, so none
# may be called at all.
B9="$SANDBOX/b9"
mkbin "$B9"
sbx_mkdir "$SANDBOX/home/.claude"
printf 'CANARY-SECRET-7f3a\n' | sbx_put "$SANDBOX/home/.claude/canary"
chmod +x "$SANDBOX/home/.claude/canary"
sbx_ln "$SANDBOX/home/.claude/canary" "$B9/claude"
LOG9="$SANDBOX/log9-tools"
for t in file dd cp; do
  real="$(command -v "$t")"
  trip_add "$real"
  sbx_put "$B9/$t" <<EOF
#!/bin/sh
echo "$t \$*" >> "$LOG9"
exec $real "\$@"
EOF
  chmod +x "$B9/$t"
done
mkcodesign "$CS" good
OUT9="$(run_preflight "$B9")"
has "scenario 8: the canary provider path is refused by the CLI-home rule" "$(row "$OUT9" claude)" "REFUSED (inside a CLI home directory; not read)"
lacks "scenario 8: the canary text never appears in the report" "$OUT9" "CANARY-SECRET"
eq "scenario 8: no file, dd or cp call was made at all" "" "$(cat "$LOG9" 2>/dev/null)"

# Scenario 8b: the ratified exception. The PATH-resolved provider binary itself lies inside a CLI home directory and is a
# Mach-O: it is allowed (kind mach-o) and registered like any other copy. Nothing else under that home is read.
B9B="$SANDBOX/b9b"
mkbin "$B9B"
sbx_mkdir "$SANDBOX/home/.claude/bin"
LOG9B="$SANDBOX/log9b"
mkmacho "$SANDBOX/home/.claude/bin/claude-real" <<EOF
echo "RAN9B \$0 \$*" >> "$LOG9B"
case "\$1" in --version) echo "v8.8.8"; exit 0 ;; esac
exit 0
EOF
sbx_ln "$SANDBOX/home/.claude/bin/claude-real" "$B9B/claude"
OUT9B="$(run_preflight "$B9B")"
has "scenario 8b: the Mach-O provider binary inside a CLI home is allowed (kind mach-o)" "$(row "$OUT9B" claude)" "mach-o"
has "scenario 8b: it is then verified like any copy (valid signer)" "$(row "$OUT9B" claude)" "valid; Developer ID Application"
has "scenario 8b: the copy runs (its body wrote the log; the version column cannot show a fixture's first line on Linux)" "$(cat "$LOG9B")" "RAN9B"
lacks "scenario 8b: the copy that ran is not the one inside the CLI home" "$(cat "$LOG9B")" "$SANDBOX/home/.claude"

# Scenario 8c (Opus finding 5): a HARD LINK to the canary, placed outside every CLI home, is refused before any read.
B9C="$SANDBOX/b9c"
mkbin "$B9C"
ln "$SANDBOX/home/.claude/canary" "$B9C/claude"
OUT9C="$(run_preflight "$B9C")"
has "scenario 8c: a hard link to a canary is refused" "$(row "$OUT9C" claude)" "REFUSED (hard-linked file"
lacks "scenario 8c: the canary text never appears in the report" "$OUT9C" "CANARY-SECRET"
has "scenario 8c: a note says it was not read or executed" "$OUT9C" "hard-linked file"

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 9: a temporary directory that others can write (not sticky) is refused: rc 1, "needs human review", and no CLI
# runs. A sticky one is accepted.
B10="$SANDBOX/b10"
mkbin "$B10"
MARK10="$SANDBOX/marker10"
mkmacho "$B10/claude" <<EOF
touch "$MARK10"
exit 0
EOF
LOOSE="$SANDBOX/loose"
sbx_mkdir "$LOOSE"
chmod 777 "$LOOSE"
OUT10="$(env -i PATH="$B10" HOME="$SANDBOX/home" TMPDIR="$LOOSE" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT_UT" 2>&1)"
eq "scenario 9: a world-writable temporary directory without the sticky bit -> exit 1" "1" "$?"
has "scenario 9: the refusal says needs human review" "$OUT10" "needs human review"
if [ -e "$MARK10" ]; then bad "scenario 9: no CLI ran in the unsafe directory"; else ok "scenario 9: no CLI ran in the unsafe directory"; fi
STICKY="$SANDBOX/sticky"
sbx_mkdir "$STICKY"
chmod 1777 "$STICKY"
OUT10S="$(env -i PATH="$B10" HOME="$SANDBOX/home" TMPDIR="$STICKY" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT_UT" 2>&1)"
eq "scenario 9: a sticky temporary directory is accepted (exit 0)" "0" "$?"
has "scenario 9: the sticky run prints the report" "$OUT10S" "SIGNATURE"
# A temporary directory inside a CLI home is refused too (the verify directory cannot live in a CLI home).
HOMETMP="$SANDBOX/home/.claude/tmp"
sbx_mkdir "$HOMETMP"
OUT10H="$(env -i PATH="$B10" HOME="$SANDBOX/home" TMPDIR="$HOMETMP" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT_UT" 2>&1)"
eq "scenario 9: a temporary directory inside a CLI home -> exit 1" "1" "$?"
has "scenario 9: that refusal says needs human review" "$OUT10H" "needs human review"
eq "scenario 9: nothing was created inside the CLI home" "" "$(ls "$HOMETMP")"

# Scenario 10: stale spike-verify.* directories left by a SIGKILLed run are swept at start. A directory whose recorded
# owner is dead goes; one whose owner is alive stays.
SW="$SANDBOX/sweep"
sbx_mkdir "$SW"
chmod 700 "$SW"
STALE="$SW/spike-verify.stale0001"
sbx_mkdir "$STALE"
DEADPID="$(sh -c 'echo $$')"
printf '%s\n' "$DEADPID" | sbx_put "$STALE/.owner"
LIVE="$SW/spike-verify.live00001"
sbx_mkdir "$LIVE"
sleep 60 &
LIVEPID=$!
printf '%s\n' "$LIVEPID" | sbx_put "$LIVE/.owner"
OUT11="$(env -i PATH="$B4" HOME="$SANDBOX/home" TMPDIR="$SW" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT_UT" 2>&1)"
eq "scenario 10: preflight exits 0 in the sweep directory" "0" "$?"
if [ ! -e "$STALE" ]; then ok "scenario 10: the stale directory (dead owner) was swept"; else bad "scenario 10: the stale directory (dead owner) was swept"; fi
if [ -d "$LIVE" ]; then ok "scenario 10: a directory whose owner is alive is left alone"; else bad "scenario 10: a directory whose owner is alive is left alone"; fi
kill "$LIVEPID" 2>/dev/null
wait "$LIVEPID" 2>/dev/null
leftovers="$(ls -d "$SW"/spike-verify.* 2>/dev/null | grep -v "$LIVE")"
eq "scenario 10: the run's own private directory is removed on exit" "" "$leftovers"

# Scenario 11: non-Mach-O files are refused by the helper's magic check on the opened file and never executed: an ELF
# header, and a shell script with a CLI name.
B11="$SANDBOX/b11"
mkbin "$B11"
MARK11="$SANDBOX/marker11"
printf '\177ELF\002\001\001\000 fake elf\n' | sbx_put "$B11/claude"
printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$MARK11" | sbx_put "$B11/codex"
chmod +x "$B11/claude" "$B11/codex"
mkcodesign "$CS" good
OUT12="$(run_preflight "$B11")"
has "scenario 11: an ELF header named claude is NOT VERIFIED (not a Mach-O file)" "$(row "$OUT12" claude)" "NOT VERIFIED (not a Mach-O file)"
has "scenario 11: a shell script named codex is a launcher, not executed (changed in round 7: the helper classifies by #!)" "$(row "$OUT12" codex)" "launcher only, not executed"
if [ -e "$MARK11" ]; then bad "scenario 11: neither non-Mach-O file was executed"; else ok "scenario 11: neither non-Mach-O file was executed"; fi

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 12 (Opus finding 1): a fake perl, env, bash and codesign first on PATH change nothing. An unsigned look-alike is
# still NOT SIGNED and never runs; a good fixture is still verified by the REAL logic; the fakes are never started.
B12="$SANDBOX/b12"
mkbin "$B12"
for t in perl bash; do
  sbx_put "$B12/$t" <<EOF
#!/bin/sh
touch "$SANDBOX/fake-$t-ran"
exit 0
EOF
  chmod +x "$B12/$t"
done
rm -f "$B12/env"
sbx_put "$B12/env" <<EOF
#!/bin/sh
touch "$SANDBOX/fake-env-ran"
exit 0
EOF
chmod +x "$B12/env"
MARK12="$SANDBOX/marker12"
for n in claude codex; do
  mkmacho "$B12/$n" <<EOF
touch "$MARK12"
exit 0
EOF
done
mkcodesign "$CS" unsigned
OUT13="$(run_preflight "$B12")"
has "scenario 12: with a fake perl first on PATH an unsigned Mach-O is still NOT SIGNED" "$(row "$OUT13" claude)" "NOT SIGNED"
lacks "scenario 12: it never registers as valid" "$OUT13" "valid;"
if [ -e "$MARK12" ]; then bad "scenario 12: the unsigned look-alike was not executed"; else ok "scenario 12: the unsigned look-alike was not executed"; fi
mkcodesign "$CS" good
OUT13G="$(run_preflight "$B12")"
has "scenario 12: with a fake perl first on PATH a good fixture is verified by the real logic" "$(row "$OUT13G" claude)" "valid; Developer ID Application"
if [ -e "$SANDBOX/fake-perl-ran" ] || [ -e "$SANDBOX/fake-env-ran" ] || [ -e "$SANDBOX/fake-bash-ran" ]; then bad "scenario 12: the fake perl, env and bash were never started"; else ok "scenario 12: the fake perl, env and bash were never started"; fi

# Scenario 13 (Opus finding 9): a TERM during a run leaves no verify directory and no scratch file behind, and the command
# the run started is gone.
B13="$SANDBOX/b13"
mkbin "$B13"
mkcodesign "$CS" good
mkmacho "$B13/claude" <<EOF
echo "\$\$" > "$SANDBOX/term13.pid"
touch "$SANDBOX/term13.started"
sleep 20
exit 0
EOF
env -i PATH="$B13" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT_UT" >| "$SANDBOX/term13.out" 2>&1 &
PF13=$!
n=0
while [ ! -e "$SANDBOX/term13.started" ] && [ "$n" -lt 60 ]; do sleep 0.1; n=$((n + 1)); done
if [ -e "$SANDBOX/term13.started" ]; then ok "scenario 13: the fixture started inside the run"; else bad "scenario 13: the fixture started inside the run"; fi
kill -s TERM "$PF13" 2>/dev/null
wait "$PF13" 2>/dev/null
RC13=$?
eq "scenario 13: preflight exits with the TERM status (143)" "143" "$RC13"
eq "scenario 13: no spike-verify.* is left in the temporary directory after TERM" "" "$(ls -d "$SANDBOX"/spike-verify.* 2>/dev/null)"
eq "scenario 13: no scratch file is left in the temporary directory after TERM" "" "$(ls -d "$SANDBOX"/spike-preflight* 2>/dev/null)"
P13="$(cat "$SANDBOX/term13.pid" 2>/dev/null)"
n=0
while [ -n "$P13" ] && kill -0 "$P13" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
if [ -n "$P13" ] && kill -0 "$P13" 2>/dev/null; then bad "scenario 13: the command started by the run is gone after TERM"; kill -9 "$P13" 2>/dev/null; else ok "scenario 13: the command started by the run is gone after TERM"; fi

# Scenario 14 (Opus finding 10): jq and git are probed with the closed environment, not the caller's.
B14="$SANDBOX/b14"
mkbin "$B14" no yes
ENVLOG="$SANDBOX/jq14.env"
sbx_put "$B14/jq" <<EOF
#!/bin/sh
/usr/bin/env > "$ENVLOG"
echo "jq-1.7-fake"
EOF
chmod +x "$B14/jq"
mkcodesign "$CS" good
OUT14="$(env -i PATH="$B14" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" USER=tester LOGNAME=tester FOO_API_KEY=k1 FOO_HOME=/h BAR_TOKEN=t2 PERL5OPT=-MFoo SPIKE_LIVE=1 /bin/bash "$PREFLIGHT_UT" 2>&1)"
has "scenario 14: the jq probe ran and its version is shown" "$(row "$OUT14" jq)" "jq-1.7-fake"
lacks "scenario 14: the jq probe saw no API-key variable" "$(cat "$ENVLOG")" "FOO_API_KEY"
lacks "scenario 14: the jq probe saw no home-like variable" "$(cat "$ENVLOG")" "FOO_HOME"
lacks "scenario 14: the jq probe saw no token variable" "$(cat "$ENVLOG")" "BAR_TOKEN"
lacks "scenario 14: the jq probe saw no PERL5OPT" "$(cat "$ENVLOG")" "PERL5OPT"
lacks "scenario 14: the jq probe saw no SPIKE_LIVE" "$(cat "$ENVLOG")" "SPIKE_LIVE"
has "scenario 14: the jq probe saw the closed set (PATH)" "$(cat "$ENVLOG")" "PATH="

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
