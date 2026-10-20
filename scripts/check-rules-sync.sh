#!/usr/bin/env bash
# Fails if the CLAUDE.md rules block embedded in setup.sh and setup.ps1 differ.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys

def block(path, unescape):
    text = open(path, encoding="utf-8").read().replace("\r\n", "\n")
    # Markers at line start only, so the scripts' own logic never matches.
    m = re.search(r"^<!-- agy-bridge:start[^\n]*-->\n.*?^<!-- agy-bridge:end -->", text, re.S | re.M)
    if not m:
        sys.exit(f"rules block not found in {path}")
    out = m.group(0)
    return out.replace("``", "`") if unescape else out

sh = block("setup.sh", False)
ps = block("setup.ps1", True)
if sh != ps:
    import difflib
    sys.stderr.write("".join(difflib.unified_diff(
        sh.splitlines(True), ps.splitlines(True), "setup.sh", "setup.ps1")))
    sys.exit("Rules blocks in setup.sh and setup.ps1 are out of sync.")
marker = re.match(r"<!-- agy-bridge:start (v\d+) -->", sh).group(1)
for path, pat in (("scripts/verify.sh", r'EXPECTED_RULES="(v\d+)"'), ("scripts/verify.ps1", r'\$ExpectedRules = "(v\d+)"')):
    found = re.search(pat, open(path, encoding="utf-8").read())
    if not found or found.group(1) != marker:
        sys.exit(f"{path} expects rules {found and found.group(1)} but setup.sh ships {marker}")
print("OK: rules blocks in setup.sh and setup.ps1 are identical, verify scripts expect " + marker + ".")
PY
