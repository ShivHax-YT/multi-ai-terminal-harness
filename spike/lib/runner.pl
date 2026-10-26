#!/usr/bin/perl
# FROZEN (ShivHax-YT, 2026-10-26): Phase 0 spike helper. No new hardening rounds; Phase 1 T-115 (binary verifier) and T-119 (runner) replace it in Rust.
#
# spike/lib/runner.pl: the ONE helper behind spike/lib/common.sh (round 7). Every security decision of the spike
# scaffold is made here, in one process per call, by file identity instead of path strings:
#
#   - it is started only as   /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_*=... /usr/bin/perl runner.pl <cmd> ...
#     (constant absolute paths; the helper's own arguments come after the constant interpreter path, so no argument can
#     be read as VAR=value by env; no PATH lookup finds this interpreter; the caller's PERL* variables are dropped)
#   - the caller's PATH, HOME, TMPDIR, LANG, TERM, USER, LOGNAME and SPIKE_LIVE arrive as SPIKE_IN_<NAME> and are copied
#     into %IN at start; the environment is then never used again, and a child gets a closed set built here
#   - a command is resolved ONCE (bare name: caller PATH searched here; absolute: as given), by walking components with
#     lstat/readlink (physical, at most 40 links). A control character (newline included) in the input, in a link
#     target or in the result refuses the path, so a caller's $(...) can never strip or inject bytes
#   - CLI-home membership compares (device, inode) of every directory on the path and of the file against the CLI homes of
#     BOTH the password-database home and an absolute HOME; hard links, case-insensitive spellings and firmlinks therefore
#     cannot hide a home. The list of CLI home names is NOT in this file: it is read at run time from the lead-owned
#     compliance/denylist.txt (located from this file's own physical path), and every operation fails closed (rc 121 and one
#     fixed message) if that file is missing, empty or malformed (round 8)
#   - a file is opened ONCE (O_RDONLY|O_NOFOLLOW|O_NOCTTY|O_NONBLOCK), checked with fstat, read from that descriptor
#   - registration VERIFIES IN PLACE: it resolves the installed CLI to its real physical path, runs the fixed codesign on THAT
#     file, records its sha256 in the registry of a private 0700 directory this helper creates (no copy of the binary is ever
#     made), and a run re-hashes that file and then executes that same real path
#   - a run puts the helper at the head of a NEW process group and forks the command into that group; the helper watches
#     the timeout, its caller (parent pid changes when the caller dies) and TERM/INT/HUP, and kills the whole group
#   - a run refuses (rc 125) unless the caller's HOME is the password-database home (same device and inode); the child's HOME
#     is always that home. The output file is opened O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW, mode 0600; a symlink, a hard-linked
#     file, a non-regular file (the null device excepted) and a parent inside a CLI home are refused (rule 4)
#   - the fixed codesign the helper starts for registration is watched too: TERM/INT/HUP or the caller's death kill its group
#
# Core modules only (POSIX Fcntl Errno Cwd Digest::SHA). Works with the system perl of macOS and of Linux.

BEGIN {
    # Never load a module from a relative @INC entry such as "." (old perls keep it), whatever the cwd holds.
    @INC = grep { defined($_) && !ref($_) && substr($_, 0, 1) eq '/' } @INC;
}
use strict;
use warnings;
use POSIX ();
use Fcntl;
use Fcntl qw(:mode);
use Errno ();
use Cwd ();
use Digest::SHA ();

# ---- fixed constants (no environment variable, flag or PATH entry changes them) -----------------------------------------
use constant CODESIGN_BIN => "/usr/bin/codesign";
use constant CODESIGN_SECS => 20;
use constant AUTH_PREFIX => "Developer ID Application";
# The designated-requirement text: the chain must reach Apple's root, the leaf must be a Developer ID Application certificate
# (Apple's marker extension OID 1.2.840.113635.100.6.1.13; documented in Apple's Code Signing Requirement Language and used in
# Developer ID requirements), and the leaf's subject OU must be the pinned team. The team and the closing quote follow.
use constant REQ_PREFIX => 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "';
my %PINNED = (
    claude => 'Q6L2SF6YDW',    # Anthropic PBC. THE HUMAN MUST CONFIRM THESE AGAINST VENDOR-PUBLISHED VALUES.
    codex  => '2DC432GLL2',    # OpenAI
);

use constant DENY_FAIL_RC  => 121;    # distinct: the CLI-home denylist file could not be used
use constant DENY_FAIL_MSG => 'the CLI-home denylist (compliance/denylist.txt) is missing, empty or malformed; every operation is refused';

my %IN;      # the caller's inputs, copied from SPIKE_IN_* at start
my $CWD;     # physical cwd at start (relative inputs are made absolute from it)
my $ORIG_PPID = getppid();    # the caller; a different parent pid later means the caller died

$| = 1;

