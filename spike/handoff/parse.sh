#!/bin/bash -p
# parse.sh --root <worktree>  ->  JSON on stdout (format: docs/spec/handoff.md). Reads exactly <root>/HANDOFF.md.
#
#   {task_id, summary, files_changed:[{path,note}], tests_run, hard_rules:[..], risks, confidence:{level,why}}
#
# Exit codes: 0 valid; 1 invalid handoff or refused input (message on stderr, nothing on stdout);
#             2 usage error (arguments, or --root empty, relative, too long, with a '.' or '..' component, not a
#               directory; /usr/bin/perl missing);
#             3 internal error (the input was not judged: do not treat it as an invalid handoff). This includes a
#               missing, empty or malformed compliance/denylist.txt, and a wrapper started through a symbolic link.
#
# SHEBANG: "#!/bin/bash -p" (privileged mode: bash does not read BASH_ENV or ENV and does not import exported functions;
# -p is accepted by bash 3.2 on macOS and by bash 4/5). It only applies when the script is executed directly. If a caller
# runs "bash parse.sh" the shebang is not used and bash has already read BASH_ENV by then; the scheduler must execute the
# script directly. The env -i exec below gives perl a clean environment in any case.
#
# STRUCTURE (round 7, round 8): this script only checks its arguments, finds the denylist file and then execs ONE perl
# process (/usr/bin/perl -f) with a scrubbed environment. That process does everything: it walks the root from "/", opens <root>/HANDOFF.md once, reads it
# into memory, checks it, and prints the JSON once at the end. No temp file, no second process, no here-string, nothing
# reopened by path. jq and awk are not used (the old design copied the file and re-read the copy).
#
# SECURITY: the input file is written by a worker AI and is untrusted data. Content never reaches a shell, never
# becomes perl code, and is never expanded or evaluated. The perl program is a single-quoted constant. Messages never
# echo file content.
#
# THREAT MODEL (honest, see docs/spec/handoff.md): the guarantees hold for filesystem state that does not change while
# the parse runs. A concurrent process running as the same user can race (or ptrace) the parser; that is out of scope
# here, and the caller must make sure ALL of the worker's processes have exited (descendants that called setsid
# included) and been reaped before it parses.
#
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

set -f
unset CDPATH BASH_ENV ENV
shopt -s execfail

ENV_BIN=/usr/bin/env
PERL_BIN=/usr/bin/perl

usage() {
  printf 'usage: parse.sh --root <dir>   (reads <dir>/HANDOFF.md only; <dir> is an absolute physical path)\n' >&2
  exit 2
}

