# split.jq: split the runner's combined output (child stdout AND stderr in one file) into its two parts.
#
#   jq -R -r --arg part raw   -f split.jq combined.txt > raw.jsonl      lines that are one JSON object
#   jq -R -r --arg part other -f split.jq combined.txt > stderr.txt     every other line (blank, text, or JSON that is not an object)
#
# Every input line lands in exactly one of the two outputs. A line is "raw" only when it parses as a JSON OBJECT, so a bare
# number, string, array, null, or half a line from interleaved output never reaches raw.jsonl. The text of a line is only
# copied, never interpreted (untrusted data). run.sh and resume.sh call this; spike/tests/test_claude_parse.sh tests it offline.
def is_object_line: try (fromjson | type == "object") catch false;

if $part == "raw" then select(is_object_line)
elif $part == "other" then select(is_object_line | not)
else error("split.jq needs --arg part raw|other") end
