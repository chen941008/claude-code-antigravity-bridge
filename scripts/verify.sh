#!/usr/bin/env bash
# Checks that setup.sh worked for the project in the current directory (macOS / Linux / WSL).
# Run it from your project root, after setup.sh:   bash scripts/verify.sh
# It never calls a model, so it costs no quota. Exit code = number of FAIL lines.
set -uo pipefail

EXPECTED_RULES="v6"
PROJECT_DIR="$(pwd -P)"
SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
TARGET_SPEC="${1:-${AGY_BRIDGE_TARGETS:-all}}"
fail=0

pass() { echo "PASS  $1"; }
warn() { echo "WARN  $1"; }
bad()  { echo "FAIL  $1"; fail=$((fail + 1)); }

echo "Verifying agy-bridge in $PROJECT_DIR"

# 1. agy is installed and answers (the /usage query runs no model)
if command -v agy > /dev/null 2>&1; then
    pass "agy found: $(command -v agy)"
    usage="$(agy -p "/usage" --output-format json --print-timeout 30s 2> /dev/null || true)"
    if [ -n "$usage" ] && command -v python3 > /dev/null 2>&1; then
        printf '%s' "$usage" | python3 -c '
import json, sys
try:
    groups = json.load(sys.stdin)["command"]["data"]["groups"]
except Exception:
    sys.exit(1)
for g in groups:
    parts = ", ".join("%s %d%%" % (b["window"], round(b["remaining_fraction"] * 100)) for b in g["buckets"])
    print("INFO  quota group %s: %s" % (g["name"], parts))
' || warn "agy /usage returned something unexpected (not a failure of the setup itself)"
    else
        warn "agy /usage gave no output (not logged in yet? run 'agy' once to sign in)"
    fi
else
    bad "agy is not on PATH (open a new terminal, or add ~/.local/bin to PATH)"
fi

# 2. settings.json and CLAUDE.md
if ! command -v python3 > /dev/null 2>&1; then
    bad "python3 not found, cannot check settings.json"
    echo; echo "$fail failure(s)."; exit "$fail"
fi

out="$(python3 - "$SETTINGS" "$PROJECT_DIR" "$EXPECTED_RULES" "$TARGET_SPEC" << 'PY'
import json, os, re, sys

settings, project, expected, target_spec = sys.argv[1:5]
if target_spec in ("--claude", "--claude-only", "claude", "CLAUDE.md"):
    target_docs = ("CLAUDE.md",)
elif target_spec in ("--agents", "--agents-only", "--codex", "agents", "codex", "AGENTS.md"):
    target_docs = ("AGENTS.md",)
else:
    target_docs = ("CLAUDE.md", "AGENTS.md")
fails = 0

def ok(m): print("PASS  " + m)
def bad(m):
    global fails
    fails += 1
    print("FAIL  " + m)

# --- settings.json
data = None
if not os.path.exists(settings):
    bad("settings.json not found at " + settings + " (run setup.sh)")
else:
    raw = open(settings, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        bad("settings.json starts with a UTF-8 BOM (agy reports it as malformed)")
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except Exception as e:
        bad("settings.json is not valid JSON: %s" % e)
if data is not None:
    perms = data.get("permissions") if isinstance(data, dict) else None
    if not isinstance(perms, dict):
        bad('"permissions" is missing or not an object')
    else:
        allow, deny = perms.get("allow"), perms.get("deny")
        trusted = data.get("trustedWorkspaces")
        for name, v in (("permissions.allow", allow), ("permissions.deny", deny), ("trustedWorkspaces", trusted)):
            if isinstance(v, list):
                ok(name + " is an array (%d entries)" % len(v))
            else:
                bad(name + " is missing or not an array")
        rule = "write_file(%s/)" % project.rstrip("/")
        if isinstance(allow, list):
            (ok if rule in allow else bad)("write rule for this project: " + rule)
        if isinstance(trusted, list):
            (ok if project in trusted else bad)("project is a trusted workspace")
        if isinstance(allow, list):
            if "command(*)" in allow:
                print("INFO  agy is in Autonomous Mode (command(*)): general commands run freely without soft-denials.")
                print("INFO  High-risk operations are guarded by permissions.deny.")
            else:
                cmds = [m.group(1) for m in (re.fullmatch(r"command\((.*)\)", str(r)) for r in allow) if m]
                print("INFO  agy may run these commands headless: " + ", ".join(cmds))
                print('INFO  To allow more (tests, rg, ...): bash scripts/allow.sh "<command>" or bash scripts/allow.sh --autonomous')
            for r in map(str, allow):
                if r == "write_file(*)":
                    print("WARN  risky allow rule: write_file(*) allows writes outside the project directory")
                elif re.fullmatch(r"command\(.*\*.*\)", r) and r != "command(*)":
                    print("WARN  risky allow rule: %s ('*' allows far more than intended; rules are already prefix matches)" % r)
                elif re.fullmatch(r"command\((.*/)?agy( .*)?\)", r):
                    print("WARN  allow rule %s lets agy call itself; remove it with: bash scripts/allow.sh --remove \"%s\"" % (r, r[8:-1]))
        if isinstance(deny, list):
            for r in ("write_file(.git/)", "read_file(.env)"):
                (ok if r in deny else bad)("deny rule present: " + r)

# --- CLAUDE.md / AGENTS.md
for doc_name in target_docs:
    md_path = os.path.join(project, doc_name)
    if not os.path.exists(md_path):
        bad(doc_name + " not found in the project root (run setup.sh here)")
    else:
        raw_md = open(md_path, "rb").read()
        if raw_md.startswith(b"\xef\xbb\xbf"):
            bad(doc_name + " starts with a UTF-8 BOM")
        md = raw_md.decode("utf-8-sig")
        starts = re.findall(r"^<!-- agy-bridge:start (v\d+) -->\r?$", md, re.M)
        ends = re.findall(r"^<!-- agy-bridge:end -->\r?$", md, re.M)
        if len(starts) != 1 or len(ends) != 1:
            bad("%s must contain exactly one agy-bridge block (found %d start, %d end)" % (doc_name, len(starts), len(ends)))
        else:
            (ok if starts[0] == expected else bad)("%s rules version is %s (expected %s)" % (doc_name, starts[0], expected))
            block = md[md.index("<!-- agy-bridge:start"):]
            (bad if "``" in block else ok)(doc_name + " rules block has no doubled backticks")
            (ok if '`agy -p "/usage"' in block else bad)(doc_name + " rules block mentions the /usage quota check")

sys.exit(fails)
PY
)"
py_fail=$?
echo "$out"
fail=$((fail + py_fail))

echo
echo "$fail failure(s)."
exit "$fail"
