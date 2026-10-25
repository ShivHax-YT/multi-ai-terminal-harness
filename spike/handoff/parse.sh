#!/usr/bin/env bash
# parse.sh --root <dir> [--] <HANDOFF.md>  ->  JSON on stdout (format: docs/spec/handoff.md)
#
#   {task_id, summary, files_changed:[{path,note}], tests_run, hard_rules:[..], risks, confidence:{level,why}}
#
# Exit codes: 0 valid; 1 invalid handoff or refused input (message on stderr, nothing on stdout); 2 usage error:
#             --root missing, empty, relative, not a directory, or with a '.' or '..' component; a missing jq or perl;
#             3 internal error (temp dir, perl, wc, tr, awk, jq or cat failure, HOME not absolute; the input was not
#             judged).
#             A signal: INT exits 130, HUP 129, QUIT 131, TERM 143; the private temp dir is removed and nothing is
#             printed. A signal during the final write (see "Output") can still cut the JSON short.
#
# SECURITY: the input file is written by a worker AI and is untrusted data. This script never eval's, sources or
# expands file content. Content only ever sits inside quoted "$variables" and reaches jq through --arg or stdin.
# Error messages never echo file content (only section names, line numbers and limits).
#
# The root and the input path are resolved by ONE perl process (PERL_WALK), the only process that receives them:
#   - the root is not resolved by this script (no pwd -P). perl walks it from "/": every component is lstat'ed and
#     refused if it is a symlink or not a directory, entered, and its (dev, ino) compared with the lstat. A symlink
#     anywhere in the root path is therefore refused: the root must be a physical absolute path;
#   - the input must be inside the root: a relative path is relative to the root, an absolute one must start with the
#     root followed by "/". Components ".", ".." and empty ones are refused;
#   - each parent directory below the root is walked the same way, and after every step the physical working
#     directory (Cwd::getcwd) must be the directory the walk expects, outside every provider CLI home;
#   - every directory on the walk and the input must be on the device of the root's final directory;
#   - a root or input that is, or is under, a provider CLI home (under HOME, as typed and as resolved) is refused
#     before any open;
#   - the leaf is lstat'ed (regular file, not a symlink, exactly one link), opened with O_NOFOLLOW, O_NONBLOCK and
#     O_NOCTTY relative to the directory the process stands in, checked again on the open handle, and copied (at most
#     MAX_BYTES+1 bytes). The process holds its working directory, so renaming a parent name cannot redirect the open.
# Every perl call runs with PERL5OPT, PERL5LIB, PERLLIB, PERL5DB and PERL_UNICODE removed from its environment.
# Everything after the copy reads only the private copy.
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

set -f
set -o pipefail
export LC_ALL=C
unset CDPATH

MAX_BYTES=16384
MAX_LINE=2000
MAX_FILES=100
MAX_RULES=20

SECTIONS=("Summary" "Files changed" "Tests run" "Hard rules touched" "Open risks / questions" "Confidence")

die() {
  printf 'handoff: %s\n' "$*" >&2
  exit 1
}

# Internal errors (the parser itself could not do its job) are exit 3, never confused with an invalid handoff.
internal() {
  printf 'handoff: internal error: %s\n' "$*" >&2
  exit 3
}

usage() {
  printf 'usage: parse.sh --root <dir> [--] <HANDOFF.md>  (the root is an absolute physical path; the file must be inside it; use "--" before a name that starts with "-")\n' >&2
  exit 2
}

# Root problems are usage errors (exit 2): the root is not checked by resolution here, the walk refuses symlinks.
root_error() {
  printf 'handoff: %s\n' "$*" >&2
  exit 2
}

# The cleanup trap is installed before anything creates a temp dir. WORK stays empty until mktemp succeeds, so the rm
# is guarded. Each signal exits through the EXIT trap, so the temp dir is removed on INT, HUP, QUIT and TERM too.
WORK=''
cleanup() {
  if [ -n "$WORK" ]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'exit 131' QUIT

# Arguments: parse.sh --root <dir> [--] <file>. A first argument that looks like an option is a usage error unless it
# follows "--". --root is required.
ROOT_ARG=''
HAVE_ROOT=0
while [ $# -gt 0 ]; do
  case $1 in
    --root)
      if [ "$HAVE_ROOT" -ne 0 ] || [ $# -lt 2 ]; then usage; fi
      ROOT_ARG=$2
      HAVE_ROOT=1
      shift 2
      ;;
    --) shift; break ;;
    -?*) usage ;;
    *) break ;;
  esac
