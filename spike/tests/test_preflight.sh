#!/usr/bin/env bash
# Tests for spike/preflight.sh using fake claude/codex/codesign/file on a private PATH. Offline; never runs a real CLI.
# Run: /bin/bash spike/tests/test_preflight.sh  (exit 0 = all passed)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREFLIGHT="$HERE/../preflight.sh"

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
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# Real tools that preflight and common.sh need, linked into each private bin dir.
TOOLS="dirname basename mktemp rm head tr cut sed awk grep cat date mkdir readlink sleep env perl wc"

# mkbin <dir> [with-jq] [with-git]: private bin dir with the real helper tools linked in.
mkbin() {
  local d="$1" t p
  mkdir -p "$d"
  for t in $TOOLS; do
    p="$(command -v "$t")" && ln -sf "$p" "$d/$t"
  done
  if [ "${2:-yes}" = yes ]; then ln -sf "$(command -v jq)" "$d/jq"; fi
  if [ "${3:-yes}" = yes ]; then ln -sf "$(command -v git)" "$d/git"; fi
}

# run_preflight <bindir>: runs preflight with PATH = that dir only.
run_preflight() {
  env -i PATH="$1" HOME="$SANDBOX/home" TMPDIR="$SANDBOX" USER=tester LOGNAME=tester /bin/bash "$PREFLIGHT" 2>&1
}

mkdir -p "$SANDBOX/home"

# mkcodesign <file> <mode> [logfile]: a fake codesign. Pinned team ids are the ones in preflight.sh.
#   good      Developer ID Application, pinned team, chain check passes
#   unsigned  verify fails: not signed at all
#   adhoc     verify passes, ad-hoc signature, no authority, team not set
#   wrongteam Developer ID Application but another team
#   notdev    pinned team but an "Apple Development" authority
#   forged    text looks right, but the -R chain requirement fails
#   weird     verify fails with rc 3
mkcodesign() {
  local f="$1" mode="$2" log="${3:-/dev/null}"
  cat > "$f" <<EOF
#!/bin/sh
echo "\$*" >> "$log"
MODE="$mode"
TEAM=UNKNOWN
case "\$*" in *claude*) TEAM=Q6L2SF6YDW ;; *codex*) TEAM=2DC432GLL2 ;; esac
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
# Scenario 1: both CLIs are "Mach-O" with a valid signature. Their status commands print secrets: none may leak.
B1="$SANDBOX/b1"
mkbin "$B1"
LOG1="$SANDBOX/log1"
cat > "$B1/file" <<'EOF'
#!/bin/sh
echo "Mach-O 64-bit executable arm64"
EOF
mkcodesign "$B1/codesign" good "$SANDBOX/codesign1.log"
for n in claude codex; do
  cat > "$B1/$n" <<EOF
#!/bin/sh
echo "\$0 \$*" >> "$LOG1"
case "\$1" in
  --version) printf 'v9.9.9 (Fake)\033[31mRED\033]0;title\007\n'; exit 0 ;;
  auth|login) echo "SECRET jane@example.com token=abc123"; echo "SECRET2 on stderr" >&2; [ "$n" = claude ] && exit 0; exit 1 ;;
esac
exit 9
EOF
done
chmod +x "$B1/file" "$B1/codesign" "$B1/claude" "$B1/codex"
OUT1="$(run_preflight "$B1")"
RC1=$?
eq "scenario 1: preflight exits 0" "0" "$RC1"
has "scenario 1: header has a SIGNATURE column" "$OUT1" "SIGNATURE"
has "scenario 1: claude row is valid and shows the signer and team" "$(row "$OUT1" claude)" "valid; Developer ID Application: Fake Dev; team Q6L2SF6YDW"
has "scenario 1: claude is signed in (exit code 0)" "$(row "$OUT1" claude)" "signed in"
has "scenario 1: codex is not signed in (exit code 1)" "$(row "$OUT1" codex)" "not signed in (rc=1)"
has "scenario 1: version is shown" "$(row "$OUT1" claude)" "v9.9.9 (Fake)"
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
has "scenario 1: the chain-to-Apple requirement for the pinned team was checked" "$(cat "$SANDBOX/codesign1.log")" 'anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
lacks "scenario 1: no prompt was ever sent" "$(cat "$LOG1")" " -p "
lacks "scenario 1: no exec subcommand was run" "$(cat "$LOG1")" "codex exec"

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 2: an unsigned look-alike Mach-O. It must be reported unsigned and NEVER executed.
B2="$SANDBOX/b2"
mkbin "$B2"
MARK2="$SANDBOX/marker2"
cat > "$B2/file" <<'EOF'
#!/bin/sh
echo "Mach-O 64-bit executable arm64"
EOF
mkcodesign "$B2/codesign" unsigned
for n in claude codex; do
  cat > "$B2/$n" <<EOF
