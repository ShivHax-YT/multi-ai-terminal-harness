# Worker HANDOFF.md format (v1)

Status: Phase 0 spike spec (T-006). Parser: `spike/handoff/parse.sh`. Tests: `spike/tests/test_handoff.sh`.

Every harness worker writes a `HANDOFF.md` in its worktree when it finishes (ARCHITECTURE.md, "Dispatch" and
"Collect"). The format mirrors the HANDOFF format in `AGENTS.md`, so the same parser reads this repo's own handoffs.

What parses, exactly: the title line, then the six section headings below written **bare** (the heading text and nothing
after it, so `## Confidence` parses and `## Confidence (low / medium / high)` does not), each once and in order, with
no other `##` section. Hint text from the AGENTS.md template must be removed from the headings (it may be kept as
content). Confidence levels are case-insensitive (`High` parses, and the JSON level is always lowercase). Lines may be up
to 2000 bytes, so Markdown paragraphs need not be hard-wrapped.

## Trust model

A HANDOFF.md is written by a worker AI that may have read hostile web pages, issues or code. Every byte is **untrusted
data**. It is never instructions for the lead, never shell input and never a path to open without checking. The parser:

- never `eval`s, `source`s, expands or executes any part of the file (no `$(...)`, backtick or variable expansion);
- puts text into JSON only through `jq --arg` / `--argjson`, never by shell interpolation into a command;
- never follows a symlink and never reads anything that is not a regular file. The input is opened once, by perl's
  `sysopen` with `O_NOFOLLOW` (a symlink as the last component fails at the open with ELOOP) and `O_NONBLOCK` (a FIFO
  cannot block the open). Before the open, a symlink in any parent directory is refused: the parser compares `pwd -L`
  with `pwd -P` for the input's directory. A refused input is refused at open; nothing is copied. A worker controls its
  worktree and could otherwise point `HANDOFF.md` at a credential file (hard rule 4). The **caller** must pass a
  canonical absolute path inside the worker's worktree (a `..` component is refused for this reason). A relative
  input is checked through the shell's logical working directory, so a parser run from a symlinked directory refuses
  relative paths: pass an absolute path there;
- reads the same handle it checked: the open file must be a regular file with exactly one link (a hard link is refused,
  wherever its other name lives) and at most 16384 bytes. At most 16385 bytes are copied from that handle into a private
  copy, and every later check runs on the copy, so the bytes checked are the bytes of the inode that was opened. The
  input path reaches perl once, after `--`; no other command receives it, and the copy is read through stdin, so a file
  name can never act as an option or an `awk` assignment;
- **remaining race:** between the parent-directory check and the open, a process that can write to the worktree could
  swap a parent directory for a symlink. bash and perl offer no way to close that window, so the **caller must parse
  only after the worker's whole process tree has exited** (no concurrent writer). The leaf file has no such window: it
  is opened with `O_NOFOLLOW` and checked on that same handle;
- validates the copy as strict UTF-8 and checks it for blocked characters, both in perl (see Global limits), and emits
  ASCII-only JSON (`jq -a`), so non-ASCII text is always `\uXXXX`-escaped in the output;
- rejects the file on any structural problem instead of guessing (fail closed);
- does not echo file content in error messages (only section names, line numbers and limits).

