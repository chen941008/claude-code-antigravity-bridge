#!/usr/bin/env bash
# Checks that setup-grok.sh worked for the project in the current directory (macOS / Linux / WSL).
# Run it from your project root, after setup-grok.sh:   bash scripts/verify-grok.sh
# It never sends a prompt to a model, so it costs no credits. Exit code = number of FAIL lines.
set -uo pipefail

EXPECTED_RULES="v2"
PROJECT_DIR="$(pwd -P)"
GROK_DIR="${GROK_HOME:-$HOME/.grok}"
GLOBAL_CONFIG="$GROK_DIR/config.toml"
TRUST_FILE="$GROK_DIR/trusted_folders.toml"
PROJECT_CONFIG="$PROJECT_DIR/.grok/config.toml"
WORKER_SCRIPT="$PROJECT_DIR/.grok/grok-worker.py"
fail=0

pass() { echo "PASS  $1"; }
warn() { echo "WARN  $1"; }
bad()  { echo "FAIL  $1"; fail=$((fail + 1)); }

echo "Verifying grok-bridge in $PROJECT_DIR"

# 1. grok is installed, signed in, and loads the project-scoped permission rules (none of these run a model)
inspect=""
if command -v grok > /dev/null 2>&1; then
    pass "grok found: $(command -v grok) ($(grok --version 2> /dev/null | head -n 1))"
    models="$(grok models 2>&1 || true)"
    if printf '%s' "$models" | grep -q "Available models"; then
        pass "grok is signed in and lists models"
        printf '%s\n' "$models" | sed -n 's/^ *[-*] /INFO  model: /p'
    else
        warn "grok models did not list models (not signed in yet? run 'grok login')"
    fi
    inspect="$(grok inspect 2>&1 || true)"
else
    bad "grok is not on PATH (open a new terminal, or add ~/.grok/bin to PATH)"
fi

# 2. .grok/config.toml, .grok/grok-worker.py, trusted_folders.toml, and CLAUDE.md
if ! command -v python3 > /dev/null 2>&1; then
    bad "python3 not found, cannot check .grok/config.toml"
    echo; echo "$fail failure(s)."; exit "$fail"
fi

# Not inside $(...): bash 3.2 (macOS /bin/bash) mis-parses quotes in a heredoc there.
GROK_INSPECT="$inspect" python3 - "$PROJECT_CONFIG" "$GLOBAL_CONFIG" "$TRUST_FILE" "$WORKER_SCRIPT" "$PROJECT_DIR" "$EXPECTED_RULES" << 'PY'
import json, os, re, subprocess, sys

project_cfg, global_cfg, trust_file, worker_script, project, expected = sys.argv[1:7]
project = project.rstrip("/")
fails = 0

def ok(m): print("PASS  " + m)
def warn(m): print("WARN  " + m)
def bad(m):
    global fails
    fails += 1
    print("FAIL  " + m)

START = "# >>> grok-bridge: managed by setup-grok.sh, re-run it to update >>>"
END = "# <<< grok-bridge <<<"
needed_allow = ["Write(%s/**)" % project, "Edit(%s/**)" % project]
needed_deny = [
    "Read(**/.env)",
    "Read(**/.env.*)",
    "Read(**/*.pem)",
    "Read(**/*.key)",
    "Read(**/.ssh/**)",
    "Edit(**/.git/**)",
    "Write(**/.git/**)",
    "Edit(**/.grok/**)",
    "Write(**/.grok/**)",
]

# --- 2a. Project-scoped .grok/config.toml
if not os.path.exists(project_cfg):
    bad("project config not found at " + project_cfg + " (run setup-grok.sh)")
else:
    text = open(project_cfg, encoding="utf-8-sig").read()
    try:
        import tomllib
    except ImportError:
        tomllib = None
    perm = None
    if tomllib is not None:
        try:
            perm = tomllib.loads(text).get("permission", {})
            ok(".grok/config.toml is valid TOML")
        except Exception as e:
            bad(".grok/config.toml is not valid TOML: %s" % e)
    if perm is None:
        perm = {"allow": [r for r in needed_allow if json.dumps(r) in text],
                "deny": [r for r in needed_deny if json.dumps(r) in text]}
    if text.count(START) == 1 and text.count(END) == 1:
        ok(".grok/config.toml has one grok-bridge block")
    elif START in text or END in text:
        bad(".grok/config.toml has a broken or duplicated grok-bridge block")
    else:
        warn("no grok-bridge block in .grok/config.toml (fine if you added the rules to your own [permission] table)")
    for r in needed_allow:
        (ok if r in perm.get("allow", []) else bad)("project allow rule: " + r)
    # Check that no other project's Write/Edit rules are in this project's config
    foreign = [
        r for r in perm.get("allow", [])
        if (r.startswith("Write(") or r.startswith("Edit(")) and r not in needed_allow
    ]
    (bad("foreign project Write/Edit rules in .grok/config.toml: %r" % foreign)
     if foreign else ok("no foreign project Write/Edit rules in .grok/config.toml"))
    for r in needed_deny:
        (ok if r in perm.get("deny", []) else bad)("deny rule present: " + r)