done
if [ "$HAVE_ROOT" -eq 0 ]; then
  printf 'handoff: --root <dir> is required (the input must be inside that directory)\n' >&2
  exit 2
fi
if [ $# -ne 1 ]; then usage; fi
for tool in jq perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'handoff: %s is required but was not found\n' "$tool" >&2
    exit 2
  fi
done

# Root checks: not empty or blank, absolute, no '.' or '..' component, and a directory. The root is not resolved here:
# a trailing slash or doubled slashes are harmless (perl drops empty components), a symlink anywhere in it is refused.
root_blank=${ROOT_ARG//[[:space:]]/}
if [ -z "$root_blank" ]; then
  root_error "--root must not be empty"
fi
case $ROOT_ARG in
  /*) ;;
  *) root_error "--root must be an absolute path to a physical directory (no symbolic link in it)" ;;
esac
case "$ROOT_ARG/" in
  */./* | */../*) root_error "--root must not contain a '.' or '..' component" ;;
esac
if [ ! -d "$ROOT_ARG" ]; then
  root_error "--root is not a directory"
fi

# The provider CLI homes are refused under HOME. HOME must be absolute, or the check cannot be made.
case ${HOME:-} in
  /*) ;;
  *) internal "HOME must be an absolute path (the provider CLI home check needs it)" ;;
esac

file=$1

# ---- the one open: root walk, path rules, the input walk and the copy (one perl process) -------------------------------
# Strings are checked before the filesystem is touched. The copy file is created before the process walks, so a
# relative TMPDIR still resolves. Every refusal exits 1 before any read of the input. Program text is a single-quoted
# constant: no single quote inside it (double quotes only), and the input reaches perl only as @ARGV.
PERL_WALK='
use strict;
use warnings;
use Errno qw(ELOOP);
use Fcntl qw(:mode O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK O_NOCTTY);
use Cwd ();
exit 3 unless @ARGV == 5;
my ($root, $file, $dst, $max, $home) = @ARGV;
exit 3 unless defined $max && $max =~ /\A[0-9]+\z/;
exit 3 unless defined $home && $home =~ m{\A/};
sub refuse {
  print STDERR "handoff: $_[0]\n";
  exit 1;
}
# Provider CLI homes, named without the leading dot (the dot is added here, so no literal credential path appears in
# this program text). Each one under HOME, as typed and as resolved, is refused.
my @cli_names = ("claude", "claude.json", "codex", "grok", "kimi-code", "kimi", "gemini");
my @homes = ($home);
my $phome = Cwd::abs_path($home);
push @homes, $phome if defined $phome && $phome ne $home;
my @deny;
for my $h (@homes) {
  (my $b = $h) =~ s{/+\z}{};
  for my $n (@cli_names) {
    push @deny, "$b/.$n";
  }
}
my $cli_msg = "refused: provider CLI directory (the path is, or is under, a provider CLI home; nothing is read)";
sub in_cli {
  my ($p) = @_;
  for my $d (@deny) {
    return 1 if $p eq $d || index($p, "$d/") == 0;
  }
  return 0;
}
my $moved = "input path changed while it was being resolved: a directory on the path was replaced or moved (refused; nothing is copied)";
my $moved_root = "--root changed while it was being resolved (refused; nothing is copied)";
# at_dir: the physical working directory must be the one the walk expects, and not inside a provider CLI home.
sub at_dir {
  my ($want, $msg) = @_;
  my $here = Cwd::getcwd();
  refuse($msg) unless defined $here && $here eq $want;
  refuse($cli_msg) if in_cli($here);
  return;
}
# The root in string form (empty components dropped), and the string checks made before anything is touched.
my @rc = grep { length } split m{/}, $root, -1;
my $nroot = "/" . join("/", @rc);
my $pref = $nroot eq "/" ? "/" : "$nroot/";
refuse($cli_msg) if in_cli($nroot);
my $rel = $file;
if (substr($file, 0, 1) eq "/") {
  refuse("outside root: the input is not inside --root (refused before any open; nothing is copied)")
    unless index($file, $pref) == 0;
  $rel = substr($file, length($pref));
}
refuse("input path must name a file inside --root") if $rel eq "";
for my $c (split m{/}, $rel, -1) {
  refuse("input path must not contain a \x27..\x27 component (give a path inside --root)") if $c eq "..";
  refuse("input path must not contain a \x27.\x27 component") if $c eq ".";
  refuse("input path must not contain an empty component") if $c eq "";
}
my $abs_in = $nroot eq "/" ? "/$rel" : "$nroot/$rel";
refuse($cli_msg) if in_cli($abs_in);
# The copy file is created before the walk (a relative TMPDIR still resolves from the start directory).
my $out;
exit 3 unless sysopen($out, $dst, O_WRONLY | O_CREAT | O_EXCL, 0600);
# Root walk: from "/", every component of the root path, the same rules as the parents below it.
exit 3 unless chdir("/");
at_dir("/", $moved_root);
my $cur = "/";
for my $c (@rc) {
  my @l = lstat($c);
  refuse("cannot read --root: a directory of the root path is missing or cannot be read") unless @l;
  refuse("symlink not allowed: a directory of --root is a symbolic link (refused; nothing is copied)") if S_ISLNK($l[2]);
  refuse("--root is not a directory") unless S_ISDIR($l[2]);
  refuse("cannot read --root: a directory of the root path cannot be entered") unless chdir($c);
  my @s = stat(".");
  exit 3 unless @s;
  refuse($moved_root) unless $s[0] == $l[0] && $s[1] == $l[1];
  $cur = $cur eq "/" ? "/$c" : "$cur/$c";
  at_dir($cur, $moved_root);
}
exit 3 unless $cur eq $nroot;
my @rs = stat(".");
exit 3 unless @rs;
my $root_dev = $rs[0];
# Input walk: the parents below the root, then the leaf.
my @comp = split m{/}, $rel, -1;
my $leaf = pop @comp;
my $dir = $nroot;
for my $c (@comp) {
  my @l = lstat($c);
  refuse("cannot read input file: a parent directory is missing or cannot be read") unless @l;
  refuse("symlink not allowed: a parent directory of the input is a symbolic link (refused before open; nothing is copied)")
    if S_ISLNK($l[2]);
  refuse("cannot read input file: a parent of the input is not a directory") unless S_ISDIR($l[2]);
  refuse("crosses a mount: a parent directory of the input is on another device than --root (refused; nothing is copied)")
    unless $l[0] == $root_dev;
  refuse("cannot read input file: a parent directory cannot be entered") unless chdir($c);
  my @s = stat(".");
  exit 3 unless @s;
  refuse("input path changed while it was being resolved: a parent directory was replaced (refused; nothing is copied)")
    unless $s[0] == $l[0] && $s[1] == $l[1];
  $dir = $dir eq "/" ? "/$c" : "$dir/$c";
  at_dir($dir, $moved);
}
my @ll = lstat($leaf);
refuse("cannot read input file") unless @ll;
refuse("symlink not allowed: the input is a symbolic link (refused before open; nothing is copied)") if S_ISLNK($ll[2]);
refuse("not a regular file: the input must be a regular file (refused before open; nothing is copied)") unless S_ISREG($ll[2]);
refuse("hard link not allowed: the input must have exactly one link (refused before open; nothing is copied)") unless $ll[3] == 1;
refuse("crosses a mount: the input is on another device than --root (refused; nothing is copied)") unless $ll[0] == $root_dev;
refuse("oversize: file is larger than $max bytes") if $ll[7] > $max;
at_dir($dir, $moved);
my $phys_leaf = $dir eq "/" ? "/$leaf" : "$dir/$leaf";
refuse($cli_msg) if in_cli($phys_leaf);
my $in;
unless (sysopen($in, $leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY)) {
  refuse("symlink not allowed: the input is a symbolic link (refused at open; nothing is copied)") if $! == ELOOP;
  refuse("cannot read input file");
}
my @fs = stat($in);
exit 3 unless @fs;
refuse("not a regular file: the opened input is not a regular file (nothing is copied)") unless S_ISREG($fs[2]);
refuse("hard link not allowed: the opened input has more than one link (nothing is copied)") unless $fs[3] == 1;
refuse("input changed between the lstat and the open (refused; nothing is copied)") unless $fs[0] == $ll[0] && $fs[1] == $ll[1];
refuse("oversize: file is larger than $max bytes") if $fs[7] > $max;
at_dir($dir, $moved);
binmode($in);
binmode($out);
my $left = $max + 1;
while ($left > 0) {
  my $want = $left < 65536 ? $left : 65536;
  my $buf = "";
  my $n = sysread($in, $buf, $want);
  exit 3 unless defined $n;
  last if $n == 0;
  my $off = 0;
  while ($off < $n) {
    my $w = syswrite($out, $buf, $n - $off, $off);
    exit 3 unless defined $w;
    $off += $w;
  }
  $left -= $n;
}
exit 3 unless close($out);
close($in);
exit 0;
'

# The temp dir. mktemp runs with INT, HUP, TERM and QUIT ignored (an ignored disposition is inherited by mktemp), so no
# signal can land between the creation of the directory and the assignment of WORK. A signal in that short window is
# dropped; the traps are restored right after.
WORK=''
trap '' INT HUP TERM QUIT
WORK=$(mktemp -d "${TMPDIR:-/tmp}/handoff-parse.XXXXXX")
made=$?
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'exit 131' QUIT
if [ "$made" -ne 0 ]; then
  WORK=''
  internal "cannot create temp dir"
fi
copy="$WORK/copy"
env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB -u PERL_UNICODE perl -e "$PERL_WALK" -- "$ROOT_ARG" "$file" "$copy" "$MAX_BYTES" "$HOME"
rc=$?
case $rc in
  0) ;;
  1) exit 1 ;; # perl has already printed the reason
  *) internal "cannot copy input file" ;;
esac

# ---- whole-file checks (on the private copy only) -----------------------------------------------------------------------
size=$(wc -c <"$copy") || internal "cannot determine file size"
size=${size//[[:space:]]/}
case $size in
  '' | *[!0-9]*) internal "cannot determine file size" ;;
esac
if [ "$size" -gt "$MAX_BYTES" ]; then
  die "oversize: file is larger than $MAX_BYTES bytes"
fi
if [ "$size" -eq 0 ]; then
  die "empty file"
fi
nonul=$(tr -d '\000' <"$copy" | wc -c) || internal "NUL byte check failed"
nonul=${nonul//[[:space:]]/}
case $nonul in
  '' | *[!0-9]*) internal "NUL byte check failed" ;;
esac
if [ "$nonul" != "$size" ]; then
  die "control character: NUL byte in file"
fi

# Strict UTF-8, the noncharacters and the character blocklist (see docs/spec/handoff.md, "Global limits"). Encode's
# "UTF-8" decoder rejects overlong forms, surrogates, code points above U+10FFFF, bytes F5-FF and 5-byte forms.
# FB_QUIET stops at the first bad byte and leaves the unread rest in $rest, so a non-empty rest means invalid UTF-8.
# The noncharacters and the Cf category are refused by explicit regular expressions as well, so the result does not
# depend on the decoder version. The Cf class is \p{Cf} of the perl that runs this check.
PERL_CHECK='
use strict;
use warnings;
use Encode qw(decode FB_QUIET);
binmode(STDIN);
my $bytes = do { local $/; <STDIN> };
exit 3 unless defined $bytes;
my $rest = $bytes;
my $text = decode("UTF-8", $rest, FB_QUIET);
if (length($rest) > 0) {
  print STDERR "handoff: invalid UTF-8 in file\n";
  exit 1;
}
if ($text =~ /[\x{FDD0}-\x{FDEF}\x{FFFE}\x{FFFF}\x{1FFFE}\x{1FFFF}\x{2FFFE}\x{2FFFF}\x{3FFFE}\x{3FFFF}\x{4FFFE}\x{4FFFF}\x{5FFFE}\x{5FFFF}\x{6FFFE}\x{6FFFF}\x{7FFFE}\x{7FFFF}\x{8FFFE}\x{8FFFF}\x{9FFFE}\x{9FFFF}\x{AFFFE}\x{AFFFF}\x{BFFFE}\x{BFFFF}\x{CFFFE}\x{CFFFF}\x{DFFFE}\x{DFFFF}\x{EFFFE}\x{EFFFF}\x{FFFFE}\x{FFFFF}\x{10FFFE}\x{10FFFF}]/) {
  print STDERR "handoff: invalid UTF-8 in file (a noncharacter code point is refused)\n";
  exit 1;
}
if ($text =~ /[\p{Cf}\x{01}-\x{08}\x{0B}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{34F}\x{600}-\x{605}\x{61C}\x{6DD}\x{70F}\x{890}-\x{891}\x{8E2}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180F}\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2060}-\x{206F}\x{2800}\x{3164}\x{FE00}-\x{FE0F}\x{FEFF}\x{FFA0}\x{FFF9}-\x{FFFB}\x{110BD}\x{110CD}\x{13430}-\x{1343F}\x{1BCA0}-\x{1BCA3}\x{1D173}-\x{1D17A}\x{E0000}-\x{E0FFF}]/) {
  print STDERR "handoff: control character in file (only tab, LF and plain text allowed; no CR, ESC, C1, bidi, zero-width or other format characters)\n";
  exit 1;
}
exit 0;
'
env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB -u PERL_UNICODE perl -e "$PERL_CHECK" <"$copy"
rc=$?
case $rc in
  0) ;;
  1) exit 1 ;; # perl has already printed the reason
  *) internal "character check failed" ;;
esac

long_line=$(awk -v max="$MAX_LINE" 'length($0) > max { print NR; exit }' <"$copy") || internal "line length check failed"
if [ -n "$long_line" ]; then
  die "line too long: line $long_line exceeds $MAX_LINE bytes"
fi

# ---- helpers -----------------------------------------------------------------------------------------------------------
NBSP=$'\xC2\xA0'

# nonblank <text>: true if the text has any character other than ASCII whitespace and U+00A0 (no-break space).
nonblank() {
  local t=${1//[[:space:]]/}
  t=${t//"$NBSP"/}
  [ -n "$t" ]
}

# reason_ok <text>: true if the text has a character other than blanks, no-break spaces and the separators - , : ; .
# A reason made only of separators is no reason, on the level line or on any line after it.
reason_ok() {
  local t=${1//[[:space:],:;.-]/}
  t=${t//"$NBSP"/}
  [ -n "$t" ]
}

# Sets RT to $1 without trailing whitespace.
rtrim() {
  RT=${1%"${1##*[![:space:]]}"}
}

# load_lines <text> <section name> <max lines>
# Sets L (array) and LN (count): the lines of <text> without leading/trailing blank lines.
load_lines() {
  local text=$1 name=$2 max=$3 line i first=-1 last=-1
  local -a all
  all=()
  while IFS= read -r line; do
    all+=("$line")
  done <<<"$text"
  for ((i = 0; i < ${#all[@]}; i++)); do
    if nonblank "${all[i]}"; then
      if [ "$first" -lt 0 ]; then first=$i; fi
      last=$i
    fi
  done
  if [ "$first" -lt 0 ]; then
    die "empty section: $name"
  fi
  LN=$((last - first + 1))
  if [ "$LN" -gt "$max" ]; then
    die "too many lines in section: $name has $LN lines (max $max)"
  fi
  L=("${all[@]:first:LN}")
}

# join_lines: joins L with newlines into J.
join_lines() {
  local i
  J=''
  for ((i = 0; i < LN; i++)); do
    if [ "$i" -eq 0 ]; then
      J=${L[i]}
    else
      J+=$'\n'"${L[i]}"
    fi
  done
}

# is_none <line>: true if the line is the single word "none" in any case.
is_none() {
  rtrim "$1"
  case $RT in
    [Nn][Oo][Nn][Ee]) return 0 ;;
    *) return 1 ;;
  esac
}

store_section() { # index text
  case $1 in
    0) S0=$2 ;;
    1) S1=$2 ;;
    2) S2=$2 ;;
    3) S3=$2 ;;
    4) S4=$2 ;;
    5) S5=$2 ;;
  esac
}

# ---- pass 1: structure (title, headings, order, fences) ------------------------------------------------------------
TITLE_RE='^# HANDOFF (T-[0-9]{3,6})$'
FENCE='```'
S0='' S1='' S2='' S3='' S4='' S5=''
task_id=''
lineno=0
cur_idx=-1 # -1 = between title and first section
last_idx=-1
seen=','
fence=0
cur=''

while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))

  if [ "$lineno" -eq 1 ]; then
    rtrim "$line"
    if [[ $RT =~ $TITLE_RE ]]; then
      task_id=${BASH_REMATCH[1]}
    else
      die "bad title: line 1 must be '# HANDOFF T-NNN' (3 to 6 digits)"
    fi
    continue
  fi

  if [[ $line == "$FENCE"* ]]; then
    if [ "$cur_idx" -lt 0 ]; then
      die "unexpected content before first section (line $lineno)"
    fi
    fence=$((1 - fence))
    cur+="$line"$'\n'
    continue
  fi

  if [ "$fence" -eq 0 ]; then
    if [[ $line == '## '* ]]; then
      name=${line#\#\# }
      rtrim "$name"
      name=$RT
      idx=-1
      case $name in
        "Summary") idx=0 ;;
        "Files changed") idx=1 ;;
        "Tests run") idx=2 ;;
        "Hard rules touched") idx=3 ;;
        "Open risks / questions") idx=4 ;;
        "Confidence") idx=5 ;;
      esac
      if [ "$idx" -lt 0 ]; then
        die "unknown section heading at line $lineno"
      fi
      case $seen in
        *",$idx,"*) die "duplicate section: ${SECTIONS[idx]} (line $lineno)" ;;
      esac
      if [ "$idx" -lt "$last_idx" ]; then
        die "section out of order: ${SECTIONS[idx]} (line $lineno) comes after ${SECTIONS[last_idx]}"
      fi
      if [ "$cur_idx" -ge 0 ]; then
        store_section "$cur_idx" "$cur"
      fi
      seen+="$idx,"
      last_idx=$idx
      cur_idx=$idx
      cur=''
      continue
    fi
    if [[ $line == '# '* ]]; then
      die "unexpected top-level heading at line $lineno"
    fi
  fi

  if [ "$cur_idx" -lt 0 ]; then
    if nonblank "$line"; then
      die "unexpected content before first section (line $lineno)"
    fi
    continue
  fi
  cur+="$line"$'\n'
done <"$copy"

if [ "$fence" -ne 0 ]; then
  die "unterminated code fence at end of file"
fi
if [ "$cur_idx" -ge 0 ]; then
  store_section "$cur_idx" "$cur"
fi

i=0
while [ "$i" -lt "${#SECTIONS[@]}" ]; do
  case $seen in
    *",$i,"*) ;;
    *) die "missing section: ${SECTIONS[i]}" ;;
  esac
  i=$((i + 1))
done

# ---- pass 2: per-section content -----------------------------------------------------------------------------------

# Summary
load_lines "$S0" "Summary" 5
join_lines
summary=$J

# Files changed (blank lines between bullets are allowed; only items are counted)
FILE_RE='^([]A-Za-z0-9_./@+=,()[-]+)( - (.*))?$'
load_lines "$S1" "Files changed" 100000
files_tsv=''
if [ "$LN" -eq 1 ] && is_none "${L[0]}"; then
  files_json='[]'
else
  items=0
  for ((i = 0; i < LN; i++)); do
    line=${L[i]}
    if ! nonblank "$line"; then
      continue
    fi
    items=$((items + 1))
    if [ "$items" -gt "$MAX_FILES" ]; then
      die "too many lines in section: Files changed has more than $MAX_FILES entries"
    fi
    if [[ $line != '- '* ]]; then
      die "bad files_changed entry: item $items must start with '- '"
    fi
    entry=${line#- }
    if ! [[ $entry =~ $FILE_RE ]]; then
      die "bad files_changed entry: item $items must be '- <path> - <note>' with a plain relative path"
    fi
    path=${BASH_REMATCH[1]}
    note=${BASH_REMATCH[3]}
    if [ "${#path}" -gt 256 ]; then
      die "bad files_changed entry: item $items path longer than 256 bytes"
    fi
    case "/$path/" in
      /-* | //* | */../*) die "bad files_changed entry: item $items path must be relative (no leading '/'), must not start with '-', and contain no '..' component" ;;
    esac
    files_tsv+="$path"$'\t'"$note"$'\n'
  done
  files_json=$(printf '%s' "$files_tsv" | jq -Rn '[inputs | index("\t") as $i | {path: .[:$i], note: .[$i+1:]}]') ||
    internal "building files_changed failed"
fi

# Tests run
load_lines "$S2" "Tests run" 60
join_lines
tests_run=$J

# Hard rules touched (blank lines between bullets are allowed; only items are counted)
load_lines "$S3" "Hard rules touched" 100000
if [ "$LN" -eq 1 ] && is_none "${L[0]}"; then
  rules_json='[]'
else
  rules_txt=''
  items=0
  for ((i = 0; i < LN; i++)); do
    line=${L[i]}
    if ! nonblank "$line"; then
      continue
    fi
    items=$((items + 1))
    if [ "$items" -gt "$MAX_RULES" ]; then
      die "too many lines in section: Hard rules touched has more than $MAX_RULES entries"
    fi
    if [[ $line != '- '* ]]; then
      die "bad hard_rules entry: item $items must start with '- '"
    fi
    entry=${line#- }
    if ! nonblank "$entry"; then
      die "bad hard_rules entry: item $items is empty"
    fi
    rules_txt+="$entry"$'\n'
  done
  rules_json=$(printf '%s' "$rules_txt" | jq -Rn '[inputs]') ||
    internal "building hard_rules failed"
fi

# Open risks / questions
load_lines "$S4" "Open risks / questions" 60
join_lines
risks=$J

# Confidence: the level is case-insensitive and is output in lowercase. Blanks before the level are ignored (ASCII
# space and tab only).
CONF_RE='^([A-Za-z]+)([[:space:],:;.]|$)(.*)$'
load_lines "$S5" "Confidence" 10
first_line=${L[0]}
lead=${first_line%%[![:space:]]*}
first_line=${first_line#"$lead"}
if ! [[ $first_line =~ $CONF_RE ]]; then
  die "bad confidence level: the Confidence section must start with low, medium or high"
fi
word=${BASH_REMATCH[1]}
rest=${BASH_REMATCH[3]}
case $word in
  [Ll][Oo][Ww]) level=low ;;
  [Mm][Ee][Dd][Ii][Uu][Mm]) level=medium ;;
  [Hh][Ii][Gg][Hh]) level=high ;;
  *) die "bad confidence level: the Confidence section must start with low, medium or high" ;;
esac
prefix=${rest%%[![:space:],:;.-]*}
rest=${rest#"$prefix"}
L[0]=$rest
join_lines
nl=$'\n'
why=${J#"${J%%[!"$nl"]*}"} # drop leading newlines (level alone on the first line)
if ! reason_ok "$why"; then
  die "confidence missing reason: give a reason after the level (separators alone are not a reason)"
fi

# ---- output (only reached when everything above passed) --------------------------------------------------------------
# The JSON goes to a temp file first and is written to stdout last, with one cat of that prepared file. An interrupt
# before that point (which runs the trap) leaves stdout empty. A signal during the cat can still cut the output short.
jq -a -n \
  --arg task_id "$task_id" \
  --arg summary "$summary" \
  --argjson files "$files_json" \
  --arg tests_run "$tests_run" \
  --argjson hard_rules "$rules_json" \
  --arg risks "$risks" \
  --arg level "$level" \
  --arg why "$why" \
  '{task_id: $task_id, summary: $summary, files_changed: $files, tests_run: $tests_run,
    hard_rules: $hard_rules, risks: $risks, confidence: {level: $level, why: $why}}' >"$WORK/json" ||
  internal "building output failed"
cat -- "$WORK/json" || internal "writing output failed"
