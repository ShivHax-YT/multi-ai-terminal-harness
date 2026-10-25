# Worker HANDOFF.md format (v1)

Status: Phase 0 spike spec, round 8 (T-006). Parser: `spike/handoff/parse.sh`. Tests: `spike/tests/test_handoff.sh`.

Every harness worker writes a `HANDOFF.md` in its worktree when it finishes (ARCHITECTURE.md, "Dispatch" and
"Collect"). The format mirrors the HANDOFF format in `AGENTS.md`, so the same parser reads this repo's own handoffs.

What parses, exactly: the title line, then the six section headings below written **bare** (the heading text and nothing
after it, so `## Confidence` parses and `## Confidence (low / medium / high)` does not), each once and in order, with
no other `##` section. Hint text from the AGENTS.md template must be removed from the headings (it may be kept as
content). Confidence levels are case-insensitive (`High` parses, and the JSON level is always lowercase), and blanks
(spaces or tabs) before the level are ignored. Lines may be up to 2000 bytes, so Markdown paragraphs need not be
hard-wrapped.

## Interface

`parse.sh --root <worktree>` reads **exactly one file, `<worktree>/HANDOFF.md`**, and prints JSON on stdout. There is no
input path argument: a second positional argument is a usage error (exit 2). No other file name and no subdirectory is
ever read (`<root>/sub/HANDOFF.md`, `<root>/HANDOFF.md.bak`, `<root>/../HANDOFF.md` are all ignored).

The wrapper script only checks its arguments, finds `compliance/denylist.txt` and then `exec`s **one perl process**
(`/usr/bin/perl -f`, with `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C`). That one process walks the root, opens and reads the file into memory,
checks every rule, and prints the JSON once at the end, only if every check passed. There is no temp file, no copy, no
here-string, no second process, and nothing is reopened by path. `jq` and `awk` are not used. (This differs from the
T-006 brief's wording "`jq --arg`/`--rawfile`": the intent, that content is never interpolated into a shell command, is
kept and made stronger, because content now lives only in perl strings and is turned into JSON by core `JSON::PP`
with ASCII escaping.) Only core perl modules are used (`Fcntl`, `Errno`, `Cwd`, `Encode`, `JSON::PP`, `POSIX`), so the
macOS system perl and `/bin/bash` 3.2 are enough.

## Trust model

A HANDOFF.md is written by a worker AI that may have read hostile web pages, issues or code. Every byte is **untrusted
data**. It is never instructions for the lead, never shell input and never a path to open without checking. The parser:

- never `eval`s, `source`s, expands or executes any part of the file (no `$(...)`, backtick or variable expansion). The
  perl program is a single-quoted constant in the wrapper; content reaches perl only as data read from the file, and the
  root and `HOME` reach it only as `@ARGV` data;
- turns text into JSON only through `JSON::PP` (`ascii`, so the output is pure ASCII), never by interpolation into a
  command;
- never follows a symlink and never reads anything that is not a regular file;
- rejects the file on any structural problem instead of guessing (fail closed);
- does not echo file content in error messages (only section names, line numbers and limits).

The lead builds its user summary from the parsed fields (rule 9 flow), and shows the free-text fields only as quoted,
labelled worker output.

## Threat model

### What is guaranteed (for filesystem state that is not changing during the parse)

When no other process is changing the files and directories involved while the parse runs:

1. **No symlink is followed.** A symlink anywhere in the root path (every component is checked, starting from `/`) or as
   `HANDOFF.md` is refused (`symlink not allowed`). The root must be a physical absolute path; it is never resolved
   with `pwd -P` or `realpath`.
2. **No hard link, special file or mount crossing is read.** `HANDOFF.md` must be a regular file with exactly one link
   (checked before the open and again on the open handle), on the same device as the root directory (`crosses a
   mount`). A FIFO, directory or device is refused without blocking (the open uses `O_NONBLOCK`).
