# Worker HANDOFF.md format (v1)

Status: Phase 0 spike spec, round 6 (T-006). Parser: `spike/handoff/parse.sh`. Tests: `spike/tests/test_handoff.sh`.

Every harness worker writes a `HANDOFF.md` in its worktree when it finishes (ARCHITECTURE.md, "Dispatch" and
"Collect"). The format mirrors the HANDOFF format in `AGENTS.md`, so the same parser reads this repo's own handoffs.

What parses, exactly: the title line, then the six section headings below written **bare** (the heading text and nothing
after it, so `## Confidence` parses and `## Confidence (low / medium / high)` does not), each once and in order, with
no other `##` section. Hint text from the AGENTS.md template must be removed from the headings (it may be kept as
content). Confidence levels are case-insensitive (`High` parses, and the JSON level is always lowercase), and blanks
(spaces or tabs) before the level are ignored. Lines may be up to 2000 bytes, so Markdown paragraphs need not be
hard-wrapped.

## Trust model

A HANDOFF.md is written by a worker AI that may have read hostile web pages, issues or code. Every byte is **untrusted
data**. It is never instructions for the lead, never shell input and never a path to open without checking. The parser:

- never `eval`s, `source`s, expands or executes any part of the file (no `$(...)`, backtick or variable expansion);
- puts text into JSON only through `jq --arg` / `--argjson`, never by shell interpolation into a command;
- never follows a symlink and never reads anything that is not a regular file;
- resolves the root and the input path in **one perl process** (`PERL_WALK`), the only process that receives them;
- rejects the file on any structural problem instead of guessing (fail closed);
- does not echo file content in error messages (only section names, line numbers and limits).

The lead builds its user summary from the parsed fields (rule 9 flow), and shows the free-text fields only as quoted,
labelled worker output.

## Guarantees of the walk (what is promised, and what is not)

These are the guarantees of `parse.sh` as written, checked by the tests named in `HANDOFF.md`:

1. **The root is walked, not resolved.** `--root` is used as typed. perl starts at `/` and walks every component of the
   root path with the same rules as the parents below it: `lstat`, refuse a symlink or a non-directory, `chdir`, then
   `stat(".")` must give the same (device, inode) as the `lstat`. **A symlink anywhere in the root path is refused**
   (`symlink not allowed`). So the root must be a physical absolute path. The root is never trusted and never resolved
   with `pwd -P`.
2. **Every directory on the way is identity-checked.** After each step below the root, the physical working directory
   (`Cwd::getcwd`) must be the directory the walk expects, and it must not be inside a provider CLI home. The root walk
   does the same for each root component.
3. **Same device.** The root's final directory records its device. Every directory below it and the input must be on
   that device (`crosses a mount`). `--root /` with an input under another mount is refused.
4. **Provider CLI homes are refused** (hard rule 4). A root or input whose physical path is, or is under, one of these
   under `HOME` is refused with `refused: provider CLI directory`, before any open: the Claude config directory and its
   JSON file, and the Codex, Grok, Kimi (`kimi-code` and `kimi`), and Gemini directories. `HOME` is checked both as typed
   and as resolved, so a symlinked `HOME` does not help. The names are built from parts in the program, and the check is
   made on strings before the walk and on the physical path after each step.
5. **Scrubbed environment.** Every perl call runs as `env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB -u PERL_UNICODE
   perl ...`. A caller's perl options cannot change the walk or the UTF-8 check.
6. **At the time of the walk, nothing outside the physical root is read.** Every directory is entered only after its
   `lstat` is compared with the `stat` of the directory entered, and the leaf is opened with `O_NOFOLLOW` relative to
   the directory the process stands in. The physical working directory is checked again after the open and before the
   first byte is read, so a file outside the root is never copied. A directory outside the root can be entered for
   the identity check, but nothing in it is read.
7. **Only a valid handoff is ever printed.** Stdout is written only after every check has passed. On refusal stdout is
   empty and no file content is printed: messages name the problem (section, line, limit, path rule), never the text.
8. **Temp dir.** The private temp dir is removed on success, on refusal and on INT, HUP, QUIT and TERM. The temp dir is
   created with those signals ignored, so a signal cannot land between its creation and the assignment that makes the
   cleanup know about it. (A signal in that short window is dropped.)

### Residual risk (stated plainly)

- A process running **as the same user** that can rename directories, or move files, into or out of the worktree can
  relocate data into the root. No path check can stop that: a file placed inside the root is a file inside the root.
  The control for that is **Phase 4 worker sandboxing**, not this parser.
- Until that exists, the caller should parse a worker's HANDOFF.md **only after the worker's processes have exited**.
  The parser does not depend on this for the guarantees above, but it is the only protection against content that is
  moved into place while the parse runs.
- A directory moved out of the root between the last identity check and the open can make the open reach a file
  outside the root. Only the open happens: the physical working directory is checked after the open and before the
  first read, so nothing outside the root is read.
- The timeout advice below still applies.