sub has_ctl { my ($s) = @_; return 1 unless defined $s; return ($s =~ /[\x00-\x1f\x7f]/) ? 1 : 0; }
sub def { my ($v, $d) = @_; return (defined($v) && length($v)) ? $v : $d; }
sub msg { print STDERR "spike: $_[0]\n"; return; }
sub ident { my @s = @_; return $s[0] . ':' . $s[1]; }
sub printable { my ($s, $max) = @_; $s = '' unless defined $s; $s =~ s/[^\x20-\x7e]//g; $s = substr($s, 0, $max) if defined $max && length($s) > $max; return $s; }
sub base_lc { my ($p) = @_; $p =~ s{.*/}{}s; $p = lc $p; $p =~ s/\.exe\z//; return $p; }

# ---- physical resolution ------------------------------------------------------------------------------------------------
# resolve_phys(path) -> { path => physical path, exists => 0|1, st => [lstat of the final entry] } or empty list.
# Runs of '/' collapse; '.' is skipped; '..' pops the (already physical) stack; every symlink is expanded in place.
# A trailing slash, a final '.' or '..', an empty path and a control character are refused. Only the FINAL component may
# be missing.
#
# resolve_phys(path, 1) is the LOOSE form used to judge a directory that does not exist yet (a capture or scratch root that
# mkdir -p will create): the first missing component and everything after it are returned lexically in { tail => [...] }
# and { path } is the physical path of the part that exists.
sub resolve_phys {
    my ($in, $loose) = @_;
    return unless defined $in && length $in;
    return if has_ctl($in);
    return if $in =~ m{/\z};
    $CWD = Cwd::getcwd() unless defined $CWD;
    my $p = $in;
    $p = $CWD . '/' . $p unless substr($p, 0, 1) eq '/';
    my @todo = grep { length } split m{/}, $p;
    return unless @todo;
    return if $todo[-1] eq '.' || $todo[-1] eq '..';
    my @stack;
    my $links  = 0;
    my $exists = 1;
    while (@todo) {
        my $c = shift @todo;
        next if $c eq '.';
        if ($c eq '..') { pop @stack; next; }
        my $full = '/' . join('/', @stack, $c);
        my @st = lstat($full);
        if (!@st) {
            if ($loose && $!{ENOENT}) {
                my @tail = ($c);
                for my $t (@todo) {
                    next if $t eq '.';
                    if ($t eq '..') { if (@tail) { pop @tail; } else { pop @stack; } next; }
                    push @tail, $t;
                }
                return { path => '/' . join('/', @stack), exists => 0, st => [], tail => \@tail };
            }
            if (!@todo && $!{ENOENT}) { push @stack, $c; $exists = 0; last; }
            return;
        }
        if (S_ISLNK($st[2])) {
            return if ++$links > 40;
            my $t = readlink($full);
            return unless defined $t && length $t;
            return if has_ctl($t);
            @stack = () if substr($t, 0, 1) eq '/';
            unshift @todo, grep { length } split m{/}, $t;
            next;
        }
        push @stack, $c;
    }
    return unless @stack;
    my $path = '/' . join('/', @stack);
    my @fin = $exists ? lstat($path) : ();
    return if $exists && !@fin;
    return { path => $path, exists => $exists, st => \@fin };
}

# path_lookup(name) -> first regular, executable file called <name> in an absolute entry of the caller's PATH, or undef.
sub path_lookup {
    my ($name) = @_;
    return if !defined $name || !length $name || $name =~ m{/} || has_ctl($name) || $name =~ /\A-/;
    for my $d (split /:/, def($IN{PATH}, '/usr/bin:/bin'), -1) {
        next unless length $d && substr($d, 0, 1) eq '/';
        next if has_ctl($d);
        my $f = "$d/$name";
        return $f if -f $f && -x _;
    }
    return;
}

# resolve_cmd(cmd) -> physical path of an existing file, or empty. A bare name is searched on PATH once; an absolute path is
# taken as given; a relative path with a slash, a leading dash and an empty name are refused.
sub resolve_cmd {
    my ($cmd) = @_;
    return unless defined $cmd && length $cmd;
    return if has_ctl($cmd);
    return if $cmd =~ /\A-/;
    my $full;
    if (substr($cmd, 0, 1) eq '/') { $full = $cmd; }
    elsif (index($cmd, '/') >= 0)  { return; }
    else { $full = path_lookup($cmd); return unless defined $full; }
    my $r = resolve_phys($full);
    return unless $r && $r->{exists};
    return $r->{path};
}

# ---- CLI homes (rule 4), by (device, inode) ------------------------------------------------------------------------------
# The names are NOT in this file. They are read at run time from compliance/denylist.txt, the lead-owned single list of CLI
# homes: one entry per line relative to the account's home, '#' comments, blank lines; every entry must match
# ^\.[A-Za-z0-9._-]+$. The file is found from this script's own physical path (spike/lib/runner.pl -> <repo root>/compliance/
# denylist.txt), opened O_NOFOLLOW and must be a regular file. Missing, unreadable, empty or malformed means FAIL CLOSED:
# denylist_ok() is false, under_cli_home() refuses everything, and main() refuses every subcommand (DENY_FAIL_RC).
my @DENY;
my $DENY_LOADED = 0;      # 0 = not tried, 1 = loaded, -1 = failed

sub denylist_file {
    my $r = resolve_phys(__FILE__);
    return unless $r && $r->{exists};
    my @parts = grep { length } split m{/}, $r->{path};
    return unless @parts >= 4;    # /<root>/<dir>/lib/runner.pl at the least
    splice @parts, -3;            # runner.pl, lib, spike
    return '/' . join('/', @parts, 'compliance', 'denylist.txt');
}

# parse_denylist(text) -> list of entries, or empty list if the text is empty or any line is malformed.
sub parse_denylist {
    my ($text) = @_;
    return unless defined $text;
    my (@n, %seen);
    for my $line (split /\n/, $text, -1) {
        $line =~ s/#.*\z//s;
        $line =~ s/\A[ \t]+//;
        $line =~ s/[ \t]+\z//;
        next unless length $line;
        return unless $line =~ /\A\.[A-Za-z0-9._-]+\z/ && $line ne '..';
        push @n, $line unless $seen{$line}++;
    }
    return @n;
}

sub load_denylist {
    return $DENY_LOADED > 0 ? 1 : 0 if $DENY_LOADED;
    $DENY_LOADED = -1;
    my $p = denylist_file();
    return 0 unless defined $p;
    my $fh;
    sysopen($fh, $p, O_RDONLY | O_NOFOLLOW | O_NOCTTY | O_NONBLOCK) or return 0;
    my @fs = stat($fh);
    unless (@fs && S_ISREG($fs[2]) && $fs[7] > 0 && $fs[7] <= 65536) { close $fh; return 0; }
    my ($data, $buf) = ('', '');
    while ((sysread($fh, $buf, 65536) || 0) > 0) { $data .= $buf; }
    close $fh;
    my @n = parse_denylist($data);
    return 0 unless @n;
    @DENY = @n;
    $DENY_LOADED = 1;
    return 1;
}

sub denylist_ok { return load_denylist(); }

sub cli_names { return load_denylist() ? @DENY : (); }

# candidate_homes(pw_home, env_home) -> the absolute, control-free, distinct homes to check. Pure, so a test can show that
# an HOME pointed away (or unset, or relative) never removes the password-database home.
sub candidate_homes {
    my ($pw, $env) = @_;
    my (@h, %seen);
    for my $h ($pw, $env) {
        next unless defined $h && length $h;
        next if has_ctl($h);
        next unless substr($h, 0, 1) eq '/';
        $h =~ s{/+\z}{};
        next unless length $h;
        next if $seen{$h}++;
        push @h, $h;
    }
    return @h;
}

# account_home() -> the password-database home of this account. ONE line, so a test can point a SANDBOX COPY of this file at a
# fake home (the same technique as the codesign constant); the shipped file is checked to keep the getpwuid form.
sub account_home { my @pw = getpwuid($<); return $pw[7]; }

sub current_homes {
    return candidate_homes(account_home(), $IN{HOME});
}

# home_idents(homes...) -> { "dev:ino" => 1 } for every CLI home entry (the entry itself and, for a symlink, its target).
sub home_idents {
    my (@homes) = @_;
    my %set;
    for my $h (@homes) {
        my $r = resolve_phys($h);
        next unless $r && $r->{exists};
        for my $n (cli_names()) {
            my $p = $r->{path} . '/' . $n;
            my @l = lstat($p);
            next unless @l;
            $set{ ident(@l) } = 1;
            my @s = stat($p);
            $set{ ident(@s) } = 1 if @s;
        }
    }
    return \%set;
}

# path_idents(physical path) -> idents of '/', every ancestor directory and the final entry.
sub path_idents {
    my ($path) = @_;
    my @ids;
    my @s = stat('/');
    push @ids, ident(@s) if @s;
    my $cur = '';
    for my $c (grep { length } split m{/}, $path) {
        $cur .= '/' . $c;
        my @st = stat($cur);
        push @ids, ident(@st) if @st;
    }
    return @ids;
}

# under_cli_home(physical path) -> 1 if the path, or any directory on it, is a CLI home entry; 1 (fail closed) if no home
# can be determined at all.
sub under_cli_home {
    my ($path) = @_;
    return 1 unless denylist_ok();
    my @homes = current_homes();
    return 1 unless @homes;
    my $set = home_idents(@homes);
    for my $id (path_idents($path)) { return 1 if $set->{$id}; }
    return 0;
}

# under_cli_home_loose(path) -> 1 if a directory that may not exist yet would be, or lie inside, a CLI home. The part that
# exists is judged by identity; a missing first component that is named like a CLI home entry directly under a home is refused
# too (mkdir -p would create it). Fails closed when the path cannot be resolved at all.
sub under_cli_home_loose {
    my ($in) = @_;
    return 1 unless denylist_ok();
    my $r = resolve_phys($in, 1) or return 1;
    return under_cli_home($r->{path}) unless $r->{tail} && @{ $r->{tail} };
    return 1 if under_cli_home($r->{path});
    my %deny = map { lc($_) => 1 } cli_names();
    if ($deny{ lc $r->{tail}[0] }) {
        my @here = stat($r->{path});
        for my $h (current_homes()) {
            my $hr = resolve_phys($h);
            next unless $hr && $hr->{exists};
            my @hs = stat($hr->{path});
            return 1 if @hs && @here && ident(@hs) eq ident(@here);
        }
    }
    return 0;
}

# path_refused(resolved) -> 1 if the resolved entry is, or lies inside, a CLI home, or is a hard-linked regular file (a hard
# link could be a second name for a file in a CLI home, and the link count cannot show where it leads).
sub path_refused {
    my ($r) = @_;
    return 1 if under_cli_home($r->{path});
    return 1 if $r->{exists} && @{ $r->{st} } && S_ISREG($r->{st}[2]) && $r->{st}[3] > 1;
    return 0;
}

# ---- files ----------------------------------------------------------------------------------------------------------------
sub open_ro {
    my ($path) = @_;
    my $fh;
    sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NOCTTY | O_NONBLOCK) or return;
    return $fh;
}

sub is_macho {
    my ($b) = @_;
    return 0 unless defined $b && length($b) >= 4;
    my $m = unpack('H8', substr($b, 0, 4));
    return ($m =~ /\A(?:feedfacf|cffaedfe|feedface|cefaedfe|cafebabe|bebafeca)\z/) ? 1 : 0;
}

sub sha_of_fh {
    my ($fh) = @_;
    sysseek($fh, 0, 0);
    my $d = Digest::SHA->new(256);
    my $buf;
    while (1) {
        my $n = sysread($fh, $buf, 65536);
        return unless defined $n;
        last unless $n;
        $d->add($buf);
    }
    return $d->hexdigest;
}

# sha_of_path(path) -> hex digest of a regular, non-symlink file, or undef.
sub sha_of_path {
    my ($path) = @_;
    my $fh = open_ro($path) or return;
    my @fs = stat($fh);
    return unless @fs && S_ISREG($fs[2]);
    my $h = sha_of_fh($fh);
    close $fh;
    return $h;
}

sub rm_tree {
    my ($d, $dev, $depth) = @_;
    return 0 if $depth > 40;
    my @l = lstat($d);
    return 0 unless @l && S_ISDIR($l[2]) && !S_ISLNK($l[2]) && $l[0] == $dev;
    opendir(my $dh, $d) or return 0;
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    for my $e (@e) {
        my $p = "$d/$e";
        my @s = lstat($p);
        next unless @s;
        if (S_ISDIR($s[2])) { rm_tree($p, $dev, $depth + 1); }
        else { unlink($p); }
    }
    return rmdir($d) ? 1 : 0;
}

# ---- the private verify directory -----------------------------------------------------------------------------------------
sub parent_ok {
    my ($d) = @_;
    my @s = lstat($d);
    return 0 unless @s && S_ISDIR($s[2]) && !S_ISLNK($s[2]);
    # A sticky directory is shared, but another user's sticky directory is not ours to put a private directory in: the owner
    # must be this user or root (round 8).
    if ($s[2] & 01000) { return ($s[4] == $> || $s[4] == 0) ? 1 : 0; }
    return 0 unless $s[4] == $>;
    return 0 if $s[2] & 022;
    return 1;
}

# vdir_valid(dir) -> the directory if it is a verify directory this helper made: a physical path named spike-verify.<id>,
# owned by this user, mode 0700, in a safe parent, not inside a CLI home, with a regular .registry file of ours.
sub vdir_valid {
    my ($d) = @_;
    return unless defined $d && length $d && substr($d, 0, 1) eq '/' && !has_ctl($d);
    return unless $d =~ m{/spike-verify\.[A-Za-z0-9]{6,}\z};
    my $r = resolve_phys($d);
    return unless $r && $r->{exists} && $r->{path} eq $d;
    my @s = lstat($d);
    return unless @s && S_ISDIR($s[2]) && !S_ISLNK($s[2]);
    return unless $s[4] == $> && ($s[2] & 07777) == 0700;
    (my $parent = $d) =~ s{/[^/]+\z}{};
    $parent = '/' unless length $parent;
    return unless parent_ok($parent);
    my @g = lstat("$d/.registry");
    return unless @g && S_ISREG($g[2]) && $g[4] == $> && $g[3] == 1;
    return if under_cli_home($d);
    return $d;
}

sub random_id {
    my $n = '';
    if (sysopen(my $u, '/dev/urandom', O_RDONLY)) {
        my $b;
        sysread($u, $b, 12);
        close $u;
        $n = join('', map { ('a' .. 'z', 'A' .. 'Z', '0' .. '9')[ord($_) % 62] } split //, (defined $b ? $b : ''));
    }
    while (length($n) < 10) { $n .= ('a' .. 'z', 'A' .. 'Z', '0' .. '9')[int(rand(62))]; }
    return $n;
}

sub tmp_parent {
    my $t = def($IN{TMPDIR}, '/tmp');
    $t =~ s{/+\z}{};
    $t = '/' if $t eq '' && defined $IN{TMPDIR};
    $t = '/tmp' unless length $t;
    my $r = resolve_phys($t);
    return unless $r && $r->{exists};
    return $r->{path};
}

sub cmd_vdir_create {
    my ($owner) = @_;
    return usage('vdir-create <owner pid>') unless defined $owner && $owner =~ /\A[0-9]{1,10}\z/;
    my $old = umask(077);
    my $parent = tmp_parent();
    unless (defined $parent && parent_ok($parent) && !under_cli_home($parent)) {
        umask($old);
        msg('the temporary directory is not safe for a private verify directory');
        return 5;
    }
    my $d;
    for (1 .. 20) {
        my $cand = $parent . '/spike-verify.' . random_id();
        if (mkdir($cand, 0700)) { $d = $cand; last; }
        next if $!{EEXIST};
        last;
    }
    unless (defined $d) { umask($old); msg('cannot create the verify directory'); return 1; }
    chmod(0700, $d);
    my @s = lstat($d);
    my $ok = @s && S_ISDIR($s[2]) && !S_ISLNK($s[2]) && $s[4] == $> && ($s[2] & 07777) == 0700;
    for my $f ('.owner', '.registry') {
        last unless $ok;
        my $fh;
        if (sysopen($fh, "$d/$f", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
            syswrite($fh, "$owner\n") if $f eq '.owner';
            close $fh;
        } else { $ok = 0; }
    }
    umask($old);
    unless ($ok) { rm_tree($d, $s[0], 0) if @s; msg('the verify directory failed its safety checks'); return 1; }
    print "$d\n";
    return 0;
}

sub cmd_vdir_sweep {
    my ($owner) = @_;
    my $parent = tmp_parent();
    return 0 unless defined $parent && parent_ok($parent) && !under_cli_home($parent);
    opendir(my $dh, $parent) or return 0;
    my @names = grep { /\Aspike-verify\./ } readdir($dh);
    closedir $dh;
    for my $n (@names) {
        my $d = "$parent/$n";
        my @s = lstat($d);
        next unless @s && S_ISDIR($s[2]) && !S_ISLNK($s[2]) && $s[4] == $>;
        my @o = lstat("$d/.owner");
        next unless @o && S_ISREG($o[2]) && $o[4] == $>;
        my $fh = open_ro("$d/.owner") or next;
        my $line = '';
        sysread($fh, $line, 32);
        close $fh;
        next unless $line =~ /\A([0-9]{1,10})\b/;
        my $pid = $1 + 0;
        next if $pid <= 1;
        next if kill(0, $pid) || $!{EPERM};
        rm_tree($d, $s[0], 0);
    }
    return 0;
}

sub cmd_vdir_remove {
    my ($d) = @_;
    my $v = vdir_valid($d);
    return 2 unless defined $v;
    my @s = lstat($v);
    rm_tree($v, $s[0], 0);
    return 0;
}

# registry: lines "<sha256>\t<cli>\t<physical path of the installed binary>\n" in <vdir>/.registry
sub registry_add {
    my ($vdir, $sha, $cli, $path) = @_;
    my $fh;
    sysopen($fh, "$vdir/.registry", O_WRONLY | O_APPEND | O_NOFOLLOW) or return 0;
    my $ok = syswrite($fh, "$sha\t$cli\t$path\n");
    close $fh;
    return $ok ? 1 : 0;
}

# registry_sha(path) -> the sha256 of a registered file, read in place, or undef. The registered file is the real installed
# binary, which may lie inside a CLI home (the ratified narrow exception), so it is lstat-ed FIRST and opened only if it is a
# regular, single-link file; inside a CLI home it must also look like a vendor binary (owner-execute bit, at least 1 MiB). A
# credential file swapped in at that path is therefore never opened.
sub registry_sha {
    my ($path) = @_;
    my @l = lstat($path);
    return unless @l && S_ISREG($l[2]) && !S_ISLNK($l[2]) && $l[3] == 1;
    return if under_cli_home($path) && !home_binary_ok(@l);
    return sha_of_path($path);
}

# registry_ok(vdir, path) -> 1 only if <path> is registered and its CURRENT content still has the recorded sha256.
sub registry_ok {
    my ($vdir, $path) = @_;
    return 0 unless defined(vdir_valid($vdir));
    my $fh = open_ro("$vdir/.registry") or return 0;
    my $data = '';
    my $buf;
    while ((sysread($fh, $buf, 65536) || 0) > 0) { $data .= $buf; }
    close $fh;
    my $want;
    for my $line (split /\n/, $data) {
        my ($sha, $cli, $p) = split /\t/, $line, 3;
        next unless defined $p && $p eq $path;
        $want = $sha;
    }
    return 0 unless defined $want;
    my $have = registry_sha($path);
    return (defined $have && $have eq $want) ? 1 : 0;
}

# ---- codesign (fixed absolute path) ----------------------------------------------------------------------------------------
# run_capture(secs, argv...) -> (status, output, timed_out). stdout+stderr go through a pipe; no temporary file.
# The child leads its own process group. This function WATCHES it: a timeout, TERM/INT/HUP to the helper, or the death of the
# helper's caller (the parent pid changes; polled every 100 ms) kills that whole group, and in the signal and caller-death cases
# the helper then ends (143 / 130 / 129), so no codesign is ever left running under init.
my $CAP_SIG = 0;

sub run_capture {
    my ($secs, @argv) = @_;
    my ($rd, $wr);
    pipe($rd, $wr) or return (-1, '', 0);
    my $mask = POSIX::SigSet->new(POSIX::SIGTERM(), POSIX::SIGINT(), POSIX::SIGHUP());
    my $old  = POSIX::SigSet->new();
    POSIX::sigprocmask(POSIX::SIG_BLOCK(), $mask, $old);
    my $pid = fork();
    unless (defined $pid) { POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old, undef); return (-1, '', 0); }
    if (!$pid) {
        close $rd;
        $SIG{$_} = 'DEFAULT' for qw(TERM INT HUP);
        POSIX::sigprocmask(POSIX::SIG_SETMASK(), POSIX::SigSet->new(), undef);
        POSIX::setpgid(0, 0);
        open(STDIN, '<', '/dev/null');
        POSIX::dup2(fileno($wr), 1);
        POSIX::dup2(fileno($wr), 2);
        # Rule 2: the account's own home, never an alternate one.
        %ENV = (PATH => '/usr/bin:/bin', LANG => 'C', HOME => def(account_home(), '/'));
        {
            no warnings 'exec';
            exec { $argv[0] } @argv;
        }
        POSIX::_exit(127);
    }
    POSIX::setpgid($pid, $pid);
    close $wr;
    $CAP_SIG = 0;
    local $SIG{TERM} = sub { $CAP_SIG ||= 143 };
    local $SIG{INT}  = sub { $CAP_SIG ||= 130 };
    local $SIG{HUP}  = sub { $CAP_SIG ||= 129 };
    POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old, undef);
    my ($out, $timed, $ended) = ('', 0, 0);
    my $deadline = time + $secs;
    my $rin = '';
    vec($rin, fileno($rd), 1) = 1;
    while (1) {
        if ($CAP_SIG) { $ended = $CAP_SIG; last; }
        if (getppid() != $ORIG_PPID) { $ended = 143; last; }
        my $left = $deadline - time;
        if ($left <= 0) { $timed = 1; last; }
        $left = 0.1 if $left > 0.1;
        my $rout = $rin;
        my $n = select($rout, undef, undef, $left);
        next if $n < 0;
        if ($n > 0) {
            my $buf;
            my $got = sysread($rd, $buf, 65536);
            last unless $got;
            $out .= $buf if length($out) < 262144;
        }
    }
    if ($timed || $ended) { kill 'KILL', -$pid; kill 'KILL', $pid; }
    close $rd;
    waitpid($pid, 0);
    POSIX::_exit($ended) if $ended;
    my $st = $?;
    my $rc = ($st & 127) ? 128 + ($st & 127) : ($st >> 8);
    return ($timed ? -1 : $rc, $out, $timed);
}

# verify_signer(path, cli) -> (ok, signature text). Only CODESIGN_BIN is run, only on the real path being registered.
sub verify_signer {
    my ($bin, $cli) = @_;
    my $want = $PINNED{$cli};
    return (0, 'NOT VERIFIED (no pinned team for this name)') unless defined $want;
    return (0, 'NOT VERIFIED (codesign unavailable)') unless -x CODESIGN_BIN;
    my ($rc, $out, $timed) = run_capture(CODESIGN_SECS, CODESIGN_BIN, '--verify', '--strict', $bin);
    return (0, 'NOT VERIFIED (codesign timed out)') if $timed;
    if ($rc != 0) {
        return (0, 'NOT SIGNED') if $out =~ /not signed at all/i;
        return (0, "NOT VERIFIED (codesign rc=$rc)");
    }
    ($rc, $out, $timed) = run_capture(CODESIGN_SECS, CODESIGN_BIN, '-dv', '--verbose=2', $bin);
    my ($firstauth) = $out =~ /^Authority=(.*)$/m;
    my ($team)      = $out =~ /^TeamIdentifier=(.*)$/m;
    $firstauth = '' unless defined $firstauth;
    $team      = '' unless defined $team;
    my $auth = printable($firstauth);
    $auth =~ s/ \([A-Z0-9]*\)\z//;
    $auth = substr($auth, 0, 46);
    $team = substr(printable($team), 0, 12);
    my $sigkind = ($out =~ /^Signature=adhoc/m) ? 'ad-hoc, ' : '';
    my $pre = AUTH_PREFIX;
    if (index($firstauth, $pre) != 0) {
        return (0, 'UNTRUSTED (valid but ' . $sigkind . (length $auth ? $auth : 'no authority') . '; not Developer ID)');
    }
    if ($team ne $want) {
        return (0, 'UNTRUSTED (valid but team ' . (length $team ? $team : 'not set') . ' is not the pinned team)');
    }
    # The text above can be forged by a self-made certificate; this asks codesign to check the chain to Apple's root.
    ($rc, $out, $timed) = run_capture(CODESIGN_SECS, CODESIGN_BIN, '--verify', '--strict',
        '-R=' . REQ_PREFIX . $want . '"', $bin);
    return (0, 'UNTRUSTED (signer text matches but the certificate chain does not satisfy the pinned team)') if $rc != 0;
    return (1, "valid; $auth; team $team");
}

# ---- registration ----------------------------------------------------------------------------------------------------------
sub emit_result {
    my (%r) = @_;
    my @f = map { my $v = defined $r{$_} ? $r{$_} : ''; $v =~ s/[\x00-\x1f\x7f]//g; $v } qw(STATUS KIND PATH COPY SIG);
    print join("\t", @f), "\n";
    return 0;
}

# home_binary_ok(stat fields) -> 1 only for a regular file with the owner-execute bit set and a size of at least 1 MiB.
use constant HOME_BINARY_MIN => 1048576;
sub home_binary_ok {
    my (@s) = @_;
    return 0 unless @s >= 8;
    return 0 unless S_ISREG($s[2]);
    return 0 unless $s[2] & 0100;
    return 0 unless $s[7] >= HOME_BINARY_MIN;
    return 1;
}

# register <vdir> <cli> <path|name> <src>: one open, one hash, one in-place signer check, one registry line (no copy).
sub cmd_register {
    my ($vdir, $cli, $mode, $src) = @_;
    return usage('register <vdir> <cli> <path|name> <src>') unless defined $src;
    my %r = (STATUS => 'badpath', KIND => '-', PATH => '', COPY => '', SIG => 'NOT VERIFIED (not a regular executable file)');
    unless (defined(vdir_valid($vdir))) { msg('register: not a valid verify directory'); return 2; }
    unless (defined $PINNED{$cli}) {
        $r{STATUS} = 'badcli';
        $r{SIG}    = 'NOT VERIFIED (no pinned team for this name)';
        return emit_result(%r);
    }
    my $cand;
    if ($mode eq 'name') {
        $cand = path_lookup($src);
        unless (defined $cand) { $r{STATUS} = 'notfound'; $r{SIG} = '-'; return emit_result(%r); }
        $r{PATH} = $cand;
    } elsif ($mode eq 'path') {
        return emit_result(%r) unless substr($src, 0, 1) eq '/' && !has_ctl($src);
        my @l = lstat($src);
        return emit_result(%r) unless @l && !S_ISLNK($l[2]) && S_ISREG($l[2]) && -x $src;
        $cand = $src;
        $r{PATH} = $cand;
    } else {
        return usage('register mode');
    }
    my $res = resolve_phys($cand);
    unless ($res && $res->{exists}) {
        $r{STATUS} = 'unresolvable';
        $r{SIG}    = 'NOT VERIFIED (unresolvable path)';
        return emit_result(%r);
    }
    my $path = $res->{path};
    $r{PATH} = $path;

    # Rule 4: decide from identity BEFORE any byte is read.
    my $inhome = under_cli_home($path);
    # The ratified narrow exception (a vendor binary inside its CLI home) is for a vendor binary only: lstat it FIRST and
    # require a regular file, the owner-execute bit and a size of at least 1 MiB. A credential file is small and 0600, so
    # it is refused here WITHOUT being opened (round 8).
    if ($inhome && !home_binary_ok(@{ $res->{st} })) {
        $r{STATUS} = 'clihome';
        $r{KIND}   = 'refused';
        $r{SIG}    = 'REFUSED (inside a CLI home directory; not read)';
        return emit_result(%r);
    }
    my $fh = open_ro($path);
    unless ($fh) {
        $r{STATUS} = 'unresolvable';
        $r{SIG}    = 'NOT VERIFIED (cannot open without following links)';
        return emit_result(%r);
    }
    my @fs = stat($fh);
    unless (@fs && S_ISREG($fs[2]) && @{ $res->{st} } && ident(@fs) eq ident(@{ $res->{st} })) {
        close $fh;
        $r{STATUS} = 'unresolvable';
        $r{SIG}    = 'NOT VERIFIED (not a regular file, or it changed while being opened)';
        return emit_result(%r);
    }
    my $set = home_idents(current_homes());
    $inhome = 1 if $set->{ ident(@fs) };
    if ($fs[3] > 1) {
        close $fh;
        $r{STATUS} = 'hardlink';
        $r{KIND}   = 'refused';
        $r{SIG}    = 'REFUSED (hard-linked file; cannot prove it is outside a CLI home directory; not read)';
        return emit_result(%r);
    }
    if ($inhome && !home_binary_ok(@fs)) {
        close $fh;
        $r{STATUS} = 'clihome';
        $r{KIND}   = 'refused';
        $r{SIG}    = 'REFUSED (inside a CLI home directory; not read)';
        return emit_result(%r);
    }

    # The first read is the 4-byte magic. For a Mach-O the whole file is then hashed and codesign-checked in place (it IS the
    # vendor binary: the ratified narrow exception for a binary inside a CLI home covers reading, checking and running it).
    my $head = '';
    sysread($fh, $head, 4);
    if (!is_macho($head)) {
        close $fh;
        if ($inhome) {
            $r{STATUS} = 'clihome';
            $r{KIND}   = 'refused';
            $r{SIG}    = 'REFUSED (inside a CLI home directory; not read)';
        } elsif (substr($head, 0, 2) eq '#!') {
            $r{STATUS} = 'script';
            $r{KIND}   = 'script';
            $r{SIG}    = 'launcher only, not executed (needs human approval)';
        } else {
            $r{STATUS} = 'other';
            $r{KIND}   = 'other';
            $r{SIG}    = 'NOT VERIFIED (not a Mach-O file)';
        }
        return emit_result(%r);
    }
    $r{KIND} = 'mach-o';
    unless (-x CODESIGN_BIN) {
        close $fh;
        $r{STATUS} = 'signer';
        $r{SIG}    = 'NOT VERIFIED (codesign unavailable)';
        return emit_result(%r);
    }

    # VERIFY IN PLACE. Record the sha256 of the descriptor we opened, run the fixed codesign on the real physical path, then
    # check that the file at that path is still the same file (identity) with the same content. No copy is made anywhere.
    my $sha = sha_of_fh($fh);
    close $fh;
    unless (defined $sha) {
        $r{STATUS} = 'recordfail';
        $r{SIG}    = 'NOT VERIFIED (cannot hash the binary)';
        return emit_result(%r);
    }
    my ($ok, $text) = verify_signer($path, $cli);
    my @after = lstat($path);
    my $again = registry_sha($path);
    if ($ok && (!@after || ident(@after) ne ident(@fs) || !defined $again || $again ne $sha)) {
        $ok   = 0;
        $text = 'NOT VERIFIED (the binary changed while it was checked)';
    }
    if (!$ok) {
        $r{STATUS} = 'signer';
        $r{SIG}    = $text;
        return emit_result(%r);
    }
    unless (registry_add($vdir, $sha, $cli, $path)) {
        $r{STATUS} = 'recordfail';
        $r{SIG}    = 'NOT VERIFIED (cannot record the verification)';
        return emit_result(%r);
    }
    # COPY is the historical field name (spike_register_cli / $SPIKE_VERIFIED_COPY): it is the verified REAL path now.
    $r{STATUS} = 'verified';
    $r{COPY}   = $path;
    $r{SIG}    = $text;
    return emit_result(%r);
}

# ---- identity gate ---------------------------------------------------------------------------------------------------------
my %ALLOW  = map { $_ => 1 } qw(git codesign true false sleep echo printf);
my %LAUNCH = map { $_ => 1 } qw(env sh bash zsh dash ksh csh tcsh fish xargs nohup command exec time nice perl python python3 node ruby script expect osascript open);
my %TOOLS  = map { $_ => 1 } qw(jq git);

sub system_path { return ($_[0] =~ m{\A(?:/bin|/usr/bin|/usr/sbin|/sbin)/.}) ? 1 : 0; }

# Provider words are judged ONLY on a program name: argv[0]'s basename and the resolved target's basename. Identity is enforced
# separately (system directory, resolved once), so the words in the ARGUMENTS of an ungated system command (echo, printf, a
# path under a directory named after a provider) cannot launch anything and are not examined (round 8).
sub provider_word {
    my ($base) = @_;
    return ($base =~ /(?:^|[^a-z0-9])(?:claude|codex|grok|gemini|kimi)(?:[^a-z0-9]|$)/i) ? 1 : 0;
}

# pinned_name(lower-case basename) -> 1 for the pinned CLI names (claude, codex), including claude.exe, claude-real, claude.2.
sub pinned_name {
    my ($base) = @_;
    return ($base =~ /\A(?:claude|codex)(?![a-z0-9])/) ? 1 : 0;
}

sub status_shape {
    my (@a) = @_;
    return 1 if @a == 1 && $a[0] eq '--version';
    return 1 if @a == 2 && ($a[0] . ' ' . $a[1]) eq 'auth status';
    return 1 if @a == 2 && ($a[0] . ' ' . $a[1]) eq 'login status';
    return 0;
}

sub arg_is_path { return (defined $_[0] && length $_[0] && substr($_[0], 0, 1) ne '-') ? 1 : 0; }

sub codesign_shape {
    my (@a) = @_;
    return 1 if @a == 3 && $a[0] eq '--verify' && $a[1] eq '--strict' && arg_is_path($a[2]);
    return 1 if @a == 3 && $a[0] eq '-dv' && $a[1] eq '--verbose=2' && arg_is_path($a[2]);
    if (@a == 4 && $a[0] eq '--verify' && $a[1] eq '--strict') {
        return 1 if index($a[2], '-R=' . REQ_PREFIX) == 0 && $a[2] =~ /"[A-Z0-9]{10}"\z/ && arg_is_path($a[3]);
    }
    return 0;
}

# codesign_rooted(path, vdir) -> 1 only if the PHYSICAL path is strictly inside a valid verify directory.
sub codesign_rooted {
    my ($p, $vdir) = @_;
    return 0 unless defined $vdir && $vdir ne '-' && defined(vdir_valid($vdir));
    my $r = resolve_phys($p);
    return 0 unless $r;
    return (index($r->{path}, $vdir . '/') == 0 && length($r->{path}) > length($vdir) + 1) ? 1 : 0;
}

# ungated_ok(resolved, typed argv0, vdir, args...) -> 1 if this may run without SPIKE_LIVE.
sub ungated_ok {
    my ($res, $cmd, $vdir, @args) = @_;
    return 0 unless defined $res && system_path($res);
    my $ab = base_lc($cmd);
    my $rb = base_lc($res);
    return 0 unless $ALLOW{$ab} && $ALLOW{$rb};
    return 0 if provider_word($ab) || provider_word($rb);
    return 0 if $LAUNCH{$rb};
    if ($rb eq 'git') { return (@args == 1 && $args[0] eq '--version') ? 1 : 0; }
    if ($rb eq 'codesign') {
        return 0 unless codesign_shape(@args);
        return 0 unless codesign_rooted($args[-1], $vdir);
        return 1;
    }
    return 1;
}

# Probe tools (display only): exactly `jq --version` and `git --version`, nothing else. The tool must be a native executable in
# a system or package-manager prefix (so a wrapper script or a copy in a user directory that happens to be first on PATH is
# refused, never run), owned by this user or root and not writable by group or others.
my @TOOL_PREFIXES = ('/bin/', '/usr/bin/', '/usr/sbin/', '/sbin/', '/usr/local/', '/opt/homebrew/');

sub tool_file_ok {
    my ($path) = @_;
    return 0 unless defined $path && !has_ctl($path);
    return 0 unless grep { index($path, $_) == 0 } @TOOL_PREFIXES;
    my @l = lstat($path);
    return 0 unless @l && S_ISREG($l[2]) && !S_ISLNK($l[2]);
    return 0 unless $l[4] == 0 || $l[4] == $>;
    return 0 if $l[2] & 022;
    return 0 unless $l[2] & 0100;
    my $fh = open_ro($path) or return 0;
    my $head = '';
    sysread($fh, $head, 2);
    close $fh;
    return 0 if substr($head, 0, 2) eq '#!';
    return 1;
}

# tool_resolve(cmd) -> (verdict, path): ok | unresolved | refuse.
sub tool_resolve {
    my ($cmd) = @_;
    return ('refuse') unless defined $cmd && ($cmd =~ /\A[A-Za-z0-9._+-]+\z/ || substr($cmd, 0, 1) eq '/') && $TOOLS{ base_lc($cmd) };
    my $path = resolve_cmd($cmd);
    return ('unresolved') unless defined $path;
    return ('refuse') unless $TOOLS{ base_lc($path) };
    return ('refuse') unless tool_file_ok($path);
    return ('ok', $path);
}

# live_pinned_ok(vdir, cmd, resolved path) -> 0 if the command is named like a pinned CLI (claude, codex), by argv[0] or by the
# resolved target, and is not the CURRENT registered, hash-verified binary (rule 6).
sub live_pinned_ok {
    my ($vdir, $cmd, $path) = @_;
    return 1 unless pinned_name(base_lc($cmd)) || pinned_name(base_lc($path));
    return 0 unless defined $vdir && $vdir ne '-';
    return registry_ok($vdir, $path) ? 1 : 0;
}

# authorize(mode, vdir, cmd, args...) -> (verdict, path); verdict is ok | gate (needs SPIKE_LIVE) | unresolved | refuse.
sub authorize {
    my ($mode, $vdir, $cmd, @args) = @_;
    my $path = resolve_cmd($cmd);
    if ($mode eq 'live') {
        return ('unresolved') unless defined $path;
        return ('refuse') unless live_pinned_ok($vdir, $cmd, $path);
        return ('ok', $path);
    }
    if ($mode eq 'ungated') {
        return ('unresolved') unless defined $path;
        return ungated_ok($path, $cmd, $vdir, @args) ? ('ok', $path) : ('gate', $path);
    }
    if ($mode eq 'tool') {
        # Exactly `<jq|git> --version`: no other argument can load a module (jq -L, import), define an alias (git -c) or name
        # a file, so a probe can never read a CLI home or start another program (rules 1 and 4).
        my ($v, $p) = tool_resolve($cmd);
        return ($v) unless $v eq 'ok';
        return ('refuse') unless @args == 1 && defined $args[0] && $args[0] eq '--version';
        return ('ok', $p);
    }
    if ($mode eq 'status') {
        return ('refuse') unless defined $cmd && substr($cmd, 0, 1) eq '/' && defined $path;
        return ('refuse') unless defined $vdir && $vdir ne '-';
        return ('refuse') unless status_shape(@args);
        return ('refuse') if $LAUNCH{ base_lc($path) };
        return ('refuse') unless registry_ok($vdir, $path);
        return ('ok', $path);
    }
    return ('refuse');
}

sub cmd_gate {
    my ($mode, $vdir, $cmd, @args) = @_;
    return usage('gate <mode> <vdir|-> <cmd> [args]') unless defined $cmd;
    my ($verdict, $path) = authorize($mode, $vdir, $cmd, @args);
    if ($verdict eq 'ok' || $verdict eq 'gate') {
        return 2 if has_ctl($path);
        print "$path\n";
        return $verdict eq 'ok' ? 0 : 1;
    }
    return 2 if $verdict eq 'unresolved';
    return 3;
}

# ---- the run: a new process group, an in-group watchdog ----------------------------------------------------------------------
# child_home() -> the password-database home, or empty if the caller's HOME is set and is not that same directory (same device and
# inode). Rule 2: a child never gets an alternate home; a run with a different HOME is refused instead (rc 125).
sub child_home {
    my $pw = account_home();
    return unless defined $pw && length $pw && substr($pw, 0, 1) eq '/' && !has_ctl($pw);
    my @ps = stat($pw);
    return unless @ps;
    my $h = $IN{HOME};
    if (defined $h && length $h) {
        return unless substr($h, 0, 1) eq '/' && !has_ctl($h);
        my @hs = stat($h);
        return unless @hs && ident(@hs) eq ident(@ps);
    }
    return $pw;
}

# open_outfile(path) -> a write handle, or empty (the reason goes to stderr). The file is opened O_WRONLY|O_CREAT|O_APPEND|
# O_NOFOLLOW with mode 0600. Refused (rule 4): a symlink, a hard-linked file, a non-regular file (only the null device is
# accepted, it discards), a file that is a CLI home entry, and any file whose parent directory is, or lies inside, a CLI home.
sub open_outfile {
    my ($f) = @_;
    return unless defined $f && length $f && !has_ctl($f);
    my ($dir, $base);
    if ($f =~ m{\A(.*)/([^/]+)\z}s) { ($dir, $base) = ($1, $2); $dir = '/' unless length $dir; }
    else { ($dir, $base) = (undef, $f); }
    return if $base eq '.' || $base eq '..';
    $CWD = Cwd::getcwd() unless defined $CWD;
    my $pdir;
    if (defined $dir) {
        my $pr = resolve_phys($dir);
        $pdir = $pr->{path} if $pr && $pr->{exists} && @{ $pr->{st} } && S_ISDIR($pr->{st}[2]);
    } else {
        $pdir = $CWD;
    }
    return unless defined $pdir;
    my $pres = resolve_phys($pdir);
    return unless $pres && $pres->{exists};
    return if path_refused($pres);
    my $full = ($pdir eq '/') ? "/$base" : "$pdir/$base";
    my @nul = stat('/dev/null');
    my @l = lstat($full);
    my $is_null = 0;
    if (@l) {
        return if S_ISLNK($l[2]);
        if (S_ISCHR($l[2])) {
            return unless @nul && S_ISCHR($nul[2]) && $l[6] == $nul[6];
            $is_null = 1;
        } else {
            return unless S_ISREG($l[2]) && $l[3] == 1;
            my $fr = resolve_phys($full);
            return if !$fr || path_refused($fr);
        }
    }
    my $out;
    sysopen($out, $full, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NOCTTY, 0600) or return;
    my @fs = stat($out);
    my $good = 0;
    if (@fs) {
        if ($is_null)           { $good = (S_ISCHR($fs[2]) && @nul && $fs[6] == $nul[6]) ? 1 : 0; }
        elsif (S_ISREG($fs[2])) { $good = ($fs[3] == 1 && (!@l || ident(@fs) eq ident(@l))) ? 1 : 0; }
    }
    unless ($good) { close $out; return; }
    return wantarray ? ($out, $full) : $out;
}

sub child_env {
    my %e = (
        PATH   => def($IN{PATH},   '/usr/bin:/bin'),
        HOME   => def(child_home(), '/'),
        TMPDIR => def($IN{TMPDIR}, '/tmp'),
        LANG   => def($IN{LANG},   'C'),
        TERM   => def($IN{TERM},   'dumb'),
    );
    # USER/LOGNAME because a CLI looks up its own stored login under the account name; they carry no credentials.
    $e{USER}    = $IN{USER}    if defined $IN{USER}    && length $IN{USER};
    $e{LOGNAME} = $IN{LOGNAME} if defined $IN{LOGNAME} && length $IN{LOGNAME};
    return %e;
}

my $PGID = 0;

# leave_group() -> (helper pid, write end) after moving THIS process out of its own group into a fresh holder group, so a
# SIGKILL to the old group cannot kill the helper that sends it. Empty list when that is not possible.
sub leave_group {
    my ($sync_r, $sync_w, $hold_r, $hold_w);
    pipe($sync_r, $sync_w) or return;
    pipe($hold_r, $hold_w) or return;
    my $me = $$;
    my $t = fork();
    return unless defined $t;
    if (!$t) {
        close $sync_r;
        close $hold_w;
        POSIX::setpgid(0, 0);
        syswrite($sync_w, 'x');
        close $sync_w;
        my $rin = '';
        vec($rin, fileno($hold_r), 1) = 1;
        while (1) {
            my $rout = $rin;
            my $n = select($rout, undef, undef, 0.5);
            last if $n > 0;
            last if getppid() != $me;
        }
        POSIX::_exit(0);
    }
    close $sync_w;
    close $hold_r;
    my $b;
    sysread($sync_r, $b, 1);
    close $sync_r;
    if (POSIX::setpgid(0, $t)) { return ($t, $hold_w); }
    close $hold_w;
    kill 'KILL', $t;
    waitpid($t, 0);
    return;
}

# sweep(term_first, child pid): TERM the group (the helper ignores it), then leave the group, wait 0.3 s, KILL the group.
sub sweep {
    my ($term_first, $cpid) = @_;
    local @SIG{qw(TERM INT HUP PIPE)} = ('IGNORE') x 4;
    kill 'TERM', -$PGID if $term_first;
    my ($holder, $hw) = leave_group();
    select(undef, undef, undef, 0.3) if $term_first;
    if (defined $holder) { kill 'KILL', -$PGID; }
    else { kill 'KILL', $cpid if defined $cpid; }
    if (defined $holder) { close $hw; kill 'KILL', $holder; waitpid($holder, 0); }
    return;
}

sub exit_status {
    my ($st) = @_;
    return ($st & 127) ? 128 + ($st & 127) : ($st >> 8);
}

# run <mode> <secs> <outfile> <vdir|-> <path> [args...]
sub cmd_run { return run_core(undef, @_); }

# run-split live <secs> <outfile> <errfile> <vdir|-> <path> [args...]: the same as `run live`, except that the child's stdout
# goes to <outfile> and its stderr to <errfile>. Only the live mode has a split form; <errfile> gets exactly the outfile
# policy, and the two files must be different files.
sub cmd_run_split {
    my ($mode, $secs, $outfile, $errfile, @rest) = @_;
    return usage('run-split live <secs> <out> <err> <vdir|-> <path> [args]') unless defined $errfile && @rest >= 2;
    return usage('run-split mode') unless $mode eq 'live';
    return usage('bad error file') unless length $errfile && !has_ctl($errfile);
    return run_core($errfile, $mode, $secs, $outfile, @rest);
}

sub run_core {
    my ($errfile, $mode, $secs, $outfile, $vdir, $path, @args) = @_;
    return usage('run <mode> <secs> <out> <vdir|-> <path> [args]') unless defined $path;
    return usage('bad timeout') unless $secs =~ /\A[0-9]{1,4}\z/ && $secs >= 1 && $secs <= 3600;
    $secs = $secs + 0;
    return usage('bad output file') unless defined $outfile && length $outfile && !has_ctl($outfile);
    my $r = resolve_phys($path);
    unless ($r && $r->{exists} && $r->{path} eq $path) { msg('run: not an exact physical path'); return 125; }
    # The policy is enforced again here, in the process that executes.
    if ($mode eq 'live') {
        unless (defined $IN{LIVE} && $IN{LIVE} eq '1') { msg('run: live mode needs SPIKE_LIVE=1'); return 125; }
        my ($v) = authorize('live', $vdir, $path, @args);
        unless ($v eq 'ok') { msg('run: a pinned CLI name runs only as the current registered, hash-verified binary'); return 125; }
    } elsif ($mode eq 'ungated') {
        unless (ungated_ok($path, $path, $vdir, @args)) { msg('run: not ungated'); return 125; }
    } elsif ($mode eq 'status') {
        my ($v) = authorize('status', $vdir, $path, @args);
        unless ($v eq 'ok') { msg('run: not the registered, hash-verified binary, or not a status shape'); return 125; }
    } elsif ($mode eq 'tool') {
        my ($v) = authorize('tool', $vdir, $path, @args);
        unless ($v eq 'ok') { msg('run: not a tool probe'); return 125; }
    } else {
        return usage('run mode');
    }
    # Rule 2: the child's HOME is always the account's own home; a caller whose HOME is another directory is refused.
    unless (defined child_home()) { msg('run: HOME is not the account home (the child never gets an alternate home)'); return 125; }
    my ($out, $outfull) = open_outfile($outfile);
    unless ($out) { msg('run: the output file is refused (symlink, hard link, non-regular file, or inside a CLI home) or cannot be opened'); return 125; }
    my $err;
    if (defined $errfile) {
        my $errfull;
        ($err, $errfull) = open_outfile($errfile);
        unless ($err) { msg('run: the error file is refused (symlink, hard link, non-regular file, or inside a CLI home) or cannot be opened'); return 125; }
        # Two names for one file would interleave the streams: refuse the same resolved path and the same open file.
        my @eid = stat($err);
        my @oid = stat($out);
        if ($errfull eq $outfull || (@eid && @oid && ident(@eid) eq ident(@oid))) {
            msg('run: the output file and the error file must be different files');
            return 125;
        }
    }
    my $orig_ppid = getppid();
    my %env = child_env();

    my $mask = POSIX::SigSet->new(POSIX::SIGTERM(), POSIX::SIGINT(), POSIX::SIGHUP());
    my $old  = POSIX::SigSet->new();
    POSIX::sigprocmask(POSIX::SIG_BLOCK(), $mask, $old);
    my $sigged = 0;
    $SIG{TERM} = sub { $sigged ||= 143; };
    $SIG{INT}  = sub { $sigged ||= 130; };
    $SIG{HUP}  = sub { $sigged ||= 129; };
    unless (POSIX::setpgid(0, 0)) { msg("run: cannot lead a new process group: $!"); return 125; }
    $PGID = $$;
    my $pid = fork();
    unless (defined $pid) { msg("run: fork failed: $!"); return 125; }
    if (!$pid) {
        $SIG{$_} = 'DEFAULT' for qw(TERM INT HUP PIPE);
        POSIX::sigprocmask(POSIX::SIG_SETMASK(), POSIX::SigSet->new(), undef);
        open(STDIN, '<', '/dev/null');
        POSIX::dup2(fileno($out), 1);
        POSIX::dup2(fileno(defined $err ? $err : $out), 2);
        %ENV = %env;
        {
            no warnings 'exec';
            exec { $path } $path, @args;
        }
        my $code = ($!{ENOENT} || $!{ENOTDIR}) ? 127 : 126;
        print STDERR "spike: cannot execute: $!\n";
        POSIX::_exit($code);
    }
    close $out;
    close $err if defined $err;
    POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old, undef);

    my $hz = POSIX::sysconf(POSIX::_SC_CLK_TCK()) || 100;
    my $t0 = (POSIX::times())[0];
    my $status;
    while (1) {
        my $w = waitpid($pid, POSIX::WNOHANG());
        if ($w == $pid) { $status = $?; last; }
        if ($w < 0) { $status = 0; last; }
        if ($sigged) { sweep(1, $pid); waitpid($pid, 0); return $sigged; }
        if (getppid() != $orig_ppid) { sweep(1, $pid); waitpid($pid, 0); return 143; }
        if (((POSIX::times())[0] - $t0) / $hz >= $secs) { sweep(1, $pid); waitpid($pid, 0); return 124; }
        select(undef, undef, undef, 0.05);
    }
    # The command exited. Sweep anything it left running in its group.
    sweep(0, undef);
    return exit_status($status);
}

# ---- small subcommands ------------------------------------------------------------------------------------------------------
sub usage { msg("usage: $_[0]"); return 2; }

# resolve <path> -> prints the physical path (relative input is made absolute from the cwd).
sub cmd_resolve {
    my ($p) = @_;
    my $r = resolve_phys($p);
    return 1 unless $r;
    print $r->{path}, "\n";
    return 0;
}

# clihome <path> -> 0 (refuse) if the path is, or lies inside, a CLI home, if it is a hard-linked regular file (it may be
# a second name for a CLI home file), or if it cannot be resolved; 1 if it is outside every CLI home.
sub cmd_clihome {
    my ($p) = @_;
    my $r = resolve_phys($p);
    return 0 unless $r;
    return path_refused($r) ? 0 : 1;
}

# clihome-new <path> -> like clihome, for a directory that may not exist yet (a capture or scratch root that mkdir -p will
# create): 0 (refuse) if it would be, or lie inside, a CLI home, or cannot be resolved; 1 otherwise.
sub cmd_clihome_new {
    my ($p) = @_;
    return 0 unless defined $p;
    return under_cli_home_loose($p) ? 0 : 1;
}

# tool-path <name> -> prints the physical path of a probe tool (jq or git) found on the caller's PATH, if it passes the tool
# identity checks (a native executable in a system or package-manager prefix); rc 1 otherwise.
sub cmd_tool_path {
    my ($name) = @_;
    my ($v, $path) = tool_resolve($name);
    return 1 unless $v eq 'ok';
    print "$path\n";
    return 0;
}

sub main {
    my ($sub, @a) = @_;
    $CWD = Cwd::getcwd();
    for my $k (qw(PATH HOME TMPDIR LANG TERM USER LOGNAME LIVE)) {
        $IN{$k} = $ENV{"SPIKE_IN_$k"} if exists $ENV{"SPIKE_IN_$k"};
    }
    %ENV = ();
    return usage('runner.pl <subcommand> ...') unless defined $sub;
    # Fail closed: without a usable compliance/denylist.txt no operation of this helper runs.
    unless (denylist_ok()) { msg(DENY_FAIL_MSG); return DENY_FAIL_RC; }
    return cmd_resolve(@a)    if $sub eq 'resolve';
    return cmd_clihome(@a)    if $sub eq 'clihome';
    return cmd_clihome_new(@a) if $sub eq 'clihome-new';
    return cmd_tool_path(@a)  if $sub eq 'tool-path';
    return cmd_gate(@a)       if $sub eq 'gate';
    return cmd_run(@a)        if $sub eq 'run';
    return cmd_run_split(@a)  if $sub eq 'run-split';
    return cmd_register(@a)   if $sub eq 'register';
    return cmd_vdir_create(@a) if $sub eq 'vdir-create';
    return cmd_vdir_sweep(@a) if $sub eq 'vdir-sweep';
    return cmd_vdir_remove(@a) if $sub eq 'vdir-remove';
    return usage("unknown subcommand: $sub");
}

# Loaded with require (by a test), the file only defines its functions. Run as a script, it runs the subcommand.
exit(main(@ARGV)) unless caller;
1;