# --- 2b. Global ~/.grok/config.toml has no lingering grok-bridge block
if os.path.exists(global_cfg):
    gtext = open(global_cfg, encoding="utf-8-sig").read()
    if START in gtext or END in gtext:
        bad("global ~/.grok/config.toml still has a legacy grok-bridge block (re-run setup-grok.sh to migrate)")
    else:
        ok("global config.toml has no grok-bridge block")
    # Global Write/Edit grants apply to every project, whatever wrote them.
    grants = re.findall(r'"((?:Write|Edit)\([^"]*\))"', "\n".join(
        line for line in gtext.splitlines() if not line.lstrip().startswith("#")))
    if grants:
        warn("global config.toml grants Write/Edit in every project: %s (move them into the .grok/config.toml of the project that needs them)"
             % ", ".join(grants))

# --- 2c. Folder trust & grok inspect
def parse_trusted_folders(ttext):
    if tomllib is not None:
        data = tomllib.loads(ttext)
        folders = data.get("folders", {})
        if not isinstance(folders, dict):
            raise ValueError("'folders' must be a table")
        out = {}
        for k, v in folders.items():
            if isinstance(v, dict) and "trusted" in v:
                if not isinstance(v["trusted"], bool):
                    raise ValueError(f"folders.{k!r}.trusted must be a boolean")
                out[k] = v["trusted"]
        return out
    out, cur = {}, None
    for raw in ttext.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("["):
            if not s.endswith("]"):
                raise ValueError(f"unclosed table header: {raw!r}")
            m = re.match(r'^folders\s*\.\s*("(?:[^"\\]|\\.)*"|\'[^\']*\')\s*$', s[1:-1].strip())
            cur = (json.loads(m.group(1)) if m.group(1).startswith('"') else m.group(1)[1:-1]) if m else None
            continue
        if cur is not None:
            m = re.match(r"^trusted\s*=\s*(true|false)\s*(?:#.*)?$", s)
            if m:
                out[cur] = (m.group(1) == "true")
            elif re.match(r"^trusted\s*=", s):
                raise ValueError(f"invalid boolean for trusted: {raw!r}")
    return out

if os.path.exists(trust_file):
    ttext = open(trust_file, encoding="utf-8-sig").read()
    try:
        tmap = parse_trusted_folders(ttext)
        if tmap.get(project) is True:
            ok("project is trusted (trusted = true) in " + trust_file)
        elif tmap.get(project) is False:
            bad("project is explicitly marked 'trusted = false' in " + trust_file)
        else:
            bad("project is not registered as trusted in " + trust_file)
    except Exception as e:
        bad("trusted_folders.toml is not valid TOML: %s" % e)
else:
    bad("trusted_folders.toml not found at " + trust_file + " (run setup-grok.sh)")

inspect = os.environ.get("GROK_INSPECT", "")
m = re.search(r"(\d+) loaded, (\d+) skipped", inspect)
if not inspect:
    pass
elif not m:
    warn("could not read the permission summary from 'grok inspect'")
else:
    loaded, skipped = int(m.group(1)), int(m.group(2))
    total = len(needed_allow) + len(needed_deny)
    (ok if loaded >= total else bad)("grok loads %d permission rules (needs at least %d)" % (loaded, total))
    if skipped:
        warn("grok skipped %d permission rule(s); run 'grok inspect' to see which" % skipped)

# --- 2d. CLI Wrapper (.grok/grok-worker.py)
if not os.path.exists(worker_script):
    bad("CLI wrapper not found at " + worker_script + " (run setup-grok.sh)")
else:
    res = subprocess.run(
        [sys.executable, worker_script, "--mode", "read-only", "-p", "ping", "--dry-run"],
        cwd=project, capture_output=True, text=True,
    )
    if res.returncode == 0:
        ok(".grok/grok-worker.py --dry-run succeeded")
    else:
        bad(".grok/grok-worker.py --dry-run failed: " + res.stderr.strip())

# --- 2e. CLAUDE.md
md_path = os.path.join(project, "CLAUDE.md")
if not os.path.exists(md_path):
    bad("CLAUDE.md not found in the project root (run setup-grok.sh here)")
else:
    md = open(md_path, encoding="utf-8").read()
    starts = re.findall(r"^<!-- grok-bridge:start (v\d+) -->$", md, re.M)
    ends = re.findall(r"^<!-- grok-bridge:end -->$", md, re.M)
    if len(starts) != 1 or len(ends) != 1:
        bad("CLAUDE.md must contain exactly one grok-bridge block (found %d start, %d end)" % (len(starts), len(ends)))
    else:
        (ok if starts[0] == expected else bad)("CLAUDE.md grok rules version is %s (expected %s)" % (starts[0], expected))
        block = md[md.index("<!-- grok-bridge:start"):md.index("<!-- grok-bridge:end -->")]
        (bad if "``" in block else ok)("rules block has no doubled backticks")
        (ok if ".grok/grok-worker.py" in block else bad)("rules block uses .grok/grok-worker.py")

sys.exit(fails)
PY
py_fail=$?
fail=$((fail + py_fail))

echo
echo "$fail failure(s)."
exit "$fail"