# Arguments: exactly "--root <dir>". Anything else (a second positional argument, a second --root, an unknown option,
# a missing value) is a usage error.
if [ $# -eq 0 ]; then
  printf 'handoff: --root <dir> is required\n' >&2
  usage
fi
if [ $# -ne 2 ] || [ "$1" != "--root" ]; then
  usage
fi
ROOT_ARG=$2

if [ ! -x "$PERL_BIN" ]; then
  printf 'handoff: perl is required but %s was not found\n' "$PERL_BIN" >&2
  exit 2
fi

# The denylist: compliance/denylist.txt, two directories above this script's PHYSICAL directory. cd -P (no subshell, so
# the wrapper still forks nothing) gives the physical directory. A symbolic link to this script is refused: the layout is
# found from the real location only. The path is passed to perl as @ARGV data; perl opens it with O_NOFOLLOW and fails
# closed (exit 3) if it is missing, empty or malformed.
if [ -L "$0" ]; then
  printf 'handoff: internal error: parse.sh must be run by its physical path, not through a symbolic link\n' >&2
  exit 3
fi
case $0 in
  */*) SELF_DIR=${0%/*} ;;
  *) SELF_DIR=. ;;
esac
if ! cd -P "$SELF_DIR"; then
  printf 'handoff: internal error: cannot locate the compliance denylist\n' >&2
  exit 3
fi
DENYLIST=${PWD%/*/*}/compliance/denylist.txt

# The one perl program. No single quote inside (double quotes, q~~ and \x27 only). The root, HOME and the denylist path
# reach it only as @ARGV data. HOME is data for the CLI home identity check and is never used as a path to read.
PERL_PROG='
BEGIN {
  $SIG{__DIE__} = sub { die @_ if $^S; print STDERR "handoff: internal error: unexpected failure in the parser\n"; exit 3; };
  $SIG{__WARN__} = sub { };
  @INC = grep { !ref($_) && m{\A/} } @INC;
}
use strict;
use warnings;
use Errno qw(ELOOP EINTR);
use Fcntl qw(:mode O_RDONLY O_NOFOLLOW O_NONBLOCK O_NOCTTY);
use Cwd ();
use Encode qw(decode FB_QUIET);
use JSON::PP ();
use POSIX ();

my $MAX_BYTES = 16384;
my $MAX_LINE = 2000;
my $MAX_FILES = 100;
my $MAX_RULES = 20;
my $NAME = "HANDOFF.md";

sub refuse { print STDERR "handoff: $_[0]\n"; exit 1; }
sub usage_err { print STDERR "handoff: $_[0]\n"; exit 2; }
sub internal { print STDERR "handoff: internal error: $_[0]\n"; exit 3; }

internal("wrong number of arguments") unless @ARGV == 3;
my ($root, $home_arg, $deny_file) = @ARGV;

# ---- the root string: usage errors, before the filesystem is touched ------------------------------------------------
usage_err("--root must not be empty") if $root =~ /\A[ \t\n\r\f\x0B]*\z/;
usage_err("--root must be an absolute path to a physical directory (no symbolic link in it)") unless substr($root, 0, 1) eq "/";
my $path_max = POSIX::PATH_MAX();
usage_err("--root is longer than PATH_MAX ($path_max bytes): refused, nothing is read") if length($root) >= $path_max;
my @rc = grep { length } split m{/}, $root, -1;
for my $c (@rc) {
  usage_err("--root must not contain a \x27.\x27 or \x27..\x27 component") if $c eq "." || $c eq "..";
}

# ---- the denylist file (hard rule 4) ---------------------------------------------------------------------------------
# compliance/denylist.txt is the single source of truth for the provider CLI home names: one entry per line, relative to
# the account home, "#" starts a comment, blank lines are ignored. Every entry must match ^\.[A-Za-z0-9._-]+$ and must not
# be only dots. The file is opened with O_NOFOLLOW and must be a regular file of 1 to 65536 bytes. Anything else (missing,
# a symbolic link, empty, no entry, a malformed entry) is an internal error: without the list the CLI home check cannot be
# made, so nothing is read. Nothing of the file is echoed.
sub load_denylist {
  my ($path) = @_;
  my $bad = "the compliance denylist (compliance/denylist.txt) is missing, empty or malformed: the provider CLI home check cannot be made (nothing is read)";
  internal($bad) unless defined $path && substr($path, 0, 1) eq "/";
  my $fh;
  internal($bad) unless sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
  my @st = stat($fh);
  internal($bad) unless @st && S_ISREG($st[2]) && $st[7] > 0 && $st[7] <= 65536;
  binmode($fh);
  my $data = "";
  my $left = 65537;
  while ($left > 0) {
    my $buf = "";
    my $n = sysread($fh, $buf, $left);
    if (!defined $n) {
      next if $! == EINTR;
      internal($bad);
    }
    last if $n == 0;
    $data .= $buf;
    $left -= $n;
  }
  close($fh);
  internal($bad) if length($data) > 65536;
  my @entries;
  for my $line (split /\n/, $data, -1) {
    $line =~ s/#.*\z//s;
    $line =~ s/\A[ \t\r]+//;
    $line =~ s/[ \t\r]+\z//;
    next if $line eq "";
    internal($bad) unless $line =~ /\A\.[A-Za-z0-9._-]+\z/ && $line !~ /\A\.+\z/;
    push @entries, $line;
  }
  internal($bad) unless @entries;
  return @entries;
}
my @deny_names = load_denylist($deny_file);

# ---- provider CLI homes, by identity (hard rule 4) -------------------------------------------------------------------
# The homes are computed from the account database and from HOME (as data), and every denylist entry under each home is
# stat-ed. Every directory of the walk, and the leaf, is then compared by (device, inode), so a case change, a bind mount
# of the home itself or a HOME trick does not help.
my @homes;
my $pw_home = (getpwuid($<))[7];
push @homes, $pw_home if defined $pw_home && $pw_home =~ m{\A/};
push @homes, $home_arg if defined $home_arg && $home_arg =~ m{\A/};
internal("no home directory is known, so the provider CLI home check cannot be made") unless @homes;
my %deny;
for my $h (@homes) {
  (my $b = $h) =~ s{/+\z}{};
  for my $n (@deny_names) {
    my @s = stat("$b/$n");
    $deny{"$s[0]:$s[1]"} = 1 if @s;
  }
}
my $cli_msg = "refused: provider CLI directory (the root is, or is inside, a provider CLI home; nothing is read)";
my $moved_root = "--root changed while it was being resolved (refused; nothing is read)";
my $moved = "input path changed while it was being resolved: the working directory is not the root (refused; nothing is read)";
sub denied { my @s = @_; return (@s >= 2 && $deny{"$s[0]:$s[1]"}) ? 1 : 0; }
# at_dir: the identity of the working directory must not be a CLI home, and its physical path must be the expected one.
sub at_dir {
  my ($want, $msg) = @_;
  my @s = stat(".");
  internal("cannot stat the working directory") unless @s;
  refuse($cli_msg) if denied(@s);
  my $here = Cwd::getcwd();
  refuse($msg) unless defined $here && $here eq $want;
  return;
}

# ---- the root walk: from "/", every component ------------------------------------------------------------------------
internal("cannot enter /") unless chdir("/");
at_dir("/", $moved_root);
my $cur = "/";
for my $c (@rc) {
  my @l = lstat($c);
  usage_err("--root is not a directory, or a directory of the root path does not exist") unless @l;
  refuse("symlink not allowed: a directory of --root is a symbolic link (refused; nothing is read)") if S_ISLNK($l[2]);
  usage_err("--root is not a directory") unless S_ISDIR($l[2]);
  refuse($cli_msg) if denied(@l);    # BEFORE the chdir: a CLI home is never entered (the check after the chdir stays)
  refuse("cannot read --root: a directory of the root path cannot be entered") unless chdir($c);
  my @s = stat(".");
  internal("cannot stat the working directory") unless @s;
  refuse($moved_root) unless $s[0] == $l[0] && $s[1] == $l[1];
  $cur = $cur eq "/" ? "/$c" : "$cur/$c";
  at_dir($cur, $moved_root);
}
internal("root walk ended in the wrong place") unless $cur eq "/" . join("/", @rc);
my @rs = stat(".");
internal("cannot stat the root") unless @rs;
my $root_dev = $rs[0];

# ---- the one leaf: <root>/HANDOFF.md ---------------------------------------------------------------------------------
my @ll = lstat($NAME);
refuse("cannot read $NAME: it is missing from --root or cannot be read") unless @ll;
refuse("symlink not allowed: $NAME is a symbolic link (refused before open; nothing is read)") if S_ISLNK($ll[2]);
refuse("not a regular file: $NAME must be a regular file (refused before open; nothing is read)") unless S_ISREG($ll[2]);
refuse("hard link not allowed: $NAME must have exactly one link (refused before open; nothing is read)") unless $ll[3] == 1;
refuse("crosses a mount: $NAME is on another device than --root (refused; nothing is read)") unless $ll[0] == $root_dev;
refuse($cli_msg) if denied(@ll);
refuse("oversize: file is larger than $MAX_BYTES bytes") if $ll[7] > $MAX_BYTES;
at_dir($cur, $moved);
my $in;
unless (sysopen($in, $NAME, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY)) {
  refuse("symlink not allowed: $NAME is a symbolic link (refused at open; nothing is read)") if $! == ELOOP;
  refuse("cannot read $NAME: it cannot be opened");
}
my @fs = stat($in);
internal("cannot stat the open file") unless @fs;
refuse("not a regular file: the opened $NAME is not a regular file (nothing is read)") unless S_ISREG($fs[2]);
refuse("hard link not allowed: the opened $NAME has more than one link (nothing is read)") unless $fs[3] == 1;
refuse("input changed between the lstat and the open (refused; nothing is read)") unless $fs[0] == $ll[0] && $fs[1] == $ll[1];
refuse("oversize: file is larger than $MAX_BYTES bytes") if $fs[7] > $MAX_BYTES;
at_dir($cur, $moved);
binmode($in);
my $bytes = "";
my $left = $MAX_BYTES + 1;
while ($left > 0) {
  my $buf = "";
  my $n = sysread($in, $buf, $left < 65536 ? $left : 65536);
  if (!defined $n) {
    next if $! == EINTR;
    internal("read failed");
  }
  last if $n == 0;
  $bytes .= $buf;
  $left -= $n;
}
# A consistency check on the open handle (not a defence against a concurrent writer; see the spec).
my @fs2 = stat($in);
internal("cannot stat the open file") unless @fs2;
refuse("input changed while it was being read (refused; nothing is printed)")
  unless $fs2[0] == $fs[0] && $fs2[1] == $fs[1] && $fs2[3] == 1 && $fs2[7] == length($bytes);
close($in);

# ---- whole-file checks (all in memory) -------------------------------------------------------------------------------
refuse("oversize: file is larger than $MAX_BYTES bytes") if length($bytes) > $MAX_BYTES;
refuse("empty file") if length($bytes) == 0;
refuse("control character: NUL byte in file") if index($bytes, "\x00") >= 0;

# Strict UTF-8 (Encode "UTF-8" rejects overlong forms, surrogates, code points above U+10FFFF, bytes F5-FF and 5-byte
# forms). FB_QUIET stops at the first bad byte and leaves the unread rest, so a non-empty rest means invalid UTF-8. The
# noncharacters and the Cf category are refused by explicit expressions as well, so the result does not depend on the
# decoder version.
my $rest = $bytes;
my $text = decode("UTF-8", $rest, FB_QUIET);
refuse("invalid UTF-8 in file") if length($rest) > 0;
if ($text =~ /[\x{FDD0}-\x{FDEF}\x{FFFE}\x{FFFF}\x{1FFFE}\x{1FFFF}\x{2FFFE}\x{2FFFF}\x{3FFFE}\x{3FFFF}\x{4FFFE}\x{4FFFF}\x{5FFFE}\x{5FFFF}\x{6FFFE}\x{6FFFF}\x{7FFFE}\x{7FFFF}\x{8FFFE}\x{8FFFF}\x{9FFFE}\x{9FFFF}\x{AFFFE}\x{AFFFF}\x{BFFFE}\x{BFFFF}\x{CFFFE}\x{CFFFF}\x{DFFFE}\x{DFFFF}\x{EFFFE}\x{EFFFF}\x{FFFFE}\x{FFFFF}\x{10FFFE}\x{10FFFF}]/) {
  refuse("invalid UTF-8 in file (a noncharacter code point is refused)");
}
if ($text =~ /[\p{Cf}\x{01}-\x{08}\x{0B}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{34F}\x{600}-\x{605}\x{61C}\x{6DD}\x{70F}\x{890}-\x{891}\x{8E2}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180F}\x{200B}-\x{200F}\x{2028}-\x{202E}\x{2060}-\x{206F}\x{2800}\x{3164}\x{FE00}-\x{FE0F}\x{FEFF}\x{FFA0}\x{FFF9}-\x{FFFB}\x{110BD}\x{110CD}\x{13430}-\x{1343F}\x{1BCA0}-\x{1BCA3}\x{1D173}-\x{1D17A}\x{E0000}-\x{E0FFF}]/) {
  refuse("control character in file (only tab, LF and plain text allowed; no CR, ESC, C1, bidi, zero-width or other format characters)");
}