3. **No provider CLI home is entered or read** (hard rule 4). The CLI home names come from one file,
   **`compliance/denylist.txt`** (one entry per line, relative to the account home; `#` comments and blank lines are
   ignored; every entry must match `^\.[A-Za-z0-9._-]+$` and not be only dots). The wrapper finds it from the script's own
   physical directory (two levels up; a symbolic link to `parse.sh` is refused) and passes the absolute path to perl, which
   opens it with `O_NOFOLLOW`, requires a regular file of 1 to 65536 bytes and reads it **at run time**. A file that is
   missing, empty, without an entry or malformed is an internal error (exit 3, one fixed message, nothing is read): the
   parser fails closed. The homes are found by **identity**: the parser computes the account home from the account database
   (`getpwuid`) and also takes `HOME` (if it is an absolute path), `stat`s every denylist entry under both, and compares the
   (device, inode) of **every directory of the walk** and of the file against them. A directory whose `lstat` identity is a CLI
   home is refused with `refused: provider CLI directory` **before the `chdir` into it** (the check is made again after the
   `chdir`), so a CLI home is never entered. Because this is by identity, case changes on a case-insensitive filesystem,
   symlinked `HOME`, a wrong `HOME`, and a **bind mount of the home itself** at another path do not help (that last case
   needs mount privilege to set up and is tested where the privilege exists). A CLI JSON file that is bind-mounted onto
   `HANDOFF.md` of an ordinary root on the same device is refused by the same identity check on the leaf (tested where mount
   is permitted). `HOME` is only an extra source of candidate homes and is never trusted as the only one. If no home at all
   is known the check cannot be made and the parser stops with an internal error (exit 3).
4. **The bytes validated are the bytes of the inode that was checked.** The file is `lstat`ed, opened once with
   `O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_NOCTTY`, `fstat`ed (the handle must be the regular, single-link inode that the
   `lstat` saw), and read from that handle into memory. All checks run on that memory.
5. **Only a fully valid handoff is printed.** Stdout is written once, at the very end, after every check has passed. On
   refusal stdout is empty and no file content is printed: messages name the problem (section, line, limit, path rule),
   never the text.
6. **The caller's perl environment cannot change the parser.** `env -i` removes `PERL5LIB`, `PERL5OPT`, `PERLLIB`,
   `PERL5DB`, `PERL_UNICODE`, `PERL_USE_UNSAFE_INC` and every other variable; `perl` and `env` are called by absolute
   path; `perl -f` skips `sitecustomize.pl` (a no-op on a perl built without it); the program drops relative and hook
   entries from `@INC` before it loads any module. `HOME` and the denylist path are passed only as data. The wrapper's own
   bash starts in privileged mode (`#!/bin/bash -p`) when executed directly, so `BASH_ENV`, `ENV` and exported functions
   do not reach it; a caller that runs `bash parse.sh` bypasses the shebang (see the precondition).
7. **Nothing is written anywhere.** No temp file, no output file, no directory is created, and nothing is left behind
   on success, refusal or signal.

The walk is also hardened against a path that changes under it (each directory is entered only after its `lstat`, the
`stat` of the directory entered must give the same (device, inode), and `getcwd` must return the expected physical path
after every step and after the open), and the handle is `fstat`ed again after the read. These are **defence in depth for
accidents and for a lost race, not a guarantee against an attacker who can race the parser** (see below). In the same
class: the `fstat` checks on the open handle (type, link count, identity against the `lstat`, size), the consistency check
after the read, the CLI check after the `chdir` and the `getcwd` check after the leaf checks. The test suite shows that
they are reachable, but removing any one of them does not fail a test, because an earlier check already refuses the same
input when nothing races.

### Precondition for the caller (the scheduler)

The parser assumes that nothing is changing the worktree. The caller must enforce this **before** it parses:
**all of the worker's processes have exited**, been killed if needed, and **been reaped**. That means every process, not
only the process group: a descendant that called `setsid` (or `setpgid`) left the group and is still a process of the same user
that can race the parser. Only then call `parse.sh --root <worktree>`. Execute `parse.sh` directly (not as `bash parse.sh`),
so that its `#!/bin/bash -p` shebang applies (privileged mode: `BASH_ENV`, `ENV` and exported functions are not imported;
accepted by bash 3.2 on macOS). The advice to run the parser under a wall-clock timeout (for example 10 s) and to treat a
timeout as a failed handoff still applies, but it is not a security control.

### Out of scope, stated plainly

