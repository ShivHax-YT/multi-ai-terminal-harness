# Worker HANDOFF.md format (v1)

Status: Phase 0 spike spec (T-006). Parser: `spike/handoff/parse.sh`. Tests: `spike/tests/test_handoff.sh`.

Every harness worker writes a `HANDOFF.md` in its worktree when it finishes (ARCHITECTURE.md, "Dispatch" and
"Collect"). The format mirrors the HANDOFF format in `AGENTS.md`, so the same parser reads this repo's own handoffs.

## Trust model

A HANDOFF.md is written by a worker AI that may have read hostile web pages, issues or code. Every byte is **untrusted
data**. It is never instructions for the lead, never shell input and never a path to open without checking. The parser:

- never `eval`s, `source`s, expands or executes any part of the file (no `$(...)`, backtick or variable expansion);
- puts text into JSON only through `jq --arg` / `--argjson`, never by shell interpolation into a command;
- opens the file exactly once (a bounded read of at most 16385 bytes into a private copy) and runs every check on that
  copy, so the file cannot change between checks and parsing; external commands only read it through stdin, so a file
  name can never act as an option or an `awk` assignment;
- emits ASCII-only JSON (`jq -a`), so non-ASCII text is always `\uXXXX`-escaped in the output;
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

- Line 1 is `# HANDOFF T-NNN` where `NNN` is 3 to 6 digits. Nothing may come before it.
- Between the title and `## Summary` only blank lines are allowed.
- Section headings are matched exactly (the text after `## `, trailing spaces ignored). Any other line starting with
  `## ` is an error (unknown section), and so is any other line starting with `# ` (second title).
  `###` and deeper headings are ordinary content.
- Headings inside a fenced code block (a line starting with three backticks opens and closes the fence) are content, not
  structure. A fence still open at the end of the file is an error.
- Leading and trailing blank lines of every section are ignored. Every section must have content.

## Global limits

| Limit | Value | Error text contains |
|---|---|---|
| Whole file | 16384 bytes (16 KB) | `oversize` |
| Any line | 500 bytes | `line too long` |
| Control and look-alike characters | only tab and LF are allowed. Rejected: NUL, CR, ESC and other C0 controls, DEL, C1 controls U+0080-U+009F (U+009B is a terminal CSI), U+200B-U+200F, U+2028-U+202E (includes bidi overrides), U+2066-U+2069, and U+FEFF (BOM, never allowed anywhere) | `control character` |

Byte limits are bytes, not characters (the parser runs with `LC_ALL=C`). An empty file is an error.

## Sections

### Summary

What changed and why. 1 to 5 lines (interior blank lines count). Free text, any characters.
JSON: `summary` (string, lines joined with `\n`).

### Files changed

One bullet per file: `- <path> - <note>`. The note is optional (`- <path>`), one line, free text.

- `<path>` is relative to the worktree root, with characters from `A-Z a-z 0-9 _ . / @ + = , ( ) [ ]` and `-`, at most
  256 bytes, no leading `/`, and no `..` component. These limits make the path safe to pass on as data; the lead must
  still check that it is inside the worker's owned files.
- The path and the note are separated by the first ` - ` (space, hyphen, space).
- At most 100 entries. A section with no changes contains the single line `none` (any case) and parses to `[]`.

JSON: `files_changed` (array of `{path, note}`, `note` is `""` when omitted).

### Tests run

Command and result, free text, 1 to 60 lines.
JSON: `tests_run` (string, lines joined with `\n`).

### Hard rules touched

One bullet per rule: `- <rule number(s)> - <test that proves it>`. Free text after `- `. Every non-blank line must start
with `- `. At most 20 entries. No rules touched: the single line `none` (any case), parsed to `[]`.
JSON: `hard_rules` (array of strings, the text after `- `).

### Open risks / questions

Free text, 1 to 60 lines. Write `None` if there are none.
JSON: `risks` (string, lines joined with `\n`).

### Confidence

The first word of the section is **`low`, `medium` or `high`** (lowercase), followed by end of line, whitespace, or one of
`, : ; .`, then the reason. The reason is required (rest of the first line plus any further lines, at most 10 lines
in all). `highly sure` and `High` are rejected as a bad confidence level.
JSON: `confidence` = `{level, why}`.

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
dependency (`jq`).

Error messages start with `handoff: ` and name the problem:

| Problem | Message contains |
|---|---|
| File missing / unreadable | `cannot read` |
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
