# scrub-init.jq: remove personal configuration from the system/init event BEFORE a capture is promoted to a fixture.
#
#   jq -c -f spike/claude/scrub-init.jq raw.jsonl | spike_redact > spike/fixtures/claude/observed.jsonl
#
# The init event lists the user's MCP servers, plugins, skills, slash commands, agents and tools by name. Those names can
# identify the person or their employer, so for the system/init event only, this replaces the value of each of these keys:
#   mcp_servers, plugins, skills, slash_commands, agents, tools
#     a non-empty array  -> ["<redacted>"]
#     an empty array     -> []
#     any other value    -> "<redacted>"   (null stays null)
# and adds "scrubbed_counts": {"<key>": <original array length, or null for a non-array>} so the shape stays useful (T-004).
# Every other event, and every non-object line, passes through unchanged. It is idempotent. It is NOT a substitute for
# spike_redact (paths, e-mail addresses, ids) or for the human's review of the whole file.
def scrub_keys: ["mcp_servers", "plugins", "skills", "slash_commands", "agents", "tools"];
def scrub_value: if type == "array" then (if length == 0 then [] else ["<redacted>"] end)
                 elif . == null then null
                 else "<redacted>" end;

if type == "object" and .type == "system" and .subtype == "init" then
  . as $o
  | ([scrub_keys[] as $k | select($o | has($k) and ($o[$k] != ["<redacted>"]))
      | {key: $k, value: ($o[$k] | if type == "array" then length else null end)}] | from_entries) as $counts
  | reduce scrub_keys[] as $k (.; if has($k) then .[$k] |= scrub_value else . end)
  | .scrubbed_counts = ((.scrubbed_counts // {}) + $counts)
else . end