#!/bin/sh
touch "$MARK2"
echo "SECRET jane@example.com"
exit 0
EOF
done
chmod +x "$B2/file" "$B2/codesign" "$B2/claude" "$B2/codex"
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
cp "$B2/file" "$B2/claude" "$B2/codex" "$B2B/"
mkcodesign "$B2B/codesign" weird
rm -f "$MARK2"
OUT2B="$(run_preflight "$B2B")"
has "scenario 2b: other codesign failures are NOT VERIFIED" "$(row "$OUT2B" claude)" "NOT VERIFIED (codesign rc=3)"
if [ -e "$MARK2" ]; then bad "scenario 2b: unverified binary was NOT executed"; else ok "scenario 2b: unverified binary was NOT executed"; fi

# Scenarios 2c-2f: the signature verifies, but it is not the pinned vendor signature. Never executed.
for mode in adhoc wrongteam notdev forged; do
  BX="$SANDBOX/b2-$mode"
  mkbin "$BX"
  cp "$B2/file" "$B2/claude" "$B2/codex" "$BX/"
  mkcodesign "$BX/codesign" "$mode"
  rm -f "$MARK2"
  OUTX="$(run_preflight "$BX")"
  eq "scenario 2 ($mode): preflight exits 0" "0" "$?"
  has "scenario 2 ($mode): claude is UNTRUSTED" "$(row "$OUTX" claude)" "UNTRUSTED"
  has "scenario 2 ($mode): codex is UNTRUSTED" "$(row "$OUTX" codex)" "UNTRUSTED"
  has "scenario 2 ($mode): version is skipped" "$(row "$OUTX" claude)" "skipped (unverified)"
  if [ -e "$MARK2" ]; then bad "scenario 2 ($mode): binary was NOT executed"; else ok "scenario 2 ($mode): binary was NOT executed"; fi
  lacks "scenario 2 ($mode): nothing leaked" "$OUTX" "SECRET"
done
has "scenario 2 (adhoc): reported as ad-hoc, not Developer ID" "$(run_preflight "$SANDBOX/b2-adhoc" | grep '^claude')" "ad-hoc"
has "scenario 2 (wrongteam): reported as not the pinned team" "$(run_preflight "$SANDBOX/b2-wrongteam" | grep '^claude')" "not the pinned team"
has "scenario 2 (forged): reported as chain mismatch" "$(run_preflight "$SANDBOX/b2-forged" | grep '^claude')" "certificate chain"

# ---------------------------------------------------------------------------------------------------------------------
# Scenario 3: script launchers (real `file`) are NOT executed; the SIGNATURE cell and a note say so.
B3="$SANDBOX/b3"
mkbin "$B3"
ln -sf "$(command -v file)" "$B3/file"
LOG3="$SANDBOX/log3"
mkcodesign "$B3/codesign" unsigned
for n in claude codex; do
  cat > "$B3/$n" <<EOF
#!/bin/sh
echo "\$0 \$*" >> "$LOG3"
case "\$1" in
  --version) echo "launcher 1.0"; exit 0 ;;
  auth|login) exit 0 ;;
esac
exit 9
EOF
done
chmod +x "$B3/codesign" "$B3/claude" "$B3/codex"
OUT3="$(run_preflight "$B3")"
RC3=$?
eq "scenario 3: preflight exits 0" "0" "$RC3"
has "scenario 3: SIGNATURE cell says launcher only, not executed" "$(row "$OUT3" claude)" "launcher only, not executed (needs human approval)"
has "scenario 3: kind is script" "$(row "$OUT3" claude)" "script"
has "scenario 3: version is skipped" "$(row "$OUT3" claude)" "skipped (unverified)"
has "scenario 3: note says the launcher was NOT executed" "$OUT3" "script launcher and was NOT executed"
if [ -s "$LOG3" ]; then bad "scenario 3: no launcher was executed"; else ok "scenario 3: no launcher was executed"; fi

# Scenario 3b: a symlinked CLI is resolved; the RESOLVED file is what gets verified and then executed.
B3B="$SANDBOX/b3b"
mkbin "$B3B"
cp "$B1/file" "$B3B/file"
CS3B="$SANDBOX/codesign3b.log"
mkcodesign "$B3B/codesign" good "$CS3B"
mkdir -p "$SANDBOX/real3b"
LOG3B="$SANDBOX/log3b"
printf '#!/bin/sh\necho "RESOLVED $0 $*" >> "%s"\nexit 0\n' "$LOG3B" > "$SANDBOX/real3b/claude-real"
chmod +x "$SANDBOX/real3b/claude-real"
ln -s "$SANDBOX/real3b/claude-real" "$B3B/claude"
OUT3B="$(run_preflight "$B3B")"
has "scenario 3b: codesign was asked about the resolved path" "$(cat "$CS3B")" "--verify --strict $SANDBOX/real3b/claude-real"
lacks "scenario 3b: codesign was never asked about the symlink path" "$(cat "$CS3B")" "$B3B/claude"
has "scenario 3b: the resolved binary is what ran (version)" "$(cat "$LOG3B")" "RESOLVED $SANDBOX/real3b/claude-real --version"
has "scenario 3b: the resolved binary is what ran (status)" "$(cat "$LOG3B")" "RESOLVED $SANDBOX/real3b/claude-real auth status"
has "scenario 3b: the resolved path is shown" "$(row "$OUT3B" claude)" "claude-real"

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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