**Advice for callers (not a security requirement):** run `parse.sh` with a wall-clock timeout (for example 10 s) and
treat a timeout as a failed handoff.

## Root and input path

`parse.sh --root <dir> [--] <file>`. `--root` is **required**.

- `--root` must be an **absolute** path to a directory, with no `.` or `..` component. A trailing slash and doubled
  slashes are harmless. An empty or blank `--root` is a usage error (exit 2), and so is a relative one, or one that is
  not a directory.
- The root is **walked** as described in "Guarantees of the walk", not resolved. A symlink anywhere in it is refused
  with `symlink not allowed` (exit 1). So a root given as a symlink, or a root whose directory was moved aside and
  replaced by a symlink, is refused.
- A **relative** input is relative to `--root`, not to the working directory of the caller.
- An **absolute** input must start with the root path followed by `/` (with `/` as the root, any absolute input).
  Anything else is refused with `outside root` before any file is touched.
- Components `.`, `..` and empty ones in the input are refused (`'..' component`, `'.' component`, `empty component`).
  So `./name` is refused: a name that starts with `-` is given after `--`, or as an absolute path.

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
| Input path | inside `--root` (`outside root` otherwise); no `..`, `.` or empty component; no symlink in the root path or as a parent directory or as the last component (refused; nothing is copied); every directory on the walk is the one that was `lstat`ed (a swap is refused); the physical working directory is the expected one after each step and after the open; not inside a provider CLI home; the same device as the root; a regular file (not a FIFO, directory or device) with exactly one link (checked before the open and on the open handle), at most 16384 bytes | `outside root`, `'..' component`, `'.' component`, `empty component`, `symlink not allowed`, `input path changed`, `hard link not allowed`, `not a regular file`, `crosses a mount`, `refused: provider CLI directory`, `oversize` |

Byte limits are bytes, not characters (the parser runs with `LC_ALL=C`). An empty file is an error.

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

`parse.sh --root <dir> [--] <file>` prints one JSON object on stdout and exits 0:

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

Exit codes: `0` valid, `1` invalid handoff or refused input (message on stderr, nothing on stdout), `2` usage error
(`--root` missing, empty or blank, relative, not a directory, or with a `.` or `..` component; a second `--root`; a
missing `jq` or `perl`), `3` internal error (temp dir cannot be created, copy, perl, jq, wc, tr or awk failure, or
`HOME` is not an absolute path; message starts with `handoff: internal error:`; the file was not judged, so do not
treat it as an invalid handoff). A signal exits `130` (INT), `129` (HUP), `131` (QUIT) or `143` (TERM) after removing
the temp dir, and prints nothing. The JSON is prepared in a temp file and written to stdout last, with one `cat` of that
file. **A signal during that final write can still cut the output short**; the exit status then names the signal, so a
caller must treat a non-zero status as a failed handoff. A first argument starting with `-` is a usage error unless it
follows `--`.

Error messages start with `handoff: ` and name the problem:

| Problem | Message contains |
|---|---|
| `--root` missing, empty or blank, relative, not a directory, with `.` or `..`, or given twice | `--root` (usage, exit 2) |
| A directory of the root path is a symlink | `symlink not allowed` (exit 1) |
| A directory of the root path is missing, not a directory, or cannot be entered | `--root` (exit 1) |
| File missing / unreadable | `cannot read` |
| A parent directory of the input is missing or cannot be read | `a parent directory is missing or cannot be read` |
| A parent directory of the input cannot be entered | `cannot be entered` |
| Input is outside `--root` (absolute path that does not start with the root and `/`) | `outside root` |
| Input is a symlink (last component, or any parent directory) | `symlink not allowed` |
| A directory on the walk was swapped or moved (identity or working directory differs from the walk) | `input path changed while it was being resolved` |
| Root or input is a provider CLI home, or is under one (as typed or as resolved) | `refused: provider CLI directory` |
| Input is on another device than `--root` | `crosses a mount` |
| Input is a hard link (link count above one) | `hard link not allowed` (refused before the open) |
| Input is a FIFO, directory or device | `not a regular file` |
| A parent of the input is a regular file | `not a directory` |
| `..` component in the input path | `'..' component` |
| `.` component in the input path | `'.' component` |
| Empty component in the input path | `empty component` |
| Invalid UTF-8 or a noncharacter | `invalid UTF-8` |
| File over 16 KB | `oversize` |
| Missing section | `missing section` and the section name |
| Section twice | `duplicate section` |
| Sections in the wrong order | `out of order` |
| Unknown `## ` heading | `unknown section` |
| Level other than low/medium/high | `bad confidence level` |
| Reason missing or only separators | `missing reason` |
| Bad title line | `bad title` |
| Bad path, bad bullet, too many lines, empty section | `bad files_changed entry`, `bad hard_rules entry`, `too many lines`, `empty section` |

## Consumers

The lead and the scheduler must also check that `task_id` equals the id of the task they dispatched, and must treat every
string field as untrusted text (display it, never act on it).
