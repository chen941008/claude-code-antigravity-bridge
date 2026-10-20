#!/usr/bin/env bash
# Probes how agy matches write_file(...) rules (parentheses, symlinks) and whether
# --print-timeout really stops a headless run.
#
# Uses your real ~/.gemini/antigravity-cli/settings.json because agy's login lives under
# $HOME. The file is backed up first and restored on exit (also on Ctrl-C).
# Cost: 7 short `agy -p` runs on your default model.
set -euo pipefail

SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
BACKUP="$SETTINGS.probe-bak"
# Not under /tmp: on macOS /tmp is itself a symlink and would skew the symlink cases.
BASE="$HOME/agy-probe-$$"
LOGDIR="$PWD/agy-probe-logs"

[ -f "$SETTINGS" ] || { echo "[ERROR] $SETTINGS not found. Run setup.sh once first."; exit 1; }
[ -e "$BACKUP" ] && { echo "[ERROR] $BACKUP exists (previous run crashed?). Restore it manually first."; exit 1; }
cp "$SETTINGS" "$BACKUP"
cleanup() {
    cp "$BACKUP" "$SETTINGS" && rm -f "$BACKUP"
    rm -rf "$BASE"
    echo "[INFO] settings.json restored. Raw agy output is in $LOGDIR"
}
trap cleanup EXIT

mkdir -p "$LOGDIR" "$BASE/ctl" "$BASE/paren (v2)" "$BASE/paren (v2)-other" "$BASE/real"
ln -s "$BASE/real" "$BASE/link"
for d in "$BASE/ctl" "$BASE/paren (v2)" "$BASE/paren (v2)-other" "$BASE/real"; do
    git -C "$d" init -q
done

# set_rules <trusted dir> [write_file path ...]
# Starts from the backup, drops ALL existing write_file allows (so a broad rule of yours
# can't mask the result), then adds exactly the rules for this case.
set_rules() {
    python3 - "$SETTINGS" "$BACKUP" "$@" << 'PY'
import json, sys
dst, src, trusted, *writes = sys.argv[1:]
with open(src, encoding="utf-8-sig") as f:
    data = json.load(f)
perms = data.setdefault("permissions", {})
keep = [a for a in perms.get("allow", []) if not a.startswith("write_file(")]
perms["allow"] = [f"write_file({w}/)" for w in writes] + keep
data["trustedWorkspaces"] = [trusted] + [t for t in data.get("trustedWorkspaces", []) if t != trusted]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PY
}

PROMPT="Create a file named probe.txt in the current directory containing exactly the text: ok. Use only your file-writing tool, never a shell command. Do nothing else."

# probe <label> <cwd> <expectation text>
probe() {
    local label=$1 dir=$2 expect=$3 result
    rm -f "$dir/probe.txt"
    (cd "$dir" && agy -p "$PROMPT" --output-format json) > "$LOGDIR/$label.log" 2>&1 || true
    if [ -f "$dir/probe.txt" ]; then result=WRITTEN; else result=DENIED; fi
    printf '%-22s %-8s (%s)\n' "$label" "$result" "$expect"
}

echo "case                   result   (meaning)"
echo "---------------------------------------------------------------------------"
set_rules "$BASE/ctl"
probe 1-no-rule "$BASE/ctl" "must be DENIED, else trustedWorkspaces alone grants writes"

set_rules "$BASE/ctl" "$BASE/ctl"
probe 2-baseline "$BASE/ctl" "must be WRITTEN, else the probe itself is broken"

set_rules "$BASE/paren (v2)" "$BASE/paren (v2)"
probe 3-paren "$BASE/paren (v2)" "WRITTEN = parens parsed (check case 4 too)"

set_rules "$BASE/paren (v2)-other" "$BASE/paren (v2)"
probe 4-paren-sibling "$BASE/paren (v2)-other" "must be DENIED; WRITTEN = rule cut at ')' -> fails OPEN"

set_rules "$BASE/link" "$BASE/link"
probe 5-symlink-logical "$BASE/link" "WRITTEN = agy matches the path as typed"

set_rules "$BASE/link" "$BASE/real"
probe 6-symlink-physical "$BASE/link" "WRITTEN = agy resolves symlinks first"

echo "---------------------------------------------------------------------------"
set_rules "$BASE/ctl" "$BASE/ctl"
START=$(date +%s)
set +e
(cd "$BASE/ctl" && agy -p "Write a 4000-word essay about the history of compilers. Print it, do not create files." \
    --output-format json --print-timeout 5s) > "$LOGDIR/7-print-timeout.log" 2>&1
CODE=$?
set -e
echo "7-print-timeout        exit=$CODE after $(($(date +%s) - START))s (~5-10s = --print-timeout works; check the log for the JSON shape)"
