#!/usr/bin/env bash
# parse.sh <HANDOFF.md>  ->  JSON on stdout (format: docs/spec/handoff.md)
#
#   {task_id, summary, files_changed:[{path,note}], tests_run, hard_rules:[..], risks, confidence:{level,why}}
#
# Exit codes: 0 valid, 1 invalid handoff (message on stderr, nothing on stdout), 2 usage error / jq or iconv missing,
#             3 internal error (temp dir, copy, jq or tool failure; the input was not judged).
#
# SECURITY: the input file is written by a worker AI and is untrusted data. This script never eval's, sources or
# expands file content. Content only ever sits inside quoted "$variables" and reaches jq through --arg or stdin.
# Error messages never echo file content (only section names, line numbers and limits).
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

set -f
export LC_ALL=C

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

# Arguments: parse.sh [--] <file>. Without "--", a first argument that looks like an option is a usage error.
if [ $# -ge 1 ] && [ "$1" = "--" ]; then
  shift
elif [ $# -ge 1 ]; then
  case $1 in
    -?*)
      printf 'usage: parse.sh [--] <HANDOFF.md>  (use "--" or ./ for file names starting with "-")\n' >&2
      exit 2
      ;;
  esac
fi
if [ $# -ne 1 ]; then
  printf 'usage: parse.sh [--] <HANDOFF.md>\n' >&2
  exit 2
fi
for tool in jq iconv; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'handoff: %s is required but was not found\n' "$tool" >&2
    exit 2
  fi
done

file=$1
# A symlink is never followed: a worker controls its worktree and could point HANDOFF.md at a file it must not read.
# The caller passes a canonical path inside the worker's worktree (symlinked parent directories are its concern).
if [ -L "$file" ]; then
  die "symlink not allowed: the input must be a regular file"
fi
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  die "cannot read input file"
fi

# The file is opened exactly once, with a bounded read, into a private copy. Every later check and the main loop
# read that copy through stdin redirection, so a file name can never act as an option or an awk assignment and the
# file cannot change between the checks and the parse (TOCTOU). External commands never receive a path argument
# derived from the input.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/handoff-parse.XXXXXX") || internal "cannot create temp dir"
trap 'rm -rf "$WORK"' EXIT
copy="$WORK/copy"
head -c $((MAX_BYTES + 1)) <"$file" >"$copy" 2>/dev/null || internal "cannot copy input file"

# ---- whole-file checks (before any line is interpreted) ----------------------------------------------------------
size=$(wc -c <"$copy" | tr -d '[:space:]')
case $size in
  '' | *[!0-9]*) internal "cannot determine file size" ;;
esac
if [ "$size" -gt "$MAX_BYTES" ]; then
  die "oversize: file is larger than $MAX_BYTES bytes"
fi
if [ "$size" -eq 0 ]; then
  die "empty file"
fi
nonul=$(tr -d '\000' <"$copy" | wc -c | tr -d '[:space:]')
if [ "$nonul" != "$size" ]; then
  die "control character: NUL byte in file"
fi

# Must be valid UTF-8 (the spec says UTF-8; jq would silently turn bad bytes into U+FFFD).
if ! iconv -f UTF-8 -t UTF-8 <"$copy" >/dev/null 2>&1; then
  die "invalid UTF-8 in file"
fi

# Control characters and look-alikes, all rejected (LC_ALL=C, so these are raw byte patterns):
#   C0 controls except tab and LF (includes CR and ESC), DEL
#   C1 controls U+0080-U+009F (U+009B is CSI, a terminal escape introducer)
#   U+200B-U+200F zero-width and direction marks, U+2028-U+202E line/paragraph separators and bidi overrides
#   U+2060-U+206F invisible operators, bidi isolates and deprecated format characters, U+00AD soft hyphen,
#   U+034F combining grapheme joiner, U+061C Arabic letter mark, U+180E Mongolian vowel separator,
#   U+FFF9-U+FFFB interlinear annotation, U+E0000-U+E007F tag characters (invisible text smuggling),
#   U+FEFF byte order mark / zero-width no-break space
# grep reads stdin; only exit status 1 (no match) counts as clean. 0 (match) and >= 2 (error) both fail closed.
BAD_CHARS=$'[\001-\010\013-\037\177]|\xC2[\x80-\x9F]|\xC2\xAD|\xCD\x8F|\xD8\x9C|\xE1\xA0\x8E|\xE2\x80[\x8B-\x8F\xA8-\xAE]|\xE2\x81[\xA0-\xAF]|\xEF\xBB\xBF|\xEF\xBF[\xB9-\xBB]|\xF3\xA0[\x80-\x81]'
grep -q -E -e "$BAD_CHARS" <"$copy" 2>/dev/null
case $? in
  1) ;;
  0) die "control character in file (only tab, LF and plain text allowed; no CR, ESC, C1, bidi or zero-width characters)" ;;
  *) internal "control character check failed" ;;
esac

long_line=$(awk -v max="$MAX_LINE" 'length($0) > max { print NR; exit }' <"$copy") || internal "line length check failed"
if [ -n "$long_line" ]; then
  die "line too long: line $long_line exceeds $MAX_LINE bytes"
fi

# ---- helpers -----------------------------------------------------------------------------------------------------
NBSP=$'\xC2\xA0'

# nonblank <text>: true if the text has any character other than ASCII whitespace and U+00A0 (no-break space).
nonblank() {
  local t=${1//[[:space:]]/}
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
  local all=()
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

# Confidence: the level is case-insensitive and is output in lowercase.
CONF_RE='^([A-Za-z]+)([[:space:],:;.]|$)(.*)$'
load_lines "$S5" "Confidence" 10
if ! [[ ${L[0]} =~ $CONF_RE ]]; then
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
if ! nonblank "$why"; then
  die "confidence missing reason: give a reason after the level"
fi

# ---- output (only reached when everything above passed) --------------------------------------------------------------
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
    hard_rules: $hard_rules, risks: $risks, confidence: {level: $level, why: $why}}' ||
  internal "building output failed"