- **A concurrent process running as the same user** (for example a worker process that is still alive). It can race the
  parser by renaming or replacing directories and files, and it could even ptrace it. A program running as the same user
  cannot defend against another process of the same user; no check in a parser can. The control for this is **Phase 4
  worker sandboxing** (the worker cannot touch the parser or the files it parses), plus the precondition above. Earlier
  rounds claimed to close races by path checks; that claim is withdrawn.
- **Anything that needs mount privilege** (root, or a setup done before the parse) is out of scope, in the same class as
  the same-user process. Two cases the identity check cannot see, named so nobody assumes otherwise:
  (a) a **bind mount of an outside file onto `HANDOFF.md`** on the same filesystem as the root (a single-link regular file
  on the root's device that is not a CLI file looks like any other `HANDOFF.md`; a file on another device is refused as
  `crosses a mount`, and a CLI JSON file in the denylist is refused by identity);
  (b) a **bind mount of a subdirectory of a CLI home** (or of a file inside one) at another path: only the CLI home
  directory itself and the denylisted files are known by identity, so a subdirectory or an inner file at a new path is not
  recognised. Reaching them by their normal path is refused, because the walk passes through the CLI home.
- Content that a still-running worker places inside the root: a file inside the root is a file inside the root.
- Case-insensitive filesystems: the root is compared with the physical path that `getcwd` reports, so a root typed with
  different letter case than the one on disk is refused (fails closed). Give the exact physical path.

## Root

`--root` must be an **absolute** path to a directory with no `.` or `..` component, shorter than `PATH_MAX` (4096 on
Linux, 1024 on macOS). A trailing slash and doubled slashes are harmless.

- The root is **walked, not resolved**: perl starts at `/` and, for every component, does `lstat`, refuses a symlink or
  a non-directory, `chdir`, then requires `stat(".")` to give the same (device, inode) as the `lstat`, the physical
  working directory (`getcwd`) to be the expected path, and the directory not to be a CLI home (by identity).
- An empty or blank root, a relative one, one with a `.` or `..` component, one at or above `PATH_MAX`
  (`--root is longer than PATH_MAX (N bytes)`), one that does not exist or is not a directory: usage error (exit 2).
- A symlink anywhere in the root path: refused (`symlink not allowed`, exit 1). A directory that cannot be entered:
  refused (exit 1).
- `--root /` is valid (and finds no `HANDOFF.md` there in practice).
- The walk may cross a mount on the way to the root (`/tmp` is often its own mount); what is refused is a `HANDOFF.md`
  that is on another device than the root directory.

## File layout

Plain UTF-8 text, LF line endings. The sections appear **exactly once each, in exactly this order**:

```
# HANDOFF T-006
## Summary
## Files changed
## Tests run
## Hard rules touched
## Open risks / questions
## Confidence
```

- The file is UTF-8. Invalid UTF-8 is rejected (`invalid UTF-8`), not repaired.
- Line 1 is `# HANDOFF T-NNN` where `NNN` is 3 to 6 digits. Nothing may come before it.
- Between the title and `## Summary` only blank lines are allowed.
- Section headings are matched exactly (the text after `## `, trailing spaces ignored). Any other line starting with
  `## ` is an error (unknown section), and so is any other line starting with `# ` (second title).
  `###` and deeper headings are ordinary content.
- Headings inside a fenced code block (a line starting with three backticks opens and closes the fence) are content, not
  structure. A fence still open at the end of the file is an error.
- Leading and trailing blank lines of every section are ignored. Every section must have content. A line holding only
  whitespace and no-break spaces (U+00A0) counts as blank.

## Global limits

