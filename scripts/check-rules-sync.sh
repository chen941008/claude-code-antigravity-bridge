#!/usr/bin/env bash
# Fails if the CLAUDE.md / AGENTS.md rules block in setup.sh, setup.ps1, and AGENTS.md differ.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import difflib, os, re, sys

def block(path, unescape):
    text = open(path, encoding="utf-8").read().replace("\r\n", "\n")
    # Markers at line start only, so the scripts' own logic never matches.
    m = re.search(r"^<!-- agy-bridge:start[^\n]*-->\n.*?^<!-- agy-bridge:end -->", text, re.S | re.M)
    if not m:
        sys.exit(f"rules block not found in {path}")
    out = m.group(0)
    return out.replace("``", "`") if unescape else out

sh = block("setup.sh", False)
# setup.ps1 holds the block in a literal @'...'@ here-string, so it must match byte for byte
# (an expandable @"..."@ once turned `$()` into an empty string).
ps = block("setup.ps1", False)
# Windows PowerShell 5.1 reads BOM-less scripts as ANSI, so non-ASCII text in setup.ps1
# would be written into CLAUDE.md / AGENTS.md as mojibake (e.g. an en dash became "??").
bad = sorted({c for c in sh if ord(c) > 127})
if bad:
    sys.exit("Rules block must be ASCII-only; found: " + " ".join("U+%04X" % ord(c) for c in bad))
if sh != ps:
    sys.stderr.write("".join(difflib.unified_diff(
        sh.splitlines(True), ps.splitlines(True), "setup.sh", "setup.ps1")))
    sys.exit("Rules blocks in setup.sh and setup.ps1 are out of sync.")
if os.path.exists("AGENTS.md"):
    ag = block("AGENTS.md", False)
    if sh != ag:
        sys.stderr.write("".join(difflib.unified_diff(
            sh.splitlines(True), ag.splitlines(True), "setup.sh", "AGENTS.md")))
        sys.exit("Rules block in AGENTS.md is out of sync with setup.sh.")
marker = re.match(r"<!-- agy-bridge:start (v\d+) -->", sh).group(1)
for path, pat in (("scripts/verify.sh", r'EXPECTED_RULES="(v\d+)"'), ("scripts/verify.ps1", r'\$ExpectedRules = "(v\d+)"')):
    found = re.search(pat, open(path, encoding="utf-8").read())
    if not found or found.group(1) != marker:
        sys.exit(f"{path} expects rules {found and found.group(1)} but setup.sh ships {marker}")

grok_text = open("setup-grok.sh", encoding="utf-8").read().replace("\r\n", "\n")
gm = re.search(r"^<!-- grok-bridge:start (v\d+) -->\n.*?^<!-- grok-bridge:end -->", grok_text, re.S | re.M)
if not gm:
    sys.exit("grok-bridge rules block not found in setup-grok.sh")
if "``" in gm.group(0):
    sys.exit("setup-grok.sh rules block contains doubled backticks")
gmarker = gm.group(1)
vfound = re.search(r'EXPECTED_RULES="(v\d+)"', open("scripts/verify-grok.sh", encoding="utf-8").read())
if not vfound or vfound.group(1) != gmarker:
    sys.exit(f"scripts/verify-grok.sh expects rules {vfound and vfound.group(1)} but setup-grok.sh ships {gmarker}")

wm = re.search(r"cat > \"\$WORKER_FILE\.tmp\" << 'GROK_WORKER_EOF'\n(.*?)\nGROK_WORKER_EOF", grok_text, re.S)
if not wm:
    sys.exit("embedded grok-worker.py not found in setup-grok.sh")
worker_standalone = open("scripts/grok-worker.py", encoding="utf-8").read().replace("\r\n", "\n").rstrip("\n")
if wm.group(1).rstrip("\n") != worker_standalone:
    sys.exit("embedded grok-worker.py in setup-grok.sh differs from scripts/grok-worker.py")

print("OK: rules blocks in setup.sh, setup.ps1, and AGENTS.md are identical, verify scripts expect "
      + marker + "; grok rules (" + gmarker + ") and grok-worker.py are in sync.")
PY
