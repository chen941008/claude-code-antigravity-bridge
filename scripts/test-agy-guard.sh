#!/usr/bin/env bash
# Offline unit test for extras/claude-hook/agy_guard.py (no Claude, no agy, no quota).
set -uo pipefail
cd "$(dirname "$0")/.."
HOOK=extras/claude-hook/agy_guard.py
fail=0

# expect <exit code> <description> <json event>
expect() {
    local want=$1 desc=$2 event=$3 got
    printf '%s' "$event" | python3 "$HOOK" 2>/dev/null
    got=$?
    if [ "$got" = "$want" ]; then echo "ok   $desc"; else echo "FAIL $desc (want $want, got $got)"; fail=1; fi
}

J='--output-format json'
JT='--output-format json --print-timeout 540s'
expect 0 "non-Bash tool passes"          '{"tool_name":"Read","tool_input":{"file_path":"x"}}'
expect 0 "unrelated bash passes"         '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
expect 0 "agy models passes"             '{"tool_name":"Bash","tool_input":{"command":"agy models"}}'
expect 0 "garbage input passes"          'not json'
expect 2 "missing json flag"             '{"tool_name":"Bash","tool_input":{"command":"agy -p \"hi\" --print-timeout 540s","timeout":600000}}'
expect 2 "missing timeout"               "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p \\\"hi\\\" $JT\"}}"
expect 2 "timeout too short"             "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p \\\"hi\\\" $JT\",\"timeout\":120000}}"
expect 2 "foreground missing print-timeout" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p \\\"hi\\\" $J\",\"timeout\":600000}}"
expect 0 "json + timeout + print-timeout passes" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p \\\"hi\\\" $JT\",\"timeout\":600000}}"
expect 0 "json + background passes"      "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p \\\"hi\\\" $J\",\"run_in_background\":true}}"
expect 0 "=-style flags pass"            '{"tool_name":"Bash","tool_input":{"command":"agy --print \"hi\" --output-format=json --print-timeout=540s","timeout":600000}}'
expect 2 "chained cd && agy caught"      '{"tool_name":"Bash","tool_input":{"command":"cd src && agy --prompt \"hi\"","timeout":600000}}'
expect 2 "full path agy caught"          '{"tool_name":"Bash","tool_input":{"command":"~/.local/bin/agy -p hi","timeout":600000}}'
expect 0 "agy-ish word not caught"       '{"tool_name":"Bash","tool_input":{"command":"echo legacy -p","timeout":1}}'

expect 0 "; inside quoted prompt not split" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p \\\"Fix A; then fix B\\\" $JT\",\"timeout\":600000}}"
expect 0 "| and && inside single quotes not split" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p 'a | b && c' $JT\",\"timeout\":600000}}"
expect 2 "real ; after quoted prompt still split" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"agy -p \\\"x; y\\\" $JT; agy -p hi\",\"timeout\":600000}}"
expect 0 "/usage query is exempt" '{"tool_name":"Bash","tool_input":{"command":"agy -p \"/usage\" --output-format json"}}'
expect 2 "prompt merely mentioning /usage is not exempt" '{"tool_name":"Bash","tool_input":{"command":"agy -p \"explain /usage\" --output-format json"}}'
expect 0 "codex/opencode shell + timeout_ms passes" "{\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"agy -p \\\"hi\\\" $JT\",\"timeout_ms\":600000}}"
expect 2 "codex/opencode shell missing json blocked" '{"tool_name":"shell","tool_input":{"command":"agy -p \"hi\" --print-timeout 540s","timeout_ms":600000}}'

exit $fail