| Limit | Value | Error text contains |
|---|---|---|
| Whole file | 16384 bytes (16 KB) | `oversize` |
| Any line | 2000 bytes | `line too long` |
| Control and invisible characters | only tab and LF are allowed. Rejected: NUL, CR, ESC and other C0 controls, DEL; C1 controls U+0080-U+009F (U+009B is a terminal CSI); U+00AD soft hyphen; U+034F combining grapheme joiner; U+0600-U+0605 Arabic number signs; U+061C Arabic letter mark; U+06DD Arabic end of ayah; U+070F Syriac abbreviation mark; U+0890-U+0891 Arabic pound marks; U+08E2 Arabic disputed end of ayah; U+115F and U+1160 Hangul fillers; U+17B4 and U+17B5 Khmer vowel inherent marks; U+180B-U+180F Mongolian variation selectors and vowel separator (U+180E included); U+200B-U+200F zero-width and direction marks; U+2028-U+202E line/paragraph separators and bidi overrides; U+2060-U+206F (word joiner, invisible operators, bidi isolates, deprecated format characters); U+2800 braille blank; U+3164 Hangul filler; U+FE00-U+FE0F variation selectors (emoji presentation is not needed in handoffs, so these are refused); U+FEFF (BOM, never allowed anywhere); U+FFA0 halfwidth Hangul filler; U+FFF9-U+FFFB interlinear annotation; U+110BD and U+110CD Kaithi number signs; U+13430-U+1343F Egyptian hieroglyph format controls; U+1BCA0-U+1BCA3 shorthand format controls; U+1D173-U+1D17A musical symbol beam and tie controls; U+E0000-U+E0FFF, the whole block of tag characters and the variation selector supplement. **Plus every character of Unicode category Cf** (perl's `\p{Cf}`, which tracks the Unicode version of the perl that runs the check). The explicit list is the floor, so a listed character is refused whatever the perl's Unicode version is | `control character` |
| Encoding | valid UTF-8, checked by perl's strict decoder (`Encode`, `UTF-8`). Refused: overlong forms, surrogates, code points above U+10FFFF, bytes F5-FF, 5-byte forms. **Noncharacters** are refused by an explicit expression for every plane, independent of the decoder: U+FDD0-U+FDEF, and U+FFFE, U+FFFF and the same two in each of planes 1 to 16 (U+1FFFE, U+1FFFF, ..., U+10FFFE, U+10FFFF). RFC 3629 allows the noncharacters, so this is stricter than the RFC; handoffs never need them | `invalid UTF-8` |
| `HANDOFF.md` | a regular file (not a symlink, FIFO, directory or device) with exactly one link (checked before the open and on the open handle), on the same device as the root directory, not a CLI home file (by identity), at most 16384 bytes | `symlink not allowed`, `not a regular file`, `hard link not allowed`, `crosses a mount`, `refused: provider CLI directory`, `oversize`, `input changed` |

Byte limits are bytes, not characters (the parser runs with `LC_ALL=C` and counts bytes). An empty file is an error. The
order of the whole-file checks is: size, empty, NUL, UTF-8, noncharacters, control characters, line length; then the
structure.

## Sections

### Summary

What changed and why. 1 to 5 lines (interior blank lines count). Free text, any characters.
JSON: `summary` (string, lines joined with `\n`).

### Files changed

One bullet per file: `- <path> - <note>`. The note is optional (`- <path>`), one line, free text.

- `<path>` is relative to the worktree root, with characters from `A-Z a-z 0-9 _ . / @ + = , ( ) [ ]` and `-`, at most
  256 bytes, no leading `/`, **its first character is not `-`** (a `-` inside or at the start of a later component such
  as `a/-b` is fine), and no `..` component. These limits make the path safe to pass on as data; the lead must
  still check that it is inside the worker's owned files.
- The path and the note are separated by the first ` - ` (space, hyphen, space).
- Blank lines between bullets are allowed and ignored. At most 100 entries (blank lines are not counted). A section with no changes contains the single line `none` (any case) and parses to `[]`.

JSON: `files_changed` (array of `{path, note}`, `note` is `""` when omitted).

### Tests run

Command and result, free text, 1 to 60 lines.
JSON: `tests_run` (string, lines joined with `\n`).

### Hard rules touched

One bullet per rule: `- <rule number(s)> - <test that proves it>`. Free text after `- `. Every non-blank line must start
with `- `, and blank lines between bullets are allowed and ignored. At most 20 entries (blank lines are not counted). No rules touched: the single line `none` (any case), parsed to `[]`.
JSON: `hard_rules` (array of strings, the text after `- `).

### Open risks / questions

Free text, 1 to 60 lines. Write `None` if there are none.
JSON: `risks` (string, lines joined with `\n`).

### Confidence

The first word of the section is **`low`, `medium` or `high`** in any letter case, after any leading spaces or tabs,
followed by end of line, whitespace, or one of `, : ; .`, then the reason. The reason is required: the rest of the first
line plus any further lines, at most 10 lines in all. A reason made only of separators and blanks is no reason, on the
level line or on any line after it (`high` then `- .`, `high` then `;`, `high, -.;:` and `high` then `-  ,` are all
refused as `missing reason`).
`highly sure` is rejected as a bad confidence level.
JSON: `confidence` = `{level, why}`; `level` is always lowercase.

## Parser output

`parse.sh --root <dir>` prints one JSON object on one line on stdout and exits 0 (shown here with line breaks):

```json
{
  "task_id": "T-006",
  "summary": "...",
  "files_changed": [{"path": "docs/spec/handoff.md", "note": "format spec"}],
  "tests_run": "...",
  "hard_rules": ["Security - injection fixture test"],
  "risks": "...",
  "confidence": {"level": "high", "why": "..."}
}
```

The output is pure ASCII (`JSON::PP` with `ascii`, so non-ASCII characters are `\uXXXX` escapes, with surrogate pairs
above U+FFFF). It is built in memory and written once at the end.

Exit codes: `0` valid; `1` invalid handoff or refused input (message on stderr, nothing on stdout); `2` usage error
(wrong arguments, including a second positional argument, a second `--root`, an unknown option or a missing value; a
`--root` that is empty, blank, relative, at or above `PATH_MAX`, has a `.` or `..` component, does not exist or is not
a directory; `/usr/bin/perl` missing); `3` internal error (no home directory is known so the CLI home check cannot be
made; `compliance/denylist.txt` is missing, empty or malformed, or `parse.sh` was started through a symbolic link; a read or
write failure, or any unexpected perl failure; the message starts with `handoff: internal error:`; the
file was not judged, so do not treat it as an invalid handoff). A signal ends the process with the usual signal status
and, because stdout is written once at the end, normally prints nothing; **a signal during that final write can still
cut the output short**, so a caller must treat a non-zero status as a failed handoff.

Error messages start with `handoff: ` and name the problem:

| Problem | Message contains |
|---|---|
| Wrong arguments (usage) | `usage:` or `--root` (exit 2) |
| `--root` empty, blank, relative, with `.` or `..`, not a directory | `--root` (exit 2) |
| `--root` at or above `PATH_MAX` | `PATH_MAX` (exit 2) |
| A directory of the root path is a symlink | `symlink not allowed` (exit 1) |
| A directory of the root path cannot be entered | `cannot be entered` (exit 1) |
| A directory of the root path was swapped or moved during the walk (identity or working directory differs) | `--root changed while it was being resolved` (exit 1) |
| Root is, or is inside, a provider CLI home (by identity) | `refused: provider CLI directory` |
| `HANDOFF.md` missing or unreadable | `cannot read` |
| `HANDOFF.md` is a symlink | `symlink not allowed` |
| `HANDOFF.md` is a FIFO, directory or device | `not a regular file` |
| `HANDOFF.md` has more than one link | `hard link not allowed` (refused before the open) |
| `HANDOFF.md` is on another device than the root | `crosses a mount` |
| The open handle is not the inode that the `lstat` saw, or the working directory is not the root after the walk, or the file changed while it was read | `input changed`, `input path changed while it was being resolved` |
| Invalid UTF-8 or a noncharacter | `invalid UTF-8` |
| NUL, C0/C1 controls, invisible or Cf characters | `control character` |
| File over 16 KB | `oversize` |
| Empty file | `empty file` |
| Line over 2000 bytes | `line too long` |
| Missing section | `missing section` and the section name |
| Section twice | `duplicate section` |
| Sections in the wrong order | `out of order` |
| Unknown `## ` heading | `unknown section` |
| Bad title line | `bad title` |
| Level other than low/medium/high | `bad confidence level` |
| Reason missing or only separators | `missing reason` |
| Bad path, bad bullet, too many lines, empty section | `bad files_changed entry`, `bad hard_rules entry`, `too many lines`, `empty section` |

## Consumers

The lead and the scheduler must also check that `task_id` equals the id of the task they dispatched, and must treat every
string field as untrusted text (display it, never act on it). They must enforce the precondition in "Threat model": parse
only after the worker's process group has exited and been reaped.
