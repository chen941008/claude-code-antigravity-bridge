#!/usr/bin/env bash
# Safely lets agy run more shell commands in headless mode (agy -p), by adding
# "command(...)" rules to permissions.allow in ~/.gemini/antigravity-cli/settings.json.
#
#   bash scripts/allow.sh "npm test" pytest     add rules (one per argument)
#   bash scripts/allow.sh --list                 show the current allow / deny rules
#   bash scripts/allow.sh --remove pytest        remove rules
#   bash scripts/allow.sh --yes rg               skip the confirmation some commands need
#
# Without a checkout of this repo:
#   curl -fsSL https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.4.0/scripts/allow.sh | bash -s -- "npm test"
#
# Rules are prefix matches: "npm test" also allows "npm test -- --watch". The settings file is
# global, so a rule applies to every project. Never touches anything but permissions.allow.
set -euo pipefail

if ! command -v python3 > /dev/null 2>&1; then
    echo "[ERROR] python3 is required but was not found."
    exit 1
fi

# AGY_BRIDGE_SETTINGS points at another settings file (used by the tests).
python3 - "${AGY_BRIDGE_SETTINGS:-$HOME/.gemini/antigravity-cli/settings.json}" "$@" << 'PY'
import json, os, re, sys

settings_path, args = sys.argv[1], sys.argv[2:]

# First word of the rule (lowercase, without a directory or .exe/.cmd/.bat/.ps1).
# Always refused: they delete, escalate, download, re-run arbitrary commands, or call agy itself.
BLOCKED = {
    "agy", "rm", "rmdir", "del", "erase", "rd", "ri", "remove-item", "sudo", "su", "doas", "runas",
    "dd", "mkfs", "format", "shutdown", "reboot", "chmod", "chown", "icacls", "takeown",
    "curl", "wget", "scp", "ssh", "nc", "invoke-webrequest", "iwr", "invoke-restmethod", "irm",
    "invoke-expression", "iex", "start-process", "eval", "exec", "xargs", "env", "nohup", "nice",
    "timeout", "watch", "time", "command", "builtin", "set-executionpolicy", "reg", "setx",
}
# Refused when allowed on their own (they would run any code or any subcommand);
# a longer prefix such as "python -m pytest" or "docker compose ps" is fine.
BARE_BLOCKED = {
    "bash", "sh", "zsh", "fish", "dash", "ksh", "pwsh", "powershell", "cmd", "wsl",
    "python", "python3", "py", "node", "deno", "bun", "ruby", "perl", "php", "lua", "java",
    "npx", "pnpx", "bunx", "uvx", "osascript",
    "docker", "kubectl", "helm", "terraform", "gh", "aws", "gcloud", "az",
}
# Need a confirmation: they print file contents, so they can show .env and other secrets
# ("read_file(.env)" in deny only covers agy's read_file tool, not shell commands).
CONTENT_READERS = {
    "cat", "tac", "type", "get-content", "gc", "head", "tail", "less", "more", "bat", "nl",
    "rg", "grep", "egrep", "fgrep", "ag", "ack", "select-string", "sls", "findstr",
    "jq", "yq", "sed", "awk", "find", "fd", "strings", "od", "xxd", "hexdump", "base64",
    "cut", "sort", "uniq",
}
# Need a confirmation when allowed on their own: they also install packages and run any script.
BROAD_RUNNERS = {
    "npm", "pnpm", "yarn", "pip", "pip3", "uv", "poetry", "cargo", "go", "make", "gradle",
    "gradlew", "mvn", "dotnet", "composer", "bundle", "rake", "cmake", "ninja",
}
SHELL_OPERATORS = re.compile(r"[|;&<>`\r\n]|\$\(")


def usage():
    print("Usage: allow.sh [--yes] <command>...   add rules, e.g. allow.sh \"npm test\" pytest")
    print("       allow.sh --list                  show the current allow / deny rules")
    print("       allow.sh --remove <command>...   remove rules")
    print("       allow.sh --autonomous            activate Autonomous Mode (command(*))")
    print("       allow.sh --strict                restore Strict Safe Mode (remove command(*))")


def normalize(arg):
    s = arg.strip()
    m = re.fullmatch(r"command\((.*)\)", s, re.S)
    if m:
        s = m.group(1).strip()
    # A trailing " *" does not work in agy: rules are already prefix matches.
    s = re.sub(r"\s*\*$", "", s).strip()
    return re.sub(r"[ \t]+", " ", s)


def first_word(cmd):
    word = re.split(r"[\\/]", cmd.split(" ")[0])[-1].lower()
    return re.sub(r"\.(exe|cmd|bat|ps1)$", "", word)