# Lines are split on LF on the validated bytes (a final line without LF counts). Byte limits are bytes.
my @lines = split /\n/, $bytes, -1;
pop @lines if @lines && $lines[-1] eq "";
for my $i (0 .. $#lines) {
  refuse("line too long: line " . ($i + 1) . " exceeds $MAX_LINE bytes") if length($lines[$i]) > $MAX_LINE;
}

# ---- helpers (byte strings; whitespace is ASCII space, tab, VT, FF, CR, LF; U+00A0 counts as blank) --------------------
sub rtrim { my $t = $_[0]; $t =~ s/[ \t\n\r\f\x0B]+\z//; return $t; }
sub nonblank { my $t = $_[0]; $t =~ s/[ \t\n\r\f\x0B]//g; $t =~ s/\xC2\xA0//g; return length($t) > 0; }
sub reason_ok { my $t = $_[0]; $t =~ s/[ \t\n\r\f\x0B,:;.-]//g; $t =~ s/\xC2\xA0//g; return length($t) > 0; }
# load_lines(text, name, max): the lines of text without leading and trailing blank lines.
sub load_lines {
  my ($t, $name, $max) = @_;
  my @all = split /\n/, $t, -1;
  pop @all if @all && $all[-1] eq "";
  my ($first, $last) = (-1, -1);
  for my $i (0 .. $#all) {
    if (nonblank($all[$i])) {
      $first = $i if $first < 0;
      $last = $i;
    }
  }
  refuse("empty section: $name") if $first < 0;
  my $n = $last - $first + 1;
  refuse("too many lines in section: $name has $n lines (max $max)") if $n > $max;
  return @all[$first .. $last];
}
sub is_none { return rtrim($_[0]) =~ /\A[Nn][Oo][Nn][Ee]\z/ ? 1 : 0; }

# ---- pass 1: structure (title, headings, order, fences) --------------------------------------------------------------
my @SEC = ("Summary", "Files changed", "Tests run", "Hard rules touched", "Open risks / questions", "Confidence");
my $FENCE = "\x60\x60\x60";
my @S = ("", "", "", "", "", "");
my %seen;
my $task_id = "";
my ($lineno, $cur_idx, $last_idx, $fence, $acc) = (0, -1, -1, 0, "");
for my $line (@lines) {
  $lineno++;
  if ($lineno == 1) {
    my $t = rtrim($line);
    if ($t =~ /\A# HANDOFF (T-[0-9]{3,6})\z/) {
      $task_id = $1;
    } else {
      refuse("bad title: line 1 must be \x27# HANDOFF T-NNN\x27 (3 to 6 digits)");
    }
    next;
  }
  if (index($line, $FENCE) == 0) {
    refuse("unexpected content before first section (line $lineno)") if $cur_idx < 0;
    $fence = 1 - $fence;
    $acc .= "$line\n";
    next;
  }
  if ($fence == 0) {
    if (index($line, "## ") == 0) {
      my $name = rtrim(substr($line, 3));
      my $idx = -1;
      for my $k (0 .. 5) { $idx = $k if $SEC[$k] eq $name; }
      refuse("unknown section heading at line $lineno") if $idx < 0;
      refuse("duplicate section: $SEC[$idx] (line $lineno)") if $seen{$idx};
      refuse("section out of order: $SEC[$idx] (line $lineno) comes after $SEC[$last_idx]") if $idx < $last_idx;
      $S[$cur_idx] = $acc if $cur_idx >= 0;
      $seen{$idx} = 1;
      $last_idx = $idx;
      $cur_idx = $idx;
      $acc = "";
      next;
    }
    refuse("unexpected top-level heading at line $lineno") if index($line, "# ") == 0;
  }
  if ($cur_idx < 0) {
    refuse("unexpected content before first section (line $lineno)") if nonblank($line);
    next;
  }
  $acc .= "$line\n";
}
refuse("unterminated code fence at end of file") if $fence != 0;
$S[$cur_idx] = $acc if $cur_idx >= 0;
for my $k (0 .. 5) {
  refuse("missing section: $SEC[$k]") unless $seen{$k};
}

# ---- pass 2: per-section content -------------------------------------------------------------------------------------
my @L = load_lines($S[0], "Summary", 5);
my $summary = join("\n", @L);

@L = load_lines($S[1], "Files changed", 100000);
my @files;
unless (@L == 1 && is_none($L[0])) {
  my $items = 0;
  for my $line (@L) {
    next unless nonblank($line);
    $items++;
    refuse("too many lines in section: Files changed has more than $MAX_FILES entries") if $items > $MAX_FILES;
    refuse("bad files_changed entry: item $items must start with \x27- \x27") unless substr($line, 0, 2) eq "- ";
    my $entry = substr($line, 2);
    unless ($entry =~ /\A([\]A-Za-z0-9_.\/@+=,()\[-]+)(?: - (.*))?\z/) {
      refuse("bad files_changed entry: item $items must be \x27- <path> - <note>\x27 with a plain relative path");
    }
    my ($path, $note) = ($1, defined $2 ? $2 : "");
    refuse("bad files_changed entry: item $items path longer than 256 bytes") if length($path) > 256;
    if (substr($path, 0, 1) eq "-" || substr($path, 0, 1) eq "/" || ("/$path/" =~ m{/\.\./})) {
      refuse("bad files_changed entry: item $items path must be relative (no leading \x27/\x27), must not start with \x27-\x27, and contain no \x27..\x27 component");
    }
    push @files, [$path, $note];
  }
}

@L = load_lines($S[2], "Tests run", 60);
my $tests_run = join("\n", @L);

@L = load_lines($S[3], "Hard rules touched", 100000);
my @rules;
unless (@L == 1 && is_none($L[0])) {
  my $items = 0;
  for my $line (@L) {
    next unless nonblank($line);
    $items++;
    refuse("too many lines in section: Hard rules touched has more than $MAX_RULES entries") if $items > $MAX_RULES;
    refuse("bad hard_rules entry: item $items must start with \x27- \x27") unless substr($line, 0, 2) eq "- ";
    my $entry = substr($line, 2);
    refuse("bad hard_rules entry: item $items is empty") unless nonblank($entry);
    push @rules, $entry;
  }
}

@L = load_lines($S[4], "Open risks / questions", 60);
my $risks = join("\n", @L);

# Confidence: the level is case-insensitive and is output in lowercase. Blanks before the level are ignored.
@L = load_lines($S[5], "Confidence", 10);
my $first_line = $L[0];
$first_line =~ s/\A[ \t\n\r\f\x0B]+//;
my $bad_level = "bad confidence level: the Confidence section must start with low, medium or high";
refuse($bad_level) unless $first_line =~ /\A([A-Za-z]+)(?:[ \t\n\r\f\x0B,:;.]|\z)(.*)\z/;
my ($word, $after) = (lc($1), $2);
refuse($bad_level) unless $word eq "low" || $word eq "medium" || $word eq "high";
$after =~ s/\A[ \t\n\r\f\x0B,:;.-]+//;
$L[0] = $after;
my $why = join("\n", @L);
$why =~ s/\A\n+//;
refuse("confidence missing reason: give a reason after the level (separators alone are not a reason)") unless reason_ok($why);

# ---- output: built in memory, written once, only now ------------------------------------------------------------------
my $json = JSON::PP->new->ascii->allow_nonref;
sub js {
  my $s = "" . $_[0];
  internal("output text is not valid UTF-8") unless utf8::decode($s);
  return $json->encode($s);
}
my $out = q~{"task_id":~ . js($task_id)
  . q~,"summary":~ . js($summary)
  . q~,"files_changed":[~ . join(",", map { q~{"path":~ . js($_->[0]) . q~,"note":~ . js($_->[1]) . q~}~ } @files) . q~]~
  . q~,"tests_run":~ . js($tests_run)
  . q~,"hard_rules":[~ . join(",", map { js($_) } @rules) . q~]~
  . q~,"risks":~ . js($risks)
  . q~,"confidence":{"level":~ . js($word) . q~,"why":~ . js($why) . q~}}~ . "\n";
binmode(STDOUT);
my $off = 0;
while ($off < length($out)) {
  my $w = syswrite(STDOUT, $out, length($out) - $off, $off);
  if (!defined $w) {
    next if $! == EINTR;
    internal("writing output failed");
  }
  $off += $w;
}
exit 0;
'

# scrubbed environment: PERL5LIB, PERL5OPT, PERLLIB, PERL5DB, PERL_UNICODE, PERL_USE_UNSAFE_INC and every other variable
# are gone (env -i), PATH is fixed, and LC_ALL=C. HOME and the denylist path are passed only as data in @ARGV. perl -f
# skips sitecustomize.pl (a no-op on a perl built without it; accepted by perl 5.8 and later, so by the macOS perl).
exec "$ENV_BIN" -i PATH=/usr/bin:/bin LC_ALL=C "$PERL_BIN" -f -e "$PERL_PROG" -- "$ROOT_ARG" "${HOME-}" "$DENYLIST"
printf 'handoff: internal error: cannot run %s\n' "$PERL_BIN" >&2
exit 3
