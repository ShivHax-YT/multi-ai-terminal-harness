#!/usr/bin/env bash
# parse.sh <HANDOFF.md>  ->  JSON on stdout (format: docs/spec/handoff.md)
#
#   {task_id, summary, files_changed:[{path,note}], tests_run, hard_rules:[..], risks, confidence:{level,why}}
#
# Exit codes: 0 valid, 1 invalid handoff (message on stderr, nothing on stdout), 2 usage error / jq missing.
#
# SECURITY: the input file is written by a worker AI and is untrusted data. This script never eval's, sources or
# expands file content. Content only ever sits inside quoted "$variables" and reaches jq through --arg or stdin.
# Error messages never echo file content (only section names, line numbers and limits).
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

set -f
export LC_ALL=C

MAX_BYTES=16384
MAX_LINE=500
MAX_FILES=100
MAX_RULES=20

SECTIONS=("Summary" "Files changed" "Tests run" "Hard rules touched" "Open risks / questions" "Confidence")

die() {
  printf 'handoff: %s\n' "$*" >&2
  exit 1
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
if ! command -v jq >/dev/null 2>&1; then
  printf 'handoff: jq is required but was not found\n' >&2
  exit 2
fi

file=$1
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  die "cannot read input file"
fi

# The file is opened exactly once, with a bounded read, into a private copy. Every later check and the main loop
# read that copy through stdin redirection, so a file name can never act as an option or an awk assignment and the
# file cannot change between the checks and the parse (TOCTOU). External commands never receive a path argument
# derived from the input.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/handoff-parse.XXXXXX") || die "cannot create temp dir"
trap 'rm -rf "$WORK"' EXIT
copy="$WORK/copy"
head -c $((MAX_BYTES + 1)) <"$file" >"$copy" 2>/dev/null || die "cannot read input file"

# ---- whole-file checks (before any line is interpreted) ----------------------------------------------------------
size=$(wc -c <"$copy" | tr -d '[:space:]')
case $size in
  '' | *[!0-9]*) die "cannot determine file size" ;;
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

# Control characters and look-alikes, all rejected (LC_ALL=C, so these are raw byte patterns):
#   C0 controls except tab and LF (includes CR and ESC), DEL
#   C1 controls U+0080-U+009F (U+009B is CSI, a terminal escape introducer)
#   U+200B-U+200F zero-width and direction marks, U+2028-U+202E line/paragraph separators and bidi overrides
#   U+2066-U+2069 bidi isolates, U+FEFF byte order mark / zero-width no-break space
# grep reads stdin; only exit status 1 (no match) counts as clean. 0 (match) and >= 2 (error) both fail closed.
BAD_CHARS=$'[\001-\010\013-\037\177]|\xC2[\x80-\x9F]|\xE2\x80[\x8B-\x8F\xA8-\xAE]|\xE2\x81[\xA6-\xA9]|\xEF\xBB\xBF'
grep -q -E -e "$BAD_CHARS" <"$copy" 2>/dev/null
case $? in
  1) ;;
  0) die "control character in file (only tab, LF and plain text allowed; no CR, ESC, C1, bidi or zero-width characters)" ;;
  *) die "internal error checking control characters" ;;
esac

long_line=$(awk -v max="$MAX_LINE" 'length($0) > max { print NR; exit }' <"$copy") || die "internal error checking line length"
if [ -n "$long_line" ]; then
  die "line too long: line $long_line exceeds $MAX_LINE bytes"
fi

# ---- helpers -----------------------------------------------------------------------------------------------------
NONBLANK_RE='[^[:space:]]'

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
    if [[ ${all[i]} =~ $NONBLANK_RE ]]; then
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
    if [[ $line =~ $NONBLANK_RE ]]; then
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

# Files changed
FILE_RE='^([]A-Za-z0-9_./@+=,()[-]+)( - (.*))?$'
load_lines "$S1" "Files changed" "$MAX_FILES"
files_tsv=''
if [ "$LN" -eq 1 ] && is_none "${L[0]}"; then
  files_json='[]'
else
  for ((i = 0; i < LN; i++)); do
    line=${L[i]}
    if [[ $line != '- '* ]]; then
      die "bad files_changed entry: item $((i + 1)) must start with '- '"
    fi
    entry=${line#- }
    if ! [[ $entry =~ $FILE_RE ]]; then
      die "bad files_changed entry: item $((i + 1)) must be '- <path> - <note>' with a plain relative path"
    fi
    path=${BASH_REMATCH[1]}
    note=${BASH_REMATCH[3]}
    if [ "${#path}" -gt 256 ]; then
      die "bad files_changed entry: item $((i + 1)) path longer than 256 bytes"
    fi
    case "/$path/" in
      /-* | //* | */../*) die "bad files_changed entry: item $((i + 1)) path must be relative, not start with '-', and contain no '..'" ;;
    esac
    files_tsv+="$path"$'\t'"$note"$'\n'
  done
  files_json=$(printf '%s' "$files_tsv" | jq -Rn '[inputs | index("\t") as $i | {path: .[:$i], note: .[$i+1:]}]') ||
    die "internal error building files_changed"
fi

# Tests run
load_lines "$S2" "Tests run" 60
join_lines
tests_run=$J

# Hard rules touched
load_lines "$S3" "Hard rules touched" "$MAX_RULES"
if [ "$LN" -eq 1 ] && is_none "${L[0]}"; then
  rules_json='[]'
else
  rules_txt=''
  for ((i = 0; i < LN; i++)); do
    line=${L[i]}
    if [[ $line != '- '* ]]; then
      die "bad hard_rules entry: item $((i + 1)) must start with '- '"
    fi
    entry=${line#- }
    if ! [[ $entry =~ $NONBLANK_RE ]]; then
      die "bad hard_rules entry: item $((i + 1)) is empty"
    fi
    rules_txt+="$entry"$'\n'
  done
  rules_json=$(printf '%s' "$rules_txt" | jq -Rn '[inputs]') ||
    die "internal error building hard_rules"
fi

# Open risks / questions
load_lines "$S4" "Open risks / questions" 60
join_lines
risks=$J

# Confidence
CONF_RE='^(low|medium|high)([[:space:],:;.]|$)(.*)$'
load_lines "$S5" "Confidence" 10
if ! [[ ${L[0]} =~ $CONF_RE ]]; then
  die "bad confidence level: the Confidence section must start with low, medium or high"
fi
level=${BASH_REMATCH[1]}
rest=${BASH_REMATCH[3]}
prefix=${rest%%[![:space:],:;.-]*}
rest=${rest#"$prefix"}
L[0]=$rest
join_lines
nl=$'\n'
why=${J#"${J%%[!"$nl"]*}"} # drop leading newlines (level alone on the first line)
if ! [[ $why =~ $NONBLANK_RE ]]; then
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
  die "internal error building output"