def classify(cmd, deny):
    """Returns (verdict, reason): verdict is ok, confirm or block."""
    if not cmd or "*" in cmd:
        return "block", "wildcards are not supported (rules are prefix matches) and '*' would allow everything"
    if SHELL_OPERATORS.search(cmd):
        return "block", "contains shell operators (| ; & < > ` $( ); agy blocks compound commands anyway"
    for rule in deny:
        m = re.fullmatch(r"command\((.*)\)", rule, re.S)
        if m and (cmd == m.group(1) or cmd.startswith(m.group(1) + " ")):
            return "block", "it matches your deny rule " + rule
    word, single = first_word(cmd), " " not in cmd
    if word == "agy":
        return "block", "agy must never call itself (runaway self-recursion and quota use)"
    if word in BLOCKED:
        return "block", "'%s' can delete files, escalate privileges, download, or run other commands" % word
    if word in BARE_BLOCKED and single:
        return "block", "'%s' on its own would let agy run any code; allow a narrower prefix such as 'python -m pytest'" % cmd
    if word in CONTENT_READERS:
        return "confirm", "it prints file contents, so agy could show .env or other secrets (deny read_file(.env) does not stop it)"
    if word in BROAD_RUNNERS and single:
        return "confirm", "'%s' on its own also installs packages and runs any script; '%s test' is safer" % (cmd, cmd)
    return "ok", ""


def ask(question):
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write(question + " [y/N] ")
            tty.flush()
            return tty.readline().strip().lower() in ("y", "yes")
    except OSError:
        return None  # no terminal


def load():
    data = {}
    if os.path.exists(settings_path):
        try:
            with open(settings_path, encoding="utf-8-sig") as f:
                text = f.read().strip()
            if text:
                data = json.loads(text)
        except Exception as e:
            sys.exit("[ERROR] Could not parse %s: %s\n        Nothing was changed. Fix the file and run again." % (settings_path, e))
    if not isinstance(data, dict):
        sys.exit("[ERROR] settings.json must contain a JSON object. Nothing was changed.")
    perms = data.setdefault("permissions", {})
    if not isinstance(perms, dict):
        sys.exit('[ERROR] "permissions" in settings.json must be an object. Nothing was changed.')
    for key in ("allow", "deny"):
        if perms.get(key) is None:
            perms[key] = []
        if not isinstance(perms[key], list):
            sys.exit('[ERROR] "permissions.%s" in settings.json must be an array. Nothing was changed.' % key)
    return data


def save(data):
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    tmp = settings_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, settings_path)


mode, yes, cmds = "add", False, []
for a in args:
    if a in ("-h", "--help"):
        usage()
        sys.exit(0)
    elif a in ("-l", "--list"):
        mode = "list"
    elif a in ("-r", "--remove"):
        mode = "remove"
    elif a in ("-y", "--yes"):
        yes = True
    elif a in ("-a", "--auto", "--autonomous"):
        mode = "autonomous"
    elif a in ("--strict", "--restore-strict"):
        mode = "strict"
    else:
        cmds.append(a)

data = load()
allow, deny = data["permissions"]["allow"], data["permissions"]["deny"]

if mode == "autonomous":
    changed = False
    if "command(*)" not in allow:
        allow.append("command(*)")
        changed = True
    essential_deny = [
        "command(rm -rf)", "command(sudo)", "command(git push --force)",
        "command(git push -f)", "command(agy)", "write_file(.git/)", "read_file(.env)"
    ]
    for d in essential_deny:
        if d not in deny:
            deny.append(d)
            changed = True
    if changed:
        save(data)
    print("[OK] Autonomous Mode activated: 'command(*)' added to permissions.allow.")
    print("     agy can run general commands freely without soft-denials.")
    print("     High-risk operations (rm, sudo, git push -f, .env, agy) remain strictly blocked by deny rules.")
    sys.exit(0)

if mode == "strict":
    if "command(*)" in allow:
        allow.remove("command(*)")
        save(data)
        print("[OK] Strict Safe Mode restored: 'command(*)' removed from permissions.allow.")
    else:
        print("[INFO] 'command(*)' was not present. Already in Strict Safe Mode.")
    sys.exit(0)

if mode == "list":
    print("Settings: " + settings_path)
    print("allow:")
    for r in allow:
        print("  " + str(r))
    print("deny:")
    for r in deny:
        print("  " + str(r))
    sys.exit(0)

if not cmds:
    usage()
    sys.exit(1)

failed, changed = 0, False
for arg in cmds:
    cmd = normalize(arg)
    rule = "command(%s)" % cmd
    if mode == "remove":
        if rule in allow:
            allow.remove(rule)
            changed = True
            print("[OK] Removed " + rule)
        else:
            print("[INFO] %s was not in permissions.allow" % rule)
        continue
    if rule in allow:
        print("[OK] %s is already allowed" % rule)
        continue
    verdict, reason = classify(cmd, deny)
    if verdict == "block":
        print("[REFUSED] %s: %s" % (rule, reason))
        failed += 1
        continue
    if verdict == "confirm" and not yes:
        print("[CAUTION] %s: %s" % (rule, reason))
        answer = ask("          Allow it anyway?")
        if answer is None:
            print("          No terminal to confirm. Re-run with --yes if you are sure.")
        if not answer:
            print("[SKIPPED] " + rule)
            failed += 1
            continue
    allow.append(rule)
    changed = True
    print("[OK] Allowed " + rule)

if changed:
    save(data)
    print("Saved %s. Rules apply to every project; undo with --remove." % settings_path)
sys.exit(1 if failed else 0)
PY
