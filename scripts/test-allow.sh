#!/usr/bin/env bash
# Offline unit test for scripts/allow.sh (no agy, no network, no quota).
set -uo pipefail
cd "$(dirname "$0")/.."
ALLOW="scripts/allow.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AGY_BRIDGE_SETTINGS="$tmp/settings.json"
fail=0

expect() {
    local want=$1 desc=$2 cmd=$3
    if eval "$cmd"; then
        echo "ok   $desc"
    else
        echo "FAIL $desc (wanted $want)"
        fail=1
    fi
}

allowed() {
    python3 - "$AGY_BRIDGE_SETTINGS" "$1" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
allow = data.get("permissions", {}).get("allow", [])
sys.exit(0 if sys.argv[2] in allow else 1)
PY
}

printf '%s' '{"model":"keep-me","permissions":{"allow":["command(ls)"],"deny":["command(rm -rf)","command(git push -f)"]}}' > "$AGY_BRIDGE_SETTINGS"

bash "$ALLOW" "npm test" pytest > /dev/null
expect 0 "add two rules" '[ $? -eq 0 ] && allowed "command(npm test)" && allowed "command(pytest)"'

out="$(bash "$ALLOW" "npm test *")"
expect 0 "trailing * normalized to existing rule" '[[ "$out" == *"already allowed"* ]]'

out="$(bash "$ALLOW" "command(go test)")"
expect 0 "command(...) form normalized" 'allowed "command(go test)"'

out="$(bash "$ALLOW" "rm -rf build" 2>&1 || true)"
expect 0 "rm refused" '[[ "$out" == *"[REFUSED]"* ]]'

out="$(bash "$ALLOW" "git push -f origin" 2>&1 || true)"
expect 0 "deny conflict refused" '[[ "$out" == *"deny rule"* ]]'

out="$(bash "$ALLOW" python 2>&1 || true)"
expect 0 "bare python refused" '[[ "$out" == *"[REFUSED]"* ]] && ! allowed "command(python)"'

bash "$ALLOW" "python -m pytest" > /dev/null
expect 0 "python -m pytest allowed" 'allowed "command(python -m pytest)"'

out="$(bash "$ALLOW" "ls | cat" 2>&1 || true)"
expect 0 "pipe refused" '[[ "$out" == *"shell operators"* ]]'

out="$(bash "$ALLOW" "/usr/bin/agy -p x" 2>&1 || true)"
expect 0 "agy path refused" '[[ "$out" == *"agy must never call itself"* ]]'

out="$(bash "$ALLOW" rg < /dev/null 2>&1 || true)"
expect 0 "rg needs confirmation (skipped without tty)" '[[ "$out" == *"[SKIPPED]"* ]] && ! allowed "command(rg)"'

bash "$ALLOW" --yes rg > /dev/null
expect 0 "rg allowed with --yes" 'allowed "command(rg)"'

bash "$ALLOW" --remove pytest > /dev/null
expect 0 "remove rule" '! allowed "command(pytest)"'

bash "$ALLOW" --autonomous > /dev/null
expect 0 "autonomous mode adds command(*)" 'allowed "command(*)"'

python3 - "$AGY_BRIDGE_SETTINGS" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
deny = data.get("permissions", {}).get("deny", [])
assert "command(agy)" in deny, "command(agy) not in deny"
assert "command(rm -rf)" in deny, "rm not in deny"
PY
expect 0 "autonomous mode ensures agy and rm in deny" '[ $? -eq 0 ]'

bash "$ALLOW" --strict > /dev/null
expect 0 "strict mode removes command(*)" '! allowed "command(*)"'

out="$(bash "$ALLOW" --list)"
expect 0 "list contains deny and allow rules" '[[ "$out" == *"command(rm -rf)"* ]] && [[ "$out" == *"command(npm test)"* ]]'

out="$(bash "$ALLOW" 2>&1 || true)"
expect 0 "no args exits with usage" '[[ "$out" == *"Usage:"* ]]'

expect 0 "other keys in settings.json preserved" 'grep -q keep-me "$AGY_BRIDGE_SETTINGS"'

printf '%s' '{"permissions": ' > "$AGY_BRIDGE_SETTINGS"
out="$(bash "$ALLOW" pytest 2>&1 || true)"
expect 0 "malformed settings.json untouched on error" '[ "$(cat "$AGY_BRIDGE_SETTINGS")" = "{\"permissions\": " ]'

rm -f "$AGY_BRIDGE_SETTINGS"
bash "$ALLOW" pytest > /dev/null
expect 0 "missing settings.json auto-created" 'allowed "command(pytest)"'

exit $fail