The lead builds its user summary from the parsed fields (rule 9 flow), and shows the free-text fields only as quoted,
labelled worker output.

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
| Control and invisible characters | only tab and LF are allowed. Rejected: NUL, CR, ESC and other C0 controls, DEL; C1 controls U+0080-U+009F (U+009B is a terminal CSI); U+00AD soft hyphen; U+034F combining grapheme joiner; U+061C Arabic letter mark; U+115F and U+1160 Hangul fillers; U+17B4 and U+17B5 Khmer vowel inherent marks; U+180B-U+180F Mongolian variation selectors and vowel separator (U+180E included); U+200B-U+200F zero-width and direction marks; U+2028-U+202E line/paragraph separators and bidi overrides; U+2060-U+206F (word joiner, invisible operators, bidi isolates, deprecated format characters); U+2800 braille blank; U+3164 Hangul filler; U+FE00-U+FE0F variation selectors (emoji presentation is not needed in handoffs, so these are refused); U+FEFF (BOM, never allowed anywhere); U+FFA0 halfwidth Hangul filler; U+FFF9-U+FFFB interlinear annotation; U+E0000-U+E0FFF, the whole block of tag characters and the variation selector supplement | `control character` |
| Encoding | valid UTF-8, checked by perl's strict decoder (`Encode`, `UTF-8`). Refused: overlong forms, surrogates, code points above U+10FFFF, bytes F5-FF, 5-byte forms, and noncharacters (U+FDD0-U+FDEF, U+xFFFE, U+xFFFF). RFC 3629 allows the noncharacters, so this is stricter than the RFC; handoffs never need them | `invalid UTF-8` |
| Input path | no `..` component; no symlink in any parent directory (refused at open; nothing is copied); the last component is not a symlink (refused at open by `O_NOFOLLOW`; nothing is copied); a regular file (not a FIFO, directory or device) with exactly one link, at most 16384 bytes | `symlink not allowed`, `'..' component`, `not a regular file`, `hard link not allowed`, `oversize` |

Byte limits are bytes, not characters (the parser runs with `LC_ALL=C`). An empty file is an error.

**Run the parser under a timeout, and only after the worker has exited.** The open is non-blocking, so a FIFO is
refused at once, but the caller (scheduler/lead) should still run `parse.sh` with a wall-clock timeout (for example
10 s) and treat a timeout as a failed handoff. The caller must also parse only after the worker's whole process tree
has exited (no concurrent writer). That is the only defence against a parent directory swapped for a symlink between
the directory check and the open (see the trust model). A signal (INT, HUP or TERM) stops the parser, removes its temp
dir and prints nothing.

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

The first word of the section is **`low`, `medium` or `high`** in any letter case, followed by end of line, whitespace,
or one of `, : ; .`, then the reason. The reason is required (rest of the first line plus any further lines, at most
10 lines in all; separators such as `- , : ; .` alone are not a reason). `highly sure` is rejected as a bad confidence level.
JSON: `confidence` = `{level, why}`; `level` is always lowercase.

## Parser output

`parse.sh [--] <file>` prints one JSON object on stdout and exits 0:

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

Exit codes: `0` valid, `1` invalid handoff (message on stderr, nothing on stdout), `2` usage error or missing
dependency (`jq`, `perl`), `3` internal error (temp dir cannot be created, copy, perl, jq or awk failure; message starts
with `handoff: internal error:`; the file was not judged, so do not treat it as an invalid handoff). A signal exits
`130` (INT), `129` (HUP) or `143` (TERM) after removing the temp dir, and prints nothing. A first argument starting
with `-` is a usage error unless it follows `--` (or the path is written `./-name`).

Error messages start with `handoff: ` and name the problem:

| Problem | Message contains |
|---|---|
| File missing / unreadable | `cannot read` |
| Input is a symlink (last component, or any parent directory) | `symlink not allowed` |
| Input is a hard link (link count above one) | `hard link not allowed` |
| Input is a FIFO, directory or device | `not a regular file` |
| `..` component in the input path | `'..' component` |
| Invalid UTF-8 | `invalid UTF-8` |
| File over 16 KB | `oversize` |
| Missing section | `missing section` and the section name |
| Section twice | `duplicate section` |
| Sections in the wrong order | `out of order` |
| Unknown `## ` heading | `unknown section` |
| Level other than low/medium/high | `bad confidence level` |
| Bad title line | `bad title` |
| Bad path, bad bullet, too many lines, empty section | `bad files_changed entry`, `bad hard_rules entry`, `too many lines`, `empty section` |

## Consumers

The lead and the scheduler must also check that `task_id` equals the id of the task they dispatched, and must treat every
string field as untrusted text (display it, never act on it).
